import AppKit
import CoreAudio
import IOKit
import NachoComboCore

/// Sound devices, the microphone and external display brightness in one place. Devices are listed and switched through
/// Core Audio; the microphone is muted on the device itself (or turned down to zero when it has no mute), so every app
/// hears silence. External displays get standard DDC/CI brightness commands. No permission is needed.
final class DeviceControlModule: NSObject, FeatureModule {
    let id = ModuleID.deviceControl
    var optionsProvider: () -> GadgetOptions = { .defaults }
    var onChange: (() -> Void)?
    /// A status item appeared or went away (the red microphone): the menu bar divider is re-created.
    var onStatusItemsChanged: (() -> Void)?

    private(set) var running = false
    private(set) var devices: [AudioDevice] = []
    private(set) var micMuted = false
    /// Input volume before muting a microphone that has no mute switch.
    private var savedInputVolume: [AudioObjectID: Float32] = [:]
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var micItem: NSStatusItem?
    let displays = ExternalDisplays()

    func start() -> ModuleState {
        guard !running else { return .running }
        running = true
        devices = CoreAudioBridge.devices()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var address = CoreAudioBridge.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                DispatchQueue.main.async { self?.devicesChanged(selector) }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main,
                                                   block) == noErr {
                listeners.append((address, block))
            }
        }
        displays.onChange = { [weak self] in self?.onChange?() }
        displays.refresh()
        return .running
    }

    func stop() {
        for (address, block) in listeners {
            var copy = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &copy, DispatchQueue.main, block)
        }
        listeners.removeAll()
        // Off means off: a muted microphone is given back.
        if micMuted { setMicMuted(false) }
        removeMicItem()
        displays.forget()
        devices = []
        running = false
    }

    func applyOptions() { refreshMicItem() }

    private func devicesChanged(_ selector: AudioObjectPropertySelector) {
        guard running else { return }
        let before = Set(devices.map { $0.uid })
        devices = CoreAudioBridge.devices()
        if selector == kAudioHardwarePropertyDevices {
            // A preferred device that just connected becomes the one in use.
            let options = optionsProvider()
            let arrived = devices.filter { !before.contains($0.uid) }
            if let output = arrived.first(where: { $0.uid == options.preferredOutput && $0.hasOutput }) {
                CoreAudioBridge.setDefault(output.id, input: false)
            }
            if let input = arrived.first(where: { $0.uid == options.preferredInput && $0.hasInput }) {
                CoreAudioBridge.setDefault(input.id, input: true)
            }
            displays.refresh()
        }
        // A new microphone stays muted while mute is on.
        if micMuted, selector != kAudioHardwarePropertyDefaultOutputDevice { applyMute(true) }
        onChange?()
    }

    // MARK: output

    var outputs: [AudioDevice] { devices.filter { $0.hasOutput } }
    var inputs: [AudioDevice] { devices.filter { $0.hasInput } }
    var currentOutput: AudioDevice? { device(CoreAudioBridge.defaultDevice(input: false)) }
    var currentInput: AudioDevice? { device(CoreAudioBridge.defaultDevice(input: true)) }

    private func device(_ id: AudioObjectID) -> AudioDevice? { devices.first { $0.id == id } }

    func selectOutput(_ uid: String) {
        guard let device = outputs.first(where: { $0.uid == uid }) else { return }
        CoreAudioBridge.setDefault(device.id, input: false)
        onChange?()
    }

    func selectInput(_ uid: String) {
        guard let device = inputs.first(where: { $0.uid == uid }) else { return }
        CoreAudioBridge.setDefault(device.id, input: true)
        if micMuted { applyMute(true) }
        onChange?()
    }

    /// The next output device, round the list.
    func nextOutput() {
        let list = outputs
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == currentOutput?.id } ?? -1
        let next = list[(index + 1) % list.count]
        CoreAudioBridge.setDefault(next.id, input: false)
        Toast.show("Sound: \(next.name)", near: NSEvent.mouseLocation)
        onChange?()
    }

    var outputVolume: Float32? { currentOutput.flatMap { CoreAudioBridge.volume($0.id, input: false) } }

    func setOutputVolume(_ value: Float32) {
        guard let device = currentOutput else { return }
        CoreAudioBridge.setVolume(device.id, input: false, value)
    }

    // MARK: microphone

    func toggleMic() { setMicMuted(!micMuted) }

    func setMicMuted(_ muted: Bool) {
        guard running || !muted else { return }
        micMuted = muted
        applyMute(muted)
        if running { Toast.show(muted ? "Microphone muted" : "Microphone on", near: NSEvent.mouseLocation) }
        refreshMicItem()
        onChange?()
    }

    private func applyMute(_ muted: Bool) {
        let targets = muted ? [CoreAudioBridge.defaultDevice(input: true)] : Array(Set(savedInputVolume.keys).union(
            [CoreAudioBridge.defaultDevice(input: true)]))
        for id in targets where id != 0 {
            if CoreAudioBridge.setMute(id, input: true, muted) { continue }
            // No mute switch on this device: turn its input down instead, and back up afterwards.
            if muted {
                if savedInputVolume[id] == nil { savedInputVolume[id] = CoreAudioBridge.volume(id, input: true) ?? 1 }
                CoreAudioBridge.setVolume(id, input: true, 0)
            } else if let volume = savedInputVolume[id] {
                CoreAudioBridge.setVolume(id, input: true, volume)
            }
        }
        if !muted { savedInputVolume.removeAll() }
    }

    private func refreshMicItem() {
        let wanted = running && micMuted && optionsProvider().micIndicator
        if wanted, micItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let image = UI.symbol("mic.slash.fill", size: 14, weight: .semibold, description: "Microphone muted") {
                item.button?.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            }
            item.button?.toolTip = "Microphone muted — click to unmute"
            item.button?.setAccessibilityLabel("Microphone muted, unmute")
            item.button?.target = self
            item.button?.action = #selector(micItemClicked)
            micItem = item
            onStatusItemsChanged?()
        } else if !wanted {
            removeMicItem()
        }
    }

    private func removeMicItem() {
        guard let item = micItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        micItem = nil
    }

    @objc private func micItemClicked() { setMicMuted(false) }

    // MARK: displays

    func changeBrightness(by step: Int) {
        guard !displays.list.isEmpty else {
            Toast.show("No external display that accepts brightness commands", near: NSEvent.mouseLocation)
            return
        }
        for display in displays.list { displays.setBrightness(display.index, displays.brightness(display.index) + step) }
        Toast.show("External displays: \(displays.brightness(0))%", near: NSEvent.mouseLocation)
    }

    var diagnostics: [String: String] {
        [
            "running": "\(running)",
            "devices": "\(devices.count)",
            "output": currentOutput?.name ?? "-",
            "input": currentInput?.name ?? "-",
            "micMuted": "\(micMuted)",
            "micItem": "\(micItem != nil)",
            "listeners": "\(listeners.count)",
            "externalDisplays": "\(displays.list.count)",
            "ddcAvailable": "\(ExternalDisplays.available)",
        ]
    }
}

/// What Device Control's controls show.
struct DeviceSnapshot {
    var outputs: [(uid: String, name: String)] = []
    var inputs: [(uid: String, name: String)] = []
    var output: String?
    var input: String?
    var volume: Double?
    var micMuted = false
    var displays: [(index: Int, name: String, brightness: Int)] = []
}

extension DeviceControlModule {
    var snapshot: DeviceSnapshot {
        guard running else { return DeviceSnapshot() }
        return DeviceSnapshot(outputs: outputs.map { ($0.uid, $0.name) }, inputs: inputs.map { ($0.uid, $0.name) },
                              output: currentOutput?.uid, input: currentInput?.uid, volume: outputVolume.map { Double($0) },
                              micMuted: micMuted,
                              displays: displays.list.map { ($0.index, $0.name, displays.brightness($0.index)) })
    }
}

// MARK: - Core Audio

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
}

enum CoreAudioBridge {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func devices() -> [AudioDevice] {
        var address = self.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else {
                return nil
            }
            let output = channels(id, scope: kAudioObjectPropertyScopeOutput) > 0
            let input = channels(id, scope: kAudioObjectPropertyScopeInput) > 0
            // Aggregate helpers some apps install show up without channels; they are of no use here.
            guard output || input else { return nil }
            return AudioDevice(id: id, uid: uid, name: name, hasOutput: output, hasInput: input)
        }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let text = value else { return nil }
        return text.takeRetainedValue() as String
    }

    static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultDevice(input: Bool) -> AudioObjectID {
        var address = self.address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func setDefault(_ device: AudioObjectID, input: Bool) {
        var id = device
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        let selectors = input ? [kAudioHardwarePropertyDefaultInputDevice]
                              : [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
        for selector in selectors {
            var address = self.address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &id)
        }
    }

    /// The main volume, or the first two channels' average when the device only has per-channel volume.
    static func volume(_ id: AudioObjectID, input: Bool) -> Float32? {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        for elements in [[kAudioObjectPropertyElementMain], [1, 2]] {
            var values: [Float32] = []
            for element in elements {
                var address = self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
                guard AudioObjectHasProperty(id, &address) else { continue }
                var value = Float32(0)
                var size = UInt32(MemoryLayout<Float32>.size)
                if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr { values.append(value) }
            }
            if !values.isEmpty { return values.reduce(0, +) / Float32(values.count) }
        }
        return nil
    }

    static func setVolume(_ id: AudioObjectID, input: Bool, _ value: Float32) {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var level = min(1, max(0, value))
        let size = UInt32(MemoryLayout<Float32>.size)
        var main = self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain)
        if settable(id, &main) {
            AudioObjectSetPropertyData(id, &main, 0, nil, size, &level)
            return
        }
        for element: AudioObjectPropertyElement in [1, 2] {
            var address = self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            if settable(id, &address) { AudioObjectSetPropertyData(id, &address, 0, nil, size, &level) }
        }
    }

    /// Returns false when the device has no mute switch for that direction.
    @discardableResult
    static func setMute(_ id: AudioObjectID, input: Bool, _ muted: Bool) -> Bool {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        var address = self.address(kAudioDevicePropertyMute, scope: scope, element: kAudioObjectPropertyElementMain)
        guard settable(id, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func settable(_ id: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(id, &address, &settable) == noErr && settable.boolValue
    }
}

// MARK: - External displays (DDC/CI)

/// Brightness of external monitors through DDC/CI, on Apple silicon (IOAVService). The service functions are looked up
/// at run time; on a Mac without them, or a monitor that ignores DDC, the list is simply empty.
final class ExternalDisplays {
    struct Display { let index: Int; let name: String }

    private typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias TransferI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static let create: CreateWithService? = symbol("IOAVServiceCreateWithService")
    private static let write: TransferI2C? = symbol("IOAVServiceWriteI2C")
    private static let read: TransferI2C? = symbol("IOAVServiceReadI2C")

    private static func symbol<T>(_ name: String) -> T? {
        guard let library = library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var available: Bool { create != nil && write != nil }

    private var services: [CFTypeRef] = []
    private var levels: [Int: Int] = [:]
    private(set) var list: [Display] = []
    private let queue = DispatchQueue(label: "com.mafianacho.nachocombo.ddc")
    var onChange: (() -> Void)?

    func refresh() {
        services = ExternalDisplays.findServices()
        let names = NSScreen.screens.filter { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(number) == 0
        }.map { $0.localizedName }
        list = services.indices.map { index in
            Display(index: index, name: names.count == services.count ? names[index] : "External Display \(index + 1)")
        }
        // Read the current brightness in the background (each read takes a moment on the display's bus).
        for index in services.indices where levels[index] == nil {
            let service = services[index]
            queue.async { [weak self] in
                let value = ExternalDisplays.readBrightness(service)
                DispatchQueue.main.async {
                    self?.levels[index] = value ?? 50
                    self?.onChange?()
                }
            }
        }
    }

    func forget() {
        services = []
        list = []
        levels = [:]
    }

    func brightness(_ index: Int) -> Int { levels[index] ?? 50 }

    func setBrightness(_ index: Int, _ value: Int) {
        guard services.indices.contains(index) else { return }
        let level = min(100, max(0, value))
        levels[index] = level
        let service = services[index]
        queue.async { ExternalDisplays.writeVCP(service, code: 0x10, value: UInt16(level)) }
    }

    private static func findServices() -> [CFTypeRef] {
        guard let create = create else { return [] }
        var found: [CFTypeRef] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let av = create(kCFAllocatorDefault, service)?.takeRetainedValue() else { continue }
            found.append(av)
        }
        return found
    }

    /// DDC/CI "Set VCP Feature": 0x51 source, length, opcode 0x03, the code, the value, a checksum.
    private static func writeVCP(_ service: CFTypeRef, code: UInt8, value: UInt16) {
        guard let write = write else { return }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        for _ in 0..<2 {
            usleep(10_000)
            _ = packet.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
        }
    }

    /// DDC/CI "Get VCP Feature" for brightness; nil when the display does not answer.
    private static func readBrightness(_ service: CFTypeRef) -> Int? {
        guard let write = write, let read = read else { return nil }
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = request[0..<3].reduce(UInt8(0x6E ^ 0x51)) { $0 ^ $1 }
        for _ in 0..<3 {
            _ = request.withUnsafeMutableBytes { write(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let status = reply.withUnsafeMutableBytes { read(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            // reply: source, length, 0x02 (reply), result, code, type, max hi, max lo, current hi, current lo, checksum
            if status == KERN_SUCCESS, reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10 {
                let maximum = Int(reply[6]) << 8 | Int(reply[7])
                let current = Int(reply[8]) << 8 | Int(reply[9])
                guard maximum > 0 else { return nil }
                return current * 100 / maximum
            }
            usleep(20_000)
        }
        return nil
    }
}
