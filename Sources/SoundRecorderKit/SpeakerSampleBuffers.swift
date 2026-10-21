/// Owns the worker's reusable PCM memory, including during a failed pipeline init.
final class SpeakerSampleBuffers {
    private let storage: UnsafeMutablePointer<Float>
    let stereo: UnsafeMutablePointer<Float>
    let raw: UnsafeMutablePointer<Float>
    let clean: UnsafeMutablePointer<Float>
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let mixed: UnsafeMutablePointer<Float>

    init() {
        storage = .allocate(capacity: 3840)
        storage.initialize(repeating: 0, count: 3840)
        stereo = storage
        raw = storage + 960
        clean = storage + 1440
        left = storage + 1920
        right = storage + 2400
        mixed = storage + 2880
    }
    deinit { storage.deallocate() }
}
