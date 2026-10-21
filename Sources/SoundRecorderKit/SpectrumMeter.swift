import Foundation
import Accelerate
import AVFoundation
import os

/// Real-time 10-band spectrum analyzer. Fed the captured audio on the audio thread
/// (`ingest`), it runs a windowed FFT and bins the magnitudes into the same ISO
/// centre frequencies as the graphic EQ (32 Hz–16 kHz), so the UI can show one LED
/// column per band. Read the smoothed 0…1 levels from any thread via `levels()`.
public final class SpectrumMeter: @unchecked Sendable {

    public static let bandCount = 10
    /// ISO octave centres, matching GraphicEQ.
    public static let centerFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Points in the high-resolution analyzer curve. The ten LED bands are an octave
    /// apart — a level meter, not an analyzer — so the curve re-bins the same FFT onto a
    /// finer log-frequency axis, which is what makes a spectral shape (a vocal formant, a
    /// bass note, a cymbal) legible instead of an octave-wide smear.
    public static let curveResolution = 96
    /// Display bounds. Detail near the lower bound is limited by the FFT bin spacing.
    public static let curveLowHz: Float = 25
    public static let curveHighHz: Float = 20_000

    /// Centre frequency of each curve point, log-spaced across the span above.
    public static let curveFrequencies: [Float] = (0..<curveResolution).map { i in
        let t = Float(i) / Float(curveResolution - 1)
        return curveLowHz * powf(curveHighHz / curveLowHz, t)
    }

    /// The dBFS window the 0…1 level spans. The top is digital full scale, so the LEDs
    /// read as a real record-level meter: an operator can see both how much headroom is
    /// left and when a band is about to clip. (The old scale topped out at −30 dBFS,
    /// which pinned every band at full for anything louder than a whisper and made the
    /// Record Level fader look like it did nothing.)
    public static let floorDB: Float = -60
    public static let ceilingDB: Float = 0
    /// Below this the level snaps to exactly 0 so the display goes fully dark. Without it
    /// the geometric decay only ever approaches zero, leaving the bottom LED of every band
    /// lit forever after the first sound — which reads as "there's signal" during silence.
    private static let silenceFloor: Float = 0.004   // ≈ 0.25 dB of the scale

    /// `vDSP_hann_window(_:_:vDSP_HANN_NORM)` scales the window by √(8/3) so it preserves
    /// *power* — right for noise, but it leaves a coherent tone reading 4.26 dB hot. Take
    /// it back out so a full-scale sine lands on 0 dBFS. `--selftest-spectrum` checks this
    /// against a tone placed exactly on a bin centre (no scalloping loss to confuse it).
    private static let hannNormGainDB: Float = 20 * log10f((8.0 / 3.0).squareRoot())

    /// FFT size. 4096 points at 48 kHz puts the bins 11.7 Hz apart, which is what lets
    /// the analyzer curve separate low notes — at 2048 the whole bass register collapsed
    /// into two or three bins and drew as one flat plateau. The 85 ms window it implies is
    /// still short enough that the display tracks a beat.
    private let n = 4096
    private let half = 2048
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup

    private let window: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let mags: UnsafeMutablePointer<Float>

    private var sampleRate: Float = 48_000

    private struct BandState {
        var levels = [Float](repeating: 0, count: SpectrumMeter.bandCount)
        var peaks = [Float](repeating: 0, count: SpectrumMeter.bandCount)
        var curve = [Float](repeating: 0, count: SpectrumMeter.curveResolution)
        var curvePeaks = [Float](repeating: 0, count: SpectrumMeter.curveResolution)
    }
    private let stateLock = OSAllocatedUnfairLock(initialState: BandState())

    public init() {
        log2n = vDSP_Length(log2(Float(n)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: n)
        mono = .allocate(capacity: n); mono.initialize(repeating: 0, count: n)
        windowed = .allocate(capacity: n)
        realp = .allocate(capacity: half)
        imagp = .allocate(capacity: half)
        mags = .allocate(capacity: half)
        vDSP_hann_window(window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        for p in [window, mono, windowed, realp, imagp, mags] { p.deallocate() }
    }

    public func configure(sampleRate: Double) { self.sampleRate = Float(sampleRate) }

    /// Smoothed per-band levels (0…1), safe to call from the UI thread.
    public func levels() -> [Float] { stateLock.withLock { $0.levels } }

    /// Slowly-falling peak-hold per band (0…1) for floating cap segments.
    public func peakLevels() -> [Float] { stateLock.withLock { $0.peaks } }

    /// Smoothed high-resolution spectrum (0…1 per `curveFrequencies` point).
    public func curve() -> [Float] { stateLock.withLock { $0.curve } }

    /// Slowly-falling peak-hold trace over that curve.
    public func curvePeaks() -> [Float] { stateLock.withLock { $0.curvePeaks } }

    /// Reset to silence (e.g. when a recording stops).
    public func reset() { stateLock.withLock { $0 = BandState() } }

    // MARK: Audio thread

    public func ingest(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int,
                       gain: Float = 1) {
        guard frames > 0 else { return }
        let channels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return }
        let meterGain = gain.isFinite ? max(0, gain) : 1

        // Slide the newest samples into a rolling mono window.
        let take = min(frames, n)
        let keep = n - take
        if keep > 0 { memmove(mono, mono + take, keep * MemoryLayout<Float>.size) }
        let startFrame = frames - take
        for i in 0..<take { mono[keep + i] = 0 }
        // Average every channel regardless of how HAL groups the buffers. A mic
        // on input 2 must meter the same in planar and interleaved audio.
        for buffer in abl {
            let bufferChannels = Int(buffer.mNumberChannels)
            guard bufferChannels > 0, let data = buffer.mData else { continue }
            let src = data.assumingMemoryBound(to: Float.self)
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * bufferChannels)
            for i in 0..<take where startFrame + i < available {
                let base = (startFrame + i) * bufferChannels
                var sum: Float = 0
                for channel in 0..<bufferChannels { sum += src[base + channel] }
                mono[keep + i] += sum * meterGain / Float(channels)
            }
        }
        analyze()
    }

    private func analyze() {
        vDSP_vmul(mono, 1, window, 1, windowed, 1, vDSP_Length(n))

        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        imagp[0] = 0 // Nyquist packed into imag[0]; ignore for magnitudes.
        vDSP_zvmags(&split, 1, mags, 1, vDSP_Length(half))

        let binHz = sampleRate / Float(n)
        let sqrt2: Float = 1.414213562

        stateLock.withLock { state in
            for b in 0..<Self.bandCount {
                let center = Self.centerFrequencies[b]
                let loBin = max(1, Int((center / sqrt2) / binHz))
                let hiBin = min(half - 1, max(loBin, Int((center * sqrt2) / binHz)))
                // Peak bin in the band: a tone reads full, leakage into other bands
                // reads low (unlike averaging, which biased the narrow low bands).
                var peak: Float = 0
                for k in loBin...hiBin where mags[k] > peak { peak = mags[k] }
                let mag = sqrtf(peak) * (2.0 / Float(n))
                let db = 20 * log10f(mag + 1e-9) - Self.hannNormGainDB
                // Linear in dB across the meter window — 5 dB per LED over 12 segments —
                // so the bar height *is* the recorded level and the Record Level fader
                // moves it one-for-one. See `--selftest-spectrum` for the calibration.
                let level = min(1, max(0, (db - Self.floorDB) / (Self.ceilingDB - Self.floorDB)))
                // Fast attack, quick-ish decay so the columns bounce.
                let prev = state.levels[b]
                var smoothed = level > prev ? level : prev * 0.78 + level * 0.22
                if smoothed < Self.silenceFloor { smoothed = 0 }
                state.levels[b] = smoothed
                // Peak-hold cap: jumps to new peaks, then falls slowly.
                state.peaks[b] = smoothed > state.peaks[b] ? smoothed : max(smoothed, state.peaks[b] * 0.965)
            }

            // The same magnitudes re-binned onto the fine log axis for the analyzer
            // curve. Each point takes the peak over the FFT bins within half a step
            // either side, so the points tile the axis without gaps: a tone lands at full
            // height on the point nearest it instead of being averaged away, and the low
            // end — where several points share one FFT bin — reads as a smooth shoulder
            // rather than a staircase.
            let halfStep = powf(Self.curveHighHz / Self.curveLowHz,
                                0.5 / Float(Self.curveResolution - 1))
            for i in 0..<Self.curveResolution {
                let f = Self.curveFrequencies[i]
                let loBin = max(1, Int((f / halfStep) / binHz))
                let hiBin = min(half - 1, max(loBin, Int((f * halfStep) / binHz)))
                var peak: Float = 0
                if hiBin > loBin {
                    // The point spans whole bins: take the loudest, so a tone reads full
                    // height instead of being averaged down by its quiet neighbours.
                    for k in loBin...hiBin where mags[k] > peak { peak = mags[k] }
                } else {
                    // Low end: the log axis is finer than the FFT, and several points fall
                    // inside one bin. Reading that bin for each of them draws a staircase
                    // of identical values, so interpolate between neighbours instead.
                    let position = min(Float(half - 2), max(1, f / binHz))
                    let base = Int(position)
                    let fraction = position - Float(base)
                    peak = mags[base] + (mags[base + 1] - mags[base]) * fraction
                }
                let mag = sqrtf(max(0, peak)) * (2.0 / Float(n))
                let db = 20 * log10f(mag + 1e-9) - Self.hannNormGainDB
                let level = min(1, max(0, (db - Self.floorDB) / (Self.ceilingDB - Self.floorDB)))
                // Slightly quicker decay than the LED bands: the curve is read as a
                // shape, and a slow release smears transients across neighbouring points.
                let prev = state.curve[i]
                var smoothed = level > prev ? level : prev * 0.72 + level * 0.28
                if smoothed < Self.silenceFloor { smoothed = 0 }
                state.curve[i] = smoothed
                state.curvePeaks[i] = smoothed > state.curvePeaks[i]
                    ? smoothed
                    : max(smoothed, state.curvePeaks[i] * 0.955)
            }
        }
    }
}
