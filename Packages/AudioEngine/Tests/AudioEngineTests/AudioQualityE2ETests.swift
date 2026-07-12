//
//  AudioQualityE2ETests.swift
//  AudioEngineTests
//
//  Fidelity regression tests: a known tone through the FULL stack
//  (CaptureEngine: SRC → HPF → gain → limiter → VAD → Opus encode, then
//  PlaybackEngine: jitter buffer → Opus decode → mix → soft clip) must come
//  out as the same tone — right pitch, right level, no clicks, no dropouts.
//
//  These are the tests that catch "audio quality quietly got worse":
//   • a pitch shift (the historical stale-sample-rate bug sounded robotic)
//   • level drops (gain staging errors)
//   • clicks at packet/buffer boundaries (discontinuity scan)
//   • mid-utterance dropouts (zero-run scan)
//   • harshness from the mixer's clipper (THD+N bound)
//

import XCTest
@testable import AudioEngine
import AudioCore

final class AudioQualityE2ETests: XCTestCase {

    /// Run `seconds` of a sine at `freq`/`amplitude` through CaptureEngine at
    /// `sourceRate`, collect the emitted Opus packets.
    private func capturePackets(freq: Float, amplitude: Float,
                                sourceRate: Double, seconds: Double) -> [(seq: UInt64, data: Data)] {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = 0.005

        let lock = NSLock()
        var packets: [(UInt64, Data)] = []
        engine.onPacket = { data, seq, isTerminator in
            guard !isTerminator else { return }
            lock.lock(); packets.append((seq, data)); lock.unlock()
        }
        engine.start(sourceRate: sourceRate, format: CaptureFormat())

        let chunk = Int(sourceRate / 100)          // 10 ms
        var buf = [Float](repeating: 0, count: chunk)
        var phase: Float = 0
        let step = 2 * Float.pi * freq / Float(sourceRate)
        for _ in 0..<Int(seconds * 100) {
            for i in 0..<chunk {
                buf[i] = sinf(phase) * amplitude
                phase += step
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            buf.withUnsafeBufferPointer { engine.ingest($0.baseAddress!, count: chunk) }
            Thread.sleep(forTimeInterval: 0.002)
        }
        Thread.sleep(forTimeInterval: 0.3)         // let the worker drain
        engine.stop()
        lock.lock(); defer { lock.unlock() }
        return packets
    }

    /// Play packets through PlaybackEngine and pull the rendered mix.
    private func renderMix(_ packets: [(seq: UInt64, data: Data)],
                           pullSeconds: Double) -> [Float] {
        let engine = PlaybackEngine()
        engine.start()
        defer { engine.stop() }
        for p in packets {
            engine.submit(sender: 1, seq: UInt32(truncatingIfNeeded: p.seq),
                          opus: p.data, isTerminator: false)
        }
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 480)
        for _ in 0..<Int(pullSeconds * 100) {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            out.append(contentsOf: block)
        }
        return out
    }

    /// The steady-state middle of the rendered signal (skips VAD onset,
    /// jitter-buffer warm-up, and the tail).
    private func steadyState(_ samples: [Float]) -> [Float] {
        // Trim leading/trailing silence.
        let active = samples.drop { abs($0) < 0.001 }.reversed()
            .drop { abs($0) < 0.001 }.reversed()
        let a = Array(active)
        guard a.count > 9_600 else { return a }
        // Drop 10% on both ends.
        let cut = a.count / 10
        return Array(a[cut..<(a.count - cut)])
    }

    // MARK: - Tests

    /// 440 Hz in → 440 Hz out, same level, no clicks, no dropouts.
    func testFullStackTonePreservation48k() {
        let inputAmplitude: Float = 0.3
        let packets = capturePackets(freq: 440, amplitude: inputAmplitude,
                                     sourceRate: 48_000, seconds: 1.0)
        XCTAssertGreaterThan(packets.count, 30, "expected ~50 packets for 1 s of speech")

        let mix = renderMix(packets, pullSeconds: 1.6)
        let body = steadyState(mix)
        XCTAssertGreaterThan(body.count, 24_000, "need ≥0.5 s of steady-state audio")

        // Pitch: exact tone survives the whole pipeline.
        let dom = AudioAnalysis.dominantFrequency(body, sampleRate: 48_000)
        XCTAssertEqual(dom.frequency, 440, accuracy: 8,
                       "pitch shift detected — SRC/format regression")

        // Level: unity gain staging end to end (Opus + HPF cost a little).
        let outRMS = AudioAnalysis.rms(body)
        let inRMS = inputAmplitude / Float(2.0.squareRoot())
        XCTAssertGreaterThan(outRMS, inRMS * 0.6, "output level dropped")
        XCTAssertLessThan(outRMS, inRMS * 1.4, "output level boosted unexpectedly")

        // Cleanliness: Opus on a pure tone should stay very clean.
        let thd = AudioAnalysis.thdNoise(body, sampleRate: 48_000, expectedHz: 440)
        XCTAssertLessThan(thd, 0.35, "THD+N too high — distortion in the pipeline")

        // No clicks at packet/buffer boundaries…
        XCTAssertEqual(AudioAnalysis.discontinuities(body, threshold: 0.4).count, 0,
                       "click/pop artefacts detected")
        // …and no mid-utterance dropouts.
        XCTAssertEqual(AudioAnalysis.zeroRuns(body, minRunLength: 240).count, 0,
                       "silent gaps detected mid-utterance")
    }

    /// A 44.1 kHz source must resample without shifting pitch. (A stale
    /// device-rate bug shifts 440 Hz to ≈ 479 Hz — the historical
    /// "robotic audio" failure. The 8 Hz tolerance can't miss it.)
    func testResampling44100PreservesPitch() {
        let packets = capturePackets(freq: 440, amplitude: 0.3,
                                     sourceRate: 44_100, seconds: 1.0)
        XCTAssertGreaterThan(packets.count, 30)

        let mix = renderMix(packets, pullSeconds: 1.6)
        let body = steadyState(mix)
        XCTAssertGreaterThan(body.count, 24_000)

        let dom = AudioAnalysis.dominantFrequency(body, sampleRate: 48_000)
        XCTAssertEqual(dom.frequency, 440, accuracy: 8,
                       "pitch shifted after 44.1 kHz SRC")
        XCTAssertEqual(AudioAnalysis.discontinuities(body, threshold: 0.4).count, 0,
                       "SRC introduced clicks")
    }

    /// Bluetooth HFP rate: 16 kHz source (narrowband capture) must still come
    /// through at the right pitch after 3× upsampling.
    func testResampling16kPreservesPitch() {
        let packets = capturePackets(freq: 440, amplitude: 0.3,
                                     sourceRate: 16_000, seconds: 1.0)
        XCTAssertGreaterThan(packets.count, 30)
        let mix = renderMix(packets, pullSeconds: 1.6)
        let body = steadyState(mix)
        XCTAssertGreaterThan(body.count, 24_000)
        let dom = AudioAnalysis.dominantFrequency(body, sampleRate: 48_000)
        XCTAssertEqual(dom.frequency, 440, accuracy: 8,
                       "pitch shifted after 16 kHz SRC")
    }

    /// Three loud talkers summing past unity must soft-clip smoothly:
    /// bounded peaks, no hard-clip squarewave harshness, no discontinuities.
    func testMultiSenderMixSoftClipsBounded() throws {
        let engine = PlaybackEngine()
        engine.start()
        defer { engine.stop() }

        for (sender, freq) in [(Int32(1), Float(330)), (2, 440), (3, 550)] {
            let packets = capturePackets(freq: freq, amplitude: 0.8,
                                         sourceRate: 48_000, seconds: 0.6)
            XCTAssertGreaterThan(packets.count, 15)
            for p in packets {
                engine.submit(sender: sender, seq: UInt32(truncatingIfNeeded: p.seq),
                              opus: p.data, isTerminator: false)
            }
        }
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 480)
        for _ in 0..<100 {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                engine.pullMix(into: $0.baseAddress!, frames: 480)
            }
            out.append(contentsOf: block)
        }
        let body = steadyState(out)
        XCTAssertGreaterThan(AudioAnalysis.rms(body), 0.1, "mix should be loud")
        XCTAssertLessThanOrEqual(AudioAnalysis.peak(body), 0.985,
                                 "soft clipper must bound the summed mix")
        XCTAssertEqual(AudioAnalysis.discontinuities(body, threshold: 0.5).count, 0,
                       "clipping produced discontinuities")
    }
}
