//
//  IOSEngineController.swift
//  AudioEngine
//
//  iOS counterpart of the macOS EngineController with the same public
//  surface (capture / playback / start / stop / apply / state + route
//  callbacks), so RealMumbleClient compiles unchanged on both platforms.
//
//  Differences from macOS, by design:
//   • No HAL device management — routing belongs to AVAudioSession, which
//     the app configures (IOSAudioSession: .playAndRecord + .voiceChat +
//     .allowBluetoothA2DP + .bluetoothHighQualityRecording).
//   • No recovery state machine — interruption and route-change
//     notifications are observed by the app, which stops and restarts the
//     engine (AVAudioEngine does not survive an iOS route change anyway).
//   • One backend: AVAudioEngine with voice processing (VPIO) unless the
//     config forces raw. VPIO + the session's high-quality-recording option
//     is what negotiates the good Bluetooth link on H2-class AirPods.
//

#if os(iOS)

import Foundation
import AVFAudio
import AudioToolbox

public enum BackendKind: String, Sendable {
    case voice   // AVAudioEngine + VPIO (AEC/NS/AGC)
    case raw     // AVAudioEngine without voice processing
}

/// Route-side description for the UI badge; mirrors the fields the app
/// reads from the macOS DeviceInfo.
public struct DeviceInfo: Equatable, Sendable {
    public let name: String
    public let qualityBadge: String?
}

public struct ResolvedRoute: Sendable {
    public let inputInfo: DeviceInfo
    public let outputInfo: DeviceInfo
    public let backend: BackendKind
}

public final class EngineController: @unchecked Sendable {

    // ---- Data plane (stable identity across rebuilds) ----------------------
    public let capture = CaptureEngine()
    public let playback = PlaybackEngine()

    // ---- Observability ------------------------------------------------------
    /// Delivered on the main queue.
    public var onStateChange: ((EngineState) -> Void)?
    /// Route info for the UI (badge, device names). Main queue.
    public var onRouteChange: ((ResolvedRoute?) -> Void)?

    public private(set) var state: EngineState = .idle {
        didSet {
            guard state != oldValue else { return }
            let s = state
            DispatchQueue.main.async { [onStateChange] in onStateChange?(s) }
        }
    }
    public private(set) var currentRoute: ResolvedRoute? {
        didSet {
            let r = currentRoute
            DispatchQueue.main.async { [onRouteChange] in onRouteChange?(r) }
        }
    }

    // ---- Internals -----------------------------------------------------------
    private let queue = DispatchQueue(label: "audio.engine.control", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var srcNode: AVAudioSourceNode?
    private var config = AudioConfig()
    private var desiredRunning = false

    public init() {}

    // MARK: - Public API (any thread)

    public func start(config: AudioConfig) {
        queue.async {
            self.config = config
            self.desiredRunning = true
            self.rebuild()
        }
    }

    public func stop() {
        queue.async {
            self.desiredRunning = false
            self.teardown()
            self.state = .idle
            self.currentRoute = nil
        }
    }

    public func apply(config newConfig: AudioConfig) {
        queue.async {
            let changed = newConfig != self.config
            self.config = newConfig
            guard self.desiredRunning, changed else { return }
            self.rebuild()
        }
    }

    // MARK: - Build / teardown (control queue)

    private func rebuild() {
        guard desiredRunning else { return }
        state = .starting
        teardown()
        do {
            try build()
            state = .running
        } catch {
            // The app's interruption / route-change handlers retrigger us.
            state = .degraded(error: "\(error)")
        }
    }

    private func build() throws {
        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let outputNode = eng.outputNode
        let useVoice = config.processing != .raw

        // Voice processing ON triggers the Bluetooth link-mode negotiation
        // (with .bluetoothHighQualityRecording set on the session, H2-class
        // AirPods keep full playback quality with the mic open).
        if useVoice {
            try inputNode.setVoiceProcessingEnabled(true)
            // Don't crush other apps' audio (music, navigation).
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                .init(enableAdvancedDucking: false, duckingLevel: .min)
        }

        // Formats are only valid after voice processing is toggled.
        let inFormat = inputNode.outputFormat(forBus: 0)
        let outNodeFormat = outputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, outNodeFormat.sampleRate > 0 else {
            throw IOSBackendError("negotiated zero sample rate")
        }

        // Capture: worker resamples device rate → 48 kHz; tap forwards mono.
        capture.start(sourceRate: inFormat.sampleRate, format: config.capture)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [capture] buf, _ in
            guard let ch0 = buf.floatChannelData?[0] else { return }
            capture.ingest(ch0, count: Int(buf.frameLength))
        }

        // Playback: source node pulls the 48 kHz mono mix at the device clock.
        guard let pullFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000, channels: 1,
                                             interleaved: false) else {
            throw IOSBackendError("make pull format")
        }
        let src = AVAudioSourceNode(format: pullFormat) { [playback] _, _, frames, ablPtr in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let ab = abl.first,
                  let dst = ab.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            playback.pullMix(into: dst, frames: Int(frames))
            return noErr
        }
        eng.attach(src)
        let mixer = eng.mainMixerNode
        eng.disconnectNodeOutput(mixer)
        eng.connect(mixer, to: outputNode, format: outNodeFormat)
        eng.connect(src, to: mixer, format: pullFormat)
        srcNode = src

        eng.prepare()
        do {
            try eng.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            capture.stop()
            throw error
        }
        engine = eng

        // AGC sub-property only sticks on an initialized AU.
        if useVoice, let au = inputNode.audioUnit {
            var agc: UInt32 = config.agcEnabled ? 1 : 0
            AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                                 kAudioUnitScope_Global, 0,
                                 &agc, UInt32(MemoryLayout<UInt32>.size))
        }

        playback.start()
        currentRoute = Self.resolveRoute(backend: useVoice ? .voice : .raw)
    }

    private func teardown() {
        if let eng = engine {
            if eng.isRunning {
                eng.inputNode.removeTap(onBus: 0)
                eng.stop()
            }
            if let s = srcNode { eng.detach(s) }
            try? eng.inputNode.setVoiceProcessingEnabled(false)
        }
        srcNode = nil
        engine = nil
        capture.stop()
        playback.stop()
    }

    // MARK: - Route description

    private static func resolveRoute(backend: BackendKind) -> ResolvedRoute {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let input = route.inputs.first
        let output = route.outputs.first
        return ResolvedRoute(
            inputInfo: DeviceInfo(name: input?.portName ?? "Default",
                                  qualityBadge: inputBadge(for: input, session: session)),
            outputInfo: DeviceInfo(name: output?.portName ?? "Default",
                                   qualityBadge: nil),
            backend: backend)
    }

    /// Bluetooth mics are the only interesting case: the session sample rate
    /// tells us whether the high-quality voice link actually engaged.
    private static func inputBadge(for port: AVAudioSessionPortDescription?,
                                   session: AVAudioSession) -> String? {
        guard let port else { return nil }
        switch port.portType {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            let kHz = Int((session.sampleRate / 1000).rounded())
            return session.sampleRate >= 32_000
                ? "High-quality Bluetooth voice (\(kHz) kHz)"
                : "Limited voice bandwidth (\(kHz) kHz link)"
        default:
            return nil
        }
    }
}

private struct IOSBackendError: Error, CustomStringConvertible {
    let stage: String
    var description: String { "\(stage) failed" }
    init(_ stage: String) { self.stage = stage }
}

#endif
