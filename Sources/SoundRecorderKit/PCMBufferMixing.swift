import CoreAudio
import Accelerate

/// Add interleaved microphone frames to packed or planar Float32 tap buffers.
/// Channel order and feed gain are preserved without allocating in the audio callback.
func addInterleaved(into dst: UnsafeMutableAudioBufferListPointer,
                            from src: UnsafePointer<Float>, frames: Int,
                            channels: Int, gain: Float) {
    guard frames > 0, channels > 0 else { return }
    var firstChannel = 0
    var g = gain
    for buffer in dst {
        let bufferChannels = Int(buffer.mNumberChannels)
        defer { firstChannel += bufferChannels }
        guard bufferChannels > 0, let data = buffer.mData else { continue }
        let out = data.assumingMemoryBound(to: Float.self)
        let count = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * bufferChannels))
        guard count > 0 else { continue }
        for channel in 0..<bufferChannels where firstChannel + channel < channels {
            vDSP_vsma(src + firstChannel + channel, vDSP_Stride(channels), &g,
                      out + channel, vDSP_Stride(bufferChannels),
                      out + channel, vDSP_Stride(bufferChannels), vDSP_Length(count))
        }
    }
}

/// memcpy each buffer of one list into the matching buffer of another, clamping to
/// the smaller size and zero-filling any remaining output space.
func copyBuffers(from src: UnsafeMutableAudioBufferListPointer,
                         to dst: UnsafeMutableAudioBufferListPointer) {
    for i in 0..<dst.count {
        guard let dstData = dst[i].mData else { continue }
        // HAL represents a disabled stream with nil data and a nonzero byte count.
        // Scratch is reused each cycle, so absent streams must overwrite old audio.
        guard i < src.count, let srcData = src[i].mData else {
            memset(dstData, 0, Int(dst[i].mDataByteSize))
            continue
        }
        let byteCount = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
        memcpy(dstData, srcData, byteCount)
        if Int(dst[i].mDataByteSize) > byteCount {
            memset(dstData + byteCount, 0, Int(dst[i].mDataByteSize) - byteCount)
        }
    }
}
