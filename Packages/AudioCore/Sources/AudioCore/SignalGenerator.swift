import Foundation

/// Deterministic synthetic-signal generators. Used to drive the pipeline
/// from tests so we can assert on what came out the other end.
public enum SignalGenerator {

    /// Pure sine wave at `frequency` Hz, amplitude `amplitude` (linear, 0…1),
    /// `durationSeconds` long, sampled at `sampleRate`.
    public static func sine(frequency: Double,
                            amplitude: Float = 0.5,
                            durationSeconds: Double,
                            sampleRate: Double = 48_000) -> [Float] {
        let n = Int((durationSeconds * sampleRate).rounded())
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let twoPiOverFs = 2.0 * .pi / sampleRate
        for i in 0..<n {
            out[i] = amplitude * Float(sin(Double(i) * twoPiOverFs * frequency))
        }
        return out
    }

    /// Linear sine sweep from `startHz` to `endHz`.
    public static func sweep(startHz: Double,
                             endHz: Double,
                             amplitude: Float = 0.5,
                             durationSeconds: Double,
                             sampleRate: Double = 48_000) -> [Float] {
        let n = Int((durationSeconds * sampleRate).rounded())
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        var phase: Double = 0
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let f = startHz + (endHz - startHz) * t
            phase += 2.0 * .pi * f / sampleRate
            out[i] = amplitude * Float(sin(phase))
        }
        return out
    }

    /// White noise with deterministic seed. amplitude is peak (uniform on
    /// [-amp, +amp]).
    public static func whiteNoise(amplitude: Float = 0.1,
                                  durationSeconds: Double,
                                  sampleRate: Double = 48_000,
                                  seed: UInt64 = 0xC0FFEE) -> [Float] {
        let n = Int((durationSeconds * sampleRate).rounded())
        guard n > 0 else { return [] }
        var rng = SplitMix64(state: seed)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = (Float(rng.nextUnitInterval()) * 2 - 1) * amplitude
        }
        return out
    }

    /// `durationSeconds` of silence.
    public static func silence(durationSeconds: Double,
                               sampleRate: Double = 48_000) -> [Float] {
        let n = Int((durationSeconds * sampleRate).rounded())
        return [Float](repeating: 0, count: n)
    }

    /// One unit-amplitude impulse surrounded by silence — useful for impulse
    /// response measurement.
    public static func impulse(durationSeconds: Double,
                               sampleRate: Double = 48_000) -> [Float] {
        var out = silence(durationSeconds: durationSeconds, sampleRate: sampleRate)
        if !out.isEmpty { out[0] = 1.0 }
        return out
    }

    /// Synthetic voice-like signal: a buzzy glottal source (sawtooth at
    /// `pitchHz`) shaped by 3 formants (F1=700, F2=1220, F3=2600 Hz —
    /// roughly the vowel /a/), with light pitch jitter and amplitude
    /// envelope so the signal is broadband and time-varying like speech.
    /// Deterministic for a given seed. Useful to ask "does the codec
    /// preserve a voice-like signal?".
    public static func voiceLike(pitchHz: Double = 130,
                                 amplitude: Float = 0.4,
                                 durationSeconds: Double,
                                 sampleRate: Double = 48_000,
                                 seed: UInt64 = 0xBEEFCAFE) -> [Float] {
        let n = Int((durationSeconds * sampleRate).rounded())
        guard n > 0 else { return [] }
        var rng = SplitMix64(state: seed)

        // Glottal source: sawtooth with slight per-period jitter.
        var src = [Float](repeating: 0, count: n)
        var phase: Double = 0
        for i in 0..<n {
            let jitter = (rng.nextUnitInterval() - 0.5) * 0.02
            phase += 2.0 * .pi * (pitchHz * (1 + jitter)) / sampleRate
            // Sawtooth in [-1, 1].
            let p = phase.truncatingRemainder(dividingBy: 2 * .pi)
            src[i] = Float((p / .pi) - 1)
        }

        // Three biquad band-pass filters @ formant frequencies, summed.
        // Lower Q (≈4) gives broader, more speech-like formants with
        // continuous energy between them — what real vowels look like.
        var out = [Float](repeating: 0, count: n)
        let formants: [(f: Double, q: Double, gain: Float)] = [
            (700,  4, 1.0),
            (1220, 5, 0.7),
            (2600, 6, 0.5),
        ]
        for (f, q, g) in formants {
            let band = biquadBandpass(src, sampleRate: sampleRate,
                                      centerHz: f, q: q)
            for i in 0..<n { out[i] += band[i] * g }
        }

        // Slow amplitude envelope (syllable-rate ~3 Hz) so it isn't a
        // perfectly stationary signal — codecs treat onsets / decays
        // differently from steady tones.
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = Float(0.5 + 0.5 * sin(2 * .pi * 3.0 * t - .pi / 2))
            out[i] *= env
        }

        // Normalise to requested amplitude.
        var peak: Float = 0
        for v in out { let a = abs(v); if a > peak { peak = a } }
        if peak > 0 {
            let g = amplitude / peak
            for i in 0..<n { out[i] *= g }
        }
        return out
    }

    /// Pink (1/f) noise generated via the Voss–McCartney algorithm.
    /// Deterministic for a given seed. Good test signal for codec quality:
    /// flat-ish on a log-frequency axis, broadband, no obvious tones.
    public static func pinkNoise(amplitude: Float = 0.2,
                                 durationSeconds: Double,
                                 sampleRate: Double = 48_000,
                                 seed: UInt64 = 0xFADEDFADE) -> [Float] {
        let n = Int((durationSeconds * sampleRate).rounded())
        guard n > 0 else { return [] }
        var rng = SplitMix64(state: seed)
        let octaves = 16
        var rows = [Double](repeating: 0, count: octaves)
        var out = [Float](repeating: 0, count: n)
        var runningSum: Double = 0
        for i in 0..<n {
            // Update one row per sample, picked by trailing-zero count of i.
            // (Voss–McCartney standard trick.)
            let k = min(octaves - 1, (i == 0) ? 0 : i.trailingZeroBitCount)
            runningSum -= rows[k]
            rows[k] = rng.nextUnitInterval() - 0.5
            runningSum += rows[k]
            out[i] = Float(runningSum) / Float(octaves)
        }
        // Normalise to requested peak amplitude.
        var peak: Float = 0
        for v in out { let a = abs(v); if a > peak { peak = a } }
        if peak > 0 {
            let g = amplitude / peak
            for i in 0..<n { out[i] *= g }
        }
        return out
    }
}

// MARK: - Internal helpers

/// Tiny single-pass biquad band-pass (RBJ cookbook). Used by voiceLike.
/// Stateless wrapper that allocates+returns a new array; not for hot paths.
private func biquadBandpass(_ x: [Float], sampleRate: Double,
                            centerHz: Double, q: Double) -> [Float] {
    let w0 = 2.0 * .pi * centerHz / sampleRate
    let alpha = sin(w0) / (2.0 * q)
    // Constant skirt gain (peak gain = Q) BPF.
    let b0 =  alpha
    let b1 =  0.0
    let b2 = -alpha
    let a0 =  1 + alpha
    let a1 = -2 * cos(w0)
    let a2 =  1 - alpha
    let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0
    let na1 = a1 / a0, na2 = a2 / a0

    var y = [Float](repeating: 0, count: x.count)
    var x1: Double = 0, x2: Double = 0
    var y1: Double = 0, y2: Double = 0
    for i in 0..<x.count {
        let xn = Double(x[i])
        let yn = nb0 * xn + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
        y[i] = Float(yn)
        x2 = x1; x1 = xn
        y2 = y1; y1 = yn
    }
    return y
}

/// Tiny deterministic PRNG so test signals are reproducible across runs.
private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
    mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
