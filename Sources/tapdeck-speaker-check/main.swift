import AppKit
import Foundation
import SoundRecorderKit

func argument(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
    fflush(stdout)
}

do {
    let usage = "Use --devices or --directory PATH --duration SECONDS (3–30), with optional --playback FILE."
    if CommandLine.arguments.contains("--help") {
        print(usage)
        exit(0)
    }
    let devicesOnly = CommandLine.arguments.contains("--devices")
    let capturePath = argument("--directory")
    let captureDuration = argument("--duration").flatMap(Double.init)
    if !devicesOnly {
        guard capturePath != nil, let captureDuration,
              captureDuration.isFinite, (3...30).contains(captureDuration) else {
            throw NSError(domain: "TapDeckSpeakerCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: usage])
        }
        if let playback = argument("--playback"), !FileManager.default.isReadableFile(atPath: playback) {
            throw NSError(domain: "TapDeckSpeakerCheck", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Playback file is not readable: \(playback)"])
        }
    }
    let watchdog = QualificationWatchdog(directory: argument("--directory").map {
        URL(fileURLWithPath: $0, isDirectory: true)
    })
    defer { withExtendedLifetime(watchdog) {} }
    _ = NSApplication.shared
    print("Discovering built-in audio devices…")
    fflush(stdout)
    let devices = try SpeakerQualification.defaultDevices()
    try emit(["microphone": devices.microphone, "speaker": devices.speaker])
    if !devicesOnly, let path = capturePath, let duration = captureDuration {
        if MicrophonePermission.status() == .notDetermined {
            watchdog.begin("microphone consent", seconds: 50)
            print("Requesting microphone consent. Allow the macOS prompt to run the diagnostic.")
            fflush(stdout)
            MicrophonePermission.request { granted in
                DispatchQueue.main.async { print("Microphone permission: \(granted ? "allowed" : "denied")") }
            }
            let deadline = Date().addingTimeInterval(45)
            while MicrophonePermission.status() == .notDetermined && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        let qualification = try SpeakerQualification(directory: URL(fileURLWithPath: path, isDirectory: true))
        watchdog.begin("native audio initialization", seconds: 15)
        try qualification.start()
        let playback = Process()
        playback.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        if let audioPath = argument("--playback") { playback.arguments = [audioPath] }
        defer { if playback.isRunning { playback.terminate(); playback.waitUntilExit() } }
        print("Capturing raw and processed microphone for \(duration) seconds. Output: \(path)")
        fflush(stdout)
        let deadline = Date().addingTimeInterval(duration)
        watchdog.begin("audio capture", seconds: duration + 5)
        let playbackStart = Date().addingTimeInterval(2)
        var playbackStarted = false
        var nextUpdate = Date()
        while Date() < deadline {
            if playback.arguments != nil && !playbackStarted && Date() >= playbackStart {
                try playback.run()
                playbackStarted = true
                print("Controlled speaker playback started.")
            }
            if Date() >= nextUpdate {
                print("Capture active; \(Int(ceil(deadline.timeIntervalSinceNow))) seconds remaining.")
                fflush(stdout)
                nextUpdate = Date().addingTimeInterval(3)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        watchdog.begin("audio finalization", seconds: 10)
        let report = try qualification.stop()
        try emit(report)
        if !report.completed { exit(2) }
    }
} catch {
    if let path = argument("--directory") {
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        let failure = destination.appendingPathComponent("failure.json")
        if !FileManager.default.fileExists(atPath: failure.path) {
            let details: [String: Any] = [
                "completed": false, "error": String(describing: error),
                "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code,
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ]
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
                    .write(to: failure, options: .atomic)
            } catch {
                fputs("Could not save diagnostic failure: \(error)\n", stderr)
            }
        }
    }
    fputs("Speaker qualification failed: \(error)\n", stderr)
    exit(1)
}
