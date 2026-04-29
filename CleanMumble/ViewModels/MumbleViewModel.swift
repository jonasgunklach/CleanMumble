//
//  MumbleViewModel.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import Foundation
import SwiftUI
import Combine
import AVFoundation

@MainActor
class MumbleViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var connectionState: ConnectionState = .disconnected
    @Published var currentServer: ServerConnectionInfo?
    @Published var servers: [ServerConnectionInfo] = []
    @Published var channels: [ChannelInfo] = []
    @Published var users: [UserInfo] = []
    @Published var currentChannel: ChannelInfo?
    @Published var isConnected: Bool = false
    @Published var isMuted: Bool = false
    @Published var isDeafened: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var inputVolume: Float = 1.0
    @Published var outputVolume: Float = 1.0
    @Published var userPreferences: UserPreferences = UserPreferences()
    @Published var chatMessages: [ChatMessage] = []
    
    // MARK: - Computed Properties
    var usersInCurrentChannel: [UserInfo] {
        guard let currentChannel = currentChannel else { return users }
        return users.filter { $0.currentChannelId == currentChannel.channelId }
    }
    
    var rootChannels: [ChannelInfo] {
        return channels.filter { $0.parentChannelId == nil || $0.parentChannelId == 0 }
            .sorted { $0.channelId < $1.channelId }
    }
    
    func usersInChannel(_ channelId: Int32) -> [UserInfo] {
        return users.filter { $0.currentChannelId == channelId }
    }
    
    func childChannels(of parentId: Int32) -> [ChannelInfo] {
        return channels.filter { $0.parentChannelId == parentId }
            .sorted { $0.channelId < $1.channelId }
    }
    
    // MARK: - Private Properties
    private var cancellables = Set<AnyCancellable>()
    private var audioEngine: AVAudioEngine?
    private var mumbleProtocol: MumbleProtocolHandler?
    private var realMumbleClient: RealMumbleClient?
    #if os(iOS)
    private var audioSession: AVAudioSession?
    #endif
    
    // MARK: - Sample Data
    init() {
        loadServers()
        loadUserPreferences()
        setupAudioSession()
        // Don't load sample data by default - let server data populate the UI
        
        // Auto-add magical.rocks server if not present
        addMagicalRocksServerIfNeeded()
    }
    
    private func addMagicalRocksServerIfNeeded() {
        // Check if magical.rocks server already exists
        let magicalRocksExists = servers.contains { server in
            server.host == "magical.rocks" && server.username == "joonasboonas"
        }
        
        if !magicalRocksExists {
            let magicalRocksServer = ServerConnectionInfo(
                name: "Magical Rocks",
                host: "magical.rocks",
                port: 64738,
                username: "joonasboonas",
                password: "",
                isFavorite: true
            )
            addServer(magicalRocksServer)
            print("📱 Auto-added magical.rocks server")
        }
    }
    
    // MARK: - Server Management
    func addServer(_ server: ServerConnectionInfo) {
        servers.append(server)
        saveServers()
    }
    
    func removeServer(_ server: ServerConnectionInfo) {
        servers.removeAll { $0.id == server.id }
        saveServers()
    }
    
    func updateServer(_ server: ServerConnectionInfo) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
            saveServers()
        }
    }
    
    func toggleFavorite(_ server: ServerConnectionInfo) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].isFavorite.toggle()
            saveServers()
        }
    }
    
    // MARK: - Connection Management
    func connectToServer(_ server: ServerConnectionInfo) {
        currentServer = server
        connectionState = .connecting
        
        // Create real Mumble client
        realMumbleClient = RealMumbleClient()
        
        // Observe connection state changes
        realMumbleClient?.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.isConnected = (state == .connected)
                
                if state == .connected {
                    self?.updateLastConnected(for: server)
                }
            }
            .store(in: &cancellables)
        
        // Observe server data changes
        realMumbleClient?.$channels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newChannels in
                print("📱 ViewModel received \(newChannels.count) channels")
                self?.channels = newChannels
            }
            .store(in: &cancellables)
        
        realMumbleClient?.$users
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newUsers in
                print("📱 ViewModel received \(newUsers.count) users")
                self?.users = newUsers
            }
            .store(in: &cancellables)
        
        realMumbleClient?.$currentChannel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newChannel in
                self?.currentChannel = newChannel
            }
            .store(in: &cancellables)
        
        realMumbleClient?.$chatMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMessages in
                self?.chatMessages = newMessages
                self?.saveChatMessages()
            }
            .store(in: &cancellables)
        
        realMumbleClient?.$isMuted
            .receive(on: DispatchQueue.main)
            .sink { [weak self] muted in
                self?.isMuted = muted
            }
            .store(in: &cancellables)
        
        realMumbleClient?.$isDeafened
            .receive(on: DispatchQueue.main)
            .sink { [weak self] deafened in
                self?.isDeafened = deafened
            }
            .store(in: &cancellables)
        
        // Start connection
        realMumbleClient?.connect(to: server.host, port: UInt16(server.port), username: server.username, password: server.password)
    }
    
    func disconnect() {
        realMumbleClient?.disconnect()
        realMumbleClient = nil
        cancellables.removeAll()
        connectionState = .disconnected
        isConnected = false
        currentServer = nil
        channels = []
        users = []
        currentChannel = nil
        chatMessages = []
        stopAudioEngine()
    }
    
    // MARK: - Channel Management
    func joinChannel(_ channel: ChannelInfo) {
        currentChannel = channel  // optimistic update; server echoes UserState to confirm
        realMumbleClient?.joinChannel(channel.channelId)
    }
    
    func sendTextMessage(_ message: String) {
        // Send to real Mumble client
        realMumbleClient?.sendTextMessage(message, to: UInt32(currentChannel?.channelId ?? 0))
    }
    
    // MARK: - Audio Controls
    func toggleMute() {
        if let client = realMumbleClient {
            client.toggleMute()   // client publishes isMuted back via Combine
        } else {
            isMuted.toggle()
        }
    }

    func toggleDeafen() {
        if let client = realMumbleClient {
            client.toggleDeafen()
        } else {
            isDeafened.toggle()
        }
    }

    func setInputVolume(_ volume: Float) {
        inputVolume = max(0.0, min(1.0, volume))
    }

    func setOutputVolume(_ volume: Float) {
        outputVolume = max(0.0, min(1.0, volume))
        realMumbleClient?.setOutputVolume(isDeafened ? 0 : outputVolume)
    }
    
    // MARK: - Preferences
    func updateTheme(_ theme: AppTheme) {
        userPreferences.theme = theme
        saveUserPreferences()
    }
    
    func updateAudioSettings(_ settings: AudioSettings) {
        userPreferences.audioSettings = settings
        saveUserPreferences()
        // If connected, apply new device selection immediately
        if let client = realMumbleClient {
            let deviceChanged = client.inputDeviceUID != settings.inputDevice
                         || client.outputDeviceUID != settings.outputDevice
            client.inputDeviceUID  = settings.inputDevice
            client.outputDeviceUID = settings.outputDevice
            client.opusBitrate  = settings.quality.bitrate
            client.opusFrameMs  = settings.quality.frameMs
            client.opusLowDelay = settings.quality.lowDelay
            // Map slider 0…1 → RMS 0.001 (very sensitive) … 0.05 (loud only).
            // Mumble-style voice activation: anything below the threshold is
            // treated as silence and not transmitted.
            client.vadThreshold = 0.001 + Float(settings.voiceActivityThreshold) * 0.049
            client.stopAudioEngine()
            // The native CoreAudio path handles device hot-swap via AU
            // property listeners; no settle delay needed. The legacy
            // AVAudioEngine path used to need ~0.8s for Bluetooth devices.
            let rebuildDelay: Double = deviceChanged ? 0.2 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + rebuildDelay) { [weak client] in
                guard let client else { return }
                client.setupAudioEngine()
                client.startAudioEngine()
            }
        }
    }
    
    // MARK: - Private Methods
    private func loadChatMessages() {
        if let data = UserDefaults.standard.data(forKey: "SavedChatMessages"),
           let savedMessages = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            chatMessages = savedMessages
        } else {
            loadSampleChatMessages()
        }
    }
    
    private func saveChatMessages() {
        if let data = try? JSONEncoder().encode(chatMessages) {
            UserDefaults.standard.set(data, forKey: "SavedChatMessages")
        }
    }
    
    private func loadSampleChatMessages() {
        chatMessages = [
            ChatMessage(id: UUID(), content: "Welcome to Magical Rocks server! 🎮", sender: "Server", timestamp: Date().addingTimeInterval(-3600), type: .system),
            ChatMessage(id: UUID(), content: "Hey everyone! How's it going?", sender: "Alice", timestamp: Date().addingTimeInterval(-1800), type: .text),
            ChatMessage(id: UUID(), content: "Great! Just finished a game of Counter-Strike", sender: "Bob", timestamp: Date().addingTimeInterval(-1200), type: .text),
            ChatMessage(id: UUID(), content: "Anyone up for some Valorant later?", sender: "Charlie", timestamp: Date().addingTimeInterval(-600), type: .text),
            ChatMessage(id: UUID(), content: "Count me in! 🎮", sender: "Diana", timestamp: Date().addingTimeInterval(-300), type: .text),
            ChatMessage(id: UUID(), content: "The voice quality on this server is amazing!", sender: "Eve", timestamp: Date().addingTimeInterval(-120), type: .text)
        ]
    }
    
    private func loadSampleData() {
        // Sample servers
        servers = [
            ServerConnectionInfo(name: "Magical Rocks", host: "magical.rocks", port: 64738, username: "JoonasBoonas", isFavorite: true)
        ]
        
        // Sample channels
        channels = [
            ChannelInfo(channelId: 0, name: "Lobby", description: "Main lobby channel"),
            ChannelInfo(channelId: 1, name: "Gaming", description: "Gaming discussions"),
            ChannelInfo(channelId: 2, name: "Gaming • FPS", description: "First-person shooters", parentChannelId: 1),
            ChannelInfo(channelId: 3, name: "Gaming • RPG", description: "Role-playing games", parentChannelId: 1),
            ChannelInfo(channelId: 4, name: "AFK", description: "Away from keyboard")
        ]
        
        // Sample users
        users = [
            UserInfo(userId: 1, name: "Alice"),
            UserInfo(userId: 2, name: "Bob", isMuted: true),
            UserInfo(userId: 3, name: "Charlie"),
            UserInfo(userId: 4, name: "Diana"),
            UserInfo(userId: 5, name: "Eve", isMuted: true)
        ]
    }
    
    private func updateLastConnected(for server: ServerConnectionInfo) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].lastConnected = Date()
            saveServers()
        }
    }
    
    private func loadServerData() {
        // In a real implementation, this would load channels and users from the server
        // For now, we'll use the sample data
    }
    
    private func setupAudioSession() {
        #if os(iOS)
        audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession?.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession?.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
        #else
        // macOS audio setup would go here
        print("Setting up macOS audio")
        #endif
    }
    
    private func updateAudioEngine() {
        // In a real implementation, this would update the audio engine settings
        // For now, we'll just update the speaking state
        isSpeaking = !isMuted && !isDeafened
    }
    
    private func stopAudioEngine() {
        audioEngine?.stop()
        audioEngine = nil
    }
    
    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: "SavedServers")
        }
    }
    
    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: "SavedServers"),
           let decodedServers = try? JSONDecoder().decode([ServerConnectionInfo].self, from: data) {
            servers = decodedServers
        }
    }
    
    private func saveUserPreferences() {
        if let data = try? JSONEncoder().encode(userPreferences) {
            UserDefaults.standard.set(data, forKey: "UserPreferences")
        }
    }
    
    private func loadUserPreferences() {
        if let data = UserDefaults.standard.data(forKey: "UserPreferences"),
           let decodedPreferences = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            userPreferences = decodedPreferences
        }
    }
    
    // MARK: - Debug Methods
    func requestChannelList() {
        realMumbleClient?.requestChannelList()
    }

    func autoConnectToMagicalRocks() {
        print("📱 ViewModel: Auto-connecting to magical.rocks server...")
        
        // Find the magical.rocks server
        if let magicalRocksServer = servers.first(where: { 
            $0.host == "magical.rocks" && $0.username == "joonasboonas" 
        }) {
            print("📱 Found magical.rocks server, connecting...")
            connectToServer(magicalRocksServer)
        } else {
            print("📱 ❌ Magical.rocks server not found!")
        }
    }
    
    func runAutomatedServerTest() {
        print("🤖 === AUTOMATED SERVER TESTING ===")
        print("🤖 This will connect to magical.rocks and test until we get full channel list")
        
        // Create a new client for testing
        let testClient = RealMumbleClient()
        
        // Set up observers to monitor the test
        var testChannels: [ChannelInfo] = []
        var testUsers: [UserInfo] = []
        var connectionEstablished = false
        
        let cancellable1 = testClient.$channels
            .sink { channels in
                testChannels = channels
                print("🤖 Test client received \(channels.count) channels")
                if channels.count > 0 {
                    for (index, channel) in channels.enumerated() {
                        print("🤖   Channel \(index + 1): \(channel.name) (ID: \(channel.channelId))")
                    }
                }
            }
        
        let cancellable2 = testClient.$users
            .sink { users in
                testUsers = users
                print("🤖 Test client received \(users.count) users")
                if users.count > 0 {
                    for (index, user) in users.enumerated() {
                        print("🤖   User \(index + 1): \(user.name) (ID: \(user.userId), Channel: \(user.currentChannelId?.description ?? "none"))")
                    }
                }
            }
        
        let cancellable3 = testClient.$connectionState
            .sink { state in
                print("🤖 Connection state: \(state)")
                if state == .connected {
                    connectionEstablished = true
                }
            }
        
        // Connect to magical.rocks
        print("🤖 Connecting to magical.rocks:64738 as joonasboonas...")
        testClient.connect(to: "magical.rocks", port: 64738, username: "joonasboonas", password: "")
        
        // Wait for connection and data
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            print("🤖 === 5 SECOND CHECK ===")
            print("🤖 Connection established: \(connectionEstablished)")
            print("🤖 Channels received: \(testChannels.count)")
            print("🤖 Users received: \(testUsers.count)")
            
            if testChannels.count == 0 && testUsers.count == 0 {
                print("🤖 ❌ No data received yet – waiting for server messages...")
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            print("🤖 === 10 SECOND CHECK ===")
            print("🤖 Connection established: \(connectionEstablished)")
            print("🤖 Channels received: \(testChannels.count)")
            print("🤖 Users received: \(testUsers.count)")
            
            if testChannels.count == 0 {
                print("🤖 ❌ Still no channels, requesting channel list...")
                testClient.requestChannelList()
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            print("🤖 === 15 SECOND FINAL CHECK ===")
            print("🤖 Connection established: \(connectionEstablished)")
            print("🤖 Channels received: \(testChannels.count)")
            print("🤖 Users received: \(testUsers.count)")
            
            if testChannels.count > 0 && testUsers.count > 0 {
                print("🤖 ✅ SUCCESS: Got \(testChannels.count) channels and \(testUsers.count) users!")
            } else {
                print("🤖 ❌ FAILURE: Still missing data")
                print("🤖   Expected: Multiple channels and 3 users")
                print("🤖   Got: \(testChannels.count) channels, \(testUsers.count) users")
            }
            
            // Clean up
            testClient.disconnect()
            cancellable1.cancel()
            cancellable2.cancel()
            cancellable3.cancel()
        }
    }
}
