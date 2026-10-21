# WebRTC audio processing

`WebRTCAudio` contains the standalone WebRTC AudioProcessing 2.1 release and
Abseil 20240722.0 sources needed by its Meson build. SwiftPM compiles the sources
into TapDeck. No Homebrew libraries or runtime downloads are used.

Upstream inputs:

- https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
  SHA-256: `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe`
- https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz
  SHA-256: `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3`

The source list comes from Meson 1.9.1 with static libraries and forced Abseil
fallback dependencies. Abseil random-number utilities are excluded because APM
does not use them. Headers are retained unchanged. Three guarded translation
units include Intel SSE implementations when compiling for Intel; AVX2 and
optional ARM NEON paths are disabled. The architecture guards use the compiler's
target, including during cross-compilation.

`TapDeckWebRTC.cpp` and `include/TapDeckWebRTC.h` provide the C interface used by
Swift. They configure AEC3 and a high-pass filter. Automatic gain control and
noise suppression are disabled. Calls run on one worker in 10 ms blocks at
48 kHz. DSP sources use optimization in debug builds to maintain real-time
processing speed.

`WebRTC-COPYING`, `Abseil-LICENSE`, and `Licenses/` contain upstream notices.
The app packaging scripts copy these into the bundle's Resources folder.
