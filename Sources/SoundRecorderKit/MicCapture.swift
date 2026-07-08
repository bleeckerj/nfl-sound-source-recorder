import Foundation
import CoreAudio
import AVFoundation
import os

/// Captures a microphone (any input device) via a plain HAL input IOProc installed
/// directly on that device, linearly resamples it from the device's clock/rate to a
/// caller-chosen target rate, maps its channels onto the target channel count, and
/// hands the resulting interleaved Float32 frames to `onBuffer`.
///
/// It is the input-side mirror of `AudioMonitor`: where the monitor pulls the ring on
/// the *output* device's clock, this pushes on the *input* device's clock. Two ways it
/// is used by `ProcessTapRecorder`:
///   • mixing — target = the tap format; `onBuffer` writes into a ring the tap IOProc drains.
///   • mic-only — target = the mic's own format (identity resample); `onBuffer` is the
///     recorder's `processCaptured`, so the mic IOProc itself clocks the file.
final class MicCapture {

    /// Interleaved Float32 target-format frames. The pointer is valid only for the call.
    typealias BufferHandler = (UnsafeMutableAudioBufferListPointer, Int) -> Void

    private let log = Logger(subsystem: "com.nfl.soundrecorder", category: "mic")
    private let device: AudioDeviceInfo
    private let targetRate: Double
    private let targetChannels: Int
    private let onBuffer: BufferHandler

    private var deviceID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?

    /// - Parameters:
    ///   - device: the input device to capture.
    ///   - targetRate: sample rate to deliver at (the tap rate when mixing).
    ///   - targetChannels: channel count to deliver (the tap channel count when mixing).
    ///   - onBuffer: receives interleaved Float32 frames at the target format.
    init(device: AudioDeviceInfo, targetRate: Double, targetChannels: Int,
         onBuffer: @escaping BufferHandler) {
        self.device = device
        self.targetRate = targetRate
        self.targetChannels = max(1, targetChannels)
        self.onBuffer = onBuffer
    }

    deinit { stop() }

    /// The mic's capture format as a human-readable string (valid after `start`).
    private(set) var captureDescription: String?

    func start() throws {
        let id = device.id
        let micRate = (try? CA.value(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
        let micChannels = max(1, (try? AudioSystem.inputChannelCount(id)) ?? 1)
        let rate = micRate > 0 ? micRate : targetRate
        // Source frames advanced per output frame (1.0 when rates match → identity path).
        let step = rate / targetRate
        captureDescription = "\(Int(rate)) Hz, \(micChannels) ch → \(Int(targetRate)) Hz, \(targetChannels) ch"

        let targetChannels = self.targetChannels
        let onBuffer = self.onBuffer
        let state = MicResampleState(channels: targetChannels)
        // Output scratch: generously sized for one input cycle upsampled to the target rate.
        let outCapacity = 32_768
        let out = UnsafeMutablePointer<Float>.allocate(capacity: targetChannels * outCapacity)
        out.initialize(repeating: 0, count: targetChannels * outCapacity)
        state.retainOutput(out, count: targetChannels * outCapacity)

        var newProc: AudioDeviceIOProcID?
        try CA.check(
            AudioDeviceCreateIOProcIDWithBlock(&newProc, id, nil) {
                _, inInputData, _, _, _ in
                let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let (inputFrames, inCh, interleaved) = micLayout(input)
                guard inputFrames > 0, inCh > 0 else { return }

                // Map a source frame (index -1 = carried previous frame) onto target channel `tc`.
                @inline(__always) func mapped(_ i: Int, _ tc: Int) -> Float {
                    if i < 0 { return state.carry[tc] }
                    let f = min(i, inputFrames - 1)
                    if inCh == 1 {
                        return micRead(input, frame: f, channel: 0, channels: inCh, interleaved: interleaved)
                    } else if targetChannels == 1 {
                        var sum: Float = 0
                        for c in 0..<inCh { sum += micRead(input, frame: f, channel: c, channels: inCh, interleaved: interleaved) }
                        return sum / Float(inCh)
                    } else {
                        return micRead(input, frame: f, channel: min(tc, inCh - 1), channels: inCh, interleaved: interleaved)
                    }
                }

                // Produce output frames while both interpolation neighbours are in range.
                var frac = state.frac
                var produced = 0
                while frac <= Double(inputFrames - 1) && produced < outCapacity {
                    let idx = Int(frac.rounded(.down))
                    let t = Float(frac - Double(idx))
                    let base = produced * targetChannels
                    for tc in 0..<targetChannels {
                        out[base + tc] = mapped(idx, tc) * (1 - t) + mapped(idx + 1, tc) * t
                    }
                    produced += 1
                    frac += step
                }

                // Carry the last source frame (mapped) and rebase the phase for the next cycle.
                for tc in 0..<targetChannels { state.carry[tc] = mapped(inputFrames - 1, tc) }
                state.frac = frac - Double(inputFrames)

                guard produced > 0 else { return }
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(targetChannels),
                        mDataByteSize: UInt32(produced * targetChannels * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(out)
                    )
                )
                withUnsafeMutablePointer(to: &abl) { p in
                    onBuffer(UnsafeMutableAudioBufferListPointer(p), produced)
                }
            },
            "AudioDeviceCreateIOProcIDWithBlock (mic)"
        )
        try CA.check(AudioDeviceStart(id, newProc), "AudioDeviceStart (mic)")
        deviceID = id
        procID = newProc
        log.info("Capturing mic \(id) at \(rate) Hz → \(self.targetRate) Hz (step \(step))")
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

/// Mutable resampler state for the real-time mic block. Owns the output scratch so it is
/// freed exactly once (on deinit), never from inside the audio callback.
private final class MicResampleState {
    var frac: Double = 0
    let carry: UnsafeMutablePointer<Float>
    private var output: UnsafeMutablePointer<Float>?

    init(channels: Int) {
        carry = .allocate(capacity: channels)
        carry.initialize(repeating: 0, count: channels)
    }

    func retainOutput(_ p: UnsafeMutablePointer<Float>, count: Int) { output = p }

    deinit {
        carry.deallocate()
        output?.deallocate()
    }
}

/// Frames-per-channel, channel count, and interleaved-ness of a mic input buffer list.
private func micLayout(_ abl: UnsafeMutableAudioBufferListPointer) -> (frames: Int, channels: Int, interleaved: Bool) {
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

private func micRead(_ abl: UnsafeMutableAudioBufferListPointer,
                     frame: Int, channel: Int, channels: Int, interleaved: Bool) -> Float {
    if interleaved {
        guard let data = abl[0].mData else { return 0 }
        return data.assumingMemoryBound(to: Float.self)[frame * channels + channel]
    } else {
        guard channel < abl.count, let data = abl[channel].mData else { return 0 }
        return data.assumingMemoryBound(to: Float.self)[frame]
    }
}
