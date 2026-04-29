import Foundation
import Opus
import COpusControl

/// Adds bitrate / complexity / FEC / signal-type / packet-loss controls to
/// `Opus.Encoder` by reaching into the wrapper's internal `encoder` pointer
/// and invoking the variadic `opus_encoder_ctl` C API through a tiny C shim.
public extension Opus.Encoder {

    enum ControlError: Error { case encoderHandleUnavailable, opus(Int32) }

    /// Bits per second; valid range roughly 6 000 … 510 000. 0 selects auto.
    func setBitrate(_ bitsPerSecond: Int32) throws {
        try perform { cm_opus_encoder_set_bitrate($0, bitsPerSecond) }
    }

    /// CPU complexity 0 (fastest, lowest quality) … 10 (slowest, best).
    func setComplexity(_ complexity: Int32) throws {
        try perform { cm_opus_encoder_set_complexity($0, complexity) }
    }

    enum SignalType { case voice, music }

    func setSignal(_ signal: SignalType) throws {
        try perform { ptr in
            switch signal {
            case .voice: return cm_opus_encoder_set_signal_voice(ptr)
            case .music: return cm_opus_encoder_set_signal_music(ptr)
            }
        }
    }

    /// Enable in-band Forward Error Correction (helps over lossy links).
    func setInbandFEC(_ enabled: Bool) throws {
        try perform { cm_opus_encoder_set_inband_fec($0, enabled ? 1 : 0) }
    }

    /// Expected packet loss percentage 0…100 (tunes FEC aggressiveness).
    func setPacketLossPercentage(_ percent: Int32) throws {
        try perform { cm_opus_encoder_set_packet_loss_perc($0, max(0, min(100, percent))) }
    }

    func setDTX(_ enabled: Bool) throws {
        try perform { cm_opus_encoder_set_dtx($0, enabled ? 1 : 0) }
    }

    func setVBR(_ enabled: Bool) throws {
        try perform { cm_opus_encoder_set_vbr($0, enabled ? 1 : 0) }
    }

    // MARK: - Internal

    private func perform(_ op: (UnsafeMutableRawPointer) -> Int32) throws {
        guard let raw = Self.extractEncoderPointer(from: self) else {
            throw ControlError.encoderHandleUnavailable
        }
        let result = op(raw)
        if result != 0 { throw ControlError.opus(result) }
    }

    /// Pull the internal `OpaquePointer` named `encoder` out of the Opus.Encoder
    /// instance via runtime reflection. The property is `internal` to the Opus
    /// module so we can't touch it directly from another module.
    private static func extractEncoderPointer(from encoder: Opus.Encoder) -> UnsafeMutableRawPointer? {
        for child in Mirror(reflecting: encoder).children {
            if child.label == "encoder", let op = child.value as? OpaquePointer {
                return UnsafeMutableRawPointer(op)
            }
        }
        return nil
    }
}
