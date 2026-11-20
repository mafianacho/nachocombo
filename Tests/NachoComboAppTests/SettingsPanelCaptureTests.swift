import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-856: the settings panel inside the widget window, drawn off screen on macOS CI (NOT a real Mac: no window
/// chrome, no popover arrow). Scenes: wall with the panel closed; Calendar Clock's Settings / Shortcuts / Permissions
/// tabs; every other gadget's Settings tab; the app settings tabs; entry points from outside; edit mode closing the
/// panel; the window's minimum width. Also: what is changed in the panel is kept by a new `ModuleManager` on the same
/// store (the app restarting). Pictures go to .build/bento-captures and, base64 in chunks, to the test log
/// (BENTO-CAPTURE lines). Everything the host reports below is a TEST FIXTURE.
final class SettingsPanelCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        ComputerUseModule.permissionOverride = { $0 == .accessibility ? true : $0 == .screenRecording ? false : true }
    }

    override func tearDown() {
        ComputerUseModule.permissionOverride = nil
        super.tearDown()
    }

    // MARK: fixture

    private final class StubModule: FeatureModule {
        let id: ModuleID
        init(_ id: ModuleID) { self.id = id }
        func start() -> ModuleState {
            // Window Snap waits for Accessibility: its page shows the permission card (the permission scenes).
            id == .windowSnap ? .needsPermission("Accessibility") : .running
        }
        func stop() {}
        var diagnostics: [String: String] { [:] }
    }

    /// The widget window's host and the settings panel's host in one: a real `ModuleManager` on a temporary store, the
    /// board's widgets from the existing fixture, and answers for everything else.
    final class PanelHost: SettingsHost, BentoHost {
        let bento = BentoCaptureTests.FixtureHost()
        let storeURL: URL
        let manager: ModuleManager
        var window: NSWindow?
        var combosOrdered: [String] = []
        let computerUse: ComputerUseModule
        var mcpCard: ComputerUseCard?
        private var petCard: PetSettingsCard?
        private var computerUseGadgetCard: ComputerUseGadgetCard?

        init(storeURL: URL? = nil) {
            let url = storeURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("nc-panel-\(UUID().uuidString)/settings.json")
            self.storeURL = url
            manager = ModuleManager(store: SettingsStore(url: url), modules: ModuleID.allCases.map { StubModule($0) })
            computerUse = ComputerUseModule(keys: APIKeyStore(url: nil))
            computerUse.currentSettings = { [manager] in manager.settings.computerUse }
            computerUse.gadgetOn = { [manager] in manager.settings.isEnabled(.computerUse) }
            // The same gadgets are on as on the wall of the board fixture.
            for id in [ModuleID.nachoPet, .systemMonitor, .windowSnap, .keepAwake, .clipboard, .captureFloat, .deviceControl, .calendarClock] {
                _ = manager.setEnabled(id, true)
            }
        }

        // BentoHost
        var bentoLayout: BentoLayout { bento.bentoLayout }
        func bentoUpdateLayout(_ change: (inout BentoLayout) -> Void) { bento.bentoUpdateLayout(change) }
        func bentoWidget(_ id: ModuleID) -> BentoWidget { bento.bentoWidget(id) }
        func bentoPetImage(signedIn: Bool) -> NSImage? { bento.bentoPetImage(signedIn: signedIn) }
        func bentoSetEnabled(_ id: ModuleID, _ on: Bool) { gadgetSetEnabled(id, on) }
        func bentoSetPinned(_ id: ModuleID, _ pinned: Bool) { bento.bentoSetPinned(id, pinned) }
        func bentoOpen(_ id: ModuleID) {}
        func bentoPerform(_ id: ModuleID) {}
        func bentoOpenSettings() {}
        func bentoOpenBoard() {}
        var bentoUpdateState: BentoUpdateState { .idle }
        func bentoInstallUpdate(from window: NSWindow?) {}

        // GadgetHost
        var gadgetManager: ModuleManager { manager }
        func gadgetSubtitle(_ id: ModuleID) -> String { "" }
        func gadgetAttention(_ id: ModuleID) -> [String] { [] }
        func gadgetBadgeCount(_ id: ModuleID) -> Int { 0 }
        func gadgetStatusLine(_ id: ModuleID) -> String? { nil }
        func gadgetPreviewInputs() -> GadgetPreviewInputs { GadgetPreviewInputs() }
        func gadgetMonitorPreview(appearance: NSAppearance.Name) -> (strip: NSImage?, panel: NSImage?, live: Bool) { (nil, nil, false) }
        func gadgetPermissionGranted(_ permission: GadgetPermission) -> Bool? {
            switch permission {
            case .accessibility, .fullDiskAccess: return false
            case .screenRecording: return false
            case .notifications, .calendars: return nil
            }
        }
        func gadgetPermissionStage(_ permission: GadgetPermission) -> PermissionStage { .notAllowed }
        func gadgetRecentlyAllowed(_ id: ModuleID) -> Bool { false }
        func gadgetOpenPermissionSettings(_ permission: GadgetPermission) {}
        func gadgetRequestPermission(_ permission: GadgetPermission) {}
        func gadgetAskAgain(_ permission: GadgetPermission) {}
        func gadgetForgetSettingsVisit(_ permission: GadgetPermission) {}
        func gadgetRelaunch() {}
        func gadgetRecheck(_ id: ModuleID) {}
        func gadgetSetEnabled(_ id: ModuleID, _ on: Bool) { _ = manager.setEnabled(id, on) }
        func gadgetSetPinned(_ id: ModuleID, _ pinned: Bool) {}
        func gadgetSetToolShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> String? { nil }
        func gadgetSetActionShortcut(_ actionID: String, _ shortcut: ToolShortcut?, reset: Bool) -> String? { nil }
        func gadgetResetActionShortcuts(_ id: ModuleID) {}
        func gadgetActionShortcutUnavailable(_ actionID: String) -> Bool { false }
        func gadgetRecordingChanged(_ recording: Bool) {}
        func gadgetSetOptions(_ options: GadgetOptions) { manager.setOptions(options) }
        func gadgetSetMonitorSettings(_ value: MonitorSettings) { manager.setMonitorSettings(value) }
        func gadgetSetDimIntensity(_ value: Double) {}
        func gadgetPerform(_ command: GadgetCommand) {}
        func gadgetDismissHint(_ key: String) {}
        func gadgetOpenDesktopSettings() {}
        var gadgetWindow: NSWindow? { window }
        func gadgetDevices() -> DeviceSnapshot { DeviceSnapshot() }
        func gadgetCommandState(_ command: GadgetCommand) -> (on: Bool, enabled: Bool) { (false, true) }
        func gadgetSetAppShortcut(_ bundleID: String, _ shortcut: ToolShortcut?) -> String? { nil }
        func gadgetComputerUseView() -> NSView? {
            if computerUseGadgetCard == nil {
                let card = ComputerUseGadgetCard(module: computerUse, manager: manager, width: GadgetDetailView.cardInner)
                card.refresh(state: manager.settings.isEnabled(.computerUse) ? .running : .off)
                computerUseGadgetCard = card
            }
            return computerUseGadgetCard?.view
        }
        func gadgetPetView() -> NSView? {
            if petCard == nil { petCard = PetSettingsCard(module: NachoPetModule(), width: GadgetDetailView.cardInner) }
            return petCard?.view
        }

        // SettingsHost
        var loginItemState: LoginItemState { .off }
        func setOpenAtLogin(_ on: Bool) -> String? { nil }
        func openLoginItemsSettings() {}
        func revealSettingsFile() {}
        func resetAllSettings() {}
        func quitApp() {}
        func settingsMCPView() -> NSView? {
            if mcpCard == nil {
                _ = manager.setEnabled(.computerUse, true)
                let card = ComputerUseCard(module: computerUse, manager: manager, width: GadgetDetailView.cardInner)
                card.refresh(state: .running)
                mcpCard = card
            }
            return mcpCard?.view
        }
        func permissionsAttentionCount() -> Int { 1 }
        func orderCombo(_ id: String) { combosOrdered.append(id) }
        func allowFromCombo(_ id: ModuleID) {}
        func saveCombo(_ combo: SavedCombo) -> Bool { true }
        func deleteCombo(_ id: String) {}
        var orderUndoName: String? { nil }
        func undoOrder() {}
        var updateState: UpdateController.State { .idle }
        var currentVersion: String { "0.12.1" }
        func checkForUpdatesNow() {}
        func installUpdate() {}
        func openReleasePage() {}
        var previousVersion: String? { nil }
        func revertUpdate() {}
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }

    /// Draws `view` in its own borderless window of `size` (the window the test controller owns keeps its content).
    private func render(_ view: NSView, size: NSSize, dark: Bool, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try emit(png, name: "\(name)-\(dark ? "dark" : "light")")
    }

    private func makeWindow(_ host: PanelHost, size: NSSize = BentoWindowController.defaultSize, dark: Bool = false) -> BentoWindowController {
        let controller = BentoWindowController(host: host, settingsHost: host)
        host.window = controller.window
        controller.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        controller.window.setContentSize(size)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.reload()
        return controller
    }

    /// The whole widget window with the panel open on `route`, drawn at `size`.
    private func windowScene(_ name: String, route: SettingsPanelRoute?, size: NSSize = BentoWindowController.defaultSize,
                             prepare: ((PanelHost) -> Void)? = nil) throws {
        for dark in [false, true] {
            let host = PanelHost()
            prepare?(host)
            let controller = makeWindow(host, size: size, dark: dark)
            controller.openPanel(route, bringToFront: false, animated: false)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            let layout = controller.panelLayout
            if route != nil, let panel = layout.panel {
                XCTAssertGreaterThanOrEqual(panel.minX, 0, "\(name): the panel is inside the window")
                XCTAssertLessThanOrEqual(panel.maxX, size.width + 0.5, "\(name): the panel is inside the window")
                if size.width - panel.width >= BentoWindowController.minBoardWidth {
                    XCTAssertLessThanOrEqual(layout.board.maxX, panel.minX + 0.5, "\(name): the board does not run under the panel")
                }
            }
            let view = try XCTUnwrap(controller.window.contentView)
            controller.window.contentView = nil
            try render(view, size: size, dark: dark, name: name)
        }
    }

    /// Only the panel, tall enough that a whole page shows (the page scrolls in the window).
    private func panelScene(_ name: String, route: SettingsPanelRoute, height: CGFloat = 900, host: PanelHost? = nil) throws {
        for dark in [false, true] {
            let theHost = host ?? PanelHost()
            let panel = SettingsPanelView(host: theHost)
            panel.show(route)
            panel.frame = NSRect(x: 0, y: 0, width: SettingsPanelView.width, height: height)
            try render(panel, size: NSSize(width: SettingsPanelView.width, height: height), dark: dark, name: name)
        }
    }

    // MARK: scenes

    /// Scene 1: the wall with the panel closed.
    func testScene1WallPanelClosed() throws {
        try windowScene("s1-wall-closed", route: nil)
    }

    /// Scene 2: a tile click opens Calendar Clock (the reference capture), its three tabs.
    func testScene2CalendarClockTabs() throws {
        for tab in GadgetPanelTab.allCases {
            try windowScene("s2-calendar-\(tab.rawValue)", route: .gadget(.calendarClock, tab))
        }
    }

    /// Scene 3: every other gadget's panel (Settings tab), one picture each, then the permission cases.
    func testScene3EveryGadgetPanel() throws {
        for id in ModuleID.allCases where id != .calendarClock {
            try panelScene("s3-gadget-\(id.rawValue)", route: .gadget(id, .settings), height: 1000)
        }
        // Every gadget has all three tabs, none empty (an empty Permissions tab says so).
        let host = PanelHost()
        _ = host.manager.setEnabled(.windowSnap, true)   // waits for Accessibility: the permission card shows on its page
        let panel = SettingsPanelView(host: host)
        for id in ModuleID.allCases {
            for tab in SettingsPanelRoute.tabs(for: id) {
                panel.show(.gadget(id, tab))
                XCTAssertFalse(panel.detail.tabContent.arrangedSubviewsOrSelf.isEmpty, "\(id) \(tab) has content")
            }
        }
        try panelScene("s3-permissions-windowSnap", route: .gadget(.windowSnap, .permissions), height: 700, host: host)
        try panelScene("s3-permissions-none-diskMap-shortcuts", route: .gadget(.diskMap, .shortcuts), height: 800, host: host)
    }

    /// Scene 4: the "설정" pill's app settings: General, Permissions, Combos, MCP.
    func testScene4AppSettingsTabs() throws {
        for tab in AppPanelTab.allCases {
            try panelScene("s4-app-\(tab.rawValue)", route: .app(tab), height: 1000)
        }
        try windowScene("s4-app-general-in-window", route: .app(.general))
    }

    /// Scene 5: entries from outside open the widget window with the panel on the right page.
    func testScene5ExternalEntries() throws {
        try windowScene("s5-entry-menubar-settings", route: SettingsEntry.menuBarSettings.route)
        try windowScene("s5-entry-permission-windowSnap", route: SettingsEntry.permissionNeeded(.windowSnap).route) { host in
            _ = host.manager.setEnabled(.windowSnap, true)
        }
        try windowScene("s5-entry-firstrun-combos", route: SettingsEntry.firstRunCombo.route)
        try windowScene("s5-entry-hidden-widget", route: SettingsEntry.hiddenWidgetSettings(.diskMap).route) { host in
            host.bentoUpdateLayout { $0.setHidden(.diskMap, true) }
        }
    }

    /// Scene 6: edit mode closes the panel and shows the edit drawer; they never show together.
    func testScene6EditModeClosesPanel() throws {
        for dark in [false, true] {
            let host = PanelHost()
            let controller = makeWindow(host, dark: dark)
            controller.openPanel(.gadget(.clipboard, .settings), bringToFront: false, animated: false)
            XCTAssertTrue(controller.isPanelOpen)
            controller.beginEditing()
            XCTAssertFalse(controller.isPanelOpen, "edit mode closes the panel")
            XCTAssertNil(controller.panelLayout.panel, "the panel is gone from the window")
            controller.tileClick(.clipboard, animated: false)
            XCTAssertFalse(controller.isPanelOpen, "a tile click while editing does not open the panel")
            controller.board.select(.clipboard)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(controller.window.contentView)
            controller.window.contentView = nil
            try render(view, size: BentoWindowController.defaultSize, dark: dark, name: "s6-edit-closes-panel")
            controller.window.contentView = view
            controller.endEditing()
            XCTAssertFalse(controller.isPanelOpen)
            controller.tileClick(.clipboard, animated: false)
            XCTAssertTrue(controller.isPanelOpen, "after editing, a tile click opens the panel again")
        }
    }

    /// Tile clicks: open, swap the content, close on the same tile; Esc and the close button close.
    func testTileClicksSwapAndClose() {
        let host = PanelHost()
        let controller = makeWindow(host)
        controller.tileClick(.clipboard, animated: false)
        XCTAssertEqual(controller.panelRoute, .gadget(.clipboard, .settings))
        controller.tileClick(.diskMap, animated: false)
        XCTAssertEqual(controller.panelRoute, .gadget(.diskMap, .settings), "another tile swaps the content")
        controller.tileClick(.diskMap, animated: false)
        XCTAssertFalse(controller.isPanelOpen, "the same tile again closes")
        controller.tileClick(.clipboard, animated: false)
        controller.settingsPanel?.onClose?()
        XCTAssertFalse(controller.isPanelOpen, "the close button closes")
    }

    /// The window's minimum width (480, the panel's width): every control of the panel shows, nothing scrolls sideways.
    func testMinimumWidthShowsWholePanel() throws {
        let min = BentoWindowController.minContentWidth
        XCTAssertEqual(min, SettingsPanelView.width)
        try windowScene("s7-min480-gadget", route: .gadget(.calendarClock, .settings), size: NSSize(width: min, height: 770))
        try windowScene("s7-min480-app", route: .app(.general), size: NSSize(width: min, height: 770))
        let host = PanelHost()
        let controller = makeWindow(host, size: NSSize(width: min, height: 770))
        XCTAssertEqual(controller.window.contentMinSize.width, min, "the window cannot be made narrower than the panel")
        controller.openPanel(.app(.general), bringToFront: false, animated: false)
        let panel = try XCTUnwrap(controller.settingsPanel)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.panelLayout.panel?.width, min, "the panel is as wide as the window")
        XCTAssertLessThanOrEqual(GadgetDetailView.width, panel.bounds.width, "the page fits the panel: no sideways scrolling")
        // Every button of the page is inside the panel (not cut off at the right edge).
        func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }
        for button in buttons(panel) where !button.isHiddenOrHasHiddenAncestor {
            let frame = panel.convert(button.bounds, from: button)
            XCTAssertLessThanOrEqual(frame.maxX, panel.bounds.width + 0.5, "\(button.title) stays inside the panel")
        }
        controller.closePanel(animated: false)
        XCTAssertNil(controller.panelLayout.panel)
        XCTAssertGreaterThanOrEqual(controller.panelLayout.board.width, 200, "the board is back")
    }

    // MARK: kept settings

    /// A control in the panel changes a gadget option; a new `ModuleManager` on the same store (the app starting
    /// again) still has it. (A real restart of the app is not exercised here.)
    func testPanelChangeSurvivesANewManager() throws {
        let host = PanelHost()
        let panel = SettingsPanelView(host: host)
        panel.show(.gadget(.menuBar, .settings))
        panel.frame = NSRect(x: 0, y: 0, width: SettingsPanelView.width, height: 900)
        panel.layoutSubtreeIfNeeded()
        let box = try XCTUnwrap(SettingsPanelCaptureTests.find(in: panel) { ($0 as? NSButton)?.title == "Expand when the pointer rests on ‹" } as? NSButton)
        XCTAssertEqual(box.state, .off)
        XCTAssertFalse(host.manager.settings.options.expandOnHover)
        box.performClick(nil)
        XCTAssertTrue(host.manager.settings.options.expandOnHover, "the panel control changed the option")
        // The app starts again: a new manager reads the same settings file.
        let again = ModuleManager(store: SettingsStore(url: host.storeURL), modules: [])
        XCTAssertTrue(again.settings.options.expandOnHover, "the value is still there after a restart of the manager")
        // The gadget's switch in the panel is kept too.
        _ = host.manager.setEnabled(.keepAwake, true)
        XCTAssertTrue(ModuleManager(store: SettingsStore(url: host.storeURL), modules: []).settings.isEnabled(.keepAwake))
    }

    /// Accessibility: the panel is a group with a label and the close button says what it does.
    func testPanelAccessibility() {
        let host = PanelHost()
        let controller = makeWindow(host)
        controller.openPanel(.gadget(.calendarClock, .settings), bringToFront: false, animated: false)
        let panel = controller.settingsPanel!
        XCTAssertEqual(panel.accessibilityLabel(), "상세 설정 패널")
        XCTAssertEqual(panel.accessibilityRole(), .group)
        let close = SettingsPanelCaptureTests.find(in: panel) { $0.accessibilityIdentifier() == "settings-panel-close" }
        XCTAssertEqual(close?.accessibilityLabel(), "닫기")
        XCTAssertNotNil(SettingsPanelCaptureTests.find(in: panel) { $0.accessibilityIdentifier() == "detail-tabs" }, "the tabs keep their identifier")
        XCTAssertNotNil(SettingsPanelCaptureTests.find(in: panel) { $0.accessibilityIdentifier() == "detail-enable" }, "the switch keeps its identifier")
    }

    static func find(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for sub in view.subviews { if let hit = find(in: sub, where: match) { return hit } }
        return nil
    }
}

private extension NSView {
    /// A tab's rows (the stack's views) or, for a plain view, its subviews.
    var arrangedSubviewsOrSelf: [NSView] { (self as? NSStackView)?.arrangedSubviews ?? subviews }
}
