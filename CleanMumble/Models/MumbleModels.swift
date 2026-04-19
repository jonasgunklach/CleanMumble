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
    var bitrate: Int  { switch self { case .dataSaver: return 16_000
                                      case .normal:    return 40_000
                                      case .crisp:     return 96_000 } }
    var frameMs: Int  { switch self { case .dataSaver: return 40
                                      case .normal:    return 20
                                      case .crisp:     return 10 } }
    var lowDelay: Bool { self == .crisp }
}

// MARK: - Audio Settings
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
