import Foundation
import AppKit
import AVFoundation
import SoundRecorderKit

struct CLIError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - Tiny arg parsing

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func printUsage() {
    print("""
    nfl-sound-recorder — tap app/system audio, record to a file, route to a device.

    USAGE:
      nfl-sound-recorder --list
      nfl-sound-recorder [--app <bundleID> | --pid <pid> | --system]
                         [--mic <deviceUID> | --mic-default]
                         [--out <deviceUID> | --no-route] [--file <path>] [--mute]

    OPTIONS:
      --list            List running apps and available input/output devices, then exit.
      --app <bundleID>  Capture an audio-first application by bundle id (see --list).
      --pid <pid>       Capture a running process by pid.
      --system          Capture all system audio.
      --mic <deviceUID> Also capture this microphone/input device and MIX it into the
                        recording. Omit the tap flags (--app/--pid/--system) to record
                        the mic ALONE.
      --mic-default     Like --mic, using the system default input device.
      --mic-level <dB>  Microphone feed level in dB (0 = unity, default 0). For balance.
      --source-level <dB> Tap/system feed level in dB (0 = unity, default 0). For balance.
      --out <deviceUID> Output device UID to route to (default: current default output).
      --no-route        Record only — a tap-only aggregate, no output device, nothing
                        plays out (null sink). Overrides --out.
      --file <path>     Output file path (default: ./recording-<timestamp>.<ext>).
      --format <fmt>    Recording format: caf, wav, aiff, aac, alac, flac (default: aac).
                        aac is lossy (~1 MB/min, the small default); caf/wav/aiff/alac/flac
                        are lossless (caf ~90 MB/min). If omitted but --file has a known
                        extension, the format is inferred. macOS has no MP3 encoder — use aac.
      --mute            Silence the app's normal output so only the routed copy is heard.
      --eq <g0,..,g9>   Enable the 10-band EQ with per-band gains in dB, low→high
                        (32,64,125,250,500,1k,2k,4k,8k,16k Hz). e.g. --eq 6,4,0,0,0,0,0,3,5,5
      --duration <sec>  Record for N seconds then stop automatically (for testing).
      --drift           Enable tap drift compensation (resampling). Off by default;
                        enabling it can add a brief level ramp at the start.
      --warmup <sec>    Skip Core Audio's device-start volume ramp by holding off file
                        writing this long (default 0.6). Use 0 to keep the raw ramp.

    Press Ctrl-C to stop recording.
    """)
}

// MARK: - Listing

func listEverything() {
    let catalog = AudioProcesses.catalog()
    print("Applications (helpers folded in — --app taps the whole group):")
    for app in catalog.apps {
        let state = app.isPlaying ? "playing" : "idle"
        let pids = app.tapPIDs.map(String.init).joined(separator: ",")
        print("  \(app.name)  [\(app.bundleID)]  \(state)  pids: \(pids)")
    }
    print("\nSystem audio processes (no owning app — target with --pid):")
    for daemon in catalog.daemons {
        let state = daemon.isPlaying ? "playing" : "idle"
        print("  pid \(String(daemon.pid).padding(toLength: 6, withPad: " ", startingAt: 0))  \(daemon.name)  [\(daemon.bundleID)]  \(state)")
    }

    print("\nOutput devices:")
    do {
        let defaultID = try AudioSystem.defaultOutputDevice()
        for dev in try AudioSystem.outputDevices() {
            let marker = dev.id == defaultID ? " (default)" : ""
            print("  \(dev.name) — \(dev.outputChannels)ch\(marker)\n      UID: \(dev.uid)")
        }
    } catch {
        print("  Error enumerating devices: \(error)")
    }

    print("\nInput devices (microphones):")
    do {
        let defaultID = try AudioSystem.defaultInputDevice()
        for dev in try AudioSystem.inputDevices() {
            let marker = dev.id == defaultID ? " (default)" : ""
            print("  \(dev.name) — \(dev.inputChannels)ch\(marker)\n      UID: \(dev.uid)")
        }
    } catch {
        print("  Error enumerating input devices: \(error)")
    }
}

// MARK: - Resolve target + device

func resolveTarget() -> ProcessTapRecorder.Target? {
    if hasFlag("--system") { return .systemWide }
    if let pidStr = argValue("--pid"), let pid = pid_t(pidStr) { return .pid(pid) }
    if let bundle = argValue("--app") {
        if let app = AudioProcesses.app(matching: bundle) {
            return .pids(app.tapPIDs)
        }
        FileHandle.standardError.write("No running application with bundle id \(bundle). Check --list.\n".data(using: .utf8)!)
        return nil
    }
    return nil
}

/// Resolve the microphone/input device from --mic <uid> or --mic-default, or nil if the
/// user asked for no mic. Throws if a requested device can't be found.
func resolveMicDevice() throws -> AudioDeviceInfo? {
    let devices = try AudioSystem.inputDevices()
    if let wanted = argValue("--mic") {
        if let match = devices.first(where: { $0.uid == wanted }) { return match }
        throw CLIError(message: "No input device with UID \(wanted). Use --list to see inputs.")
    }
    if hasFlag("--mic-default") {
        let defaultID = try AudioSystem.defaultInputDevice()
        if let match = devices.first(where: { $0.id == defaultID }) ?? devices.first { return match }
        throw CLIError(message: "No input devices found.")
    }
    return nil
}

func resolveOutputDevice() throws -> AudioDeviceInfo? {
    if hasFlag("--no-route") { return nil }   // record-only: tap-only aggregate
    let devices = try AudioSystem.outputDevices()
    if let wanted = argValue("--out") {
        if let match = devices.first(where: { $0.uid == wanted }) { return match }
        throw CLIError(message: "No output device with UID \(wanted)")
    }
    let defaultID = try AudioSystem.defaultOutputDevice()
    if let match = devices.first(where: { $0.id == defaultID }) { return match }
    guard let first = devices.first else { throw CLIError(message: "No output devices found") }
    return first
}

// MARK: - EQ self-test (offline DSP sanity check)

func runEQSelfTest() {
    let sampleRate = 48_000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true)!
    let frames = AVAudioFrameCount(sampleRate) // 1 second

    func sine(_ freq: Double) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        let stride = buffer.stride
        for f in 0..<Int(frames) {
            let s = Float(sin(2 * Double.pi * freq * Double(f) / sampleRate))
            data[f * stride] = s
            data[f * stride + 1] = s
        }
        return buffer
    }

    // RMS over the second half, avoiding the filter's startup transient.
    func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        let data = buffer.floatChannelData![0]
        let stride = buffer.stride
        let n = Int(buffer.frameLength)
        var sum = 0.0
        for f in (n / 2)..<n { let v = Double(data[f * stride]); sum += v * v }
        return (sum / Double(n / 2)).squareRoot()
    }

    func ratio(freq: Double, boostBand: Int, dB: Double) -> Double {
        let buffer = sine(freq)
        let before = rms(buffer)
        let eq = GraphicEQ(sampleRate: sampleRate, channels: 2)
        eq.setGain(band: boostBand, dB: dB)
        eq.setEnabled(true)
        eq.process(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        return rms(buffer) / before
    }

    // Boost the 4 kHz band (+12 dB). Expect ~4x at 4 kHz, ~1x far away at 100 Hz.
    let atCenter = ratio(freq: 4000, boostBand: 7, dB: 12)
    let farAway = ratio(freq: 100, boostBand: 7, dB: 12)
    let expected = pow(10.0, 12.0 / 20.0) // peaking filter peak gain
    print(String(format: "EQ self-test (+12 dB @ 4 kHz):"))
    print(String(format: "  4 kHz sine gain:  %.2fx  (expected ~%.2fx)", atCenter, expected))
    print(String(format: "  100 Hz sine gain: %.2fx  (expected ~1.00x)", farAway))
    let pass = abs(atCenter - expected) < 0.5 && abs(farAway - 1.0) < 0.1
    print(pass ? "  ✓ PASS" : "  ✗ FAIL")
}

func runSpectrumSelfTest() {
    let meter = SpectrumMeter()
    meter.configure(sampleRate: 48_000)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
    let frames = 2048
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
    buf.frameLength = AVAudioFrameCount(frames)
    let abl = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
    let data = abl[0].mData!.assumingMemoryBound(to: Float.self)
    let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    // (frequency, amplitude, dBFS label) — sweep levels to mimic real, quieter audio.
    let cases: [(Double, Double, String)] = [
        // 1007.8125 Hz is bin 43 exactly (48 kHz / 2048), so it carries no scalloping
        // loss — that's the tone the meter's calibration is trimmed against.
        (1007.8125, 0.5, "-6 dBFS (on-bin)"),
        (1000, 1.0, "0 dBFS"), (1000, 0.1, "-20 dBFS"), (1000, 0.01, "-40 dBFS"),
        (100, 0.3, "-10 dBFS"), (8000, 0.3, "-10 dBFS"),
    ]
    for (freq, amp, label) in cases {
        var phase = 0.0
        let inc = 2 * Double.pi * freq / 48_000
        for i in 0..<frames {
            let s = Float(sin(phase) * amp)
            data[i * 2] = s; data[i * 2 + 1] = s
            phase += inc
        }
        for _ in 0..<4 { meter.ingest(abl, frames: frames) } // let smoothing settle
        let levels = meter.levels()
        meter.reset()
        // Invert the meter's own mapping so the read-out is in dBFS: the band carrying
        // the tone should land within a dB or two of the tone's own level, which is what
        // makes the LEDs usable as record-level feedback rather than a light show.
        let span = SpectrumMeter.ceilingDB - SpectrumMeter.floorDB
        print("\n\(Int(freq)) Hz @ \(label):")
        for (i, l) in levels.enumerated() where l > 0.01 {
            let bar = String(repeating: "█", count: Int(l * 30))
            let db = SpectrumMeter.floorDB + l * span
            print("  \(labels[i].padding(toLength: 4, withPad: " ", startingAt: 0)) "
                  + "\(String(format: "%.3f", l)) \(String(format: "%6.1f dBFS", db)) \(bar)")
        }
    }

    // Silence must read as *exactly* zero on every band, or the bottom LED of each
    // column stays lit for the life of the recording and the meter always looks busy.
    for i in 0..<frames { data[i * 2] = 0; data[i * 2 + 1] = 0 }
    for _ in 0..<200 { meter.ingest(abl, frames: frames) }
    let quiet = meter.levels()
    let allZero = quiet.allSatisfy { $0 == 0 }
    print("\nSilence decays to zero: \(allZero ? "✓ PASS" : "✗ FAIL — \(quiet)")")
}

// MARK: - Diagnostics helpers


/// Mutable meter state, boxed so the (Sendable) timer closure can mutate it.
final class MeterState: @unchecked Sendable {
    var silentSeconds = 0.0
    var warned = false
}

func meterBar(_ peak: Float, width: Int = 24) -> String {
    // Map −60…0 dBFS onto the bar.
    let db = LevelMeter.dBFS(peak)
    let fraction = db.isFinite ? max(0, min(1, (db + 60) / 60)) : 0
    let filled = Int((Double(width) * fraction).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

// MARK: - Main

if hasFlag("--help") || hasFlag("-h") || CommandLine.arguments.count == 1 {
    printUsage()
    exit(0)
}

if hasFlag("--list") {
    listEverything()
    exit(0)
}

if hasFlag("--selftest-eq") {
    runEQSelfTest()
    exit(0)
}

if hasFlag("--check-permission") {
    print("System Audio Recording (kTCCServiceAudioCapture): \(AudioCapturePermission.status().rawValue)")
    print("Microphone (kTCCServiceMicrophone):               \(MicrophonePermission.status().rawValue)")
    exit(0)
}

if hasFlag("--selftest-spectrum") {
    runSpectrumSelfTest()
    exit(0)
}

// The tap is now optional: with a --mic flag you can record the mic alone. Validation
// (at least one source) happens once the mic device is resolved, inside the do-block.
let tapTarget = resolveTarget()

func targetLabel(_ t: ProcessTapRecorder.Target) -> String {
    switch t {
    case .pid(let pid):   return "pid \(pid)"
    case .pids(let pids): return "pids \(pids.map(String.init).joined(separator: ","))"
    case .systemWide:     return "system audio"
    }
}

// Resolve format: explicit --format wins; otherwise infer from --file's extension;
// otherwise default to AAC (small files). An unknown --format value is a hard error.
let format: RecordingFormat = {
    if let raw = argValue("--format") {
        guard let f = RecordingFormat(rawValue: raw.lowercased()) else {
            let choices = RecordingFormat.allCases.map(\.rawValue).joined(separator: ", ")
            FileHandle.standardError.write("Unknown --format \"\(raw)\". Choose one of: \(choices)\n".data(using: .utf8)!)
            exit(1)
        }
        return f
    }
    if let path = argValue("--file"),
       let inferred = RecordingFormat(fileExtension: (path as NSString).pathExtension) {
        return inferred
    }
    return .aac
}()

let fileURL: URL = {
    if let path = argValue("--file") {
        let url = URL(fileURLWithPath: path)
        // Make the extension agree with the chosen codec, or AVAudioFile's inferred
        // container won't match what we're encoding (e.g. .wav holding AAC).
        if url.pathExtension.lowercased() != format.fileExtension {
            let fixed = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
            FileHandle.standardError.write("Note: writing \(format.rawValue) → \(fixed.lastPathComponent)\n".data(using: .utf8)!)
            return fixed
        }
        return url
    }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("recording-\(stamp).\(format.fileExtension)")
}()

do {
    let device = try resolveOutputDevice()
    let mic = try resolveMicDevice()

    // Build the capture source; require at least one of tap / mic.
    let source: ProcessTapRecorder.Source
    let sourceLabel: String
    switch (tapTarget, mic) {
    case let (.some(t), .some(m)): source = .mix(tap: t, mic: m); sourceLabel = "\(targetLabel(t)) + mic (\(m.name))"
    case let (.some(t), .none):    source = .tap(t); sourceLabel = targetLabel(t)
    case let (.none, .some(m)):    source = .microphone(m); sourceLabel = "mic (\(m.name))"
    case (.none, .none):
        FileHandle.standardError.write("Specify a source: a tap (--app/--pid/--system) and/or a mic (--mic/--mic-default). Use --list to explore.\n".data(using: .utf8)!)
        exit(1)
    }
    let hasTap = tapTarget != nil
    let hasMic = mic != nil

    let warmup = argValue("--warmup").flatMap(Double.init) ?? 0.6
    let recorder = ProcessTapRecorder(source: source, outputDevice: device, fileURL: fileURL,
                                      format: format, mute: hasFlag("--mute"),
                                      driftCompensation: hasFlag("--drift"), warmupSeconds: warmup)
    if let lvl = argValue("--source-level").flatMap(Double.init) { recorder.setSourceGain(dB: lvl) }
    if let lvl = argValue("--mic-level").flatMap(Double.init) { recorder.setMicGain(dB: lvl) }

    if let eqArg = argValue("--eq") {
        let gains = eqArg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        recorder.equalizer.setGains(gains)
        recorder.equalizer.setEnabled(true)
        print("EQ enabled — gains (dB): \(gains)")
    }

    // Ensure the consents we actually need before starting: System Audio Recording
    // (kTCCServiceAudioCapture) for a tap, Microphone (kTCCServiceMicrophone) for a mic.
    // Request explicitly via a semaphore rather than relying on the automatic prompt.
    if hasTap {
        let permission = AudioCapturePermission.status()
        print("System Audio Recording permission: \(permission.rawValue)")
        if permission != .authorized {
            let sem = DispatchSemaphore(value: 0)
            AudioCapturePermission.request { granted in
                print("Audio-capture permission result: \(granted ? "granted" : "denied")")
                sem.signal()
            }
            sem.wait()
        }
    }
    if hasMic {
        let mp = MicrophonePermission.status()
        print("Microphone permission: \(mp.rawValue)")
        if mp != .authorized {
            let sem = DispatchSemaphore(value: 0)
            MicrophonePermission.request { granted in
                print("Microphone permission result: \(granted ? "granted" : "denied")")
                sem.signal()
            }
            sem.wait()
        }
    }

    // Shared teardown: stop, report whether any signal was captured, exit.
    func finish() -> Never {
        recorder.stop()
        let maxPeak = recorder.meter.maxPeak
        let db = maxPeak > 0 ? String(format: "%.1f dBFS", LevelMeter.dBFS(maxPeak)) : "−∞ (pure silence)"
        print("\n\nStopped. Saved: \(fileURL.path)")
        print("  frames captured: \(recorder.meter.totalFrames)")
        print("  peak level:      \(db)")
        print(maxPeak > 0 ? "  ✓ Signal captured." : "  ✗ No signal — see the causes above.")
        exit(0)
    }

    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler { finish() }
    sigintSource.resume()

    if let durationArg = argValue("--duration"), let seconds = Double(durationArg) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
    }

    try recorder.start()
    let routing = device.map { "routing to \"\($0.name)\"" } ?? "record only (no routing)"
    print("Recording \(sourceLabel) → \(fileURL.lastPathComponent), \(routing).")
    if hasMic && device != nil {
        print("⚠️  Mic + routing to a device can feed back (the mic hears the speakers). Use headphones or --no-route.")
    }
    print("Capture format: \(recorder.captureDescription ?? "unknown")")
    print("File format:    \(format.displayName)\(format.isLossless ? "" : " — lossy")")
    print("Press Ctrl-C to stop.\n")

    // Live level meter, so you can SEE whether the tap is delivering signal.
    let meterState = MeterState()
    let interval = 0.25
    let meterTimer = Timer(timeInterval: interval, repeats: true) { _ in
        let peak = recorder.meter.takePeak()
        let dbText = peak > 0 ? String(format: "%6.1f dBFS", LevelMeter.dBFS(peak)) : "  −∞ dBFS"
        FileHandle.standardError.write("\r  [\(meterBar(peak))] \(dbText)   ".data(using: .utf8)!)
        if peak < 0.0001 { meterState.silentSeconds += interval } else { meterState.silentSeconds = 0; meterState.warned = false }
        if meterState.silentSeconds >= 3 && !meterState.warned {
            meterState.warned = true
            let hint = """

            ⚠️  3s of pure silence — the tap is delivering no signal. Likely causes:
               1. Audio-capture consent (System Audio Recording) not granted. It's prompted
                  when the tap is created, for a signed bundle — run ./Scripts/make-cli-app.sh
                  and use the bundled binary; allow the prompt. Check System Settings ▸
                  Privacy & Security ▸ Screen & System Audio Recording.
               2. The source isn't actually playing audio right now.
               3. Its audio is being redirected/captured by another app (e.g. SoundSource);
                  try disabling that app's redirect for the source and retry.

            """
            FileHandle.standardError.write(hint.data(using: .utf8)!)
        }
    }
    RunLoop.main.add(meterTimer, forMode: .common)
    RunLoop.main.run()
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
