//
//  AudioDeviceTransport.swift
//  CleanMumble
//
//  Helpers to inspect a CoreAudio device's transport (built-in / USB /
//  Bluetooth / aggregate) and to estimate the bandwidth class the system is
//  likely to negotiate with it. Used to:
//    1. Decide whether to enable VoiceProcessingIO automatically (smart
//       default: ON for built-in + Bluetooth mics, OFF for studio USB
//       interfaces and aggregate devices).
//    2. Surface a "high-quality voice (H2)" / "wideband" / "narrowband" badge
//       in the UI so the user can verify what they're getting.
//
//  AirPods H2 + macOS Sonoma+ negotiate a proprietary 48 kHz full-bandwidth
//  duplex codec (Apple "Wireless Voice Codec") — the headset stays in music
//  quality even while the mic is open. Older AirPods (W1/H1) still fall back
//  to mSBC 16 kHz wideband when the mic is opened, which is what causes the
//  classic "YouTube goes to AM radio when joining a Discord call" experience.
//

import Foundation
import CoreAudio
import AudioToolbox

enum AudioDeviceTransport: Equatable {
    case builtIn
    case usb
    case bluetooth          // Classic BR/EDR (HFP/A2DP/AAC + Apple voice codec)
    case bluetoothLE        // BLE Audio (LC3)
    case aggregate
    case virtual            // BlackHole, Loopback, etc.
    case airplay
    case unknown(UInt32)
}

enum NegotiatedVoiceMode: Equatable {
    case wired              // No bandwidth penalty — full 48 kHz both ways.
    case airPodsHighQuality // H2 + macOS 14+: 48 kHz duplex, no A2DP→SCO collapse.
    case airPodsWideband    // H1: 16 kHz mSBC duplex when mic open.
    case bluetoothNarrowband // 8 kHz CVSD (very old headsets).
    case bluetoothWideband  // 16 kHz mSBC (everyone else).
    case unknownBluetooth
}

struct AudioDeviceTransportInfo {
    let deviceID: AudioDeviceID
    let name: String
    let transport: AudioDeviceTransport
    /// Best guess at what the system will negotiate when we open the mic.
    let voiceMode: NegotiatedVoiceMode
    /// Convenience: the user is likely to benefit from VPIO (AEC + NS + AGC,
    /// and on H2 AirPods this also unlocks the high-quality 48 kHz duplex
    /// path because CoreAudio only enables it when a voice-comms client is
    /// active). False for studio interfaces where users want raw audio.
    let recommendVoiceProcessing: Bool

    static func query(_ deviceID: AudioDeviceID) -> AudioDeviceTransportInfo {
        let transport = readTransportType(deviceID)
        let name = readDeviceName(deviceID) ?? ""
        let voiceMode = inferVoiceMode(transport: transport, name: name)
        let recommend: Bool = {
            switch transport {
            // VPIO works reliably on built-in mics and most USB headsets.
            // It does NOT work on Bluetooth on macOS: AirPods (and other BT
            // headsets) expose split input-only/output-only HAL devices, so
            // setVoiceProcessingEnabled() can never bind a duplex device and
            // never negotiates the BT HFP link. The result is a 48 kHz / 3-ch
            // dummy stream with zero samples (and a separate AUHAL output
            // also fights for the BT stream). Skip VPIO entirely on BT and
            // rely on the device's own noise reduction (AirPods' on-device
            // NR is excellent and there's negligible acoustic feedback to
            // an in-ear mic anyway).
            case .builtIn:                              return true
            case .bluetooth, .bluetoothLE:              return false
            case .usb, .aggregate, .virtual, .airplay, .unknown:
                                                        return false
            }
        }()
        return AudioDeviceTransportInfo(
            deviceID: deviceID,
            name: name,
            transport: transport,
            voiceMode: voiceMode,
            recommendVoiceProcessing: recommend
        )
    }

    /// Human-readable badge ("High-quality voice (H2)" / "Wideband 16 kHz" / …)
    /// for the settings panel. nil for wired devices.
    var qualityBadge: String? {
        switch voiceMode {
        case .wired: return nil
        case .airPodsHighQuality: return "High-quality voice (48 kHz, AirPods H2)"
        case .airPodsWideband:    return "Wideband (16 kHz, AirPods H1) — output drops to 16 kHz when mic is open"
        case .bluetoothNarrowband:return "Narrowband (8 kHz)"
        case .bluetoothWideband:  return "Wideband (16 kHz) — output drops to 16 kHz when mic is open"
        case .unknownBluetooth:   return "Bluetooth (mode unknown)"
        }
    }
}

// MARK: - Device property reads

private func readTransportType(_ id: AudioDeviceID) -> AudioDeviceTransport {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    var raw: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &raw)
    guard err == noErr else { return .unknown(0) }
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn:    return .builtIn
    case kAudioDeviceTransportTypeUSB:        return .usb
    case kAudioDeviceTransportTypeBluetooth:  return .bluetooth
    case kAudioDeviceTransportTypeBluetoothLE:return .bluetoothLE
    case kAudioDeviceTransportTypeAggregate:  return .aggregate
    case kAudioDeviceTransportTypeVirtual:    return .virtual
    case kAudioDeviceTransportTypeAirPlay:    return .airplay
    default: return .unknown(raw)
    }
}

private func readDeviceName(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope:    kAudioObjectPropertyScopeGlobal,
        mElement:  kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let err = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
    guard err == noErr, let cf = name?.takeRetainedValue() else { return nil }
    return cf as String
}

/// Heuristic. CoreAudio doesn't expose the headset's chip / Bluetooth profile,
/// so we infer from the device name (which is the user-visible Bluetooth
/// device name) and the running macOS version.
private func inferVoiceMode(transport: AudioDeviceTransport, name: String) -> NegotiatedVoiceMode {
    switch transport {
    case .builtIn, .usb, .aggregate, .virtual, .airplay, .unknown: return .wired
    case .bluetooth, .bluetoothLE: break
    }
    let lower = name.lowercased()
    let isAirPods = lower.contains("airpod")
    if isAirPods {
        // H2 chip = AirPods Pro 2 (Sept 2022), AirPods 4 (Sept 2024),
        // AirPods Max (USB-C, Sept 2024). High-quality voice requires
        // macOS Sonoma 14+.
        let isH2 = lower.contains("pro") && (lower.contains("2") || lower.contains("3"))
                   || lower.contains("airpods 4")
                   || (lower.contains("max") && !lower.contains("(lightning)"))
        let macOS14 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        if isH2 && macOS14 { return .airPodsHighQuality }
        return .airPodsWideband
    }
    // Generic BT headset: assume mSBC wideband — it's been the floor since ~2018.
    return .bluetoothWideband
}
