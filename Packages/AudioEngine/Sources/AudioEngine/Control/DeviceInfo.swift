//
//  DeviceInfo.swift
//  AudioEngine
//
//  CoreAudio HAL device queries: UID ↔ AudioDeviceID resolution, transport
//  type, and the Bluetooth voice-quality inference that drives the UI badge.
//  (Successor of the app's AudioDeviceTransport.swift, with the Bluetooth
//  policy REVERSED: voice processing is now recommended on Bluetooth — it is
//  what engages Apple's high-bandwidth AirPods voice path; see
//  audio-engine.md §3.1.)
//

#if os(macOS)

import Foundation
import CoreAudio
import AudioToolbox

public enum AudioTransport: Equatable, Sendable {
    case builtIn
    case usb
    case bluetooth
    case bluetoothLE
    case aggregate
    case virtualDevice
    case airplay
    case unknown(UInt32)
}

public enum VoiceQualityClass: Equatable, Sendable {
    case wired                    // no bandwidth penalty
    case airPodsStudio            // H2-family chip: 48 kHz studio voice path
    case airPodsWideband          // W1/H1 AirPods: link degrades with mic open
    case bluetoothWideband        // generic headset, 16 kHz mSBC
    case unknownBluetooth
}

public struct DeviceInfo: Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transport: AudioTransport
    public let voiceQuality: VoiceQualityClass
    /// Positively identified AirPods model (via the Bluetooth PnP record),
    /// nil for non-AirPods devices or when identification was unavailable.
    public let airPodsModel: String?

    /// Human-readable quality badge for the settings UI. nil for wired.
    public var qualityBadge: String? {
        let model = airPodsModel.map { "\($0): " } ?? ""
        switch voiceQuality {
        case .wired: return nil
        case .airPodsStudio:
            return "\(model)Studio-quality voice (48 kHz)"
        case .airPodsWideband:
            return "\(model)Limited voice bandwidth (W1/H1 chip)"
        case .bluetoothWideband:
            return "Wideband (16 kHz) — output drops while mic is open"
        case .unknownBluetooth:
            return "Bluetooth (mode unknown)"
        }
    }
}

public enum DeviceQuery {

    public static func defaultDeviceID(input: Bool) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                             : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size, &devID)
        return (err == noErr && devID != 0) ? devID : nil
    }

    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var devID = AudioDeviceID(0)
        var cfUID: CFString = uid as CFString
        var avt = AudioValueTranslation(
            mInputData: withUnsafeMutablePointer(to: &cfUID) { UnsafeMutableRawPointer($0) },
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: withUnsafeMutablePointer(to: &devID) { UnsafeMutableRawPointer($0) },
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let err = withUnsafeMutablePointer(to: &avt) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &addr, 0, nil, &size, $0)
        }
        return (err == noErr && devID != 0) ? devID : nil
    }

    /// Resolve a selection to a live device, falling back to system default.
    public static func resolve(_ selection: DeviceSelection, input: Bool) -> AudioDeviceID? {
        if let uid = selection.uid, let id = deviceID(forUID: uid) {
            return id
        }
        return defaultDeviceID(input: input)
    }

    public static func info(for id: AudioDeviceID) -> DeviceInfo {
        let name = readString(id, selector: kAudioObjectPropertyName) ?? ""
        let uid = readString(id, selector: kAudioDevicePropertyDeviceUID) ?? ""
        let transport = readTransport(id)

        // For Bluetooth devices, identify the model positively via the
        // paired device's PnP record; fall back to the name heuristic.
        var model: AirPodsModelInfo?
        if transport == .bluetooth || transport == .bluetoothLE {
            model = AirPodsIdentifier.identify(bluetoothDeviceNamed: name)
        }
        return DeviceInfo(id: id, uid: uid, name: name, transport: transport,
                          voiceQuality: inferVoiceQuality(transport: transport,
                                                          name: name,
                                                          model: model),
                          airPodsModel: model?.modelName)
    }

    /// Nominal sample rate the hardware is currently running at.
    public static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return (err == noErr && rate > 0) ? rate : nil
    }

    // MARK: - Internals

    private static func readString(_ id: AudioDeviceID,
                                   selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        guard err == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func readTransport(_ id: AudioDeviceID) -> AudioTransport {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw) == noErr else {
            return .unknown(0)
        }
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn:     return .builtIn
        case kAudioDeviceTransportTypeUSB:         return .usb
        case kAudioDeviceTransportTypeBluetooth:   return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: return .bluetoothLE
        case kAudioDeviceTransportTypeAggregate:   return .aggregate
        case kAudioDeviceTransportTypeVirtual:     return .virtualDevice
        case kAudioDeviceTransportTypeAirPlay:     return .airplay
        default:                                   return .unknown(raw)
        }
    }

    /// The app requires macOS 26 (Tahoe), so the OS side of the studio voice
    /// path is a given — quality class depends only on the headset's chip.
    private static func inferVoiceQuality(transport: AudioTransport,
                                          name: String,
                                          model: AirPodsModelInfo?) -> VoiceQualityClass {
        switch transport {
        case .builtIn, .usb, .aggregate, .virtualDevice, .airplay, .unknown:
            return .wired
        case .bluetooth, .bluetoothLE:
            break
        }
        // Positive identification wins.
        if let model {
            return model.chip == .h2OrNewer ? .airPodsStudio : .airPodsWideband
        }
        // Name heuristic fallback (PnP record unavailable). Deliberately
        // conservative: an unadorned name like "Jonas's AirPods Pro" can't
        // reveal the generation, so claim only what the name proves.
        let lower = name.lowercased()
        guard lower.contains("airpod") else { return .bluetoothWideband }
        let looksH2 = (lower.contains("pro") && (lower.contains("2") || lower.contains("3")))
            || lower.contains("airpods 4")
        return looksH2 ? .airPodsStudio : .airPodsWideband
    }
}

#endif
