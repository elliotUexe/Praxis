import Foundation
import CoreAudio

/// Reads and sets the capture level of the default input device.
///
/// This is hardware gain, applied before the converter, and it is the only kind that helps
/// a transcript. Multiplying already-captured samples raises the speaker and the room by
/// exactly the same amount — the signal-to-noise ratio is untouched, and Whisper normalises
/// what it is given anyway. Turning the microphone up captures more of a quiet voice above
/// the converter's own noise floor, which is a different thing entirely.
///
/// It is the same control as System Settings > Son > Entrée, so changing it here changes it
/// there. That is deliberate: a private copy inside Praxis would be a second number that
/// disagrees with the one the system shows.
enum AudioInputGain {
    struct Device {
        let id: AudioDeviceID
        let name: String
        /// Nil when the device exposes no input volume at all — an iPhone used as a
        /// microphone, or an aggregate device, typically does not.
        let volume: Float?
        let isSettable: Bool
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    static func defaultInputDevice() -> Device? {
        guard let id = defaultInputDeviceID() else { return nil }
        var address = volumeAddress

        guard AudioObjectHasProperty(id, &address) else {
            return Device(id: id, name: name(of: id), volume: nil, isSettable: false)
        }

        var settable: DarwinBoolean = false
        AudioObjectIsPropertySettable(id, &address, &settable)

        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let read = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)

        return Device(
            id: id,
            name: name(of: id),
            volume: read == noErr ? Float(value) : nil,
            isSettable: settable.boolValue
        )
    }

    @discardableResult
    static func setVolume(_ volume: Float, on deviceID: AudioDeviceID) -> Bool {
        var address = volumeAddress
        var value = Float32(min(max(volume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return (status == noErr && id != 0) ? id : nil
    }

    private static func name(of deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfName) == noErr,
              let cfName else {
            return "Entrée audio"
        }
        return cfName.takeRetainedValue() as String
    }
}
