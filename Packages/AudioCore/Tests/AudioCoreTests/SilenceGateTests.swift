import XCTest
@testable import AudioCore

final class SilenceGateTests: XCTestCase {

    func test_silence_keeps_gate_closed() {
        let gate = SilenceGate(openThreshold: 0.02, closeThreshold: 0.01,
                               holdSeconds: 0.1)
        let f = AudioFrame(format: .mumble,
                           samples: [Float](repeating: 0, count: 4800))
        let out = gate.process(f)
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(out.samples, [Float](repeating: 0, count: 4800))
    }

    func test_loud_signal_opens_gate() {
        let gate = SilenceGate(openThreshold: 0.02, closeThreshold: 0.01,
                               holdSeconds: 0.1)
        let s = SignalGenerator.sine(frequency: 800, amplitude: 0.4,
                                     durationSeconds: 0.05)
        let out = gate.process(AudioFrame(format: .mumble, samples: s))
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(AudioAnalysis.peak(out.samples),
                       AudioAnalysis.peak(s), accuracy: 1e-6)
    }

    func test_hold_keeps_gate_open_during_brief_pauses() {
        let gate = SilenceGate(openThreshold: 0.02, closeThreshold: 0.01,
                               holdSeconds: 0.150)
        let loud = SignalGenerator.sine(frequency: 800, amplitude: 0.4,
                                        durationSeconds: 0.05)
        _ = gate.process(AudioFrame(format: .mumble, samples: loud))
        XCTAssertTrue(gate.isOpen)
        // 50 ms of silence — should still be open (hold = 150 ms)
        let quiet = AudioFrame(format: .mumble,
                               samples: [Float](repeating: 0, count: 2400))
        _ = gate.process(quiet)
        XCTAssertTrue(gate.isOpen, "Hold should keep gate open through short pauses")
    }

    func test_long_silence_closes_gate() {
        let gate = SilenceGate(openThreshold: 0.02, closeThreshold: 0.01,
                               holdSeconds: 0.05)
        let loud = SignalGenerator.sine(frequency: 800, amplitude: 0.4,
                                        durationSeconds: 0.05)
        _ = gate.process(AudioFrame(format: .mumble, samples: loud))
        // 500 ms of silence
        for _ in 0..<10 {
            let q = AudioFrame(format: .mumble,
                               samples: [Float](repeating: 0, count: 2400))
            _ = gate.process(q)
        }
        XCTAssertFalse(gate.isOpen)
    }

    func test_hysteresis_prevents_chatter() {
        // Threshold barely-above-noise level. Without hysteresis the gate
        // would open and close on every frame; with it, it stays in one state.
        let gate = SilenceGate(openThreshold: 0.05, closeThreshold: 0.02,
                               holdSeconds: 0.05)
        var transitions = 0
        var lastOpen = false
        for _ in 0..<200 {
            // RMS sits around the close threshold.
            let n = SignalGenerator.whiteNoise(amplitude: 0.025,
                                               durationSeconds: 0.01)
            _ = gate.process(AudioFrame(format: .mumble, samples: n))
            if gate.isOpen != lastOpen {
                transitions += 1
                lastOpen = gate.isOpen
            }
        }
        XCTAssertLessThanOrEqual(transitions, 2,
                                 "Gate chattered \(transitions) times — hysteresis broken")
    }
}
