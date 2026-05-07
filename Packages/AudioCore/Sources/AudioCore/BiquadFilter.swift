//
//  BiquadFilter.swift
//  AudioCore
//
//  Single-section biquad IIR with realtime-safe `process` and `applyInPlace`.
//  Designed for the input chain: high-pass at ~80 Hz to strip mic rumble,
//  HVAC, and laptop fan noise before Opus sees them. Opus's psychoacoustic
//  model can't allocate bits well to those frequencies on a voice signal so
//  removing them up front genuinely improves perceived intelligibility.
//
//  Coefficient design follows the canonical RBJ Audio EQ Cookbook formulae.
//

import Foundation
import os.lock

public final class BiquadFilter: AudioProcessor {
    public struct Coefficients: Sendable {
        public var b0, b1, b2, a1, a2: Float
        public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
    }

    public let format: AudioFormat
    private var coeffs: Coefficients
    // One state pair per channel.
    private var z1: [Float]
    private var z2: [Float]
    private var lock = os_unfair_lock()

    public init(format: AudioFormat = .mumble, coeffs: Coefficients) {
        self.format = format
        self.coeffs = coeffs
        self.z1 = [Float](repeating: 0, count: format.channelCount)
        self.z2 = [Float](repeating: 0, count: format.channelCount)
    }

    public func setCoefficients(_ c: Coefficients) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        coeffs = c
    }

    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for i in z1.indices { z1[i] = 0 }
        for i in z2.indices { z2[i] = 0 }
    }

    public func process(_ frame: AudioFrame) -> AudioFrame {
        var out = frame.samples
        applyInPlace(&out, channelCount: frame.format.channelCount)
        return AudioFrame(format: frame.format, samples: out, sampleTime: frame.sampleTime)
    }

    /// Realtime in-place, mono. Lock-free fast path: copies coeffs & state to
    /// locals, runs the loop, writes state back under the lock at the end.
    public func applyInPlace(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let c = coeffs
        var s1 = z1[0], s2 = z2[0]
        os_unfair_lock_unlock(&lock)
        // Transposed Direct Form II.
        for i in 0..<count {
            let x = buf[i]
            let y = c.b0 * x + s1
            s1 = c.b1 * x - c.a1 * y + s2
            s2 = c.b2 * x - c.a2 * y
            buf[i] = y
        }
        os_unfair_lock_lock(&lock)
        z1[0] = s1; z2[0] = s2
        os_unfair_lock_unlock(&lock)
    }

    public func applyInPlace(_ samples: inout [Float], channelCount: Int) {
        precondition(channelCount == 1, "BiquadFilter is mono-only for now")
        samples.withUnsafeMutableBufferPointer { buf in
            applyInPlace(buf.baseAddress!, count: buf.count)
        }
    }

    // MARK: - Factories (RBJ cookbook)

    public static func highPass(cutoffHz: Float,
                                sampleRate: Float,
                                Q: Float = 0.707) -> Coefficients {
        let omega = 2 * Float.pi * cutoffHz / sampleRate
        let cs = cos(omega), sn = sin(omega)
        let alpha = sn / (2 * Q)
        let b0 = (1 + cs) / 2
        let b1 = -(1 + cs)
        let b2 = (1 + cs) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cs
        let a2 = 1 - alpha
        return Coefficients(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }

    public static func lowPass(cutoffHz: Float,
                               sampleRate: Float,
                               Q: Float = 0.707) -> Coefficients {
        let omega = 2 * Float.pi * cutoffHz / sampleRate
        let cs = cos(omega), sn = sin(omega)
        let alpha = sn / (2 * Q)
        let b0 = (1 - cs) / 2
        let b1 = 1 - cs
        let b2 = (1 - cs) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cs
        let a2 = 1 - alpha
        return Coefficients(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }
}
