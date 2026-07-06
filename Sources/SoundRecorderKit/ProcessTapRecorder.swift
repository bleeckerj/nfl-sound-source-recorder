import Foundation
import CoreAudio
import AVFoundation
import Accelerate
import os

/// Records a process (or system-wide) audio tap to a file while simultaneously
/// routing the same audio out to a chosen output device.
///
/// Architecture:
///   1. Create a process tap (`AudioHardwareCreateProcessTap`) on the target.
///   2. Build a private aggregate device that contains BOTH the tap (as an input
///      stream) and the target output device (as an output stream).
///   3. Install one IOProc on the aggregate. Each callback hands us the tap's
///      captured frames as input; we (a) write them to disk and (b) copy them
///      into the output buffers so they play out the chosen device.
public final class ProcessTapRecorder {

    public enum Target {
        case pid(pid_t)
        case systemWide
    }

    private let target: Target
    private let outputDevice: AudioDeviceInfo
    private let fileURL: URL
    private let mute: Bool
    private let driftCompensation: Bool
    private let warmupSeconds: Double

    /// 10-band EQ applied to both the routed output and the recorded file.
    /// Control it live (e.g. from the UI) via `setGain`/`setEnabled`.
    public let equalizer = GraphicEQ()

    /// Live input level / frame counter for diagnostics and metering.
    public let meter = LevelMeter()

    /// 10-band spectrum analyzer for the LED display.
    public let spectrum = SpectrumMeter()

    /// Recent stereo samples for the Lissajous / vectorscope display.
    public let scope = StereoScope()

    /// Master record level (linear gain) applied to the recorded file and the meter,
    /// but not the monitored/routed output. Live-settable while recording.
    private let gainLock = OSAllocatedUnfairLock(initialState: Float(1))

    /// Set the record level in dB (0 dB = unity). Clamped to +36 dB.
    public func setRecordGain(dB: Double) {
        let clamped = min(36, dB)
        gainLock.withLock { $0 = powf(10, Float(clamped) / 20) }
    }

    /// Human-readable description of the tap's capture format (set on `start`).
    public private(set) var captureDescription: String?

    private var tapID: AudioObjectID = 0
    private var tapUUID = ""
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var audioFile: AVAudioFile?
    private var tapFormat: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?

    /// - Parameters:
    ///   - driftCompensation: resample the tap to the output device's clock (off by default).
    ///   - warmupSeconds: how long to let the pipeline run before the file starts
    ///     recording, to skip Core Audio's ~0.5 s device-start volume ramp. The routed
    ///     audio still plays during this window; only file-writing is held back. Set to
    ///     0 to keep the raw ramp.
    public init(target: Target, outputDevice: AudioDeviceInfo, fileURL: URL, mute: Bool,
                driftCompensation: Bool = false, warmupSeconds: Double = 0.6) {
        self.target = target
        self.outputDevice = outputDevice
        self.fileURL = fileURL
        self.mute = mute
        self.driftCompensation = driftCompensation
        self.warmupSeconds = max(0, warmupSeconds)
    }

    // MARK: Lifecycle

    public func start() throws {
        do {
            try createTap()
            try createAggregateDevice()
            try openOutputFile()
            try installIOProc()
            try CA.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
        } catch {
            // Tear down any partially-created objects so we don't leak a tap or
            // aggregate device on a failed start.
            stop()
            throw error
        }
    }

    public func stop() {
        if aggregateID != 0, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        aggregateID = 0
        tapID = 0
        ioProcID = nil
        audioFile = nil // finalizes the file
    }

    // MARK: Setup steps

    private func createTap() throws {
        let description: CATapDescription
        switch target {
        case .pid(let pid):
            let processObject = try AudioSystem.processObject(for: pid)
            guard processObject != 0 else {
                throw CA.Error(status: -1, context: "No audio process object for pid \(pid) (is it playing audio?)")
            }
            description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        case .systemWide:
            // Exclude our OWN process from the global tap. Otherwise the audio we
            // route back out to the output device is itself "system audio", gets
            // re-captured, re-routed, re-captured… → a runaway feedback loop.
            var exclude: [AudioObjectID] = []
            if let own = try? AudioSystem.processObject(for: getpid()), own != 0 {
                exclude.append(own)
            }
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        }
        description.name = "NFL Sound Recorder Tap"
        description.isPrivate = true
        // .unmuted = app keeps playing AND we capture (duplicate).
        // .muted   = silence the original path so only our routed copy is heard (reroute).
        description.muteBehavior = mute ? .muted : .unmuted

        // The aggregate device references the tap by THIS uuid — must match exactly,
        // or the sub-tap connects to nothing and the IOProc receives silence.
        tapUUID = description.uuid.uuidString

        var newTapID: AudioObjectID = 0
        try CA.check(AudioHardwareCreateProcessTap(description, &newTapID), "AudioHardwareCreateProcessTap")
        tapID = newTapID

        var asbd = try readTapFormat()
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CA.Error(status: -1, context: "Could not build AVAudioFormat from tap format")
        }
        tapFormat = format
        captureDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, Float32"
        equalizer.reconfigure(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        spectrum.configure(sampleRate: format.sampleRate)
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CA.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "Read tap format")
        return asbd
    }

    private func createAggregateDevice() throws {
        let outputUID = outputDevice.uid
        let aggregateUID = "com.nfl.soundrecorder.agg.\(UInt(bitPattern: ObjectIdentifier(self).hashValue))"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "NFL Sound Recorder",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            // Auto-start the tap with the aggregate, or it delivers zero samples.
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID]
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID,
                    kAudioSubTapDriftCompensationKey as String: driftCompensation
                ]
            ],
        ]

        var newAggID: AudioObjectID = 0
        try CA.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newAggID
    }

    private func openOutputFile() throws {
        guard let tapFormat else { throw CA.Error(status: -1, context: "Missing tap format") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: tapFormat.sampleRate,
            AVNumberOfChannelsKey: tapFormat.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audioFile = try AVAudioFile(forWriting: fileURL, settings: settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: true)
        // Reusable buffer (tap format) for EQ processing; large enough for any IO cycle.
        scratch = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: 16_384)
    }

    private func installIOProc() throws {
        guard let tapFormat else { throw CA.Error(status: -1, context: "Missing tap format") }
        let file = audioFile
        let eq = equalizer
        let scratch = self.scratch
        let meter = self.meter
        let spectrum = self.spectrum
        let scope = self.scope
        let gainLock = self.gainLock
        // Skip the initial device-start ramp: hold off file-writing this many frames.
        let warmupFrames = UInt64(warmupSeconds * tapFormat.sampleRate)

        var newProcID: AudioDeviceIOProcID?
        try CA.check(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) {
                _, inInputData, _, outOutputData, _ in
                let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let output = UnsafeMutableAudioBufferListPointer(outOutputData)
                let inBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil)
                let frames = inBuffer?.frameLength ?? 0

                // Meter the raw tap input (pre-EQ), for diagnostics.
                let inputPeak = peakOf(input)
                if inputPeak > meter.peak { meter.peak = inputPeak }
                if inputPeak > meter.maxPeak { meter.maxPeak = inputPeak }
                meter.totalFrames &+= UInt64(frames)
                // Route immediately, but only start writing the file past the warm-up.
                let recordToFile = meter.totalFrames >= warmupFrames
                let gain = gainLock.withLock { $0 }   // master record level (linear)

                // Passthrough when EQ is off (or the cycle is too large for scratch):
                // route at natural level, then record (with record gain applied).
                if !eq.isEnabled || frames == 0 || scratch == nil || frames > scratch!.frameCapacity {
                    copyBuffers(from: input, to: output)         // monitor unaffected by record level
                    if gain != 1 { scaleBuffers(input, by: gain) }
                    if recordToFile, let file, let inBuffer { try? file.write(from: inBuffer) }
                    spectrum.ingest(input, frames: Int(frames))
                    scope.ingest(input, frames: Int(frames))
                    return
                }

                // EQ path: input → scratch → EQ → route (natural) → record (gained).
                let work = scratch!
                work.frameLength = frames
                let workABL = UnsafeMutableAudioBufferListPointer(work.mutableAudioBufferList)
                copyBuffers(from: input, to: workABL)
                eq.process(workABL)
                copyBuffers(from: workABL, to: output)           // monitor at EQ'd, natural level
                if gain != 1 { scaleBuffers(workABL, by: gain) }
                if recordToFile, let file { try? file.write(from: work) }
                // Meter the post-EQ, post-gain signal so LEDs reflect EQ and record level.
                spectrum.ingest(workABL, frames: Int(frames))
                scope.ingest(workABL, frames: Int(frames))
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newProcID
    }
}

/// memcpy each buffer of one list into the matching buffer of another, clamping to
/// the smaller size and zero-filling any remaining output space.
/// Multiply every sample in the buffer list by a scalar gain, in place.
private func scaleBuffers(_ abl: UnsafeMutableAudioBufferListPointer, by gain: Float) {
    var g = gain
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let p = data.assumingMemoryBound(to: Float.self)
        vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
    }
}

/// Largest absolute float sample across every buffer in the list.
private func peakOf(_ abl: UnsafeMutableAudioBufferListPointer) -> Float {
    var peak: Float = 0
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for i in 0..<count {
            let magnitude = abs(samples[i])
            if magnitude > peak { peak = magnitude }
        }
    }
    return peak
}

private func copyBuffers(from src: UnsafeMutableAudioBufferListPointer,
                         to dst: UnsafeMutableAudioBufferListPointer) {
    let pairs = min(src.count, dst.count)
    for i in 0..<pairs {
        guard let srcData = src[i].mData, let dstData = dst[i].mData else { continue }
        let byteCount = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
        memcpy(dstData, srcData, byteCount)
        if Int(dst[i].mDataByteSize) > byteCount {
            memset(dstData + byteCount, 0, Int(dst[i].mDataByteSize) - byteCount)
        }
    }
}
