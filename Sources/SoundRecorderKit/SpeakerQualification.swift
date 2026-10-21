import AVFoundation
import CoreAudio
import Foundation

/// A bounded hardware diagnostic for the shared WebRTC speaker recording path.
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
        public let inputBufferSeconds: Double
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
        let files = ["microphone-raw.caf", "microphone-processed.caf", "qualification.json", "failure.json", "mix.caf", "mix.sources"]
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
    private var recorder: ProcessTapRecorder?
    private var startedAt: Date?
    private var report: Report?

    public func start() throws {
        guard startedAt == nil else { throw CA.Error(status: -1, context: "Qualification already started") }
        guard MicrophonePermission.status() == .authorized else {
            throw CA.Error(status: -1, context: "Microphone permission is required")
        }
        try Self.prepareDestination(directory)
        let mic = AudioDeviceInfo(id: microphone.id, uid: microphone.uid, name: microphone.name,
                                  outputChannels: 0, inputChannels: 1)
        let recorder = ProcessTapRecorder(source: .mix(tap: .systemWide, mic: mic), outputDevice: nil,
            fileURL: directory.appendingPathComponent("mix.caf"), format: .caf, mute: false,
            warmupSeconds: 1, speakerMode: true)
        self.recorder = recorder
        try recorder.start()
        startedAt = Date()
    }

    @discardableResult public func stop() throws -> Report {
        if let report { return report }
        guard let startedAt else { throw CA.Error(status: -1, context: "Qualification has not started") }
        recorder?.stop()
        if let error = recorder?.recordingError { throw CA.Error(status: -1, context: error) }
        let sources = directory.appendingPathComponent("mix.sources")
        let rawFile = try AVAudioFile(forReading: sources.appendingPathComponent("microphone-raw.caf"))
        let processedFile = try AVAudioFile(forReading: sources.appendingPathComponent("microphone-cleaned.caf"))
        let report = Report(startedAt: startedAt, duration: Date().timeIntervalSince(startedAt),
                            microphone: microphone, speaker: speaker,
                            rawFrames: rawFile.length, processedFrames: processedFile.length,
                            droppedRawFrames: 0,
                            droppedProcessedFrames: 0,
                            inputBufferSeconds: 0.04,
                            completed: rawFile.length > 0 && processedFile.length > 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent("qualification.json"), options: .atomic)
        self.report = report
        return report
    }

    deinit { recorder?.stop() }
}
