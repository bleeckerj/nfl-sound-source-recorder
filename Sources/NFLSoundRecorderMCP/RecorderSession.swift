import Foundation
import SoundRecorderKit

/// Holds the single active recording (if any) for the MCP server.
final class RecorderSession {
    struct Active {
        let recorder: ProcessTapRecorder
        let fileURL: URL
        let sourceLabel: String
        var deviceName: String
        let startDate: Date
    }

    private(set) var active: Active?
    var isRecording: Bool { active != nil }
    private(set) var isPaused = false

    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    // Desired EQ state; applied to each recording and updated live if recording.
    private(set) var eqEnabled = false
    private(set) var eqGains = [Double](repeating: 0, count: GraphicEQ.bandCount)

    func start(source: ProcessTapRecorder.Source,
               sourceLabel: String,
               device: AudioDeviceInfo?,
               mute: Bool,
               driftCompensation: Bool,
               warmupSeconds: Double,
               sourceLevelDB: Double?,
               micLevelDB: Double?,
               format: RecordingFormat,
               fileURL: URL) throws {
        if active != nil { throw SessionError("Already recording. Call stop_recording first.") }
        let recorder = ProcessTapRecorder(source: source, outputDevice: device, fileURL: fileURL,
                                          format: format, mute: mute, driftCompensation: driftCompensation,
                                          warmupSeconds: warmupSeconds)
        try recorder.start()
        recorder.equalizer.setGains(eqGains)
        recorder.equalizer.setEnabled(eqEnabled)
        if let sourceLevelDB { recorder.setSourceGain(dB: sourceLevelDB) }
        if let micLevelDB { recorder.setMicGain(dB: micLevelDB) }
        active = Active(recorder: recorder, fileURL: fileURL, sourceLabel: sourceLabel,
                        deviceName: device?.name ?? "(record only)", startDate: Date())
        isPaused = false
        pausedAt = nil
        pausedTotal = 0
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

    /// Pause or resume file writing while keeping the capture and monitor alive.
    func setPaused(_ paused: Bool) throws {
        guard let active else { throw SessionError("Not currently recording.") }
        guard isPaused != paused else { return }

        if paused {
            pausedAt = Date()
        } else if let pausedAt {
            pausedTotal += Date().timeIntervalSince(pausedAt)
            self.pausedAt = nil
        }
        isPaused = paused
        active.recorder.setPaused(paused)
    }

    /// Reroute the live monitor without interrupting capture. Passing nil disables routing.
    func setRoutingDevice(_ device: AudioDeviceInfo?) throws {
        guard let active else { throw SessionError("Not currently recording.") }
        active.recorder.setRoutingDevice(device)
        self.active?.deviceName = device?.name ?? "(record only)"
    }

    /// Apply live source/microphone gain changes to the active recorder.
    func setLevels(sourceDB: Double?, micDB: Double?) throws {
        guard let active else { throw SessionError("Not currently recording.") }
        if let sourceDB { active.recorder.setSourceGain(dB: sourceDB) }
        if let micDB { active.recorder.setMicGain(dB: micDB) }
    }

    var elapsed: TimeInterval? {
        guard let active else { return nil }
        let paused = pausedAt.map { Date().timeIntervalSince($0) } ?? 0
        return max(0, Date().timeIntervalSince(active.startDate) - pausedTotal - paused)
    }

    /// Stops the recording and returns the file URL and its duration in seconds.
    @discardableResult
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let active else { return nil }
        active.recorder.stop()
        let duration = elapsed ?? Date().timeIntervalSince(active.startDate)
        self.active = nil
        isPaused = false
        pausedAt = nil
        pausedTotal = 0
        return (active.fileURL, duration)
    }

    struct SessionError: LocalizedError, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
        var errorDescription: String? { message }
    }
}

/// Output location. All MCP-driven writes are confined to this directory: an
/// LLM-supplied `file_path` is reduced to a sanitized filename so it can't be used
/// for path traversal (e.g. overwriting `~/.zshrc`).
enum RecordingFiles {
    static func directory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/TapDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newURL(format: RecordingFormat = .aac) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return directory().appendingPathComponent("Recording \(formatter.string(from: Date())).\(format.fileExtension)")
    }

    /// Reduce any client-supplied path to a safe filename inside `directory()`, with the
    /// extension forced to match the chosen codec.
    static func confinedURL(forRequestedPath path: String, format: RecordingFormat = .aac) -> URL {
        let ext = format.fileExtension
        var name = (path as NSString).lastPathComponent
        if name.isEmpty || name == "/" || name == "." || name == ".." { name = "Recording" }
        // Drop any client-supplied extension and apply the codec's own.
        name = (name as NSString).deletingPathExtension
        if name.isEmpty { name = "Recording" }
        return directory().appendingPathComponent("\(name).\(ext)")
    }
}
