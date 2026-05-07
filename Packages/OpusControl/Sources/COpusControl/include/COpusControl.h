#ifndef CM_OPUS_CONTROL_H
#define CM_OPUS_CONTROL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Each function returns the underlying opus error code (0 == OPUS_OK).
// `enc` must be the OpaquePointer obtained from `Opus.Encoder.encoder`.
int cm_opus_encoder_set_bitrate(void *enc, int32_t bitrate);
int cm_opus_encoder_set_complexity(void *enc, int32_t complexity);  // 0…10
int cm_opus_encoder_set_signal_voice(void *enc);
int cm_opus_encoder_set_signal_music(void *enc);
int cm_opus_encoder_set_inband_fec(void *enc, int enabled);
int cm_opus_encoder_set_packet_loss_perc(void *enc, int32_t pct);   // 0…100
int cm_opus_encoder_set_dtx(void *enc, int enabled);
int cm_opus_encoder_set_vbr(void *enc, int enabled);

// Effective sample resolution hint, 8–24. 16 = standard 16-bit PCM source.
int cm_opus_encoder_set_lsb_depth(void *enc, int32_t bits);
// Disable predictive coding (CELT only). 0 = predictor on (default), 1 = off.
int cm_opus_encoder_set_prediction_disabled(void *enc, int disabled);

// ---- Decoder side ----------------------------------------------------------
// `dec` must be the OpaquePointer obtained from `Opus.Decoder.decoder`.
//
// Decode a packet into 32-bit float interleaved PCM. Pass `data == NULL` and
// `len == 0` to request packet-loss concealment (PLC) for a missing frame.
// Pass `decode_fec != 0` together with the *next* packet's bytes to recover
// the previous (lost) frame from in-band FEC.
//
// Returns the number of samples per channel decoded, or a negative opus
// error code.
int cm_opus_decode_float(void *dec,
                         const unsigned char *data, int32_t len,
                         float *pcm, int frame_size,
                         int decode_fec);

// Reset decoder state (e.g. on a Mumble "terminator" packet or speaker
// switch). Returns the underlying opus error code.
int cm_opus_decoder_reset(void *dec);

#ifdef __cplusplus
}
#endif

#endif /* CM_OPUS_CONTROL_H */
