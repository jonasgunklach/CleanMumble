//
//  PlaybackEngine.swift
//  AudioEngine
//
//  Far-end data plane. The network thread submits sequenced Opus packets per
//  sender; one shared DecodeWorker keeps each sender's PCM ring topped up via
//  its NetJitterBuffer; the backend's render callback PULLS the mix at the
//  device clock — the only pacemaker in the playback path.
//
//  Render-side realtime rules: the callback touches only SPSC rings, ramped
//  gains, atomics, and a cached sender-pointer table refreshed with a
//  trylock (never a blocking lock). Channel objects retired by the control
//  side stay strongly referenced for a grace period, so a stale cache entry
//  can never dangle.
//

import Foundation
import Synchronization
import AudioCore

public final class PlaybackEngine: @unchecked Sendable {

    public static let maxSenders = 32

    // ---- Per-sender channel -------------------------------------------------

    final class SenderChannel {
        let id: Int32
        let jitter: NetJitterBuffer
        let gain = RampedGain(1.0)
        var ring: SPSCRingBuffer { jitter.ring }
        /// Wall-clock of last packet; drives idle retirement.
        let lastActivity: Atomic<UInt64>

        init?(id: Int32) {
            guard let jb = NetJitterBuffer() else { return nil }
            self.id = id
            self.jitter = jb
            self.lastActivity = Atomic<UInt64>(DispatchTime.now().uptimeNanoseconds)
        }
    }

    // ---- Control / network-side state ---------------------------------------

    private let stateLock = NSLock()
    private var channels: [Int32: SenderChannel] = [:]
    /// Channels removed from the table but kept alive until `graceDeadline`
    /// so the render cache can never dereference a freed pointer.
    private var graveyard: [(channel: SenderChannel, deadline: UInt64)] = []
    /// Bumped on every membership change; render refreshes its cache on it.
    private let tableGeneration = Atomic<Int>(0)
    private let renderLock = os_unfair_lock_t.allocate(capacity: 1)

    // ---- Render-side cache (render thread only) ------------------------------

    private let cachePtrs: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    private var cacheCount = 0
    private var cacheGeneration = -1

    // ---- Mix bus -------------------------------------------------------------

    public let masterGain = RampedGain(1.0)
    private let deafenedFlag = Atomic<Bool>(false)
    public var isDeafened: Bool {
        get { deafenedFlag.load(ordering: .relaxed) }
        set { deafenedFlag.store(newValue, ordering: .relaxed) }
    }
    private let mixScratch: UnsafeMutablePointer<Float>
    private let senderScratch: UnsafeMutablePointer<Float>
    private let monoScratch: UnsafeMutablePointer<Float>
    private let scratchCap = 8_192
    /// Output level for UI (bit patterns of Float peak / rms).
    private let outPeakBits = Atomic<UInt32>(0)
    private let outRMSBits = Atomic<UInt32>(0)
    /// Heartbeat for the controller's stall watchdog.
    private let renderTicks = Atomic<Int>(0)
    public var renderHeartbeat: Int { renderTicks.load(ordering: .relaxed) }

    // ---- Decode worker --------------------------------------------------------

    private let wakeup = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)

    public init() {
        renderLock.initialize(to: os_unfair_lock())
        cachePtrs = .allocate(capacity: Self.maxSenders)
        cachePtrs.initialize(repeating: nil, count: Self.maxSenders)
        mixScratch = .allocate(capacity: scratchCap)
        mixScratch.initialize(repeating: 0, count: scratchCap)
        senderScratch = .allocate(capacity: scratchCap)
        senderScratch.initialize(repeating: 0, count: scratchCap)
        monoScratch = .allocate(capacity: scratchCap)
        monoScratch.initialize(repeating: 0, count: scratchCap)
    }

    deinit {
        renderLock.deinitialize(count: 1)
        renderLock.deallocate()
        cachePtrs.deinitialize(count: Self.maxSenders)
        cachePtrs.deallocate()
        mixScratch.deinitialize(count: scratchCap)
        mixScratch.deallocate()
        senderScratch.deinitialize(count: scratchCap)
        senderScratch.deallocate()
        monoScratch.deinitialize(count: scratchCap)
        monoScratch.deallocate()
    }

    // MARK: - Lifecycle (control plane)

    public func start() {
        guard !running.load(ordering: .relaxed) else { return }
        running.store(true, ordering: .releasing)
        let t = Thread { [weak self] in self?.decodeLoop() }
        t.name = "audio.decode.worker"
        t.qualityOfService = .userInteractive
        t.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        wakeup.signal()
    }

    /// Drop all senders (disconnect).
    public func removeAllSenders() {
        stateLock.lock()
        let all = Array(channels.values)
        channels.removeAll()
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        for ch in all { graveyard.append((ch, deadline)) }
        stateLock.unlock()
        tableGeneration.wrappingAdd(1, ordering: .releasing)
    }

    public func removeSender(_ id: Int32) {
        stateLock.lock()
        if let ch = channels.removeValue(forKey: id) {
            graveyard.append((ch, DispatchTime.now().uptimeNanoseconds + 1_000_000_000))
        }
        stateLock.unlock()
        tableGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// Per-user playback volume (any thread; ramped, click-free).
    public func setSenderGain(_ id: Int32, gain: Float) {
        stateLock.lock(); defer { stateLock.unlock() }
        channels[id]?.gain.target = gain
    }

    /// Per-sender jitter stats for the network adaptation loop.
    public func snapshotStats() -> (played: Int, fec: Int, plc: Int, maxDepthMs: Double) {
        stateLock.lock()
        let list = Array(channels.values)
        stateLock.unlock()
        var played = 0, fec = 0, plc = 0
        var maxDepth = 0.0
        for ch in list {
            let s = ch.jitter.snapshotAndReset()
            played += s.played; fec += s.fec; plc += s.plc
            maxDepth = max(maxDepth, ch.jitter.targetDepthMs)
        }
        return (played, fec, plc, maxDepth)
    }

    // MARK: - Network side

    /// Submit one voice packet from the wire. Thread-safe; cheap enough for
    /// the network receive path.
    public func submit(sender: Int32, seq: UInt32, opus: Data, isTerminator: Bool) {
        if deafenedFlag.load(ordering: .relaxed) { return }
        stateLock.lock()
        var channel = channels[sender]
        if channel == nil, !isTerminator {
            if channels.count < Self.maxSenders, let fresh = SenderChannel(id: sender) {
                channels[sender] = fresh
                channel = fresh
                stateLock.unlock()
                tableGeneration.wrappingAdd(1, ordering: .releasing)
                stateLock.lock()
            }
        }
        stateLock.unlock()
        guard let ch = channel else { return }
        ch.lastActivity.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
        if isTerminator {
            ch.jitter.reset()
        } else {
            ch.jitter.push(seq: seq, opus: opus)
            wakeup.signal()
        }
    }

    // MARK: - Decode worker

    private func decodeLoop() {
        while running.load(ordering: .acquiring) {
            _ = wakeup.wait(timeout: .now() + .milliseconds(10))
            if !running.load(ordering: .acquiring) { break }

            stateLock.lock()
            let list = Array(channels.values)
            // Bury channels whose grace period has elapsed.
            let now = DispatchTime.now().uptimeNanoseconds
            if !graveyard.isEmpty {
                graveyard.removeAll { $0.deadline <= now }
            }
            stateLock.unlock()

            var membershipChanged = false
            for ch in list {
                ch.jitter.refill()
                // Retire senders idle for > 30 s.
                let idleNs = now &- ch.lastActivity.load(ordering: .relaxed)
                if idleNs > 30_000_000_000, !ch.jitter.isActive {
                    stateLock.lock()
                    if channels[ch.id] === ch {
                        channels.removeValue(forKey: ch.id)
                        graveyard.append((ch, now + 1_000_000_000))
                        membershipChanged = true
                    }
                    stateLock.unlock()
                }
            }
            if membershipChanged {
                tableGeneration.wrappingAdd(1, ordering: .releasing)
            }
        }
    }

    // MARK: - Render side (REALTIME — called by the backend)

    /// Pull `frames` of mono 48 kHz mix into `dst`. Realtime-safe: SPSC reads,
    /// atomics, a trylock-guarded cache refresh, bounded arithmetic.
    public func pullMix(into dst: UnsafeMutablePointer<Float>, frames: Int) {
        renderTicks.wrappingAdd(1, ordering: .relaxed)
        let n = min(frames, scratchCap)
        mixScratch.update(repeating: 0, count: n)

        if !deafenedFlag.load(ordering: .relaxed) {
            refreshCacheIfStale()
            for i in 0..<cacheCount {
                guard let raw = cachePtrs[i] else { continue }
                let ch = Unmanaged<SenderChannel>.fromOpaque(raw).takeUnretainedValue()
                // Only count underruns while an utterance is actually being
                // decoded — an idle ring reading silence is not an underrun.
                let had = ch.ring.availableToRead
                ch.ring.read(into: senderScratch, count: n)
                if had == 0 {
                    ch.gain.advance(count: n)
                    continue
                }
                ch.gain.applyInPlace(senderScratch, count: n)
                for s in 0..<n { mixScratch[s] += senderScratch[s] }
            }
        }

        masterGain.applyInPlace(mixScratch, count: n)

        // Soft clip: leave |v| < 0.7 untouched, compress above, hard-cap at
        // ±0.98 — avoids the harsh fuzz of naive clamping when talkers sum.
        var peak: Float = 0
        var sumSq: Float = 0
        for i in 0..<n {
            var v = mixScratch[i]
            let a = abs(v)
            if a > 0.7 {
                v = v / (1.0 + (a - 0.7) * 1.5)
                v = max(-0.98, min(0.98, v))
                mixScratch[i] = v
            }
            let av = abs(v)
            if av > peak { peak = av }
            sumSq += v * v
        }
        outPeakBits.store(peak.bitPattern, ordering: .relaxed)
        outRMSBits.store((sumSq / Float(max(n, 1))).squareRoot().bitPattern, ordering: .relaxed)

        dst.update(from: mixScratch, count: n)
        if frames > n {
            dst.advanced(by: n).update(repeating: 0, count: frames - n)
        }
    }

    /// Same as `pullMix`, fanned out to `channels`-interleaved frames
    /// (RawBackend AUHAL path).
    public func pullInterleaved(into dst: UnsafeMutablePointer<Float>,
                                frames: Int, channels chans: Int) {
        let n = min(frames, scratchCap)
        pullMix(into: monoScratch, frames: n)
        for i in 0..<n {
            let v = monoScratch[i]
            for c in 0..<chans { dst[i * chans + c] = v }
        }
        if frames > n {
            dst.advanced(by: n * chans).update(repeating: 0, count: (frames - n) * chans)
        }
    }

    /// UI meter: (peak, rms) of the most recent render block.
    public func outputLevel() -> (peak: Float, rms: Float) {
        (Float(bitPattern: outPeakBits.load(ordering: .relaxed)),
         Float(bitPattern: outRMSBits.load(ordering: .relaxed)))
    }

    private func refreshCacheIfStale() {
        let gen = tableGeneration.load(ordering: .acquiring)
        guard gen != cacheGeneration else { return }
        // Trylock only — if the control side is mutating right now, keep the
        // old cache one more callback (grace refs keep it safe).
        guard os_unfair_lock_trylock(renderLock) else { return }
        if stateLock.try() {
            var i = 0
            for ch in channels.values where i < Self.maxSenders {
                cachePtrs[i] = Unmanaged.passUnretained(ch).toOpaque()
                i += 1
            }
            cacheCount = i
            cacheGeneration = gen
            stateLock.unlock()
        }
        os_unfair_lock_unlock(renderLock)
    }
}
