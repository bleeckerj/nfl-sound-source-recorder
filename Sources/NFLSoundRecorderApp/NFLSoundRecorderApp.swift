import SwiftUI
import AppKit

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
                                                     angle: controller.iconAngle))
        }
        .menuBarExtraStyle(.window)

        // Tear-off: the same panel as a standalone, ordinary titled window.
        Window("NFL Sound Recorder", id: "panel") {
            MenuContentView(controller: controller)
                .frame(width: 320)
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
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

    var body: some View {
        if let maxContentHeight {
            // Hug the content when it fits; cap and scroll when it's taller than the screen.
            ScrollView {
                panel.background(GeometryReader { geo in
                    Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
                })
            }
            .frame(width: 320,
                   height: min(measuredHeight == 0 ? maxContentHeight : measuredHeight, maxContentHeight))
            .onPreferenceChange(PanelHeightKey.self) { measuredHeight = $0 }
        } else {
            panel
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.circle.fill").foregroundStyle(.tint)
                Text("NFL Sound Recorder").font(.headline)
                Spacer()
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
                Text("Route to").font(.caption).foregroundStyle(.secondary)
                Picker("Route to", selection: $controller.selectedDeviceUID) {
                    ForEach(controller.devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(controller.isRecording)
            }

            Toggle("Reroute (mute original output)", isOn: $controller.mute)
                .disabled(controller.isRecording)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Drift compensation (may add a startup level ramp)", isOn: $controller.driftCompensation)
                .disabled(controller.isRecording)
                .toggleStyle(.switch)
                .controlSize(.small)

            EqualizerView(controller: controller)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Record Level").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.0f dB", controller.recordLevelDB))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { controller.recordLevelDB },
                                      set: { controller.setRecordLevel($0) }),
                       in: -12...24, step: 1)
            }

            if controller.isRecording {
                RecordingVisualizerView(controller: controller)
            }

            HStack(spacing: 10) {
                Button(action: { controller.toggle() }) {
                    Label(controller.isRecording ? "Stop" : "Record",
                          systemImage: controller.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRecording ? .red : .accentColor)
                .controlSize(.large)

                if controller.isRecording {
                    Text(controller.elapsedText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

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
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { controller.refresh() }
    }
}

/// Compact 10-band graphic EQ: an enable toggle, a "Flat" reset, and one vertical
/// slider per ISO band.
struct EqualizerView: View {
    @ObservedObject var controller: RecordingController
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Equalizer", isOn: Binding(
                    get: { controller.eqEnabled },
                    set: { controller.setEQEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                Spacer()
                Button("Flat") { controller.flatEQ() }
                    .controlSize(.small)
                    .disabled(!controller.eqEnabled)
            }

            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<controller.eqGains.count, id: \.self) { band in
                    VStack(spacing: 2) {
                        Slider(
                            value: Binding(
                                get: { controller.eqGains[band] },
                                set: { controller.setEQ(band: band, dB: $0) }
                            ),
                            in: -12...12
                        )
                        .controlSize(.mini)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 60)
                        .frame(width: 26, height: 60)
                        Text(labels[band])
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(controller.eqEnabled ? 1 : 0.4)
            .disabled(!controller.eqEnabled)
        }
    }
}
