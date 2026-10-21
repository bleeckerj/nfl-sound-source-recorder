import AVFoundation
import CoreAudio
import Foundation

/// A bounded hardware diagnostic. This does not enable speaker mode in the app.
public final class SpeakerQualification {
    public struct Device: Codable, Equatable, Sendable {
        public let id: AudioObjectID
        public let name: String
        public let uid: String
        public let builtIn: Bool
    }

    public struct Report: Codable, Sendable {
        public let startedAt: Date
        public let duration: Double
        public let microphone: Device
        public let speaker: Device
        public let rawFrames: Int64
        public let processedFrames: Int64
        public let droppedRawFrames: UInt64
        public let droppedProcessedFrames: UInt64
        public let processingLatencySeconds: Double
        public let completed: Bool
    }

    public static func defaultDevices() throws -> (microphone: Device, speaker: Device) {
        func describe(_ id: AudioObjectID) throws -> Device {
            guard id != 0 else { throw CA.Error(status: -1, context: "No default audio device") }
            let transport = try CA.value(id, kAudioDevicePropertyTransportType, default: UInt32(0))
            return Device(id: id, name: try CA.string(id, kAudioObjectPropertyName),
                          uid: try CA.string(id, kAudioDevicePropertyDeviceUID),
                          builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
        }
        // Match the app's main-thread HAL bootstrap: resolve output before input.
        let output = try AudioSystem.defaultOutputDevice()
        let input = try AudioSystem.defaultInputDevice()
        return try (describe(input), describe(output))
    }

    /// Refuse previously used destinations before creating or opening any source file.
    static func prepareDestination(_ directory: URL) throws {
        let files = ["microphone-raw.caf", "microphone-processed.caf", "qualification.json", "failure.json"]
        for name in files {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
                throw CA.Error(status: -1, context: "Qualification destination already contains \(name)")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Caller must have microphone consent and keep its main run loop alive.
    /// Stop before analyzing or opening the output files.
    public init(directory: URL) throws {
        let devices = try Self.defaultDevices()
        guard devices.microphone.builtIn, devices.speaker.builtIn else {
            throw CA.Error(status: -1, context: "Speaker qualification requires built-in default input and output")
        }
        self.directory = directory
        self.microphone = devices.microphone
        self.speaker = devices.speaker
    }

    private let directory: URL
    private let microphone: Device
    private let speaker: Device
    private let processed = VoiceProcessingCapture()
    private var raw: MicCapture?
    private var rawWriter: AsyncAudioFileWriter?
    private var processedWriter: AsyncAudioFileWriter?
    private var startedAt: Date?
    private var report: Report?

    public func start() throws {
        guard startedAt == nil else { throw CA.Error(status: -1, context: "Qualification already started") }
        guard MicrophonePermission.status() == .authorized else {
            throw CA.Error(status: -1, context: "Microphone permission is required")
        }
        try Self.prepareDestination(directory)
        let rawFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                     channels: 1, interleaved: true)!
        let rawSink = try AsyncAudioFileWriter(fileURL: directory.appendingPathComponent("microphone-raw.caf"),
            settings: RecordingFormat.caf.settings(sampleRate: 48_000, channels: 1), captureFormat: rawFormat)
        rawWriter = rawSink
        let processedSink = try AsyncAudioFileWriter(fileURL: directory.appendingPathComponent("microphone-processed.caf"),
            settings: RecordingFormat.caf.settings(sampleRate: 48_000, channels: 1), captureFormat: rawFormat)
        processedWriter = processedSink
        do {
            try processed.start { input, frames, _ in
                processedSink.enqueue(input, frames: frames)
            }
            guard processed.format?.sampleRate == 48_000, processed.format?.channelCount == 1 else {
                throw CA.Error(status: -1, context: "Native processing requires a different format; qualification cannot continue")
            }
            let mic = AudioDeviceInfo(id: microphone.id, uid: microphone.uid, name: microphone.name,
                                      outputChannels: 0, inputChannels: 1)
            let rawCapture = MicCapture(device: mic, targetRate: 48_000, targetChannels: 1) { input, frames in
                rawSink.enqueue(input, frames: frames)
            }
            raw = rawCapture
            try rawCapture.start()
            startedAt = Date()
        } catch {
            raw?.stop()
            processed.stop()
            rawSink.finish()
            processedSink.finish()
            throw error
        }
    }

    @discardableResult public func stop() throws -> Report {
        if let report { return report }
        guard let startedAt else { throw CA.Error(status: -1, context: "Qualification has not started") }
        raw?.stop()
        raw = nil
        processed.stop()
        rawWriter?.finish()
        processedWriter?.finish()
        let rawFile = try AVAudioFile(forReading: directory.appendingPathComponent("microphone-raw.caf"))
        let processedFile = try AVAudioFile(forReading: directory.appendingPathComponent("microphone-processed.caf"))
        let report = Report(startedAt: startedAt, duration: Date().timeIntervalSince(startedAt),
                            microphone: microphone, speaker: speaker,
                            rawFrames: rawFile.length, processedFrames: processedFile.length,
                            droppedRawFrames: rawWriter?.droppedFrames ?? 0,
                            droppedProcessedFrames: processedWriter?.droppedFrames ?? 0,
                            processingLatencySeconds: processed.reportedLatency,
                            completed: rawFile.length > 0 && processedFile.length > 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("qualification.json"), options: .atomic)
        self.report = report
        return report
    }

    deinit {
        raw?.stop()
        processed.stop()
        rawWriter?.finish()
        processedWriter?.finish()
    }
}
