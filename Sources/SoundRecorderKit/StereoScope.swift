import Foundation
import AVFoundation
import os

/// Captures the most recent stereo sample pairs (a ring buffer) for a Lissajous /
/// vectorscope display. Fed on the audio thread; snapshotted from the UI thread.
public final class StereoScope: @unchecked Sendable {

    public static let capacity = 1024

    private struct Ring {
        var left = [Float](repeating: 0, count: StereoScope.capacity)
        var right = [Float](repeating: 0, count: StereoScope.capacity)
        var write = 0
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

        if channels >= 2 {
            // Interleaved: both channels live in the first buffer.
            lock.withLockUnchecked { ring in
                var w = ring.write
                for i in 0..<take {
                    let idx = (start + i) * channels
                    ring.left[w] = lsrc[idx]
                    ring.right[w] = lsrc[idx + 1]
                    w += 1; if w == cap { w = 0 }
                }
                ring.write = w
            }
        } else {
            // Non-interleaved stereo (right in the second buffer) or mono (right = left).
            let rsrc = abl.count >= 2
                ? abl[1].mData?.assumingMemoryBound(to: Float.self)
                : nil
            lock.withLockUnchecked { ring in
                var w = ring.write
                for i in 0..<take {
                    let idx = start + i
                    let l = lsrc[idx]
                    ring.left[w] = l
                    ring.right[w] = rsrc?[idx] ?? l
                    w += 1; if w == cap { w = 0 }
                }
                ring.write = w
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

    public func clear() { lock.withLock { $0 = Ring() } }
}
