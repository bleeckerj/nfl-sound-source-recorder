import Foundation
import CoreAudio
import AVFoundation
import Accelerate
import os

/// Records audio to a file, optionally routing the same audio out to a chosen output
/// device at the same time. The captured audio can be a process (or system-wide) tap,
/// the microphone, or a **mix** of a tap and the microphone with independent levels.
///
/// Architecture:
///   1. When a tap is involved, create a process tap (`AudioHardwareCreateProcessTap`)
///      and a private aggregate device around it; one IOProc on that aggregate clocks
///      the recording and hands us the captured frames.
///   2. The microphone (when involved) is captured on its *own* device clock by
///      `MicCapture`, resampled to the recording format, and bridged in via a ring
///      buffer that the tap IOProc drains and sums — the input-side mirror of the
///      routing ring. With **no tap** (mic-only), the mic's own IOProc clocks the file.
///   3. Every captured buffer — tap, mixed, or mic — flows through one shared sink that
///      applies the EQ, feeds the routing ring, applies the master record level, writes
///      the file, and updates the meters.
/// - Note: `@unchecked Sendable` because front-ends hand a recorder between threads (the
///   menu-bar app runs every lifecycle call — `start`/`stop`/`setRoutingDevice` — on one
///   serial control queue, off the main thread). The invariant that makes this safe: all
///   mutable lifecycle state (tap/aggregate/IOProc ids, writer, monitor, mic, rings) is only
///   ever touched under that single-serialized lifecycle path; the live setters are lock-
///   guarded; and the metering objects read from the UI (`meter`/`spectrum`/`scope`) are
///   independently thread-safe. Do not add unsynchronized mutable state read off that path.
public final class ProcessTapRecorder: @unchecked Sendable {

    public enum Target {
        case pid(pid_t)
        /// One app's whole process group (app + audio helpers), mixed down into
        /// a single tap — see `AudioAppInfo.tapPIDs`.
        case pids([pid_t])
        case systemWide
    }

    /// What to capture. `mix` records a tap and the microphone together into one file.
    public enum Source {
        case tap(Target)
        case microphone(AudioDeviceInfo)
        case mix(tap: Target, mic: AudioDeviceInfo)

        var tapTarget: Target? {
            switch self {
            case .tap(let t), .mix(let t, _): return t
            case .microphone:                 return nil
            }
        }
        var micDevice: AudioDeviceInfo? {
            switch self {
            case .microphone(let m), .mix(_, let m): return m
            case .tap:                               return nil
            }
        }
    }

    private let source: Source
    /// Current routing destination, or `nil` to record only. Unlike the tap/file this
    /// can change *while recording* — see `setRoutingDevice` — because routing lives on
    /// a separate pipeline (`monitor`) rather than being fused into the capture aggregate.
    private var routingDevice: AudioDeviceInfo?
    private let fileURL: URL
    /// Container + codec the file is written in. `fileURL`'s extension should match
    /// `format.fileExtension` so the container AVAudioFile infers agrees with the codec.
    private let format: RecordingFormat
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

    /// Per-feed levels (linear) for balancing the mix, applied *before* the sink so both
    /// the recording and the monitored output reflect the balance. `sourceGain` scales the
    /// tap feed, `micGain` the microphone feed. Live-settable while recording.
    private let sourceGainLock = OSAllocatedUnfairLock(initialState: Float(1))
    private let micGainLock = OSAllocatedUnfairLock(initialState: Float(1))

    /// Set the record level in dB (0 dB = unity). Clamped to +36 dB.
    public func setRecordGain(dB: Double) {
        gainLock.withLock { $0 = powf(10, Float(min(36, dB)) / 20) }
    }

    /// Set the tap/system feed level in dB (0 dB = unity). Clamped to +36 dB.
    public func setSourceGain(dB: Double) {
        sourceGainLock.withLock { $0 = powf(10, Float(min(36, dB)) / 20) }
    }

    /// Set the microphone feed level in dB (0 dB = unity). Clamped to +36 dB.
    public func setMicGain(dB: Double) {
        micGainLock.withLock { $0 = powf(10, Float(min(36, dB)) / 20) }
    }

    /// When true the IOProc keeps running (monitor + meters stay live) but stops
    /// writing to the file — a tape-deck "pause" that suspends the recording without
    /// tearing down and reopening the tap. Live-settable while recording.
    private let pausedLock = OSAllocatedUnfairLock(initialState: false)

    /// Pause or resume writing captured audio to the file.
    public func setPaused(_ paused: Bool) {
        pausedLock.withLock { $0 = paused }
    }

    /// Human-readable description of the capture format (set on `start`).
    public private(set) var captureDescription: String?

    private var tapID: AudioObjectID = 0
    private var tapUUID = ""
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    /// Writes the file off the render thread — the IOProc only enqueues PCM. See
    /// `AsyncAudioFileWriter` for why inline `AVAudioFile.write` caused the teardown hang.
    private var writer: AsyncAudioFileWriter?
    /// The format the file, EQ, meters, and rings all work in: the tap format when a tap
    /// is present, otherwise the microphone's format (mic-only).
    private var captureFormat: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?

    /// Bridges the capture IOProc (producer) to the routing IOProc (consumer) so the
    /// two run on independent clocks and the routing device can be swapped live.
    private var ring: AudioRingBuffer?
    /// The live routing pipeline, or `nil` when recording only. Rebuilt on device change.
    private var monitor: AudioMonitor?

    /// Microphone capture (when mixing or mic-only), the ring it feeds when mixing, and
    /// scratch buffers for combining the mic with the tap.
    private var micCapture: MicCapture?
    private var micRing: AudioRingBuffer?
    private var mixBuffer: AVAudioPCMBuffer?
    private var micReadScratch: UnsafeMutablePointer<Float>?
    private var micReadCapacity = 0

    /// One shared sink for every captured buffer (tap / mixed / mic). Built once on start
    /// with captured locals so the real-time blocks never touch `self`.
    private var captureSink: ((UnsafeMutableAudioBufferListPointer, Int) -> Void)?

    /// - Parameters:
    ///   - outputDevice: device to route captured audio to, or `nil` to record only
    ///     (a tap-only aggregate — no device is bound and nothing plays out).
    ///   - driftCompensation: resample the tap to the output device's clock (off by
    ///     default). Ignored in record-only mode (there is no output clock to track).
    ///   - warmupSeconds: how long to let the pipeline run before the file starts
    ///     recording, to skip Core Audio's ~0.5 s device-start volume ramp. The routed
    ///     audio still plays during this window; only file-writing is held back. Set to
    ///     0 to keep the raw ramp.
    public init(source: Source, outputDevice: AudioDeviceInfo?, fileURL: URL,
                format: RecordingFormat = .aac, mute: Bool,
                driftCompensation: Bool = false, warmupSeconds: Double = 0.6) {
        self.source = source
        self.routingDevice = outputDevice
        self.fileURL = fileURL
        self.format = format
        self.mute = mute
        self.driftCompensation = driftCompensation
        self.warmupSeconds = max(0, warmupSeconds)
    }

    deinit { freeMixScratch() }

    // MARK: Lifecycle

    public func start() throws {
        do {
            if let target = source.tapTarget {
                // Tap (or tap+mic mix): the tap aggregate clocks the recording.
                try createTap(target: target)
                try createAggregateDevice()
                try openOutputFile()
                makeCaptureSink()
                // Bring up mic capture BEFORE installing the tap IOProc, so the proc is
                // built once already draining the mic ring (no reinstall/gap).
                if let mic = source.micDevice { try startMicMixing(device: mic) }
                try installTapIOProc()
                try CA.check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
                startMonitor(device: routingDevice)
            } else if let mic = source.micDevice {
                // Mic-only: the microphone's own IOProc clocks the recording.
                try configureForMicOnly(device: mic)
                try openOutputFile()
                makeCaptureSink()
                startMonitor(device: routingDevice)
                try startMicOnly(device: mic)
            } else {
                throw CA.Error(status: -1, context: "No capture source (need a tap or a microphone)")
            }
        } catch {
            // Tear down any partially-created objects so we don't leak a tap or
            // aggregate device on a failed start.
            stop()
            throw error
        }
    }

    /// Tear down the whole pipeline and finalize the file. Every blocking HAL call is
    /// wrapped in a watchdog so a wedged `coreaudiod` can't hang the caller — see
    /// `CA.withTimeout`. Ordering matters: stop the producing IOProcs first (so no more
    /// frames arrive), then flush + close the writer, then destroy the aggregate/tap.
    ///
    /// Not real-time and can block briefly; callers with a UI (the menu-bar app) run this
    /// off the main thread. The CLI/MCP call it on their own (non-UI) threads.
    public func stop() {
        // 1. Stop the producers. AudioDeviceStop waits for the IOProc to go idle; the
        //    watchdog bounds that wait.
        micCapture?.stop()
        micCapture = nil
        monitor?.stop()
        monitor = nil
        if aggregateID != 0, let ioProcID {
            let agg = aggregateID
            CA.withTimeout(context: "AudioDeviceStop (aggregate)") {
                AudioDeviceStop(agg, ioProcID)
                AudioDeviceDestroyIOProcID(agg, ioProcID)
            }
        }
        // 2. No more enqueues can happen now — flush the remaining buffered audio and close.
        writer?.finish()
        writer = nil
        // 3. Destroy the HAL objects.
        if aggregateID != 0 {
            let agg = aggregateID
            CA.withTimeout(context: "AudioHardwareDestroyAggregateDevice") {
                AudioHardwareDestroyAggregateDevice(agg)
            }
        }
        if tapID != 0 {
            let tap = tapID
            CA.withTimeout(context: "AudioHardwareDestroyProcessTap") {
                AudioHardwareDestroyProcessTap(tap)
            }
        }
        aggregateID = 0
        tapID = 0
        ioProcID = nil
        ring = nil
        micRing = nil
        captureSink = nil
        freeMixScratch()
    }

    // MARK: Live routing

    /// Swap the routing destination *while recording* (or clear it with `nil`). Only the
    /// routing pipeline is rebuilt; capture, metering, and file-writing are untouched, so
    /// the recording continues seamlessly across the change.
    public func setRoutingDevice(_ device: AudioDeviceInfo?) {
        routingDevice = device
        monitor?.stop()
        monitor = nil
        // The ring drifted toward full while no consumer was draining it — clear it so
        // the new device starts at low latency rather than ~half a second behind.
        ring?.reset()
        startMonitor(device: device)
    }

    private func startMonitor(device: AudioDeviceInfo?) {
        guard let device, let ring, let captureFormat else { return }
        let m = AudioMonitor(ring: ring, tapFormat: captureFormat)
        do {
            try m.start(device: device)
            monitor = m
        } catch {
            monitor = nil   // non-fatal: keep recording, just don't route
        }
    }

    // MARK: Setup steps

    /// A stereo mixdown tap over every resolvable process object among `pids`.
    /// Some of an app's helper pids may have quit since enumeration — that's fine
    /// as long as at least one still has a HAL process object.
    private static func mixdownDescription(of pids: [pid_t]) throws -> CATapDescription {
        let objects = pids.compactMap { try? AudioSystem.processObject(for: $0) }.filter { $0 != 0 }
        guard !objects.isEmpty else {
            let list = pids.map(String.init).joined(separator: ", ")
            throw CA.Error(status: -1, context: "No audio process object for pid(s) \(list) (is it playing audio?)")
        }
        return CATapDescription(stereoMixdownOfProcesses: objects)
    }

    private func createTap(target: Target) throws {
        let description: CATapDescription
        switch target {
        case .pid(let pid):
            description = try Self.mixdownDescription(of: [pid])
        case .pids(let pids):
            description = try Self.mixdownDescription(of: pids)
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
        description.name = "TapDeck Tap"
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
        setCaptureFormat(format, description: "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, Float32")
    }

    /// Configure the pipeline to record the microphone alone. The mic's nominal rate and
    /// channel count define the recording format; there is no tap or aggregate device.
    private func configureForMicOnly(device: AudioDeviceInfo) throws {
        let rate = (try? CA.value(device.id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
        let sampleRate = rate > 0 ? rate : 48_000
        let channels = AVAudioChannelCount(max(1, (try? AudioSystem.inputChannelCount(device.id)) ?? 1))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channels, interleaved: true) else {
            throw CA.Error(status: -1, context: "Could not build microphone AVAudioFormat")
        }
        setCaptureFormat(format, description: "\(device.name): \(Int(sampleRate)) Hz, \(channels) ch, Float32")
    }

    private func setCaptureFormat(_ format: AVAudioFormat, description: String) {
        captureFormat = format
        captureDescription = description
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
        let aggregateUID = "com.nfl.soundrecorder.agg.\(UInt(bitPattern: ObjectIdentifier(self).hashValue))"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "TapDeck",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            // Auto-start the tap with the aggregate, or it delivers zero samples.
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUUID,
                    kAudioSubTapDriftCompensationKey as String: driftCompensation
                ]
            ],
        ]

        // The aggregate is always tap-only: it captures and clocks the IOProc, nothing
        // more. Routing lives on a separate pipeline (`monitor`) fed from a ring buffer,
        // so the routing device can be changed live without rebuilding this aggregate.
        var newAggID: AudioObjectID = 0
        try CA.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggID),
            "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newAggID
    }

    private func openOutputFile() throws {
        guard let captureFormat else { throw CA.Error(status: -1, context: "Missing capture format") }
        // The file's on-disk encoding comes from `format`; the buffers we hand to
        // `write(from:)` are always interleaved Float32 (`commonFormat` below), and
        // AVAudioFile converts float→int / PCM→compressed for us.
        let settings = format.settings(sampleRate: captureFormat.sampleRate,
                                       channels: captureFormat.channelCount)
        writer = try AsyncAudioFileWriter(fileURL: fileURL, settings: settings,
                                          captureFormat: captureFormat)
        // Reusable buffer (capture format) for EQ processing; large enough for any IO cycle.
        scratch = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 16_384)
        // Half a second of slack between the capture and routing clocks.
        ring = AudioRingBuffer(channels: Int(captureFormat.channelCount),
                               capacityFrames: Int(captureFormat.sampleRate * 0.5))
    }

    /// Build the one sink every captured buffer flows through. Captures only locals so the
    /// real-time blocks that call it never retain/release `self`.
    private func makeCaptureSink() {
        guard let captureFormat else { return }
        let writer = self.writer
        let eq = equalizer
        let scratch = self.scratch
        let meter = self.meter
        let spectrum = self.spectrum
        let scope = self.scope
        let gainLock = self.gainLock
        let pausedLock = self.pausedLock
        let ring = self.ring
        // Skip the initial device-start ramp: hold off file-writing this many frames.
        let warmupFrames = UInt64(warmupSeconds * captureFormat.sampleRate)

        captureSink = { abl, frames in
            // Meter the incoming (post per-feed-gain, pre-EQ) signal, for diagnostics.
            let inputPeak = peakOf(abl)
            if inputPeak > meter.peak { meter.peak = inputPeak }
            if inputPeak > meter.maxPeak { meter.maxPeak = inputPeak }
            meter.totalFrames &+= UInt64(frames)
            // Route immediately, but only start writing the file past the warm-up and
            // while not paused (pause suspends disk writes, keeps monitoring).
            let recordToFile = meter.totalFrames >= warmupFrames && !pausedLock.withLock { $0 }
            let gain = gainLock.withLock { $0 }   // master record level (linear)

            // Passthrough when EQ is off (or the cycle is too large for scratch):
            // route at natural level, then record (with record gain applied).
            if !eq.isEnabled || frames == 0 || scratch == nil || frames > scratch!.frameCapacity {
                ring?.write(abl, frames: frames)          // monitor at natural level, pre record-gain
                if gain != 1 { scaleBuffers(abl, by: gain) }
                if recordToFile { writer?.enqueue(abl, frames: frames) }   // off-thread write
                spectrum.ingest(abl, frames: frames)
                scope.ingest(abl, frames: frames)
                return
            }

            // EQ path: input → scratch → EQ → route (natural) → record (gained).
            let work = scratch!
            work.frameLength = AVAudioFrameCount(frames)
            let workABL = UnsafeMutableAudioBufferListPointer(work.mutableAudioBufferList)
            copyBuffers(from: abl, to: workABL)
            eq.process(workABL)
            ring?.write(workABL, frames: frames)          // monitor at EQ'd natural level, pre record-gain
            if gain != 1 { scaleBuffers(workABL, by: gain) }
            if recordToFile { writer?.enqueue(workABL, frames: frames) }   // off-thread write
            // Meter the post-EQ, post-gain signal so LEDs reflect EQ and record level.
            spectrum.ingest(workABL, frames: frames)
            scope.ingest(workABL, frames: frames)
        }
    }

    private func installTapIOProc() throws {
        guard let captureFormat, let sink = captureSink else {
            throw CA.Error(status: -1, context: "Missing capture format / sink")
        }
        let sourceGainLock = self.sourceGainLock
        let micGainLock = self.micGainLock
        // Mixing state (nil when tap-only): drain the mic ring and sum it into the tap feed.
        let micRing = self.micRing
        let mixBuffer = self.mixBuffer
        let micReadScratch = self.micReadScratch
        let micReadCapacity = self.micReadCapacity
        let channels = Int(captureFormat.channelCount)

        var newProcID: AudioDeviceIOProcID?
        try CA.check(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) {
                _, inInputData, _, _, _ in
                let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let frames = frameCount(input, channels: channels)   // no allocation on the RT thread
                let sourceGain = sourceGainLock.withLock { $0 }

                // Tap-only: scale the tap feed in place and hand it straight to the sink.
                guard let micRing, let mixBuffer, let micReadScratch else {
                    if sourceGain != 1 { scaleBuffers(input, by: sourceGain) }
                    sink(input, frames)
                    return
                }

                // Mix: tap (×sourceGain) + mic (×micGain) → mixBuffer → sink.
                let micGain = micGainLock.withLock { $0 }
                mixBuffer.frameLength = AVAudioFrameCount(frames)
                let mixABL = UnsafeMutableAudioBufferListPointer(mixBuffer.mutableAudioBufferList)
                copyBuffers(from: input, to: mixABL)
                if sourceGain != 1 { scaleBuffers(mixABL, by: sourceGain) }
                let wanted = min(frames, micReadCapacity)
                let got = micRing.read(into: micReadScratch, frames: wanted)
                if got > 0 {
                    addInterleaved(into: mixABL, from: micReadScratch, frames: got,
                                   channels: channels, gain: micGain)
                }
                sink(mixABL, frames)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newProcID
    }

    // MARK: Microphone

    /// Bring up mic capture that feeds the mix ring the tap IOProc drains. Non-fatal on
    /// failure: the tap keeps recording, just without the mic.
    private func startMicMixing(device: AudioDeviceInfo) throws {
        guard let captureFormat else { return }
        let channels = Int(captureFormat.channelCount)
        // ~0.5 s of slack between the mic clock and the tap clock.
        let ring = AudioRingBuffer(channels: channels,
                                   capacityFrames: Int(captureFormat.sampleRate * 0.5))
        micRing = ring
        mixBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 16_384)
        micReadCapacity = 16_384
        micReadScratch = .allocate(capacity: channels * micReadCapacity)
        micReadScratch?.initialize(repeating: 0, count: channels * micReadCapacity)

        let mic = MicCapture(device: device, targetRate: captureFormat.sampleRate,
                             targetChannels: channels) { abl, frames in
            ring.write(abl, frames: frames)
        }
        try mic.start()
        micCapture = mic
        if let micDesc = mic.captureDescription {
            captureDescription = "\(captureDescription ?? "") + mic (\(micDesc))"
        }
    }

    /// Mic-only: the mic IOProc clocks the file directly. Its buffers (already at the
    /// capture format) get the mic level then go straight to the shared sink.
    private func startMicOnly(device: AudioDeviceInfo) throws {
        guard let captureFormat, let sink = captureSink else { return }
        let micGainLock = self.micGainLock
        let mic = MicCapture(device: device, targetRate: captureFormat.sampleRate,
                             targetChannels: Int(captureFormat.channelCount)) { abl, frames in
            let gain = micGainLock.withLock { $0 }
            if gain != 1 { scaleBuffers(abl, by: gain) }
            sink(abl, frames)
        }
        try mic.start()
        micCapture = mic
    }

    private func freeMixScratch() {
        micReadScratch?.deallocate()
        micReadScratch = nil
        micReadCapacity = 0
        mixBuffer = nil
    }
}

/// Multiply every sample in the buffer list by a scalar gain, in place.
private func scaleBuffers(_ abl: UnsafeMutableAudioBufferListPointer, by gain: Float) {
    var g = gain
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let p = data.assumingMemoryBound(to: Float.self)
        vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
    }
}

/// Add `frames` of interleaved source samples (×gain) into an interleaved destination
/// buffer list of the same channel count. Used to sum the mic feed into the tap feed.
private func addInterleaved(into dst: UnsafeMutableAudioBufferListPointer,
                            from src: UnsafeMutablePointer<Float>, frames: Int,
                            channels: Int, gain: Float) {
    guard dst.count == 1, let data = dst[0].mData else { return }
    let out = data.assumingMemoryBound(to: Float.self)
    let n = min(frames * channels, Int(dst[0].mDataByteSize) / MemoryLayout<Float>.size)
    if gain == 1 {
        vDSP_vadd(out, 1, src, 1, out, 1, vDSP_Length(n))
    } else {
        var g = gain
        // out = out + src * gain
        vDSP_vsma(src, 1, &g, out, 1, out, 1, vDSP_Length(n))
    }
}

/// Frames-per-channel of an input buffer list, without allocating (interleaved = one
/// packed buffer of `channels` channels; planar = one buffer per channel).
private func frameCount(_ abl: UnsafeMutableAudioBufferListPointer, channels: Int) -> Int {
    guard abl.count > 0 else { return 0 }
    if abl.count == 1 {
        let ch = Int(abl[0].mNumberChannels)
        let per = max(1, ch)
        return Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * per)
    }
    return Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
}

/// Largest absolute float sample across every buffer in the list (vectorized, RT-safe).
private func peakOf(_ abl: UnsafeMutableAudioBufferListPointer) -> Float {
    var peak: Float = 0
    for buffer in abl {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        guard count > 0 else { continue }
        var m: Float = 0
        vDSP_maxmgv(samples, 1, &m, count)   // max magnitude
        if m > peak { peak = m }
    }
    return peak
}

/// memcpy each buffer of one list into the matching buffer of another, clamping to
/// the smaller size and zero-filling any remaining output space.
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
