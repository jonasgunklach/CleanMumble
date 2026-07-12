//
//  MumbleVoiceParser.swift
//  CleanMumble
//
//  Pure parsing of incoming (server → client) Mumble voice packets, both
//  framings. Extracted from RealMumbleClient so the exact production parse
//  path is unit-testable against packets built by VoiceTX — the wire must be
//  bit-transparent to Opus payloads.
//
//  Server → client packet layouts:
//   Legacy:   [1B header (codec<<5 | target)] [varint sender] [varint seq]
//             [varint opusLen | 1<<13 terminator bit] [opus bytes]
//   Protobuf: [1B 0x00 = MumbleUDP.Audio] [Audio message:
//             3=sender_session 4=frame_number 5=opus_data 8=is_terminator]
//

import Foundation

struct ParsedVoicePacket: Equatable {
    let sender: UInt32
    let seq: UInt32
    /// Empty for terminator packets.
    let opus: Data
    let isTerminator: Bool
}

enum MumbleVoiceParser {

    /// Parse a decrypted voice payload (as delivered via UDP or UDPTunnel).
    /// Returns nil for non-audio or malformed packets.
    static func parse(_ payload: Data) -> ParsedVoicePacket? {
        guard let header = payload.first else { return nil }
        switch (header >> 5) & 0x07 {
        case 4:  return parseLegacy(payload)     // legacy Opus
        case 0:  return parseProtobuf(payload)   // MumbleUDP.Audio (header 0x00)
        default: return nil
        }
    }

    static func parseLegacy(_ payload: Data) -> ParsedVoicePacket? {
        var pos = 1
        guard let (sender, senderLen) = readMumbleVarInt(payload, at: pos) else { return nil }
        pos += senderLen
        guard let (seq, seqLen) = readMumbleVarInt(payload, at: pos) else { return nil }
        pos += seqLen
        guard let (rawLen, lenLen) = readMumbleVarInt(payload, at: pos) else { return nil }
        pos += lenLen
        if rawLen & (1 << 13) != 0 {
            return ParsedVoicePacket(sender: UInt32(truncatingIfNeeded: sender),
                                     seq: UInt32(truncatingIfNeeded: seq),
                                     opus: Data(), isTerminator: true)
        }
        let opusLen = Int(rawLen & ~(1 << 13))
        guard opusLen > 0, pos + opusLen <= payload.count else { return nil }
        return ParsedVoicePacket(sender: UInt32(truncatingIfNeeded: sender),
                                 seq: UInt32(truncatingIfNeeded: seq),
                                 opus: payload.subdata(in: pos..<(pos + opusLen)),
                                 isTerminator: false)
    }

    static func parseProtobuf(_ payload: Data) -> ParsedVoicePacket? {
        guard payload.count > 1 else { return nil }
        var sender: UInt32 = 0
        var seq: UInt32 = 0
        var opus: Data? = nil
        var isTerminator = false
        for f in decodeProto(payload.subdata(in: 1..<payload.count)) {
            switch f.field {
            case 3: if case .varint(let v) = f.val { sender = UInt32(truncatingIfNeeded: v) }
            case 4: if case .varint(let v) = f.val { seq = UInt32(truncatingIfNeeded: v) }
            case 5: if case .bytes(let d)  = f.val { opus = d }
            case 8: if case .varint(let v) = f.val { isTerminator = v != 0 }
            default: break
            }
        }
        if isTerminator {
            return ParsedVoicePacket(sender: sender, seq: seq,
                                     opus: Data(), isTerminator: true)
        }
        guard let opusBytes = opus, !opusBytes.isEmpty else { return nil }
        return ParsedVoicePacket(sender: sender, seq: seq,
                                 opus: opusBytes, isTerminator: false)
    }

    /// Decode a Mumble VarInt from `data` at byte offset `at`.
    /// Returns (value, bytesConsumed) or nil on underflow. 4-byte forms are
    /// sufficient for sessions / sequence numbers / lengths.
    static func readMumbleVarInt(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        guard offset < data.count else { return nil }
        let b0 = data[offset]
        if b0 & 0x80 == 0 {
            return (UInt64(b0), 1)
        } else if b0 & 0xC0 == 0x80 {
            guard offset + 1 < data.count else { return nil }
            return ((UInt64(b0 & 0x3F) << 8) | UInt64(data[offset + 1]), 2)
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
        return nil
    }
}
