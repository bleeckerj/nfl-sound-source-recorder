import SwiftUI
import AppKit
import SoundRecorderKit

@main
struct NFLSoundRecorderApp: App {
    @StateObject private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra {
            // Cap the popover to the screen and let it scroll — the recording panel is
            // taller than a small display can show, which otherwise clips the bottom.
            MenuContentView(controller: controller,
                            maxContentHeight: (NSScreen.main?.visibleFrame.height ?? 760) - 16)
        } label: {
            // Rasterize the cassette to a template image — MenuBarExtra renders an
            // Image reliably, but not an arbitrary SwiftUI shape view (comes up blank).
            Image(nsImage: MenuBarIconRenderer.image(isRecording: controller.isRecording,
                                                     angle: controller.iconAngle,
                                                     level: controller.iconLevel))
        }
        .menuBarExtraStyle(.window)

        // Tear-off: the same panel as a standalone window, backed by a behind-window
        // material so it reads as frosted "glass" over the desktop like the popover.
        Window("TapDeck", id: "panel") {
            MenuContentView(controller: controller)
                .frame(width: 320)
                .fixedSize()
                .background(VisualEffectView().ignoresSafeArea())
                .background(TransparentWindow())
        }
        .windowResizability(.contentSize)
    }
}

/// A behind-window vibrancy material — the frosted glass that samples the desktop
/// and windows behind it. Needs a non-opaque host window (see `TransparentWindow`).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Punches the hosting window transparent so the behind-window blur shows through.
/// SwiftUI's `Window` scene hands its content an opaque, solid-backed window; this
/// reaches that window once it exists and clears its backing.
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Closes the MenuBarExtra `.window` popover so tearing off *hands off* the panel
/// instead of leaving both the popover and the floating window on screen.
@MainActor
func dismissMenuBarPopover() {
    for window in NSApp.windows
    where String(describing: type(of: window)).contains("MenuBarExtra") {
        window.close()
    }
}

/// Reports the natural height of the popover content so it can hug-or-scroll.
private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MenuContentView: View {
    @ObservedObject var controller: RecordingController
    /// When set (the menu-bar popover), the panel scrolls past this height instead of
    /// clipping. The tear-off window leaves it nil and sizes to its content.
    var maxContentHeight: CGFloat? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var measuredHeight: CGFloat = 0
    /// Flip state: false = front (the tape deck), true = back (settings).
    @State private var showingSettings = false

    var body: some View {
        if let maxContentHeight {
            // Hug the content when it fits; cap and scroll when it's taller than the screen.
            ScrollView {
                flipCard.background(GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                })
            }
            .frame(width: 320,
                   height: min(measuredHeight == 0 ? maxContentHeight : measuredHeight, maxContentHeight))
            .onPreferenceChange(PanelHeightKey.self) { measuredHeight = $0 }
        } else {
            flipCard
        }
    }

    /// The panel flips like a cassette: the deck on the front, settings on the back.
    private var flipCard: some View {
        ZStack {
            panel
                .opacity(showingSettings ? 0 : 1)
                .rotation3DEffect(.degrees(showingSettings ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .accessibilityHidden(showingSettings)
            settingsPanel
                .opacity(showingSettings ? 1 : 0)
                .rotation3DEffect(.degrees(showingSettings ? 0 : -180), axis: (x: 0, y: 1, z: 0))
                .accessibilityHidden(!showingSettings)
        }
        .animation(.easeInOut(duration: 0.45), value: showingSettings)
    }

    /// The "back side" — preferences. Currently the recordings save location; room to grow.
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    withAnimation { showingSettings = false }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to the deck")
                Text("Settings").font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Save recordings to").font(.caption).foregroundStyle(.secondary)
                // The chosen folder, truncating the middle so both the folder name and a
                // hint of its parent stay visible.
                Text((controller.recordingsDirectory.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

                HStack {
                    Button("Choose…") { controller.chooseRecordingsDirectory() }
                    Button("Reveal") { controller.revealRecordingsDirectory() }
                    Spacer()
                    Button("Default") { controller.resetRecordingsDirectory() }
                        .disabled(controller.recordingsDirectory == RecordingController.defaultRecordingsDirectory)
                }
                .controlSize(.small)

                Text("New recordings are written here. Existing files aren't moved.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "waveform.circle.fill").foregroundStyle(.tint)
                Text("TapDeck").font(.headline)
                Spacer()
                Button {
                    withAnimation { showingSettings = true }
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings — recordings folder")
                Button {
                    openWindow(id: "panel")
                    NSApp.activate(ignoringOtherApps: true)
                    // Hand off: close the popover so we don't leave both on screen.
                    DispatchQueue.main.async { dismissMenuBarPopover() }
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(.borderless)
                .help("Tear off into a floating window")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Record").font(.caption).foregroundStyle(.secondary)
                Picker("Record", selection: $controller.selectedSourceID) {
                    ForEach(controller.sources) { source in
                        if let icon = source.icon {
                            Label {
                                Text(source.label)
                            } icon: {
                                Image(nsImage: icon)
                            }.tag(source.id)
                        } else {
                            Text(source.label).tag(source.id)
                        }
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Microphone").font(.caption).foregroundStyle(.secondary)
                // Mixed into the recording alongside the Record source. The mic device is
                // fixed for the duration of a recording, so it's locked while recording.
                Picker("Microphone", selection: $controller.selectedMicUID) {
                    Text("Off").tag(RecordingController.micOffUID)
                    ForEach(controller.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Route to").font(.caption).foregroundStyle(.secondary)
                // Routing can be changed live, even mid-recording — see
                // RecordingController.applyRoutingChange.
                Picker("Route to", selection: $controller.selectedDeviceUID) {
                    Text("None (record only)").tag(RecordingController.noRouteUID)
                    ForEach(controller.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Format").font(.caption).foregroundStyle(.secondary)
                Picker("Format", selection: $controller.recordingFormat) {
                    ForEach(RecordingFormat.allCases, id: \.self) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording)
            }

            Toggle("Reroute (mute original output)", isOn: $controller.mute)
                // Nothing to reroute to when recording only.
                .disabled(controller.isRecording || controller.selectedDeviceUID == RecordingController.noRouteUID)
                .toggleStyle(.switch)
                .controlSize(.small)

            EqualizerView(controller: controller)

            // Per-feed balance: shown only when mixing a tap AND the mic, so you can dial
            // the two feeds against each other. The master "Record Level" is always below.
            if controller.sourceHasTap && controller.sourceHasMic {
                LevelSliderView(label: "Source Level",
                                value: controller.sourceLevelDB,
                                set: { controller.setSourceLevel($0) })
                LevelSliderView(label: "Mic Level",
                                value: controller.micLevelDB,
                                set: { controller.setMicLevel($0) })
            }

            LevelSliderView(label: "Record Level",
                            value: controller.recordLevelDB,
                            set: { controller.setRecordLevel($0) })

            // The tape deck — cassette, transport keys, and meters — is always
            // present; it just idles (static reels, dim meters) when not recording.
            RecordingVisualizerView(controller: controller)

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.lastFileURL != nil && !controller.isRecording {
                Button("Reveal Last Recording in Finder") { controller.revealLastFile() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            Divider()

            HStack {
                Button("Refresh") { controller.refresh() }
                    .controlSize(.small)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }

            // Signature line — the smallest of print.
            Text("A Near Future Laboratory Quality of Life Contrivance")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { controller.refresh() }
    }
}

/// A labelled dB level slider with a live read-out — used for the master Record Level
/// and the per-feed Source/Mic balance levels.
struct LevelSliderView: View {
    let label: String
    let value: Double
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.0f dB", value))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { set($0) }), in: -12...24, step: 1)
        }
    }
}

/// Compact 10-band graphic EQ: a header with a "Flat" reset, and one vertical
/// slider per ISO band. The EQ is always on, so there's no enable switch.
struct EqualizerView: View {
    @ObservedObject var controller: RecordingController
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Equalizer").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Flat") { controller.flatEQ() }
                    .controlSize(.mini)
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<controller.eqGains.count, id: \.self) { band in
                    VStack(spacing: 1) {
                        Slider(
                            value: Binding(
                                get: { controller.eqGains[band] },
                                set: { controller.setEQ(band: band, dB: $0) }
                            ),
                            in: -12...12
                        )
                        .controlSize(.mini)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 42)
                        .frame(width: 26, height: 42)
                        Text(labels[band])
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
