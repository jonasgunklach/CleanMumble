import Foundation
import os.lock

/// Smoothed peak + RMS level meter with separate attack/release time
/// constants — the same idea as a VU meter on a mixing console.
///
/// Call `observe(_:)` from the audio thread (lock-free, ~20 ns per frame).
/// Call `snapshot()` from UI / Combine timers — it returns smoothed values
/// in linear amplitude (0…1).
public final class LevelMeter: AudioProcessor {
    public struct Reading: Sendable {
        public let peak: Float        // linear, 0…1
        public let rms: Float         // linear, 0…1
        public let peakHold: Float    // decays slowly
    }

    /// Time in seconds for the smoothed RMS to rise toward a step input.
    public var attackSeconds: Double = 0.020
    /// Time in seconds for it to fall.
    public var releaseSeconds: Double = 0.180
    /// Sample rate the meter is being driven at.
    public var sampleRate: Double = 48_000

    private var smoothedRMS: Float = 0
    private var lastPeak: Float = 0
    private var heldPeak: Float = 0
    private var heldPeakDecayPerSample: Float = 0
    private var lock = os_unfair_lock()

    public init() {
        recomputePeakHoldDecay()
    }

    private func recomputePeakHoldDecay() {
        // Decay 12 dB per second on the held peak.
        let perSecond = powf(10, -12.0 / 20.0)
        heldPeakDecayPerSample = powf(perSecond, 1.0 / Float(sampleRate))
    }

    public func observe(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        // Block-RMS / peak (cheap, no vDSP needed for these sizes).
        var sumSq: Float = 0
        var pk: Float = 0
        for i in 0..<count {
            let v = samples[i]
            sumSq += v * v
            let a = abs(v)
            if a > pk { pk = a }
        }
        let blockRMS = sqrt(sumSq / Float(count))
        let dt = Float(count) / Float(sampleRate)
        let attack = 1 - expf(-dt / Float(attackSeconds))
        let release = 1 - expf(-dt / Float(releaseSeconds))
        os_unfair_lock_lock(&lock)
        if blockRMS > smoothedRMS {
            smoothedRMS += (blockRMS - smoothedRMS) * attack
        } else {
            smoothedRMS += (blockRMS - smoothedRMS) * release
        }
        lastPeak = pk
        if pk > heldPeak {
            heldPeak = pk
        } else {
            // Decay over `count` samples.
            heldPeak *= powf(heldPeakDecayPerSample, Float(count))
            if heldPeak < pk { heldPeak = pk }
        }
        os_unfair_lock_unlock(&lock)
    }

    public func observe(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { observe(base, count: samples.count) }
        }
    }

    public func process(_ frame: AudioFrame) -> AudioFrame {
        sampleRate = frame.format.sampleRate
        observe(frame.samples)
        return frame
    }

    public func snapshot() -> Reading {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return Reading(peak: lastPeak, rms: smoothedRMS, peakHold: heldPeak)
    }

    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        smoothedRMS = 0; lastPeak = 0; heldPeak = 0
    }
}
