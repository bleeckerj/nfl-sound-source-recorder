import Foundation
import XCTest
@testable import SoundRecorderKit

final class SpeakerModeConfigurationTests: XCTestCase {
    func testSelectionsRequireBothAppAudioAndMicrophone() {
        XCTAssertEqual(SpeakerModeConfiguration.selectionError(hasAppAudio: false, hasMicrophone: true),
                       .appAudioRequired)
        XCTAssertEqual(SpeakerModeConfiguration.selectionError(hasAppAudio: true, hasMicrophone: false),
                       .microphoneRequired)
        XCTAssertEqual(SpeakerModeConfiguration.selectionError(hasAppAudio: false, hasMicrophone: false),
                       .appAudioRequired)
        XCTAssertNil(SpeakerModeConfiguration.selectionError(hasAppAudio: true, hasMicrophone: true))
    }

    func testInvalidSpeakerSourcesFailBeforeOpeningDevicesOrCreatingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // An invalid device ID makes accidental hardware access fail with a different error.
        let mic = AudioDeviceInfo(id: 0, uid: "test-mic", name: "Test microphone",
                                  outputChannels: 0, inputChannels: 1)
        let cases: [(ProcessTapRecorder.Source, SpeakerModeConfiguration.SelectionError)] = [
            (.microphone(mic), .appAudioRequired),
            (.tap(.systemWide), .microphoneRequired),
        ]
        for (source, expected) in cases {
            let file = directory.appendingPathComponent("mix.m4a")
            let recorder = ProcessTapRecorder(source: source, outputDevice: nil, fileURL: file,
                                              mute: false, speakerMode: true)
            XCTAssertThrowsError(try recorder.start()) { error in
                XCTAssertEqual(error as? SpeakerModeConfiguration.SelectionError, expected)
                XCTAssertEqual(error.localizedDescription, expected.description)
                XCTAssertFalse(String(describing: error).contains("OSStatus"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
