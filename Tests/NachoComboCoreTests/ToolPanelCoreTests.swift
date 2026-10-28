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
        let perm = ToolStatusPresentation.make(enabled: true, state: .needsPermission("Permission"))
        XCTAssertEqual(perm.dot, .onNeedsSetup)
        XCTAssertEqual(perm.stateText, "Needs Permission")
        XCTAssertEqual(perm.detail, "Permission")
        let err = ToolStatusPresentation.make(enabled: true, state: .failed("Conflict"))
        XCTAssertEqual(err.dot, .onError)
        XCTAssertTrue(err.accessibilityText.contains("error"))
        // Switched on but not started yet must not read as green "running".
        let pending = ToolStatusPresentation.make(enabled: true, state: .off)
        XCTAssertEqual(pending.dot, .onNeedsSetup)
        XCTAssertEqual(pending.stateText, "Starting…")
        // The state names the permission it waits for when it is known.
        let named = ToolStatusPresentation.make(enabled: true, state: .needsPermission("x"), permission: "Accessibility")
        XCTAssertEqual(named.stateText, "Needs Accessibility")
        XCTAssertEqual(named.waitingFor, "Accessibility")
        XCTAssertNil(ToolStatusPresentation.make(enabled: false, state: .needsPermission("x"), permission: "Accessibility").waitingFor)
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
        XCTAssertNil(manager.setShortcut(.focusDim, ToolShortcut(keyCode: 37, modifiers: co)))   // ⌃⌥L (⌃⌥K snaps)
        XCTAssertFalse(manager.settings.isEnabled(.captureFloat))          // pinning never switches a tool on
        XCTAssertEqual(manager.states[.captureFloat], .off)
        let reloaded = SettingsStore(url: store.url).load()
        XCTAssertTrue(reloaded.isPinned(.captureFloat))
        XCTAssertEqual(reloaded.shortcut(for: .focusDim), ToolShortcut(keyCode: 37, modifiers: co))
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
            func start() -> ModuleState { .needsPermission("Consent needed") }
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
        func p(_ enabled: Bool, _ state: ModuleState, _ permission: String? = nil) -> ToolStatusPresentation {
            ToolStatusPresentation.make(enabled: enabled, state: state, permission: permission)
        }
        let off = p(false, .off), on = p(true, .running)
        let ax = p(true, .needsPermission("x"), "Accessibility"), rec = p(true, .needsPermission("x"), "Screen Recording")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [off, off]), "0 running")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [on, on, off, off, off, off]), "2 running")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [on, on, on, ax, off, off]), "3 running · 1 needs Accessibility")
        XCTAssertEqual(ToolStatusPresentation.summary(of: [on, ax, p(true, .failed("e"))]),
                       "1 running · 1 needs Accessibility · 1 error")
        XCTAssertEqual(ToolStatusPresentation.waitingText(of: [ax, rec]), "2 need permissions")
        XCTAssertEqual(ToolStatusPresentation.waitingText(of: [ax, ax]), "2 need Accessibility")
        XCTAssertEqual(ToolStatusPresentation.waitingText(of: [p(true, .off)]), "1 starting")
        XCTAssertNil(ToolStatusPresentation.waitingText(of: [on, off]))
    }

    func testManagerStatusNamesTheRequiredPermission() throws {
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: [])
        manager.setEnabled(.windowSnap, true)
        manager.report(.windowSnap, state: .needsPermission("x"))
        XCTAssertEqual(manager.status(of: .windowSnap).stateText, "Needs Accessibility")
        manager.setEnabled(.captureFloat, true)
        manager.report(.captureFloat, state: .needsPermission("x"))
        XCTAssertEqual(manager.status(of: .captureFloat).waitingFor, "Screen Recording")
        XCTAssertNil(ModuleID.systemMonitor.info.requiredPermission, "notifications are optional")
    }

    func testPermissionWordingFollowsTheMacOSVersion() {
        XCTAssertEqual(GadgetPermission.accessibility.location(major: 12),
                       "System Preferences ▸ Security & Privacy ▸ Privacy ▸ Accessibility")
        XCTAssertEqual(GadgetPermission.accessibility.location(major: 14), "System Settings ▸ Privacy & Security ▸ Accessibility")
        XCTAssertEqual(GadgetPermission.screenRecording.paneName(major: 14), "Screen Recording")
        XCTAssertEqual(GadgetPermission.screenRecording.location(major: 15),
                       "System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording")
        XCTAssertEqual(GadgetPermission.notifications.path(major: 12), "Notifications & Focus ▸ Nacho Combo")
        XCTAssertFalse(GadgetPermission.accessibility.location.contains("Monterey"), "one path, never two")
        XCTAssertEqual(GadgetPermission.screenRecording.tccService, "ScreenCapture")
        XCTAssertNil(GadgetPermission.notifications.tccService)
    }

    func testPermissionGuideStages() {
        func stage(granted: Bool = false, _ permission: GadgetPermission = .accessibility, visited: Bool = false,
                   front: Bool = false, old: String? = nil, now: String? = "b") -> PermissionStage {
            PermissionGuide.stage(granted: granted, permission: permission, visitedSettings: visited, settingsInFront: front,
                                  grantedSignature: old, currentSignature: now)
        }
        XCTAssertEqual(stage(), .notAllowed)
        XCTAssertEqual(stage(granted: true, visited: true), .allowed)
        XCTAssertEqual(stage(visited: true, front: true), .waiting)
        XCTAssertEqual(stage(visited: true), .stillNotAllowed)
        XCTAssertEqual(stage(.screenRecording, visited: true), .restartNeeded)
        XCTAssertEqual(stage(old: "a"), .updated, "allowed for an earlier copy")
        XCTAssertEqual(stage(old: "b"), .notAllowed, "same copy: the user turned it off")
        XCTAssertEqual(stage(visited: true, front: true, old: "a"), .waiting)
    }

    func testNewAppSettingsFallBackOnOldFilesAndRoundTrip() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"enabledModules":{},"menuBarCollapsed":false,"launchWindow":"bogus"}"#.utf8).write(to: url)
        let store = SettingsStore(url: url)
        var s = store.load()
        XCTAssertEqual(s.launchWindow, .whenNeeded)
        XCTAssertTrue(s.menuBarAttentionDot)
        XCTAssertTrue(s.permissionGrants.isEmpty)
        XCTAssertFalse(s.hintDismissed("menuBarSetup"))
        s.launchWindow = .never
        s.dismissedHints["menuBarSetup"] = true
        s.permissionGrants["accessibility"] = "abc"
        try store.save(s)
        let back = store.load()
        XCTAssertEqual(back.launchWindow, .never)
        XCTAssertTrue(back.hintDismissed("menuBarSetup"))
        XCTAssertEqual(back.permissionGrants["accessibility"], "abc")
    }

    func testResetAllTurnsEverythingOffButKeepsPermissionBookkeeping() {
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: [])
        manager.setEnabled(.fileShelf, true)
        manager.setPinned(.fileShelf, true)
        manager.update { $0.permissionGrants["accessibility"] = "abc"; $0.launchWindow = .never }
        _ = manager.setActionShortcut("shelf.toggle", nil)
        manager.resetAll()
        XCTAssertFalse(manager.settings.isEnabled(.fileShelf))
        XCTAssertFalse(manager.settings.isPinned(.fileShelf))
        XCTAssertEqual(manager.settings.launchWindow, .whenNeeded)
        XCTAssertTrue(manager.settings.actionShortcuts.isEmpty)
        XCTAssertEqual(manager.settings.permissionGrants["accessibility"], "abc")
        XCTAssertEqual(manager.states[.fileShelf], .off)
    }

    func testRestoreDefaultsForOneGadgetNeverCreatesAClash() {
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: [])
        let left = GadgetActions.snapID(.left)
        let leftDefault = GadgetActions.action(left)!.defaultShortcut!
        _ = manager.setActionShortcut(left, nil)                               // the user removed ⌃⌥←
        XCTAssertNil(manager.setActionShortcut("shelf.paste", leftDefault))    // and gave it to another gadget
        _ = manager.setActionShortcut(GadgetActions.snapID(.right), nil)
        manager.resetActionShortcuts(of: .windowSnap)
        XCTAssertEqual(manager.settings.shortcut(forAction: GadgetActions.snapID(.right)),
                       GadgetActions.action(GadgetActions.snapID(.right))!.defaultShortcut)
        XCTAssertNil(manager.settings.shortcut(forAction: left), "its default belongs to File Shelf now")
        XCTAssertEqual(manager.settings.shortcut(forAction: "shelf.paste"), leftDefault)
    }

    func testSnapGroupsCoverEveryPositionOnce() {
        let grouped = GadgetActions.snapGroups.flatMap { $0.actions }
        XCTAssertEqual(grouped.count, SnapAction.allCases.count)
        XCTAssertEqual(Set(grouped.map { $0.rawValue }), Set(SnapAction.allCases.map { $0.rawValue }))
        XCTAssertEqual(GadgetActions.groups(of: .windowSnap).flatMap { $0.actions }.count, GadgetActions.of(.windowSnap).count)
        XCTAssertEqual(GadgetActions.groups(of: .captureFloat).count, 1)
        XCTAssertNil(GadgetActions.groups(of: .captureFloat).first?.title)
    }

    func testCombosAreWellFormed() {
        XCTAssertEqual(ComboCatalog.presets.map { $0.number }, [1, 2, 3, 4, 5])
        XCTAssertEqual(Set(ComboCatalog.presets.map { $0.id }).count, ComboCatalog.presets.count)
        for combo in ComboCatalog.presets {
            XCTAssertFalse(combo.moments.isEmpty, combo.id)
            for moment in combo.moments {
                XCTAssertTrue(combo.gadgets.contains(moment.module), "\(combo.id) shows a moment of a gadget it leaves out")
                for action in moment.actions { XCTAssertNotNil(GadgetActions.action(action), action) }
                XCTAssertTrue(!moment.actions.isEmpty || !moment.gesture.isEmpty, "\(combo.id): a moment needs a key or a gesture")
            }
        }
        XCTAssertTrue(ComboCatalog.combo("starter")!.permissions.isEmpty, "Starter asks for nothing")
        XCTAssertEqual(ComboCatalog.combo("desk")!.permissions, [.accessibility, .screenRecording])
        XCTAssertEqual(ComboCatalog.combo("builder")!.permissions, [.accessibility])
    }

    func testComboPlanSaysWhatChanges() {
        var settings = AppSettings.defaults
        settings.setEnabled(.focusDim, true)
        settings.setEnabled(.fileShelf, true)
        let plan = ComboPlan.make(ComboCatalog.combo("desk")!, settings: settings)
        XCTAssertEqual(plan.turnsOn, [.windowSnap, .captureFloat])
        XCTAssertEqual(plan.staysOn, [.fileShelf])
        XCTAssertEqual(plan.turnsOff, [.focusDim])
        XCTAssertEqual(plan.optionChanges, ["Gap Between Windows: None → 8 pt"])
        settings.options.snapGap = 8
        XCTAssertTrue(ComboPlan.make(ComboCatalog.combo("desk")!, settings: settings).optionChanges.isEmpty)
        let focus = ComboPlan.make(ComboCatalog.combo("focus")!, settings: .defaults)
        XCTAssertEqual(focus.optionChanges, ["Dim strength: 50% → 60%", "Collapse Again After: 10 s → 5 s"],
                       "dimOtherDisplays is already on by default")
    }

    func testOrderingAComboHoldsBackWhatNeedsAPermission() {
        final class Stub: FeatureModule {
            let id: ModuleID
            var prompted = false
            init(_ id: ModuleID) { self.id = id }
            func start() -> ModuleState { .running }
            func stop() {}
            var diagnostics: [String: String] { [:] }
        }
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: ModuleID.allCases.map { Stub($0) })
        manager.setEnabled(.focusDim, true)
        let desk = ComboCatalog.combo("desk")!
        manager.order(desk, enable: [.fileShelf])          // Window Snap and Capture Float wait for Allow
        XCTAssertEqual(manager.settings.combo, "desk")
        XCTAssertTrue(manager.settings.isEnabled(.fileShelf))
        XCTAssertFalse(manager.settings.isEnabled(.windowSnap))
        XCTAssertFalse(manager.settings.isEnabled(.focusDim), "a combo switches off what it leaves out")
        XCTAssertEqual(manager.settings.options.snapGap, 8)
        XCTAssertNil(ComboCatalog.current(manager.settings), "not complete until the held-back gadgets are on")
        manager.setEnabled(.windowSnap, true)
        manager.setEnabled(.captureFloat, true)
        XCTAssertEqual(ComboCatalog.current(manager.settings)?.id, "desk")
    }

    func testCustomCombosSaveNumberAndMatch() throws {
        let store = SettingsStore(url: tempURL())
        let manager = ModuleManager(store: store, modules: [])
        manager.setEnabled(.fileShelf, true)
        manager.setEnabled(.windowSnap, true)
        var draft = ComboCatalog.draft(from: manager.settings)
        XCTAssertEqual(draft.name, "My Combo")
        XCTAssertEqual(draft.gadgets, [.windowSnap, .fileShelf], "starts from what is on")
        draft.name = "  Morning  "
        draft.tuning.snapGap = 12
        XCTAssertTrue(manager.saveCombo(draft))
        let saved = try XCTUnwrap(ComboCatalog.combo(draft.id, in: manager.settings))
        XCTAssertEqual(saved.name, "Morning")
        XCTAssertEqual(saved.number, 6, "numbered after the five presets")
        XCTAssertTrue(saved.isCustom)
        XCTAssertEqual(saved.moments.map { $0.module }, [.windowSnap, .fileShelf])
        XCTAssertEqual(ComboCatalog.current(manager.settings)?.id, draft.id, "the box is exactly this combo")
        XCTAssertEqual(ComboCatalog.draft(from: manager.settings).name, "My Combo")
        XCTAssertEqual(ComboCatalog.draft(from: manager.settings, copying: ComboCatalog.combo("desk")).name, "My Desk")
        // Survives a reload.
        XCTAssertEqual(store.load().customCombos.first?.tuning.snapGap, 12)
        // Empty combos are refused; the cap holds.
        XCTAssertFalse(manager.saveCombo(SavedCombo(id: "x", name: "Empty", gadgets: [], tuning: ComboTuning())))
        for n in 0..<10 {
            _ = manager.saveCombo(SavedCombo(id: "c\(n)", name: "C\(n)", gadgets: [.focusDim], tuning: ComboTuning()))
        }
        XCTAssertEqual(manager.settings.customCombos.count, ComboCatalog.maxCustom)
        manager.update { $0.combo = draft.id }
        manager.deleteCombo(draft.id)
        XCTAssertNil(ComboCatalog.combo(draft.id, in: manager.settings))
        XCTAssertNil(manager.settings.combo, "forgetting the ordered combo with it")
    }

    func testUndoPutsTheBoxBack() {
        final class Stub: FeatureModule {
            let id: ModuleID
            init(_ id: ModuleID) { self.id = id }
            func start() -> ModuleState { .running }
            func stop() {}
            var diagnostics: [String: String] { [:] }
        }
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: ModuleID.allCases.map { Stub($0) })
        manager.setEnabled(.systemMonitor, true)
        let before = manager.snapshot()
        manager.order(ComboCatalog.combo("focus")!, enable: [.focusDim, .menuBar])
        XCTAssertFalse(manager.settings.isEnabled(.systemMonitor))
        XCTAssertEqual(manager.settings.options.autoCollapseSeconds, 5)
        manager.restore(before)
        XCTAssertTrue(manager.settings.isEnabled(.systemMonitor))
        XCTAssertFalse(manager.settings.isEnabled(.focusDim))
        XCTAssertEqual(manager.settings.options.autoCollapseSeconds, 10)
        XCTAssertEqual(manager.settings.dimIntensity, before.dimIntensity, accuracy: 0.0001)
        XCTAssertNil(manager.settings.combo)
        XCTAssertEqual(manager.snapshot(), before)
    }
}
