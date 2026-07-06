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

    private let n = 2048
    private let half = 1024
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

    /// Reset to silence (e.g. when a recording stops).
    public func reset() { stateLock.withLock { $0 = BandState() } }

    // MARK: Audio thread

    public func ingest(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, let buffer = abl.first, let data = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let src = data.assumingMemoryBound(to: Float.self)

        // Slide the newest samples into a rolling mono window.
        let take = min(frames, n)
        let keep = n - take
        if keep > 0 { memmove(mono, mono + take, keep * MemoryLayout<Float>.size) }
        let startFrame = frames - take
        for i in 0..<take {
            let idx = (startFrame + i) * channels
            mono[keep + i] = channels >= 2 ? (src[idx] + src[idx + 1]) * 0.5 : src[idx]
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
                let db = 20 * log10f(mag + 1e-9)
                // Hot, exaggerated mapping (-82…-30 dBFS → 0…1) plus a gamma lift, so
                // ordinary program material slams the top and dances there.
                let raw = min(1, max(0, (db + 82) / 52))
                let level = powf(raw, 0.7)
                // Fast attack, quick-ish decay so the columns bounce.
                let prev = state.levels[b]
                let smoothed = level > prev ? level : prev * 0.78 + level * 0.22
                state.levels[b] = smoothed
                // Peak-hold cap: jumps to new peaks, then falls slowly.
                state.peaks[b] = smoothed > state.peaks[b] ? smoothed : max(smoothed, state.peaks[b] * 0.965)
            }
        }
    }
}
