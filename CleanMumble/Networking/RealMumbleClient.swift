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

    // MARK: Server capabilities (set from Version message)
    /// `true` once the server has announced version ≥ 1.5; drives audio format choice.
    private var serverUseProtobufAudio: Bool = false

    /// New native CoreAudio (AUHAL) I/O. When non-nil, replaces the
    /// AVAudioEngine-based capture/playback below. Selected via the
    /// `useCoreAudioIO` flag (default ON). Set the env var
    /// `CLEANMUMBLE_LEGACY_AUDIO=1` to opt back into the legacy path.
    private var coreAudioIO: CoreAudioIO?
    private let useCoreAudioIO: Bool = (ProcessInfo.processInfo.environment["CLEANMUMBLE_LEGACY_AUDIO"] != "1")

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var opusEncoder: Opus.Encoder?
    /// Per-speaker Opus decoders, keyed by sender session ID.
    /// Each remote user must have their own decoder context so the LPC
    /// predictor state for one speaker doesn't corrupt another speaker's audio.
    private var opusDecoders: [Int32: Opus.Decoder] = [:]
    /// Per-speaker scheduling state for the playback jitter buffer.
    /// `nextSampleTime` is the sample-time at which the *next* incoming buffer
    /// should be scheduled on the player. Maintaining this per speaker means
    /// late packets from speaker A don't shift speaker B's playback.
    private struct PlayQueue {
        var nextSampleTime: AVAudioFramePosition? = nil
    }
    private var playQueues: [Int32: PlayQueue] = [:]
    /// Initial playback lead used to absorb network jitter (~60 ms = 3 frames@20ms).
    private let jitterLeadSeconds: Double = 0.06
    private var opusConverter: AVAudioConverter?
    private var audioStartAttempts: Int = 0
    private var udpAudioPacketCount: Int = 0
    /// UIDs of preferred audio devices ("Default" = system default).
    var inputDeviceUID:  String = "Default"
    var outputDeviceUID: String = "Default"
    // Opus quality settings (applied on next engine start)
    var opusBitrate:  Int  = 40000   // bits/s
    var opusFrameMs:  Int  = 20      // 10 / 20 / 40 / 60 ms
    var opusLowDelay: Bool = false   // restricted low-delay application mode
    /// VAD trigger threshold as raw RMS (typ. 0.003 … 0.05). Settable from UI.
    var vadThreshold: Float = 0.008
    /// Frame size in samples derived from opusFrameMs (48 kHz).
    private var opusFrameSize: AVAudioFrameCount { AVAudioFrameCount(opusFrameMs * 48) }
    /// Monotonically increasing sequence number for outgoing audio packets.
    private var audioSequence: UInt64 = 0
    /// Timers to reset remote users' isSpeaking after audio stops arriving.
    private var speakingTimers: [Int32: Timer] = [:]
    /// Accumulates 48 kHz mono float32 samples until we have a full Opus frame.
    private var pcmAccumulator: [Float] = []
    /// Diagnostic counter for once-per-second input pipeline tick logging.
    private var diagSampleCounter: Int = 0
    /// Logs the first few render-callback chunks verbatim so we can confirm
    /// the AUHAL is actually delivering buffers (not just "Started").
    private var diagFirstChunks: Int = 8
    /// Counts consecutive silent frames; resets on speech. Used for VAD hold-off.
    private var silenceHoldCount: Int = 0
    /// Number of silent frames to hold before declaring end-of-speech (~300 ms).
    /// Computed from the current Opus frame size so changing quality preset
    /// keeps the hold-off at a constant wall-clock duration.
    private var silenceHoldFrames: Int { max(1, 300 / max(1, opusFrameMs)) }
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
        speakingTimers.values.forEach { $0.invalidate() }
        speakingTimers.removeAll()
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
        serverInfo      = ServerInfo(name: serverHost, version: "1.x", release: "",
                                     os: "", osVersion: "", welcomeText: welcome,
                                     maxBandwidth: Int(maxBW))

        print("[Mumble] ServerSync – session \(session)" +
              (welcome.isEmpty ? "" : ", welcome: \(welcome.prefix(80))"))
        startPingTimer()
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
        // Mumble sends message bodies as HTML; strip tags for plain-text display.
        let display = text.strippingHTML
        guard !display.isEmpty else { return }
        let sender = actor
            .flatMap { id in users.first { $0.userId == Int32(id) }?.name }
            ?? "Server"
        chatMessages.append(ChatMessage(id: UUID(), content: display, sender: sender,
                                        timestamp: Date(), type: .text))
    }

    private func onCryptSetup(_ payload: Data) {
        // The server sends OCB2-AES128 keys for encrypted UDP audio.
        // We tunnel audio over TCP (UDPTunnel type 1) to avoid needing OCB2.
        print("[Mumble] CryptSetup received (audio via TCP tunnel)")
    }

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
        var pos = 1
        guard let (senderSession, sessionLen) = readMumbleVarInt(payload, at: pos) else { return }
        pos += sessionLen
        guard let (_, seqLen) = readMumbleVarInt(payload, at: pos) else { return }
        pos += seqLen
        guard let (rawLen, lenLen) = readMumbleVarInt(payload, at: pos) else { return }
        pos += lenLen
        let isTerminator = (rawLen & (1 << 13)) != 0
        let opusLen = Int(rawLen & ~(1 << 13))
        if isTerminator {
            // Reset only the playback timing, NOT the Opus decoder. Discarding
            // the decoder corrupts LPC predictor warm-up and produces an audible
            // click on the first frame of the next utterance.
            playQueues[Int32(senderSession)] = nil
            return
        }
        guard opusLen > 0, pos + opusLen <= payload.count else { return }
        let opusBytes = payload.subdata(in: pos..<(pos + opusLen))
        markUserSpeaking(Int32(senderSession))
        decodeAndPlay(opusBytes, sender: Int32(senderSession))
    }

    private func parseProtobufUDPAudio(_ payload: Data) {
        // byte 0 = header; bytes 1+ = protobuf MumbleUDP.Audio
        guard payload.count > 1 else { return }
        let protoData = payload.subdata(in: 1..<payload.count)
        var senderSession: UInt32 = 0
        var opusData: Data? = nil
        var isTerminator = false
        for f in decodeProto(protoData) {
            switch f.field {
            case 3: if case .varint(let v) = f.val { senderSession = UInt32(v) }
            case 5: if case .bytes(let d)  = f.val { opusData = d }
            case 8: if case .varint(let v) = f.val { isTerminator = v != 0 }
            default: break
            }
        }
        if isTerminator {
            // Reset only the playback timing, NOT the Opus decoder. Discarding
            // the decoder corrupts LPC predictor warm-up and produces an audible
            // click on the first frame of the next utterance.
            playQueues[Int32(senderSession)] = nil
            return
        }
        guard let opusBytes = opusData, !opusBytes.isEmpty else { return }
        markUserSpeaking(Int32(senderSession))
        decodeAndPlay(opusBytes, sender: Int32(senderSession))
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

    private func decodeAndPlay(_ opusBytes: Data, sender: Int32) {
        guard !isDeafened else {
            if udpAudioPacketCount < 5 { print("[Audio] Skipped decode: deafened") }
            return
        }
        // CoreAudio path: decode → push mono Float32 PCM into the output ring buffer.
        if useCoreAudioIO {
            guard let io = coreAudioIO, io.isRunning else {
                if udpAudioPacketCount < 5 { print("[Audio] Skipped decode: coreAudioIO not running") }
                return
            }
            let decoder: Opus.Decoder
            if let existing = opusDecoders[sender] {
                decoder = existing
            } else {
                guard let fresh = try? Opus.Decoder(format: opusFormat) else { return }
                opusDecoders[sender] = fresh
                decoder = fresh
            }
            do {
                let pcm = try decoder.decode(opusBytes)
                guard let ch = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return }
                io.enqueuePlayback(ch, count: Int(pcm.frameLength))
            } catch {
                print("[Audio] Decode error: \(error)")
            }
            return
        }
        guard let player = playerNode,
              let engine = audioEngine, engine.isRunning else {
            if udpAudioPacketCount < 5 {
                print("[Audio] Skipped decode: player=\(playerNode != nil) engine.isRunning=\(audioEngine?.isRunning ?? false)")
            }
            return
        }
        // Get or create a per-speaker decoder so each user has independent LPC state.
        let decoder: Opus.Decoder
        if let existing = opusDecoders[sender] {
            decoder = existing
        } else {
            guard let fresh = try? Opus.Decoder(format: opusFormat) else { return }
            opusDecoders[sender] = fresh
            decoder = fresh
        }
        do {
            let pcm = try decoder.decode(opusBytes)
            scheduleWithJitter(pcm, on: player, sender: sender)
        } catch {
            print("[Audio] Decode error: \(error)")
        }
    }

    /// Schedule a decoded PCM buffer on the player using a per-speaker jitter
    /// buffer. The first packet of an utterance is scheduled `jitterLeadSeconds`
    /// in the future; subsequent packets are stitched directly onto the end of
    /// the previous one. This eliminates the underrun-clicks that happen when
    /// `scheduleBuffer(_:)` is called with no `at:` time and a packet arrives
    /// even slightly late.
    private func scheduleWithJitter(_ pcm: AVAudioPCMBuffer,
                                    on player: AVAudioPlayerNode,
                                    sender: Int32) {
        let sr = opusFormat.sampleRate
        var queue = playQueues[sender] ?? PlayQueue()

        let scheduledSample: AVAudioFramePosition
        if let next = queue.nextSampleTime {
            // Continuation of an active utterance — append directly.
            scheduledSample = next
        } else {
            // First packet (or first after terminator). Anchor to *now* + lead.
            let nowSample: AVAudioFramePosition
            if let lastRender = player.lastRenderTime,
               let playerTime = player.playerTime(forNodeTime: lastRender) {
                nowSample = playerTime.sampleTime
            } else {
                nowSample = 0
            }
            scheduledSample = nowSample + AVAudioFramePosition(sr * jitterLeadSeconds)
        }

        let when = AVAudioTime(sampleTime: scheduledSample, atRate: sr)
        player.scheduleBuffer(pcm, at: when, options: [], completionHandler: nil)
        queue.nextSampleTime = scheduledSample + AVAudioFramePosition(pcm.frameLength)
        playQueues[sender] = queue
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
        chatMessages.append(ChatMessage(id: UUID(), content: message, sender: me,
                                        timestamp: Date(), type: .text))
    }

    // MARK: - Mute / Deafen

    func toggleMute() {
        isMuted.toggle()
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
        sendUserState(selfMute: isMuted, selfDeaf: isDeafened)
        // Player volume: mute output when deafened
        if useCoreAudioIO {
            coreAudioIO?.output.gain = isDeafened ? 0.0 : 1.0
        } else {
            playerNode?.volume = isDeafened ? 0.0 : 1.0
        }
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
        if useCoreAudioIO {
            setupCoreAudioIO()
            return
        }
        guard audioEngine == nil else { return }
        let application: Opus.Application = opusLowDelay ? .restrictedLowDelay : .voip
        do {
            let encoder = try Opus.Encoder(format: opusFormat, application: application)
            // Apply bitrate / quality knobs via the OpusControl shim. The
            // upstream `swift-opus` only exposes `opus_encoder_create`, so all
            // of these would otherwise be Opus's defaults (auto bitrate,
            // complexity 9, no FEC) regardless of the user's quality preset.
            do {
                try encoder.setSignal(.voice)
                try encoder.setBitrate(Int32(opusBitrate))
                try encoder.setComplexity(opusLowDelay ? 5 : 8)
                try encoder.setVBR(true)
                try encoder.setInbandFEC(true)
                try encoder.setPacketLossPercentage(10)
            } catch {
                print("[Audio] Opus control warning: \(error)")
            }
            opusEncoder = encoder
            print("[Audio] Opus encoder ready (frame=\(opusFrameMs)ms / \(opusFrameSize) samples, bitrate=\(opusBitrate))")
        } catch {
            print("[Audio] Failed to create Opus encoder: \(error)"); return
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // CRITICAL ORDERING:
        //   1. Connect player → mainMixerNode first.
        //      This forces AVAudioEngine to lazily create and fully initialise
        //      both the mainMixerNode AND the output AUHAL (outputNode) with the
        //      current system-default device. Without this, engine.outputNode.audioUnit
        //      is not properly configured and AudioUnitSetProperty for device switching
        //      corrupts the AUHAL's internal device ID to 0, causing outputFormat
        //      to return 0ch/0Hz.
        //   2. THEN call applyAudioDevices to switch to the user-selected devices.
        //      At this point both AUHALs are initialised and can safely change device.
        //   3. Read HW formats — now reflects the switched devices.
        //   4. Build converter + install tap.
        //
        // We deliberately do NOT call engine.prepare() here — engine.start()
        // performs preparation implicitly, and an explicit prepare() before
        // device switching has been observed to emit -10877 noise and trip
        // -10867 (kAudioUnitErr_CannotDoInCurrentContext) at start().
        let mixer = engine.mainMixerNode        // initialises output AUHAL
        engine.connect(player, to: mixer, format: opusFormat)

        // NOTE: setVoiceProcessingEnabled is intentionally NOT called here.
        // It creates an AUVPAggregate device incompatible with Bluetooth audio
        // (AirPods etc.) — produces mic channel count 0 and cascading -10877 errors.

        applyAudioDevices(to: engine)

        // Use the hardware's native format for the tap — passing a mismatched
        // format crashes with "Failed to create tap due to format mismatch".
        // We convert to 48 kHz mono float32 ourselves inside the tap block.
        let hwFormat   = engine.inputNode.outputFormat(forBus: 0)
        let outHwFmt   = engine.outputNode.outputFormat(forBus: 0)
        print("[Audio] Input HW format: \(hwFormat) | Output HW format: \(outHwFmt)")

        // Both formats must be valid. The output format goes 0ch/0Hz when a
        // Bluetooth device (e.g. AirPods) hasn't finished connecting to CoreAudio
        // yet — which is the common case right after a Settings change.
        let inputReady  = hwFormat.sampleRate > 0 && hwFormat.channelCount > 0
        let outputReady = outHwFmt.sampleRate > 0 && outHwFmt.channelCount > 0
        guard inputReady, outputReady else {
            // The HAL hasn't published its format yet (common right after a device
            // switch). Tear down the half-built engine and retry shortly so we
            // don't leave audioEngine == nil with no scheduled recovery.
            let missing = !inputReady ? "Input" : "Output"
            print("[Audio] \(missing) HW format not ready yet — retrying in 0.5s")
            engine.stop()
            opusEncoder = nil
            audioStartAttempts += 1
            guard audioStartAttempts <= 5 else {
                print("[Audio] Giving up on HW format after \(audioStartAttempts) attempts")
                audioStartAttempts = 0
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.isConnected else { return }
                self.setupAudioEngine()
                self.startAudioEngine()
            }
            return
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: opusFormat) else {
            print("[Audio] Cannot create converter \(hwFormat) → \(opusFormat)"); return
        }
        opusConverter = converter

        engine.inputNode.installTap(onBus: 0,
                                    bufferSize: 4096,
                                    format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Allocate enough output frames for the sample-rate ratio.
            let ratio = 48000.0 / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
            guard let converted = AVAudioPCMBuffer(pcmFormat: self.opusFormat,
                                                   frameCapacity: outCapacity) else { return }
            var convError: NSError?
            var inputConsumed = false
            converter.convert(to: converted, error: &convError) { _, outStatus in
                if inputConsumed { outStatus.pointee = .noDataNow; return nil }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard convError == nil, converted.frameLength > 0,
                  let channelData = converted.floatChannelData else { return }
            let count = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))
            Task { @MainActor [weak self] in
                self?.processSamples(samples)
            }
        }

        pcmAccumulator = []
        audioEngine = engine
        playerNode  = player
    }

    func startAudioEngine() {
        if useCoreAudioIO {
            // CoreAudioIO is started inside setupCoreAudioIO; nothing to do.
            return
        }
        guard let engine = audioEngine, !engine.isRunning else { return }
        do {
            try engine.start()
            audioStartAttempts = 0
            playerNode?.play()
            print("[Audio] Engine started")
        } catch {
            audioStartAttempts += 1
            guard audioStartAttempts <= 3 else {
                print("[Audio] Engine start giving up after \(audioStartAttempts) attempts: \(error)")
                print("[Audio] Most likely causes: another app holds exclusive mic access (Zoom/Discord/Teams), the input device was unplugged, or a kernel audio driver issue. Try quitting other audio apps and reconnecting.")
                stopAudioEngine()
                audioStartAttempts = 0
                return
            }
            let delay = pow(2.0, Double(audioStartAttempts - 1))
            print("[Audio] Engine start failed (attempt \(audioStartAttempts)/3), retrying in \(delay)s: \(error)")
            // For format errors (-10875), a simple stop+restart won't help because
            // the invalid device format is baked into the engine graph. Tear down
            // and rebuild the whole graph so applyAudioDevices re-runs after the
            // Bluetooth device finishes connecting.
            let isFormatError = (error as NSError).code == -10875
            tearDownAudioEngineKeepingRetryState()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isConnected else {
                    self?.audioStartAttempts = 0
                    return
                }
                if isFormatError {
                    self.setupAudioEngine()
                }
                self.startAudioEngine()
            }
        }
    }

    /// Internal helper: tear down the engine but preserve the retry counter
    /// so `startAudioEngine` can actually give up after N tries.
    private func tearDownAudioEngineKeepingRetryState() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine    = nil
        playerNode     = nil
        opusEncoder    = nil
        opusDecoders   = [:]
        playQueues     = [:]
        opusConverter  = nil
        pcmAccumulator = []
        silenceHoldCount = 0
    }

    func stopAudioEngine() {
        if useCoreAudioIO {
            coreAudioIO?.stop()
            coreAudioIO = nil
            opusEncoder = nil
            opusDecoders = [:]
            pcmAccumulator = []
            silenceHoldCount = 0
            print("[Audio] CoreAudioIO stopped")
            return
        }
        tearDownAudioEngineKeepingRetryState()
        audioStartAttempts = 0
        print("[Audio] Engine stopped")
    }

    // MARK: - CoreAudioIO path

    /// Build the Opus encoder + start native CoreAudio capture/playback.
    private func setupCoreAudioIO() {
        // Reuse: if already running with the same UIDs, do nothing.
        if let existing = coreAudioIO,
           existing.isRunning,
           existing.inputDeviceUID == inputDeviceUID,
           existing.outputDeviceUID == outputDeviceUID {
            return
        }
        // Tear down anything in flight.
        coreAudioIO?.stop()
        coreAudioIO = nil
        // Re-arm input pipeline diagnostics for the new session.
        diagFirstChunks = 8
        diagSampleCounter = 0

        // Opus encoder (same configuration as legacy path).
        let application: Opus.Application = opusLowDelay ? .restrictedLowDelay : .voip
        do {
            let encoder = try Opus.Encoder(format: opusFormat, application: application)
            do {
                try encoder.setSignal(.voice)
                try encoder.setBitrate(Int32(opusBitrate))
                try encoder.setComplexity(opusLowDelay ? 5 : 8)
                try encoder.setVBR(true)
                try encoder.setInbandFEC(true)
                try encoder.setPacketLossPercentage(10)
            } catch {
                print("[Audio] Opus control warning: \(error)")
            }
            opusEncoder = encoder
            print("[Audio] (CoreAudioIO) Opus encoder ready (frame=\(opusFrameMs)ms / \(opusFrameSize) samples, bitrate=\(opusBitrate))")
        } catch {
            print("[Audio] (CoreAudioIO) Failed to create Opus encoder: \(error)"); return
        }

        let io = CoreAudioIO()
        io.inputDeviceUID  = inputDeviceUID
        io.outputDeviceUID = outputDeviceUID
        io.output.gain     = isDeafened ? 0.0 : 1.0

        // Realtime input callback: copy samples out and dispatch to MainActor
        // for protobuf/Opus processing on the existing path.
        io.input.onSamples = { [weak self] ptr, n in
            guard n > 0 else { return }
            let buf = UnsafeBufferPointer(start: ptr, count: n)
            let samples = Array(buf)
            Task { @MainActor [weak self] in
                self?.processSamples(samples)
            }
        }

        io.start()
        coreAudioIO = io
        pcmAccumulator = []
        silenceHoldCount = 0
    }

    func setOutputVolume(_ volume: Float) {
        let v = max(0, min(1, volume))
        if useCoreAudioIO {
            coreAudioIO?.output.gain = v
            return
        }
        playerNode?.volume = v
    }

    private func applyAudioDevices(to engine: AVAudioEngine) {
        if inputDeviceUID != "Default", !inputDeviceUID.isEmpty,
           let dev = listAudioDevices(input: true).first(where: { $0.uid == inputDeviceUID }),
           let au = engine.inputNode.audioUnit {
            var devID = dev.id
            let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr { print("[Audio] Input device → \(dev.name)") }
            else { print("[Audio] Failed to switch input device → \(dev.name): OSStatus \(status)") }
        }
        if outputDeviceUID != "Default", !outputDeviceUID.isEmpty,
           let dev = listAudioDevices(input: false).first(where: { $0.uid == outputDeviceUID }),
           let au = engine.outputNode.audioUnit {
            var devID = dev.id
            let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0,
                                              &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr { print("[Audio] Output device → \(dev.name)") }
            else {
                print("[Audio] Failed to switch output device → \(dev.name): OSStatus \(status)")
                // A failed AudioUnitSetProperty corrupts the AUHAL's internal device
                // reference, leaving outputNode.outputFormat at 0ch/0Hz and making
                // engine.start() fail. Reset explicitly to the system-default output
                // device so the AUHAL is in a clean state and the engine can start.
                // Audio will route through the system default until the Bluetooth
                // device finishes connecting and the user re-applies settings.
                var defaultID = AudioDeviceID(0)
                var sz   = UInt32(MemoryLayout<AudioDeviceID>.size)
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                    mScope:    kAudioObjectPropertyScopeGlobal,
                    mElement:  kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                              &addr, 0, nil, &sz, &defaultID) == noErr,
                   defaultID != 0 {
                    AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                        kAudioUnitScope_Global, 0,
                                        &defaultID, UInt32(MemoryLayout<AudioDeviceID>.size))
                    print("[Audio] Output reset to system default (Bluetooth not yet ready)")
                }
            }
        }
    }

    /// Reflect the local user's speaking state into the users array so the UI ring updates.
    private func setLocalUserSpeaking(_ speaking: Bool) {
        guard sessionId != 0,
              let i = users.firstIndex(where: { $0.userId == Int32(sessionId) }) else { return }
        users[i].isSpeaking = speaking
    }

    /// Accumulate samples and encode one Opus frame (exactly opusFrameSize) at a time.
    private func processSamples(_ samples: [Float]) {
        // Diagnostic: log the first few callbacks so we know the input pipeline
        // is alive end-to-end, then drop to once-per-second.
        if diagFirstChunks > 0 {
            diagFirstChunks -= 1
            var sum: Double = 0
            for s in samples { sum += Double(s) * Double(s) }
            let lvl = Float(sqrt(sum / Double(max(samples.count, 1))))
            print(String(format: "[Audio][DIAG] first-chunk: %d samples, RMS=%.5f, isMuted=%@, isConnected=%@",
                         samples.count, lvl,
                         isMuted ? "Y" : "N",
                         isConnected ? "Y" : "N"))
        }
        diagSampleCounter += samples.count
        if diagSampleCounter >= 48_000 {
            let n = samples.count
            var sum: Double = 0
            for s in samples { sum += Double(s) * Double(s) }
            let lvl = Float(sqrt(sum / Double(max(n, 1))))
            print(String(format: "[Audio][DIAG] tick: %d samples last chunk, RMS=%.5f, isMuted=%@, isConnected=%@, vadThr=%.4f",
                         n, lvl,
                         isMuted ? "Y" : "N",
                         isConnected ? "Y" : "N",
                         vadThreshold))
            diagSampleCounter = 0
        }
        guard !isMuted, isConnected else {
            audioInputLevel = 0
            if isSpeaking {
                isSpeaking = false
                setLocalUserSpeaking(false)
            }
            return
        }
        pcmAccumulator.append(contentsOf: samples)
        let frameSize = Int(opusFrameSize)
        while pcmAccumulator.count >= frameSize {
            let frame = Array(pcmAccumulator.prefix(frameSize))
            pcmAccumulator.removeFirst(frameSize)
            encodeFrame(frame)
        }
    }

    /// Opus-encode exactly opusFrameSize samples and send over TCP.
    private func encodeFrame(_ samples: [Float]) {
        // RMS-based voice activity detection with hold-off to avoid clipping
        // the ends of words.  Speech is active while level > threshold OR while
        // we are within silenceHoldFrames frames of the last active frame.
        let rms = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        let level = Float(sqrt(rms / Double(samples.count)))
        audioInputLevel = min(1.0, level * 8.0)

        if level > vadThreshold {
            silenceHoldCount = silenceHoldFrames
        } else if silenceHoldCount > 0 {
            silenceHoldCount -= 1
        }
        let nowSpeaking = silenceHoldCount > 0

        if nowSpeaking != isSpeaking {
            isSpeaking = nowSpeaking
            setLocalUserSpeaking(nowSpeaking)
            print("[Audio] Local speaking=\(nowSpeaking) level=\(String(format: "%.4f", level))")
            if nowSpeaking {
                // Reset the audio sequence at the start of each utterance so
                // remote clients see a clean monotonic stream per stream.
                audioSequence = 0
            } else {
                // Notify the server (and remote decoders) that this utterance ended.
                sendTerminator()
                return
            }
        }

        // Skip encoding and sending silence
        guard isSpeaking, let encoder = opusEncoder else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: opusFormat,
                                              frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf in
            pcmBuffer.floatChannelData?[0].initialize(from: buf.baseAddress!, count: samples.count)
        }

        var encodedBytes = [UInt8](repeating: 0, count: 1276)
        do {
            let encodedLen = try encoder.encode(pcmBuffer, to: &encodedBytes)
            guard encodedLen > 0 else { return }
            sendAudioFrame(Data(encodedBytes.prefix(encodedLen)))
        } catch {
            print("[Audio] Encode error: \(error)")
        }
    }

    /// Wrap Opus bytes in a Mumble UDPTunnel (type 1) frame and send over TCP.
    /// Uses protobuf v2 format when the server is Mumble ≥ 1.5, legacy otherwise.
    private func sendAudioFrame(_ opusData: Data) {
        let seq = audioSequence
        audioSequence &+= 1

        var packet = Data()
        if serverUseProtobufAudio {
            // Protobuf v2: 1-byte header + MumbleUDP.Audio protobuf payload
            // header: (0 << 5) | 0 = type=Protobuf (0), target=normal (0)
            packet.append(UInt8(0x00))
            var proto = Data()
            proto.pbUInt32(field: 1, value: 0)        // target = normal speech
            proto.pbUInt64(field: 4, value: seq)      // frame_number
            proto.pbBytes(field: 5, value: opusData)  // opus_data
            packet.append(proto)
        } else {
            // Legacy: (4 << 5) | 0 = type=Opus (4), target=normal (0)
            packet.append(UInt8(0x80))
            packet.mumbleVarInt(seq)
            packet.mumbleVarInt(UInt64(opusData.count))
            packet.append(opusData)
        }

        sendFrame(type: 1, payload: packet)

        isSpeaking = true
        audioInputLevel = 1.0
    }

    /// Send an end-of-speech (terminator) packet to the server.
    /// This lets remote Mumble clients reset their decoder state cleanly and
    /// hides the speaking indicator immediately rather than timing out.
    private func sendTerminator() {
        let seq = audioSequence
        audioSequence &+= 1
        var packet = Data()
        if serverUseProtobufAudio {
            packet.append(UInt8(0x00))
            var proto = Data()
            proto.pbUInt32(field: 1, value: 0)     // target = normal speech
            proto.pbUInt64(field: 4, value: seq)   // frame_number
            proto.pbBool(field: 8, value: true)    // is_terminator
            packet.append(proto)
        } else {
            packet.append(UInt8(0x80))
            packet.mumbleVarInt(seq)
            // Length varint with bit 13 set = end-of-stream; no Opus data follows.
            packet.mumbleVarInt(UInt64(1 << 13))
        }
        sendFrame(type: 1, payload: packet)
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
