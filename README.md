<div align="center">

# TapDeck

**Tap any app's — or all of your Mac's — audio, mix in your microphone, record it to a file, and route it live to any output device.**
A skeuomorphic cassette deck for macOS, driven by Core Audio process taps. No virtual audio driver, no kernel extension.

<img src="https://imagedelivery.net/gaLGizR3kCgx5yRLtiRIOw/9ca8be40-cf8d-4d31-37dd-90513e57a900/public" width="440" alt="TapDeck's cassette tape deck with transport keys and a live 10-band LED spectrum meter" />

![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20MenuBarExtra-blue)
![No kext](https://img.shields.io/badge/driver-none%20(process%20taps)-brightgreen)

</div>

TapDeck is the flagship menu-bar app of a proof-of-concept that does **the core of what SoundSource does, minus the effects**: it captures an audio-first application's (or the whole system's) audio, writes it to a file, and simultaneously copies it to an output device you choose — all through one Core Audio IO callback.

It ships **three front ends over one shared engine**:

- a **menu bar app** (SwiftUI `MenuBarExtra`) — the tape deck you see above,
- a **command-line tool**,
- an **MCP server** so LLMs can drive it.

Because it uses **Core Audio process taps** (`AudioHardwareCreateProcessTap`, macOS 14.4+), there is **no virtual audio driver / kernel extension** to install.

## The app

Pick a **Record** source, a **Route to** device, dial in the **10-band graphic EQ**, and hit **REC**. The tape reels spin, the meters come alive, and the same signal is written to disk and played out your chosen device. Watch levels as a **10-band LED spectrum**, or flip to the green-phosphor **Lissajous scope** to see the stereo field.

<table>
<tr>
<td align="center" width="33%">
<img src="https://imagedelivery.net/gaLGizR3kCgx5yRLtiRIOw/aa1ca09e-caf2-4e30-94ef-8c9f20630600/public" alt="TapDeck idle, at rest with dim meters" /><br/>
<b>Idle</b><br/><sub>At rest — <code>STOP 00:00</code>, dim meters, ready to record.</sub>
</td>
<td align="center" width="33%">
<img src="https://imagedelivery.net/gaLGizR3kCgx5yRLtiRIOw/07af01be-cb76-4d58-5c2c-e1bfbcffd100/public" alt="TapDeck recording, full panel with lit spectrum meter" /><br/>
<b>Recording · Bars</b><br/><sub>Source + routing pickers, live 10-band EQ, record level, lit spectrum.</sub>
</td>
<td align="center" width="33%">
<img src="https://imagedelivery.net/gaLGizR3kCgx5yRLtiRIOw/eb132225-4b9e-479e-2cf6-1e9970469700/public" alt="TapDeck in Scope mode showing a Lissajous vectorscope" /><br/>
<b>Recording · Scope</b><br/><sub>Green-phosphor Lissajous vectorscope of the stereo field.</sub>
</td>
</tr>
</table>

```sh
./Scripts/make-app.sh
open "dist/TapDeck.app"
```

A waveform icon appears in the menu bar. Pick a **Record** source (an audio-first app, all system audio, or **None — microphone only**), optionally add a **Microphone** to mix in, choose a **Route to** device, optionally **Reroute (mute original output)**, dial in the **10-band Equalizer** (toggle + per-band sliders, adjustable live while recording), then **Record**. Files land in `~/Music/TapDeck/`. It's a menu-bar-only agent (`LSUIElement`) — no Dock icon.

**Microphone & mixing.** Choose a **Microphone** to record it alongside the tapped audio — system audio plus your commentary in one file, the classic screencast/podcast capture. When both a tap and the mic are active, **Source Level** and **Mic Level** sliders appear so you can balance the two feeds (there's also a master **Record Level**). Set the Record source to **None — microphone only** to record just the mic.

On first Record, macOS prompts for the permission each source needs: **audio-capture** for a tap (under **Screen & System Audio Recording**) and **Microphone** for the mic. Grant them and Record again.

> ⚠️ **Feedback:** if you mix the mic *and* route to speakers, the mic hears the speakers and howls. Use headphones, or route to **None (record only)**. TapDeck shows a hint but doesn't stop you.

## Layout

```
Sources/
  SoundRecorderKit/       shared engine + live enumeration of apps & output devices
  nfl-sound-recorder/     command-line front end
  NFLSoundRecorderApp/    menu bar app (SwiftUI MenuBarExtra) — "TapDeck"
  NFLSoundRecorderMCP/    MCP server (JSON-RPC over stdio, no external deps)
Scripts/
  make-app.sh             bundles the menu bar app into dist/TapDeck.app
  make-mcp-app.sh         bundles the MCP server into dist/TapDeck MCP.app
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

A **10-band graphic EQ** ([`GraphicEQ`](Sources/SoundRecorderKit/GraphicEQ.swift)) sits in the IO callback between capture and both outputs, so its effect applies to the recording *and* the routed audio. It's a serial cascade of peaking biquad filters (RBJ cookbook) at ISO center frequencies 32 Hz–16 kHz. The meters and scope are driven from the same post-EQ stream.

## Dynamic discovery

Both the apps list and the output-device list are enumerated **live** every time they're requested, so they stay in sync as apps launch/quit/start playing and as devices are plugged in or removed:

- **Audio-first applications** come from Core Audio's own process list (`kAudioHardwarePropertyProcessObjectList`), so the list reflects apps that actually participate in audio, each tagged with whether it is *currently playing*. See [`AudioProcesses`](Sources/SoundRecorderKit/AudioProcesses.swift).
- **Output devices** come from the HAL device list, filtered to those with output channels, with the current default flagged. See [`AudioSystem`](Sources/SoundRecorderKit/CoreAudioHelpers.swift).

## MCP server (LLM integration)

The server speaks MCP over stdio and exposes five tools:

| Tool | Purpose |
|------|---------|
| `list_applications` | Live list of audio-first apps: `name`, `bundleId`, `pid`, `isPlaying`. |
| `list_output_devices` | Live list of outputs: `name`, `uid`, `channels`, `isDefault`. |
| `list_input_devices` | Live list of microphones/inputs: `name`, `uid`, `channels`, `isDefault`. |
| `start_recording` | Start capture + route. Args: `source` (`"system"`, a bundle id, or `"microphone"` for mic-only), optional `pid`, `microphone` (`"default"` or an input uid, to mix the mic in), `source_level_db`/`mic_level_db` (balance the feeds), `output_uid` (`"none"` to record only), `mute`, `file_path`. |
| `set_equalizer` | Enable/disable the 10-band EQ and set per-band gains in dB (bands 32 Hz–16 kHz). Applies live. |
| `stop_recording` | Stop and return the saved file path + duration. |
| `recording_status` | Whether a recording is in progress, with source/device/file/elapsed + EQ state. |

Build it. Bundling as a `.app` (recommended) gives the server a stable identity and the `NSAudioCaptureUsageDescription` the OS needs for the audio-capture prompt:

```sh
./Scripts/make-mcp-app.sh
# inner binary: dist/TapDeck MCP.app/Contents/MacOS/nfl-sound-recorder-mcp
```

(Or `swift build -c release` for the bare binary at `.build/release/nfl-sound-recorder-mcp`.)

Register it with an MCP client. For Claude Desktop, add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "tapdeck": {
      "command": "/Users/julian/Code/nfl-sound-source-recorder/dist/TapDeck MCP.app/Contents/MacOS/nfl-sound-recorder-mcp"
    }
  }
}
```

A typical LLM flow: call `list_applications` and `list_output_devices` to see what's available, then `start_recording` with a chosen `source` + `output_uid`, then `stop_recording`. To capture commentary too, add `microphone: "default"` (and balance with `source_level_db`/`mic_level_db`); to record just the mic, use `source: "microphone"`.

> **Permission:** `start_recording` taps audio, which is TCC-gated (its own TCC category, shown under **Screen & System Audio Recording**). Adding a `microphone` also needs **Microphone** consent. Both are attributed to whatever process launches the server (e.g. the MCP client). Grant them in **System Settings ▸ Privacy & Security** (under **Screen & System Audio Recording** and **Microphone**), or that feed captures silence. The listing tools need no permission.

## Command line

```sh
swift build

# List audio-first apps and input/output devices:
.build/debug/nfl-sound-recorder --list

# Record an audio-first application by bundle id (from --list), keep it playing:
.build/debug/nfl-sound-recorder --app <bundleID> --file ~/Desktop/capture.caf

# Record and REROUTE all system audio to a specific device:
.build/debug/nfl-sound-recorder --system --mute --out "BuiltInSpeakerDevice"

# Record with the 10-band EQ (per-band gains in dB, 32 Hz → 16 kHz):
.build/debug/nfl-sound-recorder --system --eq 6,4,0,0,0,0,0,3,5,5

# Record the microphone ALONE (no tap):
.build/debug/nfl-sound-recorder --mic-default --no-route --file ~/mic.caf

# MIX system audio + mic into one file, mic 6 dB down to balance it:
.build/debug/nfl-sound-recorder --system --mic-default --no-route \
    --source-level 0 --mic-level -6 --file ~/screencast.caf
```

**Important — silent recordings:** a bare SwiftPM binary has no `Info.plist`, so macOS can't show the audio-capture prompt, and process taps then return **silence** (the file records, but it's all zeros). For real capture, run the *bundled* CLI:

```sh
./Scripts/make-cli-app.sh
"dist/TapDeck CLI.app/Contents/MacOS/nfl-sound-recorder" --system --file ~/rec.caf
```

While recording, the CLI prints the capture format and a **live level meter**. If it shows `−∞ dBFS` for a few seconds it warns you and lists the likely causes (missing permission, source not playing, or the source's audio being redirected by another app such as SoundSource — try disabling that redirect and retry).

**One-command check:** `./Scripts/test-recording.sh` builds the bundled CLI, plays a known sound, captures 6 seconds of system audio, and reports whether any signal was captured (writes to `/tmp/nfl-test.caf`). Use `--duration <sec>` for your own hands-free timed captures.

## Distribution (signing & notarization)

To hand the menu-bar app to other people, it needs a Developer ID signature, the
Hardened Runtime, and Apple notarization — otherwise Gatekeeper blocks it on their Macs.

`make-app.sh` handles the signing automatically: if a **Developer ID Application**
certificate is in your keychain it signs with it under the Hardened Runtime, applying
[`Scripts/TapDeck.entitlements`](Scripts/TapDeck.entitlements) (just the microphone —
system-audio recording is runtime TCC consent, not an entitlement). Without that cert it
falls back to an ad-hoc signature so a fresh clone still builds. Override with
`SIGN_IDENTITY="Developer ID Application: …"`.

For a **notarized, stapled `.dmg`** ready to download, run [`Scripts/release-app.sh`](Scripts/release-app.sh):

```sh
# one-time: store notarization credentials under a profile name
xcrun notarytool store-credentials "tapdeck" \
    --apple-id "you@example.com" --team-id 9DCTLJ9BY7 --password "app-specific-password"

# build → notarize the app → staple → build DMG → notarize + staple the DMG → verify
NOTARY_PROFILE="tapdeck" ./Scripts/release-app.sh
```

It staples both the app and the DMG (so first launch works offline) and verifies with
`spctl`/`stapler`. The output `dist/TapDeck-<version>.dmg` passes Gatekeeper cleanly.
A stable Developer ID signature also fixes the ad-hoc build's re-prompt-every-rebuild
behaviour — the TCC grants stick across rebuilds.

> Requires the full-Xcode toolchain to be license-accepted (`sudo xcodebuild -license accept`),
> since notarization uses `notarytool` from Xcode.

## Known limitations (it's a POC)

- **Format matching:** the routing `memcpy` assumes the tap and output device share channel count / sample rate (true for the common stereo case). A shipping app would run frames through an `AVAudioConverter` when they differ.
- **Real-time safety:** writing to `AVAudioFile` and taking the EQ's `os_unfair_lock` inside the IOProc can allocate/block; production code would push frames to a lock-free ring buffer, write on a separate thread, and hand off EQ coefficients lock-free.
- **Single recording at a time**, single output.

## Security & privacy

- **No network, no shell-out, no secrets.** The tools only open Core Audio and write local audio files; there are no credentials in the codebase.
- **MCP write confinement.** `start_recording`'s `file_path` is reduced to a sanitized filename inside `~/Music/TapDeck/`, so an LLM can't use it for path traversal (e.g. overwriting dotfiles). See `RecordingFiles`.
- **MCP input** is parsed with `JSONSerialization` and dispatched by a fixed method allowlist; unknown methods return a JSON-RPC error.
- **Capture is TCC-gated.** Recording another app's audio always requires the OS audio-capture permission, attributed to the (bundled) binary that runs it.
- **Privacy note:** this captures other apps' audio — an LLM driving the MCP server could start a recording; `recording_status` exposes what's active so a client can surface it.

## Where to go next

- **More effects:** the EQ is a peaking-biquad cascade; the same IO stage could host compression, reverb, or `AVAudioUnit` plugins.
- **Arbitrary per-app routing** system-wide: needs a virtual audio driver (`AudioServerPlugIn` / DriverKit, cf. **BlackHole**).

## Reference material

- Apple sample: *"Capturing system audio with Core Audio taps."*
- **AudioCap** by Guilherme Rambo — open-source process-tap recorder.
- **BlackHole** — open-source virtual audio driver, for the routing layer.

---

<div align="center"><sub>A Near Future Laboratory Quality of Life Contrivance</sub></div>
