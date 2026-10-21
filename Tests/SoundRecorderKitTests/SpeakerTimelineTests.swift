import AVFoundation
import XCTest
@testable import SoundRecorderKit

final class SpeakerTimelineTests: XCTestCase {
    func testTimestampedResamplingPreservesStereoAndHandlesSilentApp() throws {
        let ring = TimestampedAudioRing(channels: 2)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                  channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441)!
        buffer.frameLength = 441
        for i in 0..<441 { buffer.floatChannelData![0][i] = 0.25; buffer.floatChannelData![1][i] = -0.5 }
        var time = AudioTimeStamp()
        time.mHostTime = AVAudioTime.hostTime(forSeconds: 2)
        time.mFlags = .hostTimeValid
        ring.write(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: 441,
                   rate: 44_100, timestamp: time)
        let start = try XCTUnwrap(ring.bounds.first)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 960)
        defer { output.deallocate() }
        XCTAssertEqual(ring.read(from: start, frames: 480, into: output), 0)
        for i in 0..<480 { XCTAssertEqual(output[2 * i], 0.25); XCTAssertEqual(output[2 * i + 1], -0.5) }
        XCTAssertEqual(ring.read(from: start + 480, frames: 480, into: output), 480)
        for i in 0..<960 { XCTAssertEqual(output[i], 0) }
    }

    func testSpeakerSourcesStayAlignedWhenAppIsSilent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mix.caf")
        var outputFrames = 0
        let pipeline = try SpeakerRecordingPipeline(fileURL: file, tapRate: 48_000,
            controls: { .init(save: true, microphoneGain: 1, sourceGain: 1) },
            output: { _, frames in outputFrames += frames })
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for i in 0..<480 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 300 / 48000)) * 0.1 }
        for block in 0..<20 {
            var time = AudioTimeStamp()
            time.mHostTime = AVAudioTime.hostTime(forSeconds: 2 + Double(block) * 0.01)
            time.mFlags = .hostTimeValid
            pipeline.receiveMicrophone(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), frames: 480, time: time)
        }
        pipeline.finish()
        XCTAssertNil(pipeline.error)
        XCTAssertEqual(outputFrames, 9600)
        let sources = file.deletingPathExtension().appendingPathExtension("sources")
        for name in ["app-audio.caf", "microphone-raw.caf", "microphone-cleaned.caf"] {
            XCTAssertEqual(try AVAudioFile(forReading: sources.appendingPathComponent(name)).length, 9600)
        }
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: sources.appendingPathComponent("session.json"))) as! [String: Any]
        XCTAssertEqual(report["completed"] as? Bool, true)
    }
}
