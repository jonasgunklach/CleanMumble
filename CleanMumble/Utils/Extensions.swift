//
//  Extensions.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI
import Foundation
import CoreAudio

// MARK: - Color Extensions
extension Color {
    static let mumbleBlue = Color(red: 0.2, green: 0.6, blue: 1.0)
    static let mumbleGreen = Color(red: 0.2, green: 0.8, blue: 0.4)
    static let mumbleRed = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let mumbleOrange = Color(red: 1.0, green: 0.6, blue: 0.2)
}

// MARK: - View Extensions
extension View {
    func mumbleCard() -> some View {
        self
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    func mumbleButton() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
    }
    
    func mumbleSecondaryButton() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.2))
            .foregroundColor(.primary)
            .cornerRadius(8)
    }
}

// MARK: - String Extensions
extension String {
    func initials() -> String {
        let words = self.components(separatedBy: " ")
        let initials = words.compactMap { $0.first?.uppercased() }
        return initials.prefix(2).joined()
    }
    
    func isValidHost() -> Bool {
        let hostRegex = #"^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$"#
        return self.range(of: hostRegex, options: .regularExpression) != nil
    }

    /// Strip HTML tags and decode common HTML entities for display.
    var strippingHTML: String {
        // Use NSAttributedString to fully parse HTML (handles entities, nested tags, etc.)
        guard !self.isEmpty,
              let data = self.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue],
                  documentAttributes: nil)
        else {
            // Fallback: plain regex tag strip
            return self.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                       .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Escape HTML special characters so the string is safe inside an HTML element.
    var escapingHTML: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    
    func isValidPort() -> Bool {
        guard let port = Int(self) else { return false }
        return port > 0 && port <= 65535
    }
}

// MARK: - CoreAudio device enumeration

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID  // UInt32 device ID
    let uid: String
    let name: String
}

func listAudioDevices(input: Bool) -> [AudioDeviceInfo] {
    var propAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize
    ) == noErr, dataSize > 0 else { return [] }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &deviceIDs
    ) == noErr else { return [] }

    var result: [AudioDeviceInfo] = []
    for deviceID in deviceIDs {
        // Skip devices without streams in the requested scope
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &streamAddr, 0, nil, &streamSize)
        guard streamSize > 0 else { continue }

        guard let name = audioDeviceStringProp(deviceID, kAudioObjectPropertyName),
              let uid  = audioDeviceStringProp(deviceID, kAudioDevicePropertyDeviceUID)
        else { continue }

        result.append(AudioDeviceInfo(id: deviceID, uid: uid, name: name))
    }
    return result
}

private func audioDeviceStringProp(_ deviceID: AudioDeviceID,
                                   _ selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfStr: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &cfStr) {
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
    }
    guard status == noErr, let s = cfStr else { return nil }
    return s as String
}

// MARK: - Date Extensions
extension Date {
    func timeAgo() -> String {
        let now = Date()
        let timeInterval = now.timeIntervalSince(self)
        
        if timeInterval < 60 {
            return "Just now"
        } else if timeInterval < 3600 {
            let minutes = Int(timeInterval / 60)
            return "\(minutes)m ago"
        } else if timeInterval < 86400 {
            let hours = Int(timeInterval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(timeInterval / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - Notification Extensions
extension Notification.Name {
    static let mumbleConnected = Notification.Name("mumbleConnected")
    static let mumbleDisconnected = Notification.Name("mumbleDisconnected")
    static let mumbleUserJoined = Notification.Name("mumbleUserJoined")
    static let mumbleUserLeft = Notification.Name("mumbleUserLeft")
    static let mumbleChannelChanged = Notification.Name("mumbleChannelChanged")
    static let mumbleMessageReceived = Notification.Name("mumbleMessageReceived")
}

// MARK: - UserDefaults Extensions
extension UserDefaults {
    private enum Keys {
        static let servers = "SavedServers"
        static let preferences = "UserPreferences"
        static let lastConnectedServer = "LastConnectedServer"
        static let windowFrame = "WindowFrame"
    }
    
    func saveServers(_ servers: [ServerConnectionInfo]) {
        if let data = try? JSONEncoder().encode(servers) {
            set(data, forKey: Keys.servers)
        }
    }
    
    func loadServers() -> [ServerConnectionInfo] {
        guard let data = data(forKey: Keys.servers),
              let servers = try? JSONDecoder().decode([ServerConnectionInfo].self, from: data) else {
            return []
        }
        return servers
    }
    
    func savePreferences(_ preferences: UserPreferences) {
        if let data = try? JSONEncoder().encode(preferences) {
            set(data, forKey: Keys.preferences)
        }
    }
    
    func loadPreferences() -> UserPreferences? {
        guard let data = data(forKey: Keys.preferences),
              let preferences = try? JSONDecoder().decode(UserPreferences.self, from: data) else {
            return nil
        }
        return preferences
    }
}

// MARK: - Animation Extensions
extension Animation {
    static let mumbleSpring = Animation.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0)
    static let mumbleBounce = Animation.interpolatingSpring(stiffness: 300, damping: 20)
    static let mumbleEase = Animation.easeInOut(duration: 0.3)
}

// MARK: - Data Extensions for Protocol Buffers
extension Data {
    mutating func appendVarint(_ value: UInt32) {
        var val = value
        while val >= 0x80 {
            append(UInt8(val & 0xFF | 0x80))
            val >>= 7
        }
        append(UInt8(val & 0xFF))
    }
    
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: 4))
    }
    
    mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: 8))
    }
    
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return subdata(in: offset..<offset + 4).withUnsafeBytes { bytes in
            bytes.load(as: UInt32.self).bigEndian
        }
    }
    
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return subdata(in: offset..<offset + 2).withUnsafeBytes { bytes in
            bytes.load(as: UInt16.self).bigEndian
        }
    }
    
    func readUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return subdata(in: offset..<offset + 8).withUnsafeBytes { bytes in
            bytes.load(as: UInt64.self).bigEndian
        }
    }
}

// MARK: - Haptic Feedback
#if os(iOS)
import UIKit

extension UIImpactFeedbackGenerator {
    static func mumbleImpact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

extension UINotificationFeedbackGenerator {
    static func mumbleNotification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}
#endif
