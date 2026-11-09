import AVFoundation
import Foundation

/// Writes comparison audio for the explicit speaker qualification command.
final class SpeakerQualificationTracks {
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
    private let appWriter: AsyncAudioFileWriter
    private let rawWriter: AsyncAudioFileWriter
    private let cleanWriter: AsyncAudioFileWriter
    let directory: URL
    private var frames: UInt64 = 0

    init(directory: URL) throws {
        self.directory = directory
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CA.Error(status: -1, context: "Speaker source folder already exists: \(directory.path)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func writer(_ name: String, channels: AVAudioChannelCount) throws -> AsyncAudioFileWriter {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeakerRecordingPipeline.rate,
                                       channels: channels, interleaved: true)!
            return try AsyncAudioFileWriter(fileURL: directory.appendingPathComponent(name),
                settings: RecordingFormat.caf.settings(sampleRate: SpeakerRecordingPipeline.rate, channels: channels), captureFormat: format)
        }
        appWriter = try writer("app-audio.caf", channels: 2)
        rawWriter = try writer("microphone-raw.caf", channels: 1)
        cleanWriter = try writer("microphone-cleaned.caf", channels: 1)
        try saveReport(stopped: false, error: nil)
    }

    func append(app: UnsafeMutablePointer<Float>, raw: UnsafeMutablePointer<Float>,
                clean: UnsafeMutablePointer<Float>) {
        withBuffer(app, channels: 2) { appWriter.enqueue($0, frames: 480) }
        withBuffer(raw, channels: 1) { rawWriter.enqueue($0, frames: 480) }
        withBuffer(clean, channels: 1) { cleanWriter.enqueue($0, frames: 480) }
        frames += 480
    }

    var failure: String? { appWriter.failure ?? rawWriter.failure ?? cleanWriter.failure }

    func finish() {
        appWriter.finish()
        rawWriter.finish()
        cleanWriter.finish()
    }

    private func withBuffer(_ samples: UnsafeMutablePointer<Float>, channels: Int,
                            _ body: (UnsafeMutableAudioBufferListPointer) -> Void) {
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
            mDataByteSize: UInt32(480 * channels * 4), mData: samples))
        withUnsafeMutablePointer(to: &buffer) { body(UnsafeMutableAudioBufferListPointer($0)) }
    }
    func saveReport(stopped: Bool, error: String?) throws {
        let report = Report(backend: "WebRTC AudioProcessing 2.1 / AEC3", sampleRate: 48_000,
            appAudio: "app-audio.caf", rawMicrophone: "microphone-raw.caf",
            cleanedMicrophone: "microphone-cleaned.caf", frames: frames, completed: stopped && error == nil, error: error)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
}
