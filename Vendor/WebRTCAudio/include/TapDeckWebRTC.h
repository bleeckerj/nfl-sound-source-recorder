#ifndef TAPDECK_WEBRTC_H
#define TAPDECK_WEBRTC_H
#ifdef __cplusplus
extern "C" {
#endif
typedef struct TDAudioProcessor TDAudioProcessor;
TDAudioProcessor *td_apm_create(void);
void td_apm_destroy(TDAudioProcessor *processor);
/* Exactly 480 normalized float samples per channel, serial worker calls only. */
int td_apm_process(TDAudioProcessor *processor, const float *left, const float *right,
                   const float *microphone, float *cleaned, int delay_ms);
#ifdef __cplusplus
}
#endif
#endif
