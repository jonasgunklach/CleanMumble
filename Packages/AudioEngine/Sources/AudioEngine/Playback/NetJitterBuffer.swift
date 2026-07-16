//
//  NetJitterBuffer.swift
//  AudioEngine
//
//  Pull-model, per-sender jitter buffer. The network thread pushes sequenced
//  Opus packets; the shared DecodeWorker calls `refill()` which tops up the
//  sender's PCM ring 1–2 frames ahead of the render head, deciding per frame
//  between direct decode, Opus in-band FEC recovery, and PLC synthesis.
//
//  The depth estimator (RFC 3550-style jitter EMA + variance → target depth
//  clamped to 40…200 ms) carries over from the previous timer-driven
//  implementation — the *pacing* is what changed: the device clock drains the
//  ring, and refill only produces what the ring can hold, so there is no
//  wall-clock timer to drift against and no "PLC forever" runaway (after
//  `maxConsecutivePLC` synthesized frames the utterance simply ends).
//

import Foundation
import AVFAudio
import Opus

public final class NetJitterBuffer {

    /// PCM sink: the sender's SPSC ring, drained by the render callback.
    let ring: SPSCRingBuffer

    // ---- Stats (read by the adaptation loop via snapshotAndReset) ----------
    private var framesPlayed = 0
    private var fecRecovered = 0
    private var plcSynthesised = 0
    public private(set) var targetDepthMs: Double = 60.0

    // ---- State (guarded by `lock`; touched by network + decode threads) ----
    private let lock = NSLock()
    private let decoder: Opus.Decoder
    private var packets: [UInt32: Data] = [:]
    private var nextSeq: UInt32?
    private var buffering = false
    private var bufferingDeadline: TimeInterval = 0
    private var lastArrival: TimeInterval?
    private var jitterEMA: Double = 0
    private var jitterVAR: Double = 0
    private var consecutivePLC = 0
    private var frameSize = 960                    // samples @48 kHz, learned from stream
    private var lastUnderruns = 0
    /// A terminator arrived but there was still buffered audio to play. We
    /// finish draining it before resetting, so the last syllable isn't cut
    /// when the terminator shares a TCP batch with the final audio frames.
    private var pendingTerminator = false
    /// The sender's frame_number stride. Mumble counts 10 ms segments, so a
    /// 20 ms-frame sender steps by 2, 40 ms by 4. 0 = not yet learned; until
    /// then we assume 1. Assuming 1 against a step-2 sender makes every packet
    /// look like it has a lost neighbour → ~50 % spurious FEC → 2× stretched
    /// "robot" audio and phantom packet loss in the stats.
    private var seqStep: UInt32 = 0

    private let maxConsecutivePLC = 25
    private let sampleRate = 48_000.0

    // Decode scratch (decode-worker thread only).
    private var pcmScratch = [Float](repeating: 0, count: 5_760)

    init(decoder: Opus.Decoder, ring: SPSCRingBuffer) {
        self.decoder = decoder
        self.ring = ring
    }

    public convenience init?(ringCapacityFrames: Int = 24_000) {
        guard let fmt = AVAudioFormat(opusPCMFormat: .float32, sampleRate: 48_000, channels: 1),
              let dec = try? Opus.Decoder(format: fmt) else { return nil }
        self.init(decoder: dec,
                  ring: SPSCRingBuffer(capacityFrames: ringCapacityFrames,
                                       overflowPolicy: .dropOldest))
    }

    // MARK: - Network side

    /// Hand over a freshly arrived packet (any thread).
    public func push(seq: UInt32, opus: Data) {
        let now = Self.monotonicNow()
        lock.lock(); defer { lock.unlock() }

        if let last = lastArrival {
            let deltaMs = (now - last) * 1000
            let frameMs = Double(frameSize) / sampleRate * 1000
            let jitter = abs(deltaMs - frameMs)
            jitterEMA = 0.95 * jitterEMA + 0.05 * jitter
            let dev = jitter - jitterEMA
            jitterVAR = 0.95 * jitterVAR + 0.05 * dev * dev
            targetDepthMs = min(200, max(40, 2 * (jitterEMA + jitterVAR.squareRoot())))
        }
        lastArrival = now

        // A new utterance started (sequence restarts near 0) before the
        // previous terminator finished draining — finalize the old one now so
        // its stale nextSeq/stride don't reject the fresh stream as ancient.
        if pendingTerminator, let nxt = nextSeq, seq < nxt {
            hardResetLocked()
        }

        // Ancient-packet drop, scaled by the sender's stride so the window is
        // ~8 frames regardless of frame size.
        if let nxt = nextSeq, seq < nxt, nxt - seq > 8 * max(1, seqStep) { return }
        packets[seq] = opus

        if nextSeq == nil {
            nextSeq = seq
            buffering = true
            bufferingDeadline = now + targetDepthMs / 1000
        }
    }

    /// Hard reset — drop everything immediately (disconnect / speaker switch).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        hardResetLocked()
    }

    /// Terminator: the sender finished this utterance. If there's still
    /// buffered audio in flight, defer the reset until the decode worker has
    /// drained it (so the last syllable isn't clipped when the terminator
    /// arrives in the same TCP batch as the final frames); otherwise reset now.
    public func terminate() {
        lock.lock(); defer { lock.unlock() }
        if nextSeq == nil && packets.isEmpty {
            hardResetLocked()
        } else {
            pendingTerminator = true
        }
    }

    /// Must be called with `lock` held.
    private func hardResetLocked() {
        packets.removeAll(keepingCapacity: true)
        nextSeq = nil
        buffering = false
        consecutivePLC = 0
        lastArrival = nil
        seqStep = 0
        pendingTerminator = false
        try? decoder.resetState()
    }

    /// (played, fec, plc) since the last call; clears the window counters.
    public func snapshotAndReset() -> (played: Int, fec: Int, plc: Int) {
        lock.lock(); defer { lock.unlock() }
        let s = (framesPlayed, fecRecovered, plcSynthesised)
        framesPlayed = 0; fecRecovered = 0; plcSynthesised = 0
        return s
    }

    /// True when an utterance is anchored or packets are waiting.
    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return nextSeq != nil || !packets.isEmpty
    }

    // MARK: - Decode-worker side

    private enum Action { case none, play(Data), fec(Data), plc, ended }

    /// Top up the PCM ring toward `targetDepth + 1 frame`. Called by the
    /// shared DecodeWorker every ~10 ms and after every push. Decoding
    /// happens outside the lock.
    public func refill() {
        // Render-side underruns mean our depth was too small — grow it.
        let underruns = ring.underrunCount.load(ordering: .relaxed)
        if underruns > lastUnderruns {
            lock.lock()
            if nextSeq != nil {                  // only while actually playing
                targetDepthMs = min(200, targetDepthMs + 10)
            }
            lock.unlock()
            lastUnderruns = underruns
        }

        while true {
            let action: Action = decideNextAction()
            switch action {
            case .none, .ended:
                return
            case .play(let data):
                let n = decode(data, fec: false)
                if n > 0 {
                    lock.lock(); framesPlayed += 1; frameSize = n; lock.unlock()
                    emit(n)
                }
            case .fec(let data):
                let n = decode(data, fec: true)
                if n > 0 {
                    lock.lock(); fecRecovered += 1; lock.unlock()
                    emit(n)
                } else {
                    synthesizePLC()
                }
            case .plc:
                synthesizePLC()
            }
        }
    }

    private func decideNextAction() -> Action {
        lock.lock(); defer { lock.unlock() }
        detectSeqStep()
        guard let want = nextSeq else { return .ended }
        let step = max(1, seqStep)
        let now = Self.monotonicNow()

        // Initial buffering: hold until the deadline unless enough audio is
        // already queued to cover the target depth.
        if buffering {
            let queuedMs = Double(packets.count * frameSize) / sampleRate * 1000
            if now < bufferingDeadline && queuedMs < targetDepthMs { return .none }
            buffering = false
        }

        // Stop when the ring already holds target depth + 1 frame of audio.
        let aheadTarget = Int(targetDepthMs / 1000 * sampleRate) + frameSize
        if ring.availableToRead >= aheadTarget { return .none }

        if let p = packets.removeValue(forKey: want) {
            nextSeq = want &+ step
            consecutivePLC = 0
            gc(playhead: want &+ step)
            return .play(p)
        }
        // The next packet (want + step) carries in-band FEC for `want`.
        if let next = packets[want &+ step] {
            nextSeq = want &+ step
            consecutivePLC = 0
            return .fec(next)
        }
        // Terminator already received and everything buffered has drained →
        // clean end, no PLC tail. (If packets remain past a gap we fall through
        // and bridge to them so they aren't cut.)
        if pendingTerminator, packets.isEmpty {
            hardResetLocked()
            return .ended
        }
        // Neither present. Only conceal once the packet is genuinely late.
        let frameMs = Double(frameSize) / sampleRate * 1000
        let sinceArrival = (lastArrival.map { (now - $0) * 1000 }) ?? .infinity
        if sinceArrival > frameMs * 1.5 {
            consecutivePLC += 1
            if consecutivePLC > maxConsecutivePLC {
                // Sender stopped without a terminator: end the utterance.
                nextSeq = nil
                buffering = false
                consecutivePLC = 0
                return .ended
            }
            nextSeq = want &+ step
            return .plc
        }
        return .none
    }

    /// Learn the sender's frame_number stride from the buffered packets. Uses
    /// the smallest positive gap between queued sequence numbers (robust to a
    /// dropped first packet or light reordering), so one detection survives
    /// the whole utterance. Must be called with `lock` held.
    private func detectSeqStep() {
        guard seqStep == 0, packets.count >= 2 else { return }
        let keys = packets.keys.sorted()
        var minGap = UInt32.max
        for i in 1..<keys.count {
            let g = keys[i] &- keys[i - 1]
            if g > 0 { minGap = min(minGap, g) }
        }
        guard minGap >= 1, minGap <= 8 else { return }
        seqStep = minGap
        // The drain loop may have advanced nextSeq by the provisional stride
        // of 1 before we knew the real one — snap it back onto the sender's
        // grid so we stop chasing sequence numbers that will never arrive.
        if let nxt = nextSeq, let base = keys.first, nxt >= base {
            nextSeq = base &+ ((nxt &- base) / minGap) &* minGap
        }
    }

    private func gc(playhead: UInt32) {
        packets = packets.filter { $0.key &+ 8 >= playhead }
    }

    private func decode(_ data: Data, fec: Bool) -> Int {
        let fs = Int32(max(frameSize, 960))
        return (try? data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return try pcmScratch.withUnsafeMutableBufferPointer { buf in
                try decoder.decodeFloat(base, length: Int32(data.count),
                                        into: buf.baseAddress!,
                                        frameSize: fs, decodeFEC: fec)
            }
        }) ?? 0
    }

    private func synthesizePLC() {
        let fs = Int32(frameSize)
        let n = (try? pcmScratch.withUnsafeMutableBufferPointer { buf in
            try decoder.concealLostFrame(into: buf.baseAddress!, frameSize: fs)
        }) ?? 0
        if n > 0 {
            lock.lock(); plcSynthesised += 1; lock.unlock()
            emit(n)
        }
    }

    private func emit(_ n: Int) {
        pcmScratch.withUnsafeBufferPointer { buf in
            _ = ring.write(buf.baseAddress!, count: n)
        }
    }

    static func monotonicNow() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}
