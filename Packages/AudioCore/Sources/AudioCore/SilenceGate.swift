import Foundation
import os.lock

/// Voice-activity / silence gate with hysteresis and hold time.
///
/// Signal is gated open when the smoothed RMS rises above `openThreshold`,
/// and closes only when it drops below `closeThreshold` for at least
/// `holdSeconds`. Hysteresis prevents the chatter you get with a single
/// threshold; hold time keeps the gate from chopping the tails of words.
public final class SilenceGate: AudioProcessor {
    public var openThreshold: Float
    public var closeThreshold: Float
    public var holdSeconds: Double
    public var attackSeconds: Double = 0.005
    public var releaseSeconds: Double = 0.080
    public var sampleRate: Double = 48_000

    private var smoothedRMS: Float = 0
    private var open: Bool = false
    private var samplesBelowClose: Int = 0
    private var lock = os_unfair_lock()

    public init(openThreshold: Float = 0.012,
                closeThreshold: Float = 0.006,
                holdSeconds: Double = 0.250) {
        precondition(openThreshold >= closeThreshold)
        self.openThreshold = openThreshold
        self.closeThreshold = closeThreshold
        self.holdSeconds = holdSeconds
    }

    public var isOpen: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return open
    }

    public var smoothedLevel: Float {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return smoothedRMS
    }

    public func process(_ frame: AudioFrame) -> AudioFrame {
        sampleRate = frame.format.sampleRate
        let count = frame.samples.count
        var sumSq: Float = 0
        for s in frame.samples { sumSq += s * s }
        let blockRMS = sqrt(sumSq / Float(max(1, count)))
        let dt = Float(count) / Float(sampleRate)
        let attack = 1 - expf(-dt / Float(attackSeconds))
        let release = 1 - expf(-dt / Float(releaseSeconds))
        os_unfair_lock_lock(&lock)
        if blockRMS > smoothedRMS {
            smoothedRMS += (blockRMS - smoothedRMS) * attack
        } else {
            smoothedRMS += (blockRMS - smoothedRMS) * release
        }
        if !open {
            if smoothedRMS >= openThreshold {
                open = true
                samplesBelowClose = 0
            }
        } else {
            if smoothedRMS < closeThreshold {
                samplesBelowClose += count
                let holdSamples = Int(holdSeconds * sampleRate)
                if samplesBelowClose >= holdSamples {
                    open = false
                    samplesBelowClose = 0
                }
            } else {
                samplesBelowClose = 0
            }
        }
        let isOpen = open
        os_unfair_lock_unlock(&lock)
        if isOpen { return frame }
        // Gate closed — return silence (preserves frame timing).
        return AudioFrame.silence(format: frame.format,
                                  frameCount: frame.frameCount,
                                  sampleTime: frame.sampleTime)
    }

    public func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        smoothedRMS = 0; open = false; samplesBelowClose = 0
    }
}
