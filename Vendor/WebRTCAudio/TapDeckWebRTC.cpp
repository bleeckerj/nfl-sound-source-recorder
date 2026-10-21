#include "include/TapDeckWebRTC.h"
#include "webrtc/modules/audio_processing/include/audio_processing.h"
#include <new>

struct TDAudioProcessor {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    float render[2][480] = {};
};

TDAudioProcessor *td_apm_create() {
    auto *p = new (std::nothrow) TDAudioProcessor;
    if (!p) return nullptr;
    p->apm = webrtc::AudioProcessingBuilder().Create();
    if (!p->apm) { delete p; return nullptr; }
    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.high_pass_filter.enabled = true;
    // Preserve microphone dynamics; only echo cancellation and high-pass filtering.
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    config.noise_suppression.enabled = false;
    p->apm->ApplyConfig(config);
    return p;
}
void td_apm_destroy(TDAudioProcessor *p) { delete p; }
int td_apm_process(TDAudioProcessor *p, const float *left, const float *right,
                   const float *mic, float *cleaned, int delay_ms) {
    if (!p || !left || !right || !mic || !cleaned) return -1;
    const float *render_in[] = {left, right};
    float *render_out[] = {p->render[0], p->render[1]};
    const webrtc::StreamConfig stereo(48000, 2), mono(48000, 1);
    int status = p->apm->ProcessReverseStream(render_in, stereo, stereo, render_out);
    if (status) return status;
    status = p->apm->set_stream_delay_ms(delay_ms);
    if (status) return status;
    const float *input[] = {mic};
    float *output[] = {cleaned};
    return p->apm->ProcessStream(input, mono, mono, output);
}
