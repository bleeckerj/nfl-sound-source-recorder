import XCTest
@testable import SoundRecorderKit

final class ScopeSignalClassifierTests: XCTestCase {
    func testTracksRecentNearMonoAndStereoWithSettling() {
        var classifier = ScopeSignalClassifier()
        let left: [Float] = (0..<512).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let nearMono = left.map { $0 * 0.99 }
        let stereo: [Float] = (0..<512).map { Float(cos(Double($0) * 0.1)) * 0.5 }

        for _ in 0..<11 { XCTAssertFalse(classifier.update(left: left, right: nearMono)) }
        XCTAssertTrue(classifier.update(left: left, right: nearMono))
        for _ in 0..<11 { XCTAssertTrue(classifier.update(left: left, right: stereo)) }
        XCTAssertFalse(classifier.update(left: left, right: stereo))
        for _ in 0..<12 { _ = classifier.update(left: left, right: nearMono) }
        XCTAssertTrue(classifier.isNearMono)
    }

    func testSilenceDoesNotSelectMonoOrCompleteATransition() {
        var classifier = ScopeSignalClassifier()
        let silence = [Float](repeating: 0, count: 512)
        for _ in 0..<20 { XCTAssertFalse(classifier.update(left: silence, right: silence)) }
        let tone = [Float](repeating: 0.5, count: 512)
        for _ in 0..<11 { _ = classifier.update(left: tone, right: tone) }
        XCTAssertFalse(classifier.update(left: silence, right: silence))
        XCTAssertFalse(classifier.update(left: tone, right: tone))
    }
}
