import Foundation
import Opus
import COpusControl

/// Adds FEC + PLC capable decode entry points to `Opus.Decoder` by reaching
/// into the wrapper's internal `decoder` pointer (mirror trick, same as the
/// encoder side) and calling our C shim.
public extension Opus.Decoder {

    enum DecoderControlError: Error { case decoderHandleUnavailable, opus(Int32) }

    /// Decode a packet into 48 kHz mono Float32 PCM.
    ///
    /// - Parameters:
    ///   - data: Raw Opus packet bytes. Pass `nil` to request packet-loss
    ///     concealment (PLC) for one missing frame.
    ///   - frameSize: Maximum frames-per-channel the caller has space for in
    ///     `pcm`. Use 5760 for the worst-case 120 ms frame at 48 kHz.
    ///   - pcm: Output buffer; must hold at least `frameSize` floats (mono).
    ///   - decodeFEC: Pass `true` together with the *next* packet's bytes to
    ///     recover the *previous* (lost) frame from in-band FEC.
    /// - Returns: Number of samples decoded per channel (or throws on error).
    @discardableResult
    func decodeFloat(_ data: UnsafePointer<UInt8>?, length: Int32,
                     into pcm: UnsafeMutablePointer<Float>,
                     frameSize: Int32,
                     decodeFEC: Bool = false) throws -> Int {
        guard let raw = Self.extractDecoderPointer(from: self) else {
            throw DecoderControlError.decoderHandleUnavailable
        }
        let result = cm_opus_decode_float(raw, data, length, pcm, frameSize,
                                          decodeFEC ? 1 : 0)
        if result < 0 { throw DecoderControlError.opus(result) }
        return Int(result)
    }

    /// PLC convenience: synthesize one frame of audio for a *known-missing*
    /// packet. `frameSize` should match what the rest of the stream uses
    /// (10 ms = 480, 20 ms = 960, etc. at 48 kHz).
    @discardableResult
    func concealLostFrame(into pcm: UnsafeMutablePointer<Float>,
                          frameSize: Int32) throws -> Int {
        return try decodeFloat(nil, length: 0, into: pcm,
                               frameSize: frameSize, decodeFEC: false)
    }

    /// Reset internal decoder state (e.g. on a Mumble terminator packet, or
    /// when a speaker stops talking and a new one takes the slot).
    func resetState() throws {
        guard let raw = Self.extractDecoderPointer(from: self) else {
            throw DecoderControlError.decoderHandleUnavailable
        }
        let r = cm_opus_decoder_reset(raw)
        if r != 0 { throw DecoderControlError.opus(r) }
    }

    private static func extractDecoderPointer(from decoder: Opus.Decoder) -> UnsafeMutableRawPointer? {
        for child in Mirror(reflecting: decoder).children {
            if child.label == "decoder", let op = child.value as? OpaquePointer {
                return UnsafeMutableRawPointer(op)
            }
        }
        return nil
    }
}
