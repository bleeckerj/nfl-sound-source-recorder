import SwiftUI
import SoundRecorderKit

/// The "recording in progress" panel: a skeuomorphic cassette above a 10-band LED
/// spectrum meter driven by the live (post-EQ) audio stream.
///
/// This view observes only the *controller*, so it is re-evaluated when the transport
/// state changes — not per meter frame. The two pieces that do animate at 30 Hz
/// (`CassetteDisplay`, `MeterDisplay`) observe `MeterState` themselves, which confines
/// each frame's invalidation to them instead of the enclosing panel.
struct RecordingVisualizerView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(spacing: 8) {
            CassetteDisplay(meters: controller.meters,
                            isRecording: controller.isRecording,
                            isPaused: controller.isPaused)

            // Physical transport keys — the primary record controls.
            DeckTransport(controller: controller)

            TransportSelector(mode: $controller.vizMode)

            MeterDisplay(meters: controller.meters, mode: controller.vizMode)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.88)))
    }
}

/// Wraps the cassette so the spinning reels and the running clock redraw on their own.
private struct CassetteDisplay: View {
    @ObservedObject var meters: MeterState
    let isRecording: Bool
    let isPaused: Bool

    var body: some View {
        CassetteView(elapsed: meters.elapsedText,
                     angle: meters.iconAngle,
                     isRecording: isRecording,
                     isPaused: isPaused)
    }
}

/// Wraps the active meter so its 30 Hz redraw doesn't reach the panel around it.
private struct MeterDisplay: View {
    @ObservedObject var meters: MeterState
    let mode: VizMode

    var body: some View {
        switch mode {
        case .bars:
            LEDSpectrumView(levels: meters.bandLevels, peaks: meters.bandPeaks)
        case .scope:
            LissajousScopeView(left: meters.scopeLeft, right: meters.scopeRight)
        }
    }
}

// MARK: - Tape-deck transport selector

/// Chunky always-visible mode keys styled like a cassette deck's transport buttons
/// (BARS / SCOPE), with an LED that lights on the selected one. Replaces the macOS
/// segmented control, which read as invisible against the black panel.
struct TransportSelector: View {
    @Binding var mode: VizMode

    var body: some View {
        HStack(spacing: 6) {
            ForEach(VizMode.allCases) { m in
                TransportKey(title: m.rawValue.uppercased(),
                             selected: mode == m) { mode = m }
            }
        }
    }
}

struct TransportKey: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    private let led = Color(red: 0.2, green: 1.0, blue: 0.45)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(selected ? led : Color(white: 0.28))
                    .frame(width: 6, height: 6)
                    .shadow(color: selected ? led.opacity(0.9) : .clear, radius: 3)
                Text(title)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(selected ? .white : Color(white: 0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(keycap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Raised plastic key that visually depresses when selected.
    private var keycap: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(
                colors: selected ? [Color(white: 0.10), Color(white: 0.20)]   // pressed in
                                 : [Color(white: 0.34), Color(white: 0.22)],  // raised
                startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(selected ? 0.05 : 0.16), lineWidth: 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.black.opacity(0.6), lineWidth: 0.5).blur(radius: 0.5))
            .shadow(color: selected ? .clear : .black.opacity(0.5),
                    radius: selected ? 0 : 1.5, y: selected ? 0 : 1)
    }
}

// MARK: - Tape-deck transport controls (Record / Pause / Stop)

/// The main recording controls, styled as a physical deck's mechanical transport
/// keys. Keys latch down when engaged (REC while recording, PAUSE while paused) and
/// pop back up on STOP — mirroring how a real cassette deck's interlocked keys move.
struct DeckTransport: View {
    @ObservedObject var controller: RecordingController

    private let recRed = Color(red: 1.0, green: 0.25, blue: 0.2)
    private let amber = Color(red: 1.0, green: 0.72, blue: 0.2)

    var body: some View {
        HStack(spacing: 8) {
            DeckButton(systemImage: "record.circle.fill", label: "REC", tint: recRed,
                       engaged: controller.isRecording && !controller.isPaused,
                       enabled: !controller.isRecording && controller.speakerModeSelectionError == nil) {
                controller.start()
            }
            DeckButton(systemImage: "pause.fill", label: "PAUSE", tint: amber,
                       engaged: controller.isPaused,
                       enabled: controller.isRecording) {
                controller.togglePause()
            }
            DeckButton(systemImage: "stop.fill", label: "STOP", tint: Color(white: 0.85),
                       engaged: !controller.isRecording,
                       enabled: controller.isRecording) {
                controller.stop()
            }
        }
    }
}

/// A single chunky, piano-key style transport button. `engaged` latches it into the
/// pressed-down state with a lit indicator; `enabled` gates whether it can be pressed.
struct DeckButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    let engaged: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // Status LED — lit in the button's tint while engaged.
                Circle()
                    .fill(engaged ? tint : Color(white: 0.24))
                    .frame(width: 5, height: 5)
                    .shadow(color: engaged ? tint.opacity(0.9) : .clear, radius: 3)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(engaged ? tint : Color(white: 0.78))
                    .shadow(color: engaged ? tint.opacity(0.7) : .clear, radius: 3)
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(engaged ? tint.opacity(0.9) : Color(white: 0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(keycap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // Raised plastic key that visually depresses (inset, darker) when engaged.
    private var keycap: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(LinearGradient(
                colors: engaged ? [Color(white: 0.09), Color(white: 0.17)]   // pressed in
                                : [Color(white: 0.36), Color(white: 0.23)],  // raised
                startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(engaged ? 0.04 : 0.16), lineWidth: 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.black.opacity(0.6), lineWidth: 0.5).blur(radius: 0.5))
            .shadow(color: engaged ? .clear : .black.opacity(0.5),
                    radius: engaged ? 0 : 2, y: engaged ? 0 : 1.5)
    }
}

// MARK: - Oscilloscope

/// Stereo X/Y oscilloscope: the left channel drives X and the right channel drives Y,
/// producing the geometric figure made by two simultaneous signals. A mono signal
/// naturally collapses toward the diagonal, while phase and stereo relationships draw
/// the characteristic ellipses, loops, and more complex Lissajous figures.
///
/// Built from retained `Shape`s rather than a `Canvas`. `Canvas` was the original
/// implementation and drew nothing here: it is an immediate-mode surface that only
/// repaints when its host gives it a display pass, and the `MenuBarExtra(.window)`
/// popover this panel lives in does not reliably do that. It was also the *only*
/// `Canvas` in the app, which is why the scope was the only meter that stayed blank
/// while the LED bars beside it — plain `Shape`s — animated normally.
struct LissajousScopeView: View {
    let left: [Float]
    let right: [Float]

    private let green = Color(red: 0.25, green: 1.0, blue: 0.45)
    private let cyan = Color(red: 0.15, green: 0.85, blue: 1.0)

    var body: some View {
        ZStack {
            // Oscilloscope graticule: center axes, quarter divisions, and a circular
            // plotting boundary make the X/Y relationship legible without labels.
            ScopeGraticule()
                .stroke(Color.white.opacity(0.10), lineWidth: 1)

            // Layered strokes: cyan halo -> green mid -> bright green core (phosphor look).
            ScopeTrace(left: left, right: right)
                .stroke(cyan.opacity(0.18), lineWidth: 5)
            ScopeTrace(left: left, right: right)
                .stroke(green.opacity(0.40), lineWidth: 2.2)
            ScopeTrace(left: left, right: right)
                .stroke(green.opacity(0.95), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The fixed graticule. Kept as its own `Shape` so it is not rebuilt with every meter
/// frame the way the trace is.
private struct ScopeGraticule: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.43
        var p = Path()
        p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2))
        p.addEllipse(in: CGRect(x: center.x - radius * 0.5, y: center.y - radius * 0.5,
                                width: radius, height: radius))
        p.move(to: CGPoint(x: center.x - radius, y: center.y))
        p.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        p.move(to: CGPoint(x: center.x, y: center.y - radius))
        p.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        for fraction: CGFloat in [-0.5, 0.5] {
            let x = center.x + radius * fraction
            let y = center.y + radius * fraction
            p.move(to: CGPoint(x: x, y: center.y - 3))
            p.addLine(to: CGPoint(x: x, y: center.y + 3))
            p.move(to: CGPoint(x: center.x - 3, y: y))
            p.addLine(to: CGPoint(x: center.x + 3, y: y))
        }
        return p
    }
}

/// The live trace: successive (left, right) sample pairs joined into a single path, which
/// is what turns a pile of samples into the figure rather than a scatter of dots.
private struct ScopeTrace: Shape {
    let left: [Float]
    let right: [Float]

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = min(left.count, right.count)
        guard n > 1 else { return p }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) * 0.43

        // Auto-scale the current window while preserving the left/right amplitude
        // relationship, so a quiet passage still draws a full-size figure instead of a
        // dot at the origin. Below the floor there is nothing meaningful to draw.
        var peak: Float = 0
        for i in 0..<n {
            peak = max(peak, max(abs(left[i]), abs(right[i])))
        }
        guard peak > 0.0002 else { return p }
        let scale = radius / CGFloat(peak)

        // X is left; Y is right, with screen Y inverted for Cartesian orientation.
        for i in 0..<n {
            let x = center.x + CGFloat(left[i]) * scale
            let y = center.y - CGFloat(right[i]) * scale
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

// MARK: - LED spectrum meter

struct LEDSpectrumView: View {
    let levels: [Float]
    let peaks: [Float]
    private let segments = 12
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(levels.indices, id: \.self) { band in
                    let peakSeg = peaks.indices.contains(band) && peaks[band] > 0.02
                        ? min(segments - 1, Int(peaks[band] * Float(segments)))
                        : -1
                    VStack(spacing: 2) {
                        ForEach((0..<segments).reversed(), id: \.self) { seg in
                            segmentView(on: Float(seg) / Float(segments) < levels[band],
                                        isPeak: seg == peakSeg,
                                        index: seg)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(labels.indices, id: \.self) { i in
                    Text(labels[i])
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func segmentView(on: Bool, isPeak: Bool, index: Int) -> some View {
        let color = segmentColor(index)
        // Peak-hold cap: a bright floating segment, lit even when the bar has fallen.
        let lit = on || isPeak
        let fill = isPeak ? color.opacity(0.95) : (on ? color : color.opacity(0.10))
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(fill)
            .frame(height: 6)
            .frame(maxWidth: .infinity)
            .shadow(color: lit ? color.opacity(0.9) : .clear, radius: lit ? 2.5 : 0)
    }

    private func segmentColor(_ index: Int) -> Color {
        let f = Double(index) / Double(segments)
        if f > 0.82 { return Color(red: 1.0, green: 0.23, blue: 0.19) }
        if f > 0.58 { return Color(red: 1.0, green: 0.80, blue: 0.0) }
        return Color(red: 0.20, green: 0.90, blue: 0.35)
    }
}

// MARK: - Skeuomorphic cassette

struct CassetteView: View {
    let elapsed: String
    let angle: Double
    var isRecording: Bool = false
    var isPaused: Bool = false

    // Indicator lamp + label reflect the transport state.
    private var lampColor: Color {
        if isPaused { return Color(red: 1.0, green: 0.72, blue: 0.2) }   // amber
        if isRecording { return .red }
        return Color(white: 0.35)                                        // idle: dark
    }
    private var statusWord: String {
        if isPaused { return "PAUSE" }
        if isRecording { return "REC" }
        return "STOP"
    }

    var body: some View {
        ZStack {
            // Smoky translucent shell.
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.14)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.black.opacity(0.5), lineWidth: 0.5).blur(radius: 0.5))

            VStack(spacing: 6) {
                // Label with brand + running time.
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color(red: 0.90, green: 0.85, blue: 0.68),
                                                      Color(red: 0.82, green: 0.75, blue: 0.55)],
                                             startPoint: .top, endPoint: .bottom))
                    HStack(spacing: 6) {
                        Circle().fill(lampColor).frame(width: 6, height: 6)
                            .shadow(color: isRecording && !isPaused ? lampColor.opacity(0.8) : .clear, radius: 2)
                        Text("\(statusWord) \(elapsed)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.black.opacity(0.75))
                        Spacer()
                        Text("NFL").font(.system(size: 8, weight: .heavy, design: .rounded))
                            .foregroundStyle(.black.opacity(0.55))
                        Text("· TYPE I").font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.black.opacity(0.4))
                    }
                    .padding(.horizontal, 8)
                }
                .frame(height: 18)

                // Twin reels with spooled tape, over a dark window.
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55))
                    HStack(spacing: 26) {
                        ReelHub(angle: angle, radius: 30)
                        ReelHub(angle: angle, radius: 30)
                    }
                    // Exposed tape along the bottom, connecting the reels.
                    Rectangle().fill(Color(white: 0.05))
                        .frame(height: 6)
                        .frame(maxWidth: .infinity)
                        .offset(y: 30)
                }
                .frame(height: 70)
                .padding(.horizontal, 6)
            }
            .padding(8)
        }
        .frame(height: 128)
        // Corner screws.
        .overlay(alignment: .topLeading) { screw.padding(6) }
        .overlay(alignment: .topTrailing) { screw.padding(6) }
        .overlay(alignment: .bottomLeading) { screw.padding(6) }
        .overlay(alignment: .bottomTrailing) { screw.padding(6) }
        // Bottom transport openings.
        .overlay(alignment: .bottom) {
            HStack(spacing: 16) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule().fill(.black.opacity(0.6)).frame(width: 7, height: 5)
                }
            }
            .padding(.bottom, 5)
        }
    }

    private var screw: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(white: 0.6), Color(white: 0.25)],
                                 center: .topLeading, startRadius: 0, endRadius: 6))
            .frame(width: 7, height: 7)
            .overlay(Rectangle().fill(.black.opacity(0.4)).frame(width: 4, height: 0.8))
    }
}

/// A cassette reel: static tape body + a rotating spool/hub with splined teeth.
struct ReelHub: View {
    let angle: Double
    let radius: CGFloat

    var body: some View {
        ZStack {
            // Wound tape.
            Circle().fill(RadialGradient(colors: [Color(white: 0.20), Color(white: 0.04)],
                                         center: .center, startRadius: radius * 0.22, endRadius: radius))
            // Rotating spool: texture marks + toothed hub.
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    Rectangle().fill(.white.opacity(0.05))
                        .frame(width: 1, height: radius * 0.7)
                        .offset(y: -radius * 0.35)
                        .rotationEffect(.degrees(Double(i) / 12 * 360))
                }
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(white: 0.82))
                        .frame(width: radius * 0.13, height: radius * 0.18)
                        .offset(y: -radius * 0.2)
                        .rotationEffect(.degrees(Double(i) / 6 * 360))
                }
                Circle().fill(Color(white: 0.9)).frame(width: radius * 0.44, height: radius * 0.44)
                Circle().fill(Color(white: 0.45)).frame(width: radius * 0.18, height: radius * 0.18)
            }
            .rotationEffect(.degrees(angle))
            // Clear window rim.
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 2)
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - Menu-bar icon

/// Compact cassette for the menu bar. While recording the reels spin at a steady rate
/// (like real tape transport) and the hub pulses with the live level, so the icon
/// reads as a level meter the way battery/wifi/bandwidth indicators do. Static idle.
/// Rendered to a template NSImage (see MenuBarIconRenderer) rather than used directly.
struct MenuBarCassetteIcon: View {
    var isRecording: Bool
    var angle: Double
    /// Live audio level (0...1); ignored when not recording.
    var level: Double = 0

    private var activeLevel: Double { isRecording ? max(0, min(1, level)) : 0 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(Color.black, lineWidth: 1.4)
                .frame(width: 19, height: 12)
            HStack(spacing: 4) {
                reel
                reel
            }
        }
        .frame(width: 20, height: 13)
    }

    private var reel: some View {
        // Hub swells from a thin ring toward a filled disc as the level rises — the
        // "how much signal" cue — while the spokes carry the spin.
        let hub = 1.8 + activeLevel * 2.6
        return ZStack {
            Circle().stroke(Color.black, lineWidth: 1).frame(width: 6, height: 6)
            Circle().fill(Color.black).frame(width: hub, height: hub)
            ForEach(0..<3, id: \.self) { i in
                Rectangle().fill(Color.black)
                    .frame(width: 1.2, height: 2.6)
                    .rotationEffect(.degrees(Double(i) / 3 * 360 + (isRecording ? angle : 0)))
            }
        }
    }
}

/// Rasterizes `MenuBarCassetteIcon` into a template NSImage for the menu bar.
@MainActor
enum MenuBarIconRenderer {
    static func image(isRecording: Bool, angle: Double, level: Double = 0) -> NSImage {
        let renderer = ImageRenderer(content:
            MenuBarCassetteIcon(isRecording: isRecording, angle: angle, level: level)
                .frame(width: 20, height: 13)
                .padding(1)
        )
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 22, height: 15))
        image.isTemplate = true // adapt to light/dark menu bar
        return image
    }
}
