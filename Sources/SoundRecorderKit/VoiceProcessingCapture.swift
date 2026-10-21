import AVFoundation
import AudioToolbox
import CoreAudio

/// Native microphone processing with silent output. Both I/O buses remain enabled
/// so macOS can supply its speaker reference while another app owns playback.
final class VoiceProcessingCapture {
    typealias Handler = (UnsafeMutableAudioBufferListPointer, Int, AudioTimeStamp) -> Void
    private var unit: AudioUnit?
    private var buffer: AVAudioPCMBuffer?
    private var handler: Handler?
    private(set) var format: AVAudioFormat?
    private(set) var reportedLatency: TimeInterval = 0

    func start(onBuffer: @escaping Handler) throws {
        guard unit == nil else { throw CA.Error(status: -1, context: "Voice processing already started") }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CA.Error(status: -1, context: "Apple VoiceProcessingIO is unavailable")
        }
        var created: AudioUnit?
        try CA.check(AudioComponentInstanceNew(component, &created), "Create VoiceProcessingIO")
        guard let created else { throw CA.Error(status: -1, context: "No VoiceProcessingIO instance") }
        unit = created
        do {
            var enabled: UInt32 = 1
            var disabled: UInt32 = 0
            func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                        _ element: AudioUnitElement, _ value: inout T) throws {
                try withUnsafePointer(to: &value) { pointer in
                    try CA.check(AudioUnitSetProperty(created, property, scope, element, pointer,
                        UInt32(MemoryLayout<T>.size)), "Set VoiceProcessingIO property \(property), bus \(element)")
                }
            }
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled)
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled)
            var input = try AudioSystem.defaultInputDevice()
            var output = try AudioSystem.defaultOutputDevice()
            try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &input)
            try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &output)
            let captureFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                             channels: 1, interleaved: true)!
            var microphoneFormat = captureFormat.streamDescription.pointee
            var speakerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                             channels: 2, interleaved: true)!.streamDescription.pointee
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &microphoneFormat)
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &speakerFormat)
            var capacity: UInt32 = 4096
            try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &capacity)
            try set(kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &disabled)
            try set(kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &disabled)
            var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false,
                                                               mDuckingLevel: .min)
            try set(kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &ducking)
            buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity)
            guard buffer != nil else { throw CA.Error(status: -1, context: "Allocate voice processing buffer") }
            handler = onBuffer
            var renderCallback = AURenderCallbackStruct(inputProc: { _, flags, _, _, _, data in
                if let data {
                    for buffer in UnsafeMutableAudioBufferListPointer(data) {
                        if let samples = buffer.mData { memset(samples, 0, Int(buffer.mDataByteSize)) }
                    }
                }
                flags.pointee.insert(.unitRenderAction_OutputIsSilence)
                return noErr
            }, inputProcRefCon: nil)
            try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback)
            var inputCallback = AURenderCallbackStruct(inputProc: { context, flags, time, _, frames, _ in
                let capture = Unmanaged<VoiceProcessingCapture>.fromOpaque(context).takeUnretainedValue()
                return capture.receive(flags: flags, time: time, frames: frames)
            }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inputCallback)
            try CA.check(AudioUnitInitialize(created), "Initialize VoiceProcessingIO")
            var latency: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            if AudioUnitGetProperty(created, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0,
                                    &latency, &size) == noErr { reportedLatency = latency }
            format = captureFormat
            try CA.check(AudioOutputUnitStart(created), "Start VoiceProcessingIO")
        } catch {
            stop()
            throw error
        }
    }

    private func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard let unit, let buffer, frames <= buffer.frameCapacity else {
            return kAudioUnitErr_TooManyFramesToProcess
        }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        if status == noErr {
            handler?(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), Int(frames), time.pointee)
        }
        return status
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        buffer = nil
        handler = nil
    }

    deinit { stop() }
}
