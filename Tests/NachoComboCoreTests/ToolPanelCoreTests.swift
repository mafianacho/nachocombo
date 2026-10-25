import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NachoComboCore

final class ToolPanelCoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nacho-combo-panel-\(UUID().uuidString)").appendingPathComponent("settings.json")
    }
    private let co = ToolShortcut.control | ToolShortcut.option

    func testStatusPresentationDotsFollowRealState() {
        XCTAssertEqual(ToolStatusPresentation.make(enabled: false, state: .off).dot, .off)
        XCTAssertEqual(ToolStatusPresentation.make(enabled: true, state: .running).dot, .on)
        let perm = ToolStatusPresentation.make(enabled: true, state: .needsPermission("권한"))
        XCTAssertEqual(perm.dot, .onNeedsSetup)
        XCTAssertEqual(perm.stateText, "권한 필요")
        XCTAssertEqual(perm.detail, "권한")
        let err = ToolStatusPresentation.make(enabled: true, state: .failed("충돌"))
        XCTAssertEqual(err.dot, .onError)
        XCTAssertTrue(err.accessibilityText.contains("오류"))
        // Switched on but not started yet must not read as green "running".
        let pending = ToolStatusPresentation.make(enabled: true, state: .off)
        XCTAssertEqual(pending.dot, .onNeedsSetup)
        XCTAssertEqual(pending.stateText, "시작 대기")
    }

    func testOffDropsSetupBadgeEvenIfStaleStateRemains() {
        let p = ToolStatusPresentation.make(enabled: false, state: .needsPermission("x"))
        XCTAssertEqual(p.dot, .off)
        XCTAssertNil(p.detail)
    }

    func testOldSettingsFileLoadsWithNothingPinnedAndNoShortcuts() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"enabledModules":{"windowSnap":true,"fileShelf":true},"menuBarCollapsed":true,"dimIntensity":0.4}"#.utf8).write(to: url)
        let s = SettingsStore(url: url).load()
        XCTAssertTrue(s.isEnabled(.windowSnap))
        XCTAssertTrue(s.menuBarCollapsed)
        for id in ModuleID.allCases { XCTAssertFalse(s.isPinned(id)); XCTAssertNil(s.shortcut(for: id)) }
    }

    func testPinAndShortcutRoundTripAndPinDoesNotEnable() throws {
        let store = SettingsStore(url: tempURL())
        let manager = ModuleManager(store: store, modules: [])
        manager.setPinned(.captureFloat, true)
        XCTAssertNil(manager.setShortcut(.focusDim, ToolShortcut(keyCode: 40, modifiers: co)))
        XCTAssertFalse(manager.settings.isEnabled(.captureFloat))          // pinning never switches a tool on
        XCTAssertEqual(manager.states[.captureFloat], .off)
        let reloaded = SettingsStore(url: store.url).load()
        XCTAssertTrue(reloaded.isPinned(.captureFloat))
        XCTAssertEqual(reloaded.shortcut(for: .focusDim), ToolShortcut(keyCode: 40, modifiers: co))
        manager.setPinned(.captureFloat, false)
        XCTAssertFalse(SettingsStore(url: store.url).load().isPinned(.captureFloat))
        XCTAssertNil(manager.setShortcut(.focusDim, nil))
        XCTAssertNil(SettingsStore(url: store.url).load().shortcut(for: .focusDim))
    }

    func testShortcutPolicy() {
        // two modifiers including ⌃/⌥ are required
        XCTAssertEqual(ShortcutPolicy.validate(ToolShortcut(keyCode: 40, modifiers: 0), for: .menuBar, existing: [:]),
                       .needsMoreModifiers)
        XCTAssertEqual(ShortcutPolicy.validate(ToolShortcut(keyCode: 40, modifiers: ToolShortcut.option), for: .menuBar, existing: [:]),
                       .needsMoreModifiers)
        XCTAssertEqual(ShortcutPolicy.validate(ToolShortcut(keyCode: 40, modifiers: ToolShortcut.command | ToolShortcut.shift),
                                               for: .menuBar, existing: [:]), .needsMoreModifiers)
        XCTAssertNil(ShortcutPolicy.validate(ToolShortcut(keyCode: 40, modifiers: ToolShortcut.option | ToolShortcut.shift),
                                             for: .menuBar, existing: [:]))
        // function keys may carry a single modifier
        XCTAssertNil(ShortcutPolicy.validate(ToolShortcut(keyCode: 111, modifiers: ToolShortcut.control), for: .menuBar, existing: [:]))
        // Esc / Delete / unknown keys are not usable
        XCTAssertEqual(ShortcutPolicy.validate(ToolShortcut(keyCode: 53, modifiers: co), for: .menuBar, existing: [:]), .unsupportedKey)
        XCTAssertEqual(ShortcutPolicy.validate(ToolShortcut(keyCode: 200, modifiers: co), for: .menuBar, existing: [:]), .unsupportedKey)
    }

    func testShortcutPolicyRejectsSystemActionAndDuplicateShortcuts() {
        let lock = ToolShortcut(keyCode: 12, modifiers: ToolShortcut.control | ToolShortcut.command)
        if case .reservedBySystem? = ShortcutPolicy.validate(lock, for: .menuBar, existing: [:]) {} else { XCTFail("lock screen") }
        let snapLeft = ToolShortcut(keyCode: 123, modifiers: co)
        if case .conflictsWithAction? = ShortcutPolicy.validate(snapLeft, for: .menuBar, existing: [:]) {} else { XCTFail("snap left") }
        let shelf = ToolShortcut(keyCode: 1, modifiers: co)
        if case .conflictsWithAction? = ShortcutPolicy.validate(shelf, for: .fileShelf, existing: [:]) {} else { XCTFail("shelf action") }
        let mine = ToolShortcut(keyCode: 46, modifiers: co)
        XCTAssertNil(ShortcutPolicy.validate(mine, for: .menuBar, existing: [:]))
        let existing = [ModuleID.menuBar.rawValue: mine]
        XCTAssertEqual(ShortcutPolicy.validate(mine, for: .systemMonitor, existing: existing), .conflictsWithTool(.menuBar))
        // re-saving the same tool's own shortcut is not a conflict
        XCTAssertNil(ShortcutPolicy.validate(mine, for: .menuBar, existing: existing))
    }

    func testManagerRefusesInvalidShortcutWithoutStoring() {
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: [])
        XCTAssertEqual(manager.setShortcut(.menuBar, ToolShortcut(keyCode: 40, modifiers: 0)), .needsMoreModifiers)
        XCTAssertNil(manager.settings.shortcut(for: .menuBar))
    }

    func testKeyLabels() {
        XCTAssertEqual(ToolShortcut(keyCode: 46, modifiers: ToolShortcut.option | ToolShortcut.shift).label, "⌥⇧M")
        XCTAssertEqual(ToolShortcut(keyCode: 123, modifiers: co).label, "⌃⌥←")
        XCTAssertEqual(ToolShortcut(keyCode: 49, modifiers: ToolShortcut.command | ToolShortcut.control).label, "⌃⌘Space")
    }

    func testPreviewFractions() {
        XCTAssertEqual(WindowLayout.previewFraction(for: .left), CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(WindowLayout.previewFraction(for: .right).minX, 0.5)
        XCTAssertEqual(WindowLayout.previewFraction(for: .maximize), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testStatusViaManagerUsesRealModuleState() {
        final class Stub: FeatureModule {
            let id = ModuleID.windowSnap
            func start() -> ModuleState { .needsPermission("동의 필요") }
            func stop() {}
            var diagnostics: [String: String] { [:] }
        }
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: [Stub()])
        XCTAssertEqual(manager.status(of: .windowSnap).dot, .off)
        manager.setEnabled(.windowSnap, true)
        XCTAssertEqual(manager.status(of: .windowSnap).dot, .onNeedsSetup)
        manager.setEnabled(.windowSnap, false)
        XCTAssertEqual(manager.status(of: .windowSnap).dot, .off)
    }

    func testSummarySeparatesPermissionAndErrorFromRunning() {
        XCTAssertEqual(ToolStatusPresentation.summary(of: [.off, .off]), "0개 켜짐")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [.on, .on, .off, .off, .off, .off]), "2개 켜짐")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [.on, .on, .on, .onNeedsSetup, .off, .off]),
                       "3개 켜짐 · 1개 권한 필요")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [.on, .onNeedsSetup, .onError]),
                       "1개 켜짐 · 1개 권한 필요 · 1개 오류")
    }
}
