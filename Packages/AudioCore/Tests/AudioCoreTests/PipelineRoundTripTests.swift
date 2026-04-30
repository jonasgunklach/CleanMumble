import XCTest
@testable import AudioCore

/// End-to-end pipeline tests using `LoopbackTransport`. These are the
/// specifications the audio stack is held to: drive a known signal through
/// gain → gate → meter → loopback transport → capture, then assert on what
/// arrives at the other side.
final class PipelineRoundTripTests: XCTestCase {

    func test_clean_loopback_preserves_signal_shape() {
        let pipeline = AudioPipeline(format: .mumble,
                                     processors: [GainProcessor(gain: 1.0)])
        let received = CapturingSink(format: .mumble)
        let transport = LoopbackTransport()
        transport.onReceive = { received.consume($0) }
        pipeline.sink = ClosureSink(format: .mumble) { transport.send($0) }

        // Push 0.5 s of 1 kHz sine in 10 ms chunks.
        let s = SignalGenerator.sine(frequency: 1_000, amplitude: 0.4,
                                     durationSeconds: 0.5)
        let chunkSize = 480 // 10 ms @ 48 kHz
        for i in stride(from: 0, to: s.count, by: chunkSize) {
            let end = min(i + chunkSize, s.count)
            let frame = AudioFrame(format: .mumble,
                                   samples: Array(s[i..<end]),
                                   sampleTime: Int64(i))
            pipeline.push(frame)
        }
        transport.flush()

        let out = received.concatenated
        XCTAssertEqual(out.count, s.count)
        XCTAssertGreaterThan(AudioAnalysis.snr(reference: s, received: out), 80,
                             "Lossless transport should round-trip with very high SNR")
        let (freq, _) = AudioAnalysis.dominantFrequency(out, sampleRate: 48_000)
        XCTAssertEqual(freq, 1_000, accuracy: 5)
    }

    func test_gain_change_scales_received_amplitude() {
        let gain = GainProcessor(gain: 2.0)
        let pipeline = AudioPipeline(format: .mumble, processors: [gain])
        let received = CapturingSink(format: .mumble)
        let transport = LoopbackTransport()
        transport.onReceive = { received.consume($0) }
        pipeline.sink = ClosureSink(format: .mumble) { transport.send($0) }

        let s = SignalGenerator.sine(frequency: 800, amplitude: 0.2,
                                     durationSeconds: 0.2)
        pipeline.push(AudioFrame(format: .mumble, samples: s))
        transport.flush()
        let peakOut = AudioAnalysis.peak(received.concatenated)
        XCTAssertEqual(peakOut, 0.4, accuracy: 0.005)
    }

    func test_silenceGate_strips_quiet_segments_from_transport() {
        let gate = SilenceGate(openThreshold: 0.02, closeThreshold: 0.01,
                               holdSeconds: 0.05)
        let pipeline = AudioPipeline(format: .mumble, processors: [gate])
        let received = CapturingSink(format: .mumble)
        let transport = LoopbackTransport()
        transport.onReceive = { received.consume($0) }
        pipeline.sink = ClosureSink(format: .mumble) { transport.send($0) }

        // 200 ms silence → 100 ms loud sine → 200 ms silence
        pipeline.push(AudioFrame(format: .mumble,
                                 samples: SignalGenerator.silence(durationSeconds: 0.2)))
        pipeline.push(AudioFrame(format: .mumble,
                                 samples: SignalGenerator.sine(frequency: 800,
                                                                amplitude: 0.4,
                                                                durationSeconds: 0.1)))
        // Plenty of silence after, well past the hold.
        for _ in 0..<10 {
            pipeline.push(AudioFrame(format: .mumble,
                                     samples: SignalGenerator.silence(durationSeconds: 0.05)))
        }
        transport.flush()

        let out = received.concatenated
        // Loud segment must survive intact (peak preserved)
        XCTAssertGreaterThan(AudioAnalysis.peak(out), 0.35)
        // The very last 200 ms should be silent (gate closed long before).
        let tail = out.suffix(9_600)  // 0.2 s
        XCTAssertEqual(AudioAnalysis.peak(Array(tail)), 0, accuracy: 1e-6)
    }

    func test_packet_loss_does_not_crash_or_drift() {
        let pipeline = AudioPipeline(format: .mumble)
        let received = CapturingSink(format: .mumble)
        let transport = LoopbackTransport()
        transport.lossProbability = 0.2
        transport.onReceive = { received.consume($0) }
        pipeline.sink = ClosureSink(format: .mumble) { transport.send($0) }

        let s = SignalGenerator.sine(frequency: 1_000, amplitude: 0.3,
                                     durationSeconds: 1.0)
        let chunkSize = 480
        var sent = 0
        for i in stride(from: 0, to: s.count, by: chunkSize) {
            let end = min(i + chunkSize, s.count)
            pipeline.push(AudioFrame(format: .mumble,
                                     samples: Array(s[i..<end])))
            sent += 1
        }
        transport.flush()
        let receivedFrames = received.frames.count
        // ~80 % delivery expected; allow generous margin.
        XCTAssertGreaterThan(receivedFrames, sent * 5 / 10)
        XCTAssertLessThanOrEqual(receivedFrames, sent)
    }
}
