//
//  AirPodsPipelineFidelityTests.swift
//  AudioEngineTests
//
//  "What goes in vs. what comes out" — the whole voice path exercised at the
//  device rates AirPods actually negotiate, measuring the OUTPUT SPECTRUM, not
//  just pitch. The complaint "it sounds bad / muffled" is a frequency-response
//  claim, so these tests measure the effective transmitted bandwidth end to
//  end and fail if the highs are being thrown away.
//
//  Why this is enough for BOTH directions: the codec path is symmetric — the
//  bytes I encode for others and the bytes I decode from others run through
//  the same Opus at the same 48 kHz. A capture(sourceRate)→Opus→decode→render
//  round trip is therefore representative of what my listeners hear AND what I
//  hear, minus the physical mic/speaker.
//
//  AirPods over VPIO on macOS negotiate a 24 kHz duplex link (per audio-engine
//  .md; 48 kHz only on the newest OS), and fall back to 16 kHz HFP on older
//  stacks. Those are the `sourceRate`s under test. CaptureEngine resamples each
//  to 48 kHz and caps Opus's coded bandwidth from `sourceRate`
//  (CaptureEngine.swift setMaxBandwidth): 16 k→wideband(8 kHz), 24 k→
//  superwideband(12 kHz), 48 k→fullband. These tests assert the output
//  actually delivers that bandwidth — the money case is 24 kHz staying ABOVE
//  wideband (a bug there is exactly "AirPods sound muffled").
//

import XCTest
import AVFAudio
import Opus
import AudioCore
@testable import AudioEngine

final class AirPodsPipelineFidelityTests: XCTestCase {

    // MARK: - End-to-end helper (capture → Opus → decode → render)

    /// Feed `input` (sampled at `sourceRate`) through CaptureEngine exactly as
    /// a backend tap would, then play the emitted packets through
    /// PlaybackEngine and return the rendered 48 kHz mono mix.
    private func roundTrip(input: [Float], sourceRate: Double,
                           format: CaptureFormat,
                           vadThreshold: Float = 0.004) -> [Float] {
        let cap = CaptureEngine()
        cap.transmitEnabled = true
        cap.vadThreshold = vadThreshold
        let lock = NSLock()
        var packets: [(seq: UInt32, data: Data, term: Bool)] = []
        cap.onPacket = { data, seq, term in
            lock.lock()
            packets.append((UInt32(truncatingIfNeeded: seq), data, term))
            lock.unlock()
        }
        cap.start(sourceRate: sourceRate, format: format)

        let chunk = max(1, Int(sourceRate / 100))          // 10 ms at the device rate
        var i = 0
        while i + chunk <= input.count {
            input[i..<(i + chunk)].withUnsafeBufferPointer {
                cap.ingest($0.baseAddress!, count: chunk)
            }
            Thread.sleep(forTimeInterval: 0.002)
            i += chunk
        }
        Thread.sleep(forTimeInterval: 0.3)                 // let the worker drain
        cap.stop()

        let pb = PlaybackEngine()
        pb.start()
        defer { pb.stop() }
        lock.lock(); let pkts = packets; lock.unlock()
        // Submit voice packets only. The trailing terminator would call
        // jitter.reset() and wipe the freshly-queued audio before the decode
        // worker runs (there's no inter-packet network delay in this harness).
        for p in pkts where !p.term {
            pb.submit(sender: 1, seq: p.seq, opus: p.data, isTerminator: false)
        }

        var out: [Float] = []
        var block = [Float](repeating: 0, count: 480)
        let renderSeconds = Double(input.count) / sourceRate + 1.0
        for _ in 0..<Int(renderSeconds * 100) {
            Thread.sleep(forTimeInterval: 0.01)
            block.withUnsafeMutableBufferPointer {
                pb.pullMix(into: $0.baseAddress!, frames: 480)
            }
            out.append(contentsOf: block)
        }
        return out
    }

    /// Trim leading/trailing near-silence (VAD onset + jitter warm-up + tail).
    private func steadyState(_ samples: [Float]) -> [Float] {
        var a = Array(samples.drop { abs($0) < 0.001 }.reversed()
            .drop { abs($0) < 0.001 }.reversed())
        if a.count > 9_600 {
            let cut = a.count / 10
            a = Array(a[cut..<(a.count - cut)])
        }
        return a
    }

    // MARK: - Spectrum measurement

    /// Welch-averaged magnitude spectrum across the whole signal (a single FFT
    /// of a sweep only sees the instantaneous frequency; averaging over hops
    /// recovers the full swept-band envelope).
    private func averagedMagnitude(_ samples: [Float], sampleRate: Double,
                                   frameSize: Int = 2_048, hop: Int = 512)
    -> (mags: [Float], binHz: Double) {
        guard samples.count >= frameSize else { return ([], 0) }
        var acc = [Float](repeating: 0, count: frameSize / 2)
        var frames = 0
        var i = 0
        while i + frameSize <= samples.count {
            let m = AudioAnalysis.magnitudeSpectrum(Array(samples[i..<(i + frameSize)]),
                                                    sampleRate: sampleRate)
            for k in 0..<acc.count { acc[k] += m[k] }
            frames += 1
            i += hop
        }
        guard frames > 0 else { return ([], 0) }
        for k in 0..<acc.count { acc[k] /= Float(frames) }
        return (acc, sampleRate / Double(frameSize))
    }

    /// Highest frequency whose (smoothed) energy is still within `dropDB` of
    /// the reference passband level — i.e. the effective transmitted bandwidth.
    private func effectiveBandwidthHz(_ samples: [Float], sampleRate: Double,
                                      refLoHz: Double = 300, refHiHz: Double = 2_500,
                                      dropDB: Float = 15) -> Double {
        let (mags, binHz) = averagedMagnitude(samples, sampleRate: sampleRate)
        guard !mags.isEmpty else { return 0 }
        func bin(_ hz: Double) -> Int { max(1, min(mags.count - 1, Int((hz / binHz).rounded()))) }

        var refSum: Float = 0, c = 0
        for k in bin(refLoHz)...bin(refHiHz) { refSum += mags[k]; c += 1 }
        let ref = refSum / Float(max(1, c))
        guard ref > 0 else { return 0 }
        let threshold = ref * powf(10, -dropDB / 20)

        // Walk down from the top; report the highest bin whose ±3-bin average
        // still clears the threshold.
        let w = 3
        var k = mags.count - 1 - w
        while k > bin(refHiHz) {
            var s: Float = 0
            for j in (k - w)...(k + w) { s += mags[j] }
            if s / Float(2 * w + 1) >= threshold { return Double(k) * binHz }
            k -= 1
        }
        return refHiHz
    }

    private func normalFormat() -> CaptureFormat {
        // The app's default "Normal" quality (MumbleModels): 64 kbps, 20 ms.
        CaptureFormat(opusBitrate: 64_000, opusFrameMs: 20, opusLowDelay: false)
    }

    // MARK: - Bandwidth preservation at each AirPods-negotiated rate

    /// 24 kHz source = AirPods over VPIO (the common macOS case). The mic
    /// carries content up to 12 kHz and the encoder is set to superwideband,
    /// so the output MUST carry well above the 8 kHz wideband ceiling.
    /// Failing here = "AirPods sound muffled / telephone-y".
    func testAirPods24kSourceKeepsSuperwidebandHighs() {
        let sweep = SignalGenerator.sweep(startHz: 200, endHz: 11_500,
                                          amplitude: 0.35, durationSeconds: 2.0,
                                          sampleRate: 24_000)
        let out = steadyState(roundTrip(input: sweep, sourceRate: 24_000,
                                        format: normalFormat()))
        XCTAssertGreaterThan(out.count, 24_000, "not enough steady-state output")

        let bw = effectiveBandwidthHz(out, sampleRate: 48_000)
        print(String(format: "[FIDELITY] AirPods 24 kHz source → effective output bandwidth = %.0f Hz", bw))
        XCTAssertGreaterThan(bw, 9_000,
            "24 kHz AirPods source rolled off at \(Int(bw)) Hz — voice is capped near wideband (muffled)")
    }

    /// 16 kHz source = AirPods HFP fallback (older stacks). Wideband is the
    /// honest ceiling here; the output should reach the top of the band, not
    /// collapse to narrowband telephone (≤ 3.4 kHz).
    func testAirPodsHFP16kSourceKeepsWideband() {
        let sweep = SignalGenerator.sweep(startHz: 200, endHz: 7_500,
                                          amplitude: 0.35, durationSeconds: 2.0,
                                          sampleRate: 16_000)
        let out = steadyState(roundTrip(input: sweep, sourceRate: 16_000,
                                        format: normalFormat()))
        XCTAssertGreaterThan(out.count, 16_000)

        let bw = effectiveBandwidthHz(out, sampleRate: 48_000)
        print(String(format: "[FIDELITY] AirPods HFP 16 kHz source → effective output bandwidth = %.0f Hz", bw))
        XCTAssertGreaterThan(bw, 6_000,
            "16 kHz source rolled off at \(Int(bw)) Hz — below wideband (telephone-quality)")
    }

    /// 48 kHz source = built-in / USB mic (and newest-OS AirPods). Fullband:
    /// the output must carry genuine high-frequency energy, proving nothing in
    /// the common path is band-limiting good mics.
    func testBuiltInMic48kSourceKeepsFullband() {
        let sweep = SignalGenerator.sweep(startHz: 200, endHz: 18_000,
                                          amplitude: 0.35, durationSeconds: 2.0,
                                          sampleRate: 48_000)
        let out = steadyState(roundTrip(input: sweep, sourceRate: 48_000,
                                        format: normalFormat()))
        XCTAssertGreaterThan(out.count, 48_000)

        let bw = effectiveBandwidthHz(out, sampleRate: 48_000)
        print(String(format: "[FIDELITY] Built-in 48 kHz source → effective output bandwidth = %.0f Hz", bw))
        XCTAssertGreaterThan(bw, 12_000,
            "48 kHz source rolled off at \(Int(bw)) Hz — highs lost on a full-bandwidth mic")
    }

    // MARK: - Holistic voice fidelity through the AirPods path

    /// Fraction of total 125…8000 Hz energy in each octave band. This is a
    /// long-term average, so it is invariant to the jitter-buffer delay and
    /// the syllabic envelope — it captures spectral BALANCE (muffling shows up
    /// as energy shifting out of the high bands) without needing time
    /// alignment or a resampled reference.
    private func octaveBalance(_ samples: [Float], sampleRate: Double) -> [Float] {
        let edges: [Double] = [125, 250, 500, 1_000, 2_000, 4_000, 8_000]
        let (mags, binHz) = averagedMagnitude(samples, sampleRate: sampleRate)
        guard !mags.isEmpty else { return [] }
        var e = [Float](repeating: 0, count: edges.count - 1)
        for b in 0..<e.count {
            let lo = max(1, Int((edges[b] / binHz).rounded()))
            let hi = min(mags.count - 1, Int((edges[b + 1] / binHz).rounded()))
            if hi >= lo { for k in lo...hi { e[b] += mags[k] * mags[k] } }
        }
        let total = e.reduce(0, +)
        guard total > 0 else { return e }
        return e.map { $0 / total }
    }

    /// A voice-like signal through the 24 kHz AirPods path must keep its
    /// spectral balance (no band shifted by more than a few dB) at a healthy
    /// level. This is the "does my actual voice survive" number, measured in a
    /// way that can't be fooled by timing.
    func testVoiceLikeThroughAirPods24kPreservesSpectralBalance() {
        let source = SignalGenerator.voiceLike(pitchHz: 130, amplitude: 0.4,
                                               durationSeconds: 2.0,
                                               sampleRate: 24_000)
        let out = steadyState(roundTrip(input: source, sourceRate: 24_000,
                                        format: normalFormat()))
        XCTAssertGreaterThan(out.count, 24_000)

        let src = octaveBalance(source, sampleRate: 24_000)
        let rcv = octaveBalance(out, sampleRate: 48_000)
        XCTAssertEqual(src.count, rcv.count)

        // Per-band dB deviation of the received balance from the source.
        var worst: Float = 0
        var report = ""
        let labels = ["125-250", "250-500", "500-1k", "1-2k", "2-4k", "4-8k"]
        for b in 0..<src.count where src[b] > 0.005 {   // ignore near-empty bands
            let dB = 10 * log10f(max(rcv[b], 1e-6) / max(src[b], 1e-6))
            worst = max(worst, abs(dB))
            report += String(format: " %@:%+0.1f", labels[b], dB)
        }
        let inRMS = AudioAnalysis.rms(source)
        let outRMS = AudioAnalysis.rms(out)
        let lvlDB = 20 * log10f(max(outRMS, 1e-6) / max(inRMS, 1e-6))
        print(String(format: "[FIDELITY] voiceLike @24 kHz → level %+0.1f dB, worst band Δ %.1f dB;%@",
                     lvlDB, worst, report))

        XCTAssertLessThan(worst, 6.0,
            "voice spectral balance shifted \(worst) dB through the AirPods path (muffling/coloration)")
        XCTAssertLessThan(abs(lvlDB), 6.0, "level shifted \(lvlDB) dB through the AirPods path")
    }
}
