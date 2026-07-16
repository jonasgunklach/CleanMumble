//
//  RealMumbleClient.swift
//  CleanMumble
//
//  Complete rewrite of the Mumble TCP networking layer, modelled after the
//  FancyMumbleNext Rust implementation (crates/mumble-protocol).
//
//  Key design decisions (mirroring the Rust code):
//  ─ Wire format: [type: u16 BE][length: u32 BE][protobuf payload]
//  ─ All payload bytes use standard protobuf LEB-128 varint encoding.
//    (The old code accidentally used Mumble-VarInt / UDP-audio encoding
//     for TCP control messages, which is incompatible with the server.)
//  ─ A receive buffer (rxBuffer) accumulates incoming TCP bytes and is
//    drained frame-by-frame.  TCP is a stream; messages can arrive split
//    across multiple read() calls.
//  ─ TLS with self-signed-cert acceptance (most Mumble servers are self-signed).
//  ─ Handshake: connect → Version → Authenticate → handle ServerSync.
//  ─ Ping timer at 15-second intervals (same as Rust default).
//

import Foundation
import Network
import Security
import Combine
import AVFoundation
import CoreAudio
import AudioToolbox
import Opus
import OpusControl
import AudioCore
import AudioEngine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Protobuf decoder
// ─────────────────────────────────────────────────────────────────────────────

enum PBVal {
    case varint(UInt64)
    case bytes(Data)
}

/// Minimal protobuf decoder for Mumble TCP control messages.
/// Supports wire types 0 (varint), 1 (64-bit LE), 2 (length-delimited), 5 (32-bit LE).
func decodeProto(_ data: Data) -> [(field: UInt32, val: PBVal)] {
    var out: [(field: UInt32, val: PBVal)] = []
    var pos = 0

    func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift = 0
        while pos < data.count {
            let b = data[pos]; pos += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    while pos < data.count {
        guard let tag = readVarint() else { break }
        let field = UInt32(tag >> 3)
        switch tag & 7 {
        case 0:
            if let v = readVarint() { out.append((field, .varint(v))) }
        case 1:
            guard pos + 8 <= data.count else { return out }
            var v: UInt64 = 0
            for b in 0..<8 { v |= UInt64(data[pos + b]) << (b * 8) }
            pos += 8
            out.append((field, .varint(v)))
        case 2:
            guard let len = readVarint() else { break }
            let end = pos + Int(len)
            guard end <= data.count else { return out }
            out.append((field, .bytes(data.subdata(in: pos..<end))))
            pos = end
        case 5:
            guard pos + 4 <= data.count else { return out }
            var v: UInt32 = 0
            for b in 0..<4 { v |= UInt32(data[pos + b]) << (b * 8) }
            pos += 4
            out.append((field, .varint(UInt64(v))))
        default:
            return out
        }
    }
    return out
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Protobuf encoder helpers
// ─────────────────────────────────────────────────────────────────────────────

extension Data {

    /// Standard protobuf LEB-128 varint (correct for TCP control messages).
    mutating func pbVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        append(UInt8(v))
    }

    mutating func pbUInt32(field: UInt32, value: UInt32) {
        pbVarint(UInt64((field << 3) | 0))
        pbVarint(UInt64(value))
    }

    mutating func pbUInt64(field: UInt32, value: UInt64) {
        pbVarint(UInt64((field << 3) | 0))
        pbVarint(value)
    }

    mutating func pbBool(field: UInt32, value: Bool) {
        pbUInt32(field: field, value: value ? 1 : 0)
    }

    mutating func pbString(field: UInt32, value: String) {
        let bytes = value.data(using: .utf8) ?? Data()
        pbVarint(UInt64((field << 3) | 2))
        pbVarint(UInt64(bytes.count))
        append(bytes)
    }

    mutating func pbBytes(field: UInt32, value: Data) {
        pbVarint(UInt64((field << 3) | 2))
        pbVarint(UInt64(value.count))
        append(value)
    }

    /// Mumble TCP frame header: [type: u16 BE][length: u32 BE].
    mutating func mumbleHeader(type: UInt16, length: UInt32) {
        var t = type.bigEndian;   append(Data(bytes: &t, count: 2))
        var l = length.bigEndian; append(Data(bytes: &l, count: 4))
    }

    /// Mumble VarInt encoder for audio packet headers (NOT protobuf LEB-128).
    mutating func mumbleVarInt(_ value: UInt64) {
        if value < 0x80 {
            append(UInt8(value))
        } else if value < 0x4000 {
            append(UInt8(0x80 | (value >> 8)))
            append(UInt8(value & 0xFF))
        } else if value < 0x200000 {
            append(UInt8(0xC0 | (value >> 16)))
            append(UInt8((value >> 8) & 0xFF))
            append(UInt8(value & 0xFF))
        } else {
            append(UInt8(0xE0 | (value >> 24)))
            append(UInt8((value >> 16) & 0xFF))
            append(UInt8((value >> 8)  & 0xFF))
            append(UInt8(value & 0xFF))
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - RealMumbleClient
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
class RealMumbleClient: ObservableObject {

    // MARK: Published state

    @Published var connectionState: ConnectionState = .disconnected
    @Published var isConnected: Bool = false
    @Published var serverInfo: ServerInfo?
    @Published var channels: [ChannelInfo] = []
    @Published var users: [UserInfo] = []
    @Published var currentChannel: ChannelInfo?
    @Published var chatMessages: [ChatMessage] = []
    @Published var isMuted: Bool = false
    @Published var isDeafened: Bool = false
    @Published var audioInputLevel: Float = 0.0
    @Published var audioOutputLevel: Float = 0.0
    @Published var isSpeaking: Bool = false
    /// Public base URL of the Fancy Mumble REST API, received in ServerConfig field 9.
    /// Non-nil means the server is a Fancy Mumble instance and supports link previews,
    /// file uploads, etc.
    @Published var fancyRestApiURL: String?

    // MARK: Server capabilities (set from Version message)
    /// `true` once the server has announced version ≥ 1.5; drives audio format choice.
    private var serverUseProtobufAudio: Bool = false

    /// The audio engine (see /audio-engine.md): one state-machine-owned
    /// controller with a realtime-safe capture worker (SRC → HPF → gain →
    /// limiter → VAD → Opus) and pull-model playback (per-sender jitter
    /// buffers drained at the device clock).
    let voiceEngine = EngineController()
    /// Voice transmit path — worker-thread safe, UDP-first with TCP tunnel
    /// fallback. Owns the OCB2-encrypted `MumbleUDPChannel`.
    private let voiceTX = VoiceTX()
    /// True once the engine callbacks have been wired (idempotence guard).
    private var voiceEngineWired = false
    private var udpAudioPacketCount: Int = 0
    /// UIDs of preferred audio devices ("Default" = system default).
    var inputDeviceUID:  String = "Default"
    var outputDeviceUID: String = "Default"
    // Opus quality settings (applied on next engine start)
    var opusBitrate:  Int  = 40000   // bits/s
    var opusFrameMs:  Int  = 20      // 10 / 20 / 40 / 60 ms
    var opusLowDelay: Bool = false   // restricted low-delay application mode

    /// The server's advertised `max_bandwidth` (bits/s, incl. packet overhead)
    /// from ServerSync. 0 = unknown / unlimited. We MUST keep our transmit
    /// bandwidth under this or the server throttles/drops our audio.
    private var serverMaxBandwidth: Int = 0
    /// Processing mode. `.auto` (default): voice processing (AEC + NS + AGC)
    /// for built-in / USB / Bluetooth — including AirPods, where VPIO is what
    /// unlocks the high-bandwidth voice link — raw AUHAL for aggregate /
    /// virtual devices. `.voice` / `.raw` force the choice.
    var voiceProcessingMode: ProcessingMode = .auto
    var enableAGC: Bool = true {
        didSet { applyEngineConfigIfRunning() }
    }
    /// VAD trigger threshold as raw RMS (typ. 0.003 … 0.05). Live-adjustable.
    var vadThreshold: Float = 0.008 {
        didSet { voiceEngine.capture.vadThreshold = vadThreshold }
    }
    /// Linear mic gain before encoding (ramped, click-free). Live-adjustable.
    var inputGain: Float = 1.0 {
        didSet { voiceEngine.capture.inputGain.target = max(0, min(8, inputGain)) }
    }
    /// Echo test: transmit with voice target 31 so the server loops our own
    /// voice back to us. Live-toggleable; nothing else changes.
    var loopbackEnabled: Bool = false {
        didSet { voiceTX.setLoopback(loopbackEnabled) }
    }
    /// RNNoise ML noise suppression on the mic. Live-toggleable; stacks on top
    /// of VPIO's own NS on the voice path, and is the only NS on the raw path.
    var noiseSuppression: Bool = true {
        didSet { voiceEngine.capture.noiseSuppressionEnabled = noiseSuppression }
    }
    /// Timers to reset remote users' isSpeaking after audio stops arriving.
    private var speakingTimers: [Int32: Timer] = [:]

    // MARK: Network

    private var connection: NWConnection?
    private let networkQueue = DispatchQueue(label: "mumble.net", qos: .userInitiated)

    /// Accumulated receive bytes.  TCP is a stream; frames can be split across
    /// multiple reads.  We drain complete frames in drainBuffer().
    /// Note: [UInt8] avoids the Data.removeFirst() startIndex-shift bug.
    private var rxBuffer: [UInt8] = []

    // MARK: Session

    private(set) var sessionId: UInt32 = 0
    private var serverHost = ""
    private var serverPort: UInt16 = 64738
    private var username = ""
    private var password = ""

    private var pingTimer: Timer?
    private var lossAdaptTimer: Timer?

    // MARK: - Connection-quality stats (read by SettingsView)
    /// Most recent observed inbound packet loss percentage (0…100), summed
    /// across all remote senders over the last adaptation window (~5 s).
    @Published var observedInboundLossPercent: Int = 0
    /// Current Opus encoder bitrate in bits per second after adaptation.
    @Published var currentEncoderBitrate: Int = 0
    /// Largest jitter-buffer target depth currently in use (ms).
    @Published var currentJitterDepthMs: Int = 0

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Connect / Disconnect
    // ─────────────────────────────────────────────────────────────────────────

    func connect(to host: String,
                 port: UInt16 = 64738,
                 username: String,
                 password: String = "") {
        disconnect()

        self.serverHost = host
        self.serverPort = port
        self.username   = username
        self.password   = password

        channels        = []
        users           = []
        rxBuffer        = []
        sessionId       = 0
        connectionState = .connecting
        isConnected     = false

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )

        // Mumble requires TLS.  Most servers use self-signed certs, so we
        // accept everything — mirroring Rust's `accept_invalid_certs: true`.
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, verify in verify(true) },
            networkQueue
        )
        sec_protocol_options_set_peer_authentication_required(
            tls.securityProtocolOptions, false
        )

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle   = 30
        // Voice frames are tiny and latency-critical; Nagle would coalesce
        // them and add up to ~40 ms of head-of-line delay on the UDPTunnel
        // (TCP) voice fallback path.
        tcp.noDelay = true

        let params = NWParameters(tls: tls, tcp: tcp)
        let conn   = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.onStateChange(state) }
        }
        conn.start(queue: networkQueue)
        voiceTX.attach(connection: conn)
        scheduleReceive()
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        lossAdaptTimer?.invalidate(); lossAdaptTimer = nil
        speakingTimers.values.forEach { $0.invalidate() }
        speakingTimers.removeAll()
        stopAudioEngine()
        voiceTX.attach(connection: nil)
        voiceTX.udp.stop()
        connection?.cancel();    connection  = nil
        rxBuffer  = []
        sessionId = 0
        if connectionState != .disconnected {
            connectionState = .disconnected
            isConnected     = false
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Connection state
    // ─────────────────────────────────────────────────────────────────────────

    private func onStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // TLS handshake complete.
            // Per Mumble protocol: send Version FIRST, then Authenticate.
            print("[Mumble] TLS ready – sending Version + Authenticate")
            sendVersion()
            sendAuthenticate()

        case .failed(let err):
            connectionState = .disconnected
            isConnected     = false
            print("[Mumble] Connection failed: \(err.localizedDescription)")

        case .cancelled:
            connectionState = .disconnected
            isConnected     = false

        case .waiting(let err):
            print("[Mumble] Waiting: \(err.localizedDescription)")

        default:
            break
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Receive loop
    // ─────────────────────────────────────────────────────────────────────────

    // scheduleReceive() is called once on connect, then again at the end of
    // each receive callback.  We never re-install the stateUpdateHandler —
    // the old code's mistake that caused connection-state resets on each read.

    /// Feed raw bytes as if they arrived from the network – used by unit tests
    /// to exercise the message handlers without a real TLS connection.
    func _testInjectBytes(_ data: Data) {
        rxBuffer.append(contentsOf: data)
        drainBuffer()
    }

    private func scheduleReceive() {
        connection?.receive(minimumIncompleteLength: 1,
                            maximumLength: 65_536) { [weak self] data, _, isDone, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let err = error {
                    print("[Mumble] Receive error: \(err)"); return
                }
                if let chunk = data, !chunk.isEmpty {
                    self.rxBuffer.append(contentsOf: chunk)
                    self.drainBuffer()
                }
                if !isDone { self.scheduleReceive() }
            }
        }
    }

    /// Drain all complete Mumble frames from the receive buffer.
    ///
    /// Frame format (identical to Rust codec::decode):
    ///   [type: u16 big-endian][length: u32 big-endian][payload: bytes]
    private func drainBuffer() {
        while rxBuffer.count >= 6 {
            let msgType = (UInt16(rxBuffer[0]) << 8) | UInt16(rxBuffer[1])
            let payLen  = (UInt32(rxBuffer[2]) << 24) | (UInt32(rxBuffer[3]) << 16)
                        | (UInt32(rxBuffer[4]) << 8)  |  UInt32(rxBuffer[5])

            // 8 MiB limit matches Rust MAX_PAYLOAD_SIZE.
            guard payLen < 8 * 1_024 * 1_024 else {
                print("[Mumble] Oversized message (\(payLen) B) – disconnecting")
                disconnect(); return
            }

            let total = 6 + Int(payLen)
            guard rxBuffer.count >= total else { break }

            let payload = Data(rxBuffer[6..<total])
            rxBuffer.removeFirst(total)

            dispatch(type: msgType, payload: payload)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Incoming message dispatch
    // ─────────────────────────────────────────────────────────────────────────

    private func dispatch(type: UInt16, payload: Data) {
        switch type {
        case  0: onVersion(payload)
        case  1: onUDPTunnel(payload)   // audio via TCP tunnel
        case  3: onPing(payload)
        case  4: onReject(payload)
        case  5: onServerSync(payload)
        case  6: onChannelRemove(payload)
        case  7: onChannelState(payload)
        case  8: onUserRemove(payload)
        case  9: onUserState(payload)
        case 11: onTextMessage(payload)
        case 15: onCryptSetup(payload)
        case 21: break   // CodecVersion – no action needed
        case 24: onServerConfig(payload)
        case 133: onLinkPreviewResponse(payload)
        default: break
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Incoming handlers
    // ─────────────────────────────────────────────────────────────────────────

    private func onVersion(_ payload: Data) {
        var release = ""; var os = ""; var versionV1: UInt32 = 0
        for f in decodeProto(payload) {
            switch f.field {
            case 1: if case .varint(let v) = f.val { versionV1 = UInt32(v) }
            case 2: if case .bytes(let d) = f.val { release = str(d) }
            case 3: if case .bytes(let d) = f.val { os      = str(d) }
            default: break
            }
        }
        // version_v1 encoding: (major << 16) | (minor << 8) | patch
        // 1.5.0 = 0x00010500 = 66816
        serverUseProtobufAudio = versionV1 >= 0x00010500
        voiceTX.setProtobufAudio(serverUseProtobufAudio)
        let major = (versionV1 >> 16) & 0xFF
        let minor = (versionV1 >>  8) & 0xFF
        print("[Mumble] Server version: \(major).\(minor) (\(release) / \(os)) — audio: \(serverUseProtobufAudio ? "protobuf" : "legacy")")
    }

    private func onPing(_ payload: Data) {
        for f in decodeProto(payload) {
            if f.field == 1, case .varint(let ts) = f.val {
                let now = UInt64(Date().timeIntervalSince1970 * 1000)
                let rtt = Double(now &- ts)
                if rtt > 0 && rtt < 60_000 { print("[Mumble] Ping RTT \(Int(rtt)) ms") }
            }
        }
    }

    private func onReject(_ payload: Data) {
        var reason = "unknown"
        for f in decodeProto(payload) {
            if f.field == 2, case .bytes(let d) = f.val { reason = str(d) }
        }
        print("[Mumble] Server rejected: \(reason)")
        connectionState = .disconnected
        isConnected     = false
    }

    private func onServerSync(_ payload: Data) {
        var session: UInt32 = 0; var maxBW: UInt32 = 0; var welcome = ""
        for f in decodeProto(payload) {
            switch f.field {
            case 1: if case .varint(let v) = f.val { session = UInt32(v) }
            case 2: if case .varint(let v) = f.val { maxBW   = UInt32(v) }
            case 3: if case .bytes(let d)  = f.val { welcome = str(d) }
            default: break
            }
        }

        sessionId       = session
        connectionState = .connected
        isConnected     = true
        serverMaxBandwidth = Int(maxBW)
        serverInfo      = ServerInfo(name: serverHost, version: "1.x", release: "",
                                     os: "", osVersion: "", welcomeText: welcome,
                                     maxBandwidth: Int(maxBW))

        print("[Mumble] ServerSync – session \(session)" +
              (welcome.isEmpty ? "" : ", welcome: \(welcome.prefix(80))"))
        startPingTimer()
        // Bring up the native UDP voice channel (same host/port as TCP).
        // It stays in `probing` until CryptSetup keys arrive and a ping is
        // echoed; until then voice transparently rides the TCP tunnel.
        voiceTX.udp.onNeedsResync = { [weak self] in
            Task { @MainActor [weak self] in
                // Empty CryptSetup = "please resend a server_nonce".
                self?.sendFrame(type: 15, payload: Data())
            }
        }
        voiceTX.udp.onVoicePacket = { [weak self] packet in
            Task { @MainActor [weak self] in self?.onUDPTunnel(packet) }
        }
        voiceTX.udp.onLinkStateChange = { state in
            print("[Mumble] UDP voice link: \(state.rawValue)")
        }
        voiceTX.udp.start(host: serverHost, port: serverPort)
        ensureMicrophoneAccess { [weak self] granted in
            guard let self else { return }
            if granted {
                self.setupAudioEngine()
                self.startAudioEngine()
            } else {
                print("[Audio] Microphone access denied. Open System Settings → Privacy & Security → Microphone and enable CleanMumble.")
            }
        }

        // Show welcome message in chat if the server provided one.
        if !welcome.isEmpty {
            let text = welcome.strippingHTML
            if !text.isEmpty {
                chatMessages.append(ChatMessage(id: UUID(), content: text, sender: "Server",
                                                timestamp: Date(), type: .system))
            }
        }
    }

    private func onChannelRemove(_ payload: Data) {
        for f in decodeProto(payload) {
            if f.field == 1, case .varint(let v) = f.val {
                channels.removeAll { $0.channelId == Int32(v) }
            }
        }
    }

    private func onChannelState(_ payload: Data) {
        let fields = decodeProto(payload)
        var cid: UInt32 = 0; var parent: UInt32 = 0
        var name = ""; var desc: String?; var temp = false; var hasCid = false

        for f in fields {
            switch f.field {
            case 1: if case .varint(let v) = f.val { cid = UInt32(v); hasCid = true }
            case 2: if case .varint(let v) = f.val { parent = UInt32(v) }
            case 3: if case .bytes(let d)  = f.val { name = str(d) }
            case 5: if case .bytes(let d)  = f.val { desc = str(d) }
            case 8: if case .varint(let v) = f.val { temp = v != 0 }
            default: break
            }
        }
        guard hasCid else { return }

        let ch = ChannelInfo(
            channelId:      Int32(cid),
            name:           name.isEmpty ? "Channel \(cid)" : name,
            description:    desc,
            isTemporary:    temp,
            parentChannelId: parent == 0 ? nil : Int32(parent)
        )

        if let i = channels.firstIndex(where: { $0.channelId == ch.channelId }) {
            channels[i] = ch
        } else {
            channels.append(ch)
            if currentChannel == nil && cid == 0 { currentChannel = ch }
        }
    }

    private func onUserRemove(_ payload: Data) {
        for f in decodeProto(payload) {
            if f.field == 1, case .varint(let v) = f.val {
                users.removeAll { $0.userId == Int32(v) }
                voiceEngine.playback.removeSender(Int32(v))
            }
        }
    }

    private func onUserState(_ payload: Data) {
        let fields = decodeProto(payload)
        var session: UInt32?; var name = ""; var cid: UInt32 = 0; var hasCid = false
        var mute = false; var deaf = false; var suppress = false
        var selfMute = false; var selfDeaf = false
        var priority = false; var recording = false; var comment: String?

        for f in fields {
            switch f.field {
            case  1: if case .varint(let v) = f.val { session   = UInt32(v) }
            case  3: if case .bytes(let d)  = f.val { name      = str(d) }
            case  5: if case .varint(let v) = f.val { cid       = UInt32(v); hasCid = true }
            case  6: if case .varint(let v) = f.val { mute      = v != 0 }
            case  7: if case .varint(let v) = f.val { deaf      = v != 0 }
            case  8: if case .varint(let v) = f.val { suppress  = v != 0 }
            case  9: if case .varint(let v) = f.val { selfMute  = v != 0 }
            case 10: if case .varint(let v) = f.val { selfDeaf  = v != 0 }
            case 14: if case .bytes(let d)  = f.val { comment   = str(d) }
            case 18: if case .varint(let v) = f.val { priority  = v != 0 }
            case 19: if case .varint(let v) = f.val { recording = v != 0 }
            default: break
            }
        }
        guard let session else { return }

        if let i = users.firstIndex(where: { $0.userId == Int32(session) }) {
            var u = users[i]
            if !name.isEmpty    { u.name            = name }
            if hasCid           { u.currentChannelId = Int32(cid) }
            u.isMuted           = mute
            u.isDeafened        = deaf
            u.isSuppressed      = suppress
            u.isSelfMuted       = selfMute
            u.isSelfDeafened    = selfDeaf
            u.isPrioritySpeaker = priority
            u.isRecording       = recording
            if let c = comment  { u.comment         = c }
            users[i] = u
        } else {
            var u = UserInfo(userId: Int32(session),
                             name: name.isEmpty ? "User \(session)" : name,
                             isMuted: mute,
                             isDeafened: deaf)
            u.currentChannelId  = Int32(cid)   // default 0 is correct for new users
            u.isSuppressed      = suppress
            u.isSelfMuted       = selfMute
            u.isSelfDeafened    = selfDeaf
            u.isPrioritySpeaker = priority
            u.isRecording       = recording
            u.comment           = comment
            users.append(u)
        }

        if session == sessionId {
            isMuted    = selfMute || mute
            isDeafened = selfDeaf || deaf
            if hasCid, let ch = channels.first(where: { $0.channelId == Int32(cid) }) {
                currentChannel = ch
            }
        }
    }

    private func onTextMessage(_ payload: Data) {
        var actor: UInt32?; var text = ""
        for f in decodeProto(payload) {
            switch f.field {
            case 1: if case .varint(let v) = f.val { actor = UInt32(v) }
            case 5: if case .bytes(let d)  = f.val { text  = str(d) }
            default: break
            }
        }
        guard !text.isEmpty else { return }

        // Extract any inline <img> from the HTML and strip tags for plain text.
        let (display, imageURL, imageData) = extractImageFromHTML(text)
        guard !display.isEmpty || imageURL != nil || imageData != nil else { return }

        let sender = actor
            .flatMap { id in users.first { $0.userId == Int32(id) }?.name }
            ?? "Server"
        let msgId = UUID()
        chatMessages.append(ChatMessage(id: msgId, content: display, sender: sender,
                                        timestamp: Date(), type: .text,
                                        imageURL: imageURL, imageData: imageData))

        // If connected to a Fancy server, request link previews for any URLs in the text.
        if fancyRestApiURL != nil, !display.isEmpty {
            let urls = extractURLs(from: display)
            if !urls.isEmpty {
                sendLinkPreviewRequest(urls: urls, requestId: msgId.uuidString)
            }
        }
    }

    private func onCryptSetup(_ payload: Data) {
        // OCB2-AES128 material for the native UDP voice channel.
        var key: [UInt8]?
        var clientNonce: [UInt8]?
        var serverNonce: [UInt8]?
        for f in decodeProto(payload) {
            switch f.field {
            case 1: if case .bytes(let d) = f.val { key = [UInt8](d) }
            case 2: if case .bytes(let d) = f.val { clientNonce = [UInt8](d) }
            case 3: if case .bytes(let d) = f.val { serverNonce = [UInt8](d) }
            default: break
            }
        }
        if let reply = voiceTX.udp.handleCryptSetup(key: key,
                                                    clientNonce: clientNonce,
                                                    serverNonce: serverNonce) {
            // Empty CryptSetup from the server = it wants our client_nonce.
            var p = Data()
            p.pbBytes(field: 2, value: Data(reply))
            sendFrame(type: 15, payload: p)
            print("[Mumble] CryptSetup: resent client nonce")
        } else {
            print("[Mumble] CryptSetup: \(key != nil ? "keys installed" : "server nonce updated")")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Fancy Mumble: link previews & image helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// Handle FancyLinkPreviewResponse (wire type 133).
    private func onLinkPreviewResponse(_ payload: Data) {
        var requestId = ""
        var embedPayloads: [Data] = []
        for f in decodeProto(payload) {
            switch f.field {
            case 1: if case .bytes(let d) = f.val { requestId = str(d) }
            case 2: if case .bytes(let d) = f.val { embedPayloads.append(d) }
            default: break
            }
        }
        guard !requestId.isEmpty else { return }

        var previews: [LinkPreviewData] = []
        for embedData in embedPayloads {
            var url = ""; var type_ = ""; var title = ""; var desc = ""; var siteName = ""
            var color: Int32 = 0
            var thumbData: Data? = nil; var thumbMime = ""

            for f in decodeProto(embedData) {
                switch f.field {
                case 1: if case .bytes(let d) = f.val { url      = str(d) }
                case 2: if case .bytes(let d) = f.val { type_    = str(d) }
                case 3: if case .bytes(let d) = f.val { title    = str(d) }
                case 4: if case .bytes(let d) = f.val { desc     = str(d) }
                case 5: if case .varint(let v) = f.val { color   = Int32(bitPattern: UInt32(v & 0xFFFFFFFF)) }
                case 6: if case .bytes(let d) = f.val { siteName = str(d) }
                case 7: // thumbnail Media sub-message
                    if case .bytes(let d) = f.val {
                        for mf in decodeProto(d) {
                            switch mf.field {
                            case 4: if case .bytes(let bd) = mf.val { thumbData = bd }
                            case 5: if case .bytes(let md) = mf.val { thumbMime = str(md) }
                            default: break
                            }
                        }
                    }
                default: break
                }
            }
            guard !url.isEmpty else { continue }
            previews.append(LinkPreviewData(
                title:         title.isEmpty    ? nil : title,
                description:   desc.isEmpty     ? nil : desc,
                siteName:      siteName.isEmpty ? nil : siteName,
                thumbnailData: thumbData,
                thumbnailMime: thumbMime.isEmpty ? nil : thumbMime,
                url:           url,
                previewType:   type_.isEmpty    ? nil : type_,
                accentColor:   color != 0       ? color : nil
            ))
        }

        // Attach previews to the matching message.
        if let idx = chatMessages.firstIndex(where: { $0.id.uuidString == requestId }) {
            chatMessages[idx].linkPreviews = previews.isEmpty ? nil : previews
        }
    }

    /// Send FancyLinkPreviewRequest (wire type 132) for the given URLs.
    private func sendLinkPreviewRequest(urls: [String], requestId: String) {
        guard !urls.isEmpty else { return }
        var p = Data()
        for url in urls { p.pbString(field: 1, value: url) }
        p.pbString(field: 2, value: requestId)
        sendFrame(type: 132, payload: p)
    }

    /// Extract URLs from plain text using NSDataDetector.
    private func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap { $0.url?.absoluteString }
    }

    /// Parse the first `<img>` tag from an HTML string and return the plain
    /// text (tags stripped), plus any detected image URL or inline data bytes.
    private func extractImageFromHTML(_ html: String) -> (text: String, imageURL: String?, imageData: Data?) {
        var imageURL: String? = nil
        var imageData: Data? = nil
        var processedHTML = html

        // Pattern matches <img ...src="VALUE"...> (case-insensitive, single-line).
        let pattern = #"<img[^>]+\bsrc="([^"]*)"[^>]*/?\s*>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let srcNSRange = Range(match.range(at: 1), in: html) {

            let src = String(html[srcNSRange])
            // Remove the <img> tag from the HTML before stripping remaining tags.
            if let tagRange = Range(match.range, in: html) {
                processedHTML = html.replacingCharacters(in: tagRange, with: "")
            }

            if src.hasPrefix("data:") {
                // Inline data URI — decode the base64 payload.
                if let commaIdx = src.firstIndex(of: ",") {
                    let b64 = String(src[src.index(after: commaIdx)...])
                    imageData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
                }
            } else if src.hasPrefix("http://") || src.hasPrefix("https://") {
                imageURL = src
            }
        }

        let display = processedHTML.strippingHTML
        return (display, imageURL, imageData)
    }

    // ─────────────────────────────────────────────────────────────────────────

    /// Handle incoming UDPTunnel (type 1) audio packets from the server.
    /// Mumble audio packet inside UDPTunnel (server → client):
    ///   [1-byte header] = (codec << 5) | target
    ///   Mumble VarInt: sender session ID  (prepended by server)
    ///   Mumble VarInt: sequence number
    ///   Mumble VarInt: opus length (bit 13 = end-of-transmission flag)
    ///   [opus bytes]
    private func onUDPTunnel(_ payload: Data) {
        udpAudioPacketCount += 1
        if udpAudioPacketCount <= 3 {
            print("[Audio] UDPTunnel packet #\(udpAudioPacketCount) (\(payload.count) bytes, header=0x\(String(payload[0], radix: 16)))")
        }
        guard payload.count > 1 else { return }
        let header = payload[0]
        let codec  = (header >> 5) & 0x07

        switch codec {
        case 4:  // Legacy Opus: [header][session varint][seq varint][len varint][opus bytes]
            parseLegacyUDPAudio(payload)
        case 0:  // Protobuf v2: [header][MumbleUDP.Audio protobuf bytes]
            parseProtobufUDPAudio(payload)
        default:
            if udpAudioPacketCount <= 3 { print("[Audio] Unknown codec \(codec) in UDPTunnel") }
        }
    }

    private func parseLegacyUDPAudio(_ payload: Data) {
        guard let p = MumbleVoiceParser.parseLegacy(payload) else { return }
        deliverParsedVoice(p)
    }

    private func parseProtobufUDPAudio(_ payload: Data) {
        guard let p = MumbleVoiceParser.parseProtobuf(payload) else { return }
        deliverParsedVoice(p)
    }

    private func deliverParsedVoice(_ p: ParsedVoicePacket) {
        if p.isTerminator {
            voiceEngine.playback.submit(sender: Int32(p.sender), seq: p.seq,
                                        opus: Data(), isTerminator: true)
            return
        }
        markUserSpeaking(Int32(p.sender))
        decodeAndPlay(p.opus, sender: Int32(p.sender), sequence: p.seq)
    }

    /// Mark a remote user as speaking and schedule a timer to clear the state.
    private func markUserSpeaking(_ userId: Int32) {
        if let i = users.firstIndex(where: { $0.userId == userId }) {
            if !users[i].isSpeaking {
                users[i].isSpeaking = true
            }
        }
        // Reset/extend the timer so isSpeaking clears ~400ms after last packet
        speakingTimers[userId]?.invalidate()
        speakingTimers[userId] = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let i = self.users.firstIndex(where: { $0.userId == userId }) {
                    self.users[i].isSpeaking = false
                }
                self.speakingTimers.removeValue(forKey: userId)
            }
        }
    }

    private func decodeAndPlay(_ opusBytes: Data, sender: Int32, sequence: UInt32 = 0) {
        // The playback engine drops packets itself while deafened; the check
        // here just saves the submit call.
        guard !isDeafened else { return }
        voiceEngine.playback.submit(sender: sender, seq: sequence,
                                    opus: opusBytes, isTerminator: false)
    }

    private func onServerConfig(_ payload: Data) {
        for f in decodeProto(payload) {
            switch f.field {
            case 2:
                if case .bytes(let d) = f.val {
                    let txt = str(d)
                    if !txt.isEmpty { print("[Mumble] ServerConfig welcome: \(txt.prefix(120))") }
                }
            case 9:
                // fancy_rest_api_url — non-empty means this is a Fancy Mumble server.
                if case .bytes(let d) = f.val {
                    let apiURL = str(d)
                    if !apiURL.isEmpty {
                        fancyRestApiURL = apiURL
                        print("[Mumble] Fancy server detected — REST API: \(apiURL)")
                    }
                }
            default: break
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Outgoing messages
    // ─────────────────────────────────────────────────────────────────────────

    private func sendFrame(type: UInt16, payload: Data) {
        guard let conn = connection, conn.state == .ready else { return }
        var frame = Data(capacity: 6 + payload.count)
        frame.mumbleHeader(type: type, length: UInt32(payload.count))
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { err in
            if let e = err { print("[Mumble] Send error: \(e)") }
        })
    }

    private func sendVersion() {
        var p = Data()
        // Announce 1.5.0 — we now handle both protobuf (type 0) and legacy (type 4)
        // audio on receive, and pick the correct send format based on the server version.
        p.pbUInt32(field: 1, value: 0x00010500)    // version_v1 = 1.5.0
        p.pbString(field: 2, value: "CleanMumble 1.0")
        #if os(iOS)
        p.pbString(field: 3, value: "iOS")
        #else
        p.pbString(field: 3, value: "macOS")
        #endif
        p.pbString(field: 4, value: ProcessInfo.processInfo.operatingSystemVersionString)
        p.pbUInt64(field: 5, value: (1 << 48) | (5 << 32)) // version_v2 = 1.5.0
        sendFrame(type: 0, payload: p)
        print("[Mumble] → Version 1.5.0")
    }

    private func sendAuthenticate() {
        var p = Data()
        p.pbString(field: 1, value: username)
        if !password.isEmpty { p.pbString(field: 2, value: password) }
        p.pbBool(field: 5, value: true)   // opus = true
        sendFrame(type: 2, payload: p)
        print("[Mumble] → Authenticate (\(username))")
    }

    func sendTextMessage(_ message: String, to channelId: UInt32? = nil) {
        let target = channelId ?? UInt32(currentChannel?.channelId ?? 0)
        // Mumble protocol requires HTML in the message field.
        // Wrap in <p> and escape special HTML characters so the server and
        // other clients (which render HTML) receive a valid message.
        let html = "<p>\(message.escapingHTML)</p>"
        var p = Data()
        p.pbUInt32(field: 3, value: target)   // channel_id
        p.pbString(field: 5, value: html)     // message text (HTML)
        sendFrame(type: 11, payload: p)

        // Optimistic local echo — show the raw message text, not the HTML.
        let me = users.first { $0.userId == Int32(sessionId) }?.name ?? username
        let msgId = UUID()
        chatMessages.append(ChatMessage(id: msgId, content: message, sender: me,
                                        timestamp: Date(), type: .text))

        // Request link previews on Fancy servers.
        if fancyRestApiURL != nil {
            let urls = extractURLs(from: message)
            if !urls.isEmpty {
                sendLinkPreviewRequest(urls: urls, requestId: msgId.uuidString)
            }
        }
    }

    /// Send an image as a base64-encoded inline `<img>` HTML message.
    /// Works on any Mumble server that allows HTML and image messages.
    /// The caller should compress the image to stay under the server's
    /// `imagemessagelength` limit (default 1 MB base64 ≈ 750 KB raw).
    func sendImageMessage(_ imageData: Data, mimeType: String = "image/jpeg") {
        let base64 = imageData.base64EncodedString()
        let html = "<img src=\"data:\(mimeType);base64,\(base64)\" />"
        let target = UInt32(currentChannel?.channelId ?? 0)
        var p = Data()
        p.pbUInt32(field: 3, value: target)
        p.pbString(field: 5, value: html)
        sendFrame(type: 11, payload: p)

        // Optimistic local echo — show the image immediately.
        let me = users.first { $0.userId == Int32(sessionId) }?.name ?? username
        chatMessages.append(ChatMessage(id: UUID(), content: "", sender: me,
                                        timestamp: Date(), type: .text,
                                        imageData: imageData))
    }

    // MARK: - Mute / Deafen

    func toggleMute() {
        isMuted.toggle()
        voiceEngine.capture.isMuted = isMuted
        sendUserState(selfMute: isMuted, selfDeaf: isDeafened)
        if isMuted {
            isSpeaking = false
            audioInputLevel = 0.0
            setLocalUserSpeaking(false)
        }
    }

    func toggleDeafen() {
        isDeafened.toggle()
        if isDeafened { isMuted = true }
        voiceEngine.capture.isMuted = isMuted
        voiceEngine.playback.isDeafened = isDeafened
        sendUserState(selfMute: isMuted, selfDeaf: isDeafened)
    }

    private func sendUserState(selfMute: Bool, selfDeaf: Bool) {
        var p = Data()
        p.pbBool(field:  9, value: selfMute)  // UserState.self_mute
        p.pbBool(field: 10, value: selfDeaf)  // UserState.self_deaf
        sendFrame(type: 9, payload: p)
    }

    func joinChannel(_ channelId: Int32) {
        var p = Data()
        p.pbUInt32(field: 5, value: UInt32(channelId))  // UserState.channel_id
        sendFrame(type: 9, payload: p)
        print("[Mumble] → Join channel \(channelId)")
    }

    // MARK: - Ping timer

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Mumble VarInt (audio wire format, differs from protobuf LEB-128)
    // ─────────────────────────────────────────────────────────────────────────
    //
    // Mumble VarInt encoding used inside UDPTunnel audio packets:
    //   0xxxxxxx                       — 7-bit value
    //   10xxxxxx xxxxxxxx              — 14-bit value
    //   110xxxxx xxxxxxxx xxxxxxxx     — 21-bit value
    //   1110xxxx ...                   — 28-bit etc.

    private func startPingTimer() {
        pingTimer?.invalidate()
        // 15-second interval matches the Rust implementation default.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendPing() }
        }
        startLossAdaptTimer()
    }

    /// Phase 3: every 5 s, sample inbound packet-loss across all per-sender
    /// jitter buffers and feed it back to the local Opus encoder. We can't see
    /// the *actual* outbound loss the server is experiencing on our packets
    /// (Mumble doesn't report it), so we use ingress loss as a proxy — it
    /// correlates well in practice on symmetric Wi-Fi / cellular paths.
    private func startLossAdaptTimer() {
        lossAdaptTimer?.invalidate()
        lossAdaptTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.adaptToObservedLoss() }
        }
    }

    private func adaptToObservedLoss() {
        // Fuse two loss signals: per-sender jitter-buffer outcomes (PLC/FEC)
        // and — once native UDP is up — the OCB2 crypt counters, which see
        // every lost datagram even while nobody is talking.
        let jb = voiceEngine.playback.snapshotStats()
        let total = jb.played + jb.fec + jb.plc
        var lossPct = 0
        if total > 0 {
            // FEC successes signal transient loss at half weight (audio is fine).
            let lossUnits = Double(jb.plc) + 0.5 * Double(jb.fec)
            lossPct = Int((lossUnits / Double(total)) * 100.0)
        }
        if voiceTX.udp.isAlive {
            let s = voiceTX.udp.stats()
            let seen = s.good &+ s.lost
            if seen > 50 {
                lossPct = max(lossPct, Int((Double(s.lost) / Double(seen)) * 100.0))
            }
        }
        let clampedLoss = max(0, min(40, lossPct))
        observedInboundLossPercent = clampedLoss
        currentJitterDepthMs = Int(jb.maxDepthMs)

        // Bitrate ladder. The user's `opusBitrate` setting is the BASELINE
        // (used at low loss), but never above what the server's max_bandwidth
        // permits; we only step DOWN from there as loss climbs.
        let baseline = min(opusBitrate, serverBitrateCeiling())
        let target: Int
        switch clampedLoss {
        case 0...2:   target = baseline
        case 3...8:   target = max(28_000, baseline * 7 / 10)   // ~70%
        case 9...20:  target = max(20_000, baseline / 2)         // ~50%
        default:      target = max(16_000, baseline * 3 / 10)    // ~30%
        }
        // Clamp again: the reduced-loss tiers floor at fixed values that could
        // still exceed a very restrictive server cap.
        let effective = min(target, serverBitrateCeiling())
        voiceEngine.capture.setNetworkAdaptation(bitrate: effective,
                                                 lossPercent: max(5, clampedLoss))
        currentEncoderBitrate = effective
    }

    /// The highest Opus bitrate whose total wire bandwidth stays under the
    /// server's advertised `max_bandwidth`. Mirrors Mumble's own
    /// `AudioInput::getNetworkBandwidth`: total = opus bitrate + per-packet
    /// overhead × packets-per-second, where a packet carries `frames` 10 ms
    /// segments. Inverting gives the Opus ceiling. Returns `Int.max` when the
    /// server advertised no limit.
    private func serverBitrateCeiling() -> Int {
        guard serverMaxBandwidth > 0 else { return Int.max }
        let frames = max(1, opusFrameMs / 10)                 // 10 ms segments per packet
        // Bytes of overhead per packet: IP(20)+UDP(8)+OCB2 crypt(4)+type/target
        // (1)+sequence varint(≈2)+Opus length varint(≈2).
        let overheadBytes = 20 + 8 + 4 + 1 + 2 + 2
        // ×8 bits, ×(100/frames) packets per second.
        let overheadBits = overheadBytes * 8 * 100 / frames
        return max(8_000, serverMaxBandwidth - overheadBits)
    }

    private func sendPing() {
        var p = Data()
        p.pbUInt64(field: 1, value: UInt64(Date().timeIntervalSince1970 * 1000))
        sendFrame(type: 3, payload: p)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Audio engine (Opus via TCP UDPTunnel)
    // ─────────────────────────────────────────────────────────────────────────

    /// Verify (and request, if needed) microphone permission before touching
    /// AVAudioEngine. Without this, `engine.inputNode.outputFormat(...)` and
    /// `engine.start()` fail with -10877 / -10867 forever, with no UI prompt
    /// because AVAudioEngine doesn't trigger the TCC dialog by itself.
    private func ensureMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }

    func setupAudioEngine() {
        wireVoiceEngineIfNeeded()
        // Push the live-adjustable knobs (they survive engine rebuilds).
        voiceEngine.capture.vadThreshold = vadThreshold
        voiceEngine.capture.inputGain.target = max(0, min(8, inputGain))
        voiceEngine.capture.isMuted = isMuted
        voiceEngine.capture.noiseSuppressionEnabled = noiseSuppression
        voiceEngine.playback.isDeafened = isDeafened
        voiceEngine.capture.transmitEnabled = true
        voiceEngine.start(config: currentAudioConfig())
    }

    func startAudioEngine() {
        // Kept for call-site compatibility: the engine starts inside
        // setupAudioEngine() and owns its lifecycle (recovery, device
        // hot-swap, watchdog) from there.
    }

    func stopAudioEngine() {
        voiceEngine.capture.transmitEnabled = false
        voiceEngine.stop()
        voiceEngine.playback.removeAllSenders()
        print("[Audio] Voice engine stopped")
    }

    /// Rebuild-class settings changed (devices, processing mode, Opus format).
    private func applyEngineConfigIfRunning() {
        guard isConnected else { return }
        voiceEngine.apply(config: currentAudioConfig())
    }

    private func currentAudioConfig() -> AudioConfig {
        var c = AudioConfig()
        c.input = DeviceSelection(uid: inputDeviceUID)
        c.output = DeviceSelection(uid: outputDeviceUID)
        c.processing = voiceProcessingMode
        c.agcEnabled = enableAGC
        c.capture = CaptureFormat(opusBitrate: min(opusBitrate, serverBitrateCeiling()),
                                  opusFrameMs: opusFrameMs,
                                  opusLowDelay: opusLowDelay)
        return c
    }

    /// One-time wiring of the engine's data-plane callbacks. Both fire on
    /// the capture worker thread — packet TX goes straight to the thread-safe
    /// transport; only UI state hops to the main actor.
    private func wireVoiceEngineIfNeeded() {
        guard !voiceEngineWired else { return }
        voiceEngineWired = true

        let tx = voiceTX
        voiceEngine.capture.onPacket = { opus, seq, isTerminator in
            tx.sendVoicePacket(opus: opus, seq: seq, isTerminator: isTerminator)
        }
        voiceEngine.capture.onSpeakingChanged = { [weak self] speaking in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSpeaking = speaking
                self.audioInputLevel = speaking ? 1.0 : 0.0
                self.setLocalUserSpeaking(speaking)
            }
        }
        voiceEngine.onStateChange = { state in
            print("[Audio] Engine state: \(state)")
        }
        voiceEngine.onRouteChange = { route in
            guard let route else { return }
            print("[Audio] Route: in=\(route.inputInfo.name) out=\(route.outputInfo.name) " +
                  "backend=\(route.backend.rawValue)" +
                  (route.inputInfo.qualityBadge.map { " [\($0)]" } ?? ""))
        }
    }

    func setOutputVolume(_ volume: Float) {
        voiceEngine.playback.masterGain.target = max(0, min(1, volume))
    }

    /// Reflect the local user's speaking state into the users array so the UI ring updates.
    private func setLocalUserSpeaking(_ speaking: Bool) {
        guard sessionId != 0,
              let i = users.firstIndex(where: { $0.userId == Int32(sessionId) }) else { return }
        users[i].isSpeaking = speaking
    }

    /// Channels arrive automatically via ChannelState messages after ServerSync.
    func requestChannelList() { }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Utilities
    // ─────────────────────────────────────────────────────────────────────────

    private func str(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
