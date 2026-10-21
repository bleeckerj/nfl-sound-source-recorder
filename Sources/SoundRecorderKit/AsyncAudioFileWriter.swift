import Foundation
import AVFoundation
import os

/// Writes captured audio to a file **off the real-time render thread**.
///
/// The capture IOProc must never block: `AVAudioFile.write` does disk I/O and, for
/// compressed formats (AAC/ALAC/FLAC), runs a full codec that allocates and can stall for
/// an unbounded time. Doing that inline on the render thread both glitches audio and — far
/// worse — lets `AudioDeviceStop` (which waits for the IOProc to go idle) hang the main
/// thread into a beachball at teardown.
///
/// So the render thread only ever copies interleaved Float32 frames into a lock-guarded
/// ring (`enqueue`, bounded, allocation-free) and returns. A dedicated serial queue drains
/// the ring on a timer and performs every `AVAudioFile.write`. `finish()` flushes what's
/// left and closes the file.
///
/// Overflow policy: if the ring ever fills (only under a catastrophic writer stall — it
/// holds several seconds), the newest frames are dropped and counted rather than blocking
/// the render thread or reordering the recording. `droppedFrames` surfaces that.
final class AsyncAudioFileWriter {
    private let log = Logger(subsystem: "com.nfl.soundrecorder", category: "filewriter")

    private var file: AVAudioFile?
    /// The file's own processing format — interleaved Float32 at the capture rate/channels —
    /// so the drain buffer needs no conversion on `write`.
    private let writeFormat: AVAudioFormat
    private let channels: Int

    // Lock-guarded interleaved Float32 ring (render thread = producer, writer queue = consumer).
    private let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = OSAllocatedUnfairLock()
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var droppedTotal: UInt64 = 0
    private let errorState = OSAllocatedUnfairLock(initialState: Optional<String>.none)

    var failure: String? {
        if let error = errorState.withLock({ $0 }) { return error }
        lock.lock(); let dropped = droppedTotal; lock.unlock()
        return dropped > 0 ? "Audio writer overflow: dropped \(dropped) frames" : nil
    }

    /// Frames the ring dropped because the writer couldn't keep up (should stay 0).
    private(set) var droppedFrames: UInt64 = 0

    private let queue = DispatchQueue(label: "com.nfl.soundrecorder.filewriter", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    /// Reused for each write so the drain never allocates. Sized to one drain chunk.
    private let drainChunk = 16_384
    private let drainBuffer: AVAudioPCMBuffer
    private var finished = false

    /// Open `fileURL` for writing with `settings`, buffering `bufferSeconds` of slack between
    /// the render thread and the writer. Throws if the file can't be created.
    init(fileURL: URL, settings: [String: Any], captureFormat: AVAudioFormat,
         bufferSeconds: Double = 6) throws {
        // Always hand `write` interleaved Float32 buffers; AVAudioFile converts float→int /
        // PCM→compressed for us, exactly as the old inline path did.
        let f = try AVAudioFile(forWriting: fileURL, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: true)
        self.file = f
        self.writeFormat = f.processingFormat
        self.channels = max(1, Int(f.processingFormat.channelCount))
        self.capacityFrames = max(drainChunk * 2, Int(captureFormat.sampleRate * bufferSeconds))
        self.storage = .allocate(capacity: channels * capacityFrames)
        self.storage.initialize(repeating: 0, count: channels * capacityFrames)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: writeFormat,
                                            frameCapacity: AVAudioFrameCount(drainChunk)) else {
            storage.deallocate()
            throw CA.Error(status: -1, context: "AsyncAudioFileWriter drain buffer")
        }
        self.drainBuffer = buffer

        let t = DispatchSource.makeTimerSource(queue: queue)
        // ~10 ms cadence: negligible latency, keeps the render thread to a lock + memcpy.
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.drain() }
        self.timer = t
        t.resume()
    }

    deinit {
        timer?.cancel()
        storage.deallocate()
    }

    /// Producer (render thread): copy `frames` of `abl` (interleaved or planar Float32,
    /// `channels` channels) into the ring. Never blocks; drops+counts the newest frames on
    /// overflow.
    func enqueue(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0 else { return }
        let interleaved = abl.count == 1
        lock.lock()
        defer { lock.unlock() }
        let free = capacityFrames - availableFrames
        if free <= 0 { droppedTotal &+= UInt64(frames); return }
        let n = min(frames, free)
        for f in 0..<n {
            let base = writeIndex * channels
            for c in 0..<channels {
                storage[base + c] = Self.sample(abl, frame: f, channel: c, interleaved: interleaved)
            }
            writeIndex = (writeIndex + 1) % capacityFrames
        }
        availableFrames += n
        if n < frames { droppedTotal &+= UInt64(frames - n) }
    }

    /// Consumer (writer queue): drain everything currently buffered to the file, one
    /// `drainChunk` at a time so the write buffer stays small and fixed.
    private func drain() {
        guard let file else { return }
        while true {
            lock.lock()
            let n = min(drainChunk, availableFrames)
            if n == 0 {
                let dropped = droppedTotal
                lock.unlock()
                if dropped != droppedFrames {
                    droppedFrames = dropped
                    log.error("Writer overflow: dropped \(dropped) frames (writer not keeping up)")
                }
                return
            }
            // Copy interleaved frames out of the ring into the reusable write buffer.
            let dst = drainBuffer.floatChannelData![0]  // interleaved: one packed buffer
            for f in 0..<n {
                let src = readIndex * channels
                let out = f * channels
                for c in 0..<channels { dst[out + c] = storage[src + c] }
                readIndex = (readIndex + 1) % capacityFrames
            }
            availableFrames -= n
            lock.unlock()

            drainBuffer.frameLength = AVAudioFrameCount(n)
            do {
                try file.write(from: drainBuffer)
            } catch {
                errorState.withLock { if $0 == nil { $0 = error.localizedDescription } }
                log.error("AVAudioFile.write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Flush every buffered frame and close the file (finalizes the on-disk header). Blocks
    /// the caller until the file is fully written. Safe to call once; idempotent thereafter.
    /// MUST be called after the producing IOProcs are stopped (no more `enqueue`).
    func finish() {
        queue.sync {
            guard !finished else { return }
            finished = true
            timer?.cancel()
            timer = nil
            drain()
            file = nil   // releasing the AVAudioFile finalizes the file on disk
        }
    }

    private static func sample(_ abl: UnsafeMutableAudioBufferListPointer,
                               frame: Int, channel: Int, interleaved: Bool) -> Float {
        if interleaved {
            let buffer = abl[0]
            let ch = Int(buffer.mNumberChannels)
            guard ch > 0, let data = buffer.mData else { return 0 }
            let p = data.assumingMemoryBound(to: Float.self)
            return p[frame * ch + min(channel, ch - 1)]
        } else {
            guard channel < abl.count, let data = abl[channel].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame]
        }
    }
}
