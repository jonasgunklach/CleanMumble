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

int cm_opus_encoder_set_lsb_depth(void *enc, int32_t bits) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_LSB_DEPTH(bits));
}

int cm_opus_encoder_set_prediction_disabled(void *enc, int disabled) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_PREDICTION_DISABLED(disabled ? 1 : 0));
}

int cm_opus_encoder_set_max_bandwidth(void *enc, int32_t bandwidth) {
    return opus_encoder_ctl((OpusEncoder *)enc, OPUS_SET_MAX_BANDWIDTH(bandwidth));
}

int cm_opus_decode_float(void *dec,
                         const unsigned char *data, int32_t len,
                         float *pcm, int frame_size,
                         int decode_fec) {
    return opus_decode_float((OpusDecoder *)dec, data, len, pcm, frame_size,
                             decode_fec ? 1 : 0);
}

int cm_opus_decoder_reset(void *dec) {
    return opus_decoder_ctl((OpusDecoder *)dec, OPUS_RESET_STATE);
}
