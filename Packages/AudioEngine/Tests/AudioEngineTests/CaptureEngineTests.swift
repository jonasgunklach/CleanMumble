import XCTest
@testable import AudioEngine

final class CaptureEngineTests: XCTestCase {

    /// Feed a loud sine at 48 kHz → expect Opus packets and a speaking=true
    /// transition; feed silence → expect a terminator and speaking=false.
    func testVoiceGatedEncoding() {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = 0.01

        let gotPackets = expectation(description: "packets")
        gotPackets.assertForOverFulfill = false
        let gotTerminator = expectation(description: "terminator")
        gotTerminator.assertForOverFulfill = false
        let spokeUp = expectation(description: "speaking true")
        spokeUp.assertForOverFulfill = false
        let wentQuiet = expectation(description: "speaking false")
        wentQuiet.assertForOverFulfill = false

        var packetCount = 0
        let countLock = NSLock()
        engine.onPacket = { data, _, isTerminator in
            if isTerminator {
                gotTerminator.fulfill()
            } else if !data.isEmpty {
                countLock.lock(); packetCount += 1; countLock.unlock()
                gotPackets.fulfill()
            }
        }
        engine.onSpeakingChanged = { speaking in
            if speaking { spokeUp.fulfill() } else { wentQuiet.fulfill() }
        }

        engine.start(sourceRate: 48_000, format: CaptureFormat())
        defer { engine.stop() }

        // 1 s of 440 Hz sine at amplitude 0.3, in 10 ms chunks.
        var phase: Float = 0
        var chunk = [Float](repeating: 0, count: 480)
        for _ in 0..<100 {
            for i in 0..<480 {
                chunk[i] = sinf(phase) * 0.3
                phase += 2 * .pi * 440 / 48_000
            }
            chunk.withUnsafeBufferPointer { engine.ingest($0.baseAddress!, count: 480) }
            Thread.sleep(forTimeInterval: 0.002)
        }
        wait(for: [spokeUp, gotPackets], timeout: 5)

        // 1 s of silence → VAD hangover (~300 ms) then terminator.
        chunk = [Float](repeating: 0, count: 480)
        for _ in 0..<100 {
            chunk.withUnsafeBufferPointer { engine.ingest($0.baseAddress!, count: 480) }
            Thread.sleep(forTimeInterval: 0.002)
        }
        wait(for: [wentQuiet, gotTerminator], timeout: 5)

        countLock.lock()
        let n = packetCount
        countLock.unlock()
        // ~1 s of speech at 20 ms frames ≈ 50 packets; allow slack for the
        // hangover and chunk boundaries.
        XCTAssertGreaterThan(n, 30)
        XCTAssertLessThan(n, 80)
    }

    /// Feeding at 24 kHz must transparently resample: same wall-clock second
    /// of audio → the same ~50 packets.
    func testResamplingFrom24kHz() {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = 0.01

        let gotPackets = expectation(description: "packets")
        gotPackets.assertForOverFulfill = false
        var packetCount = 0
        let countLock = NSLock()
        engine.onPacket = { data, _, isTerminator in
            guard !isTerminator else { return }
            countLock.lock(); packetCount += 1; countLock.unlock()
            gotPackets.fulfill()
        }

        engine.start(sourceRate: 24_000, format: CaptureFormat())
        defer { engine.stop() }

        var phase: Float = 0
        var chunk = [Float](repeating: 0, count: 240)   // 10 ms @ 24 kHz
        for _ in 0..<100 {
            for i in 0..<240 {
                chunk[i] = sinf(phase) * 0.3
                phase += 2 * .pi * 440 / 24_000
            }
            chunk.withUnsafeBufferPointer { engine.ingest($0.baseAddress!, count: 240) }
            Thread.sleep(forTimeInterval: 0.002)
        }
        wait(for: [gotPackets], timeout: 5)
        // Give the worker a beat to finish draining.
        Thread.sleep(forTimeInterval: 0.2)

        countLock.lock()
        let n = packetCount
        countLock.unlock()
        XCTAssertGreaterThan(n, 30, "24 kHz input must produce ~50 packets/s after SRC")
        XCTAssertLessThan(n, 80)
    }

    /// Mute must gate transmission and close the utterance with a terminator.
    func testMuteCutsTransmission() {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = 0.01

        let gotTerminator = expectation(description: "terminator after mute")
        gotTerminator.assertForOverFulfill = false
        let packetsAfterMute = Atomic()
        engine.onPacket = { data, _, isTerminator in
            if isTerminator { gotTerminator.fulfill() }
            else if packetsAfterMute.armed { packetsAfterMute.increment() }
        }

        engine.start(sourceRate: 48_000, format: CaptureFormat())
        defer { engine.stop() }

        var phase: Float = 0
        var chunk = [Float](repeating: 0, count: 480)
        func feedTone(chunks: Int) {
            for _ in 0..<chunks {
                for i in 0..<480 {
                    chunk[i] = sinf(phase) * 0.3
                    phase += 2 * .pi * 440 / 48_000
                }
                chunk.withUnsafeBufferPointer { engine.ingest($0.baseAddress!, count: 480) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        feedTone(chunks: 50)          // get an utterance going
        engine.isMuted = true
        Thread.sleep(forTimeInterval: 0.05)
        packetsAfterMute.arm()
        feedTone(chunks: 60)          // tone continues, but we're muted
        wait(for: [gotTerminator], timeout: 5)
        XCTAssertLessThanOrEqual(packetsAfterMute.count, 2,
                                 "mute must cut transmission immediately (no hangover leak)")
    }
}

/// Tiny helper: thread-safe counter with an arming latch.
private final class Atomic {
    private let lock = NSLock()
    private var _count = 0
    private var _armed = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    var armed: Bool { lock.lock(); defer { lock.unlock() }; return _armed }
    func arm() { lock.lock(); _armed = true; lock.unlock() }
    func increment() { lock.lock(); _count += 1; lock.unlock() }
}
