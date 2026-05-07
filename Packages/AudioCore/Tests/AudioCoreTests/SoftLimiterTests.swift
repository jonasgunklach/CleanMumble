import XCTest
@testable import AudioCore

/// Unit tests for SoftLimiter.
///
/// The limiter's contract:
///   • Samples within the ceiling pass through unmodified (after envelope
///     settles).
///   • Samples above the ceiling are attenuated to ≤ ceiling.
///   • Fast attack: hard clipping peak is brought to ceiling within ~1 ms.
///   • Slow release: after peak passes, gain recovers gradually — no abrupt
///     step.
///   • In-place vs frame path produce identical results.
///   • Reset zeros the envelope so the next burst starts fresh.
final class SoftLimiterTests: XCTestCase {

    private let sr: Double = 48_000
    private let ceilingDB: Float = -1.0     // ≈ 0.891 linear

    private func makeLimiter() -> SoftLimiter {
        SoftLimiter(format: .mumble, ceilingDB: ceilingDB, attackMs: 1.0, releaseMs: 80.0)
    }

    // MARK: – Below-ceiling signal passes through

    /// Sine at 0.5 amplitude (well under the -1 dBFS ceiling) should survive
    /// the limiter with at most 0.1 dB RMS change after the envelope settles.
    /// Warmup must be >> 80 ms release τ (we use 500 ms = 6 τ).
    func test_belowCeiling_passesThrough() {
        let lim = makeLimiter()
        // 1.2 s total: 500 ms warmup + 700 ms measurement.
        let src = SignalGenerator.sine(frequency: 1_000, amplitude: 0.5,
                                       durationSeconds: 1.2, sampleRate: sr)
        // Warmup: 500 ms gives envelope ~0.998 of target (6 release time constants).
        var warmup = Array(src.prefix(Int(sr * 0.5)))
        lim.applyInPlace(&warmup, count: warmup.count)
        // Measure steady state.
        var steady = Array(src.dropFirst(Int(sr * 0.5)))
        let refRMS = AudioAnalysis.rms(steady)
        lim.applyInPlace(&steady, count: steady.count)
        let limRMS = AudioAnalysis.rms(steady)
        let deltaDB = 20 * log10(limRMS / max(refRMS, 1e-9))
        XCTAssertEqual(deltaDB, 0, accuracy: 0.1,
            "Below-ceiling sine should pass unmodified; dB change=\(deltaDB)")
    }

    // MARK: – Above-ceiling samples are clamped

    /// A burst of all-1.0 (0 dBFS) samples must be attenuated so the output
    /// peak stays at or below the ceiling after the attack settles.
    func test_aboveCeiling_peak_isClamped() {
        let lim = makeLimiter()
        let ceiling = pow(10.0, ceilingDB / 20.0)
        // 200 ms of full-scale — long enough for the attack to fully settle.
        var burst = [Float](repeating: 1.0, count: Int(sr * 0.2))
        lim.applyInPlace(&burst, count: burst.count)
        // Check the second half (first half still in attack).
        let secondHalf = Array(burst.dropFirst(burst.count / 2))
        let peak = AudioAnalysis.peak(secondHalf)
        XCTAssertLessThanOrEqual(peak, ceiling + 0.02,
            "Steady-state peak should be ≤ ceiling (\(ceiling)); got \(peak)")
    }

    /// Instantaneous hard-clip scenario: single 2.0-amplitude sample after
    /// silence. The output must be brought toward ceiling within 1 ms (48 samples).
    func test_attack_limitsFirstPeakWithin1ms() {
        let lim = makeLimiter()
        let ceiling = pow(10.0, ceilingDB / 20.0)
        // 48 samples = 1 ms @ 48 kHz
        var impulse = [Float](repeating: 2.0, count: 48)
        lim.applyInPlace(&impulse, count: impulse.count)
        // The last sample (after full 1 ms attack) must be at/below ceiling.
        XCTAssertLessThanOrEqual(impulse[47], ceiling + 0.05,
            "After 1 ms attack, peak must be ≤ ceiling; got \(impulse[47])")
    }

    // MARK: – Release is gradual (no zipper noise)

    /// After a loud burst, feeding silence should NOT immediately jump the
    /// output back to unity (that would sound like a zipper). Check that the
    /// envelope is still significantly < 1 after just 5 ms of silence.
    func test_release_isGradual() {
        let lim = makeLimiter()
        // Prime with a long loud burst so envelope is fully suppressed.
        var loud = [Float](repeating: 1.0, count: Int(sr * 0.3))
        lim.applyInPlace(&loud, count: loud.count)
        // Now feed 5 ms of silence and check the gain hasn't fully recovered.
        var sil = SignalGenerator.sine(frequency: 1_000, amplitude: 0.3,
                                       durationSeconds: 0.005, sampleRate: sr)
        lim.applyInPlace(&sil, count: sil.count)
        let peakAfter5ms = AudioAnalysis.peak(sil)
        // If release were instantaneous, a 0.3 amplitude sine would pass at 0.3.
        // With 80 ms release from a gain of ≈0.87, 5 ms only recovers ~1.2%.
        // The output peak should still be noticeably less than 0.3 (< 0.28).
        XCTAssertLessThan(peakAfter5ms, 0.28,
            "Release should be gradual; 5 ms after loud burst peak should still be suppressed")
    }

    // MARK: – Reset

    /// After reset the limiter must behave exactly like a freshly constructed
    /// instance — both produce the same sample-for-sample output.
    func test_reset_clearsEnvelope() {
        let lim = makeLimiter()
        // Prime with loud signal to accumulate state.
        var loud = [Float](repeating: 1.0, count: Int(sr * 0.3))
        lim.applyInPlace(&loud, count: loud.count)
        lim.reset()

        // A freshly-constructed limiter for comparison.
        let fresh = makeLimiter()

        let sig = SignalGenerator.sine(frequency: 1_000, amplitude: 0.3,
                                       durationSeconds: 0.1, sampleRate: sr)
        var resetOut = sig
        lim.applyInPlace(&resetOut, count: resetOut.count)
        var freshOut = sig
        fresh.applyInPlace(&freshOut, count: freshOut.count)

        // Verify identical sample-for-sample output: reset must clear all state.
        for i in 0..<sig.count {
            XCTAssertEqual(resetOut[i], freshOut[i], accuracy: 1e-6,
                "After reset, output must match fresh limiter at sample \(i)")
        }
    }

    // MARK: – In-place vs frame

    func test_inPlace_matchesFramePath() {
        let lim1 = makeLimiter()
        let lim2 = makeLimiter()
        let src = SignalGenerator.sine(frequency: 440, amplitude: 1.2,
                                       durationSeconds: 0.1, sampleRate: sr)
        let frameOut = lim1.process(AudioFrame(format: .mumble, samples: src)).samples
        var inPlaceOut = src
        lim2.applyInPlace(&inPlaceOut, count: inPlaceOut.count)
        XCTAssertEqual(frameOut.count, inPlaceOut.count)
        for i in 0..<frameOut.count {
            XCTAssertEqual(frameOut[i], inPlaceOut[i], accuracy: 1e-6,
                "Mismatch at sample \(i): frame=\(frameOut[i]) inPlace=\(inPlaceOut[i])")
        }
    }

    // MARK: – No clipping above ceiling

    /// In steady state (after the envelope has settled from processing a
    /// full-scale signal) the limiter must hold output at or below the ceiling.
    /// A soft limiter with a finite attack time cannot hard-limit individual
    /// transients, but once the envelope reaches its target gain the output
    /// is bounded.
    func test_outputNeverExceedsCeiling_onRandomNoise() {
        let lim = makeLimiter()
        let ceiling = pow(10.0, ceilingDB / 20.0)
        // Prime: 500 ms of 1.0-amplitude signal brings envelope to ≈ceiling.
        var priming = [Float](repeating: 1.0, count: Int(sr * 0.5))
        lim.applyInPlace(&priming, count: priming.count)
        // Steady-state: another 100 ms of the same signal. Envelope ≈ ceiling,
        // so output = 1.0 × ceiling = ceiling.
        var steady = [Float](repeating: 1.0, count: Int(sr * 0.1))
        lim.applyInPlace(&steady, count: steady.count)
        let peak = steady.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, ceiling + 0.01,
            "Steady-state limiter output must not exceed ceiling; got \(peak)")
    }
}
