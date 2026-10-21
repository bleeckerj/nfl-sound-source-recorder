# Speaker recording

TapDeck has an explicit **Open speakers: echo cancellation** mode. It uses local
WebRTC AEC3 processing with the captured app audio as the reference. Standard
recording remains the default. This first version supports the built-in Mac
microphone and speakers.

## Use

In the app, select the call app under Record and enable Open speakers. Select the
built-in microphone if it is not already selected. The switch sets Route to None
and leaves the original app output audible. Routing controls stay disabled for
this recording mode. Echo cancellation adapts during the first few seconds.

Record must be the call app or All System Audio. **None — microphone only** has no
direct app audio for the echo reference. The controls show a setup warning when
either source is missing, and REC stays disabled until both selections are valid.
The app validates the selections ahead of permission requests. It repeats
validation when a permission prompt closes. The shared recorder rejects an invalid
source before opening audio devices or creating recording files. To record only
the microphone, turn off Open speakers.

When setup is invalid, its warning replaces the general echo-cancellation hint.
Selecting an app/system source and microphone removes the warning and enables REC.

CLI example:

```sh
"dist/TapDeck CLI.app/Contents/MacOS/nfl-sound-recorder" \
  --system --mic-default --speaker-mode --file "$HOME/Music/TapDeck/meeting.m4a"
```

MCP `start_recording` accepts `speaker_mode: true` with a call app or system
source and `microphone: "default"` or the built-in microphone UID. Output defaults
to record-only in this mode. Explicit routing or muting requests are rejected.
Status and stop results include `speakerMode`, `sourceFiles`, and any error.

For a mix named `meeting.m4a`, `meeting.sources/` contains:

- `app-audio.caf`: direct stereo app audio at 48 kHz.
- `microphone-raw.caf`: microphone audio before echo cancellation, mono at 48 kHz.
- `microphone-cleaned.caf`: the processed microphone, mono at 48 kHz.
- `session.json`: backend, format, source filenames, frame count, completion and errors.

The mix uses direct app audio plus the cleaned microphone. Per-feed gains and EQ
apply to the mix; source tracks retain their original levels. Source tracks use
Float32 PCM, approximately 46 MB/min in total, in addition to the mix.

## Timing and failure handling

Device callbacks copy PCM into bounded, timestamped buffers. Both feeds are
resampled onto a shared 48 kHz host-time timeline, correcting independent clock
rates without allowing drift to accumulate. One worker processes 10 ms blocks
with 40 ms of input buffering. The microphone advances the timeline when the app
is silent. The processor continues adapting during warmup and pauses; all files
share the same saving decision.

A device change, missing microphone timeline, processing error or file-writer
failure stops and finalizes the recording. The reason remains available to every
front end and in the session JSON. The engine never substitutes raw app-plus-mic
mixing after an echo-cancellation failure. Existing destinations are preserved.

DSP code is optimized in debug builds as well as release builds. The initial
unoptimized build could not sustain live processing and stopped with a timeline
overrun.

## Local qualification, October 20, 2026

MacBook Air microphone and speakers, both at 48 kHz:

- The optimized 20-second controlled speech capture completed successfully.
- Each source track contains 919,200 frames; no writer frames were dropped.
- After three seconds of convergence, the analyzer selected 9.88 seconds of speech.
- Raw microphone RMS during those portions was -26.19 dBFS.
- Cleaned microphone RMS was 23.05 dB lower, exceeding the 20 dB speaker-only target.
- The synthetic delayed, speech-modulated echo test measured 33.35 dB reduction.
  An independent signal added after convergence retained its level within 0.62 dB.
- A continuous stationary-noise test measured 18.81 dB total RMS reduction.

Evidence is stored in
`/Users/julian/Music/TapDeck/Speaker Mode Qualification/2026-10-20-test-8/`.
`acoustic-analysis.json` contains the measurement and criteria. Capture completion
alone does not establish echo suppression. The acoustic measurement assumes
controlled speaker-only playback in a quiet room.

Actual overlapping speech in a Zoom call, Zoom coexistence and a 90-minute live
soak have not been verified. The independent-signal test is an algorithm check.
It does not establish live-call performance. External speakers, USB microphones
and Bluetooth devices are outside this first version's supported setup.

## Repeat the bounded check

Source-selection checks run without audio capture:

```sh
swift test --filter SpeakerModeConfigurationTests
```

The two regression tests cover all combinations of app audio and microphone
availability, then exercise rejected recorder starts with an invalid device ID.
They check the error type and confirm that no recording folder is created.

Build a signed diagnostic without replacing the installed app:

```sh
bash Scripts/make-speaker-check-app.sh
```

Use `--devices` to inspect defaults without capture. Use a fresh destination for
capture; the diagnostic refuses existing audio or reports. For example:

```sh
"dist/TapDeck Speaker Check.app/Contents/MacOS/tapdeck-speaker-check" \
  --directory "$HOME/Music/TapDeck/Speaker Mode Qualification/next-test" \
  --duration 30 --playback /absolute/path/to/clean-speech.aiff
python3 Scripts/analyze-speaker-check.py \
  "$HOME/Music/TapDeck/Speaker Mode Qualification/next-test" --write-report
```

Playback starts after two seconds and stops with capture. Every phase has a
watchdog. Stalls write `failure.json` and exit. The command does not restart the
audio service or change system volume. The analyzer requires ffmpeg and a quiet
speaker-only sample; overlapping local speech invalidates this RMS comparison.

## Native backend history

Apple's AVAudioEngine and direct VoiceProcessingIO implementations both failed
initialization with OSStatus -10875 on this Mac. Custom native render formats
were rejected with -10868, and subsequent device discovery sometimes stalled.
Authenticated audio-service restarts restored discovery. Native attempts and
failure evidence remain in test folders 1 through 6. They contain no successful
acoustic capture. The user selected bundled WebRTC processing after these failures.
Speaker mode never calls the native voice-processing implementation.

Test 7 exercised the unoptimized WebRTC build and saved 7.39 seconds before the
worker overran. Its session JSON reports failure. Test 8 used optimized DSP code
and passed capture and acoustic measurement.
