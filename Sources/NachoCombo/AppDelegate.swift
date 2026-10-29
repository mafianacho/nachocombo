import AppKit
import NachoComboCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, PanelHost, SettingsHost, NSMenuDelegate {
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
    private var keepAwake: KeepAwakeModule!
    private var clipboard: ClipboardModule!
    private var devices: DeviceControlModule!
    private var appSwitch: AppSwitchModule!
    private var mouse: MouseTuneModule!
    private var clock: CalendarClockModule!
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
    /// Debug only (`ctl permstage <permission> <stage>`): shows a permission card stage without going through it.
    private var stageOverrides: [GadgetPermission: PermissionStage] = [:]
    /// When the user opened a permission's list from Nacho Combo (cleared once it is allowed or the gadget is off).
    private var settingsVisits: [GadgetPermission: Date] = [:]
    /// Gadgets that just started because their permission arrived: the card confirms it for a few seconds.
    private var recentlyAllowed: [ModuleID: Date] = [:]
    /// Polls the permissions while a switched-on gadget waits for one (macOS does not announce a grant).
    private var permissionWatch: Timer?
    private var permissionWatchStarted = Date.distantPast
    private var settingsWindowWasVisible = false
    private var firstLaunch = false
    /// The box before the last order, for Undo (a few minutes, until the next order).
    private var undoBox: (name: String, box: BoxSnapshot, at: Date)?

    init(debugCtl: Bool) {
        self.debugCtl = debugCtl
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Brand.registerFonts()
        firstLaunch = !FileManager.default.fileExists(atPath: store.url.path)
        organizer = MenuBarOrganizerModule(initiallyCollapsed: store.load().menuBarCollapsed)
        monitor = SystemMonitorModule()
        snap = WindowSnapModule()
        shelf = ShelfModule()
        capture = CaptureFloatModule()
        dim = FocusDimModule()
        dim.setIntensity(store.load().dimIntensity)
        keepAwake = KeepAwakeModule()
        clipboard = ClipboardModule()
        devices = DeviceControlModule()
        appSwitch = AppSwitchModule()
        mouse = MouseTuneModule()
        clock = CalendarClockModule()
        manager = ModuleManager(store: store, modules: [organizer, monitor, snap, shelf, capture, dim, keepAwake, clipboard,
                                                        devices, appSwitch, mouse, clock])
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
        dim.sessions.optionsProvider = options
        monitor.optionsProvider = options
        keepAwake.optionsProvider = options
        clipboard.optionsProvider = options
        devices.optionsProvider = options
        appSwitch.optionsProvider = options
        mouse.optionsProvider = options
        clock.optionsProvider = options

        settingsWindow = SettingsWindowController(host: self)

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
        snap.layouts.onChange = { [weak self] in self?.stateChanged() }
        // Items that come and go (recording, focus countdown, muted microphone) must not land on the hidden side.
        let rebuildBar: () -> Void = { [weak self] in self?.organizer.rebuild() }
        capture.onStatusItemsChanged = rebuildBar
        dim.sessions.onStatusItemsChanged = rebuildBar
        devices.onStatusItemsChanged = rebuildBar
        dim.sessions.onPhaseChange = { [weak self] in
            self?.dim.refresh()
            self?.stateChanged()
        }
        dim.sessions.openSettings = { [weak self] in self?.showSettings(.focusDim) }
        keepAwake.onChange = { [weak self] in self?.stateChanged() }
        keepAwake.openSettings = { [weak self] in self?.showSettings(.keepAwake) }
        keepAwake.setOptions = { [weak self] value in self?.gadgetSetOptions(value) }
        clipboard.onChange = { [weak self] in self?.stateChanged() }
        clipboard.sendToShelf = { [weak self] item in self?.shelve(item) ?? false }
        devices.onChange = { [weak self] in self?.stateChanged() }
        appSwitch.switcherShortcutProvider = { [weak self] in self?.manager.settings.shortcut(forAction: "appSwitch.next") }
        appSwitch.onChange = { [weak self] in self?.refreshPinnedItems() }
        mouse.onPermissionLost = { [weak self] in
            self?.manager.report(.mouseTune, state: .needsPermission(MouseTuneModule.permissionMessage))
        }
        clock.onChange = { [weak self] in self?.stateChanged() }
        clock.openSettings = { [weak self] in self?.showSettings(.calendarClock) }
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
            // Coming back from System Settings changes what the permission card says (waiting → still not / restart).
            if self?.settingsVisits.isEmpty == false { self?.recheckPermissions() }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Event-driven re-check: returning from System Settings is the natural moment.
            self?.recheckPermissions()
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
        notePermissionGrants()
        startPermissionWatchIfNeeded()
        // The first launch always shows the window; later launches follow General ▸ Show This Window at Launch.
        if firstLaunch {
            // Everything starts off: the first window is the combo menu.
            settingsWindow.combos.welcome = true
            settingsWindow.select(.combos)
        }
        switch manager.settings.launchWindow {
        case _ where firstLaunch, .always: settingsWindow.show()
        case .whenNeeded: if gadgetsNeedingUser().isEmpty == false { showSettings(gadgetsNeedingUser().first) }
        case .never: break
        }
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
        startPermissionWatchIfNeeded(restart: true)
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
        refreshMainItem()
        startPermissionWatchIfNeeded()
        writeDiagnostics()
    }

    /// Switched-on gadgets that cannot run until the user does something (a permission) or that failed.
    private func gadgetsNeedingUser() -> [ModuleID] {
        ModuleID.allCases.filter { id in
            guard manager.settings.isEnabled(id) else { return false }
            switch manager.states[id] ?? .off {
            case .needsPermission, .failed: return true
            default: return false
            }
        }
    }

    /// The nacho box gets a small orange dot while a gadget needs the user (General can turn the dot off).
    private func refreshMainItem() {
        let needing = gadgetsNeedingUser()
        let dot = manager.settings.menuBarAttentionDot && !needing.isEmpty
        let base = AppIcon.artwork(height: 17)
        if dot {
            let size = NSSize(width: base.size.width + 3, height: base.size.height)
            mainItem.button?.image = NSImage(size: size, flipped: false) { rect in
                base.draw(in: NSRect(origin: .zero, size: base.size))
                let d: CGFloat = 7
                let circle = NSRect(x: rect.width - d, y: rect.height - d, width: d, height: d)
                DotPalette.orange.setFill()
                NSBezierPath(ovalIn: circle).fill()
                return true
            }
        } else {
            mainItem.button?.image = base
        }
        if let first = needing.first, needing.count == 1 {
            mainItem.button?.toolTip = "Nacho Combo — \(first.displayName): \(manager.status(of: first).stateText)"
        } else if !needing.isEmpty {
            mainItem.button?.toolTip = "Nacho Combo — \(needing.count) gadgets need you"
        } else {
            mainItem.button?.toolTip = "Nacho Combo — open the tool list"
        }
        mainItem.button?.setAccessibilityLabel(needing.isEmpty ? "Nacho Combo tool list"
                                                : "Nacho Combo tool list, \(needing.count) need attention")
    }

    // MARK: permissions

    private static let systemSettingsID = "com.apple.systempreferences"
    private var systemSettingsInFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppDelegate.systemSettingsID
    }

    /// Re-tries the gadgets that wait for a permission; one that starts gets a short "allowed" confirmation, and if the
    /// user came here from the permission card the window comes back to show it.
    private func recheckPermissions() {
        var started: [ModuleID] = []
        for id in permissionGadgets where manager.settings.isEnabled(id) {
            guard case .needsPermission = manager.states[id] ?? .off else { continue }
            manager.retry(id)
            if manager.states[id] == .running { started.append(id) }
        }
        notePermissionGrants()
        for id in started {
            recentlyAllowed[id] = Date()
            if let permission = id.info.requiredPermission, settingsVisits[permission] != nil, settingsWindowWasVisible {
                showSettings(id)
            }
            if let permission = id.info.requiredPermission { settingsVisits[permission] = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { [weak self] in self?.stateChanged() }
        }
        stateChanged()
    }

    /// The gadgets that cannot run without a permission.
    private var permissionGadgets: [ModuleID] { ModuleID.allCases.filter { $0.info.requiredPermission != nil } }

    /// Remembers which copy of the app had each permission, so a later copy can tell an update from a revocation.
    private func notePermissionGrants() {
        guard let signature = CodeSignature.current else { return }
        for permission in [GadgetPermission.accessibility, .screenRecording] where gadgetPermissionGranted(permission) == true {
            if manager.settings.permissionGrants[permission.rawValue] != signature {
                manager.update { $0.permissionGrants[permission.rawValue] = signature }
            }
        }
    }

    /// Polls once a second while a switched-on gadget waits for a permission, for at most 10 minutes at a time (opening
    /// the window, the panel or System Settings from here starts it again). Stops by itself when nothing waits.
    private func startPermissionWatchIfNeeded(restart: Bool = false) {
        let waiting = permissionGadgets.contains { id in
            guard manager.settings.isEnabled(id), case .needsPermission = manager.states[id] ?? .off else { return false }
            return true
        }
        guard waiting else { permissionWatch?.invalidate(); permissionWatch = nil; return }
        if restart { permissionWatchStarted = Date() }
        guard permissionWatch == nil else { return }
        if !restart && Date().timeIntervalSince(permissionWatchStarted) > 600 { permissionWatchStarted = Date() }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.permissionTick() }
        RunLoop.main.add(timer, forMode: .common)
        permissionWatch = timer
    }

    private func permissionTick() {
        if settingsWindow.isVisible { settingsWindowWasVisible = true }
        if Date().timeIntervalSince(permissionWatchStarted) > 600 {
            permissionWatch?.invalidate()
            permissionWatch = nil
            return
        }
        let ready = permissionGadgets.contains { id in
            guard manager.settings.isEnabled(id), case .needsPermission = manager.states[id] ?? .off,
                  let permission = id.info.requiredPermission else { return false }
            return gadgetPermissionGranted(permission) == true
        }
        if ready || !settingsVisits.isEmpty { recheckPermissions() }
    }

    /// The short explanation before macOS's own permission dialog appears (only when the permission is missing).
    private func confirmPermission(for id: ModuleID, then proceed: @escaping () -> Void, cancelled: @escaping () -> Void) {
        guard let permission = id.info.requiredPermission, gadgetPermissionGranted(permission) != true else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "\(id.displayName) needs \(permission.displayName)"
        let app = GadgetPermission.settingsAppName()
        switch permission {
        case .screenRecording:
            alert.informativeText = "To read the area you select, Nacho Combo needs your OK in \(app). Next, macOS shows "
                + "its own message: choose Open \(app), then turn on Nacho Combo.\n\nNothing is recorded or uploaded."
        default:
            let purpose = id.info.permissions.first { $0.permission == permission }?.purpose ?? "needs it"
            let privacy: String
            switch id {
            case .windowSnap: privacy = "\n\nWindow titles and contents are never read."
            case .appSwitch: privacy = "\n\nWindow titles are read only to show them in the switcher, and never kept."
            case .mouseTune: privacy = "\n\nOnly the mouse's scrolling and buttons change; keystrokes are never read."
            default: privacy = ""
            }
            alert.informativeText = "\(id.displayName) \(purpose). For that, Nacho Combo needs your OK in \(app). Next, "
                + "macOS shows its own message: choose Open \(app), then turn on Nacho Combo." + privacy
        }
        alert.icon = GadgetIcon.image(for: id, size: 64)
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        alert.beginSheetModal(for: settingsWindow.window) { response in
            if response == .alertFirstButtonReturn { proceed() } else { cancelled() }
        }
    }

    /// Turning a gadget on from the gallery or the panel: a gadget that needs a missing permission explains it first.
    private func userEnable(_ id: ModuleID, _ on: Bool, navigate: Bool = true) {
        guard on, let permission = id.info.requiredPermission, gadgetPermissionGranted(permission) != true else {
            if !on, let permission = id.info.requiredPermission { settingsVisits[permission] = nil }
            manager.setEnabled(id, on)
            return
        }
        if navigate { showSettings(id) } else { settingsWindow.show() }
        confirmPermission(for: id, then: { [weak self] in
            self?.manager.setEnabled(id, true)
            self?.startPermissionWatchIfNeeded(restart: true)
        }, cancelled: { [weak self] in self?.stateChanged() })
    }

    /// Starts a fresh copy once this one has quit (macOS applies Screen Recording to a new process).
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
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
            case "dim.session": dim.toggleSession()
            case "layout.save": snap.layouts.save()
            case "layout.restore": snap.layouts.restore()
            case "capture.record": capture.toggleRecording()
            case "capture.color": capture.pickColor()
            case "capture.live": capture.beginLiveWindow()
            case "keepAwake.toggle": keepAwake.toggle()
            case "clipboard.show": clipboard.showPanel()
            case "clipboard.plain": clipboard.pastePlainLast()
            case "device.micMute": devices.toggleMic()
            case "device.nextOutput": devices.nextOutput()
            case "device.brighter": devices.changeBrightness(by: 10)
            case "device.dimmer": devices.changeBrightness(by: -10)
            case "appSwitch.next": appSwitch.cycle(forward: true); return
            case "appSwitch.previous": appSwitch.cycle(forward: false); return
            case "appSwitch.hideOthers": appSwitch.hideOthers()
            case "mouseTune.reverse": toggleMouseReverse()
            case "calendarClock.show": clock.togglePopover()
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
        var gallery: [String: Any] = ["selected": settingsWindow.page.key, "visible": settingsWindow.isVisible,
                                      "tab": settingsWindow.detail.tab.key,
                                      "windowFrame": NSStringFromRect(settingsWindow.window.frame),
                                      "contentFitting": NSStringFromSize(settingsWindow.window.contentView?.fittingSize ?? .zero)]
        for id in ModuleID.allCases {
            var entry: [String: Any] = ["subtitle": gadgetSubtitle(id), "attention": gadgetAttention(id),
                                        "badge": gadgetBadgeCount(id), "status": gadgetStatusLine(id) ?? ""]
            if let permission = id.info.requiredPermission { entry["permissionStage"] = gadgetPermissionStage(permission).rawValue }
            gallery[id.rawValue] = entry
        }
        extra["gallery"] = gallery
        extra["settingsVisits"] = settingsVisits.keys.map { $0.rawValue }.sorted()
        extra["permissionWatch"] = permissionWatch != nil
        extra["mainItemAttention"] = !gadgetsNeedingUser().isEmpty
        extra["loginItem"] = "\(loginItemState)"
        extra["combo"] = ["ordered": manager.settings.combo ?? "", "current": ComboCatalog.current(manager.settings)?.id ?? "",
                          "shown": settingsWindow.combos.selected.id]
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
        // Combos straight from the icon: the one that is the box is checked; choosing another orders it (Undo is here too).
        let comboItem = NSMenuItem(title: "Combo", action: nil, keyEquivalent: "")
        let combos = NSMenu()
        let current = ComboCatalog.current(manager.settings)
        for combo in ComboCatalog.combos(manager.settings) {
            let item = NSMenuItem(title: "No.\(combo.number)  \(combo.name)", action: #selector(menuOrderCombo(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = combo.id
            item.state = combo.id == current?.id ? .on : .off
            item.toolTip = combo.gadgets.map { $0.displayName }.joined(separator: ", ")
            combos.addItem(item)
        }
        combos.addItem(.separator())
        if let name = orderUndoName {
            let undo = NSMenuItem(title: "Undo \(name)", action: #selector(menuUndoOrder), keyEquivalent: "")
            undo.target = self
            combos.addItem(undo)
        }
        let own = NSMenuItem(title: "Make Your Own…", action: #selector(menuNewCombo), keyEquivalent: "")
        own.target = self
        combos.addItem(own)
        comboItem.submenu = combos
        menu.addItem(comboItem)
        menu.addItem(.separator())
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

    func panelSetEnabled(_ id: ModuleID, _ on: Bool) {
        if on, let permission = id.info.requiredPermission, gadgetPermissionGranted(permission) != true { panel.close() }
        userEnable(id, on)
    }
    func panelOrderCombo(_ id: String) { orderCombo(id) }
    var panelUndoName: String? { orderUndoName }
    func panelUndoOrder() { undoOrder() }
    func panelPermissionGranted(_ permission: GadgetPermission) -> Bool? { gadgetPermissionGranted(permission) }

    func panelOpenCombos(newCombo: Bool) {
        panel.close()
        settingsWindow.select(.combos)
        if newCombo { settingsWindow.combos.startNewCombo() }
        settingsWindow.show()
    }

    func panelOpenGadget(_ id: ModuleID?) {
        panel.close()
        if let id = id { showSettings(id) } else { settingsWindow.select(.permissions); settingsWindow.show() }
    }
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
        if let permission = id.info.requiredPermission { gadgetOpenPermissionSettings(permission) }
    }
    func panelRecheck(_ id: ModuleID) { recheckPermissions() }
    func panelPerform(_ command: GadgetCommand) { gadgetPerform(command) }
    func panelStatusLine(_ id: ModuleID) -> String? { gadgetStatusLine(id) }

    // MARK: GadgetHost

    var gadgetManager: ModuleManager { manager }

    private func running(_ id: ModuleID) -> Bool { manager.states[id] == .running }

    private func actionLabel(_ id: String) -> String? { manager.settings.shortcut(forAction: id)?.label }

    func gadgetSubtitle(_ id: ModuleID) -> String {
        guard manager.settings.isEnabled(id) else { return "Off" }
        switch manager.states[id] ?? .off {
        case .needsPermission, .failed, .off: return manager.status(of: id).stateText
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
            if dim.sessions.isActive { return dim.sessions.statusText }
            if dim.paused { return "Paused" }
            let strength = "\(Int((manager.settings.dimIntensity * 100).rounded()))%"
            return actionLabel("dim.toggle").map { "\($0) · \(strength)" } ?? strength
        case .keepAwake:
            guard keepAwake.decision.holds else { return "Sleeps as usual" }
            return keepAwake.until.map { "Awake · " + KeepAwakePolicy.remainingText(until: $0, now: Date()) } ?? "Awake"
        case .clipboard:
            let n = clipboard.history.items.count
            let items = n == 1 ? "1 item" : "\(n) items"
            return actionLabel("clipboard.show").map { "\($0) · \(items)" } ?? items
        case .deviceControl:
            if devices.micMuted { return "Microphone muted" }
            return devices.currentOutput?.name ?? "No sound output"
        case .appSwitch:
            let apps = manager.settings.options.appShortcuts.filter { $0.shortcut != nil }.count
            let switcher = actionLabel("appSwitch.next") ?? "Switcher"
            return apps == 0 ? switcher : "\(switcher) · \(apps) app\(apps == 1 ? "" : "s")"
        case .mouseTune:
            let options = manager.settings.options
            return (options.mouseReverse ? "Reversed wheel" : "Natural wheel") + (options.mouseSmooth ? " · smooth" : "")
        case .calendarClock:
            if let next = clock.nextMeeting(within: 60 * 60), let countdown = ClockFormat.countdown(to: next.event.startDate, now: Date()) {
                return "\(next.event.title ?? "Event") \(countdown)"
            }
            return clock.clockText.isEmpty ? "On" : clock.clockText
        }
    }

    func gadgetAttention(_ id: ModuleID) -> [String] {
        // A missing permission has its own card; these are the other things that need the user.
        var items: [String] = []
        let enabled = manager.settings.isEnabled(id)
        if case .failed(let message) = manager.states[id] ?? .off, enabled { items.append(message) }
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
        case .appSwitch:
            for bundleID in appSwitch.failedApps {
                let name = manager.settings.options.appShortcuts.first { $0.bundleID == bundleID }?.name ?? bundleID
                items.append("\(name)'s shortcut is already used by another app; choose another one on the Shortcuts tab.")
            }
        case .mouseTune:
            if !mouse.tapActive { items.append("The mouse event tap stopped. Switch Mouse Tune off and on again, or check Accessibility.") }
        default: break
        }
        return items
    }

    func gadgetBadgeCount(_ id: ModuleID) -> Int {
        var count = gadgetAttention(id).count
        if manager.settings.isEnabled(id), case .needsPermission = manager.states[id] ?? .off { count += 1 }
        return count
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
            return text + " · " + snap.layouts.summary
        case .fileShelf:
            let n = shelf.store.items.count
            return (n == 0 ? "Empty" : "\(n) item\(n == 1 ? "" : "s")") + (shelf.isPanelVisible ? " · shelf open" : " · shelf hidden")
        case .captureFloat:
            let n = capture.floats.count
            var text = n == 0 ? "No floats" : "\(n) float\(n == 1 ? "" : "s")"
            if capture.locked { text += " · locked" }
            if capture.hidden { text += " · hidden" }
            if capture.recording { text += " · recording" }
            return text
        case .focusDim:
            let shade = dim.paused ? "Paused" : (manager.settings.options.dimOnlyInSession && dim.sessions.phase != .focus
                                                 ? "Waiting for a focus session" : "Dimming")
            return dim.sessions.isActive ? "\(shade) · \(dim.sessions.statusText)" : shade
        case .keepAwake:
            return keepAwake.decision.text
        case .clipboard:
            let pins = clipboard.history.pins.count
            var text = "\(clipboard.history.items.count) of \(manager.settings.options.clipboardLimit) remembered"
            if pins > 0 { text += " · \(pins) pinned" }
            if manager.settings.options.clipboardPasteDirectly && !clipboard.accessibilityAllowed { text += " · copies only" }
            return text
        case .deviceControl:
            let output = devices.currentOutput?.name ?? "no output"
            var text = "\(output) · microphone \(devices.micMuted ? "muted" : "on")"
            let displays = devices.displays.list.count
            if displays > 0 { text += " · \(displays) external display\(displays == 1 ? "" : "s")" }
            return text
        case .appSwitch:
            let apps = manager.settings.options.appShortcuts.filter { $0.shortcut != nil }.count
            return "\(apps) app shortcut\(apps == 1 ? "" : "s") · \(appSwitch.switchCount) switch\(appSwitch.switchCount == 1 ? "" : "es") this session"
        case .mouseTune:
            let options = manager.settings.options
            return "Wheel \(options.mouseReverse ? "reversed" : "natural") · smooth \(options.mouseSmooth ? "on" : "off") · "
                + String(format: "%g× speed", options.mouseSpeed)
        case .calendarClock:
            if manager.settings.options.clockNextEvent, CalendarClockModule.access != true { return "Clock on · events need Calendars" }
            guard let next = clock.nextMeeting() else { return "No timed events in the next 12 hours" }
            let countdown = ClockFormat.countdown(to: next.event.startDate, now: Date()) ?? ""
            return "Next: \(next.event.title ?? "Event") \(countdown)" + (next.link != nil ? " · Join ready" : "")
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
        // Documentation screenshots use the sample clock, not this Mac's time and language.
        inputs.clockText = samplePreviews ? "" : clock.clockText
        inputs.worldClocks = options.worldClocks
        inputs.keepAwakeMinutes = options.keepAwakeMinutes
        for id in ["menuBar.toggle", GadgetActions.snapID(.left), "capture.area", "dim.toggle", "shelf.toggle",
                   "clipboard.show", "device.micMute", "appSwitch.next"] {
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
        case .calendars: return CalendarClockModule.access
        }
    }

    func gadgetPermissionStage(_ permission: GadgetPermission) -> PermissionStage {
        if let forced = stageOverrides[permission] { return forced }
        return PermissionGuide.stage(granted: gadgetPermissionGranted(permission) == true, permission: permission,
                                     visitedSettings: settingsVisits[permission] != nil,
                                     settingsInFront: systemSettingsInFront,
                                     grantedSignature: manager.settings.permissionGrants[permission.rawValue],
                                     currentSignature: CodeSignature.current)
    }

    func gadgetRecentlyAllowed(_ id: ModuleID) -> Bool {
        guard let at = recentlyAllowed[id] else { return false }
        return Date().timeIntervalSince(at) < 5 && manager.states[id] == .running
    }

    func gadgetOpenPermissionSettings(_ permission: GadgetPermission) {
        if permission != .notifications {
            settingsVisits[permission] = Date()
            settingsWindowWasVisible = settingsWindow.isVisible
            startPermissionWatchIfNeeded(restart: true)
        }
        openPermissionPane(permission)
    }

    func gadgetRequestPermission(_ permission: GadgetPermission) {
        switch permission {
        case .notifications: AlertNotifier.request { [weak self] in self?.stateChanged() }
        case .calendars:
            guard CalendarClockModule.access == nil else { gadgetOpenPermissionSettings(.calendars); return }
            clock.requestAccess { [weak self] in self?.stateChanged() }
        case .accessibility:
            if !WindowSnapModule.isTrusted(prompt: true) { gadgetOpenPermissionSettings(.accessibility) }
        default: gadgetOpenPermissionSettings(permission)
        }
    }

    /// Removes this app's entry from the permission's list (`tccutil reset <service> <bundle id>`, which needs no
    /// administrator for one's own app), then asks macOS again so the current copy is added.
    func gadgetAskAgain(_ permission: GadgetPermission) {
        if let service = permission.tccService, let bundleID = Bundle.main.bundleIdentifier {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        manager.update { $0.permissionGrants[permission.rawValue] = nil }
        switch permission {
        case .accessibility: _ = WindowSnapModule.isTrusted(prompt: true)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        case .notifications: AlertNotifier.request { [weak self] in self?.stateChanged() }
        case .calendars: clock.requestAccess { [weak self] in self?.stateChanged() }
        }
        settingsVisits[permission] = Date()
        settingsWindowWasVisible = settingsWindow.isVisible
        startPermissionWatchIfNeeded(restart: true)
        stateChanged()
    }

    func gadgetForgetSettingsVisit(_ permission: GadgetPermission) {
        settingsVisits[permission] = nil
        stateChanged()
    }

    func gadgetRelaunch() { relaunch() }

    func gadgetRecheck(_ id: ModuleID) {
        recheckPermissions()
        AlertNotifier.refreshStatus { [weak self] in self?.stateChanged() }
    }

    func gadgetSetEnabled(_ id: ModuleID, _ on: Bool) { userEnable(id, on) }
    func gadgetSetPinned(_ id: ModuleID, _ pinned: Bool) { panelSetPinned(id, pinned) }
    func gadgetSetToolShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> String? { applyShortcut(id, shortcut) }
    func gadgetSetActionShortcut(_ actionID: String, _ shortcut: ToolShortcut?, reset: Bool) -> String? {
        applyActionShortcut(actionID, shortcut, reset: reset)
    }
    func gadgetActionShortcutUnavailable(_ actionID: String) -> Bool { actionShortcuts.failed.contains(actionID) }

    func gadgetResetActionShortcuts(_ id: ModuleID) {
        manager.resetActionShortcuts(of: id)
        applyActionShortcuts(force: true)
        stateChanged()
    }

    func gadgetDismissHint(_ key: String) { manager.update { $0.dismissedHints[key] = true } }

    func gadgetOpenDesktopSettings() {
        let address = GadgetPermission.currentMajor >= 13 ? "x-apple.systempreferences:com.apple.Desktop-Settings.extension"
                                                          : "x-apple.systempreferences:com.apple.preference.dock"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    var gadgetWindow: NSWindow? { settingsWindow.window }

    // MARK: SettingsHost

    var loginItemState: LoginItemState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .needsApproval
        default: return .off
        }
    }

    func setOpenAtLogin(_ on: Bool) -> String? {
        guard #available(macOS 13.0, *) else { return "Open at Login needs macOS 13 or later." }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "macOS did not change the login item: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        if #available(macOS 13.0, *) { SMAppService.openSystemSettingsLoginItems() }
    }

    func revealSettingsFile() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    func resetAllSettings() {
        manager.resetAll()
        settingsVisits.removeAll()
        recentlyAllowed.removeAll()
        toolShortcuts.apply(manager.settings.toolShortcuts)
        applyActionShortcuts(force: true)
        organizer.applyOptions()
        snap.applyOptions()
        capture.applyOptions()
        applyNewGadgetOptions()
        dim.setIntensity(manager.settings.dimIntensity)
        monitor.applySettings()
        syncPins()
        stateChanged()
    }

    private func applyNewGadgetOptions() {
        keepAwake.applyOptions()
        clipboard.applyOptions()
        devices.applyOptions()
        appSwitch.applyOptions()
        mouse.applyOptions()
        clock.applyOptions()
    }

    private func toggleMouseReverse() {
        var options = manager.settings.options
        options.mouseReverse.toggle()
        gadgetSetOptions(options)
        Toast.show(options.mouseReverse ? "Mouse wheel reversed" : "Mouse wheel natural", near: NSEvent.mouseLocation)
    }

    /// Clipboard History ▸ To Shelf: the item goes through the shelf's own drop path.
    private func shelve(_ item: ClipboardItem) -> Bool {
        guard shelf.running else { return false }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.mafianacho.nachocombo.to-shelf"))
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link: pasteboard.setString(item.text, forType: .string)
        case .image: if let png = item.imagePNG { pasteboard.setData(png, forType: .png) }
        case .files: pasteboard.writeObjects(item.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL })
        }
        shelf.ingest(pasteboard)
        shelf.show()
        return true
    }

    func gadgetDevices() -> DeviceSnapshot { devices.snapshot }

    func gadgetCommandState(_ command: GadgetCommand) -> (on: Bool, enabled: Bool) {
        switch command {
        case .toggleKeepAwake: return (keepAwake.manual && keepAwake.decision.holds, true)
        case .toggleMic: return (devices.micMuted, true)
        case .nextOutput: return (false, devices.outputs.count > 1)
        case .toggleRecording: return (capture.recording, true)
        case .toggleFocusSession: return (dim.sessions.isActive, true)
        case .restoreLayout: return (false, snap.layouts.current != nil || snap.layouts.store.latest != nil)
        case .toggleMouseReverse: return (manager.settings.options.mouseReverse, true)
        case .joinNextMeeting: return (false, clock.nextMeeting()?.link != nil)
        default: return (false, true)
        }
    }

    func gadgetSetAppShortcut(_ bundleID: String, _ shortcut: ToolShortcut?) -> String? {
        if let shortcut = shortcut,
           let issue = ShortcutPolicy.validateAppShortcut(shortcut, bundleID: bundleID, settings: manager.settings) {
            lastShortcutResult = "refused:\(issue.message)"
            return issue.message
        }
        var options = manager.settings.options
        guard let index = options.appShortcuts.firstIndex(where: { $0.bundleID == bundleID }) else { return nil }
        let previous = options.appShortcuts[index].shortcut
        options.appShortcuts[index].shortcut = shortcut
        gadgetSetOptions(options)
        if shortcut != nil, manager.states[.appSwitch] == .running, appSwitch.failedApps.contains(bundleID) {
            options.appShortcuts[index].shortcut = previous
            gadgetSetOptions(options)
            lastShortcutResult = "refused:os-in-use"
            return "Another app already uses this shortcut, so it was not registered."
        }
        lastShortcutResult = shortcut.map { "saved:\($0.label)" } ?? "cleared"
        return nil
    }

    func quitApp() { NSApp.terminate(nil) }

    func orderCombo(_ id: String) {
        guard let combo = ComboCatalog.combo(id, in: manager.settings) else { return }
        undoBox = (combo.name, manager.snapshot(), Date())
        // Gadgets whose permission is missing wait for their own Allow: ordering never raises a system dialog.
        let ready = combo.gadgets.filter { gadget in
            gadget.info.requiredPermission.map { gadgetPermissionGranted($0) == true } ?? true
        }
        manager.order(combo, enable: ready)
        applyBoxSettings()
        settingsWindow.combos.welcome = false
        stateChanged()
    }

    /// After a combo changed options in one go: every gadget takes its new settings.
    private func applyBoxSettings() {
        dim.setIntensity(manager.settings.dimIntensity)
        organizer.applyOptions()
        snap.applyOptions()
        capture.applyOptions()
        applyNewGadgetOptions()
        dim.refresh()
        monitor.applySettings()
    }

    func saveCombo(_ combo: SavedCombo) -> Bool { manager.saveCombo(combo) }

    func deleteCombo(_ id: String) { manager.deleteCombo(id) }

    var orderUndoName: String? {
        guard let undo = undoBox, Date().timeIntervalSince(undo.at) < 300 else { return nil }
        return undo.name
    }

    func undoOrder() {
        guard orderUndoName != nil, let undo = undoBox else { return }
        undoBox = nil
        manager.restore(undo.box)
        applyBoxSettings()
        stateChanged()
    }

    func allowFromCombo(_ id: ModuleID) { userEnable(id, true, navigate: false) }

    func permissionsAttentionCount() -> Int {
        var count = 0
        for id in permissionGadgets where manager.settings.isEnabled(id) {
            if case .needsPermission = manager.states[id] ?? .off { count += 1 }
        }
        if manager.settings.options.alertNotifications, AlertNotifier.granted == false { count += 1 }
        return count
    }

    func gadgetRecordingChanged(_ recording: Bool) {
        recordingShortcut = recording
        if recording {
            toolShortcuts.suspend()
            actionShortcuts.suspend()
            appSwitch.suspendShortcuts()
            appliedActionShortcuts = nil
        } else {
            toolShortcuts.apply(manager.settings.toolShortcuts)
            applyActionShortcuts(force: true)
            appSwitch.applyOptions()
        }
    }

    func gadgetSetOptions(_ options: GadgetOptions) {
        let old = manager.settings.options
        manager.setOptions(options)
        organizer.applyOptions()
        snap.applyOptions()
        capture.applyOptions()
        applyNewGadgetOptions()
        if old.dimScope != options.dimScope || old.dimOtherDisplays != options.dimOtherDisplays
            || old.dimOnlyInSession != options.dimOnlyInSession { dim.refresh() }
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
        case .toggleFocusSession: dim.toggleSession()
        case .saveLayout: if running(.windowSnap) { snap.layouts.save() }
        case .restoreLayout: if running(.windowSnap) { snap.layouts.restore() }
        case .toggleRecording, .pickColor, .liveWindow:
            if capture.recording && command == .toggleRecording { capture.stopRecording(); break }
            panel.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                switch command {
                case .toggleRecording: self?.capture.toggleRecording()
                case .pickColor: self?.capture.pickColor()
                default: self?.capture.beginLiveWindow()
                }
            }
        case .toggleKeepAwake: keepAwake.toggle()
        case .keepAwakeFor(let minutes): keepAwake.hold(minutes: minutes)
        case .showClipboard:
            panel.close()
            clipboard.showPanel()
        case .clearClipboard: clipboard.clearHistory()
        case .toggleMic: devices.toggleMic()
        case .nextOutput: devices.nextOutput()
        case .selectOutput(let uid): devices.selectOutput(uid)
        case .selectInput(let uid): devices.selectInput(uid)
        case .setVolume(let value): devices.setOutputVolume(Float32(value))
        case .setBrightness(let index, let value): devices.displays.setBrightness(index, value)
        case .hideOtherApps: appSwitch.hideOthers()
        case .toggleMouseReverse: toggleMouseReverse()
        case .showCalendar:
            panel.close()
            clock.togglePopover()
        case .joinNextMeeting: clock.joinNext()
        }
        stateChanged()
    }

    @objc private func menuSettings() { showSettings() }
    @objc private func menuOrderCombo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        orderCombo(id)
        // A combo that still needs a permission continues on the Combos page, where its Allow buttons are.
        if let combo = ComboCatalog.combo(id, in: manager.settings),
           combo.gadgets.contains(where: { $0.info.requiredPermission.map { gadgetPermissionGranted($0) != true } ?? false }) {
            settingsWindow.combos.select(id)
            settingsWindow.select(.combos)
            settingsWindow.show()
        }
    }
    @objc private func menuUndoOrder() { undoOrder() }
    @objc private func menuNewCombo() { panelOpenCombos(newCombo: true) }
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
        case .calendars: address = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
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
            case "page": if let page = SettingsPage(key: parts[2]) { settingsWindow.select(page); settingsWindow.show() }
            case "tab":
                if let tab = DetailTab.allCases.first(where: { $0.key == parts[2] }) { settingsWindow.detail.select(tab: tab) }
            case "sample": samplePreviews = parts[2] == "on"; settingsWindow.refreshPreview()
            case "detail": settingsWindow.show(); _ = settingsWindow.writeDetailSnapshot(to: URL(fileURLWithPath: parts[2]))
            case "content": settingsWindow.show(); _ = settingsWindow.writeTabSnapshot(to: URL(fileURLWithPath: parts[2]))
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
            case "combos": panel.show(from: button, route: .combos)
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
        case "permstage" where parts.count == 3:
            // Debug only: show a permission card stage (`auto` follows the real state again).
            if let permission = GadgetPermission(rawValue: parts[1]) {
                stageOverrides[permission] = PermissionStage(rawValue: parts[2])
            }
        case "relaunch":
            relaunch()
        case "combo" where parts.count >= 2:
            // Debug only: `combo select|order|edit <id>`, `combo new [preset]`, `combo save`, `combo undo`,
            // `combo welcome on|off`.
            let argument = parts.count >= 3 ? parts[2] : ""
            switch parts[1] {
            case "select": settingsWindow.combos.select(argument); settingsWindow.select(.combos)
            case "order": orderCombo(argument)
            case "welcome": settingsWindow.combos.welcome = argument == "on"
            case "new": settingsWindow.select(.combos); settingsWindow.combos.startNewCombo(copying: ComboCatalog.combo(argument))
            case "edit": settingsWindow.select(.combos); settingsWindow.combos.edit(argument)
            case "undo": undoOrder()
            case "save": settingsWindow.combos.saveDraft()
            default: break
            }

        case "keepawake" where parts.count >= 2:
            // Debug only: `keepawake toggle|sleep|for <minutes>`.
            switch parts[1] {
            case "toggle": keepAwake.toggle()
            case "sleep": keepAwake.letSleep()
            case "for" where parts.count == 3: keepAwake.hold(minutes: Int(parts[2]) ?? 0)
            default: break
            }
        case "clipboard" where parts.count >= 2:
            // Debug only: `clipboard show|clear|plain|add <text>|pin <i>|shelve <i>`.
            let argument = parts.dropFirst(2).joined(separator: " ")
            let items = clipboard.history.search("")
            switch parts[1] {
            case "show": clipboard.showPanel()
            case "clear": clipboard.clearHistory()
            case "plain": clipboard.pastePlainLast()
            case "add": clipboard.debugAdd(argument)
            case "pin": if let i = Int(argument), items.indices.contains(i) { clipboard.togglePin(items[i].id) }
            case "shelve": if let i = Int(argument), items.indices.contains(i) { clipboard.shelve(items[i]) }
            default: break
            }
        case "device" where parts.count >= 2:
            // Debug only: `device mute|next|bright <step>`.
            switch parts[1] {
            case "mute": devices.toggleMic()
            case "next": devices.nextOutput()
            case "bright" where parts.count == 3: devices.changeBrightness(by: Int(parts[2]) ?? 0)
            default: break
            }
        case "switcher" where parts.count == 2:
            // Debug only: `switcher next|prev|close|hide`.
            switch parts[1] {
            case "next": appSwitch.cycle(forward: true)
            case "prev": appSwitch.cycle(forward: false)
            case "close": appSwitch.closeSwitcher()
            case "hide": appSwitch.hideOthers()
            default: break
            }
        case "calendar" where parts.count == 2:
            switch parts[1] {
            case "show": clock.togglePopover()
            case "hide": clock.closePopover()
            case "reload": clock.loadEvents(force: true)
            default: break
            }
        case "layout" where parts.count == 2:
            if parts[1] == "save" { snap.layouts.save() } else if parts[1] == "restore" { snap.layouts.restore() }
        case "session" where parts.count == 2:
            switch parts[1] {
            case "toggle": dim.toggleSession()
            case "stop": dim.sessions.stop()
            default: break
            }
        case "allowed" where parts.count == 2:
            if let id = ModuleID(rawValue: parts[1]) { recentlyAllowed[id] = Date() }
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
        case "record": capture.toggleRecording()
        case "color": capture.pickColor()
        case "live": capture.beginLiveWindow()
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
        case "markup": window.toggleMarkup()
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
