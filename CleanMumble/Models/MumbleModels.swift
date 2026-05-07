//
//  MumbleModels.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import Foundation
import SwiftUI

// MARK: - Connection State
enum ConnectionState: String, CaseIterable {
    case disconnected = "Disconnected"
    case connecting = "Connecting"
    case connected = "Connected"
    case reconnecting = "Reconnecting"
    
    var color: Color {
        switch self {
        case .disconnected: return .secondary
        case .connecting, .reconnecting: return .orange
        case .connected: return .green
        }
    }
    
    var icon: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting, .reconnecting: return "wifi.exclamationmark"
        case .connected: return "wifi"
        }
    }
}

// MARK: - Audio Quality Preset
enum AudioQuality: String, Codable, CaseIterable, Identifiable {
    case dataSaver = "dataSaver"
    case normal    = "normal"
    case crisp     = "crisp"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dataSaver: return "Data Saver"
        case .normal:    return "Normal"
        case .crisp:     return "Crisp"
        }
    }

    /// Estimated outgoing data while speaking continuously for one hour.
    /// Incoming audio (from others) is ~7 MB/hr per speaker at Data Saver,
    /// ~18 MB/hr at Normal, ~43 MB/hr at Crisp — depends on their setting.
    var sendingDataPerHour: String {
        switch self {
        case .dataSaver: return "~7 MB/hr"
        case .normal:    return "~18 MB/hr"
        case .crisp:     return "~43 MB/hr"
        }
    }

    /// Incoming data per active speaker (at their chosen quality).
    var receivingDataPerSpeakerPerHour: String {
        switch self {
        case .dataSaver: return "~7 MB/hr"
        case .normal:    return "~18 MB/hr"
        case .crisp:     return "~43 MB/hr"
        }
    }

    // Underlying Opus parameters
    //   - Normal sits at 64 kbps to match the official Mumble client's
    //     default range (60-72 kbps). At 40 kbps Opus VOIP is audibly
    //     more compressed on consonants/sibilants.
    //   - Crisp stays at 96 kbps but uses 20 ms frames + the standard VOIP
    //     application (NOT restricted-low-delay). The low-delay mode
    //     disables Opus's SILK speech layer, which makes voice sound worse
    //     per kbps. 20 ms gives Opus the most coding efficiency.
    var bitrate: Int  { switch self { case .dataSaver: return 16_000
                                      case .normal:    return 64_000
                                      case .crisp:     return 96_000 } }
    var frameMs: Int  { switch self { case .dataSaver: return 40
                                      case .normal:    return 20
                                      case .crisp:     return 20 } }
    var lowDelay: Bool { false }
}

// MARK: - Audio Settings

/// User-facing tri-state choice for the VoiceProcessingIO unit. `.auto` (the
/// recommended default) lets the audio engine decide based on the resolved
/// input device's transport type — ON for built-in mic + Bluetooth headsets
/// (incl. AirPods), OFF for studio USB interfaces and aggregate devices.
enum VoiceProcessingChoice: String, Codable, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto (recommended)"
        case .on:   return "Always on"
        case .off:  return "Off"
        }
    }
    /// Bridge to the CoreAudio layer's tri-state so callers don't have to
    /// import CoreAudio just to map the enum.
    var toCAInputMode: CoreAudioInput.VoiceProcessingMode {
        switch self {
        case .auto: return .auto
        case .on:   return .on
        case .off:  return .off
        }
    }
}

struct AudioSettings: Codable {
    var inputVolume: Float = 1.0
    var outputVolume: Float = 1.0
    var inputDevice: String = "Default"
    var outputDevice: String = "Default"
    var enableEchoCancellation: Bool = true
    var enableNoiseSuppression: Bool = true
    var enableAutomaticGainControl: Bool = true
    var voiceActivityDetection: Bool = true
    var voiceActivityThreshold: Float = 0.5
    var voiceActivityDelay: Float = 0.5
    var quality: AudioQuality = .normal
    /// Tri-state: auto (default) / on / off. See `VoiceProcessingChoice`.
    /// Migrated from the old Bool field; old saved Bool=false maps to .auto so
    /// existing users get the new smart-default behaviour automatically.
    var voiceProcessing: VoiceProcessingChoice = .auto

    /// Back-compat shim for older code paths still reading a Bool. Returns
    /// true for both `.auto` and `.on` (the auto path will further refine).
    var useVoiceProcessing: Bool {
        get { voiceProcessing != .off }
        set { voiceProcessing = newValue ? .on : .off }
    }

    init() {}

    /// Custom decoder so previously-serialized settings (without newly-added
    /// fields like `useVoiceProcessing`) still decode cleanly with defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputVolume = try c.decodeIfPresent(Float.self, forKey: .inputVolume) ?? 1.0
        self.outputVolume = try c.decodeIfPresent(Float.self, forKey: .outputVolume) ?? 1.0
        self.inputDevice = try c.decodeIfPresent(String.self, forKey: .inputDevice) ?? "Default"
        self.outputDevice = try c.decodeIfPresent(String.self, forKey: .outputDevice) ?? "Default"
        self.enableEchoCancellation = try c.decodeIfPresent(Bool.self, forKey: .enableEchoCancellation) ?? true
        self.enableNoiseSuppression = try c.decodeIfPresent(Bool.self, forKey: .enableNoiseSuppression) ?? true
        self.enableAutomaticGainControl = try c.decodeIfPresent(Bool.self, forKey: .enableAutomaticGainControl) ?? true
        self.voiceActivityDetection = try c.decodeIfPresent(Bool.self, forKey: .voiceActivityDetection) ?? true
        self.voiceActivityThreshold = try c.decodeIfPresent(Float.self, forKey: .voiceActivityThreshold) ?? 0.5
        self.voiceActivityDelay = try c.decodeIfPresent(Float.self, forKey: .voiceActivityDelay) ?? 0.5
        self.quality = try c.decodeIfPresent(AudioQuality.self, forKey: .quality) ?? .normal
        // New tri-state field; if not present, fall through to auto.
        if let choice = try c.decodeIfPresent(VoiceProcessingChoice.self, forKey: .voiceProcessing) {
            self.voiceProcessing = choice
        } else {
            self.voiceProcessing = .auto
        }
    }
}

// MARK: - User Preferences
struct UserPreferences: Codable {
    var theme: AppTheme = .system
    var showNotifications: Bool = true
    var minimizeToTray: Bool = true
    var startWithSystem: Bool = false
    var audioSettings: AudioSettings = AudioSettings()
}

// MARK: - App Theme
enum AppTheme: String, CaseIterable, Codable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"
    
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - Server Connection Info
struct ServerConnectionInfo: Identifiable, Codable {
    let id = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    var password: String
    var isFavorite: Bool = false
    var lastConnected: Date?
    
    init(name: String, host: String, port: Int = 64738, username: String = "", password: String = "", isFavorite: Bool = false) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.isFavorite = isFavorite
    }
}

// MARK: - Server Info
struct ServerInfo: Identifiable, Codable {
    let id = UUID()
    var name: String
    var version: String
    var release: String
    var os: String
    var osVersion: String
    var welcomeText: String
    var maxBandwidth: Int
    var currentUsers: Int = 0
    var maxUsers: Int = 0
    
    init(name: String, version: String, release: String, os: String, osVersion: String, welcomeText: String, maxBandwidth: Int) {
        self.name = name
        self.version = version
        self.release = release
        self.os = os
        self.osVersion = osVersion
        self.welcomeText = welcomeText
        self.maxBandwidth = maxBandwidth
    }
}

// MARK: - Channel Info
struct ChannelInfo: Identifiable, Codable {
    let id = UUID()
    var channelId: Int32
    var name: String
    var description: String?
    var isTemporary: Bool = false
    var parentChannelId: Int32?
    var userCount: Int = 0
    
    init(channelId: Int32, name: String, description: String? = nil, isTemporary: Bool = false, parentChannelId: Int32? = nil) {
        self.channelId = channelId
        self.name = name
        self.description = description
        self.isTemporary = isTemporary
        self.parentChannelId = parentChannelId
    }
}

// MARK: - User Info
struct UserInfo: Identifiable, Codable {
    let id = UUID()
    var userId: Int32
    var name: String
    var isMuted: Bool = false
    var isDeafened: Bool = false
    var isSelfMuted: Bool = false
    var isSelfDeafened: Bool = false
    var isSuppressed: Bool = false
    var isSpeaking: Bool = false
    var isPrioritySpeaker: Bool = false
    var isRecording: Bool = false
    var comment: String?
    var currentChannelId: Int32?
    var avatar: Data?
    
    init(userId: Int32, name: String, isMuted: Bool = false, isDeafened: Bool = false) {
        self.userId = userId
        self.name = name
        self.isMuted = isMuted
        self.isDeafened = isDeafened
    }
    
    var displayName: String {
        if isMuted || isSelfMuted {
            return "🔇 \(name)"
        }
        if isSpeaking {
            return "🎤 \(name)"
        }
        if isRecording {
            return "🔴 \(name)"
        }
        return name
    }
    
    var statusColor: Color {
        if isMuted || isSelfMuted {
            return .red
        }
        if isSpeaking {
            return .green
        }
        if isRecording {
            return .orange
        }
        return .primary
    }
}
