import CoreAudio
import Foundation

/// The Mac's audio inputs and which one Loquor records from: "System Default"
/// (follows macOS, e.g. AirPods when they connect, back to the built-in mic when
/// they're removed), or one device the user picked. A picked device that's gone
/// falls back to the system default.
@MainActor
final class Microphones: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var systemDefault: Device?
    /// The chosen device's UID, or nil for System Default.
    @Published var chosenUID: String? {
        didSet { UserDefaults.standard.set(chosenUID, forKey: "microphone") }
    }

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        chosenUID = UserDefaults.standard.string(forKey: "microphone")
        refresh()
        // Keep the list and the default current as devices come and go.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            listeners.append((address, block))
        }
    }

    /// The chosen device if it's connected.
    var chosen: Device? { chosenUID.flatMap { uid in devices.first { $0.uid == uid } } }
    /// A device was chosen but isn't connected right now.
    var chosenIsMissing: Bool { chosenUID != nil && chosen == nil }
    /// What the next recording will use.
    var active: Device? { chosen ?? systemDefault }

    /// The device to record from: the chosen one, else macOS's default input as it is
    /// right now (looked up at the start of each recording, so it follows AirPods in
    /// and out). Opening it by id, rather than through the engine's hidden default
    /// wrapper, keeps the log and the menu honest about which mic is used.
    var deviceForRecording: AudioDeviceID? { active?.id }

    func refresh() {
        let ids = Self.allDeviceIDs().filter(Self.hasInput)
        var seen: [String: Int] = [:]
        let raw = ids.map { (id: $0, uid: Self.string($0, kAudioDevicePropertyDeviceUID), name: Self.string($0, kAudioObjectPropertyName)) }
        let counts = Dictionary(grouping: raw, by: \.name).mapValues(\.count)
        devices = raw.map { d in
            // Two "Studio Display Microphone"s: number them so they can be told apart.
            var name = d.name
            if counts[d.name, default: 0] > 1 {
                seen[d.name, default: 0] += 1
                name += " \(seen[d.name]!)"
            }
            return Device(id: d.id, uid: d.uid, name: name)
        }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        systemDefault = devices.first { $0.id == id }
    }

    /// The name of a device by id (for logging which one the engine really opened).
    func name(of id: AudioDeviceID) -> String {
        devices.first { $0.id == id }?.name ?? Self.string(id, kAudioObjectPropertyName)
    }

    // MARK: Core Audio

    nonisolated private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    nonisolated private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return "Unknown" }
        return value.takeRetainedValue() as String
    }
}
