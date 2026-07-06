import Foundation
import AVFoundation
import os

/// A 10-band graphic equalizer: a serial cascade of peaking biquad filters
/// (RBJ audio-EQ cookbook), one per ISO center frequency, applied per channel.
///
/// Gains are set from a control thread; `process(_:)` runs on the real-time audio
/// thread. A small `os_unfair_lock` guards the coefficient/enabled read — held for
/// microseconds and uncontended in practice (POC-grade; production DSP would use a
/// lock-free coefficient hand-off).
public final class GraphicEQ: @unchecked Sendable {

    /// ISO 1/1-octave center frequencies.
    public static let centerFrequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static var bandCount: Int { centerFrequencies.count }

    struct Biquad { var b0: Float = 1; var b1: Float = 0; var b2: Float = 0; var a1: Float = 0; var a2: Float = 0 }
    struct State { var x1: Float = 0; var x2: Float = 0; var y1: Float = 0; var y2: Float = 0 }

    private var lock = os_unfair_lock_s()
    private var enabled = false
    private var gainsDB: [Double]
    private var coeffs: [Biquad]

    private var sampleRate: Double
    private var channels: Int
    private let q = 1.41 // ~1 octave

    /// Per (band, channel) filter memory. Only the audio thread mutates this.
    private var state: [State]

    public init(sampleRate: Double = 48_000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.gainsDB = Array(repeating: 0, count: Self.centerFrequencies.count)
        self.coeffs = Self.centerFrequencies.map { Self.peaking(freq: $0, gainDB: 0, q: 1.41, sampleRate: sampleRate) }
        self.state = Array(repeating: State(), count: Self.centerFrequencies.count * self.channels)
    }

    // MARK: Control (any thread)

    /// Re-tune for a new stream format, preserving band gains and enabled state.
    public func reconfigure(sampleRate: Double, channels: Int) {
        os_unfair_lock_lock(&lock)
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.coeffs = zip(Self.centerFrequencies, gainsDB).map {
            Self.peaking(freq: $0, gainDB: $1, q: q, sampleRate: sampleRate)
        }
        self.state = Array(repeating: State(), count: Self.centerFrequencies.count * self.channels)
        os_unfair_lock_unlock(&lock)
    }

    public func setEnabled(_ on: Bool) {
        os_unfair_lock_lock(&lock); enabled = on; os_unfair_lock_unlock(&lock)
    }

    public func setGain(band: Int, dB: Double) {
        guard band >= 0, band < gainsDB.count else { return }
        let clamped = max(-24, min(24, dB))
        let c = Self.peaking(freq: Self.centerFrequencies[band], gainDB: clamped, q: q, sampleRate: sampleRate)
        os_unfair_lock_lock(&lock)
        gainsDB[band] = clamped
        coeffs[band] = c
        os_unfair_lock_unlock(&lock)
    }

    public func setGains(_ dB: [Double]) {
        for (i, value) in dB.enumerated() where i < gainsDB.count { setGain(band: i, dB: value) }
    }

    public func flat() { setGains(Array(repeating: 0, count: gainsDB.count)) }

    public var isEnabled: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return enabled
    }

    public var currentGains: [Double] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return gainsDB
    }

    // MARK: Real-time processing (audio thread)

    /// Filter a buffer list in place. Handles both interleaved (one buffer, N
    /// channels) and planar (N buffers, one channel each) float32 layouts.
    public func process(_ abl: UnsafeMutableAudioBufferListPointer) {
        os_unfair_lock_lock(&lock)
        let on = enabled
        let localCoeffs = coeffs
        let chanCount = channels
        os_unfair_lock_unlock(&lock)
        guard on else { return }

        var globalChannel = 0
        for buffer in abl {
            let bufChannels = Int(buffer.mNumberChannels)
            guard bufChannels > 0, let raw = buffer.mData else { globalChannel += bufChannels; continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let frames = (Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) / bufChannels

            for channelInBuffer in 0..<bufChannels {
                let globalCh = globalChannel + channelInBuffer
                guard globalCh < chanCount else { continue }
                // Cascade every band over this channel's samples, in place.
                for band in 0..<localCoeffs.count {
                    let c = localCoeffs[band]
                    let stateIndex = band * chanCount + globalCh
                    var st = state[stateIndex]
                    var i = channelInBuffer
                    for _ in 0..<frames {
                        let x = samples[i]
                        let y = c.b0 * x + c.b1 * st.x1 + c.b2 * st.x2 - c.a1 * st.y1 - c.a2 * st.y2
                        st.x2 = st.x1; st.x1 = x
                        st.y2 = st.y1; st.y1 = y
                        samples[i] = y
                        i += bufChannels
                    }
                    state[stateIndex] = st
                }
            }
            globalChannel += bufChannels
        }
    }

    // MARK: Coefficients

    static func peaking(freq: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(
            b0: Float((1 + alpha * A) / a0),
            b1: Float((-2 * cosW) / a0),
            b2: Float((1 - alpha * A) / a0),
            a1: Float((-2 * cosW) / a0),
            a2: Float((1 - alpha / A) / a0)
        )
    }
}
