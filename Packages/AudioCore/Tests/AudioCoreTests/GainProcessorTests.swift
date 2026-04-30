import XCTest
@testable import AudioCore

final class GainProcessorTests: XCTestCase {

    func test_unityGain_passthrough() {
        let g = GainProcessor(gain: 1.0)
        let f = AudioFrame(format: .mumble,
                           samples: [0.1, -0.2, 0.3, -0.4])
        let out = g.process(f)
        XCTAssertEqual(out.samples, f.samples)
    }

    func test_doubleGain_doubles_amplitude() {
        let g = GainProcessor(gain: 2.0)
        let f = AudioFrame(format: .mumble, samples: [0.1, 0.2])
        let out = g.process(f)
        XCTAssertEqual(out.samples[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(out.samples[1], 0.4, accuracy: 1e-6)
    }

    func test_zeroGain_silences() {
        let g = GainProcessor(gain: 0)
        let f = AudioFrame(format: .mumble, samples: [0.5, -0.5, 0.9])
        XCTAssertEqual(g.process(f).samples, [0, 0, 0])
    }

    func test_clipping_is_counted() {
        let g = GainProcessor(gain: 4.0)
        let f = AudioFrame(format: .mumble, samples: [0.5, 0.3, -0.6])
        let out = g.process(f)
        XCTAssertEqual(out.samples[0], 1.0)   // 0.5 * 4 = 2 → clip
        XCTAssertEqual(out.samples[1], 1.0)   // 0.3 * 4 = 1.2 → clip
        XCTAssertEqual(out.samples[2], -1.0)  // -0.6 * 4 = -2.4 → clip
        XCTAssertEqual(g.clippedSamples, 3)
    }

    func test_gain_is_clamped_to_safe_range() {
        let g = GainProcessor()
        g.gain = -1
        XCTAssertEqual(g.gain, 0)
        g.gain = 100
        XCTAssertEqual(g.gain, 8.0)
    }

    func test_inPlace_matches_frame_path() {
        let g = GainProcessor(gain: 1.5)
        var samples: [Float] = [0.1, -0.2, 0.3, 0.7, -0.9]
        let frameOut = g.process(AudioFrame(format: .mumble, samples: samples)).samples
        samples.withUnsafeMutableBufferPointer { ptr in
            g.applyInPlace(ptr.baseAddress!, count: ptr.count)
        }
        for i in 0..<samples.count {
            XCTAssertEqual(samples[i], frameOut[i], accuracy: 1e-6)
        }
    }

    func test_sine_through_gain_is_louder_by_expected_dB() {
        let s = SignalGenerator.sine(frequency: 1_000, amplitude: 0.1,
                                     durationSeconds: 0.5)
        let f = AudioFrame(format: .mumble, samples: s)
        let g = GainProcessor(gain: 2.0)  // +6 dB
        let beforeDB = AudioAnalysis.dBFS(AudioAnalysis.rms(f.samples))
        let afterDB = AudioAnalysis.dBFS(AudioAnalysis.rms(g.process(f).samples))
        XCTAssertEqual(afterDB - beforeDB, 6.02, accuracy: 0.1)
    }
}
