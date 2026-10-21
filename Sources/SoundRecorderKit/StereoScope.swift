import Foundation
import AVFoundation
import os

/// Captures the most recent stereo sample pairs (a ring buffer) for a Lissajous /
/// vectorscope display. Fed on the audio thread; snapshotted from the UI thread.
public final class StereoScope: @unchecked Sendable {

    /// Samples held for the display. At 48 kHz this is ~43 ms — a little more than one
    /// 30 Hz meter frame, so consecutive frames overlap slightly and the figure reads as
    /// a continuous trace instead of a window that flickers between redraws.
    public static let capacity = 2048

    /// What the capture buffers actually looked like, as opposed to what the tap's
    /// declared format promised. The two disagree often enough — and the display
    /// degenerates to a diagonal line either way — that the ring records it while it is
    /// already walking the samples: a diagonal caused by a *mono source* and one caused
    /// by *misreading a stereo buffer* are indistinguishable on screen but not here.
    public struct Layout: Sendable, Equatable {
        /// Buffers in the list: 1 = interleaved (or mono), 2+ = planar.
        public var buffers = 0
        /// `mNumberChannels` of the first buffer.
        public var channels = 0
        /// Frames ingested since the last `clear()`.
        public var frames: UInt64 = 0
        /// Largest |L − R| seen. Exactly 0 over a long run means the two channels carry
        /// identical samples: whatever the reason upstream, what arrived is mono.
        public var maxChannelDelta: Float = 0
        /// Largest sample magnitude seen, so silence isn't mistaken for mono: a stereo
        /// source that simply hasn't started yet also has L − R == 0 on every frame.
        public var maxMagnitude: Float = 0

        /// True once enough audible frames have gone by to trust `maxChannelDelta == 0`.
        public var isMonoSource: Bool {
            frames > 4096 && maxMagnitude > 0.0002 && maxChannelDelta == 0
        }

        public var summary: String {
            let shape = buffers == 1
                ? (channels >= 2 ? "interleaved \(channels) ch" : "mono, 1 buffer")
                : "planar \(buffers) × \(channels) ch"
            guard frames > 0 else { return "\(shape), no frames yet" }
            return String(format: "%@, max |L−R| %.6f%@", shape, maxChannelDelta,
                          isMonoSource ? " (channels identical — mono source)" : "")
        }
    }

    private struct Ring {
        var left = [Float](repeating: 0, count: StereoScope.capacity)
        var right = [Float](repeating: 0, count: StereoScope.capacity)
        var write = 0
        var layout = Layout()
    }
    private let lock = OSAllocatedUnfairLock(initialState: Ring())

    public init() {}

    /// Append the newest frames. Handles all three tap layouts:
    ///  • interleaved stereo  — one buffer, mNumberChannels ≥ 2, samples L,R,L,R…
    ///  • non-interleaved      — two buffers, one channel each (L in [0], R in [1])
    ///  • mono                 — one channel, duplicated to both sides
    public func ingest(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, let first = abl.first, let ldata = first.mData else { return }
        let lsrc = ldata.assumingMemoryBound(to: Float.self)
        let channels = max(1, Int(first.mNumberChannels))
        let cap = Self.capacity
        let take = min(frames, cap)
        let start = frames - take
        let buffers = abl.count

        if channels >= 2 {
            // Interleaved: both channels live in the first buffer.
            lock.withLockUnchecked { ring in
                var w = ring.write
                var delta = ring.layout.maxChannelDelta
                var magnitude = ring.layout.maxMagnitude
                for i in 0..<take {
                    let idx = (start + i) * channels
                    let l = lsrc[idx], r = lsrc[idx + 1]
                    ring.left[w] = l
                    ring.right[w] = r
                    delta = max(delta, abs(l - r))
                    magnitude = max(magnitude, max(abs(l), abs(r)))
                    w += 1; if w == cap { w = 0 }
                }
                ring.write = w
                ring.layout.buffers = buffers
                ring.layout.channels = channels
                ring.layout.frames &+= UInt64(take)
                ring.layout.maxChannelDelta = delta
                ring.layout.maxMagnitude = magnitude
            }
        } else {
            // Non-interleaved stereo (right in the second buffer) or mono (right = left).
            let rsrc = abl.count >= 2
                ? abl[1].mData?.assumingMemoryBound(to: Float.self)
                : nil
            lock.withLockUnchecked { ring in
                var w = ring.write
                var delta = ring.layout.maxChannelDelta
                var magnitude = ring.layout.maxMagnitude
                for i in 0..<take {
                    let idx = start + i
                    let l = lsrc[idx]
                    let r = rsrc?[idx] ?? l
                    ring.left[w] = l
                    ring.right[w] = r
                    delta = max(delta, abs(l - r))
                    magnitude = max(magnitude, max(abs(l), abs(r)))
                    w += 1; if w == cap { w = 0 }
                }
                ring.write = w
                ring.layout.buffers = buffers
                ring.layout.channels = channels
                ring.layout.frames &+= UInt64(take)
                ring.layout.maxChannelDelta = delta
                ring.layout.maxMagnitude = magnitude
            }
        }
    }

    /// Recent samples ordered oldest → newest, safe to call from the UI thread.
    public func snapshot() -> (left: [Float], right: [Float]) {
        lock.withLock { ring in
            let cap = Self.capacity
            let w = ring.write
            var l = [Float](repeating: 0, count: cap)
            var r = [Float](repeating: 0, count: cap)
            for i in 0..<cap {
                let idx = (w + i) % cap
                l[i] = ring.left[idx]
                r[i] = ring.right[idx]
            }
            return (l, r)
        }
    }

    /// Project one sample pair into goniometer (vectorscope) coordinates: `x` is the side
    /// signal, `y` the mid (L+R), each halved so a full-scale mono pair lands at y = ±1
    /// and a full-scale hard-panned one at (±0.5, 0.5).
    ///
    /// This is the raw L/R plane rotated 45°, the orientation every phase meter uses:
    /// mono stands up as a vertical line, an inverted channel lies flat on the horizontal,
    /// and hard-panned material rides a diagonal. Side is `R − L`, not `L − R`, so that
    /// left-panned audio leans up-*left* on screen as the labels promise — with the sign
    /// the other way the figure is a mirror image of what every other meter shows.
    public static func goniometer(left: Float, right: Float) -> (x: Float, y: Float) {
        ((right - left) / 2, (left + right) / 2)
    }

    /// Pearson correlation between the two channels of a snapshot: +1 when they move
    /// together (the figure collapses to a line — a mono source reads exactly +1), 0 for
    /// an open, genuinely stereo figure, −1 when one channel is the other inverted.
    public static func correlation(left: [Float], right: [Float]) -> Float {
        let n = min(left.count, right.count)
        guard n > 1 else { return 0 }
        var sumL = 0.0, sumR = 0.0
        for i in 0..<n { sumL += Double(left[i]); sumR += Double(right[i]) }
        let mL = sumL / Double(n), mR = sumR / Double(n)
        var cov = 0.0, varL = 0.0, varR = 0.0
        for i in 0..<n {
            let dl = Double(left[i]) - mL, dr = Double(right[i]) - mR
            cov += dl * dr; varL += dl * dl; varR += dr * dr
        }
        guard varL > 0, varR > 0 else { return 0 }
        return Float(cov / (varL * varR).squareRoot())
    }

    /// What the capture buffers have looked like since the last `clear()`.
    public func layout() -> Layout { lock.withLock { $0.layout } }

    public func clear() { lock.withLock { $0 = Ring() } }
}
