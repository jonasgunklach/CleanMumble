import XCTest
@testable import AudioCore

/// Unit tests for BiquadFilter (RBJ high-pass and low-pass).
///
/// Design approach:
///   • DC / near-DC attenuation: an HPF must block frequencies well below
///     cutoff by at least -40 dB at DC (ideal ∞, but steady-state IIR
///     attenuates to float rounding noise within hundreds of samples).
///   • Passband preservation: a frequency well above the cutoff should pass
///     through with at most 1 dB of gain change.
///   • Cutoff frequency (Fc): the HPF should attenuate Fc by exactly -3 dB
///     (Butterworth Q=0.707 definition).
///   • State reset: clearing state should stop ringing / transient leakage.
///   • In-place vs frame: both code paths produce identical output.
final class BiquadFilterTests: XCTestCase {

    private let sr: Float = 48_000
    private let fc: Float = 80

    // MARK: – High-pass

    /// DC input (all zeros except a constant offset) must be attenuated to near
    /// zero after the filter settles. Allow 100 samples of warmup.
    func test_highPass_attenuatesDC() {
        let f = BiquadFilter(coeffs: BiquadFilter.highPass(cutoffHz: fc, sampleRate: sr))
        var dc = [Float](repeating: 1.0, count: 2048)
        f.applyInPlace(&dc, channelCount: 1)
        // Steady state is after warmup; check last quarter of buffer.
        let steadyState = Array(dc[1536...])
        let rms = AudioAnalysis.rms(steadyState)
        XCTAssertLessThan(rms, 1e-3,
            "HPF should reduce DC to ~0; got RMS=\(rms)")
    }

    /// A 4 kHz sine is well into the passband (50× the 80 Hz cutoff).
    /// The filter should pass it within 0.5 dB.
    func test_highPass_passesHighFrequencyWithinTolerance() {
        let f = BiquadFilter(coeffs: BiquadFilter.highPass(cutoffHz: fc, sampleRate: sr))
        let durationSec: Float = 0.1
        var sig = SignalGenerator.sine(frequency: 4_000, amplitude: 1.0,
                                       durationSeconds: Double(durationSec),
                                       sampleRate: Double(sr))
        // Warmup: run 200 samples through before measuring.
        let warmup = Array(sig.prefix(200))
        var wbuf = warmup
        f.applyInPlace(&wbuf, channelCount: 1)
        // Measure rest.
        var measureSig = Array(sig.dropFirst(200))
        let refRMS  = AudioAnalysis.rms(measureSig)
        f.applyInPlace(&measureSig, channelCount: 1)
        let filtRMS = AudioAnalysis.rms(measureSig)
        let deltaDB = 20 * log10(filtRMS / max(refRMS, 1e-9))
        XCTAssertEqual(deltaDB, 0, accuracy: 0.5,
            "4 kHz should be in passband (±0.5 dB), got \(deltaDB) dB change")
        _ = sig  // suppress warning
    }

    /// At the cutoff frequency a Butterworth HPF should attenuate by -3 dB.
    /// We give ±1 dB tolerance because a finite sine burst has some spectral
    /// spreading and a few cycles of transient.
    func test_highPass_cutoffIs_minus3dB() {
        let f = BiquadFilter(coeffs: BiquadFilter.highPass(cutoffHz: fc, sampleRate: sr))
        // 4 seconds of signal gives good frequency resolution.
        var ref = SignalGenerator.sine(frequency: Double(fc), amplitude: 1.0,
                                       durationSeconds: 4.0, sampleRate: Double(sr))
        // Warmup.
        var wbuf = Array(ref.prefix(500))
        f.applyInPlace(&wbuf, channelCount: 1)
        var meas = Array(ref.dropFirst(500))
        let refRMS  = AudioAnalysis.rms(meas)
        f.applyInPlace(&meas, channelCount: 1)
        let filtRMS = AudioAnalysis.rms(meas)
        let attenuationDB = 20 * log10(filtRMS / max(refRMS, 1e-9))
        // Expect ~-3 dB ± 1.
        XCTAssertEqual(attenuationDB, -3.0, accuracy: 1.0,
            "HPF at Fc should be -3 dB; got \(attenuationDB) dB")
        _ = ref
    }

    /// A 20 Hz sine (well below the 80 Hz cutoff) should be heavily attenuated.
    func test_highPass_stronglyAttenuatesSubCutoff() {
        let f = BiquadFilter(coeffs: BiquadFilter.highPass(cutoffHz: fc, sampleRate: sr))
        var ref = SignalGenerator.sine(frequency: 20, amplitude: 1.0,
                                       durationSeconds: 2.0, sampleRate: Double(sr))
        var wbuf = Array(ref.prefix(200)); f.applyInPlace(&wbuf, channelCount: 1)
        var meas = Array(ref.dropFirst(200))
        let refRMS = AudioAnalysis.rms(meas)
        f.applyInPlace(&meas, channelCount: 1)
        let filtRMS = AudioAnalysis.rms(meas)
        let attenuationDB = 20 * log10(filtRMS / max(refRMS, 1e-9))
        // 20 Hz is 2 octaves below 80 Hz → second-order filter → ~-24 dB per octave
        // so we expect ≫ -12 dB. Assert at least -20 dB to leave margin.
        XCTAssertLessThan(attenuationDB, -20,
            "20 Hz is below HPF cutoff; expect > 20 dB attenuation, got \(attenuationDB) dB")
        _ = ref
    }

    // MARK: – State management

    func test_reset_clearsTransient() {
        let f = BiquadFilter(coeffs: BiquadFilter.highPass(cutoffHz: fc, sampleRate: sr))
        // Drive a loud signal to load up the state.
        var loud = [Float](repeating: 0.9, count: 480)
        f.applyInPlace(&loud, channelCount: 1)
        // Reset, then feed silence. Output should also be (nearly) silent.
        f.reset()
        var silence = [Float](repeating: 0, count: 480)
        f.applyInPlace(&silence, channelCount: 1)
        let peakAfter = AudioAnalysis.peak(silence)
        XCTAssertEqual(peakAfter, 0, accuracy: 1e-6,
            "After reset + silence input, output must be silence; got peak=\(peakAfter)")
    }

    // MARK: – In-place vs frame path

    func test_inPlace_matchesFramePath() {
        let coeffs = BiquadFilter.highPass(cutoffHz: fc, sampleRate: sr)
        let f1 = BiquadFilter(coeffs: coeffs)
        let f2 = BiquadFilter(coeffs: coeffs)
        let src = SignalGenerator.sine(frequency: 440, amplitude: 0.5,
                                       durationSeconds: 0.1, sampleRate: Double(sr))
        // Frame path.
        let frameOut = f1.process(AudioFrame(format: .mumble, samples: src)).samples
        // In-place path.
        var inPlaceOut = src
        f2.applyInPlace(&inPlaceOut, channelCount: 1)
        XCTAssertEqual(frameOut.count, inPlaceOut.count)
        for i in 0..<frameOut.count {
            XCTAssertEqual(frameOut[i], inPlaceOut[i], accuracy: 1e-6,
                "Mismatch at sample \(i)")
        }
    }

    // MARK: – Low-pass sanity check (complementary)

    /// An LPF's passband is below the cutoff; a 20 Hz sine should pass
    /// untouched through a 200 Hz LPF.
    func test_lowPass_passesSubCutoff() {
        let f = BiquadFilter(coeffs: BiquadFilter.lowPass(cutoffHz: 200, sampleRate: sr))
        var ref = SignalGenerator.sine(frequency: 20, amplitude: 1.0,
                                       durationSeconds: 1.0, sampleRate: Double(sr))
        var wbuf = Array(ref.prefix(200)); f.applyInPlace(&wbuf, channelCount: 1)
        var meas = Array(ref.dropFirst(200))
        let refRMS = AudioAnalysis.rms(meas)
        f.applyInPlace(&meas, channelCount: 1)
        let filtRMS = AudioAnalysis.rms(meas)
        let deltaDB = 20 * log10(filtRMS / max(refRMS, 1e-9))
        XCTAssertEqual(deltaDB, 0, accuracy: 1.0,
            "20 Hz should be in LPF(200 Hz) passband, got \(deltaDB) dB change")
        _ = ref
    }
}
