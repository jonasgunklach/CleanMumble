//
//  AudioConfig.swift
//  AudioEngine
//
//  Desired engine state as a value. The controller diffs desired vs actual
//  and rebuilds only when a rebuild-class field changed; gains, mute, deafen
//  and VAD threshold apply live and are deliberately NOT in here.
//

public enum DeviceSelection: Equatable, Sendable {
    case systemDefault
    case pinned(uid: String)

    public init(uid: String) {
        self = (uid.isEmpty || uid == "Default") ? .systemDefault : .pinned(uid: uid)
    }
    public var uid: String? {
        if case .pinned(let uid) = self { return uid }
        return nil
    }
}

public enum ProcessingMode: String, Equatable, Sendable {
    /// Voice-processed duplex I/O (AEC + NS + AGC via VPIO). The default for
    /// every conversational device INCLUDING Bluetooth — it is what unlocks
    /// Apple's high-bandwidth AirPods voice path.
    case voice
    /// Raw AUHAL, no processing — studio interfaces / user opt-out.
    case raw
    /// Pick per device transport (aggregate/virtual → raw, everything else
    /// → voice).
    case auto
}

public struct AudioConfig: Equatable, Sendable {
    public var input: DeviceSelection = .systemDefault
    public var output: DeviceSelection = .systemDefault
    public var processing: ProcessingMode = .auto
    public var agcEnabled: Bool = true
    public var capture = CaptureFormat()

    public init() {}
}
