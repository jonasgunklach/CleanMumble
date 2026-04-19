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

    // MARK: Audio engine

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var opusEncoder: Opus.Encoder?
    private var opusDecoder: Opus.Decoder?
    private var opusConverter: AVAudioConverter?
    /// Raw C pointer to the Opus encoder state (for opus_encoder_ctl calls).
    private var opusEncoderPtr: OpaquePointer?
    /// UIDs of preferred audio devices ("Default" = system default).
    var inputDeviceUID:  String = "Default"
    var outputDeviceUID: String = "Default"
    // Opus quality settings (applied on next engine start)
    var opusBitrate:  Int  = 40000   // bits/s
    var opusFrameMs:  Int  = 20      // 10 / 20 / 40 / 60 ms
    var opusLowDelay: Bool = false   // restricted low-delay application mode
    /// Frame size in samples derived from opusFrameMs (48 kHz).
    private var opusFrameSize: AVAudioFrameCount { AVAudioFrameCount(opusFrameMs * 48) }
    /// Monotonically increasing sequence number for outgoing audio packets.
    private var audioSequence: UInt64 = 0
    /// 48 kHz mono float32 format used for both capture and playback.
    private let opusFormat = AVAudioFormat(opusPCMFormat: .float32, sampleRate: 48000, channels: 1)!

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

        let params = NWParameters(tls: tls, tcp: tcp)
        let conn   = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in self?.onStateChange(state) }
        }
        conn.start(queue: networkQueue)
        scheduleReceive()
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        stopAudioEngine()
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
        default: break
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Incoming handlers
    // ─────────────────────────────────────────────────────────────────────────

    private func onVersion(_ payload: Data) {
        var release = ""; var os = ""
        for f in decodeProto(payload) {
            switch f.field {
            case 2: if case .bytes(let d) = f.val { release = str(d) }
            case 3: if case .bytes(let d) = f.val { os      = str(d) }
            default: break
            }
        }
        print("[Mumble] Server version: \(release) / \(os)")
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
        serverInfo      = ServerInfo(name: serverHost, version: "1.x", release: "",
                                     os: "", osVersion: "", welcomeText: welcome,
                                     maxBandwidth: Int(maxBW))

        print("[Mumble] ServerSync – session \(session)" +
              (welcome.isEmpty ? "" : ", welcome: \(welcome.prefix(80))"))
        startPingTimer()
        setupAudioEngine()
        startAudioEngine()
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
            }
        }
    }

    private func onUserState(_ payload: Data) {
        let fields = decodeProto(payload)
        var session: UInt32?; var name = ""; var cid: UInt32 = 0
        var mute = false; var deaf = false; var suppress = false
        var selfMute = false; var selfDeaf = false
        var priority = false; var recording = false; var comment: String?

        for f in fields {
            switch f.field {
            case  1: if case .varint(let v) = f.val { session   = UInt32(v) }
            case  3: if case .bytes(let d)  = f.val { name      = str(d) }
            case  5: if case .varint(let v) = f.val { cid       = UInt32(v) }
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
            u.currentChannelId  = Int32(cid)
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
            u.currentChannelId  = Int32(cid)
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
            if let ch = channels.first(where: { $0.channelId == Int32(cid) }) {
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
        let sender = actor
            .flatMap { id in users.first { $0.userId == Int32(id) }?.name }
            ?? "Server"
        chatMessages.append(ChatMessage(id: UUID(), content: text, sender: sender,
                                        timestamp: Date(), type: .text))
    }

    private func onCryptSetup(_ payload: Data) {
        // The server sends OCB2-AES128 keys for encrypted UDP audio.
        // We tunnel audio over TCP (UDPTunnel type 1) to avoid needing OCB2.
        print("[Mumble] CryptSetup received (audio via TCP tunnel)")
    }

    /// Handle incoming UDPTunnel (type 1) audio packets from the server.
    /// Mumble audio packet inside UDPTunnel:
    ///   [1-byte header] = (codec << 5) | target
    ///   Mumble VarInt: sequence number
    ///   Mumble VarInt: length (with optional end-of-transmission bit 13)
    ///   [opus bytes]
    private func onUDPTunnel(_ payload: Data) {
        guard payload.count > 1 else { return }
        let header = payload[0]
        let codec  = (header >> 5) & 0x07   // 4 = Opus
        guard codec == 4 else { return }    // ignore non-Opus

        var pos = 1
        // Read Mumble VarInt for sequence
        guard let (_, seqLen) = readMumbleVarInt(payload, at: pos) else { return }
        pos += seqLen
        // Read Mumble VarInt for length (bit 13 = end-of-transmission flag)
        guard let (rawLen, lenLen) = readMumbleVarInt(payload, at: pos) else { return }
        pos += lenLen
        let opusLen = Int(rawLen & ~(1 << 13))   // strip end-of-stream bit
        guard opusLen > 0, pos + opusLen <= payload.count else { return }

        let opusBytes = payload.subdata(in: pos..<(pos + opusLen))
        decodeAndPlay(opusBytes)
    }

    private func decodeAndPlay(_ opusBytes: Data) {
        guard !isDeafened, let decoder = opusDecoder,
              let player = playerNode, let engine = audioEngine,
              engine.isRunning else { return }
        do {
            let pcm = try decoder.decode(opusBytes)
            player.scheduleBuffer(pcm, completionHandler: nil)
            if !player.isPlaying { player.play() }
        } catch {
            print("[Audio] Decode error: \(error)")
        }
    }

    private func onServerConfig(_ payload: Data) {
        for f in decodeProto(payload) {
            if f.field == 2, case .bytes(let d) = f.val {
                let txt = str(d)
                if !txt.isEmpty { print("[Mumble] ServerConfig: \(txt.prefix(120))") }
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
        // Version message (Mumble.proto type 0)
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
        var p = Data()
        p.pbUInt32(field: 3, value: target)   // channel_id
        p.pbString(field: 5, value: message)  // message text
        sendFrame(type: 11, payload: p)

        // Optimistic local echo.
        let me = users.first { $0.userId == Int32(sessionId) }?.name ?? username
        chatMessages.append(ChatMessage(id: UUID(), content: message, sender: me,
                                        timestamp: Date(), type: .text))
    }

    // MARK: - Mute / Deafen

    func toggleMute() {
        isMuted.toggle()
        sendUserState(selfMute: isMuted, selfDeaf: isDeafened)
        // Tap callback already checks isMuted before encoding, so no extra work.
        if isMuted { isSpeaking = false; audioInputLevel = 0.0 }
    }

    func toggleDeafen() {
        isDeafened.toggle()
        if isDeafened { isMuted = true }
        sendUserState(selfMute: isMuted, selfDeaf: isDeafened)
        // Player volume: mute output when deafened
        playerNode?.volume = isDeafened ? 0.0 : 1.0
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

    /// Decode a Mumble VarInt from `data` at byte offset `at`.
    /// Returns (value, bytesConsumed) or nil on underflow.
    private func readMumbleVarInt(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let b0 = data[offset]
        if b0 & 0x80 == 0 {
            return (UInt64(b0), 1)
        } else if b0 & 0xC0 == 0x80 {
            guard offset + 1 < data.count else { return nil }
            let val = (UInt64(b0 & 0x3F) << 8) | UInt64(data[offset + 1])
            return (val, 2)
        } else if b0 & 0xE0 == 0xC0 {
            guard offset + 2 < data.count else { return nil }
            let val = (UInt64(b0 & 0x1F) << 16) | (UInt64(data[offset+1]) << 8) | UInt64(data[offset+2])
            return (val, 3)
        } else if b0 & 0xF0 == 0xE0 {
            guard offset + 3 < data.count else { return nil }
            let val = (UInt64(b0 & 0x0F) << 24) | (UInt64(data[offset+1]) << 16)
                    | (UInt64(data[offset+2]) << 8) | UInt64(data[offset+3])
            return (val, 4)
        }
        // For our purposes (sequence numbers / lengths) 4 bytes is sufficient.
        return nil
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        // 15-second interval matches the Rust implementation default.
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendPing() }
        }
    }

    private func sendPing() {
        var p = Data()
        p.pbUInt64(field: 1, value: UInt64(Date().timeIntervalSince1970 * 1000))
        sendFrame(type: 3, payload: p)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Audio engine (Opus via TCP UDPTunnel)
    // ─────────────────────────────────────────────────────────────────────────

    func setupAudioEngine() {
        guard audioEngine == nil else { return }
        let application: Opus.Application = opusLowDelay ? .restrictedLowDelay : .voip
        do {
            opusEncoder = try Opus.Encoder(format: opusFormat, application: application)
            opusDecoder = try Opus.Decoder(format: opusFormat)
        } catch {
            print("[Audio] Failed to create Opus codec: \(error)"); return
        }
        // Capture raw encoder pointer for ctl calls by creating our own
        // (same args) — shares the underlying C state initialisation path.
        var errCode: Int32 = 0
        opusEncoderPtr = RealMumbleClient.opus_encoder_create_raw(
            48000, 1, application.rawValue, &errCode
        )
        applyEncoderSettings()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: opusFormat)

        let inputNode  = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Build a single reusable converter from hardware format → 48 kHz mono float32.
        guard let converter = AVAudioConverter(from: inputFormat, to: opusFormat) else {
            print("[Audio] Cannot create converter \(inputFormat) → \(opusFormat)"); return
        }
        opusConverter = converter

        inputNode.installTap(onBus: 0,
                             bufferSize: opusFrameSize,
                             format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isMuted, self.isConnected else { return }
                self.encodeAndSend(buffer)
            }
        }

        audioEngine = engine
        playerNode  = player

        // Apply user-selected devices (must be before engine.start)
        applyAudioDevices(to: engine)
    }

    func startAudioEngine() {
        guard let engine = audioEngine, !engine.isRunning else { return }
        do {
            try engine.start()
            print("[Audio] Engine started")
        } catch {
            print("[Audio] Engine start error: \(error)")
        }
    }

    func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine    = nil
        playerNode     = nil
        opusEncoder    = nil
        opusDecoder    = nil
        opusConverter  = nil
        if let ptr = opusEncoderPtr { RealMumbleClient.opus_encoder_destroy_raw(ptr) }
        opusEncoderPtr = nil
        print("[Audio] Engine stopped")
    }

    func setOutputVolume(_ volume: Float) {
        playerNode?.volume = max(0, min(1, volume))
    }

    // opus_encoder_ctl / opus_encoder_create / opus_encoder_destroy are C
    // variadic or otherwise need re-declaration for Swift access.
    @_silgen_name("opus_encoder_create")
    private static func opus_encoder_create_raw(
        _ sampleRate: Int32, _ channels: Int32,
        _ application: Int32, _ error: UnsafeMutablePointer<Int32>
    ) -> OpaquePointer

    @_silgen_name("opus_encoder_destroy")
    private static func opus_encoder_destroy_raw(_ enc: OpaquePointer)

    @_silgen_name("opus_encoder_ctl")
    private static func opus_encoder_ctl_int(
        _ enc: OpaquePointer, _ req: Int32, _ val: Int32
    ) -> Int32

    private func applyEncoderSettings() {
        guard let ptr = opusEncoderPtr else { return }
        // OPUS_SET_BITRATE_REQUEST = 4002
        let r = Self.opus_encoder_ctl_int(ptr, 4002, Int32(opusBitrate))
        print("[Audio] Set bitrate \(opusBitrate / 1000) kbps → \(r == 0 ? "ok" : "err \(r)")")
    }
    private func applyAudioDevices(to engine: AVAudioEngine) {
        if inputDeviceUID != "Default", !inputDeviceUID.isEmpty,
           let dev = listAudioDevices(input: true).first(where: { $0.uid == inputDeviceUID }),
           let au = engine.inputNode.audioUnit {
            var devID = dev.id
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            print("[Audio] Input device → \(dev.name)")
        }
        if outputDeviceUID != "Default", !outputDeviceUID.isEmpty,
           let dev = listAudioDevices(input: false).first(where: { $0.uid == outputDeviceUID }),
           let au = engine.outputNode.audioUnit {
            var devID = dev.id
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            print("[Audio] Output device → \(dev.name)")
        }
    }

    /// Convert PCM to 48 kHz mono float32, Opus-encode and send over TCP.
    private func encodeAndSend(_ buffer: AVAudioPCMBuffer) {
        guard let converter = opusConverter,
              let converted = AVAudioPCMBuffer(pcmFormat: opusFormat,
                                              frameCapacity: opusFrameSize * 4) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return }

        // RMS level for speaking indicator
        if let ptr = converted.floatChannelData {
            let n = Int(converted.frameLength)
            let rms = (0..<n).reduce(0.0) { $0 + Double(ptr[0][$1]) * Double(ptr[0][$1]) }
            let level = Float(sqrt(rms / Double(max(n, 1))))
            audioInputLevel = min(1.0, level * 8.0)
            isSpeaking      = level > 0.008
        }

        guard let encoder = opusEncoder else { return }
        var encodedBytes = [UInt8](repeating: 0, count: 1276)
        do {
            let encodedLen = try encoder.encode(converted, to: &encodedBytes)
            guard encodedLen > 0 else { return }
            sendAudioFrame(Data(encodedBytes.prefix(encodedLen)))
        } catch {
            print("[Audio] Encode error: \(error)")
        }
    }

    /// Wrap Opus bytes in a Mumble UDPTunnel (type 1) frame and send over TCP.
    private func sendAudioFrame(_ opusData: Data) {
        // Audio header byte: (4 << 5) | 0 = 0x80  (Opus codec, target = normal)
        let headerByte: UInt8 = 0x80
        let seq = audioSequence
        audioSequence &+= 1

        var packet = Data()
        packet.append(headerByte)
        packet.mumbleVarInt(seq)
        // length field: high bit 13 marks end-of-segment (keep 0 for continuous)
        packet.mumbleVarInt(UInt64(opusData.count))
        packet.append(opusData)

        sendFrame(type: 1, payload: packet)

        // Update speaking indicator
        isSpeaking = true
        audioInputLevel = 1.0
    }

    // MARK: - Compat stubs

    /// Channels arrive automatically via ChannelState messages after ServerSync.
    func requestChannelList() { }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Utilities
    // ─────────────────────────────────────────────────────────────────────────

    private func str(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }
}
