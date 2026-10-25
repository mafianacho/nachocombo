import AppKit
import NachoComboCore

final class AppDelegate: NSObject, NSApplicationDelegate, PanelHost, GadgetHost, NSMenuDelegate {
    static let commandName = Notification.Name("com.mafianacho.nachocombo.command")

    private let debugCtl: Bool
    private let store = SettingsStore(url: SettingsStore.defaultURL())
    private var manager: ModuleManager!
    private var organizer: MenuBarOrganizerModule!
    private var monitor: SystemMonitorModule!
    private var snap: WindowSnapModule!
    private var shelf: ShelfModule!
    private var capture: CaptureFloatModule!
    private var dim: FocusDimModule!
    private var mainItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController!
    private var panel: PanelController!
    private let toolShortcuts = ToolShortcutCenter()
    private let actionShortcuts = ActionShortcutCenter()
    private var appliedActionShortcuts: [String: ToolShortcut]?
    private var recordingShortcut = false
    private var pinnedItems: [ModuleID: NSStatusItem] = [:]
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var lastShortcutResult = "-"
    private var lastA11y: [String: Any] = [:]
    /// Debug only (`ctl gallery sample on`): gallery pictures use sample data, for documentation screenshots.
    private var samplePreviews = false

    init(debugCtl: Bool) {
        self.debugCtl = debugCtl
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        organizer = MenuBarOrganizerModule(initiallyCollapsed: store.load().menuBarCollapsed)
        monitor = SystemMonitorModule()
        snap = WindowSnapModule()
        shelf = ShelfModule()
        capture = CaptureFloatModule()
        dim = FocusDimModule()
        dim.setIntensity(store.load().dimIntensity)
        manager = ModuleManager(store: store, modules: [organizer, monitor, snap, shelf, capture, dim])
        panel = PanelController(host: self)

        // Created first, so it is the right-most item and never swallowed by the divider.
        mainItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The app icon (a nacho box) is the app's face in the menu bar; it has no Dock icon.
        mainItem.button?.image = AppIcon.artwork(height: 17)
        mainItem.button?.imagePosition = .imageOnly
        mainItem.button?.toolTip = "Nacho Combo — open the tool list"
        mainItem.button?.setAccessibilityLabel("Nacho Combo tool list")
        mainItem.button?.target = self
        mainItem.button?.action = #selector(mainClicked(_:))
        _ = mainItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let options: () -> GadgetOptions = { [weak self] in self?.manager.settings.options ?? .defaults }
        organizer.optionsProvider = options
        snap.optionsProvider = options
        shelf.optionsProvider = options
        capture.optionsProvider = options
        dim.optionsProvider = options
        monitor.optionsProvider = options

        settingsWindow = SettingsWindowController(host: self)
        settingsWindow.quitApp = { NSApp.terminate(nil) }

        monitor.settingsProvider = { [weak self] in self?.manager.settings.monitorSettings ?? .defaults }
        monitor.settingsChanged = { [weak self] value in self?.updateMonitorSettings(value) }
        monitor.onStatusItemsRebuilt = { [weak self] in self?.organizer.rebuild() }
        monitor.openSettings = { [weak self] in self?.showSettings(.systemMonitor) }
        monitor.onAlertsChange = { [weak self] in self?.stateChanged() }
        shelf.onVisibilityChange = { [weak self] in self?.stateChanged() }
        dim.onPauseChange = { [weak self] in self?.stateChanged() }
        capture.onChange = { [weak self] in self?.stateChanged() }
        capture.onPermissionLost = { [weak self] in
            self?.manager.report(.captureFloat, state: .needsPermission(CaptureFloatModule.permissionMessage))
        }
        organizer.onCollapsedChange = { [weak self] value in self?.manager.setMenuBarCollapsed(value) }
        organizer.onStateChange = { [weak self] in self?.stateChanged() }
        snap.onPermissionLost = { [weak self] in
            self?.manager.report(.windowSnap, state: .needsPermission(WindowSnapModule.permissionMessage))
        }
        snap.targetAppProvider = { [weak self] in self?.windowTargetApp() }
        manager.onStarted = { [weak self] id in
            // Items created after the divider would land on its hidden side: re-create the pair.
            if id != .menuBar && id.createsStatusItem { self?.organizer.rebuild() }
        }
        manager.onChange = { [weak self] in self?.stateChanged() }

        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { lastExternalApp = front }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.processIdentifier != getpid() { self?.lastExternalApp = app }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Event-driven re-check: returning from System Settings is the natural moment.
            self?.manager.retry(.windowSnap)
            self?.manager.retry(.captureFloat)
            AlertNotifier.refreshStatus { self?.stateChanged() }
        }
        if debugCtl {
            DistributedNotificationCenter.default().addObserver(
                forName: AppDelegate.commandName, object: nil, queue: .main) { [weak self] note in
                self?.handle(command: (note.userInfo?["cmd"] as? String) ?? "")
            }
        }

        toolShortcuts.onTrigger = { [weak self] id in self?.openTool(id) }
        toolShortcuts.apply(manager.settings.toolShortcuts)
        actionShortcuts.onTrigger = { [weak self] id in self?.runAction(id) }
        AlertNotifier.refreshStatus { [weak self] in self?.stateChanged() }
        syncPins()
        manager.bootstrap()
        // Opening the app (double-click) always shows the settings window; tools saved as ON are already running.
        settingsWindow.show()
    }

    /// Double-clicking the app again (or `open -a`) while it is already running re-opens the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.close()
        toolShortcuts.suspend()
        actionShortcuts.suspend()
        manager.shutdown()
    }

    private func showSettings(_ id: ModuleID? = nil) {
        if let id = id { settingsWindow.select(id) }
        settingsWindow.show()
    }

    private func updateMonitorSettings(_ value: MonitorSettings) {
        manager.setMonitorSettings(value)
        monitor.applySettings()
    }

    private func stateChanged() {
        applyActionShortcuts()
        panel.refresh()
        settingsWindow.refresh()
        refreshPinnedItems()
        writeDiagnostics()
    }

    // MARK: action shortcuts

    /// Registers the action shortcuts of the gadgets that are running (re-registers only when that set changed).
    private func applyActionShortcuts(force: Bool = false) {
        guard !recordingShortcut else { return }
        var wanted: [String: ToolShortcut] = [:]
        for action in GadgetActions.all where manager.states[action.module] == .running {
            if let shortcut = manager.settings.shortcut(forAction: action.id) { wanted[action.id] = shortcut }
        }
        guard force || wanted != appliedActionShortcuts else { return }
        appliedActionShortcuts = wanted
        actionShortcuts.apply(wanted)
    }

    private func runAction(_ id: String) {
        if id.hasPrefix("snap."), let action = SnapAction(rawValue: String(id.dropFirst(5))) {
            snap.perform(action)
        } else if id.hasPrefix("monitor."), let item = MonitorItem(rawValue: String(id.dropFirst(8))) {
            monitor.showPanel(item)
        } else {
            switch id {
            case "menuBar.toggle": organizer.setCollapsed(!organizer.collapsed)
            case "menuBar.showAll": organizer.showingAlwaysHidden ? organizer.setCollapsed(true) : organizer.showAlwaysHidden()
            case "shelf.toggle": shelf.toggle()
            case "shelf.paste": shelf.pasteClipboard()
            case "capture.area": capture.beginSelection()
            case "capture.previous": capture.capturePrevious()
            case "capture.window": capture.beginSelection(windowMode: true)
            case "capture.screen": capture.captureScreen()
            case "capture.text": capture.beginSelection(purpose: .copyText)
            case "capture.lock": capture.toggleLock()
            case "capture.hide": capture.toggleHidden()
            case "capture.closeAll": capture.closeAll()
            case "dim.toggle": dim.togglePause()
            default: return
            }
        }
        stateChanged()
    }

    private func writeDiagnostics() {
        var extra: [String: Any] = ["panel": panel.diagnostics]
        extra["pinnedItems"] = ModuleID.allCases.filter { pinnedItems[$0] != nil }.map { $0.rawValue }
        extra["toolShortcutsRegistered"] = toolShortcuts.registeredCount
        extra["toolShortcutsFailed"] = toolShortcuts.failed.map { $0.rawValue }.sorted()
        extra["toolShortcutEvents"] = toolShortcuts.firedCount
        extra["actionShortcutsRegistered"] = actionShortcuts.registered.mapValues { $0.label }
        extra["actionShortcutsFailed"] = actionShortcuts.failed.sorted()
        extra["actionShortcutEvents"] = actionShortcuts.firedCount
        extra["lastShortcutResult"] = lastShortcutResult
        extra["pinnedSetting"] = ModuleID.allCases.filter { manager.settings.isPinned($0) }.map { $0.rawValue }
        var labels: [String: String] = [:]
        for id in ModuleID.allCases { if let s = manager.settings.shortcut(for: id) { labels[id.rawValue] = s.label } }
        extra["toolShortcutLabels"] = labels
        var gallery: [String: Any] = ["selected": settingsWindow.selected.rawValue, "visible": settingsWindow.isVisible,
                                      "windowFrame": NSStringFromRect(settingsWindow.window.frame),
                                      "contentFitting": NSStringFromSize(settingsWindow.window.contentView?.fittingSize ?? .zero)]
        for id in ModuleID.allCases {
            gallery[id.rawValue] = ["subtitle": gadgetSubtitle(id), "attention": gadgetAttention(id),
                                    "status": gadgetStatusLine(id) ?? ""] as [String: Any]
        }
        extra["gallery"] = gallery
        // How the UI currently looks to the system: light/dark, the accent color the controls follow, Reduce Motion.
        extra["appearance"] = NSApp.effectiveAppearance.name.rawValue
        if let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            extra["accentRGB"] = String(format: "%.2f,%.2f,%.2f", accent.redComponent, accent.greenComponent, accent.blueComponent)
        }
        extra["reduceMotion"] = UI.reduceMotion
        if !lastA11y.isEmpty { extra["a11y"] = lastA11y }
        Diagnostics.write(manager: manager, extra: extra)
    }

    // MARK: menu bar entry points

    @objc private func mainClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        panel.toggle(from: sender, route: .list)
    }

    @objc private func pinnedClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let id = ModuleID(rawValue: raw) else { return }
        panel.toggle(from: sender, route: .tool(id))
    }

    /// Secondary click on the main icon keeps a plain menu (settings / quit) for users who prefer menus.
    private func showContextMenu() {
        panel.close()
        let menu = NSMenu()
        menu.delegate = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Nacho Combo", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        mainItem.menu = menu
        mainItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { mainItem.menu = nil }

    private func openTool(_ id: ModuleID) {
        guard let button = pinnedItems[id]?.button ?? mainItem.button else { return }
        panel.toggle(from: button, route: .tool(id))
    }

    /// Pinned tools get their own menu bar icon that opens the tool screen directly (no list in between).
    private func syncPins() {
        var changed = false
        for (id, item) in pinnedItems where !manager.settings.isPinned(id) {
            if let anchor = panel.anchor, anchor === item.button { panel.close() }
            NSStatusBar.system.removeStatusItem(item)
            pinnedItems[id] = nil
            changed = true
        }
        for id in ModuleID.allCases.reversed() where manager.settings.isPinned(id) && pinnedItems[id] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                if let image = UI.symbol(id.symbolName, size: 14, description: id.displayName) {
                    image.isTemplate = true
                    button.image = image
                    button.imagePosition = .imageOnly
                } else {
                    button.title = String(id.displayName.prefix(1))
                }
                button.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
                button.target = self
                button.action = #selector(pinnedClicked(_:))
            }
            pinnedItems[id] = item
            changed = true
        }
        refreshPinnedItems()
        // Keep the divider the left-most of our own items so pinned icons stay visible when the bar is folded.
        if changed { organizer.rebuild() }
    }

    private func refreshPinnedItems() {
        for (id, item) in pinnedItems {
            let status = manager.status(of: id)
            item.button?.toolTip = "\(id.displayName) — \(status.stateText) (pinned to the menu bar)"
            item.button?.setAccessibilityLabel("Open \(id.displayName), \(status.accessibilityText)")
            item.button?.appearsDisabled = status.dot == .off
        }
    }

    private func windowTargetApp() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { return front }
        if let last = lastExternalApp, !last.isTerminated { return last }
        return nil
    }

    private func applyShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> String? {
        let previous = manager.settings.shortcut(for: id)
        if let issue = manager.setShortcut(id, shortcut) {
            lastShortcutResult = "refused:\(issue.message)"
            writeDiagnostics()
            return issue.message
        }
        toolShortcuts.apply(manager.settings.toolShortcuts)
        if shortcut != nil, toolShortcuts.failed.contains(id) {
            // Another app owns this combination: do not keep a shortcut that does not work.
            _ = manager.setShortcut(id, previous)
            toolShortcuts.apply(manager.settings.toolShortcuts)
            lastShortcutResult = "refused:os-in-use"
            writeDiagnostics()
            return "Another app already uses this shortcut, so it was not registered."
        }
        lastShortcutResult = shortcut.map { "saved:\($0.label)" } ?? "cleared"
        writeDiagnostics()
        return nil
    }

    private func applyActionShortcut(_ id: String, _ shortcut: ToolShortcut?, reset: Bool) -> String? {
        let previous = manager.settings.actionShortcuts[id]
        if let issue = manager.setActionShortcut(id, shortcut, reset: reset) {
            lastShortcutResult = "refused:\(issue.message)"
            writeDiagnostics()
            return issue.message
        }
        applyActionShortcuts(force: true)
        let module = GadgetActions.action(id)?.module
        if shortcut != nil, !reset, actionShortcuts.failed.contains(id) {
            // Another app owns it: keep what was there before rather than a shortcut that does nothing.
            if let previous = previous { _ = manager.setActionShortcut(id, previous.shortcut) }
            else { _ = manager.setActionShortcut(id, nil, reset: true) }
            applyActionShortcuts(force: true)
            lastShortcutResult = "refused:os-in-use"
            writeDiagnostics()
            return "Another app already uses this shortcut, so it was not registered."
        }
        if shortcut != nil, let module = module, manager.states[module] != .running {
            lastShortcutResult = "saved-inactive"
        } else {
            lastShortcutResult = shortcut.map { "saved:\($0.label)" } ?? (reset ? "reset" : "cleared")
        }
        writeDiagnostics()
        return nil
    }

    // MARK: PanelHost

    var panelManager: ModuleManager { manager }
    var panelCollapse: (running: Bool, collapsed: Bool) { (organizer.isRunning, organizer.collapsed) }
    var panelShelf: (running: Bool, visible: Bool, count: Int) { (shelf.running, shelf.isPanelVisible, shelf.store.items.count) }
    var panelReading: SystemMonitorModule.Reading { monitor.latest }
    var panelOptions: GadgetOptions { manager.settings.options }

    func panelSetEnabled(_ id: ModuleID, _ on: Bool) { manager.setEnabled(id, on) }
    func panelSetPinned(_ id: ModuleID, _ pinned: Bool) {
        manager.setPinned(id, pinned)
        syncPins()
        stateChanged()
    }
    func panelOpenSettings() {
        let route = panel.route
        panel.close()
        if case .tool(let id) = route { showSettings(id) } else { showSettings() }
    }
    func panelQuit() { NSApp.terminate(nil) }
    func panelApplySnap(_ action: SnapAction) {
        snap.perform(action)
        stateChanged()
    }
    func panelToggleCollapse() { organizer.setCollapsed(!organizer.collapsed) }
    func panelToggleShelf() { shelf.toggle(); stateChanged() }
    func panelStartCapture() { gadgetPerform(.captureArea) }
    func panelSetDim(_ value: Double) { applyDimIntensity(value) }
    func panelOpenPermissionPane(_ id: ModuleID) {
        switch id {
        case .windowSnap: openPermissionPane(.accessibility)
        case .captureFloat: openPermissionPane(.screenRecording)
        default: break
        }
    }
    func panelRecheck(_ id: ModuleID) { manager.retry(id) }
    func panelPerform(_ command: GadgetCommand) { gadgetPerform(command) }
    func panelStatusLine(_ id: ModuleID) -> String? { gadgetStatusLine(id) }

    // MARK: GadgetHost

    var gadgetManager: ModuleManager { manager }

    private func running(_ id: ModuleID) -> Bool { manager.states[id] == .running }

    private func actionLabel(_ id: String) -> String? { manager.settings.shortcut(forAction: id)?.label }

    func gadgetSubtitle(_ id: ModuleID) -> String {
        guard manager.settings.isEnabled(id) else { return "Off" }
        switch manager.states[id] ?? .off {
        case .needsPermission: return "Needs Permission"
        case .failed: return "Error"
        case .off: return "Not Started"
        case .running: break
        }
        switch id {
        case .menuBar:
            let state = organizer.showingAlwaysHidden ? "Showing All" : (organizer.collapsed ? "Collapsed" : "Expanded")
            return actionLabel("menuBar.toggle").map { "\(state) · \($0)" } ?? state
        case .systemMonitor:
            let r = monitor.latest
            return "CPU \(r.cpuBusy.map { MonitorFormat.percent($0) } ?? "–") · Memory \(r.memPercent.map { MonitorFormat.percent($0) } ?? "–")"
        case .windowSnap:
            let count = GadgetActions.of(.windowSnap).filter { manager.settings.shortcut(forAction: $0.id) != nil }.count
            guard let left = actionLabel(GadgetActions.snapID(.left)) else { return "\(count) shortcuts" }
            return count > 1 ? "\(left) + \(count - 1) more" : left
        case .fileShelf:
            let n = shelf.store.items.count
            let items = n == 0 ? "Empty" : (n == 1 ? "1 item" : "\(n) items")
            return actionLabel("shelf.toggle").map { "\($0) · \(items)" } ?? items
        case .captureFloat:
            let n = capture.floats.count
            let key = actionLabel("capture.area") ?? "On"
            return n == 0 ? key : "\(key) · \(n) floating"
        case .focusDim:
            if dim.paused { return "Paused" }
            let strength = "\(Int((manager.settings.dimIntensity * 100).rounded()))%"
            return actionLabel("dim.toggle").map { "\($0) · \(strength)" } ?? strength
        }
    }

    func gadgetAttention(_ id: ModuleID) -> [String] {
        var items: [String] = []
        let enabled = manager.settings.isEnabled(id)
        switch manager.states[id] ?? .off {
        case .needsPermission(let message) where enabled: items.append(message)
        case .failed(let message) where enabled: items.append(message)
        default: break
        }
        guard running(id) else { return items }
        for action in GadgetActions.of(id) where actionShortcuts.failed.contains(action.id) {
            let label = manager.settings.shortcut(forAction: action.id)?.label ?? ""
            items.append("\(label) (\(action.title)) is already used by another app; choose another shortcut.")
        }
        switch id {
        case .menuBar:
            if organizer.dividerFailed {
                items.append("macOS did not let the divider grow, so icons cannot be folded away on this macOS version.")
            }
        case .windowSnap:
            if snap.motionFailed { items.append("⌃⌘-drag could not start: macOS refused the event tap. Check Accessibility.") }
        case .systemMonitor:
            items.append(contentsOf: monitor.alertMessages)
            if manager.settings.options.alertNotifications, AlertNotifier.granted == false {
                items.append("Notifications are turned off for Nacho Combo in System Settings.")
            }
        default: break
        }
        return items
    }

    func gadgetStatusLine(_ id: ModuleID) -> String? {
        guard running(id) else { return nil }
        switch id {
        case .menuBar:
            var text = organizer.collapsed ? "Collapsed" : "Expanded"
            if organizer.showingAlwaysHidden { text += " · showing the always-hidden icons" }
            let delay = manager.settings.options.autoCollapseSeconds
            if !organizer.collapsed && delay > 0 { text += " · collapses \(delay) s after you leave the menu bar" }
            return text
        case .systemMonitor:
            let shown = manager.settings.monitorSettings.shownItems.count
            let alerts = monitor.alertMessages.count
            return "\(shown) menu bar item\(shown == 1 ? "" : "s")" + (alerts > 0 ? " · \(alerts) alert\(alerts == 1 ? "" : "s")" : " · no alerts")
        case .windowSnap:
            let options = manager.settings.options
            var text = "\(snap.snapCount) snap\(snap.snapCount == 1 ? "" : "s") this session"
            if options.snapDragToEdges {
                text += WindowSnapModule.systemEdgeTilingEnabled ? " · edge drags are left to macOS tiling" : " · drag to snap on"
            }
            return text
        case .fileShelf:
            let n = shelf.store.items.count
            return (n == 0 ? "Empty" : "\(n) item\(n == 1 ? "" : "s")") + (shelf.isPanelVisible ? " · shelf open" : " · shelf hidden")
        case .captureFloat:
            let n = capture.floats.count
            var text = n == 0 ? "No floats" : "\(n) float\(n == 1 ? "" : "s")"
            if capture.locked { text += " · locked" }
            if capture.hidden { text += " · hidden" }
            return text
        case .focusDim:
            return dim.paused ? "Paused" : "Dimming"
        }
    }

    func gadgetPreviewInputs() -> GadgetPreviewInputs {
        var inputs = GadgetPreviewInputs()
        let options = manager.settings.options
        inputs.menuBarCollapsed = organizer.collapsed
        inputs.menuBarAlwaysHidden = options.alwaysHiddenSection
        inputs.shelfItems = samplePreviews ? [] : shelf.store.items
        inputs.dimIntensity = manager.settings.dimIntensity
        inputs.snapGap = CGFloat(options.snapGap)
        for id in ["menuBar.toggle", GadgetActions.snapID(.left), "capture.area", "dim.toggle", "shelf.toggle"] {
            if let label = actionLabel(id) { inputs.keys[id == GadgetActions.snapID(.left) ? "snap.left" : id] = label }
        }
        return inputs
    }

    func gadgetMonitorPreview(appearance: NSAppearance.Name) -> (strip: NSImage?, panel: NSImage?, live: Bool) {
        monitor.previewImages(appearance: appearance, sample: samplePreviews)
    }

    func gadgetPermissionGranted(_ permission: GadgetPermission) -> Bool? {
        switch permission {
        case .accessibility: return WindowSnapModule.isTrusted(prompt: false)
        case .screenRecording: return CaptureFloatModule.hasAccess()
        case .notifications: return AlertNotifier.granted
        }
    }

    func gadgetOpenPermissionSettings(_ permission: GadgetPermission) { openPermissionPane(permission) }

    func gadgetRequestPermission(_ permission: GadgetPermission) {
        guard permission == .notifications else { openPermissionPane(permission); return }
        AlertNotifier.request { [weak self] in self?.stateChanged() }
    }

    func gadgetRecheck(_ id: ModuleID) {
        manager.retry(id)
        AlertNotifier.refreshStatus { [weak self] in self?.stateChanged() }
        stateChanged()
    }

    func gadgetSetEnabled(_ id: ModuleID, _ on: Bool) { manager.setEnabled(id, on) }
    func gadgetSetPinned(_ id: ModuleID, _ pinned: Bool) { panelSetPinned(id, pinned) }
    func gadgetSetToolShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> String? { applyShortcut(id, shortcut) }
    func gadgetSetActionShortcut(_ actionID: String, _ shortcut: ToolShortcut?, reset: Bool) -> String? {
        applyActionShortcut(actionID, shortcut, reset: reset)
    }
    func gadgetActionShortcutUnavailable(_ actionID: String) -> Bool { actionShortcuts.failed.contains(actionID) }

    func gadgetRecordingChanged(_ recording: Bool) {
        recordingShortcut = recording
        if recording {
            toolShortcuts.suspend()
            actionShortcuts.suspend()
            appliedActionShortcuts = nil
        } else {
            toolShortcuts.apply(manager.settings.toolShortcuts)
            applyActionShortcuts(force: true)
        }
    }

    func gadgetSetOptions(_ options: GadgetOptions) {
        let old = manager.settings.options
        manager.setOptions(options)
        organizer.applyOptions()
        snap.applyOptions()
        capture.applyOptions()
        if old.dimScope != options.dimScope || old.dimOtherDisplays != options.dimOtherDisplays { dim.refresh() }
        if options.alertNotifications && !old.alertNotifications && AlertNotifier.granted == nil {
            AlertNotifier.request { [weak self] in self?.stateChanged() }
        }
        stateChanged()
    }

    func gadgetSetMonitorSettings(_ value: MonitorSettings) { updateMonitorSettings(value) }
    func gadgetSetDimIntensity(_ value: Double) { applyDimIntensity(value) }

    func gadgetPerform(_ command: GadgetCommand) {
        switch command {
        case .toggleCollapse: organizer.setCollapsed(!organizer.collapsed)
        case .showAlwaysHidden: organizer.showAlwaysHidden()
        case .openMonitorPanel(let item): monitor.showPanel(item)
        case .snap(let action): snap.perform(action)
        case .toggleShelf: shelf.toggle()
        case .pasteToShelf: shelf.pasteClipboard()
        case .clearShelf: shelf.clear()
        case .captureArea, .captureWindow:
            // The panel and the settings window must be out of the way before the selection overlay appears.
            panel.close()
            let window = command == .captureWindow
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.capture.beginSelection(windowMode: window)
            }
        case .captureScreen:
            panel.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.capture.captureScreen() }
        case .capturePrevious:
            panel.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.capture.capturePrevious() }
        case .lockFloats: capture.toggleLock()
        case .hideFloats: capture.toggleHidden()
        case .closeFloats: capture.closeAll()
        case .toggleDimPause: dim.togglePause()
        }
        stateChanged()
    }

    @objc private func menuSettings() { showSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func applyDimIntensity(_ value: Double) {
        manager.setDimIntensity(value)
        dim.setIntensity(manager.settings.dimIntensity)
    }

    private func openPermissionPane(_ permission: GadgetPermission) {
        let address: String
        switch permission {
        case .accessibility: address = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording: address = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .notifications: address = "x-apple.systempreferences:com.apple.preference.notifications"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    /// Debug-only control channel (`--debug-ctl`): set <module> on|off, collapse on|off, snap <action>,
    /// shelf show|hide|clear|undo|addfile <path>|addtext <text>|addlink <url>|remove <i>,
    /// capture select|window|screen|previous|text|lock|hide|closeall|rect x y w h,
    /// float pin|unpin|close|copy|width|opacity|lock|unlock|save <i> [arg], dim intensity <0.1-0.9>|pause|refresh,
    /// action <id>, actionshortcut <id> <keyCode> <mods>|clear|reset, option <key> <value>,
    /// gallery select <module>|detail <png>|preview <module> <png> [light],
    /// monitor show <item>|hide|hover <index>|items <a,b>|range <chart> <seconds>|snapshot <item> <png> [light]|
    /// flyout <item> <index> <png> [light]|menubar <png> [light]|publicip, settings snapshot <png>, dump, quit.
    private func handle(command: String) {
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "set" where parts.count == 3:
            if let id = ModuleID(rawValue: parts[1]) { manager.setEnabled(id, parts[2] == "on") }
        case "collapse" where parts.count == 2:
            switch parts[1] {
            case "all": organizer.showAlwaysHidden()
            default: organizer.setCollapsed(parts[1] == "on")
            }
        case "snap" where parts.count == 2:
            if let action = SnapAction(rawValue: parts[1]) { snap.perform(action) }
        case "action" where parts.count == 2:
            runAction(parts[1])
        case "actionshortcut" where parts.count >= 3:
            switch parts[2] {
            case "clear": lastShortcutResult = applyActionShortcut(parts[1], nil, reset: false) ?? lastShortcutResult
            case "reset": lastShortcutResult = applyActionShortcut(parts[1], nil, reset: true) ?? lastShortcutResult
            default:
                if parts.count == 4, let k = UInt32(parts[2]), let m = UInt32(parts[3]) {
                    _ = applyActionShortcut(parts[1], ToolShortcut(keyCode: k, modifiers: m), reset: false)
                }
            }
        case "option" where parts.count == 3:
            setOption(parts[1], parts[2])
        case "gallery" where parts.count >= 3:
            switch parts[1] {
            case "select": if let id = ModuleID(rawValue: parts[2]) { showSettings(id) }
            case "sample": samplePreviews = parts[2] == "on"; settingsWindow.refreshPreview()
            case "detail": settingsWindow.show(); _ = settingsWindow.writeDetailSnapshot(to: URL(fileURLWithPath: parts[2]))
            case "preview" where parts.count >= 4:
                if let id = ModuleID(rawValue: parts[2]) {
                    let appearance = NSAppearance(named: parts.last == "light" ? .aqua : .darkAqua)!
                    var inputs = gadgetPreviewInputs()
                    if id == .systemMonitor {
                        inputs.monitor = gadgetMonitorPreview(appearance: parts.last == "light" ? .aqua : .darkAqua)
                    }
                    let picture = GadgetPreview.picture(for: id, inputs: inputs, appearance: appearance)
                    if let tiff = picture.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[3]))
                    }
                }
            default: break
            }
        case "settings" where parts.count == 3 && parts[1] == "snapshot":
            settingsWindow.show()
            _ = settingsWindow.writeSnapshot(to: URL(fileURLWithPath: parts[2]))
        case "monitor" where parts.count >= 2:
            handleMonitor(Array(parts.dropFirst()))
        case "shelf" where parts.count >= 2:
            handleShelf(parts)
        case "capture" where parts.count >= 2:
            handleCapture(parts)
        case "float" where parts.count >= 3:
            handleFloat(parts)
        case "dim" where parts.count >= 2:
            if parts[1] == "intensity", parts.count == 3, let v = Double(parts[2]) { applyDimIntensity(v) }
            if parts[1] == "refresh" { dim.refresh() }
            if parts[1] == "pause" { dim.togglePause() }
        case "pin" where parts.count == 3:
            if let id = ModuleID(rawValue: parts[1]) { panelSetPinned(id, parts[2] == "on") }
        case "shortcut" where parts.count >= 3:
            if let id = ModuleID(rawValue: parts[1]) {
                if parts[2] == "clear" { _ = applyShortcut(id, nil) }
                else if parts.count == 4, let k = UInt32(parts[2]), let m = UInt32(parts[3]) {
                    _ = applyShortcut(id, ToolShortcut(keyCode: k, modifiers: m))
                }
            }
        case "panel" where parts.count >= 2:
            guard let button = mainItem.button else { break }
            switch parts[1] {
            case "list": panel.show(from: button, route: .list)
            case "tool" where parts.count == 3:
                if let id = ModuleID(rawValue: parts[2]) { openToolForce(id) }
            case "back": panel.back()
            case "close": panel.close()
            default: break
            }
        case "a11y" where parts.count == 2:
            // Accessibility elements (role / label / value / help / key) of the visible screen, read from AppKit.
            switch parts[1] {
            case "panel": lastA11y = ["panel": panel.accessibilityTree, "route": panel.route.name]
            case "settings": lastA11y = ["settings": settingsWindow.accessibilityTree]
            default: lastA11y = [:]
            }
        case "snapshot" where parts.count == 3:
            let window: NSWindow? = parts[1] == "panel" ? panel.window : settingsWindow.window
            if let w = window, w.windowNumber > 0,
               let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber),
                                                   [.boundsIgnoreFraming]) {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
            }
        case "settings" where parts.count == 2 && parts[1] == "show":
            showSettings()
        case "appearance" where parts.count == 2:
            // Debug-only override to capture both looks; "system" returns to following the OS.
            switch parts[1] {
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            default: NSApp.appearance = nil
            }
        case "quit":
            NSApp.terminate(nil)
        default: break
        }
        stateChanged()
    }

    /// `option <key> <value>`: sets one gadget option through its JSON form (numbers, true / false, enum names).
    private func setOption(_ key: String, _ raw: String) {
        guard let data = try? JSONEncoder().encode(manager.settings.options),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if raw == "true" || raw == "false" { object[key] = raw == "true" }
        else if let number = Double(raw) { object[key] = number }
        else { object[key] = raw }
        guard let encoded = try? JSONSerialization.data(withJSONObject: object),
              let options = try? JSONDecoder().decode(GadgetOptions.self, from: encoded) else { return }
        gadgetSetOptions(options)
    }

    // Debug-only helpers for the new modules (`--debug-ctl`).
    private func openToolForce(_ id: ModuleID) {
        guard let button = pinnedItems[id]?.button ?? mainItem.button else { return }
        panel.show(from: button, route: .tool(id))
    }

    private func handleShelf(_ parts: [String]) {
        let argument = parts.dropFirst(2).joined(separator: " ")
        switch parts[1] {
        case "show": shelf.show()
        case "hide": shelf.hide()
        case "toggle": shelf.toggle()
        case "clear": shelf.clear(); shelf.show()
        case "undo": shelf.store.undo(); shelf.show()
        case "paste": shelf.pasteClipboard()   // same ingest path as a drop
        case "addfile": _ = shelf.store.addFile(URL(fileURLWithPath: argument)); shelf.show()
        case "addtext": _ = shelf.store.addText(argument); shelf.show()
        case "addlink": if let url = URL(string: argument) { _ = shelf.store.addLink(url) }; shelf.show()
        case "remove":
            if let index = Int(argument), shelf.store.items.indices.contains(index) {
                shelf.store.remove(id: shelf.store.items[index].id)
                shelf.show()
            }
        default: break
        }
    }

    private func handleCapture(_ parts: [String]) {
        switch parts[1] {
        case "select": capture.beginSelection()
        case "window": capture.beginSelection(windowMode: true)
        case "text": capture.beginSelection(purpose: .copyText)
        case "screen": capture.captureScreen()
        case "previous": capture.capturePrevious()
        case "lock": capture.toggleLock()
        case "hide": capture.toggleHidden()
        case "closeall": capture.closeAll()
        case "rect" where parts.count == 6:
            let v = parts[2...5].compactMap(Double.init)
            if v.count == 4 { capture.captureGlobal(x: v[0], y: v[1], width: v[2], height: v[3]) }
        default: break
        }
    }

    private func handleFloat(_ parts: [String]) {
        guard let index = Int(parts[2]), let window = capture.window(at: index) else { return }
        switch parts[1] {
        case "pin": window.setPinned(true)
        case "unpin": window.setPinned(false)
        case "close": window.close()
        case "copy": window.copyToPasteboard()
        case "text": window.copyText()
        case "lock": window.setLocked(true)
        case "unlock": window.setLocked(false)
        case "width" where parts.count == 4:
            if let w = Double(parts[3]) { window.resize(toWidth: CGFloat(w)) }
        case "opacity" where parts.count == 4:
            if let o = Double(parts[3]) { window.setOpacity(CGFloat(o)) }
        case "save" where parts.count == 4: _ = window.save(to: URL(fileURLWithPath: parts[3]))
        default: break
        }
    }

    private func handleMonitor(_ args: [String]) {
        let dark = !args.contains("light")
        let sample = args.contains("sample")
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
                _ = monitor.writeSnapshot(item, to: URL(fileURLWithPath: args[2]), dark: dark, sample: sample)
            }
        case "flyout" where args.count >= 4:
            if let item = MonitorItem(rawValue: args[1]), let index = Int(args[2]) {
                _ = monitor.writeFlyoutSnapshot(item, index: index, to: URL(fileURLWithPath: args[3]), dark: dark, sample: sample)
            }
        case "menubar" where args.count >= 2:
            _ = monitor.writeMenuBarSnapshot(to: URL(fileURLWithPath: args[1]), dark: dark, sample: sample)
        case "publicip":
            monitor.lookupPublicIP()
        default:
            break
        }
    }
}
