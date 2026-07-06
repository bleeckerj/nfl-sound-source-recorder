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
                         [--out <deviceUID>] [--file <path>] [--mute]

    OPTIONS:
      --list            List running apps and available output devices, then exit.
      --app <bundleID>  Capture an audio-first application by bundle id (see --list).
      --pid <pid>       Capture a running process by pid.
      --system          Capture all system audio.
      --out <deviceUID> Output device UID to route to (default: current default output).
      --file <path>     Output file path (default: ./recording-<timestamp>.caf).
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
    print("Running apps with audio-capable processes:")
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    for app in apps {
        let name = app.localizedName ?? "(unknown)"
        let bundle = app.bundleIdentifier ?? "?"
        print("  pid \(String(app.processIdentifier).padding(toLength: 6, withPad: " ", startingAt: 0))  \(name)  [\(bundle)]")
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
}

// MARK: - Resolve target + device

func resolveTarget() -> ProcessTapRecorder.Target? {
    if hasFlag("--system") { return .systemWide }
    if let pidStr = argValue("--pid"), let pid = pid_t(pidStr) { return .pid(pid) }
    if let bundle = argValue("--app") {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) {
            return .pid(app.processIdentifier)
        }
        FileHandle.standardError.write("No running app with bundle id \(bundle)\n".data(using: .utf8)!)
        return nil
    }
    return nil
}

func resolveOutputDevice() throws -> AudioDeviceInfo {
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
        print("\n\(Int(freq)) Hz @ \(label):")
        for (i, l) in levels.enumerated() where l > 0.01 {
            let bar = String(repeating: "█", count: Int(l * 30))
            print("  \(labels[i].padding(toLength: 4, withPad: " ", startingAt: 0)) \(String(format: "%.3f", l)) \(bar)")
        }
    }
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
    exit(0)
}

if hasFlag("--selftest-spectrum") {
    runSpectrumSelfTest()
    exit(0)
}

guard let target = resolveTarget() else {
    FileHandle.standardError.write("Specify a target: --app <bundleID>, --pid <pid>, or --system. Use --list to explore.\n".data(using: .utf8)!)
    exit(1)
}

let fileURL: URL = {
    if let path = argValue("--file") { return URL(fileURLWithPath: path) }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("recording-\(stamp).caf")
}()

do {
    let device = try resolveOutputDevice()
    let warmup = argValue("--warmup").flatMap(Double.init) ?? 0.6
    let recorder = ProcessTapRecorder(target: target, outputDevice: device, fileURL: fileURL,
                                      mute: hasFlag("--mute"), driftCompensation: hasFlag("--drift"),
                                      warmupSeconds: warmup)

    if let eqArg = argValue("--eq") {
        let gains = eqArg.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        recorder.equalizer.setGains(gains)
        recorder.equalizer.setEnabled(true)
        print("EQ enabled — gains (dB): \(gains)")
    }

    // Ensure System Audio Recording consent (kTCCServiceAudioCapture) before we
    // start — request it explicitly via the TCC SPI rather than relying on the
    // (unreliable) automatic prompt.
    let permission = AudioCapturePermission.status()
    print("System Audio Recording permission: \(permission.rawValue)")
    if permission != .authorized {
        let sem = DispatchSemaphore(value: 0)
        AudioCapturePermission.request { granted in
            print("Permission request result: \(granted ? "granted" : "denied")")
            sem.signal()
        }
        sem.wait()
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
    switch target {
    case .pid(let pid): print("Recording pid \(pid) → \(fileURL.lastPathComponent), routing to \"\(device.name)\".")
    case .systemWide:   print("Recording system audio → \(fileURL.lastPathComponent), routing to \"\(device.name)\".")
    }
    print("Capture format: \(recorder.captureDescription ?? "unknown")")
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
