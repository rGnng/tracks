import Foundation
import CoreAudio
import Combine

enum AudioOutputKind: Hashable {
    case systemDefault
    case systemDefaultVolumeControl
    case device
}

/// One selectable audio output: either a synthetic system-default option or a
/// real Core Audio device with output streams.
struct AudioOutputDevice: Identifiable, Hashable {
    /// nil for the synthetic system-default entries.
    let deviceID: AudioDeviceID?
    /// nil for the synthetic system-default entries.
    let uid: String?
    let name: String
    let kind: AudioOutputKind
    let transport: UInt32?

    var id: String {
        switch kind {
        case .systemDefault:
            return "system-default"
        case .systemDefaultVolumeControl:
            return "system-default-volume-control"
        case .device:
            return uid ?? "device-\(deviceID ?? 0)"
        }
    }

    /// Plain System Default leaves AVPlayer in charge of volume. The
    /// volume-control system output and every real output lock the player at
    /// 100% and control the macOS output volume instead.
    var controlsSystemVolume: Bool { kind != .systemDefault }

    var icon: String {
        if kind == .systemDefaultVolumeControl { return "speaker.wave.2" }
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
    }

    static func list() -> [Device] {
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
                                 transport: transport))
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

/// The real output devices available to the process, plus the two synthetic
/// system-default modes. Refreshes on a light timer so plugging in
/// headphones/AirPlay updates the menu without restarting the app.
@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    private static let selectionKey = "audioOutputSelection"
    static let systemDefaultID = "system-default"

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published private(set) var selectedID: String

    private var refreshTimer: Timer?
    private let systemDefault = AudioOutputDevice(deviceID: nil,
                                                 uid: nil,
                                                 name: "System Default",
                                                 kind: .systemDefault,
                                                 transport: nil)
    private let systemDefaultVolumeControl = AudioOutputDevice(
        deviceID: nil,
        uid: nil,
        name: "System Default with Volume Control",
        kind: .systemDefaultVolumeControl,
        transport: nil
    )

    var selectedDevice: AudioOutputDevice {
        devices.first { $0.id == selectedID } ?? systemDefault
    }

    /// nil means “follow the system default output”.
    var effectiveUID: String? {
        selectedDevice.kind == .device ? selectedDevice.uid : nil
    }

    /// The Core Audio device whose system volume should be controlled. nil asks
    /// `SystemVolume` to resolve the current system default output.
    var effectiveDeviceID: AudioDeviceID? {
        selectedDevice.kind == .device ? selectedDevice.deviceID : nil
    }

    private init() {
        let defaults = UserDefaults.standard
        let initialID = defaults.string(forKey: Self.selectionKey)
            ?? Self.systemDefaultID
        selectedID = initialID
        defaults.set(initialID, forKey: Self.selectionKey)

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
                              kind: .device,
                              transport: $0.transport)
        }
        let updated = [systemDefault, systemDefaultVolumeControl] + listed
        if updated != devices {
            devices = updated
        }

        if !updated.contains(where: { $0.id == selectedID }) {
            selectedID = Self.systemDefaultID
            UserDefaults.standard.set(selectedID, forKey: Self.selectionKey)
        }
    }

    func select(_ device: AudioOutputDevice) {
        guard let selected = devices.first(where: { $0.id == device.id }) else { return }
        selectedID = selected.id
        UserDefaults.standard.set(selectedID, forKey: Self.selectionKey)
    }
}
