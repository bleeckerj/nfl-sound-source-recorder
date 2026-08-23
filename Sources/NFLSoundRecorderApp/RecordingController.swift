import Foundation
import AppKit
import Combine
import CoreAudio
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
    /// Whether this source taps process audio. Stored rather than derived by *calling*
    /// `makeTarget()`: that closure re-enumerates the HAL (a blocking IPC round-trip per
    /// audio process), which is fine at record time but ruinous when the UI asks the
    /// question during a view update. See `RecordingController.sourceHasTap`.
    let isTap: Bool
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
    @Published var mute = false { didSet { Prefs.set(mute, Prefs.mute) } }
    @Published var recordLevelDB: Double = 0 { didSet { Prefs.set(recordLevelDB, Prefs.recordLevel) } }
    /// Per-feed levels (dB) for balancing a mix; shown for the active feed(s).
    @Published var sourceLevelDB: Double = 0 { didSet { Prefs.set(sourceLevelDB, Prefs.sourceLevel) } }
    @Published var micLevelDB: Double = 0 { didSet { Prefs.set(micLevelDB, Prefs.micLevel) } }
    /// AAC by default (small files); the choice is persisted across launches — see `Prefs`.
    @Published var recordingFormat: RecordingFormat = .aac {
        didSet { Prefs.set(recordingFormat.rawValue, Prefs.format) }
    }

    @Published var eqEnabled = true { didSet { Prefs.set(eqEnabled, Prefs.eqEnabled) } }
    @Published var eqGains: [Double] = Array(repeating: 0, count: GraphicEQ.bandCount) {
        didSet { Prefs.set(eqGains, Prefs.eqGains) }
    }

    /// Folder new recordings are written to. User-settable (see `chooseRecordingsDirectory`)
    /// and persisted across launches; defaults to ~/Music/TapDeck.
    @Published var recordingsDirectory: URL = RecordingController.defaultRecordingsDirectory {
        didSet { Prefs.set(recordingsDirectory.path, Prefs.recordingsDir) }
    }

    /// The built-in default recordings location.
    static var defaultRecordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/TapDeck", isDirectory: true)
    }

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var statusText = "Idle"
    @Published var vizMode: VizMode = .bars
    @Published var lastError: String?
    @Published var lastFileURL: URL?

    /// Everything the 30 Hz tick rewrites — meters, reels, elapsed clock. A separate
    /// object (not `@Published` here, so mutating it never invalidates the panel) observed
    /// only by the views that draw it. See `MeterState`.
    let meters = MeterState()

    private var recorder: ProcessTapRecorder?
    private var timer: Timer?
    private var startDate: Date?
    /// Serializes every blocking Core Audio lifecycle op (start / stop / reroute / device
    /// enumeration) OFF the main thread, so a wedged audio server can never beachball the UI.
    private let audioQueue = DispatchQueue(label: "com.nfl.soundrecorder.control", qos: .userInitiated)
    /// Bumped on every start/stop so an in-flight async start whose result lands after the
    /// user already stopped (or restarted) is torn down instead of applied.
    private var lifecycleGeneration = 0
    /// Coalesces overlapping refreshes when the menu is opened rapidly.
    private var isRefreshing = false
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

    init() {
        // Warm up the Core Audio HAL on the MAIN thread. The HAL's one-time bootstrap
        // (HALSystem::InitializeDevices) must run on the main thread's run loop; if the very
        // first HAL access instead happens on a background queue — as our off-main `refresh()`
        // enumeration otherwise would — it deadlocks in semaphore_wait and the device/source
        // lists never populate. Touching it once here (init runs on the main actor at launch)
        // guarantees all later off-main enumeration/teardown hits an already-initialized HAL.
        _ = try? AudioSystem.defaultOutputDevice()

        // Restore persisted preferences. (Assignments in init don't fire the didSet
        // observers, so this loads without immediately re-saving.)
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Prefs.format), let f = RecordingFormat(rawValue: raw) {
            recordingFormat = f
        }
        if d.object(forKey: Prefs.mute) != nil { mute = d.bool(forKey: Prefs.mute) }
        if d.object(forKey: Prefs.eqEnabled) != nil { eqEnabled = d.bool(forKey: Prefs.eqEnabled) }
        if let g = d.array(forKey: Prefs.eqGains) as? [Double], g.count == eqGains.count { eqGains = g }
        if d.object(forKey: Prefs.recordLevel) != nil { recordLevelDB = d.double(forKey: Prefs.recordLevel) }
        if d.object(forKey: Prefs.sourceLevel) != nil { sourceLevelDB = d.double(forKey: Prefs.sourceLevel) }
        if d.object(forKey: Prefs.micLevel) != nil { micLevelDB = d.double(forKey: Prefs.micLevel) }
        if let p = d.string(forKey: Prefs.recordingsDir), !p.isEmpty {
            recordingsDirectory = URL(fileURLWithPath: p, isDirectory: true)
        }
    }

    /// Rebuild the source + device lists (call whenever the menu opens). The blocking HAL
    /// enumeration — per-device and per-process property queries — runs off the main thread
    /// so a wedged audio server can't freeze the menu; results are published back on main.
    func refresh() {
        guard !isRefreshing else { return }   // coalesce rapid re-opens
        isRefreshing = true
        audioQueue.async { [weak self] in
            let outputs = try? AudioSystem.outputDevices()
            let defaultOut = try? AudioSystem.defaultOutputDevice()
            let inputs = (try? AudioSystem.inputDevices()) ?? []
            let catalog = AudioProcesses.catalog()
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyEnumeration(outputs: outputs, defaultOut: defaultOut,
                                      inputs: inputs, catalog: catalog)
                self.isRefreshing = false
            }
        }
    }

    /// Publish freshly-enumerated devices/sources and reconcile the current selections.
    /// Runs on the main actor; icon lookup (`NSRunningApplication`) is main-affine.
    private func applyEnumeration(outputs: [AudioDeviceInfo]?, defaultOut: AudioObjectID?,
                                  inputs: [AudioDeviceInfo], catalog: AudioSourceCatalog) {
        if let outputs {
            devices = outputs
            // Keep an explicit "record only" choice; otherwise fall back to a real device.
            if selectedDeviceUID.isEmpty
                || (selectedDeviceUID != Self.noRouteUID
                    && !outputs.contains(where: { $0.uid == selectedDeviceUID })) {
                selectedDeviceUID = outputs.first(where: { $0.id == defaultOut })?.uid
                    ?? outputs.first?.uid ?? ""
            }
        } else {
            lastError = "Could not enumerate output devices."
        }

        // Input devices (microphones). Keep the "off" choice; drop a stale device.
        inputDevices = inputs
        if selectedMicUID != Self.micOffUID
            && !inputs.contains(where: { $0.uid == selectedMicUID }) {
            selectedMicUID = Self.micOffUID
        }

        var options: [SourceOption] = [
            SourceOption(
                id: "system",
                label: "All System Audio",
                icon: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil),
                isTap: true,
                makeTarget: { .systemWide }
            ),
            SourceOption(
                id: Self.micOnlySourceID,
                label: "None — microphone only",
                icon: NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: nil),
                isTap: false,
                makeTarget: { nil }
            )
        ]
        // One row per Dock application; its audio helpers (browser renderers etc.)
        // are folded in and tapped as a group at record time — re-resolved then,
        // because helpers can spawn between menu-open and Record.
        for app in catalog.apps {
            let pid = app.pid
            let bundleID = app.bundleID
            options.append(SourceOption(
                id: bundleID,
                label: app.isPlaying ? "\(app.name) — playing" : app.name,
                icon: NSRunningApplication(processIdentifier: pid)?.icon,
                isTap: true,
                makeTarget: { .pids(AudioProcesses.app(matching: bundleID)?.tapPIDs ?? [pid]) }
            ))
        }
        // A daemon earns a row only while it is audibly producing output; idle
        // HAL registrants (mediaremoted, corespeechd, …) stay hidden. So do we:
        // while routing, our own output "plays", but we must never tap ourselves.
        for daemon in catalog.daemons where daemon.isPlaying && daemon.pid != getpid() {
            let pid = daemon.pid
            options.append(SourceOption(
                id: "daemon:\(daemon.bundleID):\(pid)",
                label: "\(daemon.name) — playing",
                icon: NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil),
                isTap: true,
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

        let url = newFileURL(format: recordingFormat)
        let rec = ProcessTapRecorder(source: captureSource, outputDevice: device, fileURL: url,
                                     format: recordingFormat, mute: mute,
                                     driftCompensation: false)

        // Optimistic UI: flip to "recording" immediately so the menu stays responsive; the
        // blocking HAL start runs off-main below and confirms (or reverts) when it returns.
        lifecycleGeneration += 1
        let gen = lifecycleGeneration
        recordingSourceLabel = sourceLabel
        lastFileURL = url
        startDate = nil          // set on confirmation so the elapsed clock starts at 0
        pausedAt = nil; pausedTotal = 0; isPaused = false
        meters.elapsedText = "00:00"
        isRecording = true
        statusText = "Starting…"

        // Snapshot the live settings to apply once the pipeline is up.
        let gains = eqGains, eqOn = eqEnabled
        let recDB = recordLevelDB, srcDB = sourceLevelDB, micDB = micLevelDB
        let q = audioQueue

        q.async { [weak self] in
            let result = Result { try rec.start() }
            if case .success = result {
                rec.equalizer.setGains(gains)
                rec.equalizer.setEnabled(eqOn)
                rec.setRecordGain(dB: recDB)
                rec.setSourceGain(dB: srcDB)
                rec.setMicGain(dB: micDB)
            }
            Task { @MainActor in
                guard let self else { q.async { rec.stop() }; return }
                // Superseded (user stopped or restarted while starting): discard this one.
                guard gen == self.lifecycleGeneration else { q.async { rec.stop() }; return }
                switch result {
                case .success:
                    self.recorder = rec
                    self.startDate = Date()
                    self.updateRecordingStatus(device: device)
                    self.startTickTimer()
                case .failure(let error):
                    self.isRecording = false
                    self.lastError = "\(error)"
                    self.statusText = "Idle"
                    // start() tears itself down on throw — nothing to stop here.
                }
            }
        }
    }

    /// Start the 30 Hz UI tick. Scheduled in `.common` mode so it keeps firing while the
    /// menu-bar popover is open (default-mode timers are paused during that tracking loop).
    private func startTickTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // This timer is installed on RunLoop.main, so execute the tick in the
            // callback. Enqueuing a MainActor Task here lets delayed UI work pile up
            // at 30 tasks per second; the backlog makes the meters lag and keeps CPU
            // busy long after the frame that created each task is useful.
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        lifecycleGeneration += 1      // invalidate any in-flight start
        let rec = recorder
        recorder = nil
        timer?.invalidate()
        timer = nil
        startDate = nil
        pausedAt = nil
        pausedTotal = 0
        isRecording = false
        isPaused = false
        meters.reset()
        let name = lastFileURL?.lastPathComponent ?? "recording"
        // Tear down off-main: rec.stop() blocks on Core Audio and flushes+closes the file.
        // The UI is already back to "stopped" so a wedged server can't beachball it.
        if let rec {
            statusText = "Saving \(name)…"
            audioQueue.async { [weak self] in
                rec.stop()
                Task { @MainActor in
                    // Only claim "Saved" if the user hasn't started a new recording since.
                    guard let self, !self.isRecording else { return }
                    self.statusText = "Saved \(name)."
                }
            }
        } else {
            // Nothing running yet (stop during "Starting…"); the in-flight start's
            // completion tears its recorder down via the generation check above.
            statusText = "Saved \(name)."
        }
    }

    /// Reroute the in-progress recording to the currently-selected device (or to
    /// record-only). Capture and file-writing continue uninterrupted across the change;
    /// the monitor teardown/rebuild runs off-main so the picker never blocks.
    private func applyRoutingChange() {
        let device: AudioDeviceInfo? = selectedDeviceUID == Self.noRouteUID
            ? nil
            : devices.first(where: { $0.uid == selectedDeviceUID })
        updateRecordingStatus(device: device)
        let rec = recorder
        audioQueue.async { rec?.setRoutingDevice(device) }
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
    ///
    /// Read from `body`, so it runs on every SwiftUI view update — which, while recording,
    /// is 30× a second as the meters publish. It must stay a cheap lookup: it used to call
    /// `makeTarget()`, which for an app source re-ran a full HAL process enumeration
    /// (a synchronous mach round-trip to coreaudiod per audio process) on the main thread.
    var sourceHasTap: Bool { sources.first(where: { $0.id == selectedSourceID })?.isTap ?? false }
    var sourceHasMic: Bool { selectedMic != nil }

    func revealLastFile() {
        guard let url = lastFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Publishes a meter frame. Every write lands on `meters`, never on `self`, so a frame
    /// invalidates only the cassette / meter / menu-bar-icon views rather than the whole panel.
    private func tick() {
        // Paused: hold the reels, meters, and clock where they are.
        guard !isPaused else { return }
        if let recorder {
            switch vizMode {
            case .bars:
                meters.bandLevels = recorder.spectrum.levels()
                meters.bandPeaks = recorder.spectrum.peakLevels()
            case .scope:
                let s = recorder.scope.snapshot()
                meters.scopeLeft = s.left
                meters.scopeRight = s.right
            }
        }
        // Smoothed live level (0...1) for the menu-bar icon's hub swell: map the
        // window's peak to a perceptual scale (dBFS over a −54 dB floor), then ease
        // toward it so the hub grows/shrinks smoothly instead of jittering.
        let peak = recorder?.meter.takePeak() ?? 0
        let target = peak > 0 ? max(0, min(1, (LevelMeter.dBFS(peak) + 54) / 54)) : 0
        // Assymmetric smoothing: snap up on transients, decay slowly like a VU meter.
        let ease = target > meters.iconLevel ? 0.6 : 0.15
        meters.iconLevel += (target - meters.iconLevel) * ease
        // Spin the reels at a *constant* rate — a real tape transport moves the tape at
        // a fixed speed regardless of the signal on it. Tying speed to level made the
        // reels surge and stall with the audio ("hurk-and-jerk"), so keep it steady.
        meters.iconAngle = (meters.iconAngle + 6).truncatingRemainder(dividingBy: 360)
        guard let startDate else { return }
        let seconds = Int(Date().timeIntervalSince(startDate) - pausedTotal)
        meters.elapsedText = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func newFileURL(format: RecordingFormat) -> URL {
        // Use the chosen directory, creating it if needed; fall back to the built-in default
        // if that folder can't be created (e.g. it was deleted or is no longer writable).
        var dir = recordingsDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            let fallback = Self.defaultRecordingsDirectory
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            lastError = "Couldn't use \(dir.path) — saving to \(fallback.path) instead."
            dir = fallback
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return dir.appendingPathComponent("Recording \(formatter.string(from: Date())).\(format.fileExtension)")
    }

    /// Present a folder picker for the recordings location. Runs modally on the main thread;
    /// the choice is persisted via `recordingsDirectory`'s observer.
    func chooseRecordingsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsDirectory
        panel.prompt = "Choose"
        panel.message = "Choose where TapDeck saves recordings"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            recordingsDirectory = url
        }
    }

    /// Reset the recordings location to the built-in default (~/Music/TapDeck).
    func resetRecordingsDirectory() {
        recordingsDirectory = Self.defaultRecordingsDirectory
    }

    /// Open the recordings folder in Finder.
    func revealRecordingsDirectory() {
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([recordingsDirectory])
    }
}

/// UserDefaults-backed persistence for the menu-bar app's preferences, so the chosen format
/// (and EQ / mute / feed levels) survive relaunch instead of silently resetting to defaults.
/// Loaded in `RecordingController.init`; written from each property's `didSet`.
private enum Prefs {
    static let format = "recordingFormat"
    static let mute = "mute"
    static let eqEnabled = "eqEnabled"
    static let eqGains = "eqGains"
    static let recordLevel = "recordLevelDB"
    static let sourceLevel = "sourceLevelDB"
    static let micLevel = "micLevelDB"
    static let recordingsDir = "recordingsDirectory"
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
