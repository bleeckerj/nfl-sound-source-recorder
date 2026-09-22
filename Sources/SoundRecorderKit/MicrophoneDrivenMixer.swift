import AVFoundation

/// The microphone clocks a mixed recording, including intervals with no tap callbacks.
/// The tap writes its own clock's frames into a ring; only the mic callback uses scratch.
final class MicrophoneDrivenMixer {
    private let tapRing: AudioRingBuffer
    private let mixed: AVAudioPCMBuffer
    private let tapScratch: UnsafeMutablePointer<Float>
    private let channels: Int
    private let onBuffer: MicCapture.BufferHandler

    init(format: AVAudioFormat, onBuffer: @escaping MicCapture.BufferHandler) throws {
        channels = Int(format.channelCount)
        let capacity: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw CA.Error(status: -1, context: "Could not allocate microphone mix buffer")
        }
        mixed = buffer
        tapRing = AudioRingBuffer(channels: channels, capacityFrames: Int(format.sampleRate * 0.5))
        tapScratch = .allocate(capacity: channels * Int(capacity))
        self.onBuffer = onBuffer
    }

    deinit { tapScratch.deallocate() }

    func receiveTap(_ input: UnsafeMutableAudioBufferListPointer, frames: Int) {
        tapRing.write(input, frames: frames)
    }

    /// `MicCapture` supplies interleaved Float32 at the recording rate/channel count.
    func receiveMicrophone(_ input: UnsafeMutableAudioBufferListPointer, frames: Int,
                           microphoneGain: Float, sourceGain: Float) {
        guard frames > 0, input.count == 1, let data = input[0].mData else { return }
        let available = Int(input[0].mDataByteSize) / (MemoryLayout<Float>.size * channels)
        let count = min(frames, available, Int(mixed.frameCapacity))
        guard count > 0 else { return }
        mixed.frameLength = AVAudioFrameCount(count)
        let output = UnsafeMutableAudioBufferListPointer(mixed.mutableAudioBufferList)
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        addInterleaved(into: output, from: data.assumingMemoryBound(to: Float.self),
                       frames: count, channels: channels, gain: microphoneGain)
        let tapFrames = tapRing.read(into: tapScratch, frames: count)
        if tapFrames > 0 {
            addInterleaved(into: output, from: tapScratch, frames: tapFrames,
                           channels: channels, gain: sourceGain)
        }
        onBuffer(output, count)
    }
}
