//
//  DenoiserTests.swift
//  RNNoiseTests
//

import XCTest
@testable import RNNoise

final class DenoiserTests: XCTestCase {

    /// Deterministic white noise in [-amp, amp].
    private func whiteNoise(_ n: Int, amp: Float = 0.3, seed: UInt64 = 0xD1CE) -> [Float] {
        var s = seed
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(s >> 40) / Float(1 << 24)   // [0,1)
            out[i] = (u * 2 - 1) * amp
        }
        return out
    }

    private func rms<C: Collection>(_ x: C) -> Float where C.Element == Float {
        guard !x.isEmpty else { return 0 }
        var s: Float = 0
        for v in x { s += v * v }
        return (s / Float(x.count)).squareRoot()
    }

    func testFrameSizeIs480() {
        XCTAssertEqual(Denoiser.frameSize, 480)
        XCTAssertNotNil(Denoiser())
    }

    /// On pure (non-speech) noise, RNNoise should strongly attenuate the
    /// signal once its noise estimate has ramped up.
    func testSuppressesStationaryNoise() throws {
        let dn = try XCTUnwrap(Denoiser())
        let frames = 120
        let fs = Denoiser.frameSize
        var noise = whiteNoise(frames * fs)

        var inRMS: Float = 0
        var outRMS: Float = 0
        noise.withUnsafeMutableBufferPointer { buf in
            for f in 0..<frames {
                let base = buf.baseAddress! + f * fs
                // Measure input/output energy only on the settled tail.
                if f >= 100 { inRMS += rms(UnsafeBufferPointer(start: base, count: fs)) }
                dn.process(base)
                if f >= 100 { outRMS += rms(UnsafeBufferPointer(start: base, count: fs)) }
            }
        }
        XCTAssertGreaterThan(inRMS, 0)
        let ratio = outRMS / inRMS
        print(String(format: "[RNNoise] steady noise out/in = %.3f", ratio))
        // White noise is a worst case (broadband, partly speech-like); real
        // stationary noise suppresses far more. Require meaningful attenuation.
        XCTAssertLessThan(ratio, 0.85, "RNNoise should attenuate stationary noise (got \(ratio))")
    }

    /// A steady tone (voiced-ish energy) must not be annihilated the way pure
    /// noise is — sanity that we didn't wire up a mute.
    func testTonePartiallyPreserved() throws {
        let dn = try XCTUnwrap(Denoiser())
        let fs = Denoiser.frameSize
        let frames = 120
        var tone = [Float](repeating: 0, count: frames * fs)
        let step = 2 * Float.pi * 300 / 48_000
        var ph: Float = 0
        for i in 0..<tone.count { tone[i] = sinf(ph) * 0.3; ph += step }

        var inRMS: Float = 0, outRMS: Float = 0
        tone.withUnsafeMutableBufferPointer { buf in
            for f in 0..<frames {
                let base = buf.baseAddress! + f * fs
                if f >= 100 { inRMS += rms(UnsafeBufferPointer(start: base, count: fs)) }
                dn.process(base)
                if f >= 100 { outRMS += rms(UnsafeBufferPointer(start: base, count: fs)) }
            }
        }
        let ratio = outRMS / inRMS
        print(String(format: "[RNNoise] steady tone out/in = %.3f", ratio))
        XCTAssertGreaterThan(ratio, 0.1, "a steady tone should not be fully suppressed (got \(ratio))")
    }
}
