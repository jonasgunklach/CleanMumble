import Foundation
import os.lock

/// Realtime-safe linear gain stage with hard clipping detection.
///
/// `gain` is a linear multiplier (0…∞). 1.0 = unity. The processor is
/// thread-safe for concurrent `gain`-setter / process pairings via an
/// `os_unfair_lock` around the scalar (single load is also fine on x86/arm
/// for Float, but the lock keeps things tidy and adds < 50 ns).
public final class GainProcessor: AudioProcessor {
    private var _gain: Float = 1.0
    private var _clipped: Int = 0
    private var lock = os_unfair_lock()

    public init(gain: Float = 1.0) { self._gain = gain }

    public var gain: Float {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _gain }
        set { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
              _gain = max(0, min(8.0, newValue)) }
    }

    /// Total samples that hit |x| > 1.0 (i.e. were clipped) since last read.
    public var clippedSamples: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _clipped
    }

    public func resetClip() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        _clipped = 0
    }

    public func process(_ frame: AudioFrame) -> AudioFrame {
        os_unfair_lock_lock(&lock)
        let g = _gain
        os_unfair_lock_unlock(&lock)
        if g == 1.0 {
            // Still need to count clipped samples (caller may have over-driven
            // upstream). Cheap loop.
            var clip = 0
            for s in frame.samples where abs(s) > 1.0 { clip += 1 }
            if clip > 0 {
                os_unfair_lock_lock(&lock); _clipped &+= clip; os_unfair_lock_unlock(&lock)
            }
            return frame
        }
        var out = frame.samples
        var clip = 0
        for i in 0..<out.count {
            var v = out[i] * g
            if v > 1.0 { v = 1.0; clip += 1 }
            else if v < -1.0 { v = -1.0; clip += 1 }
            out[i] = v
        }
        if clip > 0 {
            os_unfair_lock_lock(&lock); _clipped &+= clip; os_unfair_lock_unlock(&lock)
        }
        return AudioFrame(format: frame.format,
                          samples: out,
                          sampleTime: frame.sampleTime)
    }

    /// Realtime variant for callers that already operate on raw buffers
    /// (the CoreAudio render callback). No allocations.
    public func applyInPlace(_ buf: UnsafeMutablePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock); let g = _gain; os_unfair_lock_unlock(&lock)
        if g == 1.0 { return }
        var clip = 0
        for i in 0..<count {
            var v = buf[i] * g
            if v > 1.0 { v = 1.0; clip += 1 }
            else if v < -1.0 { v = -1.0; clip += 1 }
            buf[i] = v
        }
        if clip > 0 {
            os_unfair_lock_lock(&lock); _clipped &+= clip; os_unfair_lock_unlock(&lock)
        }
    }
}
