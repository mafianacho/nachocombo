import AppKit
import NachoComboCore

/// The Mac side of the data gadget tools (NACHO-149): `DataGadgetRunner` asks, the modules answer. Main thread only.
/// Files and pictures for Nacho go through `PetHandoff` (the user's next chat message), never into a tool result.
/// Nothing here logs clipboard text, file contents or screen pictures.
final class AppDataGadgetHost: DataGadgetHost {
    private weak var monitor: SystemMonitorModule?
    private weak var disk: DiskMapModule?
    private weak var clipboard: ClipboardModule?
    private weak var shelf: ShelfModule?
    private weak var capture: CaptureFloatModule?

    init(monitor: SystemMonitorModule, disk: DiskMapModule, clipboard: ClipboardModule, shelf: ShelfModule, capture: CaptureFloatModule) {
        self.monitor = monitor
        self.disk = disk
        self.clipboard = clipboard
        self.shelf = shelf
        self.capture = capture
    }

    // MARK: monitor

    func monitorStats() -> MonitorStats? { monitor?.toolStats }

    // MARK: disk

    func diskState() -> DiskMapState { disk?.toolState ?? .empty }

    var homeDirectory: String { NSHomeDirectory() }

    func isDirectory(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    func diskStartScan(path: String) -> Bool { disk?.toolScan(path: path) ?? false }

    // MARK: clipboard

    func clipboardItems() -> [ClipboardItem] { clipboard?.history.search("") ?? [] }

    func clipboardCopyAgain(id: UUID) -> Bool {
        guard let module = clipboard, let item = module.history.item(id) else { return false }
        module.copy(item)
        return true
    }

    func clipboardClearUnpinned() -> Int {
        guard let module = clipboard else { return 0 }
        let before = module.history.items.filter { !$0.pinned }.count
        module.clearHistory()
        return before
    }

    // MARK: shelf

    func shelfRows() -> [ShelfRow] {
        (shelf?.store.items ?? []).map { item in
            ShelfRow(item) { url in
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { Int64($0) }
            }
        }
    }

    func shelfHandToNacho(id: UUID) -> String? {
        guard let item = shelf?.store.items.first(where: { $0.id == id }) else { return "선반에서 그 항목을 찾지 못했어요." }
        guard let pet = PetHandoff.module, PetHandoff.available else { return "나초가 꺼져 있어서 첨부하지 못했어요." }
        switch item.kind {
        case .file, .image:
            guard let url = item.fileURL else { return "원본 파일을 찾지 못했어요." }
            return pet.attach(fileURL: url)
        case .text:
            pet.attachText(item.text ?? "", title: item.title)
            return nil
        case .link:
            pet.attachText(item.text ?? "", title: "link")
            return nil
        }
    }

    func shelfForget(id: UUID) -> Bool { shelf?.forget(id) ?? false }

    func shelfClear() -> Int {
        guard let module = shelf else { return 0 }
        let n = module.store.items.count
        module.clear()
        return n
    }

    // MARK: capture

    func captureAsk(_ mode: CaptureAskMode, done: @escaping (CaptureAskResult) -> Void) {
        guard let module = capture else { return done(.failed("캡처 플로트가 꺼져 있어요.")) }
        guard PetHandoff.available, let pet = PetHandoff.module else { return done(.failed("나초가 꺼져 있어서 첨부하지 못했어요.")) }
        module.captureForNacho(screen: mode == .screen) { [weak pet] image in
            guard let image = image else { return done(.cancelled) }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return done(.failed("캡처한 그림을 만들지 못했어요."))
            }
            guard let pet = pet else { return done(.failed("나초가 꺼져 있어서 첨부하지 못했어요.")) }
            if let refusal = pet.attach(name: FloatingCaptureWindow.fileName, data: png, mime: "image/png") {
                return done(.failed(refusal))
            }
            done(.attached)
        }
    }

    func pinnedCaptures() -> [(width: Int, height: Int)] { capture?.pinnedSizes ?? [] }

    func captureCloseAll() -> Int {
        guard let module = capture else { return 0 }
        let n = module.floats.count
        module.closeAll()
        return n
    }
}

extension SystemMonitorModule {
    /// The numbers of `monitor_stats` (NACHO-149); nil before the first sample.
    var toolStats: MonitorStats? { toolSnapshot.map(MonitorStats.init(snapshot:)) }
}

extension MonitorStats {
    init(snapshot s: MonitorSnapshot) {
        self.init(cpuPercent: s.cpu?.busy, memoryPercent: s.memory?.usedPercent, memoryUsedBytes: s.memory?.used,
                  memoryTotalBytes: s.memory?.total, memoryPressurePercent: s.pressure, swapUsedBytes: s.memory == nil ? nil : s.swapUsed,
                  networkDownBytesPerSecond: s.netDown, networkUpBytesPerSecond: s.netUp, diskUsedPercent: s.volume?.usedPercent,
                  batteryPercent: s.battery?.percent, batteryCharging: s.battery?.charging, onPowerAdapter: s.battery?.onAC,
                  cpuTemperatureCelsius: s.cpuTemperature, gpuTemperatureCelsius: s.gpuTemperature, loadAverage: s.loadAverage,
                  topProcesses: s.processesSampled ? s.processes : [])
    }
}
