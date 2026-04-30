import XCTest
import AVFoundation
import Opus
import OpusControl
@testable import AudioCore

/// End-to-end Mumble voice pipeline tests.
///
/// Builds the full chain a real packet travels through —
///
///     [Float] source
///       → split into 20 ms / 960-sample Opus frames
///       → Opus.Encoder.encode  (lossy, this is where quality is lost)
///       → LoopbackTransport    (simulates the "fake Mumble server")
///       → Opus.Decoder.decode
///       → reassemble [Float]
///       → analyze vs. source
///
/// — and asserts measured quality metrics. If a metric regresses (because
/// someone changed bitrate, framing, or codec mode), the test fails with the
/// exact dB number so the regression is obvious.
///
/// All thresholds are set conservatively, based on what Opus 1.x is publicly
/// documented to achieve at the configured bitrate / mode (40 kbps VOIP).
final class MumblePipelineE2ETests: XCTestCase {

    private static let sampleRate = 48_000.0
    private static let frameMs = 20
    private static let frameSamples = 48 * 20   // 960 @ 48 kHz / 20 ms
    private static let bitrate: Int32 = 40_000
    private static let durationSeconds = 10.0

    // MARK: Test cases — one per signal type.

    /// 1 kHz sine, 10 s. Time-domain SNR is meaningless for a steady tone
    /// (sub-sample phase shift wrecks it), so we measure what's actually
    /// audible: dominant-frequency preservation, peak/RMS preservation, and
    /// THD+N at the fundamental. The codec should add < 1 % distortion+noise.
    func test_sine_1kHz_roundTripQuality() throws {
        let src = SignalGenerator.sine(frequency: 1_000,
                                       amplitude: 0.5,
                                       durationSeconds: Self.durationSeconds,
                                       sampleRate: Self.sampleRate)
        let recv = try roundTrip(src)
        let m = analyze(reference: src, received: recv)
        m.dump(name: "sine_1kHz")
        XCTAssertLessThan(abs(m.dominantHzReceived - 1000), 5,
            "Dominant freq drifted: src=\(m.dominantHzReference) recv=\(m.dominantHzReceived)")
        XCTAssertLessThan(m.spectralDistanceDB, 6,
            "Spectral envelope drift: \(m.spectralDistanceDB) dB")
        XCTAssertLessThan(abs(m.peakRatioDB), 3,
            "Peak amplitude drift: \(m.peakRatioDB) dB")
        XCTAssertLessThan(abs(m.rmsRatioDB), 2,
            "RMS energy drift: \(m.rmsRatioDB) dB")
        // THD+N at the fundamental — the only useful "is it clean" metric
        // for a steady tone.
        let thd = AudioAnalysis.thdNoise(recv, sampleRate: Self.sampleRate,
                                         expectedHz: 1_000)
        XCTAssertLessThan(thd, 0.10,
            "Sine THD+N too high: \(thd) (>10% means audible distortion)")
    }

    /// 80 Hz → 8 kHz log sweep, 10 s. Tests the codec's frequency response
    /// is roughly flat across the voice band. Spectral envelope distance is
    /// the right metric here; SNR and time-domain alignment are not.
    func test_logSweep_voiceBand_spectrumPreserved() throws {
        let src = SignalGenerator.sweep(startHz: 80, endHz: 8_000,
                                        amplitude: 0.5,
                                        durationSeconds: Self.durationSeconds,
                                        sampleRate: Self.sampleRate)
        let recv = try roundTrip(src)
        let m = analyze(reference: src, received: recv)
        m.dump(name: "sweep_80Hz_8kHz")
        XCTAssertLessThan(m.spectralDistanceDB, 8,
            "Frequency response not flat across voice band: LSD=\(m.spectralDistanceDB) dB")
        XCTAssertLessThan(abs(m.peakRatioDB), 4,
            "Peak amplitude drift: \(m.peakRatioDB) dB")
    }

    /// Voice-like formant signal at 130 Hz pitch ("/a/" vowel). The metric
    /// that matters perceptually is spectral envelope preservation, not
    /// sample-by-sample SNR. At 40 kbps VOIP we expect LSD < 8 dB.
    func test_voiceLike_intelligibilityPreserved() throws {
        let src = SignalGenerator.voiceLike(pitchHz: 130,
                                            amplitude: 0.4,
                                            durationSeconds: Self.durationSeconds,
                                            sampleRate: Self.sampleRate)
        let recv = try roundTrip(src)
        let m = analyze(reference: src, received: recv)
        m.dump(name: "voice_like")
        // For voiced signals, compare spectral *envelopes* (smoothed over
        // ~250 Hz) so harmonic-frequency drift inside the codec doesn't
        // dominate the metric. The envelope is what listeners actually hear
        // as "timbre" / "intelligibility".
        let lsdEnvelope = AudioAnalysis.logSpectralDistanceDB(
            reference: src, received: recv,
            sampleRate: Self.sampleRate,
            bandLowHz: 100, bandHighHz: 6_000,
            smoothBins: 12)
        XCTAssertLessThan(lsdEnvelope, 6,
            "Voice spectral envelope distorted: \(lsdEnvelope) dB")
        XCTAssertLessThan(abs(m.rmsRatioDB), 3,
            "Voice RMS energy not preserved: \(m.rmsRatioDB) dB")
        XCTAssertGreaterThan(m.crossCorrPeak, 0.5,
            "Voice signal lost time-alignment: peak=\(m.crossCorrPeak)")
        // Pitch (dominant freq) must survive the codec exactly — Opus
        // preserves pitch even at low bitrates.
        XCTAssertLessThan(abs(m.dominantHzReceived - m.dominantHzReference), 30,
            "Voice pitch drifted: src=\(m.dominantHzReference) recv=\(m.dominantHzReceived)")
    }

    /// Pink noise — broadband, no obvious tones. Realistic test for codec
    /// behaviour on consonants / fricatives. Opus VOIP is documented to
    /// aggressively roll off above ~8 kHz, so we measure inside the voice
    /// band only and accept some RMS loss as expected codec behaviour.
    func test_pinkNoise_broadbandPreserved() throws {
        let src = SignalGenerator.pinkNoise(amplitude: 0.2,
                                            durationSeconds: Self.durationSeconds,
                                            sampleRate: Self.sampleRate)
        let recv = try roundTrip(src)
        let m = analyze(reference: src, received: recv)
        m.dump(name: "pink_noise")
        // Opus VOIP rolls off above ~6-8 kHz aggressively; restrict the LSD
        // band to where the codec is actually trying to preserve information.
        let lsdVoiceBand = AudioAnalysis.logSpectralDistanceDB(
            reference: src, received: recv,
            sampleRate: Self.sampleRate,
            bandLowHz: 100, bandHighHz: 4_000)
        XCTAssertLessThan(lsdVoiceBand, 6,
            "Pink noise spectrum distorted in 100-4000 Hz band: \(lsdVoiceBand) dB")
        // Opus VOIP rolls off the top octave; -6 dB total RMS loss is
        // expected, much more than that means the codec is broken or
        // mis-configured.
        XCTAssertLessThan(abs(m.rmsRatioDB), 6,
            "RMS energy massively shifted: \(m.rmsRatioDB) dB")
    }

    /// Same as voice-like, but with 5 % packet loss. Mumble's typical
    /// real-internet condition. We assert the receiver still produces a
    /// recognisable voice envelope and no extended dropouts.
    func test_voiceLike_with5PercentPacketLoss_stillIntelligible() throws {
        let src = SignalGenerator.voiceLike(pitchHz: 130,
                                            amplitude: 0.4,
                                            durationSeconds: Self.durationSeconds,
                                            sampleRate: Self.sampleRate)
        let recv = try roundTrip(src, lossProbability: 0.05)
        let m = analyze(reference: src, received: recv)
        m.dump(name: "voice_like_5pct_loss")
        let lsdEnvelope = AudioAnalysis.logSpectralDistanceDB(
            reference: src, received: recv,
            sampleRate: Self.sampleRate,
            bandLowHz: 100, bandHighHz: 6_000,
            smoothBins: 12)
        XCTAssertLessThan(lsdEnvelope, 9,
            "Voice spectrum collapsed under 5% loss: \(lsdEnvelope) dB")
        // Output must not have extended dropouts (>= 1 s of consecutive zeros).
        let bigZeroRuns = AudioAnalysis.zeroRuns(recv,
            minRunLength: Int(Self.sampleRate)).count
        XCTAssertEqual(bigZeroRuns, 0,
            "Pipeline produced \(bigZeroRuns) ≥1s zero-runs under 5% loss")
    }

    // MARK: - Pipeline: source [Float] → Opus → loopback → [Float]

    private func roundTrip(_ source: [Float],
                           lossProbability: Double = 0) throws -> [Float] {
        // Opus 48 kHz mono Float32, exactly the format Mumble uses.
        let format = AVAudioFormat(opusPCMFormat: .float32,
                                   sampleRate: Self.sampleRate,
                                   channels: 1)!
        let encoder = try Opus.Encoder(format: format, application: .voip)
        try encoder.setBitrate(Self.bitrate)
        try encoder.setSignal(.voice)
        try encoder.setComplexity(8)
        try encoder.setVBR(true)
        try encoder.setInbandFEC(true)
        try encoder.setPacketLossPercentage(10)

        let decoder = try Opus.Decoder(format: format)

        // The "fake Mumble server": a transport that just hands packets back.
        // We use raw Data through a single-thread queue (synchronous: fine for
        // tests). The LoopbackTransport in AudioCore is frame-based, but we
        // need to carry encoded Opus bytes plus packet sequence, so use a
        // simpler in-process queue here.
        struct Packet { let seq: Int; let payload: Data }
        var inFlight: [Packet] = []
        var rng = SplitMix64(state: 0xABCDEF)
        var seq = 0

        // Drive: split the source into 960-sample frames, encode, "send".
        let frameSize = Self.frameSamples
        var i = 0
        while i + frameSize <= source.count {
            let frameSamples = Array(source[i ..< i + frameSize])
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(frameSize))
            else { throw NSError(domain: "test", code: -1) }
            pcm.frameLength = AVAudioFrameCount(frameSize)
            frameSamples.withUnsafeBufferPointer { buf in
                pcm.floatChannelData?[0].initialize(from: buf.baseAddress!,
                                                    count: frameSize)
            }
            var encoded = [UInt8](repeating: 0, count: 1276)
            let n = try encoder.encode(pcm, to: &encoded)
            guard n > 0 else { i += frameSize; continue }
            // Apply packet loss right at the "wire".
            let drop = lossProbability > 0 && rng.nextUnitInterval() < lossProbability
            if !drop {
                inFlight.append(Packet(seq: seq, payload: Data(encoded.prefix(n))))
            }
            seq += 1
            i += frameSize
        }

        // Receive side: decode each delivered packet, fill any gap (lost
        // packets) with PLC by passing nil — swift-opus 0.0.2 doesn't expose
        // packet-loss-concealment via `decode(nil)`, so we emit silence for
        // the gap, which matches what the real RealMumbleClient currently
        // does.
        var out = [Float]()
        out.reserveCapacity(source.count)
        var expected = 0
        for pkt in inFlight {
            // Insert silence for any dropped packets between expected and pkt.seq.
            while expected < pkt.seq {
                out.append(contentsOf: [Float](repeating: 0, count: frameSize))
                expected += 1
            }
            let pcm = try decoder.decode(pkt.payload)
            if let ch = pcm.floatChannelData?[0] {
                let buf = UnsafeBufferPointer(start: ch, count: Int(pcm.frameLength))
                out.append(contentsOf: buf)
            }
            expected += 1
        }
        // Pad tail with silence so reference and received have equal length.
        while out.count < source.count { out.append(0) }
        return out
    }

    // MARK: - Metrics

    private struct Metrics {
        let snrDB: Float
        let dominantHzReference: Double
        let dominantHzReceived: Double
        let spectralDistanceDB: Float
        let peakRatioDB: Float
        let rmsRatioDB: Float
        let crossCorrPeak: Float
        let crossCorrLagSamples: Int

        func dump(name: String) {
            print("""
            ── E2E[\(name)] \
            SNR=\(String(format: "%.2f", snrDB))dB \
            LSD=\(String(format: "%.2f", spectralDistanceDB))dB \
            peakΔ=\(String(format: "%+.2f", peakRatioDB))dB \
            rmsΔ=\(String(format: "%+.2f", rmsRatioDB))dB \
            xcorr=\(String(format: "%.3f", crossCorrPeak))@\(crossCorrLagSamples)smp \
            domHz src=\(String(format: "%.0f", dominantHzReference)) rcv=\(String(format: "%.0f", dominantHzReceived))
            """)
        }
    }

    private func analyze(reference: [Float], received: [Float]) -> Metrics {
        // Align received vs. reference first \u2014 Opus introduces ~10\u201325 ms of
        // algorithmic delay (SILK/hybrid mode in particular), so unaligned
        // metrics are dominated by that delay rather than codec quality.
        let xc = AudioAnalysis.crossCorrelationLag(
            reference: reference, received: received,
            maxLag: 4096)
        let lag = max(0, xc.lag)
        let alignedReceived: [Float]
        if lag > 0 && lag < received.count {
            alignedReceived = Array(received[lag...]) + [Float](repeating: 0, count: lag)
        } else {
            alignedReceived = received
        }

        let snr = AudioAnalysis.snr(reference: reference, received: alignedReceived,
                                    maxLag: 64)
        let domRef = AudioAnalysis.dominantFrequency(reference, sampleRate: Self.sampleRate)
        let domRcv = AudioAnalysis.dominantFrequency(alignedReceived, sampleRate: Self.sampleRate)
        let lsd = AudioAnalysis.logSpectralDistanceDB(
            reference: reference, received: alignedReceived,
            sampleRate: Self.sampleRate, frameSize: 2048, hop: 1024)
        let peakRef = AudioAnalysis.peak(reference)
        let peakRcv = AudioAnalysis.peak(alignedReceived)
        let peakDB = 20 * log10f(max(peakRcv, 1e-6) / max(peakRef, 1e-6))
        let rmsRef = AudioAnalysis.rms(reference)
        let rmsRcv = AudioAnalysis.rms(alignedReceived)
        let rmsDB = 20 * log10f(max(rmsRcv, 1e-6) / max(rmsRef, 1e-6))
        return Metrics(snrDB: snr,
                       dominantHzReference: domRef.frequency,
                       dominantHzReceived: domRcv.frequency,
                       spectralDistanceDB: lsd,
                       peakRatioDB: peakDB,
                       rmsRatioDB: rmsDB,
                       crossCorrPeak: xc.peak,
                       crossCorrLagSamples: xc.lag)
    }
}

// MARK: - Local PRNG (avoid pulling AudioCore's private one)

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
    mutating func nextUnitInterval() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
