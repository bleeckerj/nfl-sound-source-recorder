import Foundation
import CoreAudio

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

    /// All hardware devices that expose at least one output channel.
    public static func outputDevices() throws -> [AudioDeviceInfo] {
        let ids = try CA.array(systemObject, kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        var result: [AudioDeviceInfo] = []
        for id in ids {
            let channels = (try? outputChannelCount(id)) ?? 0
            guard channels > 0 else { continue }
            let uid = (try? CA.string(id, kAudioDevicePropertyDeviceUID)) ?? ""
            let name = (try? CA.string(id, kAudioObjectPropertyName)) ?? "(unknown)"
            result.append(AudioDeviceInfo(id: id, uid: uid, name: name, outputChannels: channels))
        }
        return result
    }

    static func outputChannelCount(_ device: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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
