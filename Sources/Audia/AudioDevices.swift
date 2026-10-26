import Foundation
import CoreAudio
import Combine

/// One selectable audio output: either the system default or a real Core Audio
/// device with output streams.
struct AudioOutputDevice: Identifiable, Hashable {
    /// nil for the synthetic “System Default” entry.
    let deviceID: AudioDeviceID?
    /// nil for the synthetic “System Default” entry.
    let uid: String?
    let name: String
    let isDefault: Bool
    let transport: UInt32?

    var id: String { uid ?? "system-default" }
    var isSystemDefault: Bool { uid == nil }

    var icon: String {
        guard let transport else { return "airplayvideo" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "hifispeaker.fill"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker"
        case kAudioDeviceTransportTypeVirtual:
            return "speaker.wave.2"
        case kAudioDeviceTransportTypeAggregate:
            return "square.stack.3d.up"
        default:
            return "hifispeaker"
        }
    }
}

private enum AudioOutputCatalog {
    struct Device {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32
        let isDefault: Bool
    }

    static func list() -> [Device] {
        let defaultID = defaultOutputDeviceID()
        var result: [Device] = []
        for id in allDeviceIDs() {
            guard hasOutputStreams(id),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString)
                    ?? stringProperty(id, selector: kAudioObjectPropertyName) else {
                continue
            }
            let transport = uint32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            result.append(Device(id: id,
                                 uid: uid,
                                 name: name,
                                 transport: transport,
                                 isDefault: id == defaultID))
        }
        return result.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                              &address, 0, nil, &size, base)
        }
        return status == noErr ? ids : []
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func stringProperty(_ objectID: AudioObjectID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private static func uint32Property(_ objectID: AudioObjectID,
                                       selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}

/// The real output devices available to the process, plus a “System Default”
/// entry. Refreshes on a light timer so plugging in headphones/AirPlay updates
/// the menu without restarting the app.
@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var selectedUID: String? =
        UserDefaults.standard.string(forKey: "audioOutputDeviceUID")

    private var refreshTimer: Timer?
    private let systemDefault = AudioOutputDevice(deviceID: nil,
                                                  uid: nil,
                                                  name: "System Default",
                                                  isDefault: true,
                                                  transport: nil)

    var selectedDevice: AudioOutputDevice {
        if let selectedUID,
           let device = devices.first(where: { $0.uid == selectedUID }) {
            return device
        }
        return systemDefault
    }

    /// nil means “follow the system default output”.
    var effectiveUID: String? {
        guard let selectedUID,
              devices.contains(where: { $0.uid == selectedUID }) else { return nil }
        return selectedUID
    }

    /// The Core Audio device whose system volume should be controlled. nil asks
    /// `SystemVolume` to resolve the current system default output.
    var effectiveDeviceID: AudioDeviceID? {
        guard let selectedUID,
              let device = devices.first(where: { $0.uid == selectedUID }) else { return nil }
        return device.deviceID
    }

    private init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let catalog = AudioOutputCatalog.list()
        let listed = catalog.map {
            AudioOutputDevice(deviceID: $0.id,
                              uid: $0.uid,
                              name: $0.name,
                              isDefault: $0.isDefault,
                              transport: $0.transport)
        }
        let updated = [systemDefault] + listed
        if updated != devices {
            devices = updated
        }

        if let selectedUID,
           !catalog.contains(where: { $0.uid == selectedUID }) {
            self.selectedUID = nil
            UserDefaults.standard.removeObject(forKey: "audioOutputDeviceUID")
        }
    }

    func select(_ device: AudioOutputDevice) {
        guard device.isSystemDefault
                || devices.contains(where: { $0.uid == device.uid }) else { return }
        selectedUID = device.uid
        if let uid = device.uid {
            UserDefaults.standard.set(uid, forKey: "audioOutputDeviceUID")
        } else {
            UserDefaults.standard.removeObject(forKey: "audioOutputDeviceUID")
        }
    }
}
