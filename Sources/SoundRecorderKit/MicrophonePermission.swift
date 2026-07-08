import Foundation
import AVFoundation

/// Checks and requests **Microphone** consent (`kTCCServiceMicrophone`). Unlike the
/// System Audio Recording consent that process taps need (see `AudioCapturePermission`,
/// which has no public API), the microphone has a first-class public API, so this is a
/// thin wrapper over `AVCaptureDevice`. Requires `NSMicrophoneUsageDescription` in the
/// bundle's Info.plist.
public enum MicrophonePermission {

    public enum Status: String {
        case authorized, denied, notDetermined, restricted, unknown
    }

    /// Non-blocking status check (no prompt).
    public static func status() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        @unknown default:    return .unknown
        }
    }

    /// Shows the system prompt if the status is undetermined; calls back with the result.
    public static func request(_ completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }
}
