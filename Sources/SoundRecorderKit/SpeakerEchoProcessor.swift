import CWebRTCAudio
import Foundation

/// Serial-worker interface to the bundled WebRTC AEC3 processor.
final class SpeakerEchoProcessor {
    static let sampleRate = 48_000
    static let blockFrames = 480
    private let handle: OpaquePointer

    init() throws {
        guard let handle = td_apm_create() else {
            throw CA.Error(status: -1, context: "Could not initialize WebRTC echo cancellation")
        }
        self.handle = handle
    }

    deinit { td_apm_destroy(handle) }

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>,
                 microphone: UnsafePointer<Float>, cleaned: UnsafeMutablePointer<Float>) throws {
        let status = td_apm_process(handle, left, right, microphone, cleaned, 0)
        guard status == 0 else {
            throw CA.Error(status: status, context: "WebRTC echo cancellation failed")
        }
    }
}
