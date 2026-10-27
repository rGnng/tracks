import Foundation
import CoreAudio
import AudioToolbox

/// Reads and writes the macOS output volume. This is deliberately separate from
/// `PlayerState.volume`, which attenuates AVPlayer. It is used when the selected
/// output option owns the macOS output volume.
enum SystemVolume {
    static func current(deviceID: AudioDeviceID? = nil) -> Double? {
        guard let device = deviceID ?? defaultOutputDevice() else { return nil }

        let value: Float32?
        if let virtual = scalar(device: device,
                                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                element: kAudioObjectPropertyElementMain) {
            value = virtual
        } else if let main = scalar(device: device,
                                    selector: kAudioDevicePropertyVolumeScalar,
                                    element: kAudioObjectPropertyElementMain) {
            value = main
        } else {
            let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
                .compactMap {
                    scalar(device: device,
                           selector: kAudioDevicePropertyVolumeScalar,
                           element: $0)
                }
            guard !channels.isEmpty else { return nil }
            value = channels.reduce(0, +) / Float32(channels.count)
        }
        guard let value else { return nil }
        if isMuted(device: device) == true { return 0 }
        return clamped(Double(value))
    }

    @discardableResult
    static func set(_ value: Double, deviceID: AudioDeviceID? = nil) -> Bool {
        guard let device = deviceID ?? defaultOutputDevice() else { return false }
        let clampedValue = clamped(value)
        let value = Float32(clampedValue)

        var didSet = setScalar(device: device,
                               selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                               element: kAudioObjectPropertyElementMain,
                               value: value)
        if !didSet {
            didSet = setScalar(device: device,
                               selector: kAudioDevicePropertyVolumeScalar,
                               element: kAudioObjectPropertyElementMain,
                               value: value)
        }
        if !didSet {
            for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
                if setScalar(device: device,
                             selector: kAudioDevicePropertyVolumeScalar,
                             element: element,
                             value: value) {
                    didSet = true
                }
            }
        }

        // Core Audio does not clear the system mute flag when the scalar volume
        // is raised. Manage it explicitly so volume-up actually unmutes.
        let didSetMute = setMuted(clampedValue <= 0, device: device)
        return didSet || didSetMute
    }

    private static func isMuted(device: AudioDeviceID) -> Bool? {
        if let value = uint32(device: device,
                              selector: kAudioDevicePropertyMute,
                              element: kAudioObjectPropertyElementMain) {
            return value != 0
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { uint32(device: device, selector: kAudioDevicePropertyMute, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.allSatisfy { $0 != 0 }
    }

    private static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        let value: UInt32 = muted ? 1 : 0
        if setUInt32(device: device,
                     selector: kAudioDevicePropertyMute,
                     element: kAudioObjectPropertyElementMain,
                     value: value) {
            return true
        }
        var didSet = false
        for element in [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)] {
            if setUInt32(device: device,
                         selector: kAudioDevicePropertyMute,
                         element: element,
                         value: value) {
                didSet = true
            }
        }
        return didSet
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != 0 else {
            return nil
        }
        return device
    }

    private static func scalar(device: AudioDeviceID,
                               selector: AudioObjectPropertySelector,
                               element: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func uint32(device: AudioDeviceID,
                               selector: AudioObjectPropertySelector,
                               element: AudioObjectPropertyElement) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func setUInt32(device: AudioDeviceID,
                                  selector: AudioObjectPropertySelector,
                                  element: AudioObjectPropertyElement,
                                  value: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func setScalar(device: AudioDeviceID,
                                  selector: AudioObjectPropertySelector,
                                  element: AudioObjectPropertyElement,
                                  value: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else {
            return false
        }
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
