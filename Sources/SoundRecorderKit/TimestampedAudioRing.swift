import AudioToolbox
import AVFoundation
import Foundation
import os

/// Bounded PCM timeline. Host timestamps place both independent device clocks on
/// a shared 48 kHz timeline; each callback is resampled to those positions.
final class TimestampedAudioRing {
    private let channels: Int
    private let capacity = 144_000
    private let samples: UnsafeMutablePointer<Float>
    private let positions: UnsafeMutablePointer<Int64>
    private let lock = OSAllocatedUnfairLock()
    private var first: Int64?
    private var end: Int64 = 0
    private var invalidTimestamp = false

    init(channels: Int) {
        self.channels = channels
        samples = .allocate(capacity: capacity * channels)
        samples.initialize(repeating: 0, count: capacity * channels)
        positions = .allocate(capacity: capacity)
        positions.initialize(repeating: .min, count: capacity)
    }

    deinit { samples.deallocate(); positions.deallocate() }

    func write(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int,
               rate: Double, timestamp: AudioTimeStamp) {
        guard frames > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard timestamp.mFlags.contains(.hostTimeValid), rate > 0 else {
            invalidTimestamp = true
            return
        }
        let start = AVAudioTime.seconds(forHostTime: timestamp.mHostTime) * 48_000
        let lower = Int64(start.rounded(.up))
        let upper = Int64((start + Double(frames) * 48_000 / rate).rounded(.up))
        guard upper > lower, upper - lower <= capacity else { invalidTimestamp = true; return }
        if first == nil { first = lower }
        for position in lower..<upper {
            let source = max(0, Double(position) - start) * rate / 48_000
            let a = min(frames - 1, Int(source))
            let b = min(frames - 1, a + 1)
            let fraction = Float(source - Double(a))
            let slot = Int(position % Int64(capacity))
            for channel in 0..<channels {
                let x = sample(abl, frame: a, channel: channel)
                let y = sample(abl, frame: b, channel: channel)
                samples[slot * channels + channel] = x + (y - x) * fraction
            }
            positions[slot] = position
        }
        end = max(end, upper)
    }

    var bounds: (first: Int64?, end: Int64, invalid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (first, end, invalidTimestamp)
    }

    /// Missing app frames mean silence. Missing microphone frames are counted by the worker.
    func read(from start: Int64, frames: Int, into output: UnsafeMutablePointer<Float>) -> Int {
        lock.lock(); defer { lock.unlock() }
        var missing = 0
        for frame in 0..<frames {
            let position = start + Int64(frame)
            let slot = Int(position % Int64(capacity))
            let valid = positions[slot] == position
            if !valid { missing += 1 }
            for c in 0..<channels {
                output[frame * channels + c] = valid ? samples[slot * channels + c] : 0
            }
        }
        return missing
    }

    private func sample(_ abl: UnsafeMutableAudioBufferListPointer, frame: Int, channel: Int) -> Float {
        guard !abl.isEmpty else { return 0 }
        if abl.count == 1 {
            let ch = Int(abl[0].mNumberChannels)
            guard ch > 0, let data = abl[0].mData,
                  (frame * ch + min(channel, ch - 1) + 1) * 4 <= abl[0].mDataByteSize else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * ch + min(channel, ch - 1)]
        }
        let c = min(channel, abl.count - 1)
        guard let data = abl[c].mData, (frame + 1) * 4 <= abl[c].mDataByteSize else { return 0 }
        return data.assumingMemoryBound(to: Float.self)[frame]
    }
}
