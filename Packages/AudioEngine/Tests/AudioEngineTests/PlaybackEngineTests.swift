import XCTest
import AVFAudio
import Opus
import OpusControl
@testable import AudioEngine

final class PlaybackEngineTests: XCTestCase {

    private let frameSamples = 960

    private func makeOpusPackets(count: Int, freq: Float = 440) throws -> [Data] {
        let fmt = AVAudioFormat(opusPCMFormat: .float32, sampleRate: 48_000, channels: 1)!
        let enc = try Opus.Encoder(format: fmt, application: .voip)
        try enc.setBitrate(40_000)
        var packets: [Data] = []
        var phase: Float = 0
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameSamples))!
        var bytes = [UInt8](repeating: 0, count: 1_500)
        for _ in 0..<count {
            buf.frameLength = AVAudioFrameCount(frameSamples)
            let p = buf.floatChannelData![0]
            for i in 0..<frameSamples {
                p[i] = sinf(phase) * 0.4
                phase += 2 * .pi * freq / 48_000
            }
            let len = try enc.encode(buf, to: &bytes)
            packets.append(Data(bytes[0..<len]))
        }
        return packets
    }

    /// End to end: submit → decode worker refills → render pull mixes audio.
    func testSubmitToPullProducesAudio() throws {
        let engine = PlaybackEngine()
        engine.start()
        defer { engine.stop() }

        let packets = try makeOpusPackets(count: 20)
        for (i, p) in packets.enumerated() {
            engine.submit(sender: 7, seq: UInt32(i), opus: p, isTerminator: false)
        }

        // Pull like a render callback: 480 frames per 10 ms.
        var out = [Float](repeating: 0, count: 480)
        var energy: Float = 0
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 0.01)
            out.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            energy += out.reduce(0) { $0 + $1 * $1 }
        }
        XCTAssertGreaterThan(energy, 1.0, "decoded far-end audio must reach the mix")
        let stats = engine.snapshotStats()
        XCTAssertGreaterThanOrEqual(stats.played, 15)
    }

    func testDeafenSilencesOutput() throws {
        let engine = PlaybackEngine()
        engine.start()
        defer { engine.stop() }
        engine.isDeafened = true

        let packets = try makeOpusPackets(count: 10)
        for (i, p) in packets.enumerated() {
            engine.submit(sender: 1, seq: UInt32(i), opus: p, isTerminator: false)
        }
        var out = [Float](repeating: 0, count: 480)
        var energy: Float = 0
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.01)
            out.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            energy += out.reduce(0) { $0 + $1 * $1 }
        }
        XCTAssertEqual(energy, 0, "deafened output must be silence")
    }

    func testPerSenderGain() throws {
        let engine = PlaybackEngine()
        engine.start()
        defer { engine.stop() }

        let packets = try makeOpusPackets(count: 20)
        for (i, p) in packets.enumerated() {
            engine.submit(sender: 3, seq: UInt32(i), opus: p, isTerminator: false)
        }
        engine.setSenderGain(3, gain: 0)

        // Let the ramp (5 ms) complete, then measure.
        var out = [Float](repeating: 0, count: 480)
        var tailEnergy: Float = 0
        for pass in 0..<40 {
            Thread.sleep(forTimeInterval: 0.01)
            out.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            if pass > 5 {
                tailEnergy += out.reduce(0) { $0 + $1 * $1 }
            }
        }
        XCTAssertLessThan(tailEnergy, 0.001, "sender gain 0 must mute that sender")
    }

    func testSenderRemovalIsRenderSafe() throws {
        let engine = PlaybackEngine()
        engine.start()
        defer { engine.stop() }

        // Interleave submits, removals and pulls — hunting for crashes /
        // dangling channel pointers in the render cache.
        let packets = try makeOpusPackets(count: 4)
        var out = [Float](repeating: 0, count: 480)
        for round in 0..<50 {
            let sender = Int32(round % 5)
            for (i, p) in packets.enumerated() {
                engine.submit(sender: sender, seq: UInt32(i), opus: p, isTerminator: false)
            }
            out.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            engine.removeSender(sender)
            out.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
        }
        engine.removeAllSenders()
        out.withUnsafeMutableBufferPointer {
            engine.pullMix(into: $0.baseAddress!, frames: 480)
        }
    }
}

final class RampedGainTests: XCTestCase {

    func testRampReachesTargetWithoutJumps() {
        let gain = RampedGain(1.0, rampSeconds: 0.005, sampleRate: 48_000)
        gain.target = 0
        var buf = [Float](repeating: 1, count: 480)   // 10 ms of DC
        buf.withUnsafeMutableBufferPointer { gain.applyInPlace($0.baseAddress!, count: 480) }
        // Monotric decay, no instant jump: first sample near 1, last at 0.
        XCTAssertGreaterThan(buf[0], 0.9)
        XCTAssertEqual(buf[479], 0)
        for i in 1..<480 {
            XCTAssertLessThanOrEqual(buf[i], buf[i - 1] + 1e-6)
        }
        // Steady state afterwards.
        var buf2 = [Float](repeating: 1, count: 64)
        buf2.withUnsafeMutableBufferPointer { gain.applyInPlace($0.baseAddress!, count: 64) }
        XCTAssertEqual(buf2, [Float](repeating: 0, count: 64))
    }

    func testClampsToSafeRange() {
        let gain = RampedGain(1.0)
        gain.target = 100
        XCTAssertEqual(gain.target, 8)
        gain.target = -3
        XCTAssertEqual(gain.target, 0)
    }
}
