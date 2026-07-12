//
//  IOBackend.swift
//  AudioEngine
//
//  Backends are dumb: they open one duplex route, wire the capture ring and
//  the playback pull, and report errors by throwing. They register no
//  listeners, retry nothing, restart nothing — all policy lives in the
//  EngineController.
//

#if os(macOS)

import CoreAudio

public enum BackendKind: String, Sendable {
    case voice   // AVAudioEngine + VPIO (AEC/NS/AGC, duplex, Bluetooth-capable)
    case raw     // AUHAL pair, untouched audio (studio mode)
}

public struct ResolvedRoute: Sendable {
    public let inputID: AudioDeviceID
    public let outputID: AudioDeviceID
    public let inputInfo: DeviceInfo
    public let outputInfo: DeviceInfo
    public let backend: BackendKind
    /// Whether the user explicitly pinned each side. When following the
    /// system default, the voice backend must NOT pin node device IDs —
    /// VPIO negotiates split Bluetooth devices (AirPods) itself, and a
    /// manual bind can wedge its aggregate ("Timeout waiting for streams").
    public let inputPinned: Bool
    public let outputPinned: Bool
}

public struct BackendError: Error, CustomStringConvertible {
    public let stage: String
    public let status: Int32
    public var description: String { "\(stage) failed (\(status))" }
    init(_ stage: String, _ status: Int32 = 0) {
        self.stage = stage
        self.status = status
    }
}

protocol IOBackend: AnyObject {
    /// Open the route and begin flowing audio. Must call
    /// `capture.start(sourceRate:format:)` with the negotiated input rate
    /// before installing its tap/callback.
    func start(route: ResolvedRoute,
               capture: CaptureEngine,
               captureFormat: CaptureFormat,
               playback: PlaybackEngine,
               agcEnabled: Bool) throws

    func stop()
}

/// Pure routing decision: which devices, which backend.
enum RoutePolicy {

    /// `forceRaw` is the controller's stall-fallback tier: when the voice
    /// backend repeatedly starts but never streams, we demote the route to
    /// raw AUHAL until the devices or config actually change.
    static func resolve(config: AudioConfig, forceRaw: Bool = false) throws -> ResolvedRoute {
        guard let inID = DeviceQuery.resolve(config.input, input: true) else {
            throw BackendError("resolve input device")
        }
        guard let outID = DeviceQuery.resolve(config.output, input: false) else {
            throw BackendError("resolve output device")
        }
        let inInfo = DeviceQuery.info(for: inID)
        let outInfo = DeviceQuery.info(for: outID)

        let backend: BackendKind
        if forceRaw {
            backend = .raw
        } else {
            switch config.processing {
            case .voice: backend = .voice
            case .raw:   backend = .raw
            case .auto:
                switch inInfo.transport {
                case .builtIn, .bluetooth, .bluetoothLE, .usb:
                    // Voice processing by default — including Bluetooth: VPIO
                    // is what negotiates Apple's high-bandwidth AirPods link.
                    backend = .voice
                case .aggregate, .virtualDevice, .airplay, .unknown:
                    backend = .raw
                }
            }
        }
        return ResolvedRoute(inputID: inID, outputID: outID,
                             inputInfo: inInfo, outputInfo: outInfo,
                             backend: backend,
                             inputPinned: config.input != .systemDefault,
                             outputPinned: config.output != .systemDefault)
    }
}

#endif
