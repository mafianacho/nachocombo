import XCTest
@testable import NachoComboCore

/// NACHO-38: the desktop tools of the registry (contract, approval, exits) and their runner on a temporary desktop.
final class DesktopToolsTests: XCTestCase {
    private final class FakeHost: DesktopTidyHost {
        var apps: [String]? = ["Safari", "Notes", "Terminal", "Mail"]
        var arranged: [(apps: [String], arrangement: String)] = []
        func windowApps(done: @escaping ([String]?) -> Void) { done(apps) }
        func arrange(apps: [String], arrangement: String, done: @escaping (PetCommandOutcome) -> Void) {
            arranged.append((apps, arrangement))
            done(PetCommandOutcome(ok: true, message: "Arranged", details: ["windows": [["window": "Safari #1"]]]))
        }
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let fm = FileManager.default
    private var root: URL!
    private var desktop: URL!
    private var clock: Clock!
    private var host: FakeHost!
    private var runner: DesktopToolRunner!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("desktop-tools-\(UUID().uuidString)", isDirectory: true)
        desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        clock = Clock()
        host = FakeHost()
        let engine = DesktopTidyEngine(desktop: desktop, journalURL: root.appendingPathComponent("journal.json"), now: { [clock] in clock!.date })
        runner = DesktopToolRunner(engine: engine, host: host, now: { [clock] in clock!.date })
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func tool(_ action: String) -> GadgetTool { DesktopTools.tools.first { $0.action == action }! }

    private func call(_ action: String, _ args: [String: JSONValue] = [:]) -> PetCommandOutcome {
        var out: PetCommandOutcome?
        let done = expectation(description: action)
        runner.run(tool(action), arguments: args) { out = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return out!
    }

    private func make(_ name: String, _ text: String = "x") throws {
        let url = desktop.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: clock.date.addingTimeInterval(-3600)], ofItemAtPath: url.path)
    }

    private func planID(_ o: PetCommandOutcome) -> JSONValue { .string(o.details?["plan_id"] as? String ?? "missing") }

    // MARK: contract

    func testRegistryKeepsTheContractWithTheDesktopTools() {
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
        XCTAssertEqual(DesktopTools.tools.map { $0.connectorName }, [
            "combo_desktop_tidy_plan", "combo_desktop_tidy_apply", "combo_desktop_tidy_undo",
            "combo_desktop_tidy_history", "combo_desktop_arrange_suggest", "combo_desktop_arrange_apply"])
        XCTAssertEqual(DesktopTools.tools.map { $0.mcpName }.first, "desktop_tidy_plan")
        for t in DesktopTools.tools {
            for word in GadgetToolRegistry.forbiddenConnectorWords { XCTAssertFalse(t.connectorName.contains(word), "\(t.connectorName) has \(word)") }
        }
        XCTAssertNotNil(GadgetToolRegistry.guide(for: .desktop))
        XCTAssertTrue(GadgetToolRegistry.prompts.contains { $0.name == "desktop_tidy_preview" })
    }

    func testRisksAndExits() {
        let table: [(String, GadgetToolRisk, Set<GadgetToolExit>, Bool)] = [
            ("tidy_plan", .read, [.mcp, .connector], false), ("tidy_apply", .change, [.connector], true),
            ("tidy_undo", .change, [.connector], false), ("tidy_history", .read, [.mcp, .connector], false),
            ("arrange_suggest", .read, [.mcp, .connector], false), ("arrange_apply", .change, [.connector], true),
        ]
        for (action, risk, exits, always) in table {
            let t = tool(action)
            XCTAssertEqual(t.risk, risk, action)
            XCTAssertEqual(t.exits, exits, action)
            XCTAssertEqual(t.alwaysRequiresApproval, always, action)
            XCTAssertEqual(t.connectorApproval(alwaysAllowed: false), always, action)
            XCTAssertEqual(t.connectorApproval(alwaysAllowed: true), always, "always allow does not lift it: \(action)")
            XCTAssertTrue(t.requiresGadgetOn, action)
        }
    }

    func testApplyAndUndoAreNotOnTheMCPExit() {
        let mcp = GadgetToolRegistry.tools(on: .mcp).map { $0.mcpName }
        for name in ["desktop_tidy_apply", "desktop_tidy_undo", "desktop_arrange_apply"] {
            XCTAssertFalse(mcp.contains(name), name)
            XCTAssertNil(GadgetToolRegistry.mcpTool(named: name), name)
        }
        for name in ["desktop_tidy_plan", "desktop_tidy_history", "desktop_arrange_suggest"] { XCTAssertTrue(mcp.contains(name), name) }
    }

    func testTheConnectorDeclaresApprovalRequiredForApplyEvenWhenTheGadgetIsAlwaysAllowed() {
        for allowed: Set<GadgetID> in [[], [.desktop]] {
            let caps = PetCommands.capabilities(allowQuit: true, alwaysAllowed: allowed, disabled: [])
            func approval(_ name: String) -> String? { caps.first { $0["name"] as? String == name }?["approval"] as? String }
            XCTAssertEqual(approval("combo_desktop_tidy_apply"), "required")
            XCTAssertEqual(approval("combo_desktop_arrange_apply"), "required")
            XCTAssertNil(approval("combo_desktop_tidy_plan"))
            XCTAssertNil(approval("combo_desktop_tidy_undo"))
            XCTAssertNil(approval("combo_desktop_tidy_history"))
            XCTAssertNil(approval("combo_desktop_arrange_suggest"))
        }
        XCTAssertTrue(PetCommands.approvalRequired.contains("combo_desktop_tidy_apply"))
        XCTAssertFalse(GadgetToolRegistry.trustableGadgets().contains(.desktop), "nothing to always allow")
    }

    func testExistingToolsKeepTheirApprovalDeclaration() {
        for t in GadgetToolRegistry.all where t.gadget != .desktop {
            XCTAssertFalse(t.alwaysRequiresApproval, t.mcpName)
            for allowed in [false, true] {
                let byRisk: Bool
                switch t.risk {
                case .read, .change: byRisk = false
                case .contentOut, .inputInject: byRisk = !allowed
                case .destructive: byRisk = true
                }
                XCTAssertEqual(t.connectorApproval(alwaysAllowed: allowed), byRisk, "\(t.mcpName) allowed=\(allowed)")
            }
        }
        let plain = GadgetTool(gadget: .window, action: "x", korean: "", english: "", output: "", risk: .change)
        XCTAssertFalse(plain.alwaysRequiresApproval)
        XCTAssertFalse(plain.connectorApproval(alwaysAllowed: false))
    }

    func testGuideListsToolsPerExit() {
        let guide = GadgetToolRegistry.guide(for: .desktop)!
        let mcp = guide.render(for: .mcp)
        let connector = guide.render(for: .connector)
        XCTAssertTrue(mcp.contains("desktop_tidy_plan"))
        XCTAssertFalse(mcp.contains("`desktop_tidy_apply`"))
        XCTAssertTrue(connector.contains("combo_desktop_tidy_apply"))
        XCTAssertTrue(connector.contains("정리됨"))
    }

    // MARK: tidy tools

    func testPlanThenApplyThenHistoryThenUndo() throws {
        try make("스크린샷 1.png")
        try make("보고서.pdf")
        try make("a.zip")
        let plan = call("tidy_plan")
        XCTAssertTrue(plan.ok)
        XCTAssertEqual(plan.details?["total"] as? Int, 3)
        XCTAssertEqual(plan.details?["expires_in_seconds"] as? Int, 600)
        let categories = (plan.details?["categories"] as? [[String: Any]])?.map { "\($0["category"] as? String ?? ""):\($0["count"] as? Int ?? 0)" }
        XCTAssertEqual(categories, ["screenshot:1", "document:1", "archive:1"])
        XCTAssertEqual((plan.details?["files"] as? [[String: String]])?.count, 3)
        XCTAssertEqual(plan.details?["more"] as? Int, 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(plan.resultJSON))
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("보고서.pdf").path), "planning moves nothing")

        let apply = call("tidy_apply", ["plan_id": planID(plan)])
        XCTAssertTrue(apply.ok, apply.message)
        XCTAssertEqual(apply.details?["moved"] as? Int, 3)
        let tidyID = try XCTUnwrap(apply.details?["tidy_id"] as? String)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(apply.resultJSON))
        XCTAssertFalse(fm.fileExists(atPath: desktop.appendingPathComponent("보고서.pdf").path))

        let history = call("tidy_history")
        let entries = try XCTUnwrap(history.details?["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.first?["tidy_id"] as? String, tidyID)
        XCTAssertEqual(entries.first?["count"] as? Int, 3)
        XCTAssertEqual(entries.first?["undone"] as? Bool, false)
        XCTAssertNil(entries.first?["moves"], "history has no file names")

        let undo = call("tidy_undo")
        XCTAssertTrue(undo.ok)
        XCTAssertEqual(undo.details?["restored"] as? Int, 3)
        XCTAssertEqual(undo.details?["complete"] as? Bool, true)
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("보고서.pdf").path))
        XCTAssertEqual((call("tidy_history").details?["entries"] as? [[String: Any]])?.first?["undone"] as? Bool, true)
    }

    func testPlanListsFiftyNamesAndCountsTheRest() throws {
        for i in 0..<57 { try make(String(format: "f%02d.txt", i)) }
        let plan = call("tidy_plan")
        XCTAssertEqual(plan.details?["total"] as? Int, 57)
        XCTAssertEqual((plan.details?["files"] as? [[String: String]])?.count, 50)
        XCTAssertEqual(plan.details?["more"] as? Int, 7)
    }

    func testAnEmptyDesktopGivesNoPlanID() {
        let plan = call("tidy_plan")
        XCTAssertTrue(plan.ok)
        XCTAssertEqual(plan.details?["total"] as? Int, 0)
        XCTAssertNil(plan.details?["plan_id"])
    }

    func testStaleAndUnknownPlansAreRefusedWithAReason() throws {
        try make("a.pdf")
        let plan = call("tidy_plan")
        clock.date = clock.date.addingTimeInterval(601)
        let stale = call("tidy_apply", ["plan_id": planID(plan)])
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.details?["reason"] as? String, "plan_stale")
        XCTAssertNotNil(stale.details?["hint"])
        XCTAssertNotNil(stale.details?["guide_ko"])
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("a.pdf").path))
        XCTAssertEqual(call("tidy_apply", ["plan_id": .string("zzzz")]).details?["reason"] as? String, "plan_not_found")
        XCTAssertEqual(call("tidy_undo").details?["reason"] as? String, "nothing_to_undo")
        XCTAssertEqual(call("tidy_undo", ["tidy_id": .string("nope")]).details?["reason"] as? String, "tidy_not_found")
    }

    func testUndoReportsWhatItCouldNotRestoreInKorean() throws {
        try make("a.pdf", "moved")
        let apply = call("tidy_apply", ["plan_id": planID(call("tidy_plan"))])
        XCTAssertTrue(apply.ok)
        try make("a.pdf", "new")
        let undo = call("tidy_undo")
        XCTAssertTrue(undo.ok)
        XCTAssertEqual(undo.details?["restored"] as? Int, 0)
        let rows = try XCTUnwrap(undo.details?["not_restored"] as? [[String: String]])
        XCTAssertEqual(rows.first?["reason"], "conflict")
        XCTAssertTrue(rows.first?["label_ko"]?.hasPrefix("되돌리지 못함") == true)
        XCTAssertEqual(try String(contentsOf: desktop.appendingPathComponent("a.pdf")), "new")
    }

    func testBadArgumentsAreRefused() {
        XCTAssertFalse(call("tidy_apply").ok)
        XCTAssertTrue(call("tidy_apply").message.contains("plan_id is required"))
        XCTAssertFalse(call("tidy_apply", ["plan_id": .int(5)]).ok)
        XCTAssertFalse(call("tidy_apply", ["plan_id": .string("")]).ok)
        XCTAssertFalse(call("tidy_apply", ["plan_id": .string(String(repeating: "a", count: 33))]).ok)
        XCTAssertFalse(call("tidy_apply", ["plan_id": .string("a"), "path": .string("/")]).ok)
        XCTAssertFalse(call("tidy_plan", ["path": .string("/")]).ok, "no folder argument: only the desktop")
        XCTAssertFalse(call("tidy_undo", ["plan_id": .string("a")]).ok)
        XCTAssertFalse(call("tidy_history", ["days": .int(5)]).ok)
        XCTAssertFalse(call("arrange_apply").ok)
    }

    func testAnUnreadableDesktopTellsHowToAllowIt() throws {
        try fm.removeItem(at: desktop)
        let out = call("tidy_plan")
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.details?["reason"] as? String, "desktop_unreadable")
        XCTAssertTrue((out.details?["guide_ko"] as? String)?.contains("파일 및 폴더") == true)
    }

    // MARK: arrange

    func testSuggestThenApplyUsesTheWindowToolArguments() {
        let suggest = call("arrange_suggest")
        XCTAssertTrue(suggest.ok)
        XCTAssertEqual(suggest.details?["arrangement"] as? String, "quadrants")
        XCTAssertEqual(suggest.details?["apps"] as? [String], ["Safari", "Notes", "Terminal", "Mail"])
        let args = suggest.details?["window_arguments"] as? [String: Any]
        XCTAssertEqual(args?["arrangement"] as? String, "quadrants")
        XCTAssertTrue(host.arranged.isEmpty, "a suggestion moves nothing")

        let applied = call("arrange_apply", ["plan_id": planID(suggest)])
        XCTAssertTrue(applied.ok)
        XCTAssertEqual(host.arranged.count, 1)
        XCTAssertEqual(host.arranged.first?.apps, ["Safari", "Notes", "Terminal", "Mail"])
        XCTAssertEqual(host.arranged.first?.arrangement, "quadrants")
        XCTAssertEqual(applied.details?["undo_with"] as? String, "window_undo")
        XCTAssertEqual(call("arrange_apply", ["plan_id": planID(suggest)]).details?["reason"] as? String, "plan_not_found", "runs once")
    }

    func testArrangementFollowsTheAppCount() {
        XCTAssertEqual(DesktopToolRunner.arrangement(forCount: 2), "columns")
        XCTAssertEqual(DesktopToolRunner.arrangement(forCount: 3), "columns")
        XCTAssertEqual(DesktopToolRunner.arrangement(forCount: 4), "quadrants")
        XCTAssertEqual(DesktopToolRunner.arrangement(forCount: 5), "grid")
        host.apps = (1...15).map { "App \($0)" } + ["App 1", ""]
        let suggest = call("arrange_suggest")
        XCTAssertEqual((suggest.details?["apps"] as? [String])?.count, DesktopToolRunner.maxArrangeApps)
        XCTAssertEqual(suggest.details?["arrangement"] as? String, "grid")
    }

    func testSuggestNeedsTwoAppsAndAccessibility() {
        host.apps = ["Safari"]
        let one = call("arrange_suggest")
        XCTAssertTrue(one.ok)
        XCTAssertNil(one.details?["plan_id"])
        host.apps = nil
        let denied = call("arrange_suggest")
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.details?["reason"] as? String, "permission_needed")
    }

    func testAnArrangementPlanExpires() {
        let suggest = call("arrange_suggest")
        clock.date = clock.date.addingTimeInterval(601)
        let late = call("arrange_apply", ["plan_id": planID(suggest)])
        XCTAssertEqual(late.details?["reason"] as? String, "plan_stale")
        XCTAssertTrue(host.arranged.isEmpty)
    }

    func testTheSuggestionNeverCarriesWindowTitles() {
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: call("arrange_suggest").resultJSON)) ?? Data(), as: UTF8.self)
        XCTAssertFalse(json.contains("title"))
    }
}
