import Foundation

/// Shared, lightweight level/throughput meter written from the real-time audio
/// thread and read from a control thread (UI or CLI poll loop).
///
/// The reads/writes race by design — a stale peak value is harmless for a meter,
/// so this avoids taking any lock on the audio thread. `@unchecked Sendable`
/// documents that we've accepted the benign race deliberately.
public final class LevelMeter: @unchecked Sendable {
    /// Peak absolute sample seen since the reader last reset it (linear, 0...1+).
    public var peak: Float = 0
    /// Largest peak seen for the whole session (never reset) — the "did we ever
    /// capture any signal?" answer.
    public var maxPeak: Float = 0
    /// Total frames delivered by the tap since recording started.
    public var totalFrames: UInt64 = 0

    public init() {}

    /// Read the current peak and reset it, so each poll reflects one window.
    public func takePeak() -> Float {
        let value = peak
        peak = 0
        return value
    }

    /// Peak expressed in dBFS (−inf for pure silence).
    public static func dBFS(_ linear: Float) -> Double {
        linear > 0 ? 20 * log10(Double(linear)) : -.infinity
    }
}
