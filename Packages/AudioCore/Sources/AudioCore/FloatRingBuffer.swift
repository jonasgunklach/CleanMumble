import Foundation
import os.lock

/// Single-producer / single-consumer ring buffer of Float samples.
///
/// Critical sections are O(chunk) memcpy, suitable for audio render
/// callbacks at typical buffer sizes (256–4096 frames).
public final class FloatRingBuffer {
    private var storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private var head = 0   // read index
    private var tail = 0   // write index
    private var lock = os_unfair_lock()
    /// Counts samples dropped due to overflow since last `clear()`.
    public private(set) var droppedSamples: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 1)
        self.capacity = capacity
        let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        p.initialize(repeating: 0, count: capacity)
        self.storage = UnsafeMutableBufferPointer(start: p, count: capacity)
    }

    deinit {
        storage.baseAddress?.deinitialize(count: capacity)
        storage.baseAddress?.deallocate()
    }

    public var availableRead: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (tail &- head + capacity) % capacity
    }

    public var availableWrite: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return capacity - 1 - (tail &- head + capacity) % capacity
    }

    /// Writes `count` samples; if the buffer would overflow, drops the
    /// OLDEST data (so live audio prefers freshest content over silence).
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let cap = capacity
        let used = (tail &- head + cap) % cap
        let free = cap - used - 1
        if count > free {
            let drop = count - free
            head = (head + drop) % cap
            droppedSamples &+= drop
        }
        var written = 0
        var t = tail
        while written < count {
            let chunk = min(count - written, cap - t)
            storage.baseAddress!.advanced(by: t)
                .update(from: samples.advanced(by: written), count: chunk)
            t = (t + chunk) % cap
            written += chunk
        }
        tail = t
    }

    /// Convenience for tests / Swift callers.
    public func write(_ array: [Float]) {
        array.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress { write(base, count: array.count) }
        }
    }

    /// Reads up to `count` samples. Pads remainder with silence so the
    /// caller always gets a full buffer.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        os_unfair_lock_lock(&lock)
        let cap = capacity
        let avail = (tail &- head + cap) % cap
        let toCopy = min(avail, count)
        var copied = 0
        var h = head
        while copied < toCopy {
            let chunk = min(toCopy - copied, cap - h)
            dst.advanced(by: copied)
                .update(from: storage.baseAddress!.advanced(by: h), count: chunk)
            h = (h + chunk) % cap
            copied += chunk
        }
        head = h
        os_unfair_lock_unlock(&lock)
        if copied < count {
            (dst + copied).update(repeating: 0, count: count - copied)
        }
        return copied
    }

    public func read(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { ptr in
            _ = read(into: ptr.baseAddress!, count: count)
        }
        return out
    }

    public func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0; tail = 0; droppedSamples = 0
    }
}
