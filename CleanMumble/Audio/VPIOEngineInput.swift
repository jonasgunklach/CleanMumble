//
//  VPIOEngineInput.swift
//  CleanMumble
//
//  AVAudioEngine-based microphone capture with Apple's voice processing
//  (AEC + NS + AGC) enabled. This is the path Discord, Teams, Zoom, and
//  Apple's own apps use on macOS.
//
//  Why a second backend in addition to the AUHAL one in CoreAudioIO.swift?
//  -----------------------------------------------------------------------
//  Setting `kAudioUnitSubType_VoiceProcessingIO` directly on a raw AUHAL
//  fails on Bluetooth devices (AirPods, BT headsets) because VPIO needs to
//  internally create an aggregate device that pairs the BT mic + speaker
//  and renegotiate the BT link's audio mode (HFP/SCO ↔ A2DP). AUHAL has no
//  hook for that mode-switch — it just gets `error -10875` (`who?`).
//
//  `AVAudioEngine`, in contrast, hides the aggregate-device + mode-switch
//  dance behind `inputNode.setVoiceProcessingEnabled(true)`. The system
//  takes care of putting the BT device into HFP for the duration of the
//  call and restoring it afterwards. This is the approach Apple recommends
//  (and uses in WWDC sample code) for any voice-call use case on macOS.
//
//  Public surface mirrors the relevant subset of `CoreAudioInput` so it can
//  be plugged in as an alternative backend without touching callers.
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import AudioUnit
import AudioCore

final class VPIOEngineInput {

    // ---- Public surface (mirrors CoreAudioInput) ----------------------------

    var onSamples: ((UnsafePointer<Float>, Int) -> Void)?
    var onRestart: (() -> Void)?

    let inputGainProcessor: GainProcessor
    let inputMeter: LevelMeter

    /// "" / "Default" → system default input.
    var deviceUID: String = "Default"
    /// Output (speaker) UID. "" / "Default" → system default output.
    /// For Bluetooth devices this MUST point at the same physical device as
    /// `deviceUID` (e.g. both "AirPods Pro") — VPIO's internal aggregate
    /// can only do echo cancellation when input + output share a clock.
    var outputDeviceUID: String = "Default"

    /// Set BEFORE start(); applied to the engine's input AU at start time.
    var enableAGC: Bool = true
    /// Set BEFORE start(); applied to the engine's input AU at start time.
    var bypassNoiseSuppressionAndAEC: Bool = false

    // ---- Playback (downlink) — VPIO owns both directions of the BT device,
    //      so far-end audio MUST flow through this same engine. ---------------

    /// Linear gain applied to playback samples.
    var outputGain: Float = 1.0
    /// Smoothed meter for what the speaker actually hears (post-gain).
    /// Injected by the owner so existing UI bindings (e.g.
    /// `io.output.outputMeter`) keep ticking when the engine path is active.
    var outputMeter: LevelMeter = LevelMeter()
    /// 1 second @ 48 kHz mono — same capacity as CoreAudioOutput's ring.
    let outputRing = FloatRingBuffer(capacity: 48_000)

    private(set) var isRunning: Bool = false

    // ---- Internals ----------------------------------------------------------

    /// We rebuild the engine on every start() so a re-route fully resets state.
    private var engine: AVAudioEngine?
    /// Device-rate → 48 kHz mono Float32 converter (when needed).
    private var converter: AVAudioConverter?
    /// Reusable destination buffer for converted PCM (resized as needed).
    private var convDst: AVAudioPCMBuffer?
    /// Source node feeding the engine's mainMixer → outputNode (VPIO downlink).
    private var srcNode: AVAudioSourceNode?
    private let outFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!

    init(gain: GainProcessor, meter: LevelMeter) {
        self.inputGainProcessor = gain
        self.inputMeter = meter
    }

    // MARK: - Lifecycle

    func start() throws {
        stop()

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let outputNode = eng.outputNode

        // 1) Resolve the input device up front (always — even "Default" —
        //    so we can pin BOTH ends of VPIO to the same HAL device id).
        //    VPIO will not start a Bluetooth HFP session unless inputNode AND
        //    outputNode are bound to matching device ids.
        let resolvedInputID  = resolveInputDeviceID(uid: deviceUID)
        let resolvedOutputID = resolveOutputDeviceID(uid: outputDeviceUID)

        // 2) Bind the device on the input AU. On macOS we MUST use the
        //    AUAudioUnit.deviceID property — the AVAudioEngine I/O unit is an
        //    aggregate node that rejects raw AudioUnitSetProperty writes.
        //    Some devices (e.g. AirPods) expose split input-only/output-only
        //    HAL handles that fail this bind with -10851 because the AU
        //    requires a duplex device. We trust the system default in that
        //    case — VPIO is intentionally NOT used on BT (see
        //    AudioDeviceTransport.recommendVoiceProcessing).
        if let dev = resolvedInputID {
            do {
                try inputNode.auAudioUnit.setDeviceID(dev)
            } catch {
                // Non-fatal: fall back to system-default routing.
            }
        }

        // 3) Bind the SAME (or paired) device on the output AU.
        if let dev = resolvedOutputID {
            do {
                try outputNode.auAudioUnit.setDeviceID(dev)
            } catch {
                // Non-fatal: fall back to system-default routing.
            }
        }

        // 4) Enable voice processing. This is what triggers the BT HFP
        //    mode-switch under the hood (provided steps 2+3 ran first).
        try inputNode.setVoiceProcessingEnabled(true)

        // 5) Determine the input node's post-VP format and the output node's
        //    expected format. NOTE: outFormat varies by device — e.g. 24 kHz
        //    mono on AirPods HFP.
        let inFormat  = inputNode.outputFormat(forBus: 0)
        let outNodeFmt = outputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, outNodeFmt.sampleRate > 0 else {
            print("[VPIOEng] zero sample rate (in=\(inFormat.sampleRate), out=\(outNodeFmt.sampleRate)); aborting")
            return
        }

        // Build a converter only when the formats actually differ.
        if inFormat.sampleRate != outFormat.sampleRate ||
           inFormat.channelCount != outFormat.channelCount {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
        } else {
            converter = nil
        }

        // Install the tap. Buffer size 1024 ≈ 21 ms @ 48k — close enough to a
        // 20 ms Opus frame to avoid pathological re-buffering downstream.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in
            self?.handleBuffer(buf)
        }

        // ---- Wire up downlink (playback) so VPIO has a far-end reference ---
        // VPIO is a DUPLEX audio unit: its outputNode (speaker) MUST run at
        // exactly the same format as its inputNode (mic) — otherwise
        // AudioUnitInitialize fails with -10875 ("client-side input and
        // output formats do not match"). For AirPods on HFP this means
        // 24 kHz mono on BOTH sides, even though our app pipeline is 48 kHz.
        //
        // We therefore force the mainMixer→outputNode link to `inFormat`,
        // and let mainMixer resample our 48 kHz mono source down to it.
        let src = AVAudioSourceNode(format: outFormat) { [weak self] _, _, frames, ablPtr in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let ab = abl.first,
                  let dst = ab.mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let n = Int(frames)
            self.outputRing.read(into: dst, count: n)
            let g = self.outputGain
            if g != 1.0 {
                for i in 0..<n { dst[i] *= g }
            }
            self.outputMeter.observe(dst, count: n)
            return noErr
        }
        eng.attach(src)
        // Touching `mainMixerNode` triggers an implicit auto-connect from
        // mainMixer → outputNode using outputNode's *current* format, which
        // for VPIO defaults to 44.1 kHz stereo and trips the -10875 mismatch
        // check. Disconnect that and re-connect explicitly at outputNode's
        // actual (negotiated) duplex format.
        let mixer = eng.mainMixerNode
        eng.disconnectNodeOutput(mixer)
        eng.connect(mixer, to: outputNode, format: outNodeFmt)
        eng.connect(src, to: mixer, format: outFormat)
        srcNode = src

        eng.prepare()
        try eng.start()
        engine = eng
        isRunning = true

        // NOW the AU is initialized — it's safe to write VPIO sub-properties.
        // Doing this before initialize gave kAudioUnitErr_InvalidParameter
        // (err 1718449215 = 'kerr').
        applyVPIOSubProperties()

        // Listen for default-input changes so we can re-route when the user
        // unplugs/swaps a device while connected.
        addDefaultInputListener()

        print("[VPIOEng] Started — in=\(Int(inFormat.sampleRate))Hz/\(inFormat.channelCount)ch out=\(Int(outNodeFmt.sampleRate))Hz/\(outNodeFmt.channelCount)ch (vp=on)")
    }

    func stop() {
        removeDefaultInputListener()
        if let eng = engine {
            if eng.isRunning {
                eng.inputNode.removeTap(onBus: 0)
                eng.stop()
            }
            if let s = srcNode {
                eng.detach(s)
            }
            // Gracefully tear down voice processing; if the engine is already
            // disposed this throws, which we ignore.
            try? eng.inputNode.setVoiceProcessingEnabled(false)
            engine = nil
        }
        srcNode = nil
        converter = nil
        convDst = nil
        outputRing.clear()
        isRunning = false
    }

    /// Submit decoded mono Float32 PCM @ 48 kHz for playback through the
    /// engine's outputNode (i.e. through VPIO's downlink).
    func enqueuePlayback(_ samples: UnsafePointer<Float>, count: Int) {
        outputRing.write(samples, count: count)
    }

    // Set after start() with no effect — VPIO sub-properties currently
    // require a stop()/start(). We expose this for consistency with
    // CoreAudioInput; callers should set the flags before start().
    func applyVPIOSubProperties() {
        guard let au = engine?.inputNode.audioUnit else { return }
        var agc: UInt32 = enableAGC ? 1 : 0
        AudioUnitSetProperty(au, kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                             kAudioUnitScope_Global, 0,
                             &agc, UInt32(MemoryLayout<UInt32>.size))
        var bypass: UInt32 = bypassNoiseSuppressionAndAEC ? 1 : 0
        AudioUnitSetProperty(au, kAUVoiceIOProperty_BypassVoiceProcessing,
                             kAudioUnitScope_Global, 0,
                             &bypass, UInt32(MemoryLayout<UInt32>.size))
    }

    // MARK: - Tap

    private func handleBuffer(_ buf: AVAudioPCMBuffer) {
        // Fast path: already 48 kHz mono Float32 — apply gain & forward.
        if converter == nil, let ptr = buf.floatChannelData?[0] {
            let n = Int(buf.frameLength)
            inputGainProcessor.applyInPlace(ptr, count: n)
            inputMeter.observe(ptr, count: n)
            onSamples?(ptr, n)
            return
        }

        // Slow path: rate / channel-count conversion.
        guard let conv = converter else { return }

        // Estimate frames needed in the destination buffer (with margin).
        let outRate = outFormat.sampleRate
        let inRate  = buf.format.sampleRate
        let outFrames = AVAudioFrameCount(Double(buf.frameLength) * outRate / inRate + 256)

        // Reuse the destination buffer when possible.
        if convDst == nil || convDst!.frameCapacity < outFrames {
            convDst = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames)
        }
        guard let dst = convDst else { return }
        dst.frameLength = 0

        var nsErr: NSError?
        var fed = false
        let status = conv.convert(to: dst, error: &nsErr) { _, ioStatus in
            if fed { ioStatus.pointee = .endOfStream; return nil }
            fed = true
            ioStatus.pointee = .haveData
            return buf
        }
        if status == .error {
            if let nsErr { print("[VPIOEng] convert error: \(nsErr)") }
            return
        }
        guard let ptr = dst.floatChannelData?[0], dst.frameLength > 0 else { return }
        let n = Int(dst.frameLength)
        inputGainProcessor.applyInPlace(ptr, count: n)
        inputMeter.observe(ptr, count: n)
        onSamples?(ptr, n)
    }

    // MARK: - Hot-swap (default input device changed)

    private static let defaultInputAddr: AudioObjectPropertyAddress = {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
    }()

    private func addDefaultInputListener() {
        var addr = Self.defaultInputAddr
        AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                       &addr,
                                       vpioInputDefaultDeviceChanged,
                                       Unmanaged.passUnretained(self).toOpaque())
    }

    private func removeDefaultInputListener() {
        var addr = Self.defaultInputAddr
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                          &addr,
                                          vpioInputDefaultDeviceChanged,
                                          Unmanaged.passUnretained(self).toOpaque())
    }

    fileprivate func handleDefaultInputChanged() {
        // Only restart for "Default" — explicit device pins survive route changes.
        guard deviceUID.isEmpty || deviceUID == "Default" else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            print("[VPIOEng] Default input changed — restarting")
            do {
                try self.start()
                self.onRestart?()
            } catch {
                print("[VPIOEng] restart failed: \(error)")
            }
        }
    }

    // MARK: - Helpers

    private func lookupDeviceID(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var devID = AudioDeviceID(0)
        var cfUID: CFString = uid as CFString
        var avt = AudioValueTranslation(
            mInputData:      withUnsafeMutablePointer(to: &cfUID) { UnsafeMutableRawPointer($0) },
            mInputDataSize:  UInt32(MemoryLayout<CFString>.size),
            mOutputData:     withUnsafeMutablePointer(to: &devID) { UnsafeMutableRawPointer($0) },
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let err = withUnsafeMutablePointer(to: &avt) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &addr, 0, nil, &size, $0)
        }
        return (err == noErr && devID != 0) ? devID : nil
    }

    /// Resolve an input device UID, treating "" / "Default" as the system
    /// default input. Returns nil only when both lookups fail.
    private func resolveInputDeviceID(uid: String) -> AudioDeviceID? {
        if !uid.isEmpty && uid != "Default" {
            if let id = lookupDeviceID(uid: uid) { return id }
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &devID)
        return (err == noErr && devID != 0) ? devID : nil
    }

    /// Resolve an output device UID, treating "" / "Default" as the system
    /// default output.
    private func resolveOutputDeviceID(uid: String) -> AudioDeviceID? {
        if !uid.isEmpty && uid != "Default" {
            if let id = lookupDeviceID(uid: uid) { return id }
        }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &devID)
        return (err == noErr && devID != 0) ? devID : nil
    }
}

// MARK: - C trampoline

private func vpioInputDefaultDeviceChanged(_ id: AudioObjectID,
                                           _ count: UInt32,
                                           _ addrs: UnsafePointer<AudioObjectPropertyAddress>,
                                           _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let user else { return noErr }
    let me = Unmanaged<VPIOEngineInput>.fromOpaque(user).takeUnretainedValue()
    me.handleDefaultInputChanged()
    return noErr
}
