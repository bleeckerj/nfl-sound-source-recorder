import AVFoundation
import CoreAudio
import Foundation
import os

/// Copies timestamped input on device callbacks; runs AEC and source writing on
/// one worker. The normal recorder sink receives only the cleaned stereo mix.
final class SpeakerRecordingPipeline: @unchecked Sendable {
    struct Controls {
        let save: Bool
        let microphoneGain: Float
        let sourceGain: Float
    }
    struct Report: Codable {
        let backend: String
        let sampleRate: Int
        let appAudio: String
        let rawMicrophone: String
        let cleanedMicrophone: String
        let frames: UInt64
        let completed: Bool
        let error: String?
    }
    static let rate = 48_000.0
    private let app = TimestampedAudioRing(channels: 2)
    private let microphone = TimestampedAudioRing(channels: 1)
    private let processor: SpeakerEchoProcessor
    private let appWriter: AsyncAudioFileWriter
    private let rawWriter: AsyncAudioFileWriter
    private let cleanWriter: AsyncAudioFileWriter
    let directory: URL
    private let output: (UnsafeMutableAudioBufferListPointer, Int) -> Void
    private let controls: () -> Controls
    private let queue = DispatchQueue(label: "com.nfl.tapdeck.speaker-processing", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var cursor: Int64?
    private var frames: UInt64 = 0
    private var stopped = false
    private let errorState = OSAllocatedUnfairLock(initialState: Optional<String>.none)
    var error: String? { errorState.withLock { $0 } }
    private let tapRate: Double
    private let samples = SpeakerSampleBuffers()

    static func validate(microphone: AudioDeviceInfo, output: AudioDeviceInfo?, mute: Bool) throws {
        guard output == nil, !mute else {
            throw CA.Error(status: -1, context: "Speaker mode requires Route to None and original app audio unmuted")
        }
        let defaults = try SpeakerQualification.defaultDevices()
        let transport = try CA.value(microphone.id, kAudioDevicePropertyTransportType, default: UInt32(0))
        guard defaults.speaker.builtIn, transport == kAudioDeviceTransportTypeBuiltIn else {
            throw CA.Error(status: -1, context: "Speaker mode currently requires the built-in Mac microphone and speakers")
        }
    }

    init(fileURL: URL, tapRate: Double, controls: @escaping () -> Controls,
         output: @escaping (UnsafeMutableAudioBufferListPointer, Int) -> Void) throws {
        self.tapRate = tapRate
        self.controls = controls
        self.output = output
        processor = try SpeakerEchoProcessor()
        let directory = fileURL.deletingPathExtension().appendingPathExtension("sources")
        self.directory = directory
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CA.Error(status: -1, context: "Speaker source folder already exists: \(directory.path)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func writer(_ name: String, channels: AVAudioChannelCount) throws -> AsyncAudioFileWriter {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate,
                                       channels: channels, interleaved: true)!
            return try AsyncAudioFileWriter(fileURL: directory.appendingPathComponent(name),
                settings: RecordingFormat.caf.settings(sampleRate: Self.rate, channels: channels), captureFormat: format)
        }
        appWriter = try writer("app-audio.caf", channels: 2)
        rawWriter = try writer("microphone-raw.caf", channels: 1)
        cleanWriter = try writer("microphone-cleaned.caf", channels: 1)
        try saveReport()
    }

    deinit { timer?.cancel() }

    func receiveApp(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int, time: AudioTimeStamp) {
        app.write(abl, frames: frames, rate: tapRate, timestamp: time)
    }
    func receiveMicrophone(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int, time: AudioTimeStamp) {
        microphone.write(abl, frames: frames, rate: Self.rate, timestamp: time)
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain(final: false) }
        self.timer = timer
        timer.resume()
    }
    func finish(error message: String? = nil) {
        queue.sync {
            if let message { fail(message) }
            guard !stopped else { return }
            timer?.cancel(); timer = nil
            drain(final: true)
            stopped = true
            appWriter.finish(); rawWriter.finish(); cleanWriter.finish()
            for writer in [appWriter, rawWriter, cleanWriter] {
                if let failure = writer.failure { fail(failure) }
            }
            do { try saveReport() } catch { fail("Could not save speaker session: \(error)") }
        }
    }
    func reportFailure(_ message: String) {
        queue.sync {
            fail(message)
            do { try saveReport() } catch { fail("Could not update speaker session: \(error)") }
        }
    }
    private func fail(_ message: String) { errorState.withLock { if $0 == nil { $0 = message } } }
    private func drain(final: Bool) {
        guard error == nil else { return }
        let stereo = samples.stereo, raw = samples.raw, clean = samples.clean
        let left = samples.left, right = samples.right, mixed = samples.mixed
        let bounds = microphone.bounds
        guard !bounds.invalid, !app.bounds.invalid else { fail("Audio host timestamp became unavailable"); return }
        guard let first = bounds.first else { return }
        if cursor == nil { cursor = first }
        // Hold 40 ms so the app callback for the same host time can arrive first.
        let limit = bounds.end - (final ? 0 : 1920)
        while let position = cursor, position + 480 <= limit {
            let missing = microphone.read(from: position, frames: 480, into: raw)
            guard missing <= 2 else {
                fail("Microphone timeline discontinuity or processing overrun: \(missing)/480 frames missing, worker lag \(Double(bounds.end - position) / 48_000) seconds")
                return
            }
            _ = app.read(from: position, frames: 480, into: stereo)
            for i in 0..<480 { left[i] = stereo[2 * i]; right[i] = stereo[2 * i + 1] }
            do { try processor.process(left: left, right: right, microphone: raw, cleaned: clean) }
            catch { fail("\(error)"); return }
            let controls = controls()
            for i in 0..<480 {
                let mic = clean[i] * controls.microphoneGain
                mixed[2 * i] = stereo[2 * i] * controls.sourceGain + mic
                mixed[2 * i + 1] = stereo[2 * i + 1] * controls.sourceGain + mic
            }
            if controls.save {
                withBuffer(stereo, channels: 2) { appWriter.enqueue($0, frames: 480) }
                withBuffer(raw, channels: 1) { rawWriter.enqueue($0, frames: 480) }
                withBuffer(clean, channels: 1) { cleanWriter.enqueue($0, frames: 480) }
                frames += 480
            }
            withBuffer(mixed, channels: 2) { output($0, 480) }
            cursor = position + 480
            for writer in [appWriter, rawWriter, cleanWriter] {
                if let failure = writer.failure { fail(failure); return }
            }
        }
    }
    private func withBuffer(_ samples: UnsafeMutablePointer<Float>, channels: Int,
                            _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(480 * channels * 4), mData: samples))
        withUnsafeMutablePointer(to: &buffer) { body(UnsafeMutableAudioBufferListPointer($0)) }
    }
    private func saveReport() throws {
        let report = Report(backend: "WebRTC AudioProcessing 2.1 / AEC3", sampleRate: 48_000,
            appAudio: "app-audio.caf", rawMicrophone: "microphone-raw.caf",
            cleanedMicrophone: "microphone-cleaned.caf", frames: frames, completed: stopped && error == nil, error: error)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}
