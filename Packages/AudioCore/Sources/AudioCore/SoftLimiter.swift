//
//  SoftLimiter.swift
//  AudioCore
//
//  Realtime-safe soft-knee peak limiter. Targets a configurable ceiling
//  (default -1 dBFS true-peak) with fast attack and a release time that
//  produces no audible pumping on speech.
//
//  Used as the final pre-Opus stage so the encoder never sees clipped
//  samples (Opus handles slight saturation gracefully but obvious clipping
//  ruins intelligibility on the decoded side because the codec spends bits
//  trying to reproduce the square edges).
//

import Foundation
import os.lock

public final class SoftLimiter: AudioProcessor {
    public let format: AudioFormat
    /// Linear ceiling (e.g. 0.891 for -1 dBFS, 1.0 for none).
    public var ceiling: Float
    /// Attack/release coefficients in samples. Computed from time constants.
    private var attackCoeff: Float
    private var releaseCoeff: Float
    private var envelope: Float = 0
    private var lock = os_unfair_lock()

    public init(format: AudioFormat = .mumble,
                ceilingDB: Float = -1.0,
                attackMs: Float = 1.0,
                releaseMs: Float = 80.0) {
        self.format = format
        self.ceiling = pow(10.0, ceilingDB / 20.0)
        let sr = Float(format.sampleRate)
        // Standard one-pole: α = exp(-1 / (τ · fs))
        self.attackCoeff  = exp(-1.0 / (attackMs  * 0.001 * sr))
        self.releaseCoeff = exp(-1.0 / (releaseMs * 0.001 * sr))
    }

    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        envelope = 0
    }

    public func process(_ frame: AudioFrame) -> AudioFrame {
        var out = frame.samples
        out.withUnsafeMutableBufferPointer { buf in
            applyInPlace(buf.baseAddress!, count: buf.count)
        }
        return AudioFrame(format: frame.format, samples: out, sampleTime: frame.sampleTime)
    }

    public func applyInPlace(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let aA = attackCoeff, aR = releaseCoeff
        let ceil = ceiling
        var env = envelope
        os_unfair_lock_unlock(&lock)

        for i in 0..<count {
            let x = buf[i]
            let absX = abs(x)
            // Required gain reduction for THIS sample.
            let target: Float = (absX > ceil) ? (ceil / max(absX, 1e-9)) : 1.0
            // Smooth envelope: faster when reducing (attack), slower when
            // releasing back to unity. env tracks the *gain*, so attack means
            // env going DOWN.
            if target < env {
                env = aA * env + (1 - aA) * target
            } else {
                env = aR * env + (1 - aR) * target
            }
            buf[i] = x * env
        }

        os_unfair_lock_lock(&lock)
        envelope = env
        os_unfair_lock_unlock(&lock)
    }
}
