import Foundation

/// Checks and requests the **System Audio Recording** consent that Core Audio
/// process taps require (`kTCCServiceAudioCapture`) — a distinct TCC service from
/// Microphone. There is no public API for this, so (like Rogue Amoeba's AudioCap
/// sample) we call the TCC private framework's `TCCAccessPreflight` /
/// `TCCAccessRequest` via `dlsym`. Requires `NSAudioCaptureUsageDescription` in the
/// bundle's Info.plist and a code-signed binary.
public enum AudioCapturePermission {

    public enum Status: String {
        case authorized, denied, notDetermined, unknown
    }

    nonisolated(unsafe) private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    nonisolated(unsafe) private static let preflightFn: PreflightFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    nonisolated(unsafe) private static let requestFn: RequestFn? = {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFn.self)
    }()

    /// Non-blocking status check (no prompt). 0 = granted, 1 = denied, 2 = not determined.
    public static func status() -> Status {
        guard let preflightFn else { return .unknown }
        switch preflightFn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        case 2: return .notDetermined
        default: return .unknown
        }
    }

    /// Shows the system prompt if the status is undetermined; calls back with the result.
    public static func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestFn else { completion(false); return }
        requestFn(service, nil, completion)
    }
}
