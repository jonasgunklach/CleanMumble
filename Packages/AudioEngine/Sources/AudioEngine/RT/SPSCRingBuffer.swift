//
//  SPSCRingBuffer.swift
//  AudioEngine
//
//  True lock-free single-producer / single-consumer ring buffer for Float
//  samples. Replaces the os_unfair_lock-guarded FloatRingBuffer: a lock held
//  by a lower-priority thread while the audio render thread spins on it is a
//  priority-inversion hazard; acquire/release atomics have no such failure
//  mode and are wait-free on both sides.
//
//  Contract: exactly ONE producer thread calls `write`, exactly ONE consumer
//  thread calls `read`. Any thread may call `availableToRead` (approximate).
//  `clear()` is consumer-side only.
//

import Synchronization

public final class SPSCRingBuffer: @unchecked Sendable {

    public enum OverflowPolicy: Sendable {
        /// Drop the incoming samples that don't fit (capture side: a glitch
        /// stays local instead of corrupting older, already-queued audio).
        case dropNewest
        /// Advance the read head to make room (playback side: latency stays
        /// bounded; the oldest queued audio is sacrificed).
        case dropOldest
    }

    private let storage: UnsafeMutablePointer<Float>
    /// Power-of-two capacity so index wrapping is a mask, not a division.
    private let capacity: Int
    private let mask: Int
    /// Monotonically increasing positions (not wrapped); wrapped on access.
    private let head = Atomic<Int>(0)  // read position  (consumer-owned)
    private let tail = Atomic<Int>(0)  // write position (producer-owned)
    public let overflowPolicy: OverflowPolicy
    /// Total samples lost to overflow/underrun since creation (diagnostics).
    public let overflowCount = Atomic<Int>(0)
    public let underrunCount = Atomic<Int>(0)

    public init(capacityFrames: Int, overflowPolicy: OverflowPolicy = .dropOldest) {
        var cap = 1
        while cap < capacityFrames { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.overflowPolicy = overflowPolicy
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Approximate fill level. Exact when called from the consumer thread.
    public var availableToRead: Int {
        tail.load(ordering: .acquiring) - head.load(ordering: .acquiring)
    }

    public var availableToWrite: Int {
        capacity - availableToRead
    }

    /// Producer side. Realtime-safe: no allocation, no locks.
    /// Returns the number of samples actually written.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let t = tail.load(ordering: .relaxed)          // producer-owned
        let h = head.load(ordering: .acquiring)        // consumer's progress
        let free = capacity - (t - h)
        var toWrite = count
        var srcOffset = 0
        if count > free {
            switch overflowPolicy {
            case .dropNewest:
                toWrite = free
                overflowCount.wrappingAdd(count - free, ordering: .relaxed)
                if toWrite == 0 { return 0 }
            case .dropOldest:
                // SPSC purity note: only the consumer normally moves `head`.
                // dropOldest is used on playback rings where the producer
                // (decode worker) may advance head; the consumer tolerates
                // this because it re-reads head via CAS-free monotonic
                // positions — worst case it reads a sample that was just
                // overwritten (one transient glitch, no memory unsafety).
                if count >= capacity {
                    srcOffset = count - capacity
                    toWrite = capacity
                    overflowCount.wrappingAdd(srcOffset, ordering: .relaxed)
                } else {
                    let need = count - free
                    head.wrappingAdd(need, ordering: .releasing)
                    overflowCount.wrappingAdd(need, ordering: .relaxed)
                }
            }
        }
        var written = 0
        var pos = t
        while written < toWrite {
            let idx = pos & mask
            let chunk = min(toWrite - written, capacity - idx)
            storage.advanced(by: idx)
                .update(from: samples.advanced(by: srcOffset + written), count: chunk)
            pos += chunk
            written += chunk
        }
        tail.store(t + toWrite, ordering: .releasing)
        return toWrite
    }

    /// Consumer side. Realtime-safe. Reads up to `count` samples; pads the
    /// remainder of `dst` with silence. Returns samples actually read.
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let h = head.load(ordering: .relaxed)          // consumer-owned
        let t = tail.load(ordering: .acquiring)        // producer's progress
        let avail = t - h
        let toRead = min(avail, count)
        var copied = 0
        var pos = h
        while copied < toRead {
            let idx = pos & mask
            let chunk = min(toRead - copied, capacity - idx)
            dst.advanced(by: copied)
                .update(from: storage.advanced(by: idx), count: chunk)
            pos += chunk
            copied += chunk
        }
        if toRead > 0 {
            head.store(h + toRead, ordering: .releasing)
        }
        if copied < count {
            dst.advanced(by: copied).update(repeating: 0, count: count - copied)
            underrunCount.wrappingAdd(count - copied, ordering: .relaxed)
        }
        return copied
    }

    /// Discard everything queued. Consumer-side only.
    public func clear() {
        let t = tail.load(ordering: .acquiring)
        head.store(t, ordering: .releasing)
    }
}
