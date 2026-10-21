import Foundation

/// Ends only this diagnostic if a synchronous Core Audio call stops responding.
final class QualificationWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL?
    private var phase = "device discovery"
    private var deadline = Date().addingTimeInterval(10)
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))

    init(directory: URL?) {
        self.directory = directory
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkDeadline() }
        timer.resume()
    }

    func begin(_ phase: String, seconds: TimeInterval) {
        lock.lock()
        self.phase = phase
        deadline = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    private func checkDeadline() {
        lock.lock()
        let expired = Date() > deadline
        let currentPhase = phase
        lock.unlock()
        guard expired else { return }
        let message = "Speaker diagnostic timed out during \(currentPhase)."
        if let directory {
            let destination = directory.appendingPathComponent("failure.json")
            do {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let details: [String: Any] = ["completed": false, "error": message,
                        "phase": currentPhase, "createdAt": ISO8601DateFormatter().string(from: Date())]
                    try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys])
                        .write(to: destination, options: .atomic)
                }
            } catch {
                fputs("Could not save timeout report: \(error)\n", stderr)
            }
        }
        fputs("\(message)\n", stderr)
        // Do not run teardown code that may be blocked on the same audio service.
        _exit(3)
    }

    deinit { timer.cancel() }
}
