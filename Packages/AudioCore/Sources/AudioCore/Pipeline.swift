import Foundation

/// Anything that emits PCM frames — a microphone, a file reader, a synthetic
/// signal generator. Implementations push frames into the pipeline by calling
/// the supplied `onFrame` closure.
public protocol AudioSource: AnyObject {
    var format: AudioFormat { get }
    var onFrame: ((AudioFrame) -> Void)? { get set }
    func start()
    func stop()
}

/// Anything that consumes PCM frames — a speaker, a file writer, a network
/// transport that encodes and ships them.
public protocol AudioSink: AnyObject {
    var format: AudioFormat { get }
    func consume(_ frame: AudioFrame)
}

/// In-place processor: takes a frame, returns a (possibly modified) frame.
/// Typical examples: gain, level meter (transparent), silence gate.
public protocol AudioProcessor: AnyObject {
    func process(_ frame: AudioFrame) -> AudioFrame
}

/// Wraps the network leg. The pipeline doesn't care whether it's a real
/// Mumble TLS+Opus connection or an in-memory loopback for tests.
public protocol VoiceTransport: AnyObject {
    /// Send one frame (typically already encoded by the caller, but the
    /// transport may also do encoding internally — that's a transport-side
    /// concern).
    func send(_ frame: AudioFrame)
    /// Called for every received frame. The transport calls this on whatever
    /// queue it chooses; consumers must be thread-safe.
    var onReceive: ((AudioFrame) -> Void)? { get set }
}
