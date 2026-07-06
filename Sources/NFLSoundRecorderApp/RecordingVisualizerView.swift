import SwiftUI
import SoundRecorderKit

/// The "recording in progress" panel: a skeuomorphic cassette above a 10-band LED
/// spectrum meter driven by the live (post-EQ) audio stream.
struct RecordingVisualizerView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(spacing: 8) {
            CassetteView(elapsed: controller.elapsedText, angle: controller.iconAngle)

            TransportSelector(mode: $controller.vizMode)

            switch controller.vizMode {
            case .bars:
                LEDSpectrumView(levels: controller.bandLevels, peaks: controller.bandPeaks)
            case .scope:
                LissajousView(left: controller.scopeLeft, right: controller.scopeRight)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.88)))
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

// MARK: - Lissajous vectorscope

/// Lissajous / goniometer display: plots the stereo field as an X-Y phase trace
/// (not a time-domain waveform). Left and right are rotated 45° so a mono signal
/// draws a vertical line, hard-panned content leans along the L/R diagonals, and
/// stereo width opens the figure horizontally. Peak-normalized every frame so *any*
/// audible signal fills the screen regardless of absolute level — quiet or cranked.
struct LissajousView: View {
    let left: [Float]
    let right: [Float]

    private let green = Color(red: 0.25, green: 1.0, blue: 0.45)
    private let cyan = Color(red: 0.15, green: 0.85, blue: 1.0)

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cx = w / 2, cy = h / 2
            let r = min(w, h) / 2 - 2        // square plotting radius

            // Graticule: crosshair through the middle marking the L/R + mono axes.
            var grid = Path()
            grid.move(to: CGPoint(x: cx, y: cy - r)); grid.addLine(to: CGPoint(x: cx, y: cy + r))
            grid.move(to: CGPoint(x: cx - r, y: cy)); grid.addLine(to: CGPoint(x: cx + r, y: cy))
            ctx.stroke(grid, with: .color(.white.opacity(0.10)), lineWidth: 1)

            let n = min(left.count, right.count)
            guard n > 1 else { return }

            // Peak-normalize across both channels. The rotated sum/diff can reach
            // √2·peak, so divide that out to keep the figure inside the graticule.
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, max(abs(left[i]), abs(right[i]))) }
            guard peak > 0.0002 else { return } // effectively silent → just the crosshair
            let norm = CGFloat(0.92) * r / (CGFloat(peak) * CGFloat(2.0).squareRoot())

            // Rotate 45°: x = (L − R), y = (L + R). Mono (L=R) → vertical line.
            var path = Path()
            var first = true
            for i in 0..<n {
                let l = CGFloat(left[i]), rr = CGFloat(right[i])
                let x = cx + (l - rr) * norm
                let y = cy - (l + rr) * norm
                let pt = CGPoint(x: x, y: y)
                if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
            }
            // Layered strokes: cyan halo → green mid → bright green core (phosphor look).
            ctx.stroke(path, with: .color(cyan.opacity(0.18)), lineWidth: 5)
            ctx.stroke(path, with: .color(green.opacity(0.40)), lineWidth: 2.2)
            ctx.stroke(path, with: .color(green.opacity(0.95)), lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                        Circle().fill(.red).frame(width: 6, height: 6)
                            .shadow(color: .red.opacity(0.8), radius: 2)
                        Text("REC \(elapsed)")
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

/// Compact cassette for the menu bar: reels spin while recording, static otherwise.
/// Rendered to a template NSImage (see MenuBarIconRenderer) rather than used directly.
struct MenuBarCassetteIcon: View {
    var isRecording: Bool
    var angle: Double

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
        ZStack {
            Circle().stroke(Color.black, lineWidth: 1).frame(width: 6, height: 6)
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
    static func image(isRecording: Bool, angle: Double) -> NSImage {
        let renderer = ImageRenderer(content:
            MenuBarCassetteIcon(isRecording: isRecording, angle: angle)
                .frame(width: 20, height: 13)
                .padding(1)
        )
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 22, height: 15))
        image.isTemplate = true // adapt to light/dark menu bar
        return image
    }
}
