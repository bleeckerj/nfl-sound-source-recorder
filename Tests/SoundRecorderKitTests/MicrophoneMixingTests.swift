import AVFoundation
import XCTest
@testable import SoundRecorderKit

final class MicrophoneMixingTests: XCTestCase {
    private func buffer(interleaved: Bool, frames: Int = 8) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for frame in 0..<frames { set(buffer, frame: frame, channel: channel, value: 0) }
        }
        return buffer
    }

    private func set(_ buffer: AVAudioPCMBuffer, frame: Int, channel: Int, value: Float) {
        let pointer = buffer.floatChannelData![buffer.format.isInterleaved ? 0 : channel]
        pointer[frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)] = value
    }

    private func sample(_ buffer: AVAudioPCMBuffer, frame: Int, channel: Int) -> Float {
        let pointer = buffer.floatChannelData![buffer.format.isInterleaved ? 0 : channel]
        return pointer[frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)]
    }

    func testMicrophoneIsAddedToBothTapLayoutsWithGain() {
        for interleaved in [true, false] {
            let tap = buffer(interleaved: interleaved)
            for frame in 0..<8 { set(tap, frame: frame, channel: 0, value: 0.125) }
            let microphone = (0..<8).flatMap { _ in [Float(0), Float(0.25)] }
            microphone.withUnsafeBufferPointer {
                addInterleaved(into: UnsafeMutableAudioBufferListPointer(tap.mutableAudioBufferList),
                               from: $0.baseAddress!, frames: 8, channels: 2, gain: 2)
            }
            for frame in 0..<8 {
                XCTAssertEqual(sample(tap, frame: frame, channel: 0), 0.125)
                XCTAssertEqual(sample(tap, frame: frame, channel: 1), 0.5,
                               "Mic input 2 must survive mixing; interleaved=\(interleaved)")
            }
        }
    }

    func testRightChannelMeterMatchesForPackedAndPlanarAudio() {
        var levels: [[Float]] = []
        for interleaved in [true, false] {
            let input = buffer(interleaved: interleaved, frames: 4096)
            for frame in 0..<4096 {
                set(input, frame: frame, channel: 1,
                    value: Float(sin(2 * Double.pi * 1000 * Double(frame) / 48_000)) * 0.5)
            }
            let meter = SpectrumMeter()
            meter.ingest(UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList), frames: 4096)
            levels.append(meter.levels())
            XCTAssertGreaterThan(meter.levels()[5], 0.5, "Input 2 must move the meter")
        }
        for band in 0..<SpectrumMeter.bandCount {
            XCTAssertEqual(levels[0][band], levels[1][band], accuracy: 0.0001)
        }
    }

    func testMixedMicrophoneSurvivesFileWrite() throws {
        for interleaved in [true, false] {
            let mixed = buffer(interleaved: interleaved, frames: 512)
            let microphone = (0..<512).flatMap { _ in [Float(0), Float(0.25)] }
            microphone.withUnsafeBufferPointer {
                addInterleaved(into: UnsafeMutableAudioBufferListPointer(mixed.mutableAudioBufferList),
                               from: $0.baseAddress!, frames: 512, channels: 2, gain: 1)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapdeck-mix-\(UUID()).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AsyncAudioFileWriter(fileURL: url,
                settings: RecordingFormat.caf.settings(sampleRate: 48_000, channels: 2),
                captureFormat: mixed.format)
            writer.enqueue(UnsafeMutableAudioBufferListPointer(mixed.mutableAudioBufferList), frames: 512)
            writer.finish()
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let recorded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
            try file.read(into: recorded)
            XCTAssertEqual(recorded.frameLength, 512)
            for frame in 0..<Int(recorded.frameLength) {
                XCTAssertEqual(sample(recorded, frame: frame, channel: 0), 0)
                XCTAssertEqual(sample(recorded, frame: frame, channel: 1), 0.25)
            }
        }
    }

    func testMissingTapBufferClearsPreviousAudio() {
        let source = buffer(interleaved: false)
        let destination = buffer(interleaved: false)
        for frame in 0..<8 { set(destination, frame: frame, channel: 1, value: 0.5) }
        let sourceABL = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let data = sourceABL[1].mData
        sourceABL[1].mData = nil
        defer { sourceABL[1].mData = data }
        copyBuffers(from: sourceABL, to: UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList))
        for frame in 0..<8 { XCTAssertEqual(sample(destination, frame: frame, channel: 1), 0) }
    }

    func testMicrophoneClocksRecordingBeforeDuringAndAfterTapAudio() throws {
        for interleaved in [true, false] {
            let format = buffer(interleaved: interleaved).format
            let microphone = buffer(interleaved: true, frames: 4096)
            let tap = buffer(interleaved: interleaved, frames: 4096)
            for frame in 0..<4096 {
                set(microphone, frame: frame, channel: 1, value: 0.25)
                set(tap, frame: frame, channel: 0, value: 0.125)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tapdeck-clock-\(UUID()).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try AsyncAudioFileWriter(fileURL: url,
                settings: RecordingFormat.caf.settings(sampleRate: 48_000, channels: 2),
                captureFormat: format)
            var deliveredFrames = 0
            let mixer = try MicrophoneDrivenMixer(format: format) { output, frames in
                deliveredFrames += frames
                writer.enqueue(output, frames: frames)
            }
            let input = UnsafeMutableAudioBufferListPointer(microphone.mutableAudioBufferList)
            // No tap callbacks at all: the microphone must still reach disk.
            mixer.receiveMicrophone(input, frames: 4096, microphoneGain: 1, sourceGain: 1)
            XCTAssertEqual(deliveredFrames, 4096)
            mixer.receiveTap(UnsafeMutableAudioBufferListPointer(tap.mutableAudioBufferList), frames: 4096)
            mixer.receiveMicrophone(input, frames: 4096, microphoneGain: 2, sourceGain: 2)
            // The tap ring is now empty. Old source samples must not repeat.
            mixer.receiveMicrophone(input, frames: 4096, microphoneGain: 1, sourceGain: 1)
            XCTAssertEqual(deliveredFrames, 12_288)
            writer.finish()

            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let recorded = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 12_288)!
            try file.read(into: recorded)
            XCTAssertEqual(recorded.frameLength, 12_288)
            for block in 0..<3 {
                let start = block * 4096
                let left = (start..<(start + 4096)).map { sample(recorded, frame: $0, channel: 0) }
                let right = (start..<(start + 4096)).map { sample(recorded, frame: $0, channel: 1) }
                XCTAssertEqual(left, Array(repeating: block == 1 ? Float(0.25) : 0, count: 4096))
                XCTAssertEqual(right, Array(repeating: block == 1 ? Float(0.5) : 0.25, count: 4096))
            }
        }
    }
}
