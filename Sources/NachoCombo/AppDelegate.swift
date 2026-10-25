import AppKit
import NachoComboCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let commandName = Notification.Name("com.mafianacho.nachocombo.command")

    private let debugCtl: Bool
    private let store = SettingsStore(url: SettingsStore.defaultURL())
    private var manager: ModuleManager!
    private var organizer: MenuBarOrganizerModule!
    private var monitor: SystemMonitorModule!
    private var snap: WindowSnapModule!
    private var mainItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController!

    init(debugCtl: Bool) { self.debugCtl = debugCtl }

    func applicationDidFinishLaunching(_ notification: Notification) {
        organizer = MenuBarOrganizerModule(initiallyCollapsed: store.load().menuBarCollapsed)
        monitor = SystemMonitorModule()
        snap = WindowSnapModule()
        manager = ModuleManager(store: store, modules: [organizer, monitor, snap])

        // Created first, so it is the right-most item and never swallowed by the divider.
        mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainItem.button?.title = "NC"
        mainItem.button?.toolTip = "Nacho Combo"

        settingsWindow = SettingsWindowController(manager: manager, organizer: organizer)
        settingsWindow.openAccessibilitySettings = { [weak self] in self?.openAccessibilityPane() }
        settingsWindow.recheckPermission = { [weak self] in self?.manager.retry(.windowSnap) }
        settingsWindow.onMonitorSettingsChanged = { [weak self] value in self?.updateMonitorSettings(value) }

        monitor.settingsProvider = { [weak self] in self?.manager.settings.monitorSettings ?? .defaults }
        monitor.settingsChanged = { [weak self] value in self?.updateMonitorSettings(value) }
        monitor.onStatusItemsRebuilt = { [weak self] in self?.organizer.rebuild() }
        monitor.openSettings = { [weak self] in self?.settingsWindow.show() }

        organizer.onCollapsedChange = { [weak self] value in self?.manager.setMenuBarCollapsed(value) }
        snap.onPermissionLost = { [weak self] in
            self?.manager.report(.windowSnap, state: .needsPermission(WindowSnapModule.permissionMessage))
        }
        manager.onStarted = { [weak self] id in
            // Items created after the divider would land on its hidden side: re-create the pair.
            if id != .menuBar { self?.organizer.rebuild() }
        }
        manager.onChange = { [weak self] in self?.stateChanged() }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Event-driven re-check: returning from System Settings is the natural moment.
            self?.manager.retry(.windowSnap)
        }
        if debugCtl {
            DistributedNotificationCenter.default().addObserver(
                forName: AppDelegate.commandName, object: nil, queue: .main) { [weak self] note in
                self?.handle(command: (note.userInfo?["cmd"] as? String) ?? "")
            }
        }

        manager.bootstrap()
        if !ModuleID.allCases.contains(where: { manager.settings.isEnabled($0) }) || CommandLine.arguments.contains("--show-settings") {
            settingsWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) { manager.shutdown() }

    private func updateMonitorSettings(_ value: MonitorSettings) {
        manager.setMonitorSettings(value)
        monitor.applySettings()
    }

    private func stateChanged() {
        rebuildMenu()
        settingsWindow.refresh()
        Diagnostics.write(manager: manager)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        for id in ModuleID.allCases {
            let state = manager.states[id] ?? .off
            let item = NSMenuItem(title: "\(id.displayName) — \(state.label)", action: #selector(menuToggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            item.state = manager.settings.isEnabled(id) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if organizer.isRunning {
            let title = organizer.collapsed ? "Expand Hidden Icons" : "Collapse Hidden Icons"
            let item = NSMenuItem(title: title, action: #selector(menuCollapse), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if case .needsPermission = manager.states[.windowSnap] ?? .off {
            let item = NSMenuItem(title: "Accessibility Permission Help…", action: #selector(menuOpenAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Nacho Combo", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        mainItem.menu = menu
    }

    @objc private func menuToggle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw) else { return }
        manager.setEnabled(id, !manager.settings.isEnabled(id))
    }
    @objc private func menuCollapse() { organizer.setCollapsed(!organizer.collapsed) }
    @objc private func menuSettings() { settingsWindow.show() }
    @objc private func menuOpenAccessibility() { settingsWindow.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Debug-only control channel (`--debug-ctl`): set <module> on|off, collapse on|off, snap left|right|maximize,
    /// monitor show <item>|hide|hover <index>|items <a,b>|range <chart> <seconds>|snapshot <item> <png> [light]|
    /// flyout <item> <index> <png> [light]|menubar <png> [light]|publicip,
    /// settings snapshot <png>, dump, quit.
    private func handle(command: String) {
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "set" where parts.count == 3:
            if let id = ModuleID(rawValue: parts[1]) { manager.setEnabled(id, parts[2] == "on") }
        case "collapse" where parts.count == 2:
            organizer.setCollapsed(parts[1] == "on")
        case "snap" where parts.count == 2:
            if let action = SnapAction(rawValue: parts[1]) { snap.perform(action) }
        case "settings" where parts.count == 3 && parts[1] == "snapshot":
            settingsWindow.show()
            _ = settingsWindow.writeSnapshot(to: URL(fileURLWithPath: parts[2]))
        case "monitor" where parts.count >= 2:
            handleMonitor(Array(parts.dropFirst()))
        case "quit":
            NSApp.terminate(nil)
        default: break
        }
        Diagnostics.write(manager: manager)
    }

    private func handleMonitor(_ args: [String]) {
        let dark = args.last != "light"
        switch args[0] {
        case "show" where args.count == 2:
            if let item = MonitorItem(rawValue: args[1]) { monitor.showPanel(item) }
        case "hide":
            monitor.hidePanel()
        case "hover" where args.count == 2:
            if let index = Int(args[1]) { monitor.showFlyout(index) }
        case "items" where args.count == 2:
            let wanted = Set(args[1].split(separator: ",").map(String.init))
            var value = manager.settings.monitorSettings
            for item in MonitorItem.allCases { value.setShown(item, wanted.contains(item.rawValue)) }
            updateMonitorSettings(value)
        case "range" where args.count == 3:
            if let range = Int(args[2]).flatMap(ChartRange.init(rawValue:)) {
                var value = manager.settings.monitorSettings
                value.setRange(range, for: args[1])
                updateMonitorSettings(value)
            }
        case "snapshot" where args.count >= 3:
            if let item = MonitorItem(rawValue: args[1]) {
                _ = monitor.writeSnapshot(item, to: URL(fileURLWithPath: args[2]), dark: dark)
            }
        case "flyout" where args.count >= 4:
            if let item = MonitorItem(rawValue: args[1]), let index = Int(args[2]) {
                _ = monitor.writeFlyoutSnapshot(item, index: index, to: URL(fileURLWithPath: args[3]), dark: dark)
            }
        case "menubar" where args.count >= 2:
            _ = monitor.writeMenuBarSnapshot(to: URL(fileURLWithPath: args[1]), dark: dark)
        case "publicip":
            monitor.lookupPublicIP()
        default:
            break
        }
    }
}
