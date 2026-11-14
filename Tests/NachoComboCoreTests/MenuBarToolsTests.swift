import XCTest
@testable import NachoComboCore

/// Fake organizer: records calls, answers synchronously.
private final class FakeMenuBar: MenuBarControlling {
    var current: MenuBarState
    var reading: MenuBarReading = .permissionNeeded
    private(set) var calls: [String] = []
    init(_ s: MenuBarState) { current = s }
    func state(done: @escaping (MenuBarState) -> Void) { calls.append("state"); done(current) }
    func setCollapsed(_ collapsed: Bool, done: @escaping (MenuBarState) -> Void) {
        calls.append("setCollapsed(\(collapsed))"); current.collapsed = collapsed
        if collapsed { current.showingAlwaysHidden = false }
        done(current)
    }
    func tidy(done: @escaping (MenuBarState) -> Void) { calls.append("tidy"); current.collapsed = true; current.showingAlwaysHidden = false; done(current) }
    func showHidden(done: @escaping (MenuBarState) -> Void) {
        calls.append("showHidden"); current.collapsed = false; current.showingAlwaysHidden = current.hasAlwaysHiddenSection; done(current)
    }
    func readItems(done: @escaping (MenuBarReading) -> Void) { calls.append("readItems"); done(reading) }
}

private func tool(_ action: String) -> GadgetTool { MenuBarTools.tools.first { $0.action == action }! }

private func runTool(_ fake: FakeMenuBar, _ action: String, _ args: [String: JSONValue] = [:]) -> PetCommandOutcome {
    var result: PetCommandOutcome?
    var count = 0
    MenuBarToolRunner(controller: fake).run(tool(action), arguments: args) { result = $0; count += 1 }
    XCTAssertEqual(count, 1, "done must be called exactly once")
    return result!
}

final class MenuBarToolsTests: XCTestCase {
    func testRegistryHasTheFiveTools() {
        XCTAssertEqual(MenuBarTools.tools.map { $0.mcpName },
                       ["menubar_status", "menubar_list_items", "menubar_tidy", "menubar_set_collapsed", "menubar_show_hidden"])
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
        XCTAssertEqual(tool("list_items").permissions, [.accessibility])
        XCTAssertEqual(tool("list_items").risk, .read)
        XCTAssertEqual(tool("tidy").risk, .change)
        XCTAssertTrue(GadgetToolRegistry.all.contains { $0.connectorName == "combo_menubar_list_items" })
        XCTAssertEqual(GadgetToolRegistry.guide(for: .menubar)?.gadget, .menubar)
        XCTAssertEqual(MenuBarTools.prompts.map { $0.name }, ["menubar_organize"])
    }

    func testGuideRendersForBothExits() {
        let mcp = GadgetToolRegistry.guide(for: .menubar)!.render(for: .mcp)
        XCTAssertTrue(mcp.contains("menubar_tidy"))
        XCTAssertTrue(mcp.contains("⌘"))
        let nacho = GadgetToolRegistry.guide(for: .menubar)!.render(for: .connector)
        XCTAssertTrue(nacho.contains("combo_menubar_list_items"))
    }

    // MARK: state and commands

    func testStatusReadsCollapsedAndAutoCollapse() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: true, hasAlwaysHiddenSection: true, autoCollapseSeconds: 15))
        let out = runTool(fake, "status")
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.details?["collapsed"] as? Bool, true)
        XCTAssertEqual(out.details?["auto_collapse_seconds"] as? Int, 15)
        XCTAssertEqual(out.details?["always_hidden_section"] as? Bool, true)
        XCTAssertEqual(fake.calls, ["state"])
    }

    func testStatusWhenGadgetNotRunningIsGadgetOff() {
        let out = runTool(FakeMenuBar(MenuBarState(running: false, collapsed: false)), "status")
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.details?["reason"] as? String, "gadget_off")
    }

    func testSetCollapsedFoldsAndUnfolds() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false))
        let fold = runTool(fake, "set_collapsed", ["collapsed": .bool(true)])
        XCTAssertTrue(fold.ok)
        XCTAssertEqual(fold.details?["collapsed"] as? Bool, true)
        XCTAssertEqual(fold.details?["changed"] as? Bool, true)
        let again = runTool(fake, "set_collapsed", ["collapsed": .bool(true)])
        XCTAssertEqual(again.details?["changed"] as? Bool, false)
        let open = runTool(fake, "set_collapsed", ["collapsed": .bool(false)])
        XCTAssertEqual(open.details?["collapsed"] as? Bool, false)
        XCTAssertEqual(fake.calls.filter { $0.hasPrefix("setCollapsed") }, ["setCollapsed(true)", "setCollapsed(true)", "setCollapsed(false)"])
    }

    func testSetCollapsedRejectsBadArguments() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false))
        XCTAssertFalse(runTool(fake, "set_collapsed").ok)
        XCTAssertFalse(runTool(fake, "set_collapsed", ["collapsed": .string("yes")]).ok)
        XCTAssertFalse(runTool(fake, "set_collapsed", ["collapsed": .bool(true), "app": .string("x")]).ok)
        XCTAssertFalse(runTool(fake, "tidy", ["force": .bool(true)]).ok)
        XCTAssertEqual(fake.calls, [], "invalid calls never reach the organizer")
    }

    func testTidyFoldsAndClearsAlwaysHiddenView() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false, showingAlwaysHidden: true, hasAlwaysHiddenSection: true))
        let out = runTool(fake, "tidy")
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.details?["collapsed"] as? Bool, true)
        XCTAssertEqual(out.details?["showing_always_hidden"] as? Bool, false)
        XCTAssertEqual(out.details?["changed"] as? Bool, true)
    }

    func testTidyReportsDividerFailure() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false))
        final class Failing: MenuBarControlling {
            var s = MenuBarState(running: true, collapsed: false)
            func state(done: @escaping (MenuBarState) -> Void) { done(s) }
            func setCollapsed(_ c: Bool, done: @escaping (MenuBarState) -> Void) { done(s) }
            func tidy(done: @escaping (MenuBarState) -> Void) { s.dividerFailed = true; done(s) }
            func showHidden(done: @escaping (MenuBarState) -> Void) { done(s) }
            func readItems(done: @escaping (MenuBarReading) -> Void) { done(.permissionNeeded) }
        }
        _ = fake
        let failing = Failing()
        var result: PetCommandOutcome?
        MenuBarToolRunner(controller: failing).run(tool("tidy"), arguments: [:]) { result = $0 }
        XCTAssertEqual(result?.ok, false)
        XCTAssertEqual(result?.details?["reason"] as? String, "divider_failed")
    }

    func testShowHiddenExpandsEverything() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: true, hasAlwaysHiddenSection: true))
        let out = runTool(fake, "show_hidden")
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.details?["showing_always_hidden"] as? Bool, true)
        XCTAssertEqual(out.details?["collapsed"] as? Bool, false)
    }

    func testChangeToolsRefuseWhileGadgetOff() {
        for action in ["tidy", "show_hidden"] {
            let out = runTool(FakeMenuBar(MenuBarState(running: false, collapsed: false)), action)
            XCTAssertEqual(out.details?["reason"] as? String, "gadget_off", action)
        }
    }

    // MARK: Accessibility items → serialization → zones

    private let dividers = MenuBarDividers(divider: 1000, alwaysDivider: 400)

    func testZonesFollowTheDividers() {
        XCTAssertEqual(dividers.zone(centerX: 100), .alwaysHidden)
        XCTAssertEqual(dividers.zone(centerX: 700), .hidden)
        XCTAssertEqual(dividers.zone(centerX: 1200), .visible)
        XCTAssertEqual(MenuBarDividers(divider: 1000).zone(centerX: 100), .hidden)
        XCTAssertEqual(MenuBarDividers(divider: nil).zone(centerX: 100), .visible)
    }

    func testItemsSerializeLeftToRightWithZones() {
        let items = [
            MenuBarItem(app: "Clock", title: "10:42", x: 1300, y: 0, width: 50, height: 24),
            MenuBarItem(app: "Dropbox", title: "Dropbox", x: 700, y: 0, width: 30, height: 24),
            MenuBarItem(app: "Slack", title: "Slack\nunread", x: 100, y: 0, width: 30, height: 24),
        ]
        let out = MenuBarToolRunner.itemsOutcome(items, dividers: dividers)
        let list = out.details?["items"] as? [[String: Any]]
        XCTAssertEqual(list?.map { $0["app"] as? String }, ["Slack", "Dropbox", "Clock"])
        XCTAssertEqual(list?.map { $0["zone"] as? String }, ["always_hidden", "hidden", "visible"])
        XCTAssertEqual(list?.first?["title"] as? String, "Slack unread")
        XCTAssertEqual(out.details?["zones"] as? [String: Int], ["visible": 1, "hidden": 1, "always_hidden": 1])
        XCTAssertEqual(out.details?["count"] as? Int, 3)
    }

    func testOffscreenItemsAreMarked() {
        let item = MenuBarItem(app: "Hidden", title: "", x: -5000, y: 0, width: 30, height: 24)
        let list = MenuBarSerializer.serialize([item], dividers: MenuBarDividers(divider: 1000))
        XCTAssertEqual(list.first?["on_screen"] as? Bool, false)
        XCTAssertEqual(list.first?["zone"] as? String, "hidden")
    }

    func testLongTitlesAndHugeListsAreCapped() {
        let long = MenuBarItem(app: "A", title: String(repeating: "x", count: 500), x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual((MenuBarSerializer.serialize([long], dividers: dividers).first?["title"] as? String)?.count, MenuBarSerializer.maxTextLength)
        let many = (0..<200).map { MenuBarItem(app: "A\($0)", title: "", x: Double($0), y: 0, width: 1, height: 1) }
        let out = MenuBarToolRunner.itemsOutcome(many, dividers: dividers)
        XCTAssertEqual((out.details?["items"] as? [[String: Any]])?.count, MenuBarSerializer.maxItems)
        XCTAssertEqual(out.details?["truncated"] as? Bool, true)
        XCTAssertEqual(out.details?["count"] as? Int, 200)
    }

    func testListItemsWithoutAccessibilityIsPermissionNeeded() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false))
        fake.reading = .permissionNeeded
        let out = runTool(fake, "list_items")
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.details?["reason"] as? String, "permission_needed")
        XCTAssertEqual(out.details?["permission"] as? String, "accessibility")
        XCTAssertNotNil(out.details?["guide_ko"])
    }

    func testDispatcherAnswersPermissionNeededBeforeTheRunner() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false))
        let dispatcher = GadgetToolDispatcher(gadgetIsOn: { _ in true }, permissionGranted: { _ in false })
        dispatcher.register(MenuBarToolRunner(controller: fake), for: [.menubar])
        let out = dispatcher.runAndWait(tool("list_items"), arguments: [:], exit: .mcp, timeout: 2)
        XCTAssertEqual(out.details?["reason"] as? String, "permission_needed")
        XCTAssertEqual(fake.calls, [])
        // status needs no permission
        XCTAssertTrue(dispatcher.runAndWait(tool("status"), arguments: [:], exit: .mcp, timeout: 2).ok)
    }

    func testMcpRoundTripThroughTheDispatcher() {
        let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false))
        fake.reading = .items([MenuBarItem(app: "Clock", title: "", x: 1300, y: 0, width: 50, height: 24)], dividers: dividers)
        let dispatcher = GadgetToolDispatcher(gadgetIsOn: { _ in true }, permissionGranted: { _ in true })
        dispatcher.register(MenuBarToolRunner(controller: fake), for: [.menubar])
        let list = dispatcher.runAndWait(tool("list_items"), arguments: [:], exit: .mcp, timeout: 2)
        XCTAssertTrue(list.ok)
        let tidy = dispatcher.runAndWait(tool("tidy"), arguments: [:], exit: .mcp, timeout: 2)
        XCTAssertTrue(tidy.ok)
        XCTAssertEqual(tidy.details?["collapsed"] as? Bool, true)
        XCTAssertEqual(fake.calls, ["readItems", "state", "tidy"])
    }
}

/// The real MCP server in front of the menu bar runner (no AppKit): switch off → tools hidden, switch on → call.
final class MenuBarMCPRoundTripTests: XCTestCase {
    private var settings = ComputerUseSettings()
    private var service: NachoComboMCPService!
    private var token = ""
    private var log: [String] = []
    private let fake = FakeMenuBar(MenuBarState(running: true, collapsed: false, hasAlwaysHiddenSection: false))

    override func setUpWithError() throws {
        let keys = APIKeyStore(url: nil, random: CountingRandom())
        token = try keys.create(label: "Test Key").token
        fake.reading = .items([
            MenuBarItem(app: "Dropbox", title: "Dropbox", x: 700, y: 0, width: 30, height: 24),
            MenuBarItem(app: "Clock", title: "", x: 1300, y: 0, width: 50, height: 24),
        ], dividers: MenuBarDividers(divider: 1000))
        let dispatcher = GadgetToolDispatcher(gadgetIsOn: { _ in true }, permissionGranted: { _ in true })
        dispatcher.register(MenuBarToolRunner(controller: fake), for: [.menubar])
        service = NachoComboMCPService(settings: { [unowned self] in self.settings }, keys: keys, backend: FakeBackend(), gadgets: dispatcher)
    }

    private func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> [String: Any] {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                           body: Data(body.utf8)), peer: "127.0.0.1")
        let text = String(decoding: r.body, as: UTF8.self)
        log.append("> \(method) \(params)")
        log.append("< \(r.status) \(text.count > 220 ? String(text.prefix(220)) + "…" : text)")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func testListItemsAndTidyOverMCP() {
        let hidden = ((rpc(1, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
        XCTAssertTrue(hidden.isEmpty, "gadget switch is off by default")
        settings.setGadgetEnabled(.menubar, true)
        let names = (((rpc(2, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["menubar_status", "menubar_list_items", "menubar_tidy", "menubar_set_collapsed", "menubar_show_hidden"])
        let guide = rpc(3, "resources/read", #"{"uri":"nachocombo://gadgets/menubar/guide"}"#)
        XCTAssertTrue(String(describing: guide).contains("menubar_tidy"))
        let list = rpc(4, "tools/call", #"{"name":"menubar_list_items","arguments":{}}"#)
        XCTAssertEqual((list["result"] as? [String: Any])?["isError"] as? Bool, false)
        let tidy = rpc(5, "tools/call", #"{"name":"menubar_tidy","arguments":{}}"#)
        XCTAssertEqual((tidy["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(fake.current.collapsed)
        XCTAssertFalse(log.joined().contains(token))
        print("MCP-ROUNDTRIP menubar (Authorization: Bearer ****)\n" + log.joined(separator: "\n"))
    }
}
