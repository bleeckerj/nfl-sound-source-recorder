import Foundation
import CoreAudio
import AVFoundation
import os

/// A lock-guarded single-producer / single-consumer ring of interleaved Float32
/// audio. The capture IOProc (producer) pushes the monitored signal in; the routing
/// IOProc (consumer) pulls it out on the *output device's* clock. It exists purely to
/// bridge the two independent audio pipelines so that swapping the routing device
/// never has to touch — or interrupt — capture and file-writing.
///
/// On overflow the oldest frames are dropped; on underflow the consumer reads fewer
/// frames than asked and fills the rest with silence. Both only ever affect what you
/// *hear* while monitoring, never the recorded file.
final class AudioRingBuffer {
    let channels: Int
    private let capacityFrames: Int
    /// Cushion the consumer builds up before it starts draining, so playback doesn't
    /// stutter while the buffer is near-empty (at startup or just after a reset).
    private let primeFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = OSAllocatedUnfairLock()
    private var readIndex = 0
    private var writeIndex = 0
    private var availableFrames = 0
    private var primed = false

    init(channels: Int, capacityFrames: Int) {
        self.channels = max(1, channels)
        self.capacityFrames = max(1, capacityFrames)
        // ~1/10 of the buffer (≈50 ms for a 0.5 s ring) of monitoring latency.
        self.primeFrames = max(1, self.capacityFrames / 10)
        storage = .allocate(capacity: self.channels * self.capacityFrames)
        storage.initialize(repeating: 0, count: self.channels * self.capacityFrames)
    }

    deinit { storage.deallocate() }

    /// Drop everything buffered and re-arm priming. Called when the routing device is
    /// swapped so the new monitor starts at the small prime latency instead of inheriting
    /// however full the ring drifted to while no consumer was draining it.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = writeIndex
        availableFrames = 0
        primed = false
    }

    /// Producer: append `frames` frames read from `abl` (interleaved or planar Float32,
    /// `channels` channels). Overwrites the oldest data if the ring is full.
    func write(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0 else { return }
        let interleaved = abl.count == 1
        lock.lock()
        defer { lock.unlock() }
        for f in 0..<frames {
            let base = writeIndex * channels
            for c in 0..<channels {
                storage[base + c] = Self.sample(abl, frame: f, channel: c, interleaved: interleaved)
            }
            writeIndex = (writeIndex + 1) % capacityFrames
            if availableFrames < capacityFrames {
                availableFrames += 1
            } else {
                // Full: the write just overwrote the oldest frame — advance the reader.
                readIndex = (readIndex + 1) % capacityFrames
            }
        }
    }

    /// Consumer: copy up to `frames` interleaved frames into `dst`, returning how many
    /// were actually available (the caller silences the shortfall).
    func read(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        // Hold the consumer off until the cushion is built, then keep draining until
        // genuinely empty (at which point we re-prime to rebuild the cushion).
        if !primed {
            guard availableFrames >= primeFrames else { return 0 }
            primed = true
        } else if availableFrames == 0 {
            primed = false
            return 0
        }
        let n = min(frames, availableFrames)
        for f in 0..<n {
            let src = readIndex * channels
            let out = f * channels
            for c in 0..<channels { dst[out + c] = storage[src + c] }
            readIndex = (readIndex + 1) % capacityFrames
        }
        availableFrames -= n
        return n
    }

    private static func sample(_ abl: UnsafeMutableAudioBufferListPointer,
                               frame: Int, channel: Int, interleaved: Bool) -> Float {
        if interleaved {
            let buffer = abl[0]
            let ch = Int(buffer.mNumberChannels)
            guard ch > 0, let data = buffer.mData else { return 0 }
            let p = data.assumingMemoryBound(to: Float.self)
            let idx = frame * ch + min(channel, ch - 1)
            return p[idx]
        } else {
            guard channel < abl.count, let data = abl[channel].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame]
        }
    }
}

/// Mutable resampler carry state, kept in a heap object so the real-time IOProc block
/// can own it without capturing the `AudioMonitor` itself.
private final class ResamplerState {
    var frac: Double = 0
    let carry: UnsafeMutablePointer<Float>   // last source frame, for interpolation continuity
    let channels: Int

    init(channels: Int) {
        self.channels = channels
        carry = .allocate(capacity: channels)
        carry.initialize(repeating: 0, count: channels)
    }
    deinit { carry.deallocate() }

    func reset() {
        frac = 0
        carry.update(repeating: 0, count: channels)
    }
}

/// Plays the ring-buffered monitor signal out to a chosen output device via a plain
/// HAL output IOProc installed directly on that device. Because it owns nothing of the
/// capture pipeline, it can be torn down and re-created on a different device at any
/// time without disturbing the recording — the whole point of the split.
///
/// The monitor runs on the output device's own clock and sample rate, so it linearly
/// resamples the tap-rate ring signal to the device rate and maps the tap's channels
/// onto the device's. This bridging affects only the monitored output; the file is
/// always written straight from the tap.
final class AudioMonitor {
    private let log = Logger(subsystem: "com.nfl.soundrecorder", category: "monitor")
    private let ring: AudioRingBuffer
    private let tapChannels: Int
    private let tapRate: Double

    private let state: ResamplerState
    // Big enough to hold one output cycle's worth of source frames even for large
    // device buffers and heavy downsampling (tap-rate ≫ device-rate).
    private let scratchFrames = 32_768
    private let scratch: UnsafeMutablePointer<Float>   // interleaved tap-rate source frames

    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    init(ring: AudioRingBuffer, tapFormat: AVAudioFormat) {
        self.ring = ring
        self.tapChannels = max(1, Int(tapFormat.channelCount))
        self.tapRate = tapFormat.sampleRate
        self.state = ResamplerState(channels: self.tapChannels)
        self.scratch = .allocate(capacity: self.tapChannels * scratchFrames)
        self.scratch.initialize(repeating: 0, count: self.tapChannels * scratchFrames)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    /// Begin playing the ring signal out to `device`. Safe to call once per instance.
    func start(device: AudioDeviceInfo) throws {
        let id = device.id
        // Float64 is Double, so this is the device's nominal sample rate in Hz.
        let deviceRate = (try? CA.value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
        let ratio = deviceRate > 0 ? tapRate / deviceRate : 1   // source frames per output frame

        state.reset()

        // Locals captured by the real-time block — never `self`.
        let ring = self.ring
        let tapCh = self.tapChannels
        let scratch = self.scratch
        let scratchFrames = self.scratchFrames
        let state = self.state

        var newProc: AudioDeviceIOProcID?
        try CA.check(
            AudioDeviceCreateIOProcIDWithBlock(&newProc, id, nil) {
                _, _, _, outOutputData, _ in
                let output = UnsafeMutableAudioBufferListPointer(outOutputData)
                let (frameCount, deviceChannels, interleaved) = outputLayout(output)
                guard frameCount > 0, deviceChannels > 0 else { return }

                // How many whole source frames this output block advances through.
                let total = state.frac + Double(frameCount) * ratio
                let wanted = Int(total.rounded(.down))
                let consumed = min(wanted, scratchFrames)
                let got = ring.read(into: scratch, frames: consumed)

                // Interpolation window: index 0 is the carried previous frame; index
                // k (1...consumed) is source frame k-1, clamped to what we actually got.
                @inline(__always) func src(_ k: Int, _ c: Int) -> Float {
                    if k == 0 { return state.carry[c] }
                    guard got > 0 else { return state.carry[c] }
                    let kk = min(k - 1, got - 1)
                    return scratch[kk * tapCh + c]
                }

                for i in 0..<frameCount {
                    let pos = state.frac + Double(i) * ratio
                    let idx = Int(pos.rounded(.down))
                    let f = Float(pos - Double(idx))
                    for outC in 0..<deviceChannels {
                        let value: Float
                        if deviceChannels == 1 && tapCh >= 2 {
                            let a = 0.5 * (src(idx, 0) + src(idx, 1))
                            let b = 0.5 * (src(idx + 1, 0) + src(idx + 1, 1))
                            value = a * (1 - f) + b * f
                        } else if outC < tapCh {
                            value = src(idx, outC) * (1 - f) + src(idx + 1, outC) * f
                        } else {
                            value = 0
                        }
                        writeOutput(output, frame: i, channel: outC, value: value,
                                    channels: deviceChannels, interleaved: interleaved)
                    }
                }

                if got > 0 {
                    let last = (got - 1) * tapCh
                    for c in 0..<tapCh { state.carry[c] = scratch[last + c] }
                }
                // Keep the phase in [0, 1); if we ever had to clamp `consumed` below what
                // the math wanted, drop the phase rather than let it run away.
                state.frac = consumed == wanted ? total - Double(consumed) : 0
            },
            "AudioDeviceCreateIOProcIDWithBlock (monitor)"
        )
        try CA.check(AudioDeviceStart(id, newProc), "AudioDeviceStart (monitor)")
        deviceID = id
        procID = newProc
        log.info("Monitoring to device \(id) at \(deviceRate) Hz (ratio \(ratio))")
    }

    func stop() {
        if deviceID != 0, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        deviceID = 0
        procID = nil
    }
}

/// Frames-per-channel, channel count, and interleaved-ness of an output buffer list.
private func outputLayout(_ abl: UnsafeMutableAudioBufferListPointer) -> (frames: Int, channels: Int, interleaved: Bool) {
    guard abl.count > 0 else { return (0, 0, true) }
    if abl.count == 1 {
        let b = abl[0]
        let ch = Int(b.mNumberChannels)
        let frames = ch > 0 ? Int(b.mDataByteSize) / (MemoryLayout<Float>.size * ch) : 0
        return (frames, ch, true)
    } else {
        let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
        return (frames, abl.count, false)
    }
}

private func writeOutput(_ abl: UnsafeMutableAudioBufferListPointer,
                         frame: Int, channel: Int, value: Float,
                         channels: Int, interleaved: Bool) {
    if interleaved {
        guard let data = abl[0].mData else { return }
        data.assumingMemoryBound(to: Float.self)[frame * channels + channel] = value
    } else {
        guard channel < abl.count, let data = abl[channel].mData else { return }
        data.assumingMemoryBound(to: Float.self)[frame] = value
    }
}
