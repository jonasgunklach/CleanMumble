//
//  Denoiser.swift
//  RNNoise
//
//  Thin Swift wrapper over the vendored RNNoise C library. RNNoise processes
//  fixed 480-sample (10 ms @ 48 kHz) mono frames and, by convention, expects
//  the float samples in 16-bit PCM scale (roughly ±32768) rather than ±1.0 —
//  this wrapper handles that scaling so callers keep working in normalized
//  floats.
//

import CRNNoise

public final class Denoiser {

    /// Samples consumed/produced per `process` call (RNNoise is fixed at 480).
    public static let frameSize = 480

    private let state: OpaquePointer
    private var scratch = [Float](repeating: 0, count: Denoiser.frameSize)

    public init?() {
        // nil model = the built-in trained weights (rnn_data.c).
        guard let st = rnnoise_create(nil) else { return nil }
        state = st
        precondition(rnnoise_get_frame_size() == Int32(Self.frameSize),
                     "RNNoise frame size changed from 480")
    }

    deinit { rnnoise_destroy(state) }

    /// Denoise exactly `frameSize` normalized (±1.0) samples in place.
    /// `samples` must point to at least `frameSize` floats.
    public func process(_ samples: UnsafeMutablePointer<Float>) {
        let n = Self.frameSize
        for i in 0..<n { scratch[i] = samples[i] * 32_768.0 }
        scratch.withUnsafeMutableBufferPointer { buf in
            _ = rnnoise_process_frame(state, buf.baseAddress, buf.baseAddress)
        }
        let inv: Float = 1.0 / 32_768.0
        for i in 0..<n { samples[i] = scratch[i] * inv }
    }
}
