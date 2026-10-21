import CoreAudio
import Foundation

/// Device changes invalidate the measured echo path. End the session rather than
/// continuing through an unknown output or disconnected input.
final class SpeakerDeviceGuard {
    private let queue = DispatchQueue(label: "com.nfl.tapdeck.speaker-devices")
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(microphone: AudioDeviceInfo, failure: @escaping (String) -> Void) throws {
        let properties: [(AudioObjectID, AudioObjectPropertySelector)] = [
            (AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
            (microphone.id, kAudioDevicePropertyDeviceIsAlive),
            (microphone.id, kAudioDevicePropertyNominalSampleRate),
            (try AudioSystem.defaultOutputDevice(), kAudioDevicePropertyNominalSampleRate)
        ]
        do {
            for (device, selector) in properties {
                func currentValue() throws -> Double {
                    if selector == kAudioDevicePropertyNominalSampleRate {
                        return try CA.value(device, selector, default: Float64(0))
                    }
                    return Double(try CA.value(device, selector, default: UInt32(0)))
                }
                let expected = try currentValue()
                var address = AudioObjectPropertyAddress(mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let block: AudioObjectPropertyListenerBlock = { _, _ in
                    if (try? currentValue()) != expected {
                        failure("Audio device changed during speaker recording. The recording must be restarted.")
                    }
                }
                try CA.check(AudioObjectAddPropertyListenerBlock(device, &address, queue, block), "Speaker device listener")
                registrations.append((device, address, block))
            }
        } catch { stop(); throw error }
    }
    func stop() {
        for (device, var address, block) in registrations {
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        registrations.removeAll()
    }
    deinit { stop() }
}
