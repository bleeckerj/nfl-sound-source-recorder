# NFL Sound Recorder

A proof-of-concept macOS project that **taps an audio-first application's or the
whole system's audio, records it to a file, and simultaneously routes it out to an
output device you choose** — the core of what SoundSource does, minus the effects.

It ships three front ends over one shared engine:

- a **menu bar app** (SwiftUI `MenuBarExtra`),
- a **command-line tool**,
- an **MCP server** so LLMs can drive it.

It uses **Core Audio process taps** (`AudioHardwareCreateProcessTap`, macOS
14.4+), so there is **no virtual audio driver / kernel extension** to install.

## Layout

```
Sources/
  SoundRecorderKit/       shared engine + live enumeration of apps & output devices
  nfl-sound-recorder/     command-line front end
  NFLSoundRecorderApp/    menu bar app (SwiftUI MenuBarExtra)
  NFLSoundRecorderMCP/    MCP server (JSON-RPC over stdio, no external deps)
Scripts/
  make-app.sh             bundles the menu bar app into dist/NFL Sound Recorder.app
  make-mcp-app.sh         bundles the MCP server into dist/NFL Sound Recorder MCP.app
  make-cli-app.sh         bundles the CLI (so it can obtain capture permission)
```

## How it works

```
  ┌────────────────────┐  process tap   ┌──────────────────────────────┐
  │  Audio-first app / │ ─────────────► │  Aggregate device            │
  │  all system audio  │                │   • tap        (input)       │
  └────────────────────┘                │   • output dev (output)      │
                                        └──────────────┬───────────────┘
                                                       │  one IOProc callback
                                             ┌─────────┴──────────┐
                                             ▼                    ▼
                                       write to file        copy to output
                                       (Recording.caf)      (plays on device)
```

A **10-band graphic EQ** ([`GraphicEQ`](Sources/SoundRecorderKit/GraphicEQ.swift))
sits in the IO callback between capture and both outputs, so its effect applies to
the recording *and* the routed audio. It's a serial cascade of peaking biquad
filters (RBJ cookbook) at ISO center frequencies 32 Hz–16 kHz.

## Dynamic discovery

Both the apps list and the output-device list are enumerated **live** every time
they're requested, so they stay in sync as apps launch/quit/start playing and as
devices are plugged in or removed:

- **Audio-first applications** come from Core Audio's own process list
  (`kAudioHardwarePropertyProcessObjectList`), so the list reflects apps that
  actually participate in audio, each tagged with whether it is *currently
  playing*. See [`AudioProcesses`](Sources/SoundRecorderKit/AudioProcesses.swift).
- **Output devices** come from the HAL device list, filtered to those with
  output channels, with the current default flagged. See
  [`AudioSystem`](Sources/SoundRecorderKit/CoreAudioHelpers.swift).

## MCP server (LLM integration)

The server speaks MCP over stdio and exposes five tools:

| Tool | Purpose |
|------|---------|
| `list_applications` | Live list of audio-first apps: `name`, `bundleId`, `pid`, `isPlaying`. |
| `list_output_devices` | Live list of outputs: `name`, `uid`, `channels`, `isDefault`. |
| `start_recording` | Start capture + route. Args: `source` (`"system"` or a bundle id), optional `pid`, `output_uid`, `mute`, `file_path`. |
| `set_equalizer` | Enable/disable the 10-band EQ and set per-band gains in dB (bands 32 Hz–16 kHz). Applies live. |
| `stop_recording` | Stop and return the saved file path + duration. |
| `recording_status` | Whether a recording is in progress, with source/device/file/elapsed + EQ state. |

Build it. Bundling as a `.app` (recommended) gives the server a stable identity
and the `NSAudioCaptureUsageDescription` the OS needs for the audio-capture prompt:

```sh
./Scripts/make-mcp-app.sh
# inner binary: dist/NFL Sound Recorder MCP.app/Contents/MacOS/nfl-sound-recorder-mcp
```

(Or `swift build -c release` for the bare binary at `.build/release/nfl-sound-recorder-mcp`.)

Register it with an MCP client. For Claude Desktop, add to
`~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "nfl-sound-recorder": {
      "command": "/Users/julian/Code/nfl-sound-source-recorder/dist/NFL Sound Recorder MCP.app/Contents/MacOS/nfl-sound-recorder-mcp"
    }
  }
}
```

A typical LLM flow: call `list_applications` and `list_output_devices` to see
what's available, then `start_recording` with a chosen `source` + `output_uid`,
then `stop_recording`.

> **Permission:** `start_recording` taps audio, which is TCC-gated (its own TCC category, shown under
> **Screen & System Audio Recording**). The permission is attributed to whatever process launches the
> server (e.g. the MCP client). Grant it in **System Settings ▸ Privacy &
> Security ▸ Screen & System Audio Recording**, or the tap captures silence. The listing tools need no
> permission.

## Menu bar app

```sh
./Scripts/make-app.sh
open "dist/NFL Sound Recorder.app"
```

A waveform icon appears in the menu bar. Pick a **Record** source (an audio-first
app or all system audio), a **Route to** device, optionally **Reroute (mute
original output)**, dial in the **10-band Equalizer** (toggle + per-band sliders,
adjustable live while recording), then **Record**. Files land in
`~/Music/NFL Sound Recorder/`. It's a menu-bar-only agent (`LSUIElement`) — no
Dock icon.

On first Record, macOS prompts for audio-capture permission (under **Screen & System Audio Recording**);
grant it and Record again.

## Command line

```sh
swift build

# List audio-first apps and output devices:
.build/debug/nfl-sound-recorder --list

# Record an audio-first application by bundle id (from --list), keep it playing:
.build/debug/nfl-sound-recorder --app <bundleID> --file ~/Desktop/capture.caf

# Record and REROUTE all system audio to a specific device:
.build/debug/nfl-sound-recorder --system --mute --out "BuiltInSpeakerDevice"

# Record with the 10-band EQ (per-band gains in dB, 32 Hz → 16 kHz):
.build/debug/nfl-sound-recorder --system --eq 6,4,0,0,0,0,0,3,5,5
```

**Important — silent recordings:** a bare SwiftPM binary has no `Info.plist`, so
macOS can't show the audio-capture prompt, and process taps then return **silence**
(the file records, but it's all zeros). For real capture, run the *bundled* CLI:

```sh
./Scripts/make-cli-app.sh
"dist/NFL Sound Recorder CLI.app/Contents/MacOS/nfl-sound-recorder" --system --file ~/rec.caf
```

While recording, the CLI prints the capture format and a **live level meter**. If
it shows `−∞ dBFS` for a few seconds it warns you and lists the likely causes
(missing permission, source not playing, or the source's audio being redirected by
another app such as SoundSource — try disabling that redirect and retry).

**One-command check:** `./Scripts/test-recording.sh` builds the bundled CLI, plays
a known sound, captures 6 seconds of system audio, and reports whether any signal
was captured (writes to `/tmp/nfl-test.caf`). Use `--duration <sec>` for your own
hands-free timed captures.

## Known limitations (it's a POC)

- **Format matching:** the routing `memcpy` assumes the tap and output device
  share channel count / sample rate (true for the common stereo case). A shipping
  app would run frames through an `AVAudioConverter` when they differ.
- **Real-time safety:** writing to `AVAudioFile` and taking the EQ's
  `os_unfair_lock` inside the IOProc can allocate/block; production code would push
  frames to a lock-free ring buffer, write on a separate thread, and hand off EQ
  coefficients lock-free.
- **Single recording at a time**, single output.

## Security & privacy

- **No network, no shell-out, no secrets.** The tools only open Core Audio and
  write local audio files; there are no credentials in the codebase.
- **MCP write confinement.** `start_recording`'s `file_path` is reduced to a
  sanitized filename inside `~/Music/NFL Sound Recorder/`, so an LLM can't use it
  for path traversal (e.g. overwriting dotfiles). See `RecordingFiles`.
- **MCP input** is parsed with `JSONSerialization` and dispatched by a fixed method
  allowlist; unknown methods return a JSON-RPC error.
- **Capture is TCC-gated.** Recording another app's audio always requires the OS
  audio-capture permission, attributed to the (bundled) binary that runs it.
- **Privacy note:** this captures other apps' audio — an LLM driving the MCP server
  could start a recording; `recording_status` exposes what's active so a client can
  surface it.

## Where to go next

- **More effects:** the EQ is a peaking-biquad cascade; the same IO stage could
  host compression, reverb, or `AVAudioUnit` plugins.
- **Arbitrary per-app routing** system-wide: needs a virtual audio driver
  (`AudioServerPlugIn` / DriverKit, cf. **BlackHole**).

## Reference material

- Apple sample: *"Capturing system audio with Core Audio taps."*
- **AudioCap** by Guilherme Rambo — open-source process-tap recorder.
- **BlackHole** — open-source virtual audio driver, for the routing layer.
