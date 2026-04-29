#include "COpusControl.h"
#include <opus.h>

int cm_opus_encoder_set_bitrate(void *enc, int32_t bitrate) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_BITRATE(bitrate));
}

int cm_opus_encoder_set_complexity(void *enc, int32_t complexity) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_COMPLEXITY(complexity));
}

int cm_opus_encoder_set_signal_voice(void *enc) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE));
}

int cm_opus_encoder_set_signal_music(void *enc) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));
}

int cm_opus_encoder_set_inband_fec(void *enc, int enabled) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_INBAND_FEC(enabled ? 1 : 0));
}

int cm_opus_encoder_set_packet_loss_perc(void *enc, int32_t pct) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_PACKET_LOSS_PERC(pct));
}

int cm_opus_encoder_set_dtx(void *enc, int enabled) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_DTX(enabled ? 1 : 0));
}

int cm_opus_encoder_set_vbr(void *enc, int enabled) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_VBR(enabled ? 1 : 0));
}
