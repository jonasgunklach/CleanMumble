//
//  VoiceTransport.swift
//  CleanMumble
//
//  Thread-safe voice transmit path. `CaptureEngine.onPacket` fires on the
//  capture worker thread; this box builds the Mumble voice packet and sends
//  it WITHOUT touching MainActor state — UDP first (OCB2-encrypted), TCP
//  tunnel (UDPTunnel type 1) as automatic fallback. NWConnection.send is
//  thread-safe, so the worker posts frames directly.
//

import Foundation
import Network
import AudioEngine

final class VoiceTX: @unchecked Sendable {

    /// Encrypted UDP voice channel; owned here, keys fed by the client's
    /// CryptSetup handler.
    let udp = MumbleUDPChannel()

    private let lock = NSLock()
    private var connection: NWConnection?
    private var useProtobuf = false
    private var loopback = false
    /// TX diagnostics: log the first packets of a session and a periodic
    /// counter so "am I transmitting?" is answerable from the console.
    private var txCount = 0
    private var txViaUDP = 0

    /// Called on (re)connect and disconnect from the main actor.
    func attach(connection: NWConnection?) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    /// Set once the server's Version message arrives.
    func setProtobufAudio(_ enabled: Bool) {
        lock.lock()
        useProtobuf = enabled
        lock.unlock()
        udp.useProtobufPing = enabled
    }

    /// Echo test: voice target 31 makes the server loop our own audio back —
    /// the only way to verify the transmit path without a second person.
    func setLoopback(_ enabled: Bool) {
        lock.lock()
        loopback = enabled
        lock.unlock()
    }

    /// Build + send one voice packet (any thread). The same packet bytes go
    /// over native UDP when the link is alive, or wrapped in a UDPTunnel TCP
    /// frame otherwise.
    func sendVoicePacket(opus: Data, seq: UInt64, isTerminator: Bool) {
        lock.lock()
        let proto = useProtobuf
        let conn = connection
        let target: UInt8 = loopback ? 31 : 0
        lock.unlock()

        let packet = Self.buildPacket(opus: opus, seq: seq,
                                      isTerminator: isTerminator,
                                      protobuf: proto,
                                      target: target)
        let sentViaUDP = udp.sendVoice(packet)

        lock.lock()
        txCount += 1
        if sentViaUDP { txViaUDP += 1 }
        let n = txCount
        let nUDP = txViaUDP
        lock.unlock()
        if n <= 3 || n % 500 == 0 {
            print("[Audio] TX voice #\(n) (\(opus.count)B, seq \(seq)" +
                  (isTerminator ? ", terminator" : "") +
                  ") via \(sentViaUDP ? "UDP" : "TCP tunnel") — UDP \(nUDP)/\(n)")
        }
        if sentViaUDP { return }

        guard let conn, conn.state == .ready else { return }
        var frame = Data(capacity: 6 + packet.count)
        frame.mumbleHeader(type: 1, length: UInt32(packet.count))
        frame.append(packet)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Mumble voice packet, protobuf (≥1.5) or legacy framing.
    /// `target`: 0 = normal speech, 1–30 = whisper targets, 31 = server
    /// loopback (echo test).
    static func buildPacket(opus: Data, seq: UInt64,
                            isTerminator: Bool, protobuf: Bool,
                            target: UInt8 = 0) -> Data {
        var packet = Data()
        if protobuf {
            packet.append(UInt8(0x00))                    // MumbleUDP: 0 = Audio
            var proto = Data()
            proto.pbUInt32(field: 1, value: UInt32(target))
            proto.pbUInt64(field: 4, value: seq)          // frame_number
            if isTerminator {
                proto.pbBool(field: 8, value: true)       // is_terminator
            } else {
                proto.pbBytes(field: 5, value: opus)      // opus_data
            }
            packet.append(proto)
        } else {
            packet.append(0x80 | (target & 0x1F))         // legacy: Opus (4) << 5 | target
            packet.mumbleVarInt(seq)
            if isTerminator {
                packet.mumbleVarInt(UInt64(1 << 13))      // length varint, bit 13 = end
            } else {
                packet.mumbleVarInt(UInt64(opus.count))
                packet.append(opus)
            }
        }
        return packet
    }
}
