import Foundation
import CoreAudio
import AppKit

/// A process that Core Audio knows about as an audio participant. `isPlaying`
/// reflects whether it is currently producing output, so callers can prefer
/// live sources.
public struct AudioProcessInfo: Identifiable, Sendable, Hashable {
    public let id: AudioObjectID   // Core Audio process object
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let isPlaying: Bool
}

/// A Dock application together with every Core Audio process that plays audio on
/// its behalf. Browsers and Electron apps render audio from helper processes whose
/// pids differ from the app's own, so capture must target the whole group.
public struct AudioAppInfo: Identifiable, Sendable, Hashable {
    public let pid: pid_t            // the application's own pid
    public let bundleID: String
    public let name: String
    /// HAL processes attributed to this app. Empty if the app has never
    /// registered with the HAL — i.e. hasn't touched audio since launch.
    public let processes: [AudioProcessInfo]

    public var isPlaying: Bool { processes.contains { $0.isPlaying } }
    /// The pids a tap should target: every attributed HAL process, or the app's
    /// own pid as a last resort (creating the tap then fails with a clear
    /// "is it playing audio?" error if the app never became an audio participant).
    public var tapPIDs: [pid_t] { processes.isEmpty ? [pid] : processes.map(\.pid) }
    public var id: String { bundleID }
}

/// The audio-source universe split the way users think about it: applications
/// (with their helpers folded in), and HAL registrants no Dock app owns —
/// daemons, which are only worth surfacing while one is audibly playing.
public struct AudioSourceCatalog: Sendable {
    public let apps: [AudioAppInfo]
    public let daemons: [AudioProcessInfo]
}

/// Activity Monitor-style attribution: maps a helper pid to the application that
/// spawned it. Private-but-stable libsystem symbol, resolved dynamically so its
/// absence merely degrades grouping to bundle-id-prefix matching.
private let responsiblePID: (@convention(c) (pid_t) -> pid_t)? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2) /* RTLD_DEFAULT */,
                          "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
}()

public enum AudioProcesses {

    /// Live list of every HAL audio participant, re-enumerated on each call so it
    /// stays in sync as processes launch, quit, or start/stop playing. Raw view —
    /// UIs should almost always present `catalog()` instead.
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

    /// Group the raw HAL process list under the Dock applications responsible for
    /// them. Every regular app appears (even if it has no HAL presence yet, so it
    /// can be picked before it first plays); whatever can't be attributed to an
    /// app is returned separately as a daemon.
    public static func catalog() -> AudioSourceCatalog {
        let processes = list()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let appByPid = Dictionary(running.map { ($0.processIdentifier, $0) },
                                  uniquingKeysWith: { first, _ in first })

        var owned: [pid_t: [AudioProcessInfo]] = [:]
        var daemons: [AudioProcessInfo] = []
        for process in processes {
            if let owner = owningApp(of: process, running: running, appByPid: appByPid) {
                owned[owner.processIdentifier, default: []].append(process)
            } else {
                daemons.append(process)
            }
        }

        let apps = running.map { app in
            AudioAppInfo(pid: app.processIdentifier,
                         bundleID: app.bundleIdentifier ?? "",
                         name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                         processes: owned[app.processIdentifier] ?? [])
        }.sorted {
            ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased())
        }

        return AudioSourceCatalog(apps: apps, daemons: daemons)
    }

    /// Resolve a bundle id (exact, or parent/helper prefix in either direction)
    /// to its application group.
    public static func app(matching bundleID: String) -> AudioAppInfo? {
        let apps = catalog().apps
        return apps.first { $0.bundleID == bundleID }
            ?? apps.first { $0.bundleID.hasPrefix("\(bundleID).") || bundleID.hasPrefix("\($0.bundleID).") }
    }

    /// Which Dock application does this HAL process play audio for?
    private static func owningApp(of process: AudioProcessInfo,
                                  running: [NSRunningApplication],
                                  appByPid: [pid_t: NSRunningApplication]) -> NSRunningApplication? {
        // 1. The process IS a Dock app.
        if process.pid > 0, let direct = appByPid[process.pid] { return direct }
        // 2. Responsibility attribution — how Activity Monitor folds helpers
        //    (including bundle-id-less ones like caphost) under their app.
        if process.pid > 0, let responsible = responsiblePID?(process.pid),
           responsible != process.pid, let owner = appByPid[responsible] {
            return owner
        }
        // 3. Bundle-id prefix: com.vivaldi.Vivaldi.helper ↔ com.vivaldi.Vivaldi.
        if !process.bundleID.isEmpty {
            return running.first {
                guard let appID = $0.bundleIdentifier else { return false }
                return process.bundleID == appID
                    || process.bundleID.hasPrefix(appID + ".")
                    || appID.hasPrefix(process.bundleID + ".")
            }
        }
        return nil
    }
}
