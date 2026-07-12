//
//  DeviceManager.swift
//  AudioEngine
//
//  Single owner of every HAL notification the engine cares about. Registers
//  block-based listeners exactly once (registration lifetime == manager
//  lifetime, so the old "duplicate listeners leak on failed starts" bug is
//  structurally impossible) and reduces the HAL's notification zoo to one
//  event: `onInvalidated(reason)` delivered on the supplied queue.
//
//  The controller decides what to do; listeners never restart anything.
//

#if os(macOS)

import Foundation
import CoreAudio

public enum InvalidationReason: String, Sendable {
    case defaultInputChanged
    case defaultOutputChanged
    case deviceListChanged
    case coreAudioServiceRestarted
    case ioStalled
    case startFailed
    case configChanged
}

final class DeviceManager {

    /// Fires on `queue` for every relevant hardware event.
    var onInvalidated: ((InvalidationReason) -> Void)?

    private let queue: DispatchQueue
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(queue: DispatchQueue) {
        self.queue = queue
        register(selector: kAudioHardwarePropertyDefaultInputDevice, reason: .defaultInputChanged)
        register(selector: kAudioHardwarePropertyDefaultOutputDevice, reason: .defaultOutputChanged)
        register(selector: kAudioHardwarePropertyDevices, reason: .deviceListChanged)
        register(selector: kAudioHardwarePropertyServiceRestarted, reason: .coreAudioServiceRestarted)
    }

    deinit {
        for (addr, block) in registrations {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &a, queue, block)
        }
    }

    private func register(selector: AudioObjectPropertySelector, reason: InvalidationReason) {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onInvalidated?(reason)
        }
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        if err == noErr {
            registrations.append((addr, block))
        }
    }
}

#endif
