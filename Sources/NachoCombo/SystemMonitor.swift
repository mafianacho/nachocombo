import AppKit
import NachoComboCore

/// iStat-style system monitor: one status item per metric group (CPU, memory, disk, network, sensors),
/// each opening a dropdown panel with history charts, processes and details. Resting the pointer on a
/// card opens a flyout with a larger chart (or the disk usage ring) beside the panel.
final class SystemMonitorModule: NSObject, FeatureModule {
    let id = ModuleID.systemMonitor

    var settingsProvider: () -> MonitorSettings = { .defaults }
    var settingsChanged: (MonitorSettings) -> Void = { _ in }
    /// Our status items were re-created (the menu bar divider must move back to their left).
    var onStatusItemsRebuilt: (() -> Void)?
    var openSettings: (() -> Void)?

    private var engine: MonitorEngine?
    private var statusItems: [MonitorItem: NSStatusItem] = [:]
    private var statusViews: [MonitorItem: StatusItemView] = [:]
    private let panels = MonitorPanelController()
    private var panel: PanelContent?
    private var flyout: FlyoutContent?

    var isRunning: Bool { engine != nil }

    /// Latest numbers for the tool panel's monitor summary.
    struct Reading {
        var cpuBusy: Double?
        var memPercent: Double?
        var memUsed: UInt64 = 0
        var memTotal: UInt64 = 0
        var rx: Double?
        var tx: Double?
    }

    var latest: Reading {
        guard let s = engine?.snapshot else { return Reading() }
        return Reading(cpuBusy: s.cpu?.busy, memPercent: s.memory?.usedPercent, memUsed: s.memory?.used ?? 0,
                       memTotal: s.memory?.total ?? 0, rx: s.netDown, tx: s.netUp)
    }
    private var shownOrder: [MonitorItem] { MonitorItem.allCases.filter { statusItems[$0] != nil } }

    override init() {
        super.init()
        panels.onClose = { [weak self] _ in
            self?.panel = nil
            self?.engine?.focus = nil
        }
        panels.makeFlyout = { [weak self] make in
            guard let self = self, let engine = self.engine else { return nil }
            let content = make(self.makeContext(relayout: .flyout))
            content.update(engine)
            self.flyout = content
            return content.root
        }
        panels.onFlyoutClose = { [weak self] in self?.flyout = nil }
    }

    func start() -> ModuleState {
        guard engine == nil else { return .running }
        let engine = MonitorEngine()
        engine.publicIPAutoLookup = settingsProvider().publicIPLookup
        engine.onSample = { [weak self] in self?.render() }
        self.engine = engine
        engine.start()
        buildStatusItems()
        return .running
    }

    func stop() {
        panels.close()
        panel = nil
        removeStatusItems()
        engine?.stop()
        engine = nil
    }

    /// Re-reads the settings: re-creates status items when the shown set changed.
    func applySettings() {
        guard let engine = engine else { return }
        let settings = settingsProvider()
        engine.publicIPAutoLookup = settings.publicIPLookup
        if settings.shownItems != shownOrder {
            panels.close()
            removeStatusItems()
            buildStatusItems()
            onStatusItemsRebuilt?()
        } else if let panel = panel {
            panel.update(engine)
            flyout?.update(engine)
        }
    }

    // MARK: Status items

    private func buildStatusItems() {
        // A new status item appears left of the existing ones, so create them right-to-left.
        for item in settingsProvider().shownItems.reversed() {
            let statusItem = NSStatusBar.system.statusItem(withLength: StatusRenderer.width(for: item))
            guard let button = statusItem.button else { continue }
            let view = StatusItemView(item: item)
            view.engine = engine
            view.frame = button.bounds
            view.autoresizingMask = [.width, .height]
            button.addSubview(view)
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
            button.toolTip = "Nacho Combo · \(item.displayName)"
            button.setAccessibilityTitle("\(item.displayName) monitor")
            statusItems[item] = statusItem
            statusViews[item] = view
        }
    }

    private func removeStatusItems() {
        for statusItem in statusItems.values { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItems = [:]
        statusViews = [:]
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let item = MonitorItem(rawValue: raw) else { return }
        if panels.item == item {
            panels.close()
        } else {
            showPanel(item)
        }
    }

    private func render() {
        statusViews.values.forEach { $0.needsDisplay = true }
        guard let engine = engine else { return }
        panel?.update(engine)
        flyout?.update(engine)
    }

    // MARK: Panels

    func showPanel(_ item: MonitorItem) {
        guard let engine = engine else { return }
        panels.close()
        let content = PanelContent.make(item, context: makeContext())
        panel = content
        engine.focus = item
        content.update(engine)
        panels.show(content.root, item: item, anchor: statusItems[item]?.button, hoverTargets: content.hoverTargets)
    }

    func hidePanel() { panels.close() }

    /// Opens the flyout of the open panel's `index`-th hover card, as if the pointer rested on it.
    func showFlyout(_ index: Int) {
        guard let targets = panel?.hoverTargets, targets.indices.contains(index) else { return }
        panels.openFlyout(for: targets[index].card, make: targets[index].make, pinned: true)
    }

    func lookupPublicIP() { engine?.lookupPublicIP() }

    private enum RelayoutTarget { case none, panel, flyout }

    private func makeContext(relayout: RelayoutTarget = .panel) -> PanelContext {
        PanelContext(
            settings: { [weak self] in self?.settingsProvider() ?? .defaults },
            setRange: { [weak self] chart, range in
                guard let self = self else { return }
                var settings = self.settingsProvider()
                settings.setRange(range, for: chart)
                self.settingsChanged(settings)
            },
            relayout: { [weak self] in
                guard let self = self else { return }
                switch relayout {
                case .none: break
                case .panel: if let root = self.panel?.root { self.panels.relayout(root) }
                case .flyout: self.panels.relayoutFlyout()
                }
            },
            perform: { [weak self] action in self?.perform(action) },
            lookupPublicIP: { [weak self] in self?.engine?.lookupPublicIP() })
    }

    private func perform(_ action: PanelAction) {
        panels.close()
        switch action {
        case .settings:
            openSettings?()
        case .networkSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") { NSWorkspace.shared.open(url) }
        default:
            guard let id = action.bundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    // MARK: Debug snapshots (`--debug-ctl`)

    func writeSnapshot(_ item: MonitorItem, to url: URL, dark: Bool) -> Bool {
        guard let engine = engine else { return false }
        let content = PanelContent.make(item, context: makeContext(relayout: .none))
        content.update(engine)
        let size = content.root.relayout()
        return MonitorPanelController.renderPNG(content.root, size: size, appearance: dark ? .darkAqua : .aqua, to: url)
    }

    /// The panel with its `index`-th hover card highlighted and that card's flyout beside it.
    func writeFlyoutSnapshot(_ item: MonitorItem, index: Int, to url: URL, dark: Bool) -> Bool {
        guard let engine = engine else { return false }
        let content = PanelContent.make(item, context: makeContext(relayout: .none))
        content.update(engine)
        guard content.hoverTargets.indices.contains(index) else { return false }
        let target = content.hoverTargets[index]
        let detail = target.make(makeContext(relayout: .none))
        detail.update(engine)
        content.root.relayout()
        detail.root.relayout()
        target.card.highlighted = true
        return MonitorPanelController.renderFlyoutPNG(panel: content.root, flyout: detail.root, card: target.card,
                                                      appearance: dark ? .darkAqua : .aqua, to: url)
    }

    func writeMenuBarSnapshot(to url: URL, dark: Bool) -> Bool {
        guard let engine = engine else { return false }
        return StatusRenderer.renderStrip(engine: engine, items: MonitorItem.allCases, appearance: dark ? .darkAqua : .aqua, to: url)
    }

    // MARK: Diagnostics

    var diagnostics: [String: String] {
        let s = engine?.snapshot
        func number(_ value: Double?, _ format: String = "%.1f") -> String { value.map { String(format: format, $0) } ?? "-" }
        return [
            "statusItems": "\(statusItems.count)",
            "items": shownOrder.map { $0.rawValue }.joined(separator: ","),
            "timerActive": "\(engine?.isTimerActive ?? false)",
            "sampleCount": "\(engine?.sampleCount ?? 0)",
            "lastRxBytesPerSec": number(s?.netDown, "%.0f"),
            "lastTxBytesPerSec": number(s?.netUp, "%.0f"),
            "panel": panels.item?.rawValue ?? "-",
            "panelFrame": panels.geometry.panel,
            "anchorFrame": panels.geometry.anchor,
            "flyoutFrame": panels.geometry.flyout,
            "hoverCards": "\(panel?.hoverTargets.count ?? 0)",
            "panelIsKey": "\(panels.isKey)",
            "cpuBusy": number(s?.cpu?.busy),
            "cores": "\(s?.cores.count ?? 0)",
            "efficiencyCores": "\(s?.cores.filter { $0.efficiency }.count ?? 0)",
            "cpuMHz": number(s?.cpuMHz, "%.0f"),
            "gpuMHz": number(s?.gpuMHz, "%.0f"),
            "gpuUtilization": number(s?.gpuUtilization, "%.0f"),
            "memoryUsedPercent": number(s?.memory?.usedPercent),
            "memoryPressure": number(s?.pressure, "%.0f"),
            "diskReadBytesPerSec": number(s?.diskRead, "%.0f"),
            "diskWriteBytesPerSec": number(s?.diskWrite, "%.0f"),
            "smc": "\(s?.smcAvailable ?? false)",
            "ioreport": "\(engine?.ioReportAvailable ?? false)",
            "sensors": "\(s?.sensors.count ?? 0)",
            "cpuTemperature": number(s?.cpuTemperature),
            "gpuTemperature": number(s?.gpuTemperature),
            "fans": s?.fans.map { String(format: "%.0f", $0.rpm) }.joined(separator: ",") ?? "-",
            "powerWatts": number(s?.power),
            "ssdHealth": s?.ssd.map { "\($0.healthPercent)" } ?? "-",
            "processGroups": "\(s?.processes.count ?? 0)",
            "networkProcessGroups": "\(s?.networkProcesses.count ?? 0)",
        ]
    }
}
