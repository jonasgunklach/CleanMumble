//
//  NoiseSuppressionIntegrationTests.swift
//  AudioEngineTests
//
//  RNNoise wired into the live capture path: enabling it must NOT destroy
//  speech (pitch/level survive) and must still produce a normal utterance.
//  The denoiser's actual attenuation is unit-tested in the RNNoise package;
//  here we prove the CaptureEngine integration is sound end to end.
//

import XCTest
import AVFAudio
import Opus
import AudioCore
@testable import AudioEngine

final class NoiseSuppressionIntegrationTests: XCTestCase {

    private let sampleRate = 48_000.0

    private func capture(_ source: [Float], ns: Bool)
    -> [(seq: UInt64, data: Data, isTerm: Bool)] {
        let engine = CaptureEngine()
        engine.transmitEnabled = true
        engine.vadThreshold = 0.004
        engine.noiseSuppressionEnabled = ns
        let lock = NSLock()
        var packets: [(UInt64, Data, Bool)] = []
        engine.onPacket = { data, seq, term in
            lock.lock(); packets.append((seq, data, term)); lock.unlock()
        }
        engine.start(sourceRate: sampleRate, format: CaptureFormat())
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

    private func decodeFirstFewFramesPitch(_ packets: [(seq: UInt64, data: Data, isTerm: Bool)]) throws -> Double {
        let fmt = AVAudioFormat(opusPCMFormat: .float32, sampleRate: sampleRate, channels: 1)!
        let dec = try Opus.Decoder(format: fmt)
        var pcm: [Float] = []
        for p in packets where !p.isTerm {
            let out = try dec.decode(p.data)
            if let ch = out.floatChannelData?[0] {
                pcm.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            }
            if pcm.count > 20_000 { break }
        }
        return AudioAnalysis.dominantFrequency(pcm, sampleRate: sampleRate).frequency
    }

    func testNoiseSuppressionPreservesVoice() throws {
        // A steady 440 Hz tone (RNNoise passes voiced/tonal energy — verified in
        // the RNNoise package tests): capturing it with NS on must transmit a
        // full utterance and keep the pitch exact through decode.
        let source = SignalGenerator.sine(frequency: 440, amplitude: 0.4,
                                           durationSeconds: 1.2, sampleRate: sampleRate)
        let withNS = capture(source, ns: true).filter { !$0.isTerm }
        XCTAssertGreaterThan(withNS.count, 20, "NS-on should still transmit a full utterance")

        let outPitch = try decodeFirstFewFramesPitch(withNS)
        XCTAssertEqual(outPitch, 440, accuracy: 15,
                       "NS shifted/destroyed the tone pitch (out \(outPitch))")
    }

    func testToggleIsLiveAndDefaultsOff() {
        let engine = CaptureEngine()
        XCTAssertFalse(engine.noiseSuppressionEnabled, "NS must default off")
        engine.noiseSuppressionEnabled = true
        XCTAssertTrue(engine.noiseSuppressionEnabled)
        engine.noiseSuppressionEnabled = false
        XCTAssertFalse(engine.noiseSuppressionEnabled)
    }
}
