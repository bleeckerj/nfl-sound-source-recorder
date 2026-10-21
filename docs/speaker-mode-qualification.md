# Speaker recording qualification

The native higher-quality speaker mode failed hardware qualification. It is not
available in the TapDeck interface, normal CLI, or MCP interface yet.

The first milestone adds native VoiceProcessingIO capture and a separate,
bounded diagnostic that saves raw and processed microphone audio. The existing
recording paths and user interface are unchanged.

## Local evidence, October 20, 2026

- The MacBook Air microphone and speakers were the default devices, both at 48 kHz.
- The first AVAudioEngine-based test failed during native output-unit initialization
  with OSStatus -10875. Audio logs also reported aggregate-device input-channel
  layout mismatches. No speech playback or microphone capture completed.
- The replacement diagnostic uses VoiceProcessingIO directly with explicit device
  selection, disabled automatic gain control, minimum fixed ducking, and silent
  speaker output. It has not passed hardware qualification.
- A subsequent run stalled in `AudioObjectGetPropertyData` while querying the default
  input device, before reaching the replacement native implementation. A stack
  sample confirmed the blocked Core Audio initialization. Only that diagnostic
  process was terminated. A subsequent bounded system audio inventory was empty.
- Two authenticated audio-service restarts restored device discovery. Attempts 3
  and 4 rejected custom silent-output formats with OSStatus -10868; attempt 5
  timed out during device discovery. The corrected implementation leaves the
  render bus in its native format and only tears down initialized/running stages.
- Attempt 6 reached direct VoiceProcessingIO initialization after a successful
  restart and failed with OSStatus -10875. No capture or playback began. Both
  AVAudioEngine and direct VoiceProcessingIO have now failed the initialization
  gate on this Mac. Device discovery stalled again afterward.
- A final authenticated cleanup restart restored device discovery. The bounded
  device-only diagnostic resolved the MacBook Air microphone and speakers and
  exited successfully. No further native capture attempts followed that check.
- No acoustic suppression measurement, overlapping-speech assessment, Zoom
  coexistence test, or long-duration test has passed. The 20 dB reduction target
  remains unverified.

Test files are kept under
`/Users/julian/Music/TapDeck/Speaker Mode Qualification/`.
The CAF files from failed initialization contain no captured audio. They are
failure evidence. Each test has a separate folder; failed runs are never reused.

## Build and run

Build the signed diagnostic without replacing the installed TapDeck app:

```sh
bash Scripts/make-speaker-check-app.sh
```

Inspect devices without starting capture:

```sh
"dist/TapDeck Speaker Check.app/Contents/MacOS/tapdeck-speaker-check" --devices
```

Use a fresh destination for every capture. For example:

```sh
"dist/TapDeck Speaker Check.app/Contents/MacOS/tapdeck-speaker-check" \
  --directory "$HOME/Music/TapDeck/Speaker Mode Qualification/next-test" \
  --duration 30 --playback /absolute/path/to/clean-speech.aiff
```

The diagnostic requires microphone permission and built-in default input/output.
Playback starts after two seconds and is stopped when capture ends. Each phase
has a watchdog; a stalled operation produces `failure.json` and exits. The command
does not restart the system audio service or change system speaker volume.

`qualification.json` reports capture completion, frame counts, dropped frames,
device identities, and reported native latency. Capture completion alone does not
establish that echo cancellation is effective. Compare the two source files using
a known speech sample and listening tests before enabling a speaker recording UI.

## Verification completed

- All seven Swift tests pass, including two qualification destination-preservation tests.
- The Swift test build compiles the app, normal CLI, MCP, and diagnostic targets.
- The diagnostic bundle builds and passes strict code-signature verification.
- Help and invalid-duration checks exit without initializing audio or starting capture.
- The device-discovery watchdog was exercised against the stalled audio query; it
  exited with status 3 and a clear timeout after ten seconds.
- The test folders contain `failure.json`; `2026-10-20-test-2` also contains
  `blocked-thread.txt` from the stalled device query.

## Remaining implementation

- After an audio backend passes qualification, implement timestamp-aligned
  app/raw/clean capture, the finished mix and retained source tracks, explicit
  speaker-mode controls in the app/CLI/MCP, interruption handling, and the
  acceptance tests in the approved plan.
- A processing failure must finalize the mix and source files and display its
  reason in the app, CLI, or MCP result. Raw app-plus-mic capture cannot replace
  echo cancellation without an explicit change of recording mode.
