import XCTest
import AVFAudio
import Opus
import OpusControl
@testable import AudioEngine

final class NetJitterBufferTests: XCTestCase {

    private let frameSamples = 960   // 20 ms @ 48 kHz

    private func makeOpusPackets(count: Int) throws -> [Data] {
        let fmt = AVAudioFormat(opusPCMFormat: .float32, sampleRate: 48_000, channels: 1)!
        let enc = try Opus.Encoder(format: fmt, application: .voip)
        try enc.setBitrate(40_000)
        try enc.setInbandFEC(true)
        try enc.setPacketLossPercentage(20)
        var packets: [Data] = []
        var phase: Float = 0
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameSamples))!
        var bytes = [UInt8](repeating: 0, count: 1_500)
        for _ in 0..<count {
            buf.frameLength = AVAudioFrameCount(frameSamples)
            let p = buf.floatChannelData![0]
            for i in 0..<frameSamples {
                p[i] = sinf(phase) * 0.4
                phase += 2 * .pi * 440 / 48_000
            }
            let len = try enc.encode(buf, to: &bytes)
            packets.append(Data(bytes[0..<len]))
        }
        return packets
    }

    private func drain(_ jb: NetJitterBuffer, into sink: inout [Float]) {
        var buf = [Float](repeating: 0, count: 4_096)
        while jb.ring.availableToRead > 0 {
            let n = min(4_096, jb.ring.availableToRead)
            buf.withUnsafeMutableBufferPointer {
                _ = jb.ring.read(into: $0.baseAddress!, count: n)
            }
            sink.append(contentsOf: buf[0..<n])
        }
    }

    func testInOrderPlayback() throws {
        let jb = NetJitterBuffer()!
        let packets = try makeOpusPackets(count: 10)
        for (i, p) in packets.enumerated() {
            jb.push(seq: UInt32(i), opus: p)
        }
        // 10 × 20 ms = 200 ms queued ≥ target depth → refill starts at once.
        var sink: [Float] = []
        for _ in 0..<20 {
            jb.refill()
            drain(jb, into: &sink)
        }
        let stats = jb.snapshotAndReset()
        XCTAssertEqual(stats.played, 10)
        XCTAssertEqual(stats.fec, 0)
        XCTAssertEqual(stats.plc, 0)
        XCTAssertEqual(sink.count, 10 * frameSamples)
        // Decoded audio should be non-silent.
        let energy = sink.reduce(Float(0)) { $0 + $1 * $1 }
        XCTAssertGreaterThan(energy, 1.0)
    }

    func testSingleLossRecoveredViaFEC() throws {
        let jb = NetJitterBuffer()!
        let packets = try makeOpusPackets(count: 10)
        for (i, p) in packets.enumerated() where i != 4 {
            jb.push(seq: UInt32(i), opus: p)
        }
        var sink: [Float] = []
        for _ in 0..<20 {
            jb.refill()
            drain(jb, into: &sink)
        }
        let stats = jb.snapshotAndReset()
        XCTAssertEqual(stats.fec, 1, "missing seq 4 should be FEC-recovered from seq 5")
        XCTAssertEqual(stats.played, 9)
        XCTAssertEqual(sink.count, 10 * frameSamples)
    }

    func testLatePacketGapSynthesizedWithPLC() throws {
        let jb = NetJitterBuffer()!
        let packets = try makeOpusPackets(count: 4)
        for (i, p) in packets.enumerated() {
            jb.push(seq: UInt32(i), opus: p)
        }
        var sink: [Float] = []
        for _ in 0..<10 { jb.refill(); drain(jb, into: &sink) }
        XCTAssertEqual(sink.count, 4 * frameSamples)

        // Next expected packet (seq 4) never arrives; once it is stale the
        // buffer conceals to keep playback continuous.
        Thread.sleep(forTimeInterval: 0.05)   // > 1.5 × frame duration
        jb.refill()
        drain(jb, into: &sink)
        let stats = jb.snapshotAndReset()
        XCTAssertGreaterThanOrEqual(stats.plc, 1)
    }

    func testRunawayPLCEndsUtterance() throws {
        let jb = NetJitterBuffer()!
        let packets = try makeOpusPackets(count: 2)
        for (i, p) in packets.enumerated() { jb.push(seq: UInt32(i), opus: p) }
        var sink: [Float] = []
        // Keep draining like a render callback; sender never resumes.
        var iterations = 0
        while jb.isActive && iterations < 200 {
            Thread.sleep(forTimeInterval: 0.01)
            jb.refill()
            drain(jb, into: &sink)
            iterations += 1
        }
        XCTAssertFalse(jb.isActive, "utterance must end after the PLC cap")
        let stats = jb.snapshotAndReset()
        XCTAssertLessThanOrEqual(stats.plc, 26, "PLC must stop at the cap, not run away")
    }

    func testTerminatorResetsCleanly() throws {
        let jb = NetJitterBuffer()!
        let packets = try makeOpusPackets(count: 5)
        for (i, p) in packets.enumerated() { jb.push(seq: UInt32(i), opus: p) }
        jb.reset()
        XCTAssertFalse(jb.isActive)
        jb.refill()
        XCTAssertEqual(jb.ring.availableToRead, 0)
        // A new utterance re-anchors at an arbitrary sequence.
        let more = try makeOpusPackets(count: 5)
        for (i, p) in more.enumerated() { jb.push(seq: UInt32(1000 + i), opus: p) }
        var sink: [Float] = []
        for _ in 0..<10 { jb.refill(); drain(jb, into: &sink) }
        XCTAssertEqual(jb.snapshotAndReset().played, 5)
    }

    func testUnderrunGrowsTargetDepth() throws {
        let jb = NetJitterBuffer()!
        let packets = try makeOpusPackets(count: 3)
        for (i, p) in packets.enumerated() { jb.push(seq: UInt32(i), opus: p) }
        jb.refill()
        let before = jb.targetDepthMs
        // Simulate a render-side underrun: read more than is available.
        var buf = [Float](repeating: 0, count: 48_000)
        buf.withUnsafeMutableBufferPointer {
            _ = jb.ring.read(into: $0.baseAddress!, count: 48_000)
        }
        jb.refill()
        XCTAssertGreaterThan(jb.targetDepthMs, before - 0.001)
        XCTAssertGreaterThanOrEqual(jb.targetDepthMs, before + 10 - 0.001,
                                    "an underrun while anchored should grow the target depth")
    }
}
