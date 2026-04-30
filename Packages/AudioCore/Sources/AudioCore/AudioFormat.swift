import Foundation

/// Canonical PCM format used throughout the pipeline.
public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        precondition(sampleRate > 0)
        precondition(channelCount > 0)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// 48 kHz mono Float32 — the format the Mumble pipeline operates in.
    public static let mumble = AudioFormat(sampleRate: 48_000, channelCount: 1)
}

/// A chunk of mono / multichannel Float32 PCM. Storage is owned by the frame.
///
/// The pipeline standardises on Float32 because every relevant codec (Opus),
/// every analysis routine (FFT, RMS), and every macOS/iOS audio API speaks it
/// natively. Integer formats are converted at the device boundary.
public struct AudioFrame: Sendable {
    public let format: AudioFormat
    /// Interleaved samples. For mono this is just `frameCount` samples.
    public var samples: [Float]
    public var frameCount: Int { samples.count / format.channelCount }
    public var sampleTime: Int64

    public init(format: AudioFormat, samples: [Float], sampleTime: Int64 = 0) {
        precondition(samples.count % format.channelCount == 0)
        self.format = format
        self.samples = samples
        self.sampleTime = sampleTime
    }

    /// Allocate a zero-filled frame of `frameCount` frames.
    public static func silence(format: AudioFormat,
                               frameCount: Int,
                               sampleTime: Int64 = 0) -> AudioFrame {
        AudioFrame(format: format,
                   samples: [Float](repeating: 0, count: frameCount * format.channelCount),
                   sampleTime: sampleTime)
    }
}
