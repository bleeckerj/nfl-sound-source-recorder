import Foundation
import CoreAudio
import AppKit

/// An application that Core Audio knows about as an audio participant — i.e. an
/// audio-first application. `isPlaying` reflects whether it is currently
/// producing output, so callers can prefer live sources.
public struct AudioProcessInfo: Identifiable, Sendable, Hashable {
    public let id: AudioObjectID   // Core Audio process object
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let isPlaying: Bool
}

public enum AudioProcesses {

    /// Live list of audio-first applications, re-enumerated on every call so it
    /// stays in sync as apps launch, quit, or start/stop playing.
    public static func list() -> [AudioProcessInfo] {
        let objects = (try? CA.array(
            AudioSystem.systemObject,
            kAudioHardwarePropertyProcessObjectList,
            of: AudioObjectID.self
        )) ?? []

        var result: [AudioProcessInfo] = []
        for object in objects {
            let pid: pid_t = (try? CA.value(object, kAudioProcessPropertyPID, default: pid_t(-1))) ?? -1
            let bundleID = (try? CA.string(object, kAudioProcessPropertyBundleID)) ?? ""
            let playingFlag: UInt32 = (try? CA.value(object, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0

            // Skip system/helper audio objects with no identity.
            if bundleID.isEmpty && pid <= 0 { continue }

            let friendlyName = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? (bundleID.isEmpty ? "pid \(pid)" : bundleID)

            result.append(AudioProcessInfo(
                id: object,
                pid: pid,
                bundleID: bundleID,
                name: friendlyName,
                isPlaying: playingFlag != 0
            ))
        }

        // Currently-playing apps first, then alphabetical.
        return result.sorted {
            ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased())
        }
    }
}
