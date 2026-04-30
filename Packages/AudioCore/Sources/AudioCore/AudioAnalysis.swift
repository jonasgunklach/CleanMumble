import Foundation
import Accelerate

/// Pure-function audio analysis routines. None of these allocate beyond the
/// returned arrays, all are deterministic, and all are safe to call from
/// tests. Use them to assert on what a pipeline actually produced.
public enum AudioAnalysis {

    // MARK: Levels

    /// Root-mean-square amplitude of `samples` in linear (0…~1) units.
    public static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var v: Float = 0
        vDSP_rmsqv(samples, 1, &v, vDSP_Length(samples.count))
        return v
    }

    /// Peak absolute amplitude.
    public static func peak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var v: Float = 0
        vDSP_maxmgv(samples, 1, &v, vDSP_Length(samples.count))
        return v
    }

    /// Convert linear amplitude (>0) to dBFS. Clamps the floor at -120 dB.
    public static func dBFS(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return -120 }
        return max(-120, 20 * log10f(amplitude))
    }

    // MARK: Spectrum

    /// Magnitude spectrum (length N/2) of `samples` (length N must be a power
    /// of two). Applies a Hann window. Bin `k` corresponds to frequency
    /// `k * sampleRate / N`.
    public static func magnitudeSpectrum(_ samples: [Float],
                                         sampleRate: Double) -> [Float] {
        let n = samples.count
        precondition(n > 0 && (n & (n - 1)) == 0,
                     "magnitudeSpectrum requires a power-of-two length")
        let log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // Hann window
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        windowed.withUnsafeMutableBufferPointer { wptr in
            real.withUnsafeMutableBufferPointer { rptr in
                imag.withUnsafeMutableBufferPointer { iptr in
                    var split = DSPSplitComplex(realp: rptr.baseAddress!,
                                                imagp: iptr.baseAddress!)
                    wptr.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                        capacity: n / 2) { cptr in
                        vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
                }
            }
        }
        // Normalise (vDSP packs DC + Nyquist into real[0]/imag[0]; we don't
        // care about absolute scale, only relative bin energy).
        var scale: Float = 1.0 / Float(n)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(n / 2))
        return mags
    }

    /// Returns (frequency, magnitude) of the strongest non-DC bin.
    public static func dominantFrequency(_ samples: [Float],
                                         sampleRate: Double) -> (frequency: Double, magnitude: Float) {
        // Snap to the nearest power of two ≤ samples.count.
        var n = 1
        while n * 2 <= samples.count { n *= 2 }
        guard n >= 64 else { return (0, 0) }
        let trimmed = Array(samples.prefix(n))
        let mags = magnitudeSpectrum(trimmed, sampleRate: sampleRate)
        // Skip DC (bin 0) and the very-low bins where window leakage dominates.
        let startBin = max(2, mags.count / 1024)
        var bestBin = startBin
        var bestMag: Float = 0
        for k in startBin..<mags.count {
            if mags[k] > bestMag { bestMag = mags[k]; bestBin = k }
        }
        let freq = Double(bestBin) * sampleRate / Double(n)
        return (freq, bestMag)
    }

    /// Total harmonic distortion + noise relative to the fundamental at
    /// `expectedHz`, as a ratio (0…1). Lower is cleaner.
    public static func thdNoise(_ samples: [Float],
                                sampleRate: Double,
                                expectedHz: Double,
                                toleranceHz: Double = 5.0) -> Float {
        var n = 1
        while n * 2 <= samples.count { n *= 2 }
        guard n >= 1024 else { return 1 }
        let trimmed = Array(samples.prefix(n))
        let mags = magnitudeSpectrum(trimmed, sampleRate: sampleRate)
        let binHz = sampleRate / Double(n)
        let tolBins = max(2, Int((toleranceHz / binHz).rounded(.up)))
        let centerBin = Int((expectedHz / binHz).rounded())
        guard centerBin > 0, centerBin < mags.count else { return 1 }
        // Sum energy in fundamental window.
        var fundamentalEnergy: Float = 0
        for k in max(1, centerBin - tolBins)...min(mags.count - 1, centerBin + tolBins) {
            fundamentalEnergy += mags[k] * mags[k]
        }
        // Sum the rest (excluding DC and a small low-bin guard).
        var totalEnergy: Float = 0
        for k in 2..<mags.count {
            totalEnergy += mags[k] * mags[k]
        }
        let noise = max(0, totalEnergy - fundamentalEnergy)
        guard fundamentalEnergy > 0 else { return 1 }
        return sqrt(noise / fundamentalEnergy)
    }

    // MARK: Glitch / discontinuity detection

    /// Returns indices where the absolute first difference exceeds
    /// `threshold`. Useful for spotting click/pop artefacts after a join,
    /// resampling glitch, or buffer-boundary discontinuity.
    public static func discontinuities(_ samples: [Float],
                                       threshold: Float = 0.5) -> [Int] {
        guard samples.count > 1 else { return [] }
        var hits: [Int] = []
        for i in 1..<samples.count {
            if abs(samples[i] - samples[i - 1]) > threshold {
                hits.append(i)
            }
        }
        return hits
    }

    /// Counts contiguous runs of exactly-zero samples longer than
    /// `minRunLength`. Excessive zero runs after activity indicate buffer
    /// underruns.
    public static func zeroRuns(_ samples: [Float],
                                minRunLength: Int = 64) -> [(start: Int, length: Int)] {
        var runs: [(Int, Int)] = []
        var runStart = -1
        for (i, s) in samples.enumerated() {
            if s == 0 {
                if runStart < 0 { runStart = i }
            } else if runStart >= 0 {
                let len = i - runStart
                if len >= minRunLength { runs.append((runStart, len)) }
                runStart = -1
            }
        }
        if runStart >= 0 {
            let len = samples.count - runStart
            if len >= minRunLength { runs.append((runStart, len)) }
        }
        return runs
    }

    // MARK: Latency / alignment

    /// Find the integer sample lag that maximises cross-correlation of
    /// `received` against `reference`. Searches lags 0…`maxLag`. Returns
    /// (lagSamples, normalisedPeak ∈ -1…1). A peak < ~0.3 indicates the two
    /// signals don't actually correlate (e.g. heavy distortion).
    public static func crossCorrelationLag(reference: [Float],
                                           received: [Float],
                                           maxLag: Int) -> (lag: Int, peak: Float) {
        let refRMS = rms(reference)
        let recvRMS = rms(received)
        guard refRMS > 0, recvRMS > 0 else { return (0, 0) }
        let n = min(reference.count, received.count) - maxLag
        guard n > 0, maxLag >= 0 else { return (0, 0) }

        // Vectorised correlation via vDSP. With a positive filter stride
        // vDSP_conv computes correlation:
        //   C[lag] = Σ_{k=0..n-1} received[lag + k] * reference[k]
        // for lag in 0...maxLag. Orders of magnitude faster than the naive
        // nested loop.
        var corr = [Float](repeating: 0, count: maxLag + 1)
        let kernelLen = vDSP_Length(n)
        let outLen = vDSP_Length(maxLag + 1)
        // received has length >= n + maxLag.
        received.withUnsafeBufferPointer { rb in
            reference.withUnsafeBufferPointer { kb in
                corr.withUnsafeMutableBufferPointer { ob in
                    vDSP_conv(rb.baseAddress!, 1,
                              kb.baseAddress!, 1,
                              ob.baseAddress!, 1,
                              outLen, kernelLen)
                }
            }
        }
        var bestLag = 0
        var bestVal: Float = -.infinity
        for (lag, v) in corr.enumerated() where v > bestVal {
            bestVal = v; bestLag = lag
        }
        let normPeak = bestVal / (Float(n) * refRMS * recvRMS)
        return (bestLag, normPeak)
    }

    // MARK: Signal-to-noise ratio

    /// SNR in dB of `received` vs. a known `reference`. Aligns by
    /// cross-correlation up to `maxLag`. Returns +∞ if signals match
    /// exactly. Negative values indicate the noise dominates.
    public static func snr(reference: [Float],
                           received: [Float],
                           maxLag: Int = 256) -> Float {
        let (lag, peak) = crossCorrelationLag(reference: reference,
                                              received: received,
                                              maxLag: maxLag)
        guard peak > 0.1 else { return -120 }
        let n = min(reference.count - lag, received.count - lag)
        guard n > 0 else { return -120 }
        var refScale: Float = 0
        var num: Float = 0   // <ref, recv>
        var den: Float = 0   // <ref, ref>
        for i in 0..<n {
            num += reference[i] * received[i + lag]
            den += reference[i] * reference[i]
        }
        guard den > 0 else { return -120 }
        refScale = num / den
        var noiseEnergy: Float = 0
        var signalEnergy: Float = 0
        for i in 0..<n {
            let predicted = reference[i] * refScale
            let err = received[i + lag] - predicted
            noiseEnergy += err * err
            signalEnergy += predicted * predicted
        }
        guard noiseEnergy > 0 else { return 120 }
        return 10 * log10f(signalEnergy / noiseEnergy)
    }

    // MARK: Spectral distance

    /// RMS log-magnitude spectral distance between two equal-length signals,
    /// computed in dB. 0 dB = identical spectrum; small (<3 dB) = perceptually
    /// very close; >10 dB = audibly different. Uses Hann-windowed FFTs, so it
    /// tolerates phase / fractional-sample shifts \u2014 exactly what you want
    /// when comparing codec output to source.
    ///
    /// Bins are weighted by the reference's magnitude so quiet bins (mostly
    /// noise floor) don't dominate. Only bins above
    /// `referenceFloorDB` below the reference's peak in the band of interest
    /// are counted at all. Default band is 80\u20268 kHz (Opus VOIP useful range).
    public static func logSpectralDistanceDB(reference: [Float],
                                             received: [Float],
                                             sampleRate: Double = 48_000,
                                             frameSize: Int = 2048,
                                             hop: Int = 1024,
                                             bandLowHz: Double = 80,
                                             bandHighHz: Double = 8_000,
                                             referenceFloorDB: Float = -40,
                                             smoothBins: Int = 0) -> Float {
        let n = min(reference.count, received.count)
        guard n >= frameSize, frameSize & (frameSize - 1) == 0 else { return .infinity }
        let binHz = sampleRate / Double(frameSize)
        let lowBin = max(1, Int((bandLowHz / binHz).rounded()))
        let highBin = min(frameSize / 2 - 1, Int((bandHighHz / binHz).rounded()))
        guard highBin > lowBin else { return .infinity }

        var weightedSqDB: Double = 0
        var totalWeight: Double = 0
        var i = 0
        while i + frameSize <= n {
            let refFrame = Array(reference[i ..< i + frameSize])
            let rcvFrame = Array(received[i ..< i + frameSize])
            var refMag = magnitudeSpectrum(refFrame, sampleRate: sampleRate)
            var rcvMag = magnitudeSpectrum(rcvFrame, sampleRate: sampleRate)
            if smoothBins > 1 {
                // Box-smooth both spectra so the harmonic comb of a voiced
                // signal collapses into its envelope. This removes spurious
                // distance from inter-bin harmonic drift.
                refMag = movingAverage(refMag, window: smoothBins)
                rcvMag = movingAverage(rcvMag, window: smoothBins)
            }

            // Find this frame's reference peak in the band so we can floor
            // anything that's not actually signal.
            var framePeak: Float = 0
            for k in lowBin...highBin where refMag[k] > framePeak { framePeak = refMag[k] }
            let floorMag = framePeak * powf(10, referenceFloorDB / 20)

            for k in lowBin...highBin where refMag[k] >= floorMag {
                let refDB = 20 * log10(Double(max(refMag[k], 1e-9)))
                let rcvDB = 20 * log10(Double(max(rcvMag[k], 1e-9)))
                let d = refDB - rcvDB
                // Weight by reference magnitude (linear) so loud bins matter.
                let w = Double(refMag[k])
                weightedSqDB += w * d * d
                totalWeight  += w
            }
            i += hop
        }
        guard totalWeight > 0 else { return .infinity }
        return Float(sqrt(weightedSqDB / totalWeight))
    }

    private static func movingAverage(_ x: [Float], window: Int) -> [Float] {
        guard window > 1, x.count > 0 else { return x }
        let half = window / 2
        var out = [Float](repeating: 0, count: x.count)
        var sum: Float = 0
        for i in 0..<min(window, x.count) { sum += x[i] }
        for i in 0..<x.count {
            let lo = max(0, i - half)
            let hi = min(x.count - 1, i + half)
            // Simple O(n*w) — fine for offline test analysis.
            var s: Float = 0
            for k in lo...hi { s += x[k] }
            out[i] = s / Float(hi - lo + 1)
        }
        _ = sum   // silence unused-warning
        return out
    }
}
