import XCTest
@testable import NachoComboCore

final class WindowLayoutTests: XCTestCase {
    private let landscape = CGRect(x: 0, y: 25, width: 1200, height: 775)
    private let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)

    func testQuartersTileTheScreenExactly() {
        let quarters: [SnapAction] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        let rects = quarters.map { WindowLayout.target(for: $0, in: landscape) }
        XCTAssertEqual(rects.map { $0.width * $0.height }.reduce(0, +), landscape.width * landscape.height)
        XCTAssertEqual(rects[0].maxX, rects[1].minX)
        XCTAssertEqual(rects[2].maxY, rects[0].minY)
        XCTAssertEqual(rects[0].maxY, landscape.maxY)
        XCTAssertEqual(rects[3].minY, landscape.minY)
    }

    func testThirdsRunAcrossLandscapeAndDownPortrait() {
        let first = WindowLayout.target(for: .firstThird, in: landscape)
        let center = WindowLayout.target(for: .centerThird, in: landscape)
        let last = WindowLayout.target(for: .lastThird, in: landscape)
        XCTAssertEqual(first.minX, landscape.minX)
        XCTAssertEqual(first.maxX, center.minX)
        XCTAssertEqual(center.maxX, last.minX)
        XCTAssertEqual(last.maxX, landscape.maxX)
        XCTAssertEqual(first.height, landscape.height)
        XCTAssertEqual(WindowLayout.target(for: .firstTwoThirds, in: landscape).width, 800)

        let top = WindowLayout.target(for: .firstThird, in: portrait)
        XCTAssertEqual(top.maxY, portrait.maxY)                 // first third is the top one on a portrait screen
        XCTAssertEqual(top.width, portrait.width)
        XCTAssertEqual(top.height, 640)
        XCTAssertEqual(WindowLayout.target(for: .lastThird, in: portrait).minY, portrait.minY)
    }

    func testRepeatedHalfCyclesThroughTwoThirdsAndOneThird() {
        let half = WindowLayout.target(for: .left, in: landscape, current: nil, gap: 0, cycle: true)
        XCTAssertEqual(half.width, 600)
        let twoThirds = WindowLayout.target(for: .left, in: landscape, current: half, gap: 0, cycle: true)
        XCTAssertEqual(twoThirds.width, 800)
        XCTAssertEqual(twoThirds.minX, landscape.minX)
        let third = WindowLayout.target(for: .left, in: landscape, current: twoThirds, gap: 0, cycle: true)
        XCTAssertEqual(third.width, 400)
        XCTAssertEqual(WindowLayout.target(for: .left, in: landscape, current: third, gap: 0, cycle: true).width, 600)
        // Right half anchors at the right edge while cycling, and cycling off always gives the half.
        let right = WindowLayout.target(for: .right, in: landscape, current: WindowLayout.target(for: .right, in: landscape),
                                        gap: 0, cycle: true)
        XCTAssertEqual(right.maxX, landscape.maxX)
        XCTAssertEqual(right.width, 800)
        XCTAssertEqual(WindowLayout.target(for: .left, in: landscape, current: half, gap: 0, cycle: false).width, 600)
    }

    func testGapsSeparateNeighboursByOneGap() {
        let gap: CGFloat = 10
        let l = WindowLayout.target(for: .left, in: landscape, current: nil, gap: gap, cycle: false)
        let r = WindowLayout.target(for: .right, in: landscape, current: nil, gap: gap, cycle: false)
        XCTAssertEqual(l.minX, landscape.minX + gap)
        XCTAssertEqual(r.minX - l.maxX, gap)
        XCTAssertEqual(r.maxX, landscape.maxX - gap)
        XCTAssertEqual(l.maxY, landscape.maxY - gap)
        // Cycling still recognises a half that was placed with gaps.
        let next = WindowLayout.target(for: .left, in: landscape, current: l, gap: gap, cycle: true)
        XCTAssertEqual(next.width, 800 - gap - gap / 2)
    }

    func testCenterKeepsSizeAndAlmostMaximizeLeavesMargin() {
        let window = CGRect(x: 10, y: 40, width: 500, height: 300)
        let centered = WindowLayout.target(for: .center, in: landscape, current: window, gap: 0, cycle: false)
        XCTAssertEqual(centered.size, window.size)
        XCTAssertEqual(centered.midX, landscape.midX, accuracy: 1)
        XCTAssertEqual(centered.midY, landscape.midY, accuracy: 1)
        let almost = WindowLayout.target(for: .almostMaximize, in: landscape)
        XCTAssertEqual(almost.width, 1080)
        XCTAssertEqual(almost.midX, landscape.midX, accuracy: 1)
        let tall = WindowLayout.target(for: .maximizeHeight, in: landscape, current: window, gap: 0, cycle: false)
        XCTAssertEqual(tall.minX, window.minX)
        XCTAssertEqual(tall.width, window.width)
        XCTAssertEqual(tall.height, landscape.height)
    }

    func testSmallerAndLargerStayInsideTheScreen() {
        let window = CGRect(x: 300, y: 200, width: 600, height: 400)
        let larger = WindowLayout.target(for: .larger, in: landscape, current: window, gap: 0, cycle: false)
        XCTAssertEqual(larger.width, 660)
        XCTAssertEqual(larger.midX, window.midX, accuracy: 1)
        let smaller = WindowLayout.target(for: .smaller, in: landscape, current: window, gap: 0, cycle: false)
        XCTAssertEqual(smaller.width, 540)
        // Never smaller than a quarter of the screen, never larger than the screen, never outside it.
        let tiny = WindowLayout.target(for: .smaller, in: landscape, current: CGRect(x: 0, y: 25, width: 310, height: 200),
                                       gap: 0, cycle: false)
        XCTAssertEqual(tiny.width, 300)
        let huge = WindowLayout.target(for: .larger, in: landscape, current: landscape.insetBy(dx: 5, dy: 5), gap: 0, cycle: false)
        XCTAssertTrue(landscape.contains(huge))
        XCTAssertEqual(huge.size, landscape.size)
    }

    func testMoveToAnotherDisplayKeepsProportions() {
        let right = CGRect(x: 1200, y: 0, width: 2400, height: 1600)
        let half = WindowLayout.target(for: .left, in: landscape)
        let moved = WindowLayout.move(half, from: landscape, to: right)
        XCTAssertEqual(moved.minX, right.minX)
        XCTAssertEqual(moved.width, 1200)
        XCTAssertEqual(moved.height, right.height)
        let screens = [landscape, right, CGRect(x: -1080, y: 0, width: 1080, height: 1920)]
        XCTAssertEqual(WindowLayout.adjacentScreen(of: 0, screens: screens, forward: true), 1)
        XCTAssertEqual(WindowLayout.adjacentScreen(of: 1, screens: screens, forward: true), 2)   // wraps to the left-most
        XCTAssertEqual(WindowLayout.adjacentScreen(of: 0, screens: screens, forward: false), 2)
        XCTAssertNil(WindowLayout.adjacentScreen(of: 0, screens: [landscape], forward: true))
    }

    func testDragZones() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1, y: 450), screen: screen), .left)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1439, y: 450), screen: screen), .right)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 700, y: 899), screen: screen), .maximize)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 2, y: 890), screen: screen), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 15, y: 899), screen: screen), .topLeft)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1438, y: 10), screen: screen), .bottomRight)
        // Along a side edge, just past the corner: top / bottom half.
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1, y: 800), screen: screen), .topHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1439, y: 100), screen: screen), .bottomHalf)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 300, y: 1), screen: screen), .firstThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 700, y: 1), screen: screen), .centerThird)
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 1100, y: 1), screen: screen), .lastThird)
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 700, y: 450), screen: screen))
        XCTAssertNil(SnapZones.action(at: CGPoint(x: 3000, y: 1), screen: screen))
        XCTAssertEqual(SnapZones.action(at: CGPoint(x: 500, y: 1), screen: CGRect(x: 0, y: 0, width: 1080, height: 1920)),
                       .bottomHalf)
    }

    func testCenterTwoThirds() {
        let r = WindowLayout.target(for: .centerTwoThirds, in: landscape)
        XCTAssertEqual(r.minX, 200)
        XCTAssertEqual(r.width, 800)
        XCTAssertEqual(HotKeySpec.spec(for: .centerTwoThirds)?.label, "⌃⌥R")
    }

    func testDefaultSnapShortcutsAreUnique() {
        let keys = HotKeySpec.defaults.map { "\($0.keyCode)/\($0.carbonModifiers)" }
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(HotKeySpec.defaults.map { $0.action }).count, HotKeySpec.defaults.count)
        XCTAssertEqual(HotKeySpec.spec(for: .left)?.label, "⌃⌥←")
        XCTAssertEqual(HotKeySpec.spec(for: .maximizeHeight)?.label, "⌃⌥⇧↑")
        XCTAssertEqual(HotKeySpec.spec(for: .nextDisplay)?.label, "⌃⌥⌘→")
        XCTAssertEqual(HotKeySpec.spec(for: .restore)?.label, "⌃⌥⌫")
    }
}

final class GadgetCatalogTests: XCTestCase {
    func testEveryGadgetHasADetailPage() {
        for id in ModuleID.allCases {
            let info = id.info
            XCTAssertEqual(info.id, id)
            XCTAssertFalse(info.tagline.isEmpty)
            XCTAssertGreaterThanOrEqual(info.features.count, 5, "\(id) features")
            XCTAssertFalse(info.tips.isEmpty, "\(id) tips")
            // Without a required permission, the page must say why none is needed.
            if !info.permissions.contains(where: { !$0.optional }) { XCTAssertFalse(info.permissionNote.isEmpty, "\(id)") }
        }
        // The permission lists match what the modules really ask for.
        XCTAssertEqual(ModuleID.windowSnap.info.permissions.map { $0.permission }, [.accessibility])
        XCTAssertEqual(ModuleID.captureFloat.info.permissions.map { $0.permission }, [.screenRecording])
        XCTAssertTrue(ModuleID.menuBar.info.permissions.isEmpty)
        XCTAssertTrue(ModuleID.focusDim.info.permissions.isEmpty)
        XCTAssertTrue(ModuleID.fileShelf.info.permissions.isEmpty)
        XCTAssertEqual(GadgetActions.of(.windowSnap).count, SnapAction.allCases.count)
    }

    func testActionShortcutsDefaultsAreUniqueAndOverridable() throws {
        let defaults = AppSettings.defaults.effectiveActionShortcuts
        let keys = defaults.map { "\($0.keyCode)/\($0.modifiers)" }
        XCTAssertEqual(Set(keys).count, keys.count, "no two default actions share a shortcut")
        XCTAssertEqual(AppSettings.defaults.shortcut(forAction: "dim.toggle")?.label, "⌃⌥⌘H")
        XCTAssertEqual(AppSettings.defaults.shortcut(forAction: "capture.area")?.label, "⇧⌘2")
        XCTAssertEqual(AppSettings.defaults.shortcut(forAction: "shelf.toggle")?.label, "⌃⌥S")
        XCTAssertNil(AppSettings.defaults.shortcut(forAction: "menuBar.toggle"))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let manager = ModuleManager(store: SettingsStore(url: url), modules: [])
        let co = ToolShortcut.control | ToolShortcut.option
        // Taken by another action, by macOS, or too few modifiers.
        XCTAssertEqual(manager.setActionShortcut("menuBar.toggle", ToolShortcut(keyCode: 123, modifiers: co)),
                       .conflictsWithAction("Window Snap Left Half ⌃⌥←"))
        XCTAssertEqual(manager.setActionShortcut("menuBar.toggle", ToolShortcut(keyCode: 21, modifiers: ToolShortcut.command | ToolShortcut.shift)),
                       .reservedBySystem("Screenshot ⇧⌘4"))
        XCTAssertEqual(manager.setActionShortcut("menuBar.toggle", ToolShortcut(keyCode: 11, modifiers: ToolShortcut.option)),
                       .needsMoreModifiers)
        // A free combination is stored; removing the left-half shortcut frees ⌃⌥← for it.
        XCTAssertNil(manager.setActionShortcut("menuBar.toggle", ToolShortcut(keyCode: 11, modifiers: co)))
        XCTAssertEqual(manager.settings.shortcut(forAction: "menuBar.toggle")?.label, "⌃⌥B")
        XCTAssertNil(manager.setActionShortcut(GadgetActions.snapID(.left), nil))
        XCTAssertNil(manager.settings.shortcut(forAction: GadgetActions.snapID(.left)))
        XCTAssertNil(manager.setActionShortcut("menuBar.toggle", ToolShortcut(keyCode: 123, modifiers: co)))
        // A tool-open shortcut may not take an action's combination either.
        XCTAssertEqual(manager.setShortcut(.menuBar, ToolShortcut(keyCode: 123, modifiers: co)),
                       .conflictsWithAction("Menu Bar Organizer Expand / Collapse ⌃⌥←"))
        // Back to the default, and it survives a reload.
        XCTAssertNil(manager.setActionShortcut(GadgetActions.snapID(.left), nil, reset: true))
        XCTAssertEqual(manager.settings.shortcut(forAction: GadgetActions.snapID(.left))?.label, "⌃⌥←")
        let reloaded = SettingsStore(url: url).load()
        XCTAssertEqual(reloaded.shortcut(forAction: "menuBar.toggle")?.label, "⌃⌥←")
        XCTAssertEqual(reloaded.shortcut(forAction: GadgetActions.snapID(.left))?.label, "⌃⌥←")
    }

    func testOptionsDecodeEachFieldOnItsOwn() throws {
        let json = #"{"version":1,"enabledModules":{},"menuBarCollapsed":false,"options":{"snapGap":"wide","autoCollapseSeconds":30,"shelfTrigger":"anyDrag","dimFadeSeconds":99}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.options.snapGap, GadgetOptions.defaults.snapGap, "a broken value falls back alone")
        XCTAssertEqual(s.options.autoCollapseSeconds, 30)
        XCTAssertEqual(s.options.shelfTrigger, .anyDrag)
        XCTAssertEqual(s.options.dimFadeSeconds, 5, "clamped")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"enabledModules":{},"menuBarCollapsed":false}"#.utf8))
        XCTAssertEqual(old.options, .defaults)
        XCTAssertTrue(old.actionShortcuts.isEmpty)
    }
}
