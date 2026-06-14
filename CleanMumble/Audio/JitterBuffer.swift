//
//  JitterBuffer.swift
//  CleanMumble
//
//  Per-sender, sequence-aware jitter buffer with Opus FEC + PLC, modelled on
//  the algorithms used by Discord's voice client and the speex/opus jitter
//  buffer reference design.
//
//  Goals:
//   • Absorb network jitter without introducing audible underrun clicks.
//   • Recover lost frames using Opus' in-band Forward Error Correction
//     (decode the *previous* frame from the *next* packet's bytes).
//   • Synthesise plausible audio for fully-missing frames using Packet Loss
//     Concealment (NULL-data decode).
//   • Adapt depth to observed network jitter — small (40 ms) on a clean LAN,
//     larger (up to 200 ms) over flaky Wi-Fi or cellular tethering.
//
//  Threading:
//   • `push(seq:opus:)` is called on the network thread (RealMumbleClient).
//   • A GCD timer fires every 10 ms on `queue` to drain frames; each emitted
//     PCM frame is delivered through `onFrame` (must be realtime-safe).
//   • Mutable state is guarded by `lock`.
//

import Foundation
import Opus
import OpusControl
import os

/// A single per-speaker jitter buffer. Construct one per remote user as their
/// first packet arrives; tear down when the user leaves the channel.
final class JitterBuffer {

    /// Frame size in samples (mono 48 kHz). Detected from the first decoded
    /// packet; defaults to 20 ms (960 samples) which is what CleanMumble emits.
    private(set) var frameSize: Int = 960

    /// Sample rate of `onFrame` PCM.
    let sampleRate: Double = 48_000

    /// Called once per emitted frame (drained or PLC). Must be realtime-safe;
    /// in production we point this at `CoreAudioIO.enqueuePlayback`.
    var onFrame: ((UnsafePointer<Float>, Int) -> Void)?

    /// Diagnostics: number of FEC-recovered frames since construction.
    private(set) var fecRecovered: Int = 0
    /// Diagnostics: number of PLC-synthesised frames since construction.
    private(set) var plcSynthesised: Int = 0
    /// Diagnostics: number of frames played from a directly-arrived packet.
    private(set) var framesPlayed: Int = 0
    /// Diagnostics: current adaptive target depth in milliseconds.
    private(set) var targetDepthMs: Double = 60.0

    private let decoder: Opus.Decoder
    private let lock = OSAllocatedUnfairLock()
    private var packets: [UInt32: Data] = [:]   // seq → opus bytes
    private var nextSeq: UInt32?                // sequence we want to play next
    private var lastArrivalHostTime: TimeInterval?
    private var jitterEMA: Double = 0           // exponentially-smoothed jitter (ms)
    private var jitterVAR: Double = 0           // variance estimator (ms²)
    private var firstFrameDeadline: TimeInterval?
    private var timer: DispatchSourceTimer?
    /// True when `timer` is currently suspended to save power. The timer is
    /// suspended whenever there's nothing to drain (no anchored playhead and
    /// no queued packets) and resumed by `push()`. With ~7 talkers this drops
    /// idle-time wake-ups from 700/sec to 0/sec.
    private var timerSuspended = false
    private let queue = DispatchQueue(label: "com.cleanmumble.JitterBuffer",
                                       qos: .userInteractive)
    private var pcmScratch = [Float](repeating: 0, count: 5760) // 120 ms max
    private var stopped = false
    /// Number of consecutive PLC frames emitted with no real packet arrival.
    /// Used to bail out of the "PLC forever" trap when a sender stops mid
    /// utterance without sending a clean terminator (very common over UDP).
    /// After ~`maxConsecutivePLC` PLC frames in a row we tear down the
    /// playback anchor; the next real packet starts a fresh utterance and
    /// re-anchors `nextSeq` instead of trying to "catch up" by emitting
    /// thousands of silence frames into the output ring.
    private var consecutivePLC: Int = 0
    private let maxConsecutivePLC: Int = 25 // ~250ms @ 10ms tick
    /// Mumble frame_number counts 10 ms units (480 samples @ 48 kHz). A sender
    /// using 20 ms frames increments sequence by 2 per packet, not 1. We detect
    /// the step from the first two distinct sequence numbers so that FEC lookups
    /// and nextSeq advancement stay aligned with the actual sender cadence.
    private var seqStep: UInt32 = 1
    private var seqStepDetected: Bool = false
    private var firstReceivedSeq: UInt32? = nil

    /// Snapshot the running loss-rate counters since the last call. Returns
    /// `(played, fec, plc)` and clears the windowed counters so the next call
    /// reflects only the next interval.
    func snapshotAndReset() -> (played: Int, fec: Int, plc: Int) {
        return lock.withLock {
            let s = (framesPlayed, fecRecovered, plcSynthesised)
            framesPlayed = 0
            fecRecovered = 0
            plcSynthesised = 0
            return s
        }
    }

    init(decoder: Opus.Decoder) {
        self.decoder = decoder
        startTimer()
    }

    deinit { stop() }

    /// Hand a freshly-arrived packet to the jitter buffer. Sequence numbers
    /// are Mumble frame counts (monotonically increasing per sender).
    func push(seq: UInt32, opus: Data) {
        let now = Self.monotonicNow()
        lock.withLock {
            // Track inter-arrival jitter (RFC 3550 §A.8 style smoothing).
            if let last = lastArrivalHostTime {
                let deltaMs = (now - last) * 1000
                let frameMs = Double(frameSize) / sampleRate * 1000
                let jitter = abs(deltaMs - frameMs)
                jitterEMA = 0.95 * jitterEMA + 0.05 * jitter
                let dev = jitter - jitterEMA
                jitterVAR = 0.95 * jitterVAR + 0.05 * (dev * dev)
                let stddev = sqrt(jitterVAR)
                // Target = max(2σ, baseline frame jitter), clamped to sane range.
                targetDepthMs = min(200.0, max(40.0, 2.0 * (jitterEMA + stddev)))
            }
            lastArrivalHostTime = now

            // Drop ancient packets (already past playback deadline).
            if let nxt = nextSeq, seq < nxt && nxt - seq > 8 &* seqStep {
                return
            }
            packets[seq] = opus

            // Anchor playback on the first packet of a new utterance.
            if nextSeq == nil {
                nextSeq = seq
                firstFrameDeadline = now + targetDepthMs / 1000.0
                firstReceivedSeq = seq
            }

            // Detect sender's sequence step from the first two distinct seq numbers.
            // Corrects nextSeq if the drain timer already advanced it by 1 before
            // the step was known.
            if !seqStepDetected, let f = firstReceivedSeq, seq != f {
                let delta = seq &- f
                if delta >= 1 && delta <= 8 {
                    seqStep = delta
                    seqStepDetected = true
                    if let nxt = nextSeq, nxt == f &+ 1 {
                        nextSeq = f &+ seqStep
                    }
                }
            }
            // Resume the drain timer if we'd suspended it during idle.
            if timerSuspended, let t = timer {
                t.resume()
                timerSuspended = false
            }
        }
    }

    /// Reset everything (call on terminator packet, sender silence, or speaker
    /// switch). Resets internal Opus decoder state too.
    func reset() {
        lock.withLock {
            packets.removeAll(keepingCapacity: true)
            nextSeq = nil
            lastArrivalHostTime = nil
            firstFrameDeadline = nil
            consecutivePLC = 0
            seqStep = 1; seqStepDetected = false; firstReceivedSeq = nil
            try? decoder.resetState()
        }
    }

    /// Stop the drain timer permanently. Call before discarding the instance.
    func stop() {
        lock.withLock {
            stopped = true
            // DispatchSourceTimer must be resumed before cancel() if it's
            // currently suspended, otherwise the cancel handler never fires
            // and resources leak.
            if timerSuspended {
                timer?.resume()
                timerSuspended = false
            }
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: - Drain

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 10 ms tick — half the frame interval, which keeps drain latency
        // bounded to ≤10 ms regardless of when packets actually land.
        t.schedule(deadline: .now() + .milliseconds(5),
                   repeating: .milliseconds(10),
                   leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        // Snapshot under lock, do work outside (decoder calls can be slow-ish).
        let work: DrainAction = lock.withLock {
            guard !stopped else { return DrainAction.none }
            // Idle suspend: nothing to play and nothing queued. Park the
            // timer until the next push() arrives. With many talkers in a
            // channel this saves hundreds of wake-ups per second when no
            // one is speaking.
            if nextSeq == nil && packets.isEmpty, let t = timer, !timerSuspended {
                t.suspend()
                timerSuspended = true
                return DrainAction.none
            }
            guard let want = nextSeq else { return DrainAction.none }
            let now = Self.monotonicNow()

            // Initial buffering: wait until depth elapses OR enough packets queued.
            if let deadline = firstFrameDeadline, now < deadline,
               packets[want] == nil {
                return DrainAction.none
            }
            firstFrameDeadline = nil

            let action: DrainAction
            if let p = packets.removeValue(forKey: want) {
                action = .play(p)
                nextSeq = want &+ seqStep
                consecutivePLC = 0
            } else if let next = packets[want &+ seqStep] {
                // Packet for `want` is missing, but the next expected seq is here — try FEC.
                action = .fec(next)
                nextSeq = want &+ seqStep
                consecutivePLC = 0
            } else {
                // Neither is present yet. If we've waited more than one
                // frame interval past the expected arrival of `want`, give
                // up and emit PLC to keep playback continuous. Otherwise
                // wait one more tick.
                let oneFrameMs = Double(frameSize) / sampleRate * 1000
                let stale = (lastArrivalHostTime.map { (now - $0) * 1000 } ?? .infinity) > oneFrameMs * 1.5
                if stale {
                    consecutivePLC &+= 1
                    if consecutivePLC > maxConsecutivePLC {
                        // Sender has gone silent without a terminator. Stop
                        // emitting PLC (which would otherwise pile silence
                        // into the output ring at 2× wall-clock rate, since
                        // each tick decodes a 20ms frame) and let the next
                        // real packet re-anchor playback timing.
                        nextSeq = nil
                        firstFrameDeadline = nil
                        consecutivePLC = 0
                        action = .none
                    } else {
                        nextSeq = want &+ seqStep
                        action = .plc
                    }
                } else {
                    action = .none
                }
            }

            // Garbage-collect packets older than the new playhead.
            if let nxt = nextSeq {
                packets = packets.filter { $0.key &+ 8 >= nxt || $0.key >= nxt }
            }
            return action
        }

        switch work {
        case .none: return
        case .play(let data): emitDecoded(data)
        case .fec(let nextData): emitFEC(from: nextData)
        case .plc: emitPLC()
        }
    }

    private enum DrainAction { case none, play(Data), fec(Data), plc }

    // MARK: - Decode helpers (off-lock, called serially from queue)

    private func emitDecoded(_ data: Data) {
        let n = decodeInto(scratch: &pcmScratch, data: data, fec: false)
        if n > 0 {
            if frameSize != n { frameSize = n }
            framesPlayed += 1
            pcmScratch.withUnsafeBufferPointer { onFrame?($0.baseAddress!, n) }
        }
    }

    private func emitFEC(from nextData: Data) {
        let n = decodeInto(scratch: &pcmScratch, data: nextData, fec: true)
        if n > 0 {
            fecRecovered += 1
            pcmScratch.withUnsafeBufferPointer { onFrame?($0.baseAddress!, n) }
        } else {
            emitPLC()
        }
    }

    private func emitPLC() {
        let fs = Int32(frameSize)
        let n: Int
        do {
            n = try pcmScratch.withUnsafeMutableBufferPointer { buf in
                try decoder.concealLostFrame(into: buf.baseAddress!, frameSize: fs)
            }
        } catch {
            return
        }
        if n > 0 {
            plcSynthesised += 1
            pcmScratch.withUnsafeBufferPointer { onFrame?($0.baseAddress!, n) }
        }
    }

    private func decodeInto(scratch: inout [Float], data: Data, fec: Bool) -> Int {
        let fs = Int32(frameSize == 0 ? 5760 : max(frameSize, 960))
        do {
            return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return try scratch.withUnsafeMutableBufferPointer { buf in
                    try decoder.decodeFloat(base, length: Int32(data.count),
                                            into: buf.baseAddress!,
                                            frameSize: fs, decodeFEC: fec)
                }
            }
        } catch {
            return 0
        }
    }

    private static func monotonicNow() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}
