//
//  VoiceTransportTests.swift
//  CleanMumbleTests
//
//  Wire-format tests for the voice TX path: the packets VoiceTX builds must
//  be exactly what Mumble servers (and our own RX parser) expect, in both
//  protobuf (≥1.5) and legacy framing. A framing regression here would break
//  outgoing voice against every server, so it gets golden-byte coverage.
//

import XCTest
@testable import CleanMumble

final class VoiceTransportTests: XCTestCase {

    // MARK: - Protobuf (Mumble ≥ 1.5) framing

    func testProtobufVoicePacket() {
        let opus = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packet = VoiceTX.buildPacket(opus: opus, seq: 7,
                                         isTerminator: false, protobuf: true)
        // Header byte 0x00 = MumbleUDP Audio.
        XCTAssertEqual(packet.first, 0x00)

        var target: UInt64?
        var frameNumber: UInt64?
        var opusData: Data?
        var terminator = false
        // Data slices keep their parent's indices; rebase before decoding.
        for f in decodeProto(Data(packet.dropFirst())) {
            switch f.field {
            case 1: if case .varint(let v) = f.val { target = v }
            case 4: if case .varint(let v) = f.val { frameNumber = v }
            case 5: if case .bytes(let d) = f.val { opusData = d }
            case 8: if case .varint(let v) = f.val { terminator = v != 0 }
            default: XCTFail("unexpected field \(f.field)")
            }
        }
        XCTAssertEqual(target, 0)
        XCTAssertEqual(frameNumber, 7)
        XCTAssertEqual(opusData, opus)
        XCTAssertFalse(terminator)
    }

    func testProtobufTerminatorPacket() {
        let packet = VoiceTX.buildPacket(opus: Data(), seq: 42,
                                         isTerminator: true, protobuf: true)
        XCTAssertEqual(packet.first, 0x00)
        var terminator = false
        var hasOpusField = false
        for f in decodeProto(Data(packet.dropFirst())) {
            if f.field == 8, case .varint(let v) = f.val { terminator = v != 0 }
            if f.field == 5 { hasOpusField = true }
        }
        XCTAssertTrue(terminator)
        XCTAssertFalse(hasOpusField, "terminator must not carry opus_data")
    }

    // MARK: - Legacy framing

    /// Decode a Mumble VarInt (the audio-header encoding, not LEB-128).
    private func readMumbleVarInt(_ data: [UInt8], at pos: Int) -> (value: UInt64, len: Int)? {
        guard pos < data.count else { return nil }
        let b = data[pos]
        if b & 0x80 == 0 { return (UInt64(b), 1) }
        if b & 0xC0 == 0x80 {
            guard pos + 1 < data.count else { return nil }
            return (UInt64(b & 0x3F) << 8 | UInt64(data[pos + 1]), 2)
        }
        if b & 0xE0 == 0xC0 {
            guard pos + 2 < data.count else { return nil }
            return (UInt64(b & 0x1F) << 16 | UInt64(data[pos + 1]) << 8
                    | UInt64(data[pos + 2]), 3)
        }
        if b & 0xF0 == 0xE0 {
            guard pos + 3 < data.count else { return nil }
            return (UInt64(b & 0x0F) << 24 | UInt64(data[pos + 1]) << 16
                    | UInt64(data[pos + 2]) << 8 | UInt64(data[pos + 3]), 4)
        }
        return nil
    }

    func testLegacyVoicePacket() {
        let opus = Data([0x01, 0x02, 0x03])
        let packet = [UInt8](VoiceTX.buildPacket(opus: opus, seq: 5,
                                                 isTerminator: false, protobuf: false))
        // Header: type Opus (4) << 5, target 0.
        XCTAssertEqual(packet[0], 0x80)
        var pos = 1
        guard let (seq, seqLen) = readMumbleVarInt(packet, at: pos) else {
            return XCTFail("bad seq varint")
        }
        XCTAssertEqual(seq, 5)
        pos += seqLen
        guard let (rawLen, lenLen) = readMumbleVarInt(packet, at: pos) else {
            return XCTFail("bad length varint")
        }
        XCTAssertEqual(rawLen & (1 << 13), 0, "terminator bit must be clear")
        XCTAssertEqual(Int(rawLen & ~(1 << 13)), opus.count)
        pos += lenLen
        XCTAssertEqual(Array(packet[pos...]), [UInt8](opus))
    }

    // MARK: - Loopback (voice target 31, echo test)

    func testProtobufLoopbackTarget() {
        let packet = VoiceTX.buildPacket(opus: Data([0xAA]), seq: 3,
                                         isTerminator: false, protobuf: true,
                                         target: 31)
        XCTAssertEqual(packet.first, 0x00)
        var target: UInt64?
        for f in decodeProto(Data(packet.dropFirst())) where f.field == 1 {
            if case .varint(let v) = f.val { target = v }
        }
        XCTAssertEqual(target, 31, "loopback packets must carry target 31")
    }

    func testLegacyLoopbackTargetInHeader() {
        let packet = [UInt8](VoiceTX.buildPacket(opus: Data([0xAA]), seq: 3,
                                                 isTerminator: false, protobuf: false,
                                                 target: 31))
        // Opus (4) << 5 | target 31 = 0x9F.
        XCTAssertEqual(packet[0], 0x9F)
    }

    func testDefaultTargetIsNormalSpeech() {
        let legacy = [UInt8](VoiceTX.buildPacket(opus: Data([1]), seq: 1,
                                                 isTerminator: false, protobuf: false))
        XCTAssertEqual(legacy[0] & 0x1F, 0, "default target must be 0")
    }

    func testLegacyTerminatorPacket() {
        let packet = [UInt8](VoiceTX.buildPacket(opus: Data(), seq: 130,
                                                 isTerminator: true, protobuf: false))
        XCTAssertEqual(packet[0], 0x80)
        var pos = 1
        guard let (seq, seqLen) = readMumbleVarInt(packet, at: pos) else {
            return XCTFail("bad seq varint")
        }
        XCTAssertEqual(seq, 130)
        pos += seqLen
        guard let (rawLen, lenLen) = readMumbleVarInt(packet, at: pos) else {
            return XCTFail("bad length varint")
        }
        XCTAssertNotEqual(rawLen & (1 << 13), 0, "terminator bit must be set")
        XCTAssertEqual(pos + lenLen, packet.count, "no payload after terminator")
    }
}
