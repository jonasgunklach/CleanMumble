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

#ifdef __cplusplus
}
#endif

#endif /* CM_OPUS_CONTROL_H */
