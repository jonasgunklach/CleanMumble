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

    /// Effective sample resolution hint. 16 = standard 16-bit PCM source
    /// (which is what 48 kHz Float32 voice effectively contains after the
    /// AGC/limiter chain). Helps the encoder skip unnecessary noise modelling
    /// at low bitrates.
    func setLSBDepth(_ bits: Int32) throws {
        try perform { cm_opus_encoder_set_lsb_depth($0, bits) }
    }

    /// Disable predictive coding (CELT mode only). Reduces dependency between
    /// frames — better packet-loss resilience at the cost of ~1–2 dB SNR.
    func setPredictionDisabled(_ disabled: Bool) throws {
        try perform { cm_opus_encoder_set_prediction_disabled($0, disabled ? 1 : 0) }
    }

    /// Audio bandwidth ceiling. Capping to the capture source's real
    /// bandwidth stops the encoder spending bits on empty spectrum — at low
    /// bitrates those bits noticeably improve the band that matters.
    enum MaxBandwidth: Int32 {
        case narrowband  = 1101   // 4 kHz  (8 kHz source)
        case mediumband  = 1102   // 6 kHz  (12 kHz source)
        case wideband    = 1103   // 8 kHz  (16 kHz source, BT HFP mic)
        case superwideband = 1104 // 12 kHz (24 kHz source)
        case fullband    = 1105   // 20 kHz (48 kHz source, default)
    }

    func setMaxBandwidth(_ bw: MaxBandwidth) throws {
        try perform { cm_opus_encoder_set_max_bandwidth($0, bw.rawValue) }
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
