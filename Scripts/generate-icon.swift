// Renders the TapDeck app icon: a skeuomorphic compact audio cassette in the
// black-shell, cream-label style of the Walkman era (TDK D, Maxell, BASF).
//
// Draws the same vector artwork at every size macOS wants, so each rung of the
// iconset is crisp rather than a downscale. Small sizes drop fine detail (screws,
// hub teeth, label lines) so they don't turn to mush.
//
//   swift Scripts/generate-icon.swift <output.iconset-dir>
//
// The companion make-icon.sh runs this and folds the result into an .icns.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r / 255, g / 255, b / 255, a])!
}
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
func rrect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func circle(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2), transform: nil)
}

/// Draw the cassette into a flipped (y-down, origin top-left) context of side `S`.
func drawCassette(_ ctx: CGContext, _ S: CGFloat) {
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * S, y: y * S) }
    let detail = S >= 128        // screws, hub teeth, label lines
    let mid = S >= 64            // reel tape rings, bottom holes

    // Shell body — a black plastic rounded rectangle, slightly chunkier than a real
    // cassette so it fills the square icon grid. Soft ground shadow underneath.
    let shell = CGRect(x: 0.06 * S, y: 0.155 * S, width: 0.88 * S, height: 0.69 * S)
    let shellR = 0.052 * S

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.018 * S), blur: 0.05 * S,
                  color: rgb(0, 0, 0, 0.42))
    ctx.addPath(rrect(shell, shellR))
    ctx.setFillColor(rgb(20, 21, 24))
    ctx.fillPath()
    ctx.restoreGState()

    // Plastic gradient: light along the top edge falling to near-black at the base.
    ctx.saveGState()
    ctx.addPath(rrect(shell, shellR)); ctx.clip()
    ctx.drawLinearGradient(
        grad([rgb(86, 90, 97), rgb(45, 47, 52), rgb(16, 17, 20)], [0, 0.5, 1]),
        start: P(0, 0.155), end: P(0, 0.845), options: [])
    // Glossy sheen skimming the top third.
    ctx.addPath(rrect(CGRect(x: shell.minX, y: shell.minY,
                             width: shell.width, height: shell.height * 0.34),
                       shellR)); ctx.clip()
    ctx.drawLinearGradient(
        grad([rgb(255, 255, 255, 0.22), rgb(255, 255, 255, 0)], [0, 1]),
        start: P(0, 0.155), end: P(0, 0.42), options: [])
    ctx.restoreGState()

    // Crisp top highlight line + thin dark seam for edge definition.
    ctx.saveGState()
    ctx.addPath(rrect(shell.insetBy(dx: 0.006 * S, dy: 0.006 * S), shellR * 0.9))
    ctx.setStrokeColor(rgb(255, 255, 255, 0.10)); ctx.setLineWidth(max(1, 0.006 * S))
    ctx.strokePath()
    ctx.restoreGState()

    // Cream label filling the upper body. The two reel windows are cut through its
    // lower half, exactly as on a real tape.
    let label = CGRect(x: 0.135 * S, y: 0.205 * S, width: 0.73 * S, height: 0.40 * S)
    let labelR = 0.018 * S
    ctx.saveGState()
    ctx.addPath(rrect(label, labelR)); ctx.clip()
    ctx.drawLinearGradient(
        grad([rgb(249, 245, 235), rgb(232, 224, 205)], [0, 1]),
        start: P(0, 0.205), end: P(0, 0.605), options: [])
    // Coloured header stripes — the classic TDK red band over a thin navy rule.
    let stripe = CGRect(x: label.minX, y: label.minY, width: label.width, height: 0.052 * S)
    ctx.setFillColor(rgb(184, 38, 34)); ctx.fill(stripe)
    ctx.setFillColor(rgb(30, 54, 92))
    ctx.fill(CGRect(x: label.minX, y: stripe.maxY, width: label.width, height: 0.014 * S))
    // A couple of faint "writing" rules on the label (large sizes only).
    if detail {
        ctx.setStrokeColor(rgb(90, 84, 70, 0.35)); ctx.setLineWidth(0.006 * S)
        for ly in [CGFloat(0.31), 0.345] {
            ctx.move(to: P(0.18, ly)); ctx.addLine(to: P(0.82, ly)); ctx.strokePath()
        }
    }
    ctx.restoreGState()
    // Label edge.
    ctx.addPath(rrect(label, labelR))
    ctx.setStrokeColor(rgb(120, 112, 96, 0.5)); ctx.setLineWidth(max(0.8, 0.004 * S)); ctx.strokePath()

    // Reel windows + hubs. Left reel wound fuller than the right, mid-play.
    let reelY: CGFloat = 0.52
    let winR: CGFloat = 0.118 * S
    let hubR: CGFloat = 0.048 * S
    for (cx, tapeR) in [(CGFloat(0.345), 0.092 * S), (CGFloat(0.655), 0.066 * S)] {
        let c = P(cx, reelY)
        // Window recess — dark, radial so it reads as a hole under clear plastic.
        ctx.saveGState()
        ctx.addPath(circle(c.x, c.y, winR)); ctx.clip()
        ctx.drawRadialGradient(
            grad([rgb(58, 60, 64), rgb(10, 11, 13)], [0, 1]),
            startCenter: CGPoint(x: c.x - winR * 0.3, y: c.y - winR * 0.3), startRadius: 0,
            endCenter: c, endRadius: winR, options: [])
        ctx.restoreGState()
        // Clear-plastic rim highlight around the window.
        ctx.addPath(circle(c.x, c.y, winR))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.14)); ctx.setLineWidth(max(1, 0.007 * S)); ctx.strokePath()

        // Wound tape pack.
        if mid {
            ctx.saveGState()
            ctx.addPath(circle(c.x, c.y, tapeR)); ctx.clip()
            ctx.drawRadialGradient(
                grad([rgb(58, 42, 28), rgb(28, 19, 12)], [0, 1]),
                startCenter: c, startRadius: hubR, endCenter: c, endRadius: tapeR, options: [])
            ctx.restoreGState()
        }

        // Hub: pale spindle with sprocket teeth and a dark centre.
        ctx.addPath(circle(c.x, c.y, hubR))
        ctx.setFillColor(rgb(206, 206, 210)); ctx.fillPath()
        if detail {
            ctx.setFillColor(rgb(70, 70, 74))
            let teeth = 6
            for i in 0..<teeth {
                let a = CGFloat(i) / CGFloat(teeth) * .pi * 2
                let tp = CGPoint(x: c.x + cos(a) * hubR * 0.62, y: c.y + sin(a) * hubR * 0.62)
                ctx.addPath(circle(tp.x, tp.y, hubR * 0.2))
            }
            ctx.fillPath()
        }
        ctx.addPath(circle(c.x, c.y, hubR * (detail ? 0.42 : 0.5)))
        ctx.setFillColor(rgb(24, 24, 27)); ctx.fillPath()
    }

    // Bottom mechanism: the felt-pad / head window flanked by capstan holes, plus
    // two outer alignment holes along the lower edge.
    if mid {
        ctx.setFillColor(rgb(8, 9, 11))
        let padWin = CGRect(x: 0.435 * S, y: 0.735 * S, width: 0.13 * S, height: 0.066 * S)
        ctx.addPath(rrect(padWin, 0.01 * S)); ctx.fillPath()
        ctx.setFillColor(rgb(196, 150, 150))   // hint of the pressure-pad felt
        ctx.addPath(rrect(padWin.insetBy(dx: 0.028 * S, dy: 0.022 * S), 0.006 * S)); ctx.fillPath()
        ctx.setFillColor(rgb(8, 9, 11))
        for hx in [CGFloat(0.40), 0.60] { ctx.addPath(circle(hx * S, 0.775 * S, 0.017 * S)) }
        for hx in [CGFloat(0.205), 0.795] { ctx.addPath(circle(hx * S, 0.79 * S, 0.013 * S)) }
        ctx.fillPath()
    }

    // Corner screws — a metallic pip with a slot.
    if detail {
        let inset: CGFloat = 0.05
        for (sx, sy) in [(0.06 + inset, 0.155 + inset * 1.4), (0.94 - inset, 0.155 + inset * 1.4),
                         (0.06 + inset, 0.845 - inset * 1.4), (0.94 - inset, 0.845 - inset * 1.4)] {
            let c = P(sx, sy); let r = 0.022 * S
            ctx.saveGState()
            ctx.addPath(circle(c.x, c.y, r)); ctx.clip()
            ctx.drawRadialGradient(
                grad([rgb(150, 152, 156), rgb(70, 72, 76)], [0, 1]),
                startCenter: CGPoint(x: c.x - r * 0.4, y: c.y - r * 0.4), startRadius: 0,
                endCenter: c, endRadius: r, options: [])
            ctx.restoreGState()
            ctx.addPath(circle(c.x, c.y, r))
            ctx.setStrokeColor(rgb(0, 0, 0, 0.5)); ctx.setLineWidth(0.004 * S); ctx.strokePath()
            ctx.setStrokeColor(rgb(30, 30, 33)); ctx.setLineWidth(0.006 * S)
            ctx.move(to: CGPoint(x: c.x - r * 0.55, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r * 0.55, y: c.y))
            ctx.strokePath()
        }
    }
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)   // flip to y-down
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    drawCassette(ctx, CGFloat(px))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: generate-icon.swift <output.iconset-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let rungs: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"),
    (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"),
    (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]
for (px, name) in rungs {
    writePNG(render(px), outDir.appendingPathComponent("icon_\(name).png"))
}
print("✓ wrote \(rungs.count) images to \(outDir.path)")
