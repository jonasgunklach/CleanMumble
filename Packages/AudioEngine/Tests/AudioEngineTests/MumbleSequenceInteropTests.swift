//
//  MumbleSequenceInteropTests.swift
//  AudioEngineTests
//
//  Guards the Mumble frame_number protocol semantics that the CleanMumble↔
//  CleanMumble fidelity tests can't see: frame_number counts 10 ms audio
//  SEGMENTS, not packets. A 20 ms Opus frame must advance it by 2. Getting
//  this wrong is inaudible against another CleanMumble (both sides agree) but
//  produces "robot voice" + phantom packet loss against every standard client
//  (Linux / iOS Mumble), because their jitter buffer timestamps are
//  frameSize × frame_number.
//
//   • Outbound: consecutive voice packets step by frameMs/10.
//   • Inbound: a lossless step-2 stream (what a standard 20 ms client sends)
//     must decode WITHOUT triggering FEC/PLC — the 50 %-phantom-FEC bug.
//

import XCTest
import AVFAudio
import Opus
import AudioCore
@testable import AudioEngine

final class MumbleSequenceInteropTests: XCTestCase {

    private let sampleRate = 48_000.0

    /// Capture an utterance and return its emitted packets in order.
    private func capture(_ source: [Float], format: CaptureFormat)
    -> [(seq: UInt64, data: Data, isTerm: Bool)] {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = 0.004
        let lock = NSLock()
        var packets: [(UInt64, Data, Bool)] = []
        engine.onPacket = { data, seq, term in
            lock.lock(); packets.append((seq, data, term)); lock.unlock()
        }
        engine.start(sourceRate: sampleRate, format: format)
        let chunk = Int(sampleRate / 100)
        var i = 0
        while i + chunk <= source.count {
            source[i..<(i + chunk)].withUnsafeBufferPointer {
                engine.ingest($0.baseAddress!, count: chunk)
            }
            Thread.sleep(forTimeInterval: 0.002)
            i += chunk
        }
        Thread.sleep(forTimeInterval: 0.3)
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return packets
    }

    // MARK: - Outbound: frame_number counts 10 ms segments

    func testOutbound20msFrameNumberStepsBy2() {
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 1.0,
                                               sampleRate: sampleRate)
        let voice = capture(source, format: CaptureFormat()).filter { !$0.isTerm }   // 20 ms default
        XCTAssertGreaterThan(voice.count, 20, "expected a full utterance of packets")
        for i in 1..<voice.count {
            XCTAssertEqual(voice[i].seq - voice[i - 1].seq, 2,
                "20 ms frame must advance frame_number by 2 (10 ms segments), got " +
                "\(voice[i].seq - voice[i - 1].seq) at packet \(i)")
        }
    }

    func testOutbound40msFrameNumberStepsBy4() {
        var fmt = CaptureFormat(); fmt.opusFrameMs = 40; fmt.vadPreRollMs = 0
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 1.2,
                                               sampleRate: sampleRate)
        let voice = capture(source, format: fmt).filter { !$0.isTerm }
        XCTAssertGreaterThan(voice.count, 10)
        for i in 1..<voice.count {
            XCTAssertEqual(voice[i].seq - voice[i - 1].seq, 4,
                "40 ms frame must advance frame_number by 4")
        }
    }

    // MARK: - Inbound: a lossless step-2 stream must not fabricate FEC/PLC

    func testInboundStep2StreamDecodesWithoutPhantomConcealment() {
        // Real Opus packets from a 20 ms encoder, re-stamped with a standard
        // client's frame_number grid (0, 2, 4, …) with NO gaps.
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 1.5,
                                               sampleRate: sampleRate)
        let voice = capture(source, format: CaptureFormat()).filter { !$0.isTerm }
        XCTAssertGreaterThan(voice.count, 40)

        let pb = PlaybackEngine()
        pb.start()
        defer { pb.stop() }
        for (i, p) in voice.enumerated() {
            pb.submit(sender: 1, seq: UInt32(i * 2), opus: p.data, isTerminator: false)
        }

        // Drain well past the utterance length.
        var block = [Float](repeating: 0, count: 480)
        for _ in 0..<320 {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                pb.pullMix(into: $0.baseAddress!, frames: 480)
            }
        }

        let stats = pb.snapshotStats()
        // Nothing was actually lost mid-stream, so in-band FEC must NOT fire.
        // The stride bug produced ~1 phantom FEC frame per real packet
        // (≈ voice.count); the fix brings it to ~0. (A bounded PLC tail is
        // expected here because this harness never sends a terminator, so the
        // buffer conceals to maxConsecutivePLC before ending — that's the
        // normal no-terminator ending, not the bug.)
        XCTAssertLessThanOrEqual(stats.fec, max(2, voice.count / 10),
            "lossless step-2 stream triggered \(stats.fec) phantom FEC frames " +
            "— the frame_number stride bug (should be ~0)")
        // Every real packet should decode directly (not be stretched 2× by
        // interleaved phantom frames).
        XCTAssertGreaterThan(stats.played, voice.count * 3 / 4,
            "most step-2 packets should decode directly (played=\(stats.played) of \(voice.count))")
    }

    // MARK: - Deferred terminator: don't clip the last syllable

    func testTerminatorInSameBatchDoesNotClipBufferedAudio() {
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 0.8,
                                               sampleRate: sampleRate)
        let voice = capture(source, format: CaptureFormat()).filter { !$0.isTerm }
        XCTAssertGreaterThan(voice.count, 20)

        let pb = PlaybackEngine()
        pb.start()
        defer { pb.stop() }
        // Whole utterance AND its terminator arrive in one TCP burst, before
        // the decode worker has had a chance to drain any of it. An immediate
        // reset() would drop every still-undecoded packet.
        for (i, p) in voice.enumerated() {
            pb.submit(sender: 1, seq: UInt32(i * 2), opus: p.data, isTerminator: false)
        }
        pb.submit(sender: 1, seq: UInt32(voice.count * 2), opus: Data(), isTerminator: true)

        var block = [Float](repeating: 0, count: 480)
        for _ in 0..<220 {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                pb.pullMix(into: $0.baseAddress!, frames: 480)
            }
        }
        let stats = pb.snapshotStats()
        XCTAssertGreaterThan(stats.played, voice.count * 3 / 4,
            "terminator in the same batch clipped buffered audio " +
            "(played=\(stats.played) of \(voice.count) — reset should defer until drained)")
    }
}
