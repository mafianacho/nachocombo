import Foundation
import XCTest
@testable import NachoComboCore

final class PetDesktopParseTests: XCTestCase {
    func testParsesAppCommands() {
        XCTAssertEqual(PetCommands.parse(capability: "combo_open_app", params: ["app": "  계산기 "]), .success(.openApp("계산기")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_focus_app", params: ["app": "com.apple.Safari"]),
                       .success(.focusApp("com.apple.Safari")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_hide_app", params: ["app": "Slack"]), .success(.hideApp("Slack")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_list_apps", params: nil), .success(.listApps(installed: false)))
        XCTAssertEqual(PetCommands.parse(capability: "combo_list_apps", params: ["installed": true]), .success(.listApps(installed: true)))
        // Declared only with the server's approval card; then it parses.
        XCTAssertEqual(PetCommands.parse(capability: "combo_quit_app", params: ["app": "Notes"], allowQuit: true), .success(.quitApp("Notes")))
    }

    func testParsesLayoutSystemGadgetsAndWorkspaces() {
        XCTAssertEqual(PetCommands.parse(capability: "combo_layout_windows", params: ["items": [
            ["app": "Safari", "position": "left"],
            ["app": "Notes", "position": "right", "display": 2],
            ["app": "Safari", "position": "maximize", "window": 2, "display": NSNull()],
        ]]), .success(.layoutWindows([
            PetWindowPlacement(app: "Safari", position: .left),
            PetWindowPlacement(app: "Notes", position: .right, display: 2),
            PetWindowPlacement(app: "Safari", position: .maximize, window: 2),
        ])))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_system", params: ["volume": 0, "dnd": true]),
                       .success(.setSystem(PetSystemChange(volume: 0, doNotDisturb: true))))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_system", params: ["brightness": 100.0]),
                       .success(.setSystem(PetSystemChange(brightness: 100))))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_dim_strength", params: ["percent": 70]), .success(.setDimStrength(70)))
        XCTAssertEqual(PetCommands.parse(capability: "combo_clear_shelf", params: [:]), .success(.clearShelf))
        XCTAssertEqual(PetCommands.parse(capability: "combo_workspace_save", params: ["name": " 업무 모드 "]), .success(.saveWorkspace("업무 모드")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_workspace_apply", params: ["name": "업무 모드"]), .success(.applyWorkspace("업무 모드")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_workspace_list", params: nil), .success(.listWorkspaces))
        XCTAssertEqual(PetCommands.parse(capability: "combo_list_windows", params: NSNull()), .success(.listWindows))
    }

    func testOldCapabilitiesStayLenient() {
        // The first three capabilities shipped without strict field checks; servers may still send extra fields.
        XCTAssertEqual(PetCommands.parse(capability: "combo_arrange_window", params: ["position": "left", "note": "x"]),
                       .success(.arrangeWindow(.left, app: nil)))
        XCTAssertEqual(PetCommands.parse(capability: "combo_list_gadgets", params: ["verbose": true]), .success(.listGadgets))
    }

    func testQuitIsDeclaredWithApprovalOnlyWhenSwitchedOn() {
        XCTAssertFalse(PetCommands.declaresQuitApp)
        XCTAssertFalse(PetCommands.names.contains(PetCommands.quitApp))
        let on = PetCommands.capabilities(allowQuit: true)
        let quit = on.first { $0["name"] as? String == PetCommands.quitApp }
        XCTAssertEqual(quit?["approval"] as? String, "required")
        XCTAssertEqual(on.filter { $0["approval"] != nil }.count, 1)
        for c in on { XCTAssertLessThanOrEqual((c["description"] as! String).count, 200) }
        XCTAssertEqual(on.count, PetCommands.allNames.count)
        XCTAssertEqual(PetCommands.allNames.count, Set(PetCommands.allNames).count)
        for name in PetCommands.allNames { XCTAssertNotNil(PetCommands.spec(name), name) }
    }

    func testHelloFrameCarriesTheCapabilities() {
        let hello = ConnectorFrames.hello(token: "nct_abc")
        let o = try! JSONSerialization.jsonObject(with: Data(hello.utf8)) as! [String: Any]
        let names = (o["capabilities"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertEqual(names, PetCommands.names)
        XCTAssertFalse(hello.contains("combo_quit_app"))
        XCTAssertFalse(hello.contains("\"approval\""))
    }

    func testOutcomeDetailsGoIntoTheResultButNeverOverrideOkOrMessage() {
        let o = PetCommandOutcome(ok: false, message: "m", details: ["apps": [["name": "Safari"]], "ok": true, "message": "x"])
        let json = o.resultJSON
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["message"] as? String, "m")
        XCTAssertEqual((json["apps"] as? [[String: String]])?.first?["name"], "Safari")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
        XCTAssertEqual(o, PetCommandOutcome(ok: false, message: "m", details: ["apps": [["name": "Safari"]], "ok": true, "message": "x"]))
        XCTAssertNotEqual(o, PetCommandOutcome(ok: false, message: "m"))
    }
}

final class PetAppMatcherTests: XCTestCase {
    private let apps = [
        PetAppEntry(bundleID: "com.apple.calculator", names: ["계산기", "Calculator"], running: false),
        PetAppEntry(bundleID: "com.apple.Safari", names: ["Safari"], running: true),
        PetAppEntry(bundleID: "com.google.Chrome", names: ["Google Chrome"], running: false),
        PetAppEntry(bundleID: "com.google.Chrome.canary", names: ["Google Chrome Canary"], running: false),
        PetAppEntry(bundleID: "com.microsoft.Word", names: ["Microsoft Word"], running: false),
        PetAppEntry(bundleID: "com.microsoft.Excel", names: ["Microsoft Excel"], running: false),
        PetAppEntry(bundleID: "com.apple.Notes", names: ["메모", "Notes"], running: true),
        // The same app found twice (running + in /Applications) is one app.
        PetAppEntry(bundleID: "com.apple.notes", names: ["Notes"], running: false),
    ]

    private func found(_ q: String) -> String? {
        if case let .found(e) = PetAppMatcher.match(q, in: apps) { return e.bundleID }
        return nil
    }

    func testMatchesKoreanEnglishAndBundleNames() {
        XCTAssertEqual(found("계산기"), "com.apple.calculator")
        XCTAssertEqual(found("calculator"), "com.apple.calculator")
        XCTAssertEqual(found("Calculator.app"), "com.apple.calculator")
        XCTAssertEqual(found(" SAFARI "), "com.apple.Safari")
        XCTAssertEqual(found("com.apple.safari"), "com.apple.Safari")
        XCTAssertEqual(found("메모"), "com.apple.Notes")
        XCTAssertEqual(found("google chrome"), "com.google.Chrome")   // exact beats the Canary partial match
        XCTAssertEqual(found("googlechrome"), "com.google.Chrome")
        XCTAssertEqual(found("word"), "com.microsoft.Word")             // single partial match
    }

    func testAmbiguousAndUnknownNames() {
        guard case let .ambiguous(list) = PetAppMatcher.match("Microsoft", in: apps) else { return XCTFail("not ambiguous") }
        XCTAssertEqual(Set(list.map { $0.bundleID }), ["com.microsoft.Word", "com.microsoft.Excel"])
        guard case .ambiguous = PetAppMatcher.match("chrome", in: apps) else { return XCTFail("chrome must be ambiguous") }
        XCTAssertEqual(PetAppMatcher.match("Photoshop", in: apps), .none(suggestions: []))
        XCTAssertEqual(PetAppMatcher.match("", in: apps), .none(suggestions: []))
        XCTAssertEqual(PetAppMatcher.match("a", in: apps), .none(suggestions: []))   // one letter never partially matches
        guard case let .none(suggestions) = PetAppMatcher.match("Microsoft Paint", in: apps) else { return XCTFail() }
        XCTAssertEqual(Set(suggestions), ["Microsoft Word", "Microsoft Excel"])
    }

    func testDuplicatesMergeAndRunningWins() {
        let merged = PetAppMatcher.dedupe(apps)
        XCTAssertEqual(merged.filter { $0.bundleID.lowercased() == "com.apple.notes" }.count, 1)
        XCTAssertEqual(merged.first { $0.bundleID == "com.apple.Notes" }?.running, true)
        let twoNotes = [PetAppEntry(bundleID: "a.notes", names: ["Notes"], running: false),
                        PetAppEntry(bundleID: "b.notes", names: ["Notes"], running: true)]
        XCTAssertEqual(PetAppMatcher.match("notes", in: twoNotes), .found(twoNotes[1]))
    }

    func testProtectedApps() {
        XCTAssertTrue(PetAppMatcher.isProtected("com.apple.finder"))
        XCTAssertTrue(PetAppMatcher.isProtected("com.mafianacho.nachocombo"))
        XCTAssertFalse(PetAppMatcher.isProtected("com.apple.Safari"))
    }
}

final class PetDisplaysTests: XCTestCase {
    func testNumbersDisplaysLeftToRight() {
        // Primary first in NSScreen order, an external display on the left.
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                       CGRect(x: 1512, y: 0, width: 1080, height: 1920)]
        XCTAssertEqual(PetDisplays.index(forNumber: 1, screens: screens), 1)
        XCTAssertEqual(PetDisplays.index(forNumber: 2, screens: screens), 0)
        XCTAssertEqual(PetDisplays.index(forNumber: 3, screens: screens), 2)
        XCTAssertNil(PetDisplays.index(forNumber: 4, screens: screens))
        XCTAssertNil(PetDisplays.index(forNumber: 0, screens: screens))
        XCTAssertEqual(PetDisplays.number(forIndex: 0, screens: screens), 2)
    }
}

final class DesktopWorkspaceTests: XCTestCase {
    private func sample(_ name: String = "업무 모드") -> DesktopWorkspace {
        DesktopWorkspace(name: name, savedAt: Date(timeIntervalSince1970: 1_800_000_000), displays: "1512x982+0+0",
                         apps: [.init(bundleID: "com.apple.Safari", name: "Safari"), .init(bundleID: "com.apple.Notes", name: "메모")],
                         windows: [SavedWindow(bundleID: "com.apple.Safari", appName: "Safari",
                                               frame: CGRect(x: 0, y: 0, width: 756, height: 957), order: 0),
                                   SavedWindow(bundleID: "com.apple.Notes", appName: "메모",
                                               frame: CGRect(x: 756, y: 0, width: 756, height: 957), order: 0)],
                         gadgets: ["focusDim": true, "keepAwake": false])
    }

    func testRoundTripThroughTheFile() throws {
        var store = DesktopWorkspaceStore()
        XCTAssertEqual(store.save(sample()), .added)
        let data = try store.encoded()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"version\" : 1"))
        XCTAssertTrue(text.contains("2027-01-15T08:00:00Z"))
        XCTAssertEqual(DesktopWorkspaceStore.decode(data), store)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)/workspaces.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try store.write(to: url)
        XCTAssertEqual(DesktopWorkspaceStore.load(from: url), store)
    }

    func testReadsOlderAndNewerFilesLeniently() {
        let json = #"""
        {"version": 2, "future": {"x": 1}, "workspaces": [
          {"name": "집중", "savedAt": "2026-11-13T00:00:00Z", "apps": [{"bundleID": "com.apple.Notes", "name": "메모"}],
           "colorTheme": "dark"},
          {"name": 42},
          {"name": "빈 공간"}
        ]}
        """#
        let store = DesktopWorkspaceStore.decode(Data(json.utf8))
        XCTAssertEqual(store?.workspaces.map { $0.name }, ["집중", "빈 공간"])
        XCTAssertEqual(store?.workspaces.first?.apps.count, 1)
        XCTAssertEqual(store?.workspaces.first?.windows, [])
        XCTAssertEqual(store?.workspaces.last?.gadgets, [:])
        XCTAssertNil(DesktopWorkspaceStore.decode(Data("not json".utf8)))
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString).json")
        XCTAssertEqual(DesktopWorkspaceStore.load(from: missing), DesktopWorkspaceStore())
    }

    func testNamesReplaceRemoveAndLimit() {
        var store = DesktopWorkspaceStore()
        XCTAssertEqual(store.save(sample("업무 모드")), .added)
        XCTAssertEqual(store.save(sample("업무모드")), .replaced)   // same name without the space
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces.first?.name, "업무모드")
        XCTAssertNotNil(store.workspace(named: "업무 모드"))
        for i in 1..<DesktopWorkspaceStore.maxWorkspaces { XCTAssertEqual(store.save(sample("ws \(i)")), .added) }
        XCTAssertEqual(store.save(sample("one too many")), .full)
        XCTAssertEqual(store.workspaces.count, DesktopWorkspaceStore.maxWorkspaces)
        XCTAssertEqual(store.save(sample("WS 3")), .replaced)       // replacing still works when full
        XCTAssertEqual(store.workspaces.first?.name, "WS 3")
        XCTAssertTrue(store.remove(named: "ws3"))
        XCTAssertFalse(store.remove(named: "ws3"))
        XCTAssertEqual(DesktopWorkspaceStore.validName("  집중 "), .success("집중"))
        XCTAssertEqual(DesktopWorkspaceStore.validName(" "), .failure(.empty))
        XCTAssertEqual(DesktopWorkspaceStore.validName(String(repeating: "가", count: 41)), .failure(.tooLong))
        XCTAssertEqual(DesktopWorkspaceStore.validName("a\u{7}b"), .failure(.badCharacters))
        XCTAssertEqual(DesktopWorkspaceStore.validName("a\u{2028}b"), .failure(.badCharacters))
    }

    func testOnlySwitchableGadgetsAreApplied() {
        var w = sample()
        w.gadgets = ["focusDim": true, "computerUse": true, "nachoPet": false, "removedGadget": true, "keepAwake": false]
        XCTAssertEqual(w.gadgetSwitches.map { "\($0.0.rawValue)=\($0.1)" }, ["focusDim=true", "keepAwake=false"])
        XCTAssertEqual(w.koreanSummary, "앱 2개 · 창 2개 · 가젯 3개 켜짐")
    }

    func testApplyReport() {
        var r = WorkspaceApplyReport(name: "업무 모드")
        r.openedApps = ["메모"]
        r.placedWindows = 2
        r.savedWindows = 2
        r.gadgetsChanged = ["Focus Dim on"]
        XCTAssertTrue(r.ok)
        XCTAssertTrue(r.outcome.message.contains("opened 메모 (apps already open were left running)"))
        r.windowsNeedPermission = true
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.outcome.message.contains("Accessibility"))
        XCTAssertTrue(r.outcome.message.contains("손쉬운 사용"))
        let parts = [PetPartResult(name: "volume", ok: true, message: "set to 40%"),
                     PetPartResult(name: "dnd", ok: false, message: "macOS does not let apps switch Focus")]
        let o = PetPartResult.summary(parts)
        XCTAssertFalse(o.ok)
        XCTAssertEqual((o.resultJSON["results"] as? [[String: Any]])?.count, 2)
    }
}
