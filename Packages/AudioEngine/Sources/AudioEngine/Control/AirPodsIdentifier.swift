//
//  AirPodsIdentifier.swift
//  AudioEngine
//
//  Positive AirPods model identification via the paired Bluetooth device's
//  PnP information (Device ID SDP record, attributes 0x0201 VendorID /
//  0x0202 ProductID) — the same identifiers `system_profiler
//  SPBluetoothDataType` shows. This replaces guessing the generation from
//  the user-visible device name, which fails the moment someone names their
//  headset "Jonas's AirPods Pro".
//
//  Requirements: the app must have the `com.apple.security.device.bluetooth`
//  sandbox entitlement and an `NSBluetoothAlwaysUsageDescription`. When the
//  lookup is unavailable (entitlement missing, TCC denied, unpaired device),
//  callers fall back to the name heuristic in DeviceInfo.
//
//  PID table sources: community-documented Apple Bluetooth PIDs
//  (theapplewiki.com/wiki/Bluetooth_PIDs). Entries marked [unverified] were
//  not confirmable at the time of writing — extend/correct as devices are
//  tested; unknown Apple audio PIDs degrade gracefully to the name check.
//

#if os(macOS)

import Foundation
import IOBluetooth

/// Which audio chip family the model carries — the H2 (and newer) family is
/// what qualifies for Apple's 48 kHz studio-quality voice path.
public enum AirPodsChipClass: Equatable, Sendable {
    case h1Family          // W1/H1: classic HFP collapse when the mic opens
    case h2OrNewer         // H2+: studio-quality voice on macOS 26
}

public struct AirPodsModelInfo: Equatable, Sendable {
    public let modelName: String
    public let chip: AirPodsChipClass
    public let productID: Int
}

public enum AirPodsIdentifier {

    private static let appleVendorID = 0x004C

    /// Bluetooth ProductID → model. Keep sorted; extend as new models ship.
    private static let models: [Int: (name: String, chip: AirPodsChipClass)] = [
        0x2002: ("AirPods (1st gen)", .h1Family),
        0x200F: ("AirPods (2nd gen)", .h1Family),
        0x2013: ("AirPods (3rd gen)", .h1Family),
        0x200E: ("AirPods Pro", .h1Family),
        0x200A: ("AirPods Max", .h1Family),
        0x201F: ("AirPods Max (USB-C)", .h1Family),          // [unverified]
        0x2014: ("AirPods Pro 2", .h2OrNewer),
        0x2024: ("AirPods Pro 2 (USB-C)", .h2OrNewer),
        0x2019: ("AirPods 4", .h2OrNewer),                    // [unverified]
        0x201B: ("AirPods 4 (ANC)", .h2OrNewer),              // [unverified]
        0x2027: ("AirPods Pro 3", .h2OrNewer),
    ]

    /// Pure classification — unit-testable without Bluetooth hardware.
    public static func classify(vendorID: Int, productID: Int) -> AirPodsModelInfo? {
        guard vendorID == appleVendorID else { return nil }
        guard let m = models[productID] else { return nil }
        return AirPodsModelInfo(modelName: m.name, chip: m.chip, productID: productID)
    }

    /// Find the paired Bluetooth device whose name matches the CoreAudio
    /// device name and read its PnP record. Returns nil when anything in the
    /// chain is unavailable — callers keep their heuristic fallback.
    public static func identify(bluetoothDeviceNamed deviceName: String) -> AirPodsModelInfo? {
        guard !deviceName.isEmpty,
              let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]
        else { return nil }

        for device in paired {
            guard let name = device.name, !name.isEmpty else { continue }
            // The HAL device name is normally the BT name verbatim; tolerate
            // suffixed variants on either side.
            guard deviceName == name
                    || deviceName.hasPrefix(name)
                    || name.hasPrefix(deviceName) else { continue }
            guard let records = device.services as? [IOBluetoothSDPServiceRecord] else { continue }
            for record in records {
                guard let vendorElem = record.getAttributeDataElement(0x0201),
                      let productElem = record.getAttributeDataElement(0x0202),
                      let vendor = vendorElem.getNumberValue()?.intValue,
                      let product = productElem.getNumberValue()?.intValue
                else { continue }
                if let info = classify(vendorID: vendor, productID: product) {
                    return info
                }
            }
        }
        return nil
    }
}

#endif
