//
//  LowQualityVoiceTests.swift
//  AudioEngineTests
//
//  Degraded-condition coverage: what voice sounds like when the network or
//  the headset is bad — the situations users actually complain about.
//
//   • Low bitrate (16 kbps, the adaptation loop's bad-network region):
//     the full stack must still deliver the right pitch, level, and no
//     artefacts.
//   • Packet loss through the REAL jitter buffer: in-band FEC and PLC must
//     actually engage (stats prove it) and conceal the gaps — no silence
//     holes, no clicks.
//   • VAD pre-roll: the quiet start of an utterance (before the VAD fires)
//     must be transmitted, not chopped.
//

import XCTest
import AVFAudio
import Opus
import AudioCore
@testable import AudioEngine

final class LowQualityVoiceTests: XCTestCase {

    private let sampleRate = 48_000.0

    // MARK: - Helpers (mirror AudioQualityE2ETests)

    private func capturePackets(source: [Float], format: CaptureFormat,
                                vadThreshold: Float = 0.005)
    -> [(seq: UInt64, data: Data, isTerm: Bool)] {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = vadThreshold
        let lock = NSLock()
        var packets: [(UInt64, Data, Bool)] = []
        engine.onPacket = { data, seq, isTerm in
            lock.lock(); packets.append((seq, data, isTerm)); lock.unlock()
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

    private func renderMix(_ engine: PlaybackEngine, seconds: Double) -> [Float] {
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 480)
        for _ in 0..<Int(seconds * 100) {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            out.append(contentsOf: block)
        }
        return out
    }

    private func steadyState(_ samples: [Float]) -> [Float] {
        var a = Array(samples.drop { abs($0) < 0.001 }.reversed()
            .drop { abs($0) < 0.001 }.reversed())
        if a.count > 9_600 {
            let cut = a.count / 10
            a = Array(a[cut..<(a.count - cut)])
        }
        return a
    }

    // MARK: - 1. Low bitrate

    /// 16 kbps — where the network-adaptation loop lands on a bad link.
    /// Pitch, level and cleanliness must survive.
    func testLowBitrate16kVoiceStaysClean() {
        var format = CaptureFormat()
        format.opusBitrate = 16_000
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 1.5,
                                               sampleRate: sampleRate)
        let packets = capturePackets(source: source, format: format)
        XCTAssertGreaterThan(packets.count, 40)

        let playback = PlaybackEngine()
        playback.start()
        defer { playback.stop() }
        for p in packets {
            playback.submit(sender: 1, seq: UInt32(truncatingIfNeeded: p.seq),
                            opus: p.data, isTerminator: p.isTerm)
        }
        let body = steadyState(renderMix(playback, seconds: 2.2))
        XCTAssertGreaterThan(body.count, 24_000)

        let domSrc = AudioAnalysis.dominantFrequency(source, sampleRate: sampleRate)
        let domRcv = AudioAnalysis.dominantFrequency(body, sampleRate: sampleRate)
        XCTAssertEqual(domRcv.frequency, domSrc.frequency, accuracy: 30,
                       "pitch drifted at 16 kbps")
        let rmsDelta = 20 * log10f(max(AudioAnalysis.rms(body), 1e-6)
                                   / max(AudioAnalysis.rms(source), 1e-6))
        XCTAssertLessThan(abs(rmsDelta), 5, "level shifted \(rmsDelta) dB at 16 kbps")
        XCTAssertEqual(AudioAnalysis.discontinuities(body, threshold: 0.4).count, 0,
                       "clicks at 16 kbps")
        XCTAssertEqual(AudioAnalysis.zeroRuns(body, minRunLength: 480).count, 0,
                       "dropouts at 16 kbps")
    }

    // MARK: - 2. Packet loss through the real jitter buffer

    /// Drop every 10th packet. The jitter buffer must recover via in-band
    /// FEC / PLC (counters prove it engaged) and the output must have no
    /// silence holes — concealment, not gaps.
    func testPacketLossIsConcealedByFECAndPLC() {
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 2.0,
                                               sampleRate: sampleRate)
        let packets = capturePackets(source: source, format: CaptureFormat())
        XCTAssertGreaterThan(packets.count, 60)

        let playback = PlaybackEngine()
        playback.start()
        defer { playback.stop() }
        var dropped = 0
        for (i, p) in packets.enumerated() {
            if !p.isTerm && i % 10 == 5 { dropped += 1; continue }   // lose it
            playback.submit(sender: 1, seq: UInt32(truncatingIfNeeded: p.seq),
                            opus: p.data, isTerminator: p.isTerm)
        }
        XCTAssertGreaterThan(dropped, 3)

        let mix = renderMix(playback, seconds: 2.8)
        let stats = playback.snapshotStats()
        XCTAssertGreaterThan(stats.fec + stats.plc, 0,
                             "loss concealment never engaged (fec=\(stats.fec) plc=\(stats.plc))")

        let body = steadyState(mix)
        XCTAssertGreaterThan(body.count, 48_000)
        // Concealment must leave no audible holes: nothing ≥ 20 ms of silence.
        XCTAssertEqual(AudioAnalysis.zeroRuns(body, minRunLength: 960).count, 0,
                       "silence holes despite FEC/PLC")
        let domSrc = AudioAnalysis.dominantFrequency(source, sampleRate: sampleRate)
        let domRcv = AudioAnalysis.dominantFrequency(body, sampleRate: sampleRate)
        XCTAssertEqual(domRcv.frequency, domSrc.frequency, accuracy: 30,
                       "pitch destroyed by 10% loss")
    }

    // MARK: - 3. VAD pre-roll

    /// A fade-in utterance: the VAD fires only once the level crosses the
    /// threshold, so without pre-roll the quiet onset is lost. With pre-roll
    /// the transmitted stream must start earlier (more packets) and its
    /// first packet must be from the quieter, earlier part of the ramp.
    func testVADPreRollPreservesQuietOnset() throws {
        // 0.7 s quiet noise (kept below the VAD threshold), then a jump to
        // full level: the VAD fires on the first loud frame, so the quiet
        // section right before it exists only if pre-roll transmits it.
        var source = SignalGenerator.pinkNoise(amplitude: 0.3,
                                               durationSeconds: 1.4,
                                               sampleRate: sampleRate)
        let quietLen = Int(0.7 * sampleRate)
        for i in 0..<quietLen { source[i] *= 0.25 }

        // Threshold between the quiet level (0.25×) and the loud level (1×),
        // with margin for pink-noise frame-RMS fluctuation on both sides.
        let steadyRMS = AudioAnalysis.rms(Array(source[quietLen...]))
        let threshold = steadyRMS * 0.6
        XCTAssertGreaterThan(threshold, 0.001, "signal too quiet for the test")

        var noPreRoll = CaptureFormat();  noPreRoll.vadPreRollMs = 0
        var withPreRoll = CaptureFormat(); withPreRoll.vadPreRollMs = 40

        let base = capturePackets(source: source, format: noPreRoll,
                                  vadThreshold: threshold)
            .filter { !$0.isTerm }
        let pre = capturePackets(source: source, format: withPreRoll,
                                 vadThreshold: threshold)
            .filter { !$0.isTerm }
        guard base.count > 10, !pre.isEmpty else {
            return XCTFail("VAD never fired (base=\(base.count) pre=\(pre.count)) — bad test setup")
        }

        // Pre-roll must add the onset frames (2 × 20 ms, ±1 frame of timing
        // jitter between the two runs).
        XCTAssertGreaterThanOrEqual(pre.count, base.count + 1,
            "pre-roll added no packets (base=\(base.count) pre=\(pre.count))")

        // The first transmitted packet must now be from the quieter part of
        // the fade-in — decode both first packets and compare energy.
        let fmt = AVAudioFormat(opusPCMFormat: .float32,
                                sampleRate: sampleRate, channels: 1)!
        func firstPacketRMS(_ packets: [(seq: UInt64, data: Data, isTerm: Bool)]) throws -> Float {
            let dec = try Opus.Decoder(format: fmt)
            let pcm = try dec.decode(packets[0].data)
            guard let ch = pcm.floatChannelData?[0] else { return 0 }
            return AudioAnalysis.rms(Array(UnsafeBufferPointer(start: ch,
                                                               count: Int(pcm.frameLength))))
        }
        let baseOnset = try firstPacketRMS(base)
        let preOnset = try firstPacketRMS(pre)
        // Pre-roll's first packet is from the 0.25× quiet section; the
        // VAD-triggered first packet is from the 1× loud section.
        XCTAssertLessThan(preOnset, baseOnset * 0.6,
            "pre-roll first packet (rms \(preOnset)) should carry the quiet " +
            "onset, not the loud VAD-triggered frame (rms \(baseOnset))")
    }
}
