import Foundation
import XCTest
@testable import NachoComboCore

// NACHO-145: the NachoCombo MCP shared contract (registry, risk → approval, "always allow" re-declaration and its race,
// old-name aliases, resources / prompts, per-gadget MCP switches).

/// A content_out tool of a test gadget, for the "always allow" paths (no such connector tool ships yet).
private let contentTool = GadgetTool(gadget: .clipboard, action: "test_read_item",
                                     korean: "시험용으로 클립보드 기록 항목 하나의 내용을 읽어 보내요. 승인 규칙을 확인할 때만 써요.",
                                     english: "Test only: sends the content of one clipboard history item.",
                                     input: GadgetSchema.object(["index": GadgetSchema.integer(minimum: 1, maximum: 50)], required: ["index"]),
                                     output: "{ok, message, text}", risk: .contentOut)
private let inputTool = GadgetTool(gadget: .computer, action: "test_type", korean: "시험용으로 지금 입력 칸에 글을 입력해요. 승인 규칙을 확인할 때만 써요.",
                                   english: "Test only: types text.", output: "{ok, message}", risk: .inputInject, exits: [.connector])
private let destructiveTool = GadgetTool(gadget: .clipboard, action: "test_wipe", korean: "시험용으로 클립보드 기록을 모두 지워요. 되돌릴 수 없어요.",
                                         english: "Test only: wipes the clipboard history.", output: "{ok, message}", risk: .destructive)
private let gatedTool = GadgetTool(gadget: .monitor, action: "test_stats", korean: "시험용으로 시스템 모니터의 지금 수치(처리 장치·메모리)를 봐요.",
                                   english: "Test only: current monitor numbers.", output: "{ok, message, cpu, memory}", risk: .read,
                                   permissions: [.accessibility])
private let testTools = GadgetToolRegistry.all + [contentTool, inputTool, destructiveTool, gatedTool]

/// Records the registry calls and answers ok.
final class RecordingGadgetRunner: GadgetToolRunning {
    private let lock = NSLock()
    private(set) var calls: [(name: String, arguments: [String: JSONValue])] = []
    func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        lock.lock(); calls.append((tool.mcpName, arguments)); lock.unlock()
        done(PetCommandOutcome(ok: true, message: "ran \(tool.mcpName)"))
    }
}

private func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

// MARK: registry

final class GadgetRegistryTests: XCTestCase {
    func testRegistryKeepsTheContract() {
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
    }

    func testIntegrityCheckCatchesEveryBrokenRule() {
        let ok = contentTool
        func broken(_ t: GadgetTool, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
            let found = GadgetToolRegistry.problems(in: [ok, t], prompts: [], guides: [])
            XCTAssertTrue(found.contains { $0.contains(expected) }, "\(expected) not reported in \(found)", file: file, line: line)
        }
        broken(GadgetTool(gadget: .clipboard, action: "test_read_item", korean: ok.koreanDescription, english: "x", output: "o", risk: .read),
               "also used by")
        broken(GadgetTool(gadget: .clipboard, action: String(repeating: "a", count: 60), korean: ok.koreanDescription, english: "x", output: "o", risk: .read),
               "breaks ^[a-zA-Z0-9_-]{1,64}$")
        broken(GadgetTool(gadget: .clipboard, action: "send_text", korean: ok.koreanDescription, english: "x", output: "o", risk: .read),
               "contains 'send'")
        broken(GadgetTool(gadget: .clipboard, action: "a", korean: String(repeating: "가", count: 201), english: "x", output: "o", risk: .read),
               "201 characters")
        broken(GadgetTool(gadget: .clipboard, action: "b", korean: "Reads the clipboard history list now.", english: "x", output: "o", risk: .read),
               "not mostly Korean")
        broken(GadgetTool(gadget: .clipboard, action: "c", korean: ok.koreanDescription, english: "", output: "o", risk: .read),
               "English description")
        broken(GadgetTool(gadget: .clipboard, action: "d", korean: ok.koreanDescription, english: "x",
                          input: .object(["type": .string("object"), "properties": .object([:])]), output: "o", risk: .read),
               "additionalProperties")
        broken(GadgetTool(gadget: .clipboard, action: "e", korean: ok.koreanDescription, english: "x",
                          input: GadgetSchema.object([:], required: ["missing"]), output: "o", risk: .read),
               "required")
        broken(GadgetTool(gadget: .clipboard, action: "Bad.Name", korean: ok.koreanDescription, english: "x", output: "o", risk: .read),
               "lower-case")
        broken(GadgetTool(gadget: .clipboard, action: "f", korean: ok.koreanDescription, english: "x", output: "", risk: .read),
               "output shape")
    }

    func testGadgetIDTable() {
        XCTAssertEqual(GadgetID.allCases.filter { $0 != .combo }.map { $0.rawValue },
                       ["window", "menubar", "monitor", "disk", "clipboard", "shelf", "capture", "dim", "awake", "device",
                        "mouse", "appswitch", "calendar", "computer"])
        for id in GadgetID.allCases where id != .combo {
            XCTAssertEqual(GadgetID(module: id.moduleID!), id)
        }
        XCTAssertNil(GadgetID(module: .nachoPet), "the pet is not a gadget of the MCP")
        XCTAssertEqual(GadgetID(named: "windowSnap"), .window)
        XCTAssertEqual(GadgetID(named: "Window Snap"), .window)
        XCTAssertEqual(GadgetID(named: "dim"), .dim)
        XCTAssertEqual(GadgetID.window.guideURI, "nachocombo://gadgets/window/guide")
        XCTAssertEqual(GadgetToolRegistry.providers.map { $0.gadget }.sorted { $0.rawValue < $1.rawValue },
                       GadgetID.allCases.sorted { $0.rawValue < $1.rawValue }, "one provider per gadget")
    }

    func testEveryOldToolIsMigratedWithItsNameAsAlias() {
        // The 16 combo_* capabilities, first and in their old order, still declared under the old names.
        XCTAssertEqual(Array(PetCommands.allNames.prefix(16)), PetCommands.legacyNames)
        for old in PetCommands.legacyNames {
            let t = GadgetToolRegistry.connectorTool(named: old)
            XCTAssertNotNil(t, old)
            XCTAssertEqual(t?.declaredConnectorName, old)
            XCTAssertEqual(GadgetToolRegistry.connectorTool(named: t!.connectorName)?.legacyConnectorName, old, "new name is an alias")
        }
        XCTAssertEqual(GadgetToolRegistry.connectorTool(named: "combo_window_arrange")?.legacyConnectorName, "combo_arrange_window")
        XCTAssertEqual(GadgetToolRegistry.connectorTool(named: "combo_appswitch_quit")?.legacyConnectorName, "combo_quit_app")
        // The Computer Use MCP tools: 24, renamed computer_<old>, old names still resolve.
        let old = ["screen_list_displays", "screen_capture", "app_list", "app_open", "app_activate", "app_quit", "window_list",
                   "window_set_frame", "window_minimize", "mouse_move", "mouse_click", "mouse_drag", "mouse_scroll", "key_press",
                   "type_text", "clipboard_read", "clipboard_write", "open_url", "open_file", "system_info", "process_list",
                   "applescript_run", "shell_run", "file_read", "file_write", "process_kill"]
        XCTAssertEqual(ToolCatalog.all.map { $0.legacyName }, old)
        for name in old {
            XCTAssertEqual(GadgetToolRegistry.mcpTool(named: name)?.mcpName, "computer_\(name)")
            XCTAssertEqual(ToolCatalog.definition(named: "computer_\(name)")?.legacyName, name)
        }
    }

    func testNamesFollowTheRule() {
        for t in GadgetToolRegistry.all {
            XCTAssertEqual(t.mcpName, "\(t.gadget.rawValue)_\(t.action)")
            XCTAssertEqual(t.connectorName, t.gadget == .combo ? "combo_\(t.action)" : "combo_\(t.gadget.rawValue)_\(t.action)")
            XCTAssertFalse(t.mcpName.contains("."))
        }
        XCTAssertTrue(GadgetToolRegistry.all.contains { $0.mcpName == "window_arrange" })
        XCTAssertEqual(GadgetToolRegistry.connectorTool(named: "combo_gadget_guide")?.risk, .read)
    }

    func testEveryToolHasARiskAndDangerousOnesAreDestructive() {
        let byName = Dictionary(uniqueKeysWithValues: GadgetToolRegistry.all.map { ($0.mcpName, $0.risk) })
        for name in ["appswitch_quit", "computer_app_quit", "computer_shell_run", "computer_applescript_run", "computer_file_write", "computer_process_kill"] {
            XCTAssertEqual(byName[name], .destructive, name)
        }
        for name in ["computer_screen_capture", "computer_clipboard_read", "computer_file_read"] { XCTAssertEqual(byName[name], .contentOut, name) }
        for name in ["computer_mouse_click", "computer_type_text", "computer_key_press"] { XCTAssertEqual(byName[name], .inputInject, name) }
        for name in ["window_list_windows", "appswitch_list", "combo_list_gadgets", "combo_workspace_list"] { XCTAssertEqual(byName[name], .read, name) }
    }
}

// MARK: risk → approval

final class GadgetApprovalTests: XCTestCase {
    func testRiskToApprovalTable() {
        XCTAssertFalse(GadgetTool(gadget: .window, action: "r", korean: "", english: "", output: "", risk: .read).connectorApproval(alwaysAllowed: false))
        XCTAssertFalse(GadgetTool(gadget: .window, action: "c", korean: "", english: "", output: "", risk: .change).connectorApproval(alwaysAllowed: false))
        XCTAssertTrue(contentTool.connectorApproval(alwaysAllowed: false))
        XCTAssertFalse(contentTool.connectorApproval(alwaysAllowed: true))
        XCTAssertTrue(inputTool.connectorApproval(alwaysAllowed: false))
        XCTAssertFalse(inputTool.connectorApproval(alwaysAllowed: true))
        XCTAssertTrue(destructiveTool.connectorApproval(alwaysAllowed: false))
        XCTAssertTrue(destructiveTool.connectorApproval(alwaysAllowed: true), "destructive ignores always allow")
    }

    private func approval(_ caps: [[String: Any]], _ name: String) -> String?? {
        guard let c = caps.first(where: { $0["name"] as? String == name }) else { return .none }
        return .some(c["approval"] as? String)
    }

    func testDeclarationFollowsAlwaysAllowAndDisabled() {
        let off = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: [], tools: testTools)
        XCTAssertEqual(approval(off, contentTool.declaredConnectorName), .some("required"))
        XCTAssertEqual(approval(off, destructiveTool.declaredConnectorName), .some("required"))
        XCTAssertEqual(approval(off, "combo_quit_app"), .some("required"))
        XCTAssertEqual(approval(off, "combo_list_apps"), .some(nil))
        let on = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [.clipboard], disabled: [], tools: testTools)
        XCTAssertEqual(approval(on, contentTool.declaredConnectorName), .some(nil), "always allowed: no card")
        XCTAssertEqual(approval(on, destructiveTool.declaredConnectorName), .some("required"), "destructive still asks")
        XCTAssertEqual(approval(on, inputTool.declaredConnectorName), .some("required"), "another gadget still asks")
        let disabled = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: ["combo_open_app", contentTool.connectorName], tools: testTools)
        XCTAssertNil(disabled.first { $0["name"] as? String == "combo_open_app" }, "a switched-off action is not declared")
        XCTAssertNil(disabled.first { $0["name"] as? String == contentTool.declaredConnectorName })
        XCTAssertEqual(disabled.count, off.count - 2)
        // allowQuit keeps PR #27's switch.
        XCTAssertNil(PetCommands.capabilities(allowQuit: false, alwaysAllowed: [], disabled: [], tools: testTools)
            .first { $0["name"] as? String == "combo_quit_app" })
    }

    func testTrustStoreIsPerGadgetDefaultOffAndPersisted() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nacho-trust-\(UUID().uuidString)/gadget-trust.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trust = GadgetTrust(url: url, trustable: { [.clipboard] })
        XCTAssertEqual(trust.alwaysAllowed, [])
        var changes = 0
        trust.observe { changes += 1 }
        XCTAssertFalse(trust.setAlwaysAllowed(.window, true), "a gadget without content tools cannot be always allowed")
        XCTAssertTrue(trust.setAlwaysAllowed(.clipboard, true))
        XCTAssertFalse(trust.setAlwaysAllowed(.clipboard, true), "no change, no notification")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(GadgetTrust(url: url, trustable: { [.clipboard] }).alwaysAllowed, [.clipboard])
        XCTAssertTrue(trust.setAlwaysAllowed(.clipboard, false))
        XCTAssertEqual(GadgetTrust(url: url, trustable: { [.clipboard] }).alwaysAllowed, [])
        trust.disabled = ["combo_open_app"]
        XCTAssertEqual(changes, 3)
        // NACHO-149 offers content tools of clipboard, shelf and capture to Nacho; other lanes may add more.
        XCTAssertTrue(GadgetToolRegistry.trustableGadgets().isSuperset(of: [.clipboard, .shelf, .capture]))
        XCTAssertFalse(GadgetToolRegistry.trustableGadgets().contains(.window), "no content tool, no always allow")
        XCTAssertTrue(GadgetToolRegistry.trustableGadgets(in: testTools).isSuperset(of: [.clipboard, .computer]))
    }
}

// MARK: connector bridge

final class GadgetConnectorTests: XCTestCase {
    private var factory = PetTransportFactory()
    private var ex = PetRecordingExecutor()
    private var runner = RecordingGadgetRunner()
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var trust = GadgetTrust(trustable: { [.clipboard] })
    private var client: PetConnectorClient!
    private var t: PetFakeTransport!

    override func setUp() {
        factory = PetTransportFactory(); ex = PetRecordingExecutor(); runner = RecordingGadgetRunner(); scheduled = []
        trust = GadgetTrust(trustable: { [.clipboard] })
        let dispatcher = GadgetToolDispatcher(tools: testTools)
        dispatcher.register(runner, for: [.clipboard, .monitor])
        client = PetConnectorClient(url: URL(string: "ws://127.0.0.1:8787/ws/connector")!, token: "nct_abc", executor: ex,
                                    makeTransport: factory.make, schedule: { [unowned self] d, w in self.scheduled.append((d, w)) },
                                    trust: trust, tools: testTools, dispatcher: dispatcher)
        client.connect(); client.flush()
        t = factory.with(path: "/ws/connector")[0]
        t.handler?(.opened); client.flush()
        t.deliver(#"{"type":"ready","agent_id":"a"}"#); client.flush()
    }

    private func frames(_ type: String) -> [[String: Any]] { t.sent.map(object).filter { $0["type"] as? String == type } }
    private func frame(_ type: String, _ n: Int) -> [String: Any] { let f = frames(type); return n < f.count ? f[n] : [:] }

    private func approval(in frame: [String: Any], _ name: String) -> String?? {
        guard let c = (frame["capabilities"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }) else { return .none }
        return .some(c["approval"] as? String)
    }

    private func request(_ id: String, _ capability: String, _ params: String = "{}") -> [String: Any] {
        t.deliver(#"{"type":"request","id":"\#(id)","capability":"\#(capability)","params":\#(params)}"#)
        client.flush(); client.flush()
        return t.sent.map(object).last { $0["id"] as? String == id } ?? [:]
    }

    func testHelloDeclaresContentToolsWithApprovalByDefault() {
        let hello = frame("hello", 0)
        XCTAssertEqual(approval(in: hello, contentTool.declaredConnectorName), .some("required"))
        XCTAssertEqual(approval(in: hello, "combo_list_apps"), .some(nil))
    }

    func testAlwaysAllowToggleRedeclaresAtOnce() {
        trust.setAlwaysAllowed(.clipboard, true); client.flush(); client.flush()
        let caps = frames("capabilities")
        XCTAssertEqual(caps.count, 1, "one capabilities frame per change")
        XCTAssertEqual(approval(in: frame("capabilities", 0), contentTool.declaredConnectorName), .some(nil))
        XCTAssertEqual(approval(in: frame("capabilities", 0), destructiveTool.declaredConnectorName), .some("required"))
        XCTAssertEqual(t.sent.last, ConnectorFrames.ping, "a ping right behind it tells when the server read it")
        trust.setAlwaysAllowed(.clipboard, false); client.flush(); client.flush()
        XCTAssertEqual(approval(in: frame("capabilities", 1), contentTool.declaredConnectorName), .some("required"))
        trust.disabled = ["combo_open_app"]; client.flush(); client.flush()
        XCTAssertNil((frame("capabilities", 2)["capabilities"] as? [[String: Any]])?.first { $0["name"] as? String == "combo_open_app" })
    }

    func testRequestsBetweenRevokeAndRedeclarationAreRefused() {
        trust.setAlwaysAllowed(.clipboard, true); client.flush(); client.flush()
        t.deliver(#"{"type":"pong"}"#); client.flush()             // server now declares it without a card
        XCTAssertEqual((request("r1", contentTool.declaredConnectorName, #"{"index":1}"#)["result"] as? [String: Any])?["ok"] as? Bool, true)
        trust.setAlwaysAllowed(.clipboard, false); client.flush(); client.flush()
        // The server may still send a call under the old declaration: no card ran, so it is refused.
        let refused = request("r2", contentTool.declaredConnectorName, #"{"index":2}"#)["result"] as? [String: Any]
        XCTAssertEqual(refused?["ok"] as? Bool, false)
        XCTAssertEqual(refused?["reason"] as? String, "approval_revoked")
        XCTAssertNotNil(refused?["hint"] as? String)
        XCTAssertEqual(runner.calls.count, 1, "the refused call never reached the gadget")
        t.deliver(#"{"type":"pong"}"#); client.flush()             // the server read the new declaration
        XCTAssertEqual((request("r3", contentTool.declaredConnectorName, #"{"index":3}"#)["result"] as? [String: Any])?["ok"] as? Bool, true,
                       "now the server shows the card first, so the call runs")
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testUnansweredRedeclarationReopensTheConnection() {
        trust.setAlwaysAllowed(.clipboard, true); client.flush(); client.flush()
        let barrier = scheduled.last { $0.0 == PetConnectorClient.barrierSeconds }
        XCTAssertNotNil(barrier)
        barrier?.1(); client.flush()
        XCTAssertEqual(factory.with(path: "/ws/connector").count, 2, "a fresh hello declares the current switches")
    }

    func testSwitchedOffActionIsRefused() {
        trust.disabled = ["combo_open_app"]; client.flush(); client.flush()
        let r = request("r1", "combo_open_app", #"{"app":"Safari"}"#)["result"] as? [String: Any]
        XCTAssertEqual(r?["reason"] as? String, "action_disabled")
        XCTAssertTrue(ex.commands.isEmpty)
    }

    func testNewNamesAreAliasesOfTheOldCapabilities() {
        _ = request("r1", "combo_window_arrange", #"{"position":"left"}"#)
        _ = request("r2", "combo_appswitch_open", #"{"app":"Safari"}"#)
        _ = request("r3", "combo_arrange_window", #"{"position":"right"}"#)
        XCTAssertEqual(ex.commands, [.arrangeWindow(.left, app: nil), .openApp("Safari"), .arrangeWindow(.right, app: nil)])
        XCTAssertEqual(PetCommands.parse(capability: "combo_dim_set_strength", params: ["percent": 40]), .success(.setDimStrength(40)))
    }

    func testGadgetGuideToolAnswersTheGuideText() {
        let r = request("g1", "combo_gadget_guide", #"{"gadget":"window"}"#)["result"] as? [String: Any]
        XCTAssertEqual(r?["ok"] as? Bool, true)
        let guide = r?["guide"] as? String ?? ""
        XCTAssertTrue(guide.contains("combo_arrange_window"), "connector names in Nacho's guide")
        XCTAssertFalse(guide.contains("`window_arrange"), "no MCP names in Nacho's guide")
        XCTAssertEqual(guide, WindowTools.guide!.render(for: .connector, tools: testTools))
        let bad = request("g2", "combo_gadget_guide", #"{"gadget":"toaster"}"#)["result"] as? [String: Any]
        XCTAssertEqual(bad?["ok"] as? Bool, false)
        let none = request("g3", "combo_gadget_guide", #"{"gadget":"disk"}"#)["result"] as? [String: Any]
        XCTAssertEqual(none?["ok"] as? Bool, true, "a gadget without a guide yet lists its tools")
    }

    func testGadgetOffAndPermissionResultsAreShared() {
        let d = GadgetToolDispatcher(tools: testTools, gadgetIsOn: { $0 != .monitor })
        d.register(runner, for: [.monitor])
        var out: PetCommandOutcome?
        d.run(gatedTool, arguments: [:], exit: .connector) { out = $0 }
        XCTAssertEqual(out?.ok, false)
        XCTAssertEqual(out?.resultJSON["reason"] as? String, "gadget_off")
        XCTAssertEqual(out?.resultJSON["hint"] as? String, "ask the user with ask_choice, then call combo_set_gadget")
        XCTAssertNotNil(out?.resultJSON["guide_ko"] as? String)
        d.setState(gadgetIsOn: { _ in true }, permissionGranted: { $0 != .accessibility })
        d.run(gatedTool, arguments: [:], exit: .connector) { out = $0 }
        XCTAssertEqual(out?.resultJSON["reason"] as? String, "permission_needed")
        XCTAssertEqual(out?.resultJSON["permission"] as? String, "accessibility")
        XCTAssertTrue((out?.resultJSON["guide_ko"] as? String ?? "").contains("손쉬운 사용"))
        XCTAssertTrue(runner.calls.isEmpty)
        let none = GadgetToolDispatcher(tools: testTools)
        none.run(gatedTool, arguments: [:], exit: .mcp) { out = $0 }
        XCTAssertEqual(out?.resultJSON["reason"] as? String, "unavailable")
    }
}

// MARK: MCP server

final class NachoComboMCPServerTests: XCTestCase {
    private var settings = ComputerUseSettings()
    private var backend = FakeBackend()
    private var runner = RecordingGadgetRunner()
    private var pet = PetRecordingExecutor()
    private var keys: APIKeyStore!
    private var service: NachoComboMCPService!
    private var token = ""
    private var log: [String] = []

    override func setUpWithError() throws {
        settings = ComputerUseSettings(); backend = FakeBackend(); runner = RecordingGadgetRunner(); pet = PetRecordingExecutor(); log = []
        keys = APIKeyStore(url: nil, random: CountingRandom())
        token = try keys.create(label: "Test Key").token
        let dispatcher = GadgetToolDispatcher(tools: testTools)
        dispatcher.register(PetCommandToolRunner(executor: pet), for: PetCommandToolRunner.gadgets)
        dispatcher.register(runner, for: [.monitor])
        service = NachoComboMCPService(settings: { [unowned self] in self.settings }, keys: keys, backend: backend,
                                       gadgets: dispatcher, registry: testTools)
    }

    private func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> [String: Any] {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                           body: Data(body.utf8)), peer: "127.0.0.1")
        let text = String(decoding: r.body, as: UTF8.self)
        log.append("> \(method) \(params)")
        log.append("< \(r.status) \(text.count > 160 ? String(text.prefix(160)) + "…" : text)")
        return object(text)
    }

    private func result(_ o: [String: Any]) -> [String: Any] { o["result"] as? [String: Any] ?? [:] }
    private func toolNames() -> [String] { ((result(rpc(9, "tools/list"))["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String } }
    private func callText(_ o: [String: Any]) -> [String: Any] {
        object(((result(o)["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "")
    }

    func testInitializeDeclaresToolsResourcesAndPrompts() {
        let r = result(rpc(1, "initialize", #"{"protocolVersion":"2025-06-18"}"#))
        XCTAssertEqual((r["serverInfo"] as? [String: Any])?["name"] as? String, "NachoCombo MCP")
        let caps = r["capabilities"] as? [String: Any]
        XCTAssertNotNil(caps?["tools"]); XCTAssertNotNil(caps?["resources"]); XCTAssertNotNil(caps?["prompts"])
    }

    func testResourcesListAndReadTheGuides() {
        let list = (result(rpc(1, "resources/list"))["resources"] as? [[String: Any]]) ?? []
        XCTAssertTrue(list.contains { $0["uri"] as? String == "nachocombo://gadgets/window/guide" })
        XCTAssertTrue(list.allSatisfy { $0["mimeType"] as? String == "text/markdown" })
        let read = result(rpc(2, "resources/read", #"{"uri":"nachocombo://gadgets/window/guide"}"#))
        let text = ((read["contents"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("`window_arrange"), "MCP names in the MCP guide")
        XCTAssertFalse(text.contains("combo_arrange_window`"))
        XCTAssertTrue(text.contains("## 예시 호출"))
        let missing = rpc(3, "resources/read", #"{"uri":"nachocombo://gadgets/toaster/guide"}"#)
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? Int, -32002)
        XCTAssertEqual(((rpc(4, "resources/read", "{}"))["error"] as? [String: Any])?["code"] as? Int, JSONRPCError.invalidParams)
    }

    func testPromptsListAndGet() {
        let list = (result(rpc(1, "prompts/list"))["prompts"] as? [[String: Any]]) ?? []
        let p = list.first { $0["name"] as? String == "window_side_by_side" }
        XCTAssertEqual((p?["arguments"] as? [[String: Any]])?.map { $0["name"] as? String }, ["left", "right"])
        let got = result(rpc(2, "prompts/get", #"{"name":"window_side_by_side","arguments":{"left":"Safari","right":"Notes"}}"#))
        let message = (got["messages"] as? [[String: Any]])?.first
        XCTAssertEqual(message?["role"] as? String, "user")
        let text = (message?["content"] as? [String: Any])?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("Safari") && text.contains("Notes") && text.contains("window_layout"))
        XCTAssertEqual((rpc(3, "prompts/get", #"{"name":"window_side_by_side","arguments":{"left":"Safari"}}"#)["error"] as? [String: Any])?["code"] as? Int,
                       JSONRPCError.invalidParams, "a required argument is missing")
        XCTAssertEqual((rpc(4, "prompts/get", #"{"name":"nope"}"#)["error"] as? [String: Any])?["code"] as? Int, JSONRPCError.invalidParams)
        XCTAssertEqual((rpc(5, "prompts/get", #"{"name":"window_side_by_side","arguments":{"left":"a","right":"b","x":"c"}}"#)["error"] as? [String: Any])?["code"] as? Int,
                       JSONRPCError.invalidParams)
    }

    func testGadgetSwitchOffHidesAndRefusesItsTools() {
        XCTAssertTrue(toolNames().isEmpty, "every switch off by default")
        let off = rpc(1, "tools/call", #"{"name":"window_arrange","arguments":{"position":"left"}}"#)
        XCTAssertEqual(result(off)["isError"] as? Bool, true)
        XCTAssertTrue(pet.commands.isEmpty)
        settings.setGadgetEnabled(.window, true)
        XCTAssertEqual(Set(toolNames()), ["window_arrange", "window_layout", "window_list_windows", "window_displays", "window_place", "window_tile", "window_split",
                                          "window_ratio", "window_move_display", "window_arrange_apps", "window_undo"])
        let on = rpc(2, "tools/call", #"{"name":"window_arrange","arguments":{"position":"left"}}"#)
        XCTAssertEqual(result(on)["isError"] as? Bool, false)
        XCTAssertEqual(callText(on)["ok"] as? Bool, true)
        XCTAssertEqual(pet.commands, [.arrangeWindow(.left, app: nil)])
        let bad = rpc(3, "tools/call", #"{"name":"window_arrange","arguments":{"position":"sideways"}}"#)
        XCTAssertEqual(result(bad)["isError"] as? Bool, true, "the old parameter checks still apply")
        XCTAssertEqual(pet.commands.count, 1)
        settings.setGadgetEnabled(.computer, true)
        XCTAssertFalse(settings.isGadgetEnabled(.computer), "computer keeps its tool group switches")
        XCTAssertFalse(toolNames().contains("computer_screen_capture"))
        XCTAssertFalse(toolNames().contains("combo_gadget_guide"), "the guide tool is Nacho's; MCP has resources")
    }

    func testOldAndNewComputerUseNamesReachTheSameBackendTool() {
        settings.setEnabled(.screen, true)
        XCTAssertEqual(Set(toolNames()), ["computer_screen_list_displays", "computer_screen_capture"])
        _ = rpc(1, "tools/call", #"{"name":"computer_screen_capture","arguments":{"target":"display"}}"#)
        _ = rpc(2, "tools/call", #"{"name":"screen_capture","arguments":{"target":"display"}}"#)
        XCTAssertEqual(backend.calls.map { $0.tool }, ["screen_capture", "screen_capture"])
        XCTAssertEqual(service.callLog.entries.map { $0.tool }, ["computer_screen_capture", "screen_capture"])
    }

    func testEmergencyStopAlsoStopsGadgetTools() {
        settings.setGadgetEnabled(.window, true)
        service.emergencyStop()
        XCTAssertTrue(toolNames().isEmpty)
        XCTAssertEqual(result(rpc(1, "tools/call", #"{"name":"window_list_windows"}"#))["isError"] as? Bool, true)
        XCTAssertTrue(pet.commands.isEmpty)
    }

    func testGadgetSwitchesDecodeFromOldSettingsFilesAsOff() throws {
        let old = try JSONDecoder().decode(ComputerUseSettings.self, from: Data(#"{"port":47653,"enabledGroups":{"screen":true}}"#.utf8))
        XCTAssertEqual(old.enabledGadgets, [:])
        let bad = try JSONDecoder().decode(ComputerUseSettings.self, from: Data(#"{"enabledGadgets":"yes"}"#.utf8))
        XCTAssertEqual(bad.enabledGadgets, [:])
        var s = ComputerUseSettings(); s.setGadgetEnabled(.monitor, true)
        let back = try JSONDecoder().decode(ComputerUseSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.isGadgetEnabled(.monitor))
    }

    /// initialize → tools/list → resources/list → resources/read → tools/call, printed with the key masked
    /// (the round-trip log of the PR). No screen, clipboard or typed content is involved.
    func testRoundTripLog() {
        settings.setGadgetEnabled(.window, true)
        _ = rpc(1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"roundtrip","version":"1"}}"#)
        XCTAssertTrue(toolNames().contains("window_list_windows"))
        _ = rpc(3, "resources/list")
        _ = rpc(4, "resources/read", #"{"uri":"nachocombo://gadgets/window/guide"}"#)
        let call = rpc(5, "tools/call", #"{"name":"window_list_windows","arguments":{}}"#)
        XCTAssertEqual(result(call)["isError"] as? Bool, false)
        XCTAssertEqual(pet.commands, [.listWindows])
        let text = log.joined(separator: "\n")
        XCTAssertFalse(text.contains(token))
        print("MCP-ROUNDTRIP (Authorization: Bearer ****)\n" + text)
    }
}
