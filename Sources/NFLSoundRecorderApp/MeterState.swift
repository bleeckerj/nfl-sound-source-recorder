import Foundation
import SoundRecorderKit

/// The fast-changing half of the UI state: everything the 30 Hz tick rewrites.
///
/// Kept deliberately separate from `RecordingController`. The controller publishes the
/// panel's *configuration* — source/device lists with their per-app icons, the ten EQ
/// sliders, format, toggles — none of which changes while tape is rolling. The meters
/// change 30 times a second. When both lived on one object every meter frame fired the
/// controller's `objectWillChange`, so `MenuContentView.body` was re-evaluated and the
/// whole 320pt panel re-laid-out at 30 Hz; a `sample` of the running app showed the main
/// thread essentially parked in that body getter.
///
/// Splitting them means a meter frame only invalidates the views that actually observe
/// *this* object — the cassette, the LED/scope meter, and the menu-bar icon — while the
/// pickers and sliders above them are left alone.
@MainActor
final class MeterState: ObservableObject {
    @Published var bandLevels: [Float] = Array(repeating: 0, count: SpectrumMeter.bandCount)
    @Published var bandPeaks: [Float] = Array(repeating: 0, count: SpectrumMeter.bandCount)
    /// High-resolution analyzer curve and its peak-hold trace (0…1 per log-spaced point).
    @Published var spectrumCurve: [Float] = []
    @Published var spectrumPeaks: [Float] = []
    @Published var scopeLeft: [Float] = []
    @Published var scopeRight: [Float] = []
    /// Channel correlation of the window on screen (+1 mono/in-phase … −1 inverted).
    @Published var scopeCorrelation: Float = 0
    /// The capture has handed us bit-identical channels for long enough to say so: the
    /// source really is mono, and no display can draw a stereo figure from it.
    @Published var scopeIsMono = false
    /// Rotation (degrees) for the cassette reels; advances while recording.
    @Published var iconAngle: Double = 0
    /// Smoothed live audio level (0...1) driving the menu-bar icon's hub swell.
    @Published var iconLevel: Double = 0
    @Published var elapsedText = "00:00"

    /// Drop the meters back to rest on stop. The reel `iconAngle` is deliberately left
    /// where it stopped (the reels don't snap back on a real deck), and `elapsedText`
    /// keeps showing the final running time until the next recording starts.
    func reset() {
        bandLevels = Array(repeating: 0, count: SpectrumMeter.bandCount)
        bandPeaks = Array(repeating: 0, count: SpectrumMeter.bandCount)
        spectrumCurve = []
        spectrumPeaks = []
        scopeLeft = []
        scopeRight = []
        scopeCorrelation = 0
        scopeIsMono = false
        iconLevel = 0
    }
}
