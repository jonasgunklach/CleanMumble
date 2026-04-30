import XCTest
@testable import AudioCore

final class LevelMeterTests: XCTestCase {

    func test_silence_yields_zero() {
        let m = LevelMeter()
        m.observe([Float](repeating: 0, count: 4800))
        let r = m.snapshot()
        XCTAssertEqual(r.peak, 0, accuracy: 1e-6)
        XCTAssertEqual(r.rms, 0, accuracy: 1e-6)
    }

    func test_steady_sine_converges_to_correct_RMS() {
        let m = LevelMeter()
        let s = SignalGenerator.sine(frequency: 1_000, amplitude: 0.5,
                                     durationSeconds: 1.0)
        // Feed in 480-sample (10 ms) blocks so the smoother has time to settle.
        s.withUnsafeBufferPointer { ptr in
            var i = 0
            while i < ptr.count {
                let n = min(480, ptr.count - i)
                m.observe(ptr.baseAddress!.advanced(by: i), count: n)
                i += n
            }
        }
        let r = m.snapshot()
        let expectedRMS = 0.5 / sqrtf(2)
        XCTAssertEqual(r.rms, expectedRMS, accuracy: 0.02)
        XCTAssertEqual(r.peak, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(r.peakHold, 0.49)
    }

    func test_attack_is_faster_than_release() {
        let m = LevelMeter()
        m.attackSeconds = 0.010
        m.releaseSeconds = 0.500
        // Hit it with a loud burst…
        let burst = SignalGenerator.sine(frequency: 1_000, amplitude: 0.8,
                                         durationSeconds: 0.05)
        m.observe(burst)
        let afterBurst = m.snapshot().rms
        XCTAssertGreaterThan(afterBurst, 0.3)
        // …then feed silence and confirm it drops only slowly.
        m.observe([Float](repeating: 0, count: 480))   // 10 ms of silence
        let after10ms = m.snapshot().rms
        XCTAssertGreaterThan(after10ms, afterBurst * 0.85,
                             "Release should be slow; meter dropped too fast")
    }
}
