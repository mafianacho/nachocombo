import AppKit
import ApplicationServices
import Carbon.HIToolbox
import NachoComboCore

/// App shortcuts (open, bring forward or hide an app) and a window switcher: hold the switcher shortcut's modifiers
/// (⌥ by default) and press Tab to go through every window, not only apps; letting go switches. Windows are listed
/// from the window server and named through the Accessibility API, which is also what raises the chosen one.
final class AppSwitchModule: NSObject, FeatureModule, PermissionPrompting {
    var allowPermissionPrompt = false
    let id = ModuleID.appSwitch
    static let permissionMessage = "To list and raise other apps' windows, allow Nacho Combo in "
        + "\(GadgetPermission.accessibility.location)."

    var optionsProvider: () -> GadgetOptions = { .defaults }
    /// The switcher shortcut, to know which modifiers have to be held.
    var switcherShortcutProvider: () -> ToolShortcut? = { nil }
    var onChange: (() -> Void)?

    private let appKeys = HotKeyCenter(signature: 0x4E43_4150)   // 'NCAP'
    private let cancelKeys = HotKeyCenter(signature: 0x4E43_4553)   // 'NCES'
    private var promptedSinceEnabled = false
    private(set) var running = false
    private(set) var failedApps: [String] = []
    private(set) var switchCount = 0
    private var switcher: WindowSwitcherPanel?
    private var holdTimer: Timer?

    func start() -> ModuleState {
        let shouldPrompt = allowPermissionPrompt && !promptedSinceEnabled
        if allowPermissionPrompt { promptedSinceEnabled = true }
        guard WindowSnapModule.isTrusted(prompt: shouldPrompt) else { return .needsPermission(AppSwitchModule.permissionMessage) }
        running = true
        applyOptions()
        return .running
    }

    func stop() {
        running = false
        promptedSinceEnabled = false
        appKeys.unregisterAll()
        failedApps = []
        closeSwitcher()
    }

    /// Re-registers the app shortcuts.
    func applyOptions() {
        appKeys.unregisterAll()
        failedApps = []
        guard running else { return }
        for (index, hotKey) in optionsProvider().appShortcuts.enumerated() {
            guard let shortcut = hotKey.shortcut else { continue }
            let ok = appKeys.register(id: UInt32(index + 1), keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                DispatchQueue.main.async { self?.openOrToggle(hotKey) }
            }
            if !ok { failedApps.append(hotKey.bundleID) }
        }
    }

    /// While the user records a shortcut, the app shortcuts must not catch the key.
    func suspendShortcuts() { appKeys.unregisterAll() }

    // MARK: app shortcuts

    func openOrToggle(_ hotKey: AppHotKey) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: hotKey.bundleID).first
        if let app = running, app.isActive, optionsProvider().appHideOnRepeat {
            app.hide()
            return
        }
        // Opening a running app brings it forward and asks it for a window if it has none.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hotKey.bundleID) else {
            Toast.show("\(hotKey.name) is not installed", near: NSEvent.mouseLocation)
            return
        }
        running?.unhide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    func hideOthers() {
        guard running else { return }
        let front = NSWorkspace.shared.frontmostApplication
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app.processIdentifier != front?.processIdentifier && app.processIdentifier != getpid() {
            app.hide()
        }
    }

    // MARK: window switcher

    var switcherVisible: Bool { switcher != nil }

    func cycle(forward: Bool) {
        guard running else { return }
        if let switcher = switcher { switcher.move(forward ? 1 : -1); return }
        let windows = SwitchableWindow.list()
        guard !windows.isEmpty else { return }
        let panel = WindowSwitcherPanel(windows: windows)
        panel.onPick = { [weak self] index in self?.commit(index) }
        panel.select(forward ? min(1, windows.count - 1) : windows.count - 1)
        panel.show()
        switcher = panel
        // Esc cancels; with the modifiers still held it arrives as ⌥Esc (or whatever they are).
        let mods = switcherShortcutProvider()?.modifiers ?? UInt32(optionKey)
        for (index, modifiers) in [mods, mods | UInt32(shiftKey), 0].enumerated() {
            _ = cancelKeys.register(id: UInt32(index + 1), keyCode: UInt32(kVK_Escape), modifiers: modifiers) { [weak self] in
                DispatchQueue.main.async { self?.closeSwitcher() }
            }
        }
        // Letting go of the modifiers switches. Their state is read from the window server, which needs no monitor.
        let t = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in self?.checkHold() }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
        onChange?()
    }

    private func checkHold() {
        guard let switcher = switcher else { return }
        let held = CGEventSource.flagsState(.combinedSessionState)
        let wanted = AppSwitchModule.cgFlags(carbon: switcherShortcutProvider()?.modifiers ?? UInt32(optionKey))
            .subtracting(.maskShift)
        if held.intersection(wanted).isEmpty { commit(switcher.selectedIndex) }
    }

    private func commit(_ index: Int) {
        guard let switcher = switcher else { return }
        let window = switcher.windows.indices.contains(index) ? switcher.windows[index] : nil
        closeSwitcher()
        window?.focus()
        if window != nil { switchCount += 1 }
    }

    func closeSwitcher() {
        holdTimer?.invalidate()
        holdTimer = nil
        cancelKeys.unregisterAll()
        switcher?.orderOut(nil)
        switcher?.close()
        switcher = nil
        onChange?()
    }

    static func cgFlags(carbon: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }

    var diagnostics: [String: String] {
        [
            "running": "\(running)",
            "accessibility": "\(AXIsProcessTrusted())",
            "appShortcuts": "\(appKeys.registeredCount)",
            "appShortcutsFailed": failedApps.joined(separator: ","),
            "switcherVisible": "\(switcher != nil)",
            "switcherWindows": "\(switcher?.windows.count ?? 0)",
            "switchCount": "\(switchCount)",
        ]
    }
}

// MARK: - Windows to switch to

struct SwitchableWindow {
    let pid: pid_t
    let appName: String
    let icon: NSImage?
    let title: String
    let element: AXUIElement?
    let minimized: Bool

    /// On-screen windows front to back (current Space), then minimized ones. Titles come from the Accessibility API,
    /// matched to the window server's list by position and size.
    static func list() -> [SwitchableWindow] {
        let own = getpid()
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var axCache: [pid_t: [(element: AXUIElement, frame: CGRect, title: String, minimized: Bool)]] = [:]
        func axWindows(_ pid: pid_t) -> [(element: AXUIElement, frame: CGRect, title: String, minimized: Bool)] {
            if let cached = axCache[pid] { return cached }
            let app = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            var result: [(element: AXUIElement, frame: CGRect, title: String, minimized: Bool)] = []
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for element in windows {
                    let window = AXWindow(element: element, pid: pid)
                    guard window.isStandard, let frame = window.axFrame else { continue }
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
                    var minimized: CFTypeRef?
                    AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized)
                    result.append((element, frame, (title as? String) ?? "", (minimized as? Bool) ?? false))
                }
            }
            axCache[pid] = result
            return result
        }

        var list: [SwitchableWindow] = []
        var used: Set<String> = []
        for entry in raw {
            guard let pidValue = entry[kCGWindowOwnerPID as String] as? Int, pidValue != Int(own),
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 80, frame.height >= 50,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { continue }
            let pid = pid_t(pidValue)
            guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            let match = axWindows(pid).first { abs($0.frame.minX - frame.minX) < 3 && abs($0.frame.minY - frame.minY) < 3
                && abs($0.frame.width - frame.width) < 3 && abs($0.frame.height - frame.height) < 3 }
            let key = "\(pid):\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width))"
            guard !used.contains(key) else { continue }
            used.insert(key)
            let name = app.localizedName ?? "App"
            let title = (match?.title).flatMap { $0.isEmpty ? nil : $0 } ?? name
            list.append(SwitchableWindow(pid: pid, appName: name, icon: app.icon, title: title, element: match?.element,
                                         minimized: false))
        }
        // Minimized windows of the apps that run, at the end.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != own {
            for window in axWindows(app.processIdentifier) where window.minimized {
                list.append(SwitchableWindow(pid: app.processIdentifier, appName: app.localizedName ?? "App", icon: app.icon,
                                             title: window.title.isEmpty ? (app.localizedName ?? "App") : window.title,
                                             element: window.element, minimized: true))
            }
        }
        return Array(list.prefix(24))
    }

    func focus() {
        if let element = element {
            if minimized { AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
}

// MARK: - The switcher

final class WindowSwitcherPanel: NSPanel {
    let windows: [SwitchableWindow]
    private(set) var selectedIndex = 0
    var onPick: ((Int) -> Void)?
    private var rows: [SwitcherRow] = []
    static let width: CGFloat = 460
    static let rowHeight: CGFloat = 40

    init(windows: [SwitchableWindow]) {
        self.windows = windows
        let height = CGFloat(windows.count) * WindowSwitcherPanel.rowHeight + 20
        super.init(contentRect: NSRect(x: 0, y: 0, width: WindowSwitcherPanel.width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: WindowSwitcherPanel.width, height: height))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        contentView = effect
        for (index, window) in windows.enumerated() {
            let row = SwitcherRow(window: window)
            row.frame = NSRect(x: 10, y: height - 10 - CGFloat(index + 1) * WindowSwitcherPanel.rowHeight,
                               width: WindowSwitcherPanel.width - 20, height: WindowSwitcherPanel.rowHeight)
            row.onClick = { [weak self] in self?.onPick?(index) }
            effect.addSubview(row)
            rows.append(row)
        }
        setAccessibilityLabel("Window Switcher")
    }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var frame = self.frame
        frame.size.height = min(frame.height, visible.height - 40)
        setFrame(NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2 + visible.height * 0.08,
                        width: frame.width, height: frame.height), display: true)
        orderFrontRegardless()
    }

    func select(_ index: Int) {
        guard !windows.isEmpty else { return }
        selectedIndex = (index % windows.count + windows.count) % windows.count
        for (i, row) in rows.enumerated() { row.selected = i == selectedIndex }
    }

    func move(_ step: Int) { select(selectedIndex + step) }
}

final class SwitcherRow: NSView {
    var selected = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private let item: SwitchableWindow

    init(window: SwitchableWindow) {
        self.item = window
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(window.title), \(window.appName)")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        item.icon?.draw(in: NSRect(x: 8, y: (bounds.height - 28) / 2, width: 28, height: 28))
        let ink: NSColor = selected ? .white : .labelColor
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let appFont = NSFont.systemFont(ofSize: 11)
        let titleRect = NSRect(x: 46, y: bounds.midY - 1, width: bounds.width - 56, height: 17)
        (item.title as NSString).draw(with: titleRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                         attributes: [.font: titleFont, .foregroundColor: ink])
        let app = item.appName + (item.minimized ? " · minimized" : "")
        (app as NSString).draw(with: NSRect(x: 46, y: bounds.midY - 15, width: bounds.width - 56, height: 14),
                               options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                               attributes: [.font: appFont, .foregroundColor: ink.withAlphaComponent(0.7)])
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
