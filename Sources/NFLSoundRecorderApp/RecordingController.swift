import Foundation
import AppKit
import Combine
import SoundRecorderKit

enum VizMode: String, CaseIterable, Identifiable {
    case bars = "Bars"
    case scope = "Scope"
    var id: String { rawValue }
}

/// One selectable audio source in the menu (either all system audio or a running app).
struct SourceOption: Identifiable, Hashable {
    let id: String
    let label: String
    let icon: NSImage?
    let makeTarget: @Sendable () -> ProcessTapRecorder.Target

    static func == (lhs: SourceOption, rhs: SourceOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drives the menu bar UI: enumerates sources/devices and owns the recorder.
@MainActor
final class RecordingController: ObservableObject {
    @Published var sources: [SourceOption] = []
    @Published var devices: [AudioDeviceInfo] = []
    @Published var selectedSourceID = "system"
    @Published var selectedDeviceUID = ""
    @Published var mute = false
    @Published var driftCompensation = false
    @Published var recordLevelDB: Double = 0

    @Published var eqEnabled = false
    @Published var eqGains: [Double] = Array(repeating: 0, count: GraphicEQ.bandCount)

    @Published var isRecording = false
    @Published var elapsedText = "00:00"
    @Published var statusText = "Idle"
    @Published var bandLevels: [Float] = Array(repeating: 0, count: SpectrumMeter.bandCount)
    @Published var bandPeaks: [Float] = Array(repeating: 0, count: SpectrumMeter.bandCount)
    @Published var vizMode: VizMode = .bars
    @Published var scopeLeft: [Float] = []
    @Published var scopeRight: [Float] = []
    /// Rotation (degrees) for the menu-bar cassette reels; advances while recording.
    @Published var iconAngle: Double = 0
    @Published var lastError: String?
    @Published var lastFileURL: URL?

    private var recorder: ProcessTapRecorder?
    private var timer: Timer?
    private var startDate: Date?

    /// Rebuild the source + device lists (call whenever the menu opens).
    func refresh() {
        do {
            devices = try AudioSystem.outputDevices()
            let currentDefault = try? AudioSystem.defaultOutputDevice()
            if selectedDeviceUID.isEmpty || !devices.contains(where: { $0.uid == selectedDeviceUID }) {
                selectedDeviceUID = devices.first(where: { $0.id == currentDefault })?.uid
                    ?? devices.first?.uid ?? ""
            }
        } catch {
            lastError = "\(error)"
        }

        var options: [SourceOption] = [
            SourceOption(
                id: "system",
                label: "All System Audio",
                icon: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil),
                makeTarget: { .systemWide }
            )
        ]
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            let pid = app.processIdentifier
            options.append(SourceOption(
                id: app.bundleIdentifier ?? "pid:\(pid)",
                label: app.localizedName ?? "(unknown)",
                icon: app.icon,
                makeTarget: { .pid(pid) }
            ))
        }
        sources = options
        if !sources.contains(where: { $0.id == selectedSourceID }) { selectedSourceID = "system" }
    }

    func toggle() { isRecording ? stop() : start() }

    /// Gate on System Audio Recording consent (kTCCServiceAudioCapture) — this is
    /// what actually shows the permission prompt and registers the app under
    /// System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.
    func start() {
        lastError = nil
        switch AudioCapturePermission.status() {
        case .authorized, .unknown:
            beginRecording()
        case .notDetermined:
            statusText = "Requesting System Audio Recording permission…"
            AudioCapturePermission.request { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.beginRecording()
                    } else {
                        self.statusText = "Idle"
                        self.lastError = "Permission denied. Enable it in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."
                    }
                }
            }
        case .denied:
            lastError = "System Audio Recording is off. Enable NFL Sound Recorder in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."
        }
    }

    private func beginRecording() {
        lastError = nil
        guard let source = sources.first(where: { $0.id == selectedSourceID }) else {
            lastError = "Pick a source."; return
        }
        guard let device = devices.first(where: { $0.uid == selectedDeviceUID }) else {
            lastError = "Pick an output device."; return
        }

        let url = Self.newFileURL()
        let rec = ProcessTapRecorder(target: source.makeTarget(), outputDevice: device, fileURL: url,
                                     mute: mute, driftCompensation: driftCompensation)
        do {
            try rec.start()
            rec.equalizer.setGains(eqGains)
            rec.equalizer.setEnabled(eqEnabled)
            rec.setRecordGain(dB: recordLevelDB)
            recorder = rec
            startDate = Date()
            lastFileURL = url
            isRecording = true
            statusText = "Recording “\(source.label)”…"
            // Schedule in .common mode so it keeps firing while the menu-bar popover
            // is open (default-mode timers are paused during that tracking run loop).
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } catch {
            lastError = "\(error)"
            statusText = "Idle"
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        startDate = nil
        isRecording = false
        bandLevels = Array(repeating: 0, count: SpectrumMeter.bandCount)
        bandPeaks = Array(repeating: 0, count: SpectrumMeter.bandCount)
        statusText = "Saved \(lastFileURL?.lastPathComponent ?? "recording")."
    }

    func setEQEnabled(_ on: Bool) {
        eqEnabled = on
        recorder?.equalizer.setEnabled(on)
    }

    func setEQ(band: Int, dB: Double) {
        guard band >= 0, band < eqGains.count else { return }
        eqGains[band] = dB
        recorder?.equalizer.setGain(band: band, dB: dB)
    }

    func flatEQ() {
        eqGains = Array(repeating: 0, count: eqGains.count)
        recorder?.equalizer.flat()
    }

    func setRecordLevel(_ dB: Double) {
        recordLevelDB = dB
        recorder?.setRecordGain(dB: dB)
    }

    func revealLastFile() {
        guard let url = lastFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func tick() {
        if let recorder {
            switch vizMode {
            case .bars:
                bandLevels = recorder.spectrum.levels()
                bandPeaks = recorder.spectrum.peakLevels()
            case .scope:
                let s = recorder.scope.snapshot()
                scopeLeft = s.left
                scopeRight = s.right
            }
        }
        iconAngle = (iconAngle + 12).truncatingRemainder(dividingBy: 360) // ~1 rev/sec at 30fps
        guard let startDate else { return }
        let seconds = Int(Date().timeIntervalSince(startDate))
        elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func newFileURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/NFL Sound Recorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(formatter.string(from: Date())).caf")
    }
}
