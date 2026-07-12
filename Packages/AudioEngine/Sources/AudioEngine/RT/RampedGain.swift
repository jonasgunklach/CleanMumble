//
//  RampedGain.swift
//  AudioEngine
//
//  Click-free gain: any thread sets `target`; the audio-side consumer applies
//  a per-sample linear ramp toward it. A raw non-atomic Float shared across
//  threads (the old CoreAudioOutput.gain) is a data race; an instant jump is
//  a click ("zipper noise"). This is both correct and inaudible.
//

import Synchronization

public final class RampedGain: @unchecked Sendable {

    /// Bit-pattern-encoded Float so it can live in an Atomic<UInt32>.
    private let targetBits: Atomic<UInt32>
    /// Current value — touched only by the audio-side consumer.
    private var current: Float
    /// Per-sample step. 48 kHz * 0.005 s = 240 samples for a full 0→1 swing.
    private let step: Float

    public init(_ initial: Float = 1.0, rampSeconds: Double = 0.005, sampleRate: Double = 48_000) {
        self.targetBits = Atomic<UInt32>(initial.bitPattern)
        self.current = initial
        self.step = Float(1.0 / (rampSeconds * sampleRate))
    }

    /// Thread-safe. Clamped to [0, 8] (+18 dB) for safety.
    public var target: Float {
        get { Float(bitPattern: targetBits.load(ordering: .relaxed)) }
        set { targetBits.store(min(max(newValue, 0), 8).bitPattern, ordering: .relaxed) }
    }

    /// Audio-side: multiply `buf` in place, ramping toward the target.
    /// Realtime-safe.
    public func applyInPlace(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        let t = target
        if current == t {
            if t == 1.0 { return }
            for i in 0..<count { buf[i] *= t }
            return
        }
        var c = current
        let s = step
        for i in 0..<count {
            if c < t { c = min(c + s, t) } else if c > t { c = max(c - s, t) }
            buf[i] *= c
        }
        current = c
    }

    /// Audio-side: advance the ramp without applying (used when a channel is
    /// silent this cycle so a pending change still completes).
    public func advance(count: Int) {
        let t = target
        if current == t { return }
        let delta = step * Float(count)
        if current < t { current = min(current + delta, t) }
        else { current = max(current - delta, t) }
    }
}
