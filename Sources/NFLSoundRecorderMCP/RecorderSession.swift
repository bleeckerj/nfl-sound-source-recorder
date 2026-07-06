import Foundation
import SoundRecorderKit

/// Holds the single active recording (if any) for the MCP server.
final class RecorderSession {
    struct Active {
        let recorder: ProcessTapRecorder
        let fileURL: URL
        let sourceLabel: String
        let deviceName: String
        let startDate: Date
    }

    private(set) var active: Active?
    var isRecording: Bool { active != nil }

    // Desired EQ state; applied to each recording and updated live if recording.
    private(set) var eqEnabled = false
    private(set) var eqGains = [Double](repeating: 0, count: GraphicEQ.bandCount)

    func start(target: ProcessTapRecorder.Target,
               sourceLabel: String,
               device: AudioDeviceInfo,
               mute: Bool,
               driftCompensation: Bool,
               warmupSeconds: Double,
               fileURL: URL) throws {
        if active != nil { throw SessionError("Already recording. Call stop_recording first.") }
        let recorder = ProcessTapRecorder(target: target, outputDevice: device, fileURL: fileURL,
                                          mute: mute, driftCompensation: driftCompensation,
                                          warmupSeconds: warmupSeconds)
        try recorder.start()
        recorder.equalizer.setGains(eqGains)
        recorder.equalizer.setEnabled(eqEnabled)
        active = Active(recorder: recorder, fileURL: fileURL, sourceLabel: sourceLabel,
                        deviceName: device.name, startDate: Date())
    }

    /// Update EQ state; takes effect immediately if a recording is in progress.
    func setEqualizer(enabled: Bool?, gains: [Double]?) {
        if let enabled { eqEnabled = enabled }
        if let gains {
            for (i, value) in gains.enumerated() where i < eqGains.count { eqGains[i] = value }
        }
        if let active {
            if gains != nil { active.recorder.equalizer.setGains(eqGains) }
            active.recorder.equalizer.setEnabled(eqEnabled)
        }
    }

    /// Stops the recording and returns the file URL and its duration in seconds.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let active else { return nil }
        active.recorder.stop()
        let duration = Date().timeIntervalSince(active.startDate)
        self.active = nil
        return (active.fileURL, duration)
    }

    struct SessionError: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}

/// Output location. All MCP-driven writes are confined to this directory: an
/// LLM-supplied `file_path` is reduced to a sanitized filename so it can't be used
/// for path traversal (e.g. overwriting `~/.zshrc`).
enum RecordingFiles {
    static func directory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/NFL Sound Recorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory().appendingPathComponent("Recording \(formatter.string(from: Date())).caf")
    }

    /// Reduce any client-supplied path to a safe filename inside `directory()`.
    static func confinedURL(forRequestedPath path: String) -> URL {
        var name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "/" || name == "." || name == ".." { name = "Recording.caf" }
        if !name.lowercased().hasSuffix(".caf") { name += ".caf" }
        return directory().appendingPathComponent(name)
    }
}
