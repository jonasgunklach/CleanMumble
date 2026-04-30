import Foundation

/// In-process transport: anything `send()` is delivered to `onReceive` after
/// an optional fixed delay and / or random packet loss. Lets us assert the
/// pipeline's behaviour under realistic network conditions without booting
/// a real Mumble server.
public final class LoopbackTransport: VoiceTransport {
    public var onReceive: ((AudioFrame) -> Void)?
    /// Fixed one-way delay applied to every delivered frame.
    public var delaySeconds: Double = 0
    /// Probability (0…1) that a given frame is dropped.
    public var lossProbability: Double = 0
    /// If true, two consecutive frames may be delivered out of order.
    public var jitterReorder: Bool = false
    private let queue = DispatchQueue(label: "AudioCore.LoopbackTransport")
    private var seed: UInt64 = 0xC0FFEE
    private var pending: AudioFrame?

    public init() {}

    public func send(_ frame: AudioFrame) {
        // Loss
        let r = nextUnitInterval()
        if r < lossProbability { return }
        let deliver: () -> Void = { [weak self] in
            guard let self else { return }
            self.deliver(frame)
        }
        if delaySeconds > 0 {
            queue.asyncAfter(deadline: .now() + delaySeconds, execute: deliver)
        } else {
            queue.async(execute: deliver)
        }
    }

    private func deliver(_ frame: AudioFrame) {
        if jitterReorder, let prev = pending {
            // Swap order of this frame and the previous one
            onReceive?(frame)
            onReceive?(prev)
            pending = nil
            return
        }
        if jitterReorder, pending == nil {
            pending = frame
            return
        }
        onReceive?(frame)
    }

    /// Drain any queued frames synchronously (test helper).
    public func flush() {
        queue.sync { /* barrier */ }
        if let p = pending {
            onReceive?(p)
            pending = nil
        }
    }

    private func nextUnitInterval() -> Double {
        seed &+= 0x9E3779B97F4A7C15
        var z = seed
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        z ^= z &>> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
