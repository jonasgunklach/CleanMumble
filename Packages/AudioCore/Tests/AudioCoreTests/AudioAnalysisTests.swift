import XCTest
@testable import AudioCore

final class AudioAnalysisTests: XCTestCase {

    func test_rms_of_known_sine() {
        let s = SignalGenerator.sine(frequency: 1000, amplitude: 0.5,
                                     durationSeconds: 0.5)
        // RMS of a sine of amplitude A is A / √2.
        let expected = 0.5 / sqrtf(2)
        XCTAssertEqual(AudioAnalysis.rms(s), expected, accuracy: 0.005)
    }

    func test_peak_of_known_sine() {
        let s = SignalGenerator.sine(frequency: 1000, amplitude: 0.7,
                                     durationSeconds: 0.5)
        XCTAssertEqual(AudioAnalysis.peak(s), 0.7, accuracy: 0.001)
    }

    func test_dBFS_conversions() {
        XCTAssertEqual(AudioAnalysis.dBFS(1.0), 0.0, accuracy: 0.001)
        XCTAssertEqual(AudioAnalysis.dBFS(0.5), -6.0206, accuracy: 0.01)
        XCTAssertEqual(AudioAnalysis.dBFS(0.0), -120.0, accuracy: 0.001)
    }

    func test_dominantFrequency_recovers_pure_tone() {
        for hz in [220.0, 440.0, 1_000.0, 2_500.0, 5_000.0] {
            let s = SignalGenerator.sine(frequency: hz, amplitude: 0.5,
                                         durationSeconds: 1.0)
            let (f, mag) = AudioAnalysis.dominantFrequency(s, sampleRate: 48_000)
            XCTAssertEqual(f, hz, accuracy: max(2.0, hz * 0.005),
                           "Recovered \(f) Hz, expected \(hz)")
            XCTAssertGreaterThan(mag, 0.05)
        }
    }

    func test_thd_is_low_for_pure_sine() {
        let s = SignalGenerator.sine(frequency: 1_000, amplitude: 0.5,
                                     durationSeconds: 1.0)
        let thd = AudioAnalysis.thdNoise(s, sampleRate: 48_000, expectedHz: 1_000)
        XCTAssertLessThan(thd, 0.05, "Pure sine should have very low THD+N")
    }

    func test_thd_is_high_for_noise() {
        let n = SignalGenerator.whiteNoise(amplitude: 0.5, durationSeconds: 1.0)
        let thd = AudioAnalysis.thdNoise(n, sampleRate: 48_000, expectedHz: 1_000)
        XCTAssertGreaterThan(thd, 1.0, "Noise should have THD+N >> 1")
    }

    func test_discontinuities_finds_injected_clicks() {
        var s = SignalGenerator.sine(frequency: 440, amplitude: 0.2,
                                     durationSeconds: 0.1)
        s[1000] += 1.5  // huge step away from a small-amplitude sine
        s[2000] -= 1.5
        let hits = AudioAnalysis.discontinuities(s, threshold: 0.5)
        XCTAssertTrue(hits.contains(1000))
        XCTAssertTrue(hits.contains(2000))
    }

    func test_zeroRuns_finds_buffer_underrun() {
        var s = SignalGenerator.sine(frequency: 440, amplitude: 0.3,
                                     durationSeconds: 0.05)
        // Inject a 200-sample dropout
        for i in 500..<700 { s[i] = 0 }
        let runs = AudioAnalysis.zeroRuns(s, minRunLength: 100)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].start, 500)
        XCTAssertEqual(runs[0].length, 200)
    }

    func test_crossCorrelation_recovers_known_lag() {
        let ref = SignalGenerator.sine(frequency: 800, amplitude: 0.4,
                                       durationSeconds: 0.25)
        // Delayed copy of the reference.
        var delayed = [Float](repeating: 0, count: 64)
        delayed.append(contentsOf: ref)
        let (lag, peak) = AudioAnalysis.crossCorrelationLag(reference: ref,
                                                            received: delayed,
                                                            maxLag: 200)
        XCTAssertEqual(lag, 64)
        XCTAssertGreaterThan(peak, 0.4)
    }

    func test_snr_high_for_clean_passthrough() {
        let ref = SignalGenerator.sine(frequency: 1_000, amplitude: 0.5,
                                       durationSeconds: 0.5)
        let snr = AudioAnalysis.snr(reference: ref, received: ref)
        XCTAssertGreaterThan(snr, 60, "Identity should have very high SNR")
    }

    func test_snr_low_for_noise() {
        let ref = SignalGenerator.sine(frequency: 1_000, amplitude: 0.5,
                                       durationSeconds: 0.5)
        let noise = SignalGenerator.whiteNoise(amplitude: 0.5,
                                               durationSeconds: 0.5)
        let snr = AudioAnalysis.snr(reference: ref, received: noise)
        XCTAssertLessThan(snr, 0)
    }
}
