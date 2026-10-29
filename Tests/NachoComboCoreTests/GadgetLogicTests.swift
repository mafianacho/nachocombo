import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NachoComboCore

final class GadgetLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Keep Awake

    func testKeepAwakeHoldsByHandUntilTheTimeIsUp() {
        let options = GadgetOptions.defaults
        let until = now.addingTimeInterval(30 * 60)
        let during = KeepAwakePolicy.decide(manual: true, until: until, now: now, runningApp: nil, onBattery: false,
                                            batteryPercent: nil, options: options)
        XCTAssertTrue(during.holds)
        XCTAssertEqual(during.text, "Awake for 30m more")
        let after = KeepAwakePolicy.decide(manual: true, until: until, now: until, runningApp: nil, onBattery: false,
                                           batteryPercent: nil, options: options)
        XCTAssertEqual(after, .sleepAllowed)
        XCTAssertEqual(KeepAwakePolicy.decide(manual: false, until: nil, now: now, runningApp: nil, onBattery: false,
                                              batteryPercent: nil, options: options), .sleepAllowed)
    }

    func testKeepAwakeFollowsChosenAppsAndTheBatteryGuard() {
        var options = GadgetOptions.defaults
        options.keepAwakeBatteryFloor = 20
        let app = KeepAwakePolicy.decide(manual: false, until: nil, now: now, runningApp: "Downloader", onBattery: true,
                                         batteryPercent: 60, options: options)
        XCTAssertEqual(app, .awake("Awake while Downloader runs"))
        let low = KeepAwakePolicy.decide(manual: true, until: nil, now: now, runningApp: nil, onBattery: true,
                                         batteryPercent: 20, options: options)
        XCTAssertFalse(low.holds)
        XCTAssertEqual(low, .heldBack("Battery at 20%: sleeping as usual"))
        // Low battery on the adapter is fine: the guard is about running out.
        XCTAssertTrue(KeepAwakePolicy.decide(manual: true, until: nil, now: now, runningApp: nil, onBattery: false,
                                             batteryPercent: 5, options: options).holds)
        options.keepAwakePowerOnly = true
        XCTAssertEqual(KeepAwakePolicy.decide(manual: true, until: nil, now: now, runningApp: nil, onBattery: true,
                                              batteryPercent: 90, options: options), .heldBack("Waiting for the power adapter"))
    }

    func testKeepAwakeTexts() {
        XCTAssertEqual(KeepAwakePolicy.remainingText(until: now.addingTimeInterval(65 * 60), now: now), "1:05")
        XCTAssertEqual(KeepAwakePolicy.remainingText(until: now.addingTimeInterval(59), now: now), "1m")
        XCTAssertEqual(KeepAwakePolicy.durationName(0), "Until Turned Off")
        XCTAssertEqual(KeepAwakePolicy.durationName(15), "15 Minutes")
        XCTAssertEqual(KeepAwakePolicy.durationName(60), "1 Hour")
        XCTAssertEqual(KeepAwakePolicy.durationName(300), "5 Hours")
    }

    // MARK: Clipboard History

    private func text(_ value: String, pinned: Bool = false) -> ClipboardItem {
        ClipboardItem(kind: .text, text: value, date: now, pinned: pinned)
    }

    func testClipboardDedupesAndMovesTheCopyUp() {
        var history = ClipboardHistory(limit: 10)
        history.add(text("one"))
        history.add(text("two"))
        history.add(text("one"))
        XCTAssertEqual(history.items.map { $0.text }, ["one", "two"])
        XCTAssertFalse(history.add(text("")), "empty copies are ignored")
    }

    func testClipboardLimitNeverDropsPins() {
        var history = ClipboardHistory(limit: 2)
        history.add(text("keep"))
        history.togglePin(history.items[0].id)
        for value in ["a", "b", "c"] { history.add(text(value)) }
        XCTAssertEqual(history.items.map { $0.text }, ["c", "b", "keep"])
        XCTAssertEqual(history.pins.map { $0.text }, ["keep"])
        // Copying a pin again keeps it pinned.
        history.add(text("keep"))
        XCTAssertTrue(history.items[0].pinned)
        history.clearUnpinned()
        XCTAssertEqual(history.items.map { $0.text }, ["keep"])
    }

    func testClipboardSearchListsPinsFirstAndMatchesEveryWord() {
        var history = ClipboardHistory(limit: 10, pins: [text("Main Street 12")])
        history.add(ClipboardItem(kind: .link, text: "https://example.com/report", sourceApp: "Browser"))
        history.add(text("quarterly report draft"))
        XCTAssertEqual(history.search("").first?.text, "Main Street 12")
        XCTAssertEqual(history.search("report").count, 2)
        XCTAssertEqual(history.search("report draft").map { $0.text }, ["quarterly report draft"])
        XCTAssertEqual(history.search("link").map { $0.kind }, [.link])
        XCTAssertEqual(history.search("browser").count, 1)
    }

    func testClipboardImagesDedupeByContentAndSkipHugeOnes() {
        var history = ClipboardHistory(limit: 10)
        let png = Data([1, 2, 3, 4])
        history.add(ClipboardItem(kind: .image, text: "", imagePNG: png))
        history.add(ClipboardItem(kind: .image, text: "", imagePNG: png))
        XCTAssertEqual(history.items.count, 1)
        let huge = Data(count: ClipboardHistory.maxImageBytes + 1)
        XCTAssertFalse(history.add(ClipboardItem(kind: .image, text: "", imagePNG: huge)))
    }

    func testClipboardTitles() {
        XCTAssertEqual(text("\n  first line \nsecond").title, "first line")
        XCTAssertEqual(ClipboardItem(kind: .files, text: "/a/Report.pdf").title, "Report.pdf")
        XCTAssertEqual(ClipboardItem(kind: .files, text: "/a/x.png\n/b/y.png").title, "2 files: x.png, y.png")
    }

    // MARK: Meeting links

    func testMeetingLinksFindVideoCallsOnly() {
        let notes = "Agenda: https://docs.example.com/plan.\nJoin: https://us02web.zoom.us/j/123456?pwd=abc)."
        XCTAssertEqual(MeetingLinks.detect(in: [nil, "Room 4", notes])?.absoluteString, "https://us02web.zoom.us/j/123456?pwd=abc")
        XCTAssertEqual(MeetingLinks.detect(in: ["https://meet.google.com/abc-defg-hij"])?.host, "meet.google.com")
        XCTAssertNil(MeetingLinks.detect(in: ["https://example.com/zoom.us"]))
        XCTAssertNil(MeetingLinks.detect(in: ["no links here"]))
    }

    // MARK: Calendar Clock

    func testWorldClockNamesAndOffsets() {
        XCTAssertEqual(WorldClock.city("America/New_York"), "New York")
        XCTAssertEqual(WorldClock.city("UTC"), "UTC")
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(WorldClock.offset(TimeZone(secondsFromGMT: 9 * 3600)!, from: utc, at: now), "+9h")
        XCTAssertEqual(WorldClock.offset(TimeZone(secondsFromGMT: -(3 * 3600 + 1800))!, from: utc, at: now), "−3h 30m")
        XCTAssertEqual(WorldClock.offset(utc, from: utc, at: now), "Same time")
        for id in WorldClock.suggestions { XCTAssertNotNil(TimeZone(identifier: id), id) }
    }

    func testClockTemplateAndCountdown() {
        XCTAssertEqual(ClockFormat.template(date: true, weekday: true, seconds: false, hours: .system), "EEEdMMMjmm")
        XCTAssertEqual(ClockFormat.template(date: false, weekday: false, seconds: true, hours: .twentyFour), "Hmmss")
        XCTAssertEqual(ClockFormat.countdown(to: now.addingTimeInterval(5 * 60), now: now), "in 5 min")
        XCTAssertEqual(ClockFormat.countdown(to: now.addingTimeInterval(80 * 60), now: now), "in 1 h 20 min")
        XCTAssertEqual(ClockFormat.countdown(to: now.addingTimeInterval(-60), now: now), "now")
        XCTAssertNil(ClockFormat.countdown(to: now.addingTimeInterval(-10 * 60), now: now))
    }

    // MARK: Mouse Tune

    func testSmoothScrollerDeliversTheWholeDistanceAndStopsOnReverse() {
        var scroller = SmoothScroller()
        scroller.add(120)
        var total = 0.0
        for _ in 0..<200 where !scroller.isIdle { total += scroller.step(dt: 1.0 / 120) }
        XCTAssertEqual(total, 120, accuracy: 0.0001)
        XCTAssertTrue(scroller.isIdle)
        scroller.add(80)
        _ = scroller.step(dt: 1.0 / 120)
        scroller.add(-40)
        XCTAssertEqual(scroller.pending, -40, "turning the wheel back drops the rest of the glide")
        XCTAssertEqual(ScrollTuning.adjusted(3, reverse: true, speed: 2), -6)
    }

    // MARK: Window layouts

    func testDisplaySignatureIgnoresTheOrderScreensAreListed() {
        let a = CGRect(x: 0, y: 0, width: 1512, height: 982), b = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(DisplaySignature.make([b, a]), "1512x982+0+0,1920x1080+1512+0")
        XCTAssertEqual(DisplaySignature.make([a, b]), DisplaySignature.make([b, a]))
    }

    func testLayoutStoreKeepsOnePerDisplaySetAndRoundTrips() throws {
        var store = WindowLayoutStore()
        let w = SavedWindow(bundleID: "com.example.notes", appName: "Notes", frame: CGRect(x: 10, y: 20, width: 300, height: 200),
                            order: 0)
        store.save(SavedWindowLayout(displays: "A", displayCount: 1, savedAt: now, windows: [w]))
        store.save(SavedWindowLayout(displays: "B", displayCount: 2, savedAt: now, windows: []))
        store.save(SavedWindowLayout(displays: "A", displayCount: 1, savedAt: now.addingTimeInterval(60), windows: [w, w]))
        XCTAssertEqual(store.layouts.map { $0.displays }, ["A", "B"])
        XCTAssertEqual(store.layout(for: "A")?.windows.count, 2)
        XCTAssertNil(store.layout(for: "C"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layouts-\(UUID().uuidString).json")
        try store.write(to: url)
        XCTAssertEqual(WindowLayoutStore.load(from: url), store)
        for i in 0..<12 { store.save(SavedWindowLayout(displays: "X\(i)", displayCount: 1, savedAt: now, windows: [])) }
        XCTAssertEqual(store.layouts.count, WindowLayoutStore.maxLayouts)
    }

    func testLayoutMatchingGivesEachAppItsFramesInOrder() {
        let saved = [
            SavedWindow(bundleID: "editor", appName: "Editor", frame: CGRect(x: 0, y: 0, width: 100, height: 100), order: 0),
            SavedWindow(bundleID: "editor", appName: "Editor", frame: CGRect(x: 100, y: 0, width: 100, height: 100), order: 1),
            SavedWindow(bundleID: "mail", appName: "Mail", frame: CGRect(x: 200, y: 0, width: 50, height: 50), order: 0),
        ]
        let current: [(bundleID: String, order: Int)] = [("editor", 0), ("browser", 0), ("editor", 1), ("editor", 2)]
        let result = LayoutMatching.assign(saved: saved, current: current)
        XCTAssertEqual(result[0]?.minX, 0)
        XCTAssertNil(result[1], "apps without a saved frame stay where they are")
        XCTAssertEqual(result[2]?.minX, 100)
        XCTAssertNil(result[3], "a third editor window has no saved frame")
    }

    // MARK: Focus sessions

    func testFocusSessionRunsFocusThenBreakThenStops() {
        var session = FocusSession()
        session.start(now: now, minutes: 25)
        XCTAssertEqual(session.phase, .focus)
        XCTAssertEqual(FocusSession.clock(session.remaining(now: now)), "25:00")
        XCTAssertNil(session.tick(now: now.addingTimeInterval(60), breakMinutes: 5))
        XCTAssertEqual(session.tick(now: now.addingTimeInterval(25 * 60), breakMinutes: 5), .focusEnded)
        XCTAssertEqual(session.phase, .rest)
        XCTAssertEqual(session.completed, 1)
        XCTAssertEqual(session.tick(now: now.addingTimeInterval(30 * 60), breakMinutes: 5), .restEnded)
        XCTAssertEqual(session.phase, .idle)
        session.start(now: now, minutes: 1)
        XCTAssertEqual(session.tick(now: now.addingTimeInterval(61), breakMinutes: 0), .focusEnded)
        XCTAssertFalse(session.isActive, "no break: straight back to idle")
    }

    // MARK: options and combos

    func testNewOptionsFallBackOneByOne() throws {
        let json = #"{"keepAwakeMinutes":-5,"clipboardLimit":3,"mouseSpeed":99,"clockHours":"bogus","focusMinutes":25}"#
        let options = try JSONDecoder().decode(GadgetOptions.self, from: Data(json.utf8))
        XCTAssertEqual(options.keepAwakeMinutes, 0)
        XCTAssertEqual(options.clipboardLimit, 10)
        XCTAssertEqual(options.mouseSpeed, 5)
        XCTAssertEqual(options.clockHours, .system)
        XCTAssertEqual(options.focusMinutes, 25)
        XCTAssertTrue(options.autoApplyLayouts)
        XCTAssertEqual(options.appShortcuts, [])
    }

    func testOptionTabSwitcherIsAllowedButCommandTabIsNot() {
        let settings = AppSettings.defaults
        let optionTab = ToolShortcut(keyCode: 48, modifiers: ToolShortcut.option)
        XCTAssertNil(ShortcutPolicy.validateAction(optionTab, actionID: "appSwitch.next", settings: settings))
        let commandTab = ToolShortcut(keyCode: 48, modifiers: ToolShortcut.command)
        XCTAssertNotNil(ShortcutPolicy.validateAction(commandTab, actionID: "appSwitch.next", settings: settings))
        let controlA = ToolShortcut(keyCode: 0, modifiers: ToolShortcut.control)
        XCTAssertEqual(ShortcutPolicy.validateAction(controlA, actionID: "appSwitch.next", settings: settings), .needsMoreModifiers)
    }

    func testAppShortcutsCannotClashWithActionsOrEachOther() {
        var settings = AppSettings.defaults
        let mail = ToolShortcut(keyCode: 46, modifiers: ToolShortcut.control | ToolShortcut.option)   // ⌃⌥M: mic mute
        XCTAssertNotNil(ShortcutPolicy.validateAppShortcut(mail, bundleID: "mail", settings: settings))
        let free = ToolShortcut(keyCode: 0, modifiers: ToolShortcut.control | ToolShortcut.option | ToolShortcut.command)
        XCTAssertNil(ShortcutPolicy.validateAppShortcut(free, bundleID: "mail", settings: settings))
        settings.options.appShortcuts = [AppHotKey(bundleID: "mail", name: "Mail", shortcut: free)]
        XCTAssertNil(ShortcutPolicy.validateAppShortcut(free, bundleID: "mail", settings: settings), "its own shortcut")
        XCTAssertNotNil(ShortcutPolicy.validateAppShortcut(free, bundleID: "notes", settings: settings))
        XCTAssertNotNil(ShortcutPolicy.validateAction(free, actionID: "clipboard.show", settings: settings))
    }

    func testEveryGadgetHasAMomentForCustomCombos() {
        for id in ModuleID.allCases {
            XCTAssertFalse(ComboCatalog.moments(for: [id]).isEmpty, id.rawValue)
        }
        let meeting = ComboCatalog.combo("meeting")
        XCTAssertEqual(meeting?.gadgets, [.calendarClock, .deviceControl, .keepAwake])
        XCTAssertTrue(meeting?.permissions.isEmpty ?? false, "the Meeting combo needs no permission to order")
        XCTAssertEqual(ComboCatalog.combo("full")?.number, ComboCatalog.presets.count)
    }

    func testNewActionsAreUniqueAndBelongToTheirGadget() {
        XCTAssertEqual(Set(GadgetActions.all.map { $0.id }).count, GadgetActions.all.count)
        XCTAssertEqual(GadgetActions.action("clipboard.show")?.module, .clipboard)
        XCTAssertEqual(GadgetActions.groups(of: .windowSnap).last?.title, "Layouts")
        XCTAssertEqual(GadgetActions.groups(of: .windowSnap).flatMap { $0.actions }.count, GadgetActions.of(.windowSnap).count)
    }
}
