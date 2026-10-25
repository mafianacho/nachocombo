import AppKit
import NachoComboCore

final class AppDelegate: NSObject, NSApplicationDelegate, PanelHost, NSMenuDelegate {
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
    private var pinnedItems: [ModuleID: NSStatusItem] = [:]
    private var lastExternalApp: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var lastShortcutResult = "-"
    private var lastA11y: [String: Any] = [:]

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
        mainItem.button?.title = "NC"
        mainItem.button?.toolTip = "Nacho Combo — 도구 목록 열기"
        mainItem.button?.setAccessibilityLabel("Nacho Combo 도구 목록")
        mainItem.button?.target = self
        mainItem.button?.action = #selector(mainClicked(_:))
        _ = mainItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        settingsWindow = SettingsWindowController(manager: manager, organizer: organizer)
        settingsWindow.openAccessibilitySettings = { [weak self] in self?.openAccessibilityPane() }
        settingsWindow.recheckPermission = { [weak self] in self?.manager.retry(.windowSnap) }
        settingsWindow.openScreenRecordingSettings = { [weak self] in self?.openScreenRecordingPane() }
        settingsWindow.recheckScreenRecording = { [weak self] in self?.manager.retry(.captureFloat) }
        settingsWindow.toggleShelf = { [weak self] in self?.shelf.toggle(); self?.stateChanged() }
        settingsWindow.startCapture = { [weak self] in self?.capture.beginSelection() }
        settingsWindow.releaseDim = { [weak self] in self?.manager.setEnabled(.focusDim, false) }
        settingsWindow.dimIntensityChanged = { [weak self] value in self?.applyDimIntensity(value) }
        settingsWindow.shelfVisible = { [weak self] in self?.shelf.isPanelVisible ?? false }
        settingsWindow.pinChanged = { [weak self] id, pinned in self?.panelSetPinned(id, pinned) }
        settingsWindow.shortcutRecorded = { [weak self] id, shortcut in self?.applyShortcut(id, shortcut) }
        settingsWindow.recordingChanged = { [weak self] recording in
            guard let self = self else { return }
            if recording { self.toolShortcuts.suspend() } else { self.toolShortcuts.apply(self.manager.settings.toolShortcuts) }
        }
        shelf.onVisibilityChange = { [weak self] in self?.stateChanged() }
        dim.onInstantRelease = { [weak self] in self?.manager.setEnabled(.focusDim, false) }
        capture.onPermissionLost = { [weak self] in
            self?.manager.report(.captureFloat, state: .needsPermission(CaptureFloatModule.permissionMessage))
        }

        organizer.onCollapsedChange = { [weak self] value in self?.manager.setMenuBarCollapsed(value) }
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
        }
        if debugCtl {
            DistributedNotificationCenter.default().addObserver(
                forName: AppDelegate.commandName, object: nil, queue: .main) { [weak self] note in
                self?.handle(command: (note.userInfo?["cmd"] as? String) ?? "")
            }
        }

        settingsWindow.quitApp = { NSApp.terminate(nil) }

        toolShortcuts.onTrigger = { [weak self] id in self?.openTool(id) }
        toolShortcuts.apply(manager.settings.toolShortcuts)
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
        manager.shutdown()
    }

    private func stateChanged() {
        panel.refresh()
        settingsWindow.refresh()
        refreshPinnedItems()
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        var extra: [String: Any] = ["panel": panel.diagnostics]
        extra["pinnedItems"] = ModuleID.allCases.filter { pinnedItems[$0] != nil }.map { $0.rawValue }
        extra["toolShortcutsRegistered"] = toolShortcuts.registeredCount
        extra["toolShortcutsFailed"] = toolShortcuts.failed.map { $0.rawValue }.sorted()
        extra["toolShortcutEvents"] = toolShortcuts.firedCount
        extra["lastShortcutResult"] = lastShortcutResult
        extra["pinnedSetting"] = ModuleID.allCases.filter { manager.settings.isPinned($0) }.map { $0.rawValue }
        var labels: [String: String] = [:]
        for id in ModuleID.allCases { if let s = manager.settings.shortcut(for: id) { labels[id.rawValue] = s.label } }
        extra["toolShortcutLabels"] = labels
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
        let settings = NSMenuItem(title: "설정…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Nacho Combo 종료", action: #selector(menuQuit), keyEquivalent: "q")
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
            item.button?.toolTip = "\(id.displayName) — \(status.stateText) (메뉴 막대에 고정됨)"
            item.button?.setAccessibilityLabel("\(id.displayName) 열기, \(status.accessibilityText)")
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
            return "다른 앱이 이미 쓰고 있어 등록하지 못했습니다."
        }
        lastShortcutResult = shortcut.map { "saved:\($0.label)" } ?? "cleared"
        writeDiagnostics()
        return nil
    }

    // MARK: PanelHost

    var panelManager: ModuleManager { manager }
    var panelCollapse: (running: Bool, collapsed: Bool) { (organizer.isRunning, organizer.collapsed) }
    var panelShelf: (running: Bool, visible: Bool, count: Int) { (shelf.running, shelf.isPanelVisible, shelf.store.items.count) }
    var panelReading: SystemMonitorModule.Reading { monitor.latest }

    func panelSetEnabled(_ id: ModuleID, _ on: Bool) { manager.setEnabled(id, on) }
    func panelSetPinned(_ id: ModuleID, _ pinned: Bool) {
        manager.setPinned(id, pinned)
        syncPins()
        stateChanged()
    }
    func panelOpenSettings() {
        panel.close()
        settingsWindow.show()
    }
    func panelQuit() { NSApp.terminate(nil) }
    func panelApplySnap(_ action: SnapAction) {
        snap.perform(action)
        stateChanged()
    }
    func panelToggleCollapse() { organizer.setCollapsed(!organizer.collapsed) }
    func panelToggleShelf() { shelf.toggle(); stateChanged() }
    func panelStartCapture() {
        panel.close()
        // The panel must be gone before the selection overlay appears, so it is never part of the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.capture.beginSelection() }
    }
    func panelSetDim(_ value: Double) { applyDimIntensity(value) }
    func panelOpenPermissionPane(_ id: ModuleID) {
        switch id {
        case .windowSnap: openAccessibilityPane()
        case .captureFloat: openScreenRecordingPane()
        default: break
        }
    }
    func panelRecheck(_ id: ModuleID) { manager.retry(id) }

    @objc private func menuSettings() { settingsWindow.show() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func applyDimIntensity(_ value: Double) {
        manager.setDimIntensity(value)
        dim.setIntensity(manager.settings.dimIntensity)
    }

    private func openScreenRecordingPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openAccessibilityPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Debug-only control channel (`--debug-ctl`): set <module> on|off, collapse on|off, snap left|right|maximize,
    /// shelf show|hide|clear|addfile <path>|addtext <text>|remove <i>, capture select|rect x y w h,
    /// float pin|unpin|close|copy|width|save <i> [arg], dim intensity <0.1-0.9>, dump, quit.
    private func handle(command: String) {
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "set" where parts.count == 3:
            if let id = ModuleID(rawValue: parts[1]) { manager.setEnabled(id, parts[2] == "on") }
        case "collapse" where parts.count == 2:
            organizer.setCollapsed(parts[1] == "on")
        case "snap" where parts.count == 2:
            if let action = SnapAction(rawValue: parts[1]) { snap.perform(action) }
        case "shelf" where parts.count >= 2:
            handleShelf(parts)
        case "capture" where parts.count >= 2:
            handleCapture(parts)
        case "float" where parts.count >= 3:
            handleFloat(parts)
        case "dim" where parts.count >= 2:
            if parts[1] == "intensity", parts.count == 3, let v = Double(parts[2]) { applyDimIntensity(v) }
            if parts[1] == "refresh" { dim.refresh() }
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
            settingsWindow.show()
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
        writeDiagnostics()
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
        case "clear": shelf.store.clear(); shelf.show()
        case "paste": shelf.ingest(NSPasteboard.general); shelf.show()   // same ingest path as a drop
        case "addfile": _ = shelf.store.addFile(URL(fileURLWithPath: argument)); shelf.show()
        case "addtext": _ = shelf.store.addText(argument); shelf.show()
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
        case "width" where parts.count == 4:
            if let w = Double(parts[3]) { window.resize(toWidth: CGFloat(w)) }
        case "save" where parts.count == 4: _ = window.save(to: URL(fileURLWithPath: parts[3]))
        default: break
        }
    }
}
