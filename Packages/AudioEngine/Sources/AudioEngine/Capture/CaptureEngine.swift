//
//  CaptureEngine.swift
//  AudioEngine
//
//  Mic-side data plane: the backend's tap thread memcpys device-rate mono
//  samples into an SPSC ring; a dedicated worker thread does everything else
//  (SRC → HPF → gain → limiter → meter → 20 ms framing → VAD → Opus encode)
//  and hands finished packets to `onPacket`. Nothing here ever touches the
//  main thread, so UI or game load cannot stall the outgoing voice path.
//

import Foundation
import AudioToolbox
import AVFAudio
import Synchronization
import AudioCore
import Opus
import OpusControl

/// Rebuild-class encoder settings — fixed for the lifetime of a `start()`.
public struct CaptureFormat: Equatable, Sendable {
    public var opusBitrate: Int = 40_000
    public var opusFrameMs: Int = 20          // 10 / 20 / 40 / 60
    public var opusLowDelay: Bool = false
    /// VAD pre-roll: how much audio from just BEFORE the VAD fired is
    /// transmitted with the utterance, so quiet word onsets aren't chopped.
    /// 0 disables.
    public var vadPreRollMs: Int = 40
    public init() {}
    public init(opusBitrate: Int, opusFrameMs: Int, opusLowDelay: Bool) {
        self.opusBitrate = opusBitrate
        self.opusFrameMs = opusFrameMs
        self.opusLowDelay = opusLowDelay
    }
}

public final class CaptureEngine: @unchecked Sendable {

    // ---- Outputs (both invoked on the capture worker thread) ---------------

    /// One encoded Opus packet, its per-utterance sequence number, and the
    /// terminator flag. `data.isEmpty && isTerminator` marks end-of-utterance.
    public var onPacket: ((_ opus: Data, _ seq: UInt64, _ isTerminator: Bool) -> Void)?
    /// Local VAD state changed (drives the speaking indicator).
    public var onSpeakingChanged: ((Bool) -> Void)?

    // ---- Live-adjustable knobs (any thread) ---------------------------------

    public let inputGain = RampedGain(1.0)
    public let meter = LevelMeter()

    private let vadThresholdBits = Atomic<UInt32>(Float(0.008).bitPattern)
    public var vadThreshold: Float {
        get { Float(bitPattern: vadThresholdBits.load(ordering: .relaxed)) }
        set { vadThresholdBits.store(newValue.bitPattern, ordering: .relaxed) }
    }

    private let mutedFlag = Atomic<Bool>(false)
    public var isMuted: Bool {
        get { mutedFlag.load(ordering: .relaxed) }
        set { mutedFlag.store(newValue, ordering: .relaxed) }
    }

    /// When false, frames are gated by VAD only for the speaking indicator but
    /// never sent (e.g. not connected yet).
    private let transmitFlag = Atomic<Bool>(false)
    public var transmitEnabled: Bool {
        get { transmitFlag.load(ordering: .relaxed) }
        set { transmitFlag.store(newValue, ordering: .relaxed) }
    }

    /// Applied between frames on the worker (network-adaptation path).
    private let targetBitrate = Atomic<Int>(40_000)
    private let targetLossPercent = Atomic<Int>(10)
    public func setNetworkAdaptation(bitrate: Int, lossPercent: Int) {
        targetBitrate.store(max(8_000, min(510_000, bitrate)), ordering: .relaxed)
        targetLossPercent.store(max(0, min(40, lossPercent)), ordering: .relaxed)
    }

    /// Exposed for the UI stats panel.
    public var currentBitrate: Int { targetBitrate.load(ordering: .relaxed) }

    // ---- Ingest side (called by the backend's tap/render thread) ------------

    /// Device-rate mono samples in, nothing else done on the caller's thread.
    /// The declared source sample rate is sticky per `start()`; a format
    /// change is a rebuild (the controller restarts us with the new rate).
    public func ingest(_ samples: UnsafePointer<Float>, count: Int) {
        guard running.load(ordering: .relaxed) else { return }
        ring.write(samples, count: count)
        ingestTicks.wrappingAdd(1, ordering: .relaxed)
        wakeup.signal()
    }

    /// Heartbeat for the controller's stall watchdog.
    public var ingestHeartbeat: Int { ingestTicks.load(ordering: .relaxed) }

    // ---- Internals -----------------------------------------------------------

    private let ring = SPSCRingBuffer(capacityFrames: 48 * 1024, overflowPolicy: .dropNewest)
    private let wakeup = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private let ingestTicks = Atomic<Int>(0)
    private var worker: Thread?

    // Worker-owned state (created in start(), used only on the worker).
    private var sourceRate: Double = 48_000
    private var format = CaptureFormat()

    public init() {}

    // MARK: - Lifecycle (control plane)

    /// `sourceRate` is the rate the backend will `ingest` at. The worker
    /// resamples to 48 kHz in software — device/AU-side SRC is exactly what
    /// Bluetooth HFP devices choke on (silent "started" AUs).
    public func start(sourceRate: Double, format: CaptureFormat) {
        stop()
        self.sourceRate = sourceRate
        self.format = format
        targetBitrate.store(format.opusBitrate, ordering: .relaxed)
        ring.clear()
        running.store(true, ordering: .releasing)
        let t = Thread { [weak self] in self?.workerLoop() }
        t.name = "audio.capture.worker"
        t.qualityOfService = .userInteractive
        t.start()
        worker = t
    }

    public func stop() {
        guard running.load(ordering: .relaxed) else { return }
        running.store(false, ordering: .releasing)
        wakeup.signal()
        // The worker exits its loop promptly; no join primitive on Thread, and
        // none needed — worker-owned state is rebuilt on next start().
        worker = nil
    }

    // MARK: - Worker

    private func workerLoop() {
        // ---- Preallocate everything the loop touches --------------------
        let frameSamples = max(1, format.opusFrameMs) * 48        // @48 kHz
        let holdFrames = max(1, 300 / max(1, format.opusFrameMs)) // ~300 ms VAD hangover

        let hpf = BiquadFilter(format: .mumble,
                               coeffs: BiquadFilter.highPass(cutoffHz: 80,
                                                             sampleRate: 48_000,
                                                             Q: 0.707))
        let limiter = SoftLimiter(format: .mumble, ceilingDB: -1.0)

        let application: Opus.Application = format.opusLowDelay ? .restrictedLowDelay : .voip
        guard let pcmFormat = AVAudioFormat(opusPCMFormat: .float32, sampleRate: 48_000, channels: 1),
              let encoder = try? Opus.Encoder(format: pcmFormat, application: application)
        else {
            running.store(false, ordering: .releasing)
            return
        }
        try? encoder.setSignal(.voice)
        try? encoder.setBitrate(Int32(format.opusBitrate))
        // Complexity 10: mono 48 kHz encode is ~1 % of a core either way on
        // Apple silicon; matches stock Mumble / libopus reference clients.
        try? encoder.setComplexity(10)
        try? encoder.setVBR(true)
        try? encoder.setInbandFEC(true)
        try? encoder.setPacketLossPercentage(Int32(targetLossPercent.load(ordering: .relaxed)))
        try? encoder.setLSBDepth(16)
        try? encoder.setDTX(false)      // our VAD is the single transmit gate
        // Band-limited source (Bluetooth HFP mic at 8/16 kHz): cap the coded
        // bandwidth to what the mic actually delivers so no bits are ever
        // spent on empty spectrum above it.
        if sourceRate <= 8_000 {
            try? encoder.setMaxBandwidth(.narrowband)
        } else if sourceRate <= 16_000 {
            try? encoder.setMaxBandwidth(.wideband)
        } else if sourceRate <= 24_000 {
            try? encoder.setMaxBandwidth(.superwideband)
        }

        var appliedBitrate = format.opusBitrate
        var appliedLoss = targetLossPercent.load(ordering: .relaxed)

        // Software SRC (device rate → 48 kHz) when needed.
        var converter: AudioConverterRef?
        if Int(sourceRate) != 48_000 {
            var src = AudioStreamBasicDescription(
                mSampleRate: sourceRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            var dst = src; dst.mSampleRate = 48_000
            var conv: AudioConverterRef?
            if AudioConverterNew(&src, &dst, &conv) == noErr { converter = conv }
        }
        defer { if let c = converter { AudioConverterDispose(c) } }

        let drainChunk = 2048
        let rawBuf = UnsafeMutablePointer<Float>.allocate(capacity: drainChunk)
        defer { rawBuf.deallocate() }
        let srcCap = drainChunk * 4 + 256   // worst case 16 kHz → 48 kHz
        let srcBuf = UnsafeMutablePointer<Float>.allocate(capacity: srcCap)
        defer { srcBuf.deallocate() }

        // Frame accumulator (48 kHz mono).
        let accum = UnsafeMutablePointer<Float>.allocate(capacity: frameSamples * 4)
        defer { accum.deallocate() }
        var accumCount = 0

        guard let frameBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                                 frameCapacity: AVAudioFrameCount(frameSamples))
        else { running.store(false, ordering: .releasing); return }
        var packetBytes = [UInt8](repeating: 0, count: 1_500)

        var sequence: UInt64 = 0
        var speaking = false
        var holdCount = 0

        // VAD pre-roll: ring of the last N complete frames captured while
        // idle, flushed (encoded + sent) the moment the VAD fires — so the
        // quiet start of an utterance is transmitted instead of chopped.
        let preRollFrames = max(0, format.vadPreRollMs / max(1, format.opusFrameMs))
        var preRoll: [[Float]] = []
        preRoll.reserveCapacity(preRollFrames)

        // Feeder state for AudioConverterFillComplexBuffer: hands the
        // converter the current raw chunk exactly once per call.
        final class FeedBox {
            var ptr: UnsafeMutablePointer<Float>?
            var remaining: Int = 0
        }
        let feed = FeedBox()
        let feedProc: AudioConverterComplexInputDataProc = { _, ioNumPackets, ioData, _, inUserData in
            let box = Unmanaged<FeedBox>.fromOpaque(inUserData!).takeUnretainedValue()
            guard let p = box.ptr, box.remaining > 0 else {
                ioNumPackets.pointee = 0
                return noErr        // "dry" — converter returns what it has
            }
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = 1
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(p)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(box.remaining * 4)
            ioNumPackets.pointee = UInt32(box.remaining)
            box.remaining = 0
            return noErr
        }
        let feedCtx = Unmanaged.passUnretained(feed).toOpaque()

        // ---- Loop --------------------------------------------------------
        while running.load(ordering: .acquiring) {
            _ = wakeup.wait(timeout: .now() + .milliseconds(20))
            if !running.load(ordering: .acquiring) { break }

            // Apply pending encoder-knob changes between frames.
            let wantBitrate = targetBitrate.load(ordering: .relaxed)
            if wantBitrate != appliedBitrate {
                try? encoder.setBitrate(Int32(wantBitrate)); appliedBitrate = wantBitrate
            }
            let wantLoss = targetLossPercent.load(ordering: .relaxed)
            if wantLoss != appliedLoss {
                try? encoder.setPacketLossPercentage(Int32(wantLoss)); appliedLoss = wantLoss
            }

            while ring.availableToRead > 0 {
                let got = ring.read(into: rawBuf, count: min(drainChunk, ring.availableToRead))
                if got == 0 { break }

                // 1) SRC to 48 kHz.
                var samples: UnsafeMutablePointer<Float>
                var count: Int
                if let conv = converter {
                    feed.ptr = rawBuf; feed.remaining = got
                    var outFrames = UInt32(srcCap)
                    var outList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 1,
                                              mDataByteSize: UInt32(srcCap * 4),
                                              mData: UnsafeMutableRawPointer(srcBuf)))
                    let err = AudioConverterFillComplexBuffer(conv, feedProc, feedCtx,
                                                              &outFrames, &outList, nil)
                    if err != noErr && outFrames == 0 { continue }
                    samples = srcBuf; count = Int(outFrames)
                } else {
                    samples = rawBuf; count = got
                }
                if count == 0 { continue }

                // 2) DSP chain in place: HPF → gain → limiter → meter.
                hpf.applyInPlace(samples, count: count)
                inputGain.applyInPlace(samples, count: count)
                limiter.applyInPlace(samples, count: count)
                meter.observe(samples, count: count)

                // 3) Frame accumulation.
                var consumed = 0
                while consumed < count {
                    let space = frameSamples - accumCount
                    let take = min(space, count - consumed)
                    accum.advanced(by: accumCount)
                        .update(from: samples.advanced(by: consumed), count: take)
                    accumCount += take
                    consumed += take
                    guard accumCount == frameSamples else { continue }
                    accumCount = 0

                    // 4) VAD + encode + emit, one frame at a time.
                    // Mute is a hard gate: it ends the utterance instantly
                    // (no VAD hangover — the accumulator holds real mic
                    // audio and MUST NOT be transmitted while muted).
                    let muted = mutedFlag.load(ordering: .relaxed)
                    var rms: Float = 0
                    if !muted {
                        var sum: Float = 0
                        for i in 0..<frameSamples { sum += accum[i] * accum[i] }
                        rms = (sum / Float(frameSamples)).squareRoot()
                    }

                    let threshold = Float(bitPattern: vadThresholdBits.load(ordering: .relaxed))
                    if muted {
                        holdCount = 0
                        // Pre-roll holds real mic audio — never keep any
                        // captured while muted.
                        preRoll.removeAll(keepingCapacity: true)
                    } else if rms > threshold {
                        holdCount = holdFrames
                    } else if holdCount > 0 {
                        holdCount -= 1
                    }
                    let nowSpeaking = holdCount > 0

                    if nowSpeaking != speaking {
                        speaking = nowSpeaking
                        onSpeakingChanged?(nowSpeaking)
                        if nowSpeaking {
                            sequence = 0
                            // Flush the onset that happened before the VAD
                            // fired (oldest first, contiguous sequence).
                            if transmitFlag.load(ordering: .relaxed) {
                                for frame in preRoll {
                                    frameBuffer.frameLength = AVAudioFrameCount(frameSamples)
                                    frame.withUnsafeBufferPointer {
                                        frameBuffer.floatChannelData![0]
                                            .update(from: $0.baseAddress!, count: frameSamples)
                                    }
                                    if let len = try? encoder.encode(frameBuffer, to: &packetBytes),
                                       len > 0 {
                                        onPacket?(Data(packetBytes[0..<len]), sequence, false)
                                        sequence &+= 1
                                    }
                                }
                            }
                            preRoll.removeAll(keepingCapacity: true)
                        } else if transmitFlag.load(ordering: .relaxed) {
                            onPacket?(Data(), sequence, true)   // terminator
                            sequence &+= 1
                        }
                    }
                    guard speaking, transmitFlag.load(ordering: .relaxed) else {
                        // Idle: remember this frame as potential onset.
                        if !speaking, !muted, preRollFrames > 0 {
                            if preRoll.count >= preRollFrames { preRoll.removeFirst() }
                            preRoll.append(Array(UnsafeBufferPointer(start: accum,
                                                                     count: frameSamples)))
                        }
                        continue
                    }

                    frameBuffer.frameLength = AVAudioFrameCount(frameSamples)
                    frameBuffer.floatChannelData![0].update(from: accum, count: frameSamples)
                    if let len = try? encoder.encode(frameBuffer, to: &packetBytes), len > 0 {
                        onPacket?(Data(packetBytes[0..<len]), sequence, false)
                        sequence &+= 1
                    }
                }
            }
        }

        // Loop exited: if we were mid-utterance, close it out cleanly.
        if speaking {
            onSpeakingChanged?(false)
            if transmitFlag.load(ordering: .relaxed) {
                onPacket?(Data(), sequence, true)
            }
        }
    }
}
