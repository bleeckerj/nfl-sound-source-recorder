import Foundation
import XCTest
@testable import SoundRecorderKit

final class SpeakerQualificationTests: XCTestCase {
    func testPreviouslyUsedQualificationFolderIsPreserved() throws {
        for name in ["microphone-raw.caf", "microphone-processed.caf", "qualification.json", "failure.json"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = Data("original diagnostic evidence".utf8)
            let file = directory.appendingPathComponent(name)
            try original.write(to: file)
            XCTAssertThrowsError(try SpeakerQualification.prepareDestination(directory))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [name])
        }
    }

    func testNewDestinationPreservesUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try SpeakerQualification.prepareDestination(directory)
        let file = directory.appendingPathComponent("notes.txt")
        try Data("operator notes".utf8).write(to: file)
        try SpeakerQualification.prepareDestination(directory)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "operator notes")
    }
}
