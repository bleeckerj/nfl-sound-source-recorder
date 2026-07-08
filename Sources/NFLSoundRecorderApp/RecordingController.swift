import Foundation
import AppKit
import Combine
import SoundRecorderKit

enum VizMode: String, CaseIterable, Identifiable {
    case bars = "Bars"
    case scope = "Scope"
    var id: String { rawValue }
}

/// One selectable audio source in the menu (all system audio, a running app, or the
/// "microphone only" choice — whose `makeTarget` returns nil, meaning no tap).
struct SourceOption: Identifiable, Hashable {
    let id: String
    let label: String
    let icon: NSImage?
    let makeTarget: @Sendable () -> ProcessTapRecorder.Target?

    static func == (lhs: SourceOption, rhs: SourceOption) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Drives the menu bar UI: enumerates sources/devices and owns the recorder.
@MainActor
final class RecordingController: ObservableObject {
    /// Sentinel `selectedDeviceUID` meaning "don't route anywhere" — record only.
    static let noRouteUID = "__none__"
    /// Sentinel `selectedMicUID` meaning "no microphone".
    static let micOffUID = "__mic_off__"
    /// Sentinel source id for the "microphone only" (no tap) choice.
    static let micOnlySourceID = "__mic_only__"

    @Published var sources: [SourceOption] = []
    @Published var devices: [AudioDeviceInfo] = []
    /// Input devices (microphones) available to capture / mix in.
    @Published var inputDevices: [AudioDeviceInfo] = []
    @Published var selectedSourceID = "system"
    /// Selected microphone UID, or `micOffUID` for no mic.
    @Published var selectedMicUID = micOffUID {
        didSet {
            if isRecording && oldValue != selectedMicUID {
                // Mic device is fixed for the current recording; note it for next start.
                statusText = "Microphone change applies to the next recording."
            }
        }
    }
    @Published var selectedDeviceUID = "" {
        didSet {
            // Routing can change live while recording — reroute without interrupting
            // capture. (When idle this just records the choice for the next start.)
            if isRecording && oldValue != selectedDeviceUID { applyRoutingChange() }
        }
    }
    @Published var mute = false
    @Published var recordLevelDB: Double = 0
    /// Per-feed levels (dB) for balancing a mix; shown for the active feed(s).
    @Published var sourceLevelDB: Double = 0
    @Published var micLevelDB: Double = 0
    @Published var recordingFormat: RecordingFormat = .caf

    @Published var eqEnabled = true
    @Published var eqGains: [Double] = Array(repeating: 0, count: GraphicEQ.bandCount)

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsedText = "00:00"
    @Published var statusText = "Idle"
    @Published var bandLevels: [Float] = Array(repeating: 0, count: SpectrumMeter.bandCount)
    @Published var bandPeaks: [Float] = Array(repeating: 0, count: SpectrumMeter.bandCount)
    @Published var vizMode: VizMode = .bars
    @Published var scopeLeft: [Float] = []
    @Published var scopeRight: [Float] = []
    /// Rotation (degrees) for the menu-bar cassette reels; advances while recording.
    @Published var iconAngle: Double = 0
    /// Smoothed live audio level (0...1) driving the menu-bar icon — the reels spin
    /// faster and the hub pulses as the captured signal gets louder.
    @Published var iconLevel: Double = 0
    @Published var lastError: String?
    @Published var lastFileURL: URL?

    private var recorder: ProcessTapRecorder?
    private var timer: Timer?
    private var startDate: Date?
    /// When the current pause began, and total time spent paused, so elapsed time
    /// reflects tape actually written rather than wall-clock since Record.
    private var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0
    /// The "Recording …" status line, remembered so resuming (or a routing change) can
    /// rebuild it, plus the source label it's built from.
    private var recordingStatus = ""
    private var recordingSourceLabel = ""
    /// Whether the current recording includes the mic (for the feedback hint).
    private var recordingHasMic = false

    /// Rebuild the source + device lists (call whenever the menu opens).
    func refresh() {
        do {
            devices = try AudioSystem.outputDevices()
            let currentDefault = try? AudioSystem.defaultOutputDevice()
            // Keep an explicit "record only" choice; otherwise fall back to a real device.
            if selectedDeviceUID.isEmpty
                || (selectedDeviceUID != Self.noRouteUID
                    && !devices.contains(where: { $0.uid == selectedDeviceUID })) {
                selectedDeviceUID = devices.first(where: { $0.id == currentDefault })?.uid
                    ?? devices.first?.uid ?? ""
            }
        } catch {
            lastError = "\(error)"
        }

        // Input devices (microphones). Keep the "off" choice; drop a stale device.
        inputDevices = (try? AudioSystem.inputDevices()) ?? []
        if selectedMicUID != Self.micOffUID
            && !inputDevices.contains(where: { $0.uid == selectedMicUID }) {
            selectedMicUID = Self.micOffUID
        }

        var options: [SourceOption] = [
            SourceOption(
                id: "system",
                label: "All System Audio",
                icon: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil),
                makeTarget: { .systemWide }
            ),
            SourceOption(
                id: Self.micOnlySourceID,
                label: "None — microphone only",
                icon: NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: nil),
                makeTarget: { nil }
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

    /// The microphone device currently selected, or nil for "off".
    var selectedMic: AudioDeviceInfo? {
        guard selectedMicUID != Self.micOffUID else { return nil }
        return inputDevices.first(where: { $0.uid == selectedMicUID })
    }

    func toggle() { isRecording ? stop() : start() }

    /// Gate on the consents the chosen recording actually needs — System Audio Recording
    /// (kTCCServiceAudioCapture) for a tap, and Microphone (kTCCServiceMicrophone) for a
    /// mic — then begin. Each is only requested when its source is in play.
    func start() {
        lastError = nil
        let target = sources.first(where: { $0.id == selectedSourceID })?.makeTarget()
        let needsTap = target != nil
        let needsMic = selectedMic != nil
        guard needsTap || needsMic else {
            lastError = "Pick a source or a microphone."; return
        }
        ensureAudioCapturePermission(required: needsTap) { [weak self] granted in
            guard let self, granted else { return }
            self.ensureMicPermission(required: needsMic) { [weak self] granted in
                guard let self, granted else { return }
                self.beginRecording()
            }
        }
    }

    /// Ensure System Audio Recording consent if a tap is involved. Registers TapDeck under
    /// System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording.
    private func ensureAudioCapturePermission(required: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard required else { completion(true); return }
        switch AudioCapturePermission.status() {
        case .authorized, .unknown:
            completion(true)
        case .notDetermined:
            statusText = "Requesting System Audio Recording permission…"
            AudioCapturePermission.request { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if !granted {
                        self.statusText = "Idle"
                        self.lastError = "Permission denied. Enable it in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."
                    }
                    completion(granted)
                }
            }
        case .denied:
            lastError = "System Audio Recording is off. Enable TapDeck in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."
            completion(false)
        }
    }

    /// Ensure Microphone consent if the mic is involved.
    private func ensureMicPermission(required: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard required else { completion(true); return }
        switch MicrophonePermission.status() {
        case .authorized:
            completion(true)
        case .notDetermined:
            statusText = "Requesting Microphone permission…"
            MicrophonePermission.request { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if !granted {
                        self.statusText = "Idle"
                        self.lastError = "Microphone permission denied. Enable TapDeck in System Settings ▸ Privacy & Security ▸ Microphone."
                    }
                    completion(granted)
                }
            }
        case .denied, .restricted, .unknown:
            lastError = "Microphone is off. Enable TapDeck in System Settings ▸ Privacy & Security ▸ Microphone."
            completion(false)
        }
    }

    private func beginRecording() {
        lastError = nil
        guard let sourceOption = sources.first(where: { $0.id == selectedSourceID }) else {
            lastError = "Pick a source."; return
        }
        // Combine the tap choice (may be nil = mic-only) with the mic choice into a Source.
        let target = sourceOption.makeTarget()
        let mic = selectedMic
        let captureSource: ProcessTapRecorder.Source
        let sourceLabel: String
        switch (target, mic) {
        case let (.some(t), .some(m)): captureSource = .mix(tap: t, mic: m); sourceLabel = "\(sourceOption.label) + \(m.name)"
        case let (.some(t), .none):    captureSource = .tap(t); sourceLabel = sourceOption.label
        case let (.none, .some(m)):    captureSource = .microphone(m); sourceLabel = m.name
        case (.none, .none):           lastError = "Pick a source or a microphone."; return
        }
        recordingHasMic = mic != nil

        // Record-only when "None" is selected; otherwise resolve the routing device.
        let device: AudioDeviceInfo?
        if selectedDeviceUID == Self.noRouteUID {
            device = nil
        } else {
            guard let picked = devices.first(where: { $0.uid == selectedDeviceUID }) else {
                lastError = "Pick an output device."; return
            }
            device = picked
        }

        let url = Self.newFileURL(format: recordingFormat)
        let rec = ProcessTapRecorder(source: captureSource, outputDevice: device, fileURL: url,
                                     format: recordingFormat, mute: mute,
                                     driftCompensation: false)
        do {
            try rec.start()
            rec.equalizer.setGains(eqGains)
            rec.equalizer.setEnabled(eqEnabled)
            rec.setRecordGain(dB: recordLevelDB)
            rec.setSourceGain(dB: sourceLevelDB)
            rec.setMicGain(dB: micLevelDB)
            recorder = rec
            startDate = Date()
            pausedAt = nil
            pausedTotal = 0
            isPaused = false
            lastFileURL = url
            isRecording = true
            recordingSourceLabel = sourceLabel
            updateRecordingStatus(device: device)
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
        pausedAt = nil
        pausedTotal = 0
        isRecording = false
        isPaused = false
        bandLevels = Array(repeating: 0, count: SpectrumMeter.bandCount)
        bandPeaks = Array(repeating: 0, count: SpectrumMeter.bandCount)
        scopeLeft = []
        scopeRight = []
        iconLevel = 0
        statusText = "Saved \(lastFileURL?.lastPathComponent ?? "recording")."
    }

    /// Reroute the in-progress recording to the currently-selected device (or to
    /// record-only). Capture and file-writing continue uninterrupted across the change.
    private func applyRoutingChange() {
        let device: AudioDeviceInfo? = selectedDeviceUID == Self.noRouteUID
            ? nil
            : devices.first(where: { $0.uid == selectedDeviceUID })
        recorder?.setRoutingDevice(device)
        updateRecordingStatus(device: device)
    }

    /// Rebuild the "Recording …" status line for the given routing device.
    private func updateRecordingStatus(device: AudioDeviceInfo?) {
        let routing = device.map { "→ \($0.name)" } ?? "(record only)"
        var line = "Recording “\(recordingSourceLabel)” \(routing)…"
        // Mic + routing to a device can feed back (the mic hears the speakers).
        if recordingHasMic && device != nil {
            line += "  ⚠️ mic + routing may feed back — use headphones."
        }
        recordingStatus = line
        if isRecording && !isPaused { statusText = recordingStatus }
    }

    func togglePause() { isPaused ? resume() : pause() }

    /// Suspend disk-writing while keeping the tap alive. The reels, meters, and
    /// elapsed clock freeze; the monitored output keeps playing.
    func pause() {
        guard isRecording, !isPaused else { return }
        isPaused = true
        pausedAt = Date()
        recorder?.setPaused(true)
        statusText = "Paused."
    }

    func resume() {
        guard isRecording, isPaused else { return }
        if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        isPaused = false
        recorder?.setPaused(false)
        statusText = recordingStatus
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

    /// Live per-feed levels for balancing a mix.
    func setSourceLevel(_ dB: Double) {
        sourceLevelDB = dB
        recorder?.setSourceGain(dB: dB)
    }

    func setMicLevel(_ dB: Double) {
        micLevelDB = dB
        recorder?.setMicGain(dB: dB)
    }

    /// Whether the current source selection includes a tap / a mic — drives which feed
    /// level sliders the UI shows.
    var sourceHasTap: Bool { sources.first(where: { $0.id == selectedSourceID })?.makeTarget() != nil }
    var sourceHasMic: Bool { selectedMic != nil }

    func revealLastFile() {
        guard let url = lastFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func tick() {
        // Paused: hold the reels, meters, and clock where they are.
        guard !isPaused else { return }
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
        // Smoothed live level (0...1) for the menu-bar icon's hub swell: map the
        // window's peak to a perceptual scale (dBFS over a −54 dB floor), then ease
        // toward it so the hub grows/shrinks smoothly instead of jittering.
        let peak = recorder?.meter.takePeak() ?? 0
        let target = peak > 0 ? max(0, min(1, (LevelMeter.dBFS(peak) + 54) / 54)) : 0
        // Assymmetric smoothing: snap up on transients, decay slowly like a VU meter.
        let ease = target > iconLevel ? 0.6 : 0.15
        iconLevel += (target - iconLevel) * ease
        // Spin the reels at a *constant* rate — a real tape transport moves the tape at
        // a fixed speed regardless of the signal on it. Tying speed to level made the
        // reels surge and stall with the audio ("hurk-and-jerk"), so keep it steady.
        iconAngle = (iconAngle + 6).truncatingRemainder(dividingBy: 360)
        guard let startDate else { return }
        let seconds = Int(Date().timeIntervalSince(startDate) - pausedTotal)
        elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func newFileURL(format: RecordingFormat) -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/TapDeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(formatter.string(from: Date())).\(format.fileExtension)")
    }
}
