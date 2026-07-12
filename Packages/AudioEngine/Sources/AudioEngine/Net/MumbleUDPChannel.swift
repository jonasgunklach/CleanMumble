//
//  MumbleUDPChannel.swift
//  AudioEngine
//
//  Native encrypted UDP voice channel with automatic liveness tracking.
//  Voice over the TCP tunnel suffers head-of-line blocking (one lost segment
//  stalls every audio packet behind it for ≥ 1 RTT); this channel is the fix.
//
//  Usage contract (mirrors stock Mumble):
//   • Owner feeds CryptSetup material via `handleCryptSetup`.
//   • Channel pings every second once keys are set; a ping echo (or any
//     valid voice packet) marks the link alive. No valid packet for 4 s →
//     dead → owner falls back to the TCP tunnel; probing continues and the
//     link upgrades back automatically.
//   • `sendVoice` returns false when the link isn't usable — the caller
//     sends via the tunnel instead. Same packet bytes either way.
//

import Foundation
import Network
import Synchronization

public final class MumbleUDPChannel: @unchecked Sendable {

    public enum LinkState: String, Sendable {
        case down          // no keys / no socket
        case probing       // keys set, no echo yet
        case alive         // recent valid packet
    }

    /// Decrypted, non-ping packets (voice) — delivered on the channel queue.
    public var onVoicePacket: ((Data) -> Void)?
    /// Link state transitions — delivered on the channel queue.
    public var onLinkStateChange: ((LinkState) -> Void)?
    /// Ask the owner to send a CryptSetup resync request over TCP.
    public var onNeedsResync: (() -> Void)?

    public private(set) var linkState: LinkState = .down {
        didSet {
            if linkState != oldValue { onLinkStateChange?(linkState) }
        }
    }

    /// Protobuf (Mumble ≥ 1.5) vs legacy UDP packet framing for pings.
    public var useProtobufPing = false

    private let queue = DispatchQueue(label: "mumble.udp", qos: .userInitiated)
    private var connection: NWConnection?
    private let crypt = CryptStateOCB2()
    private var pingTimer: DispatchSourceTimer?
    private var lastValidAt: TimeInterval = 0
    private var lastResyncRequestAt: TimeInterval = 0
    private let aliveFlag = Atomic<Bool>(false)

    /// Cheap, thread-safe check for the voice TX hot path.
    public var isAlive: Bool { aliveFlag.load(ordering: .relaxed) }

    /// (good, late, lost) crypt counters for the adaptation loop.
    public func stats() -> (good: UInt32, late: UInt32, lost: UInt32) {
        queue.sync { (crypt.good, crypt.late, crypt.lost) }
    }

    public init() {}

    // MARK: - Lifecycle

    public func start(host: String, port: UInt16) {
        queue.async {
            self.teardown()
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state { self.startPinging() }
            }
            self.connection = conn
            conn.start(queue: self.queue)
            self.receiveLoop(conn)
        }
    }

    public func stop() {
        queue.async { self.teardown() }
    }

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        linkState = .down
        aliveFlag.store(false, ordering: .relaxed)
    }

    // MARK: - CryptSetup plumbing (call from the TCP message handler)

    /// Full setup: key + client_nonce (our encrypt IV) + server_nonce.
    /// Partial setup: server_nonce only (resync response).
    /// Empty setup: the server asks for our client_nonce — returns it so the
    /// owner can reply over TCP.
    @discardableResult
    public func handleCryptSetup(key: [UInt8]?, clientNonce: [UInt8]?,
                                 serverNonce: [UInt8]?) -> [UInt8]? {
        var reply: [UInt8]?
        queue.sync {
            if let key, let clientNonce, let serverNonce {
                _ = crypt.setKey(key, encryptIV: clientNonce, decryptIV: serverNonce)
                if linkState == .down, connection != nil { linkState = .probing }
            } else if let serverNonce {
                _ = crypt.setDecryptIV(serverNonce)
            } else {
                reply = crypt.currentEncryptIV
            }
        }
        return reply
    }

    // MARK: - TX

    /// Encrypt and send one voice packet (the same bytes that would go into
    /// a UDPTunnel frame). Returns false when the link is unusable — caller
    /// falls back to the tunnel.
    @discardableResult
    public func sendVoice(_ packet: Data) -> Bool {
        guard isAlive else { return false }
        queue.async {
            guard let conn = self.connection, self.crypt.isValid else { return }
            if let wire = self.crypt.encrypt([UInt8](packet)) {
                conn.send(content: Data(wire), completion: .contentProcessed { _ in })
            }
        }
        return true
    }

    // MARK: - Ping / liveness

    private func startPinging() {
        guard pingTimer == nil else { return }
        if crypt.isValid, linkState == .down { linkState = .probing }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.pingTick() }
        t.resume()
        pingTimer = t
    }

    private func pingTick() {
        guard let conn = connection, crypt.isValid else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // Liveness bookkeeping.
        let wasAlive = linkState == .alive
        let alive = (now - lastValidAt) < 4.0 && lastValidAt > 0
        if alive != wasAlive {
            linkState = alive ? .alive : .probing
            aliveFlag.store(alive, ordering: .relaxed)
        }

        // Sustained decrypt failure with packets arriving → nonce desync;
        // ask the owner to send a CryptSetup resync (rate-limited).
        if !alive, lastValidAt > 0, now - lastValidAt > 8,
           now - lastResyncRequestAt > 5 {
            lastResyncRequestAt = now
            onNeedsResync?()
        }

        // Ping payload (timestamp echoed by the server).
        let ts = UInt64(now * 1000)
        var plain = [UInt8]()
        if useProtobufPing {
            plain.append(0x01)                       // MumbleUDP: 1 = Ping
            plain.append(contentsOf: protoVarintField(field: 1, value: ts))
        } else {
            plain.append(0x20)                       // legacy: (Ping=1) << 5
            plain.append(contentsOf: mumbleVarint(ts))
        }
        if let wire = crypt.encrypt(plain) {
            conn.send(content: Data(wire), completion: .contentProcessed { _ in })
        }
    }

    // MARK: - RX

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleDatagram([UInt8](data))
            }
            if error == nil, let conn, conn === self.connection {
                self.receiveLoop(conn)
            }
        }
    }

    private func handleDatagram(_ wire: [UInt8]) {
        guard crypt.isValid, let plain = crypt.decrypt(wire), !plain.isEmpty else { return }
        lastValidAt = ProcessInfo.processInfo.systemUptime
        if linkState != .alive {
            linkState = .alive
            aliveFlag.store(true, ordering: .relaxed)
        }
        let header = plain[0]
        let isPing = useProtobufPing ? (header == 0x01) : ((header >> 5) == 1)
        if isPing { return }
        onVoicePacket?(Data(plain))
    }

    // MARK: - Varint helpers

    private func mumbleVarint(_ value: UInt64) -> [UInt8] {
        var out = [UInt8]()
        if value < 0x80 {
            out.append(UInt8(value))
        } else if value < 0x4000 {
            out.append(UInt8(0x80 | (value >> 8)))
            out.append(UInt8(value & 0xFF))
        } else if value < 0x20_0000 {
            out.append(UInt8(0xC0 | (value >> 16)))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        } else if value < 0x1000_0000 {
            out.append(UInt8(0xE0 | (value >> 24)))
            out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF))
            out.append(UInt8(value & 0xFF))
        } else {
            out.append(0xF4)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
        return out
    }

    private func protoVarintField(field: UInt32, value: UInt64) -> [UInt8] {
        var out = [UInt8]()
        out.append(UInt8((field << 3) | 0))          // wire type 0 = varint
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
}
