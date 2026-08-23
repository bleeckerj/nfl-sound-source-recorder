import Foundation
import CoreAudio
import os

/// Thin, throwing wrappers around the Core Audio HAL property API so the rest of
/// the code reads like normal Swift instead of a wall of `AudioObjectGetPropertyData`.
enum CA {

    struct Error: Swift.Error, CustomStringConvertible {
        let status: OSStatus
        let context: String
        var description: String {
            "\(context) failed: OSStatus \(status) (\(fourCharString(status)))"
        }
    }

    static func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
        guard status == noErr else { throw Error(status: status, context: context()) }
    }

    // MARK: Teardown watchdog

    private static let watchdogLog = Logger(subsystem: "com.nfl.soundrecorder", category: "watchdog")

    /// Run a blocking HAL teardown call under a deadline so a wedged `coreaudiod` can never
    /// hang the caller indefinitely. `work` runs on a detached thread; if it hasn't returned
    /// within `seconds` we log, abandon it (leaking whatever it was tearing down), and return
    /// so the app can still finalize its file and UI. Returns true if `work` finished in time.
    ///
    /// This is deliberately a last-resort guard: in normal operation teardown completes in
    /// microseconds and the timeout never trips. Leaking a HAL object on the rare wedge is a
    /// far better outcome than an unkillable beachball.
    @discardableResult
    static func withTimeout(_ seconds: Double = 3, context: String = "HAL teardown",
                            _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        // Detached (not a pooled queue) so a permanently-stuck call can't starve a shared queue.
        let thread = Thread { work(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        if done.wait(timeout: .now() + seconds) == .timedOut {
            watchdogLog.error("\(context) exceeded \(seconds, format: .fixed(precision: 1))s — abandoning (leaked) to avoid a hang")
            return false
        }
        return true
    }

    // MARK: Scalar / array property reads

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        default defaultValue: T,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0
    ) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        var result = defaultValue
        try check(
            AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, &result),
            "Get property \(fourCharString(OSStatus(bitPattern: selector)))"
        )
        return result
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        of type: T.Type
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize),
            "Get property size \(fourCharString(OSStatus(bitPattern: selector)))"
        )
        let count = Int(dataSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(
                AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, buffer.baseAddress!),
                "Get property \(fourCharString(OSStatus(bitPattern: selector)))"
            )
            initialized = count
        }
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: Unmanaged<CFString>?
        try check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, &cfStr),
            "Get string property"
        )
        return cfStr?.takeRetainedValue() as String? ?? ""
    }
}

func fourCharString(_ value: OSStatus) -> String {
    let n = UInt32(bitPattern: value)
    let bytes = [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return String(value)
}

// MARK: - Domain helpers

public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let outputChannels: Int
    /// Input (recording) channels the device exposes. `0` for devices enumerated purely
    /// as output destinations; populated by `inputDevices()`.
    public let inputChannels: Int

    public init(id: AudioObjectID, uid: String, name: String,
                outputChannels: Int, inputChannels: Int = 0) {
        self.id = id
        self.uid = uid
        self.name = name
        self.outputChannels = outputChannels
        self.inputChannels = inputChannels
    }
}

public enum AudioSystem {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    /// Translate a Unix pid into the AudioObjectID Core Audio uses for that process.
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var pidValue = pid
        return try withUnsafeMutablePointer(to: &pidValue) { ptr -> AudioObjectID in
            try CA.value(
                systemObject,
                kAudioHardwarePropertyTranslatePIDToProcessObject,
                default: AudioObjectID(0),
                qualifier: UnsafeRawPointer(ptr),
                qualifierSize: UInt32(MemoryLayout<pid_t>.size)
            )
        }
    }

    public static func defaultOutputDevice() throws -> AudioObjectID {
        try CA.value(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }

    public static func defaultInputDevice() throws -> AudioObjectID {
        try CA.value(systemObject, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))
    }

    /// All hardware devices that expose at least one output channel.
    public static func outputDevices() throws -> [AudioDeviceInfo] {
        let ids = try CA.array(systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        var result: [AudioDeviceInfo] = []
        for id in ids {
            let channels = (try? channelCount(id, scope: kAudioDevicePropertyScopeOutput)) ?? 0
            guard channels > 0 else { continue }
            let uid = (try? CA.string(id, kAudioDevicePropertyDeviceUID)) ?? ""
            let name = (try? CA.string(id, kAudioObjectPropertyName)) ?? "(unknown)"
            result.append(AudioDeviceInfo(id: id, uid: uid, name: name, outputChannels: channels))
        }
        return result
    }

    /// All hardware devices that expose at least one input (recording) channel — the
    /// candidate microphones. Mirrors `outputDevices()` on the input scope.
    public static func inputDevices() throws -> [AudioDeviceInfo] {
        let ids = try CA.array(systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        var result: [AudioDeviceInfo] = []
        for id in ids {
            let channels = (try? channelCount(id, scope: kAudioDevicePropertyScopeInput)) ?? 0
            guard channels > 0 else { continue }
            let uid = (try? CA.string(id, kAudioDevicePropertyDeviceUID)) ?? ""
            let name = (try? CA.string(id, kAudioObjectPropertyName)) ?? "(unknown)"
            result.append(AudioDeviceInfo(id: id, uid: uid, name: name,
                                          outputChannels: 0, inputChannels: channels))
        }
        return result
    }

    static func outputChannelCount(_ device: AudioObjectID) throws -> Int {
        try channelCount(device, scope: kAudioDevicePropertyScopeOutput)
    }

    static func inputChannelCount(_ device: AudioObjectID) throws -> Int {
        try channelCount(device, scope: kAudioDevicePropertyScopeInput)
    }

    /// Total channels across every stream of `device` in the given scope (input or output).
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try CA.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "Stream config size")
        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPtr.deallocate() }
        try CA.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferListPtr), "Stream config")
        let ablPtr = UnsafeMutableAudioBufferListPointer(bufferListPtr.assumingMemoryBound(to: AudioBufferList.self))
        return ablPtr.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
