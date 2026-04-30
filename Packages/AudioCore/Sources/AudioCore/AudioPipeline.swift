import Foundation

/// Composes processors in series. Frames flow source → [processors] → sink.
///
///     let pipeline = AudioPipeline(format: .mumble)
///     pipeline.append(GainProcessor(gain: 1.5))
///     pipeline.append(SilenceGate())
///     pipeline.append(meter)
///     pipeline.sink = transportSink
///
/// Push frames in via `push(_:)`. The pipeline does not own a source — it's
/// a passive in/out filter, which makes it trivial to drive from tests.
public final class AudioPipeline {
    public let format: AudioFormat
    public var processors: [AudioProcessor]
    public var sink: AudioSink?

    public init(format: AudioFormat,
                processors: [AudioProcessor] = [],
                sink: AudioSink? = nil) {
        self.format = format
        self.processors = processors
        self.sink = sink
    }

    public func append(_ processor: AudioProcessor) {
        processors.append(processor)
    }

    public func push(_ frame: AudioFrame) {
        precondition(frame.format == format,
                     "Pipeline format \(format) ≠ frame format \(frame.format)")
        var current = frame
        for p in processors {
            current = p.process(current)
        }
        sink?.consume(current)
    }
}

/// Trivial sink that records every frame for assertion in tests.
public final class CapturingSink: AudioSink {
    public let format: AudioFormat
    public private(set) var frames: [AudioFrame] = []
    public init(format: AudioFormat) { self.format = format }
    public func consume(_ frame: AudioFrame) { frames.append(frame) }
    public func reset() { frames.removeAll() }
    /// Concatenated samples across every received frame.
    public var concatenated: [Float] {
        frames.flatMap { $0.samples }
    }
}

/// Sink that hands each frame to a closure (e.g. ringbuffer.write or
/// transport.send).
public final class ClosureSink: AudioSink {
    public let format: AudioFormat
    private let block: (AudioFrame) -> Void
    public init(format: AudioFormat, block: @escaping (AudioFrame) -> Void) {
        self.format = format
        self.block = block
    }
    public func consume(_ frame: AudioFrame) { block(frame) }
}
