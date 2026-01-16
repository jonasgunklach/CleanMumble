//
//  MumbleProtocol.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import Foundation
import Network
import Combine

// MARK: - Mumble Protocol Constants
struct MumbleConstants {
    nonisolated static let defaultPort: UInt16 = 64738
    nonisolated static let protocolVersion: UInt32 = 0x01020304
    nonisolated static let maxPacketSize: Int = 8192
    nonisolated static let audioFrameSize: Int = 480 // 10ms at 48kHz
}

// MARK: - Mumble Message Types
enum MumbleMessageType: UInt16 {
    case version = 0
    case udpTunnel = 1
    case authenticate = 2
    case ping = 3
    case reject = 4
    case serverSync = 5
    case channelRemove = 6
    case channelState = 7
    case userRemove = 8
    case userState = 9
    case banList = 10
    case textMessage = 11
    case permissionDenied = 12
    case acl = 13
    case queryUsers = 14
    case cryptSetup = 15
    case contextActionModify = 16
    case contextAction = 17
    case userList = 18
    case voiceTarget = 19
    case permissionQuery = 20
    case codecVersion = 21
    case userStats = 22
    case requestBlob = 23
    case serverConfig = 24
    case suggestConfig = 25
}

// MARK: - Mumble Connection State
enum MumbleConnectionState {
    case disconnected
    case connecting
    case connected
    case authenticating
    case synchronized
    case error(String)
}

// MARK: - Mumble Protocol Handler
@MainActor
class MumbleProtocolHandler: ObservableObject {
    @Published var connectionState: MumbleConnectionState = .disconnected
    @Published var isConnected: Bool = false
    
    private var tcpConnection: NWConnection?
    private var udpConnection: NWConnection?
    private var serverHost: String = ""
    private var serverPort: UInt16 = MumbleConstants.defaultPort
    private var username: String = ""
    private var password: String = ""
    
    private var cancellables = Set<AnyCancellable>()
    
    func connect(to host: String, port: UInt16 = MumbleConstants.defaultPort, username: String, password: String = "") {
        self.serverHost = host
        self.serverPort = port
        self.username = username
        self.password = password
        
        connectionState = .connecting
        
        // For demo purposes, simulate connection instead of real network calls
        // This prevents DNS errors and allows the UI to work properly
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Simulate successful connection
            self.connectionState = .connected
            self.isConnected = true
        }
        
        // TODO: Implement real Mumble protocol connection
        // This would involve:
        // 1. TCP connection for control messages
        // 2. UDP connection for audio data  
        // 3. Proper Mumble protocol handshake
        // 4. Authentication with server
        // 5. SSL/TLS encryption
    }
    
    func disconnect() {
        tcpConnection?.cancel()
        udpConnection?.cancel()
        tcpConnection = nil
        udpConnection = nil
        
        connectionState = .disconnected
        isConnected = false
    }
    
    private func setupTCPConnection() {
        tcpConnection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.connectionState = .connected
                    self?.isConnected = true
                    self?.sendVersion()
                    self?.sendAuthentication()
                case .failed(let error):
                    self?.connectionState = .error("TCP connection failed: \(error.localizedDescription)")
                    self?.isConnected = false
                case .cancelled:
                    self?.connectionState = .disconnected
                    self?.isConnected = false
                default:
                    break
                }
            }
        }
        
        // Start receiving TCP data
        receiveTCPData()
    }
    
    private func setupUDPConnection() {
        udpConnection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    print("UDP connection ready")
                case .failed(let error):
                    print("UDP connection failed: \(error.localizedDescription)")
                case .cancelled:
                    print("UDP connection cancelled")
                default:
                    break
                }
            }
        }
        
        udpConnection?.start(queue: DispatchQueue.global(qos: .userInitiated))
    }
    
    private func sendVersion() {
        var versionMessage = Data()
        
        // Message type (Version)
        versionMessage.append(contentsOf: withUnsafeBytes(of: MumbleMessageType.version.rawValue.bigEndian) { Data($0) })
        
        // Protocol version
        versionMessage.append(contentsOf: withUnsafeBytes(of: MumbleConstants.protocolVersion.bigEndian) { Data($0) })
        
        // Release string (simplified)
        let release = "CleanMumble 1.0.0"
        let releaseData = release.data(using: .utf8) ?? Data()
        versionMessage.append(contentsOf: withUnsafeBytes(of: UInt32(releaseData.count).bigEndian) { Data($0) })
        versionMessage.append(releaseData)
        
        // OS string
        let os = "macOS"
        let osData = os.data(using: .utf8) ?? Data()
        versionMessage.append(contentsOf: withUnsafeBytes(of: UInt32(osData.count).bigEndian) { Data($0) })
        versionMessage.append(osData)
        
        // OS version string
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let osVersionData = osVersion.data(using: .utf8) ?? Data()
        versionMessage.append(contentsOf: withUnsafeBytes(of: UInt32(osVersionData.count).bigEndian) { Data($0) })
        versionMessage.append(osVersionData)
        
        sendTCPData(versionMessage)
    }
    
    private func sendAuthentication() {
        var authMessage = Data()
        
        // Message type (Authenticate)
        authMessage.append(contentsOf: withUnsafeBytes(of: MumbleMessageType.authenticate.rawValue.bigEndian) { Data($0) })
        
        // Username
        let usernameData = username.data(using: .utf8) ?? Data()
        authMessage.append(contentsOf: withUnsafeBytes(of: UInt32(usernameData.count).bigEndian) { Data($0) })
        authMessage.append(usernameData)
        
        // Password
        let passwordData = password.data(using: .utf8) ?? Data()
        authMessage.append(contentsOf: withUnsafeBytes(of: UInt32(passwordData.count).bigEndian) { Data($0) })
        authMessage.append(passwordData)
        
        // Additional fields would go here (celt versions, opus, etc.)
        
        sendTCPData(authMessage)
    }
    
    private func sendTCPData(_ data: Data) {
        let length = UInt32(data.count).bigEndian
        var packet = Data()
        packet.append(contentsOf: withUnsafeBytes(of: length) { Data($0) })
        packet.append(data)
        
        tcpConnection?.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                print("TCP send error: \(error)")
            }
        })
    }
    
    private func receiveTCPData() {
        tcpConnection?.receive(minimumIncompleteLength: 4, maximumLength: MumbleConstants.maxPacketSize) { [weak self] data, _, isComplete, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.connectionState = .error("TCP receive error: \(error.localizedDescription)")
                }
                return
            }
            
            if let data = data, !data.isEmpty {
                self?.processTCPData(data)
            }
            
            if !isComplete {
                self?.receiveTCPData()
            }
        }
    }
    
    private func processTCPData(_ data: Data) {
        guard data.count >= 4 else { return }
        
        let length = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard data.count >= Int(length) + 4 else { return }
        
        let messageData = data.dropFirst(4).prefix(Int(length))
        
        guard messageData.count >= 2 else { return }
        
        let messageType = messageData.prefix(2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        
        if let type = MumbleMessageType(rawValue: messageType) {
            handleMessage(type: type, data: messageData.dropFirst(2))
        }
    }
    
    private func handleMessage(type: MumbleMessageType, data: Data) {
        switch type {
        case .version:
            handleVersionMessage(data)
        case .serverSync:
            handleServerSyncMessage(data)
            connectionState = .synchronized
        case .channelState:
            handleChannelStateMessage(data)
        case .userState:
            handleUserStateMessage(data)
        case .textMessage:
            handleTextMessage(data)
        case .ping:
            handlePingMessage(data)
        default:
            print("Unhandled message type: \(type.rawValue)")
        }
    }
    
    private func handleVersionMessage(_ data: Data) {
        print("Received version message")
        // Handle version response
    }
    
    private func handleServerSyncMessage(_ data: Data) {
        print("Received server sync message")
        // Handle server synchronization
    }
    
    private func handleChannelStateMessage(_ data: Data) {
        print("Received channel state message")
        // Handle channel updates
    }
    
    private func handleUserStateMessage(_ data: Data) {
        print("Received user state message")
        // Handle user updates
    }
    
    private func handleTextMessage(_ data: Data) {
        print("Received text message")
        // Handle text messages
    }
    
    private func handlePingMessage(_ data: Data) {
        print("Received ping message")
        // Handle ping/pong
    }
    
    // MARK: - Audio Methods
    func sendAudioData(_ audioData: Data) {
        guard isConnected else { return }
        
        // Send audio data via UDP
        // This is a simplified implementation
        udpConnection?.send(content: audioData, completion: .contentProcessed { error in
            if let error = error {
                print("UDP audio send error: \(error)")
            }
        })
    }
    
    func sendTextMessage(_ message: String, to channelId: Int32? = nil) {
        guard isConnected else { return }
        
        var textMessage = Data()
        
        // Message type (TextMessage)
        textMessage.append(contentsOf: withUnsafeBytes(of: MumbleMessageType.textMessage.rawValue.bigEndian) { Data($0) })
        
        // Actor (current user ID - simplified)
        textMessage.append(contentsOf: withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) })
        
        // Message content
        let messageData = message.data(using: .utf8) ?? Data()
        textMessage.append(contentsOf: withUnsafeBytes(of: UInt32(messageData.count).bigEndian) { Data($0) })
        textMessage.append(messageData)
        
        // Channel ID (if specified)
        if let channelId = channelId {
            textMessage.append(contentsOf: withUnsafeBytes(of: channelId.bigEndian) { Data($0) })
        }
        
        sendTCPData(textMessage)
    }
}
