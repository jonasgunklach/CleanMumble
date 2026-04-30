//
//  IOSAudioSession.swift
//  CleanMumble
//
//  iOS-only audio session manager. Fixes the "Mumble interrupts other apps'
//  audio at launch / steals routing / can't recover from a phone call"
//  family of bugs by:
//
//  1. NOT activating the audio session at app launch — only when the user
//     actually connects to a server. App can sit in the background or open
//     other apps while idle without disturbing them.
//  2. Using `.voiceChat` mode + `.allowBluetoothA2DP` so AirPods stay in
//     hands-free profile, not the awful 8 kHz HFP fallback.
//  3. Observing `AVAudioSession.interruptionNotification` so a phone call,
//     Siri, or another app grabbing the session cleanly stops the audio
//     engine and restarts it after.
//  4. Observing `routeChangeNotification` so unplugging headphones / pairing
//     AirPods triggers a clean stop / restart instead of audio cutting out.
//

import Foundation

#if os(iOS)
import AVFoundation

@MainActor
final class IOSAudioSession {
    static let shared = IOSAudioSession()

    /// Called when the system interrupts us (phone call etc.). Caller should
    /// stop the audio engine. The bool is `true` for began, `false` for ended
    /// (with `shouldResume` already evaluated; you can resume).
    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?
    /// Called when the route changes (headphones plugged/unplugged etc.).
    var onRouteChange: (() -> Void)?

    private(set) var isActive = false
    private var registered = false

    func activateForVoiceChat() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .voiceChat tells iOS this is a real-time conversation: enables
            // echo cancellation, prefers a low-latency I/O buffer, ducks music
            // during speech rather than killing it. .allowBluetoothA2DP is
            // critical for AirPods quality (HFP is 8 kHz mono and sounds awful).
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            isActive = true
            registerObservers()
            print("[AudioSession] Activated for voice chat")
        } catch {
            print("[AudioSession] Activation failed: \(error)")
        }
    }

    func deactivate() {
        guard isActive else { return }
        do {
            // .notifyOthersOnDeactivation tells music apps "you can take over now".
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
            isActive = false
            print("[AudioSession] Deactivated")
        } catch {
            print("[AudioSession] Deactivation failed: \(error)")
        }
    }

    private func registerObservers() {
        guard !registered else { return }
        registered = true
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification,
                       object: nil)
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }
        switch type {
        case .began:
            print("[AudioSession] Interruption began")
            onInterruption?(true, false)
        case .ended:
            var shouldResume = false
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                shouldResume = opts.contains(.shouldResume)
            }
            print("[AudioSession] Interruption ended (shouldResume=\(shouldResume))")
            onInterruption?(false, shouldResume)
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)
        else { return }
        // Filter to the ones that actually need a graph rebuild.
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .categoryChange:
            print("[AudioSession] Route change: \(reason)")
            onRouteChange?()
        default:
            break
        }
    }
}
#endif
