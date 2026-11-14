import Foundation
import XCTest
@testable import NachoComboCore

// NACHO-147: Computer Use on Nacho's path (connector) and the accessibility tree tools on both exits.
// Fixtures only: no real screen, no real window, no typed text.

final class FakeElement {
    var info: UIElementInfo?
    var children: [FakeElement]
    init(_ role: String, title: String? = nil, value: String? = nil, label: String? = nil, subrole: String? = nil,
         frame: UIRect? = UIRect(x: 10, y: 20, width: 100, height: 30), enabled: Bool? = nil, _ children: [FakeElement] = []) {
        info = UIElementInfo(role: role, subrole: subrole, title: title, value: value, label: label, frame: frame, enabled: enabled)
        self.children = children
    }
}

final class FakeElementAccess: UIElementAccess {
    var root: FakeElement
    var app = UITreeApp(name: "Notes", pid: 812, bundleID: "com.apple.Notes")
    private(set) var targets: [UITreeTarget] = []
    private(set) var pressed: [FakeElement] = []
    private(set) var infoReads = 0
    init(_ root: FakeElement) { self.root = root }
    func root(of target: UITreeTarget) throws -> (element: AnyObject, app: UITreeApp) {
        targets.append(target)
        if target.app == "Missing" { throw PolicyError("Running app not found") }
        return (root, app)
    }
    func info(of element: AnyObject) -> UIElementInfo? { infoReads += 1; return (element as? FakeElement)?.info }
    func children(of element: AnyObject) -> [AnyObject] { (element as? FakeElement)?.children ?? [] }
    func press(_ element: AnyObject) -> Bool {
        guard let e = element as? FakeElement else { return false }
        pressed.append(e)
        return e.info?.role == "AXButton"
    }
}

final class FakeSelfGuard: ComputerSelfGuard {
    var ownRect: UIRect?
    var keyboardStaysWithUs = false
    private(set) var released = 0
    func ownsPoint(x: Double, y: Double) -> Bool {
        guard let r = ownRect else { return false }
        return x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height
    }
    func releaseKeyboard() -> Bool { released += 1; return !keyboardStaysWithUs }
}

/// A window: toolbar (2 buttons), a list with 30 rows, a search field, a password field.
private func sampleWindow() -> FakeElement {
    let rows = (1...30).map { i in FakeElement("AXRow", [FakeElement("AXStaticText", value: "메모 \(i)")]) }
    return FakeElement("AXWindow", title: "메모", frame: UIRect(x: 0, y: 25, width: 800, height: 600), [
        FakeElement("AXToolbar", [
            FakeElement("AXButton", title: "새로운 메모", frame: UIRect(x: 100, y: 40, width: 40, height: 20)),
            FakeElement("AXButton", label: "Delete", frame: UIRect(x: 150, y: 40, width: 40, height: 20), enabled: false),
        ]),
        FakeElement("AXScrollArea", [FakeElement("AXTable", rows)]),
        FakeElement("AXTextField", title: "검색", value: String(repeating: "가", count: 300), subrole: "AXSearchField"),
        FakeElement("AXTextField", title: "암호", value: "hunter2", subrole: "AXSecureTextField"),
    ])
}

private let tools = GadgetToolRegistry.all
private func tool(_ action: String) -> GadgetTool { tools.first { $0.gadget == .computer && $0.action == action }! }

private func answer(_ runner: ComputerGadgetRunner, _ t: GadgetTool, _ args: [String: JSONValue]) -> PetCommandOutcome {
    let sem = DispatchSemaphore(value: 0)
    var out: PetCommandOutcome?
    runner.run(t, arguments: args) { out = $0; sem.signal() }
    XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
    return out ?? PetCommandOutcome(ok: false, message: "no answer")
}

private func nodes(_ o: PetCommandOutcome) -> [[String: Any]] { (o.details?["nodes"] as? [[String: Any]]) ?? [] }

// MARK: tree model (Core)

final class ComputerUITreeTests: XCTestCase {
    func testLimitsAreClampedToTheirRanges() {
        XCTAssertEqual(UITreeLimits(), UITreeLimits(maxDepth: 8, maxNodes: 200, maxTextLength: 80))
        let wild = UITreeLimits(maxDepth: 999, maxNodes: 100_000, maxTextLength: 1)
        XCTAssertEqual(wild.maxDepth, 25)
        XCTAssertEqual(wild.maxNodes, 500)
        XCTAssertEqual(wild.maxTextLength, 10)
        XCTAssertEqual(UITreeLimits(maxDepth: 0, maxNodes: -5).maxNodes, 1)
    }

    func testTextIsCutToOneBoundedLine() {
        XCTAssertEqual(UITreeText.clip("가나다\n라마\t바", 80), "가나다 라마 바")
        XCTAssertEqual(UITreeText.clip(String(repeating: "x", count: 20), 10), "xxxxxxxxx…")
        XCTAssertEqual(UITreeText.clip(String(repeating: "x", count: 20), 10)?.count, 10)
        XCTAssertNil(UITreeText.clip("  \n ", 10))
        XCTAssertNil(UITreeText.clip(nil, 10))
        XCTAssertEqual(UITreeText.roleKey("AXTextField"), UITreeText.roleKey("text_field"))
        XCTAssertEqual(UITreeText.roleKey("button"), UITreeText.roleKey("AXButton"))
    }

    func testTreeIsBoundedByDepthCountAndTextLength() throws {
        let access = FakeElementAccess(sampleWindow())
        let reader = UITreeReader(access: access)
        let s = try reader.read(UITreeTarget(), limits: UITreeLimits(maxDepth: 2, maxNodes: 500, maxTextLength: 20))
        XCTAssertEqual(s.nodes.map { $0.depth }.max(), 2, "nothing deeper than maxDepth")
        XCTAssertGreaterThan(s.leftOutByDepth, 0)
        XCTAssertTrue(s.truncated)
        let search = try XCTUnwrap(s.nodes.first { $0.subrole == "AXSearchField" })
        XCTAssertEqual(search.value?.count, 20, "values are cut to maxTextLength")
        XCTAssertTrue(search.value!.hasSuffix("…"))

        let few = try reader.read(UITreeTarget(), limits: UITreeLimits(maxDepth: 25, maxNodes: 6))
        XCTAssertEqual(few.nodes.count, 6, "at most maxNodes")
        XCTAssertGreaterThan(few.leftOutByCount, 0)
        // Breadth first: the window and its direct children come before the depths of the list.
        XCTAssertEqual(few.nodes.map { $0.role }, ["AXWindow", "AXToolbar", "AXButton", "AXScrollArea", "AXTextField", "AXTextField"])
        XCTAssertEqual(few.nodes.map { $0.depth }, [0, 1, 2, 1, 1, 1], "answered in tree order")
        XCTAssertLessThan(access.infoReads, 60, "a 30-row list is not walked when the budget is spent")
    }

    func testSecureFieldValueIsNeverSent() throws {
        let reader = UITreeReader(access: FakeElementAccess(sampleWindow()))
        let s = try reader.read(UITreeTarget(), limits: UITreeLimits())
        let secure = try XCTUnwrap(s.nodes.first { $0.title == "암호" })
        XCTAssertNil(secure.value)
        XCTAssertTrue(secure.secure)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: s.details()), as: UTF8.self)
        XCTAssertFalse(json.contains("hunter2"))
        // Nor can a search find it by its value.
        XCTAssertTrue(try reader.find(UITreeTarget(), role: nil, title: "hunter2", maxResults: 5).snapshot.nodes.isEmpty)
    }

    func testFindByRoleAndTitle() throws {
        let reader = UITreeReader(access: FakeElementAccess(sampleWindow()))
        let buttons = try reader.find(UITreeTarget(), role: "button", title: nil, maxResults: 10).snapshot
        XCTAssertEqual(buttons.nodes.count, 2)
        let byLabel = try reader.find(UITreeTarget(), role: "AXButton", title: "delete", maxResults: 10).snapshot
        XCTAssertEqual(byLabel.nodes.map { $0.label }, ["Delete"], "title matches the label too, ignoring case")
        let rows = try reader.find(UITreeTarget(), role: nil, title: "메모 ", maxResults: 3)
        XCTAssertEqual(rows.snapshot.nodes.count, 3, "at most maxResults")
        XCTAssertGreaterThan(rows.scanned, 3)
        let field = try reader.find(UITreeTarget(), role: "search_field", title: nil, maxResults: 3).snapshot
        XCTAssertEqual(field.nodes.first?.title, "검색", "subroles match too")
        XCTAssertTrue(try reader.find(UITreeTarget(), role: "slider", title: nil, maxResults: 3).snapshot.nodes.isEmpty)
    }

    func testIdsResolveOnlyWhileTheElementIsUnchanged() throws {
        let window = sampleWindow()
        let reader = UITreeReader(access: FakeElementAccess(window))
        let s = try reader.read(UITreeTarget(), limits: UITreeLimits())
        let button = try XCTUnwrap(s.nodes.first { $0.title == "새로운 메모" })
        guard case .element = reader.element(id: button.id) else { return XCTFail("fresh id resolves") }
        window.children[0].children[0].info?.title = "다른 버튼"
        guard case .problem(let why) = reader.element(id: button.id) else { return XCTFail("changed element") }
        XCTAssertTrue(why.contains("changed"))
        window.children[0].children[0].info = nil
        guard case .problem(let gone) = reader.element(id: button.id) else { return XCTFail("gone element") }
        XCTAssertTrue(gone.contains("gone"))
        guard case .problem = reader.element(id: "nonsense") else { return XCTFail() }
        for _ in 0..<UITreeReader.keptReads { _ = try reader.read(UITreeTarget(), limits: UITreeLimits(maxNodes: 1)) }
        guard case .problem(let old) = reader.element(id: s.nodes[0].id) else { return XCTFail("old read") }
        XCTAssertTrue(old.contains("older read"))
    }
}

// MARK: registry: risk, approval, what Nacho gets

final class ComputerUseNachoRegistryTests: XCTestCase {
    private let nachoActions: Set<String> = ["screen_list_displays", "screen_capture", "mouse_move", "mouse_click", "mouse_drag",
                                             "mouse_scroll", "key_press", "type_text", "ui_tree", "find_element", "click_element"]

    func testNachoGetsTheObserveAndInputToolsOnly() {
        let declared = Set(GadgetToolRegistry.tools(on: .connector).filter { $0.gadget == .computer }.map { $0.action })
        XCTAssertEqual(declared, nachoActions)
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
        for a in ["ui_tree", "find_element", "click_element"] {
            XCTAssertNotNil(GadgetToolRegistry.mcpTool(named: "computer_\(a)"), "MCP has \(a) too")
            XCTAssertNotNil(GadgetToolRegistry.connectorTool(named: "combo_computer_\(a)"))
        }
    }

    func testHighRiskToolsAreNeverDeclaredToNacho() {
        let caps = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [.computer], disabled: []).compactMap { $0["name"] as? String }
        for old in ["applescript_run", "shell_run", "file_read", "file_write", "process_kill", "app_quit", "clipboard_read", "open_file"] {
            XCTAssertFalse(caps.contains("combo_computer_\(old)"), old)
            XCTAssertNil(GadgetToolRegistry.connectorTool(named: "combo_computer_\(old)"), old)
            XCTAssertNil(GadgetToolRegistry.connectorTool(named: old), old)
        }
        XCTAssertFalse(caps.contains { $0.contains("shell") || $0.contains("applescript") || $0.contains("file_") || $0.contains("process") })
    }

    func testRiskDecidesTheApprovalAndAlwaysAllowLiftsIt() {
        func approvals(_ allowed: Set<GadgetID>) -> [String: String] {
            var out: [String: String] = [:]
            for c in PetCommands.capabilities(allowQuit: true, alwaysAllowed: allowed, disabled: [])
            where (c["name"] as? String)?.hasPrefix("combo_computer_") == true {
                out[c["name"] as! String] = c["approval"] as? String ?? "none"
            }
            return out
        }
        let off = approvals([])
        XCTAssertEqual(off["combo_computer_screen_list_displays"], "none", "read runs at once")
        for name in ["screen_capture", "ui_tree", "find_element"] {
            XCTAssertEqual(tool(name).risk, .contentOut, name)
            XCTAssertEqual(off["combo_computer_\(name)"], "required", "\(name): approval every time")
        }
        for name in ["mouse_move", "mouse_click", "mouse_drag", "mouse_scroll", "key_press", "type_text", "click_element"] {
            XCTAssertEqual(tool(name).risk, .inputInject, name)
            XCTAssertEqual(off["combo_computer_\(name)"], "required", name)
        }
        let on = approvals([.computer])
        XCTAssertEqual(Set(on.values), ["none"], "always allowed: declared without approval")
        XCTAssertEqual(on.count, off.count)
        XCTAssertEqual(approvals([.clipboard]), off, "another gadget's switch changes nothing here")
        XCTAssertTrue(GadgetToolRegistry.trustableGadgets().contains(.computer))
        XCTAssertFalse(GadgetTrust(trustable: { GadgetToolRegistry.trustableGadgets() }).isAlwaysAllowed(.computer), "off by default")
    }

    func testNewToolsSitUnderTheToolGroupSwitchesOnMCP() {
        XCTAssertEqual(tool("ui_tree").mcpGroup, .appsWindows)
        XCTAssertEqual(tool("find_element").mcpGroup, .appsWindows)
        XCTAssertEqual(tool("click_element").mcpGroup, .input)
        for a in ["ui_tree", "find_element", "click_element"] {
            XCTAssertEqual(tool(a).permissions, [.accessibility])
            XCTAssertTrue(tool(a).requiresGadgetOn)
        }
        var s = ComputerUseSettings()
        XCTAssertFalse(s.offers(tool("ui_tree")), "off by default")
        s.setEnabled(.appsWindows, true)
        XCTAssertTrue(s.offers(tool("ui_tree")))
        XCTAssertFalse(s.offers(tool("click_element")))
    }

    func testGuideAndPrompts() throws {
        let guide = try XCTUnwrap(GadgetToolRegistry.guide(for: .computer))
        let nacho = guide.render(for: .connector)
        XCTAssertTrue(nacho.contains("`combo_computer_ui_tree"))
        XCTAssertTrue(nacho.contains("`combo_computer_click_element {\"id\":\"t3.12\"}`"))
        XCTAssertFalse(nacho.contains("shell_run"), "Nacho's guide lists Nacho's tools only")
        for word in ["관찰", "행동", "확인", "좌표", "손쉬운 사용", "화면 기록", "승인", "⌃⌥⌘."] {
            XCTAssertTrue(nacho.contains(word), word)
        }
        let mcp = guide.render(for: .mcp)
        XCTAssertTrue(mcp.contains("`computer_find_element"))
        let names = GadgetToolRegistry.prompts.filter { $0.gadget == .computer }.map { $0.name }
        XCTAssertEqual(names, ["computer_click_by_label", "computer_describe_screen"])
    }
}

// MARK: runner (Nacho's path)

final class ComputerGadgetRunnerTests: XCTestCase {
    private var backend = FakeBackend()
    private var access = FakeElementAccess(sampleWindow())
    private var stopped = false
    private var attached: [ComputerImageAttachment] = []
    private var attachRefusal: String?
    private var guardian = FakeSelfGuard()
    private var runner: ComputerGadgetRunner!

    override func setUp() {
        backend = FakeBackend(); access = FakeElementAccess(sampleWindow()); stopped = false; attached = []; attachRefusal = nil
        guardian = FakeSelfGuard()
        runner = ComputerGadgetRunner(backend: backend, elements: access, emergencyStopped: { [unowned self] in self.stopped },
                                      attach: { [unowned self] in self.attached.append($0); return self.attachRefusal },
                                      selfGuard: guardian, now: { Date(timeIntervalSince1970: 1_794_000_000) })
    }

    func testTreeAnswerCarriesBoundedNodesWithIds() {
        let out = answer(runner, tool("ui_tree"), ["maxNodes": .int(5), "app": .string("Notes")])
        XCTAssertTrue(out.ok, out.message)
        XCTAssertEqual(nodes(out).count, 5)
        XCTAssertEqual(out.details?["truncated"] as? Bool, true)
        XCTAssertEqual((out.details?["app"] as? [String: Any])?["pid"] as? Int, 812)
        XCTAssertTrue((nodes(out).first?["id"] as? String)?.hasPrefix("t") == true)
        XCTAssertEqual(access.targets.last, UITreeTarget(pid: nil, app: "Notes", scope: .window))
        XCTAssertTrue(backend.calls.isEmpty, "reading never injects input")
    }

    func testFindThenClickByIdClicksTheMiddleOfTheElement() throws {
        let found = answer(runner, tool("find_element"), ["role": .string("button"), "title": .string("새로운")])
        XCTAssertTrue(found.ok, found.message)
        let id = try XCTUnwrap(nodes(found).first?["id"] as? String)
        let click = answer(runner, tool("click_element"), ["id": .string(id)])
        XCTAssertTrue(click.ok, click.message)
        XCTAssertEqual(backend.calls.map { $0.tool }, ["mouse_click"])
        XCTAssertEqual(backend.calls.first?.arguments["x"], .double(120))
        XCTAssertEqual(backend.calls.first?.arguments["y"], .double(50))
        // press runs the default action instead of a mouse click.
        XCTAssertTrue(answer(runner, tool("click_element"), ["id": .string(id), "press": .bool(true)]).ok)
        XCTAssertEqual(access.pressed.count, 1)
        XCTAssertEqual(backend.calls.count, 1)
        // A disabled element, an unknown id: nothing is clicked.
        let disabled = answer(runner, tool("find_element"), ["title": .string("Delete")])
        let did = try XCTUnwrap(nodes(disabled).first?["id"] as? String)
        XCTAssertFalse(answer(runner, tool("click_element"), ["id": .string(did)]).ok)
        let stale = answer(runner, tool("click_element"), ["id": .string("t99.1")])
        XCTAssertFalse(stale.ok)
        XCTAssertEqual(stale.details?["reason"] as? String, "stale_element")
        XCTAssertEqual(backend.calls.count, 1)
    }

    func testClickByCoordinatesAndArgumentRules() {
        XCTAssertTrue(answer(runner, tool("click_element"), ["x": .int(300), "y": .double(200.5)]).ok)
        XCTAssertEqual(backend.calls.last?.arguments["x"], .double(300))
        for bad: [String: JSONValue] in [[:], ["x": .int(1)], ["id": .string("t1.1"), "x": .int(1), "y": .int(1)],
                                         ["x": .int(1), "y": .int(1), "press": .bool(true)]] {
            let out = answer(runner, tool("click_element"), bad)
            XCTAssertFalse(out.ok, "\(bad)")
            XCTAssertTrue(out.message.hasPrefix("bad parameters"), out.message)
        }
        XCTAssertEqual(backend.calls.count, 1)
        XCTAssertFalse(answer(runner, tool("find_element"), [:]).ok, "find needs role or title")
        XCTAssertFalse(answer(runner, tool("ui_tree"), ["pid": .int(1), "app": .string("Notes")]).ok, "pid or app, not both")
        let missing = answer(runner, tool("ui_tree"), ["app": .string("Missing")])
        XCTAssertFalse(missing.ok)
        XCTAssertEqual(missing.message, "Running app not found")
    }

    func testArgumentsAreCheckedAgainstTheClosedSchema() {
        let cases: [(String, [String: JSONValue], String)] = [
            ("ui_tree", ["depth": .int(3)], "unknown field depth"),
            ("ui_tree", ["maxNodes": .int(9999)], "maxNodes must be at most 500"),
            ("ui_tree", ["maxDepth": .string("3")], "maxDepth must be an integer"),
            ("ui_tree", ["scope": .string("screen")], "scope must be one of window, app"),
            ("find_element", ["title": .string(String(repeating: "a", count: 101))], "title must have at most 100 characters"),
            ("click_element", ["clickCount": .int(4), "x": .int(1), "y": .int(1)], "clickCount must be at most 3"),
            ("click_element", ["x": .string("1"), "y": .int(1)], "x must be a finite number"),
            ("mouse_click", ["x": .int(1)], "y is required"),
            ("mouse_click", ["x": .int(1), "y": .int(1), "button": .string("thumb")], "button must be one of"),
            ("type_text", ["text": .int(5)], "text must be a string"),
            ("key_press", ["key": .string("c"), "modifiers": .array([.int(1)])], "modifiers must be an array of strings"),
            ("screen_capture", ["target": .string("display"), "format": .string("jpg")], "unknown field format"),
        ]
        for (action, args, expected) in cases {
            let out = answer(runner, tool(action), args)
            XCTAssertFalse(out.ok, action)
            XCTAssertTrue(out.message.contains(expected), "\(action): \(out.message)")
        }
        XCTAssertTrue(backend.calls.isEmpty, "nothing ran")
        XCTAssertTrue(answer(runner, tool("mouse_click"), ["x": .int(1), "y": .double(2), "button": .string("right")]).ok)
    }

    func testEmergencyStopRefusesEveryCallAtOnceAndTheWaitingOnes() {
        stopped = true
        for (action, args) in [("ui_tree", [:]), ("click_element", ["x": .int(1), "y": .int(1)]), ("type_text", ["text": .string("x")]),
                               ("screen_capture", ["target": .string("display")])] as [(String, [String: JSONValue])] {
            let out = answer(runner, tool(action), args)
            XCTAssertFalse(out.ok)
            XCTAssertEqual(out.details?["reason"] as? String, "emergency_stop", action)
        }
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertTrue(access.targets.isEmpty)
        // A call that was waiting in the queue when the stop came is refused when its turn comes.
        stopped = false
        let gate = DispatchQueue(label: "gate")
        let blocked = ComputerGadgetRunner(backend: backend, elements: access, emergencyStopped: { [unowned self] in self.stopped },
                                           attach: nil, queue: gate)
        let hold = DispatchSemaphore(value: 0)
        gate.async { hold.wait() }
        let sem = DispatchSemaphore(value: 0)
        var late: PetCommandOutcome?
        blocked.run(tool("mouse_click"), arguments: ["x": .int(5), "y": .int(5)]) { late = $0; sem.signal() }
        stopped = true
        hold.signal()
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(late?.details?["reason"] as? String, "emergency_stop")
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testHighRiskToolsNeverRunHereEvenIfAsked() {
        for old in ["shell_run", "applescript_run", "file_read", "file_write", "process_kill", "app_quit", "clipboard_read"] {
            let t = tools.first { $0.legacyMCPName == old }!
            let out = answer(runner, t, [:])
            XCTAssertFalse(out.ok, old)
            XCTAssertTrue(out.message.contains("not offered to Nacho"), out.message)
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testScreenshotIsAttachedToTheChatNotSentAsText() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        backend.result = ToolResult(content: [.image(base64: png.base64EncodedString(), mimeType: "image/png"),
                                              .text("1568x980 pixels (original 3136x1960)")])
        let out = answer(runner, tool("screen_capture"), ["target": .string("display")])
        XCTAssertTrue(out.ok, out.message)
        XCTAssertEqual(attached, [ComputerImageAttachment(name: "screen-20261106-212000.png", mime: "image/png", data: png)])
        XCTAssertEqual(out.details?["delivered"] as? String, "chat_attachment")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: out.resultJSON), as: UTF8.self)
        XCTAssertFalse(json.contains(png.base64EncodedString()), "no image bytes in the text result")
        XCTAssertTrue(out.message.contains("next message"))
        attachRefusal = "한 번에 붙일 수 있는 파일은 5개까지예요."
        let full = answer(runner, tool("screen_capture"), ["target": .string("display")])
        XCTAssertFalse(full.ok)
        XCTAssertEqual(full.details?["reason"] as? String, "attach_failed")
        let noChat = ComputerGadgetRunner(backend: backend, elements: nil, emergencyStopped: { false }, attach: nil)
        XCTAssertFalse(answer(noChat, tool("screen_capture"), ["target": .string("display")]).ok)
        XCTAssertEqual(answer(noChat, tool("ui_tree"), [:]).details?["reason"] as? String, "unavailable")
    }

    func testBackendResultsBecomeConnectorOutcomes() {
        backend.result = .text(#"{"displays":[{"displayId":1,"main":true}]}"#)
        let displays = answer(runner, tool("screen_list_displays"), [:])
        XCTAssertTrue(displays.ok)
        XCTAssertEqual((displays.details?["displays"] as? [[String: Any]])?.count, 1)
        backend.result = .error("Accessibility permission is missing.")
        let failed = answer(runner, tool("key_press"), ["key": .string("c"), "modifiers": .array([.string("cmd")])])
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "Accessibility permission is missing.")
    }

    func testInputNeverLandsInNachoCombosOwnWindows() {
        guardian.ownRect = UIRect(x: 1000, y: 500, width: 380, height: 540)   // the chat with its approval card
        for (action, args) in [("mouse_click", ["x": .int(1100), "y": .int(600)]),
                               ("mouse_drag", ["fromX": .int(10), "fromY": .int(10), "toX": .int(1100), "toY": .int(600)]),
                               ("click_element", ["x": .int(1100), "y": .int(600)])] as [(String, [String: JSONValue])] {
            let out = answer(runner, tool(action), args)
            XCTAssertFalse(out.ok, action)
            XCTAssertEqual(out.details?["reason"] as? String, "own_window", action)
        }
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertTrue(answer(runner, tool("mouse_click"), ["x": .int(10), "y": .int(10)]).ok, "elsewhere is fine")
        guardian.keyboardStaysWithUs = true
        let typed = answer(runner, tool("type_text"), ["text": .string("hello")])
        XCTAssertFalse(typed.ok)
        XCTAssertEqual(typed.details?["reason"] as? String, "own_window")
        XCTAssertFalse(answer(runner, tool("key_press"), ["key": .string("return")]).ok, "Return would send the chat or press a card")
        XCTAssertEqual(backend.calls.count, 1)
        guardian.keyboardStaysWithUs = false
        XCTAssertTrue(answer(runner, tool("type_text"), ["text": .string("hello")]).ok)
        XCTAssertEqual(guardian.released, 3)
    }
}

// MARK: both exits, end to end

final class ComputerUseExitTests: XCTestCase {
    private func object(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    /// Nacho: hello declares the tools with approval, a request runs through the dispatcher and the runner.
    func testConnectorDeclaresAndRunsTheTreeTool() {
        let factory = PetTransportFactory()
        let backend = FakeBackend()
        var stopped = false
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(ComputerGadgetRunner(backend: backend, elements: FakeElementAccess(sampleWindow()),
                                                 emergencyStopped: { stopped }, attach: nil), for: [.computer])
        let trust = GadgetTrust(trustable: { [.computer] })
        let client = PetConnectorClient(url: URL(string: "ws://127.0.0.1:8787/ws/connector")!, token: "nct_abc", executor: PetRecordingExecutor(),
                                        makeTransport: factory.make, schedule: { _, _ in }, trust: trust, dispatcher: dispatcher)
        client.connect(); client.flush()
        let t = factory.with(path: "/ws/connector")[0]
        t.handler?(.opened); client.flush()
        t.deliver(#"{"type":"ready","agent_id":"a"}"#); client.flush()
        let hello = object(t.sent[0])
        let caps = (hello["capabilities"] as? [[String: Any]]) ?? []
        let tree = caps.first { $0["name"] as? String == "combo_computer_ui_tree" }
        XCTAssertEqual(tree?["approval"] as? String, "required")
        XCTAssertNil(caps.first { ($0["name"] as? String)?.contains("shell") == true })

        func request(_ id: String, _ capability: String, _ params: String) -> [String: Any] {
            t.deliver(#"{"type":"request","id":"\#(id)","capability":"\#(capability)","params":\#(params)}"#)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                client.flush()
                if let r = t.sent.map(object).last(where: { $0["id"] as? String == id }) { return r }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return [:]
        }
        let r = request("r1", "combo_computer_ui_tree", #"{"maxNodes":3}"#)["result"] as? [String: Any]
        XCTAssertEqual(r?["ok"] as? Bool, true)
        XCTAssertEqual((r?["nodes"] as? [[String: Any]])?.count, 3)
        stopped = true
        let s = request("r2", "combo_computer_mouse_click", #"{"x":1,"y":1}"#)["result"] as? [String: Any]
        XCTAssertEqual(s?["reason"] as? String, "emergency_stop")
        let shell = request("r3", "combo_computer_shell_run", #"{"command":"ls"}"#)
        XCTAssertNotNil(shell["error"], "an undeclared high-risk tool is an unknown capability")
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertFalse(client.handled.joined().contains("maxNodes"), "the log keeps names only")
    }

    /// MCP: `computer_ui_tree` and `screen_capture` round trip, printed with the key and the contents masked.
    func testMCPRoundTripLog() throws {
        var settings = ComputerUseSettings()
        settings.setEnabled(.appsWindows, true)
        settings.setEnabled(.screen, true)
        let backend = FakeBackend()
        backend.result = ToolResult(content: [.image(base64: Data([1, 2, 3, 4]).base64EncodedString(), mimeType: "image/png"),
                                              .text("1568x980 pixels (original 3136x1960)")])
        let keys = APIKeyStore(url: nil, random: CountingRandom())
        let token = try keys.create(label: "Test Key").token
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(ComputerGadgetRunner(backend: backend, elements: FakeElementAccess(sampleWindow()),
                                                 emergencyStopped: { false }, attach: nil), for: [.computer])
        let service = NachoComboMCPService(settings: { settings }, keys: keys, backend: backend, gadgets: dispatcher)
        var log: [String] = []
        func rpc(_ id: Int, _ method: String, _ params: String) -> [String: Any] {
            let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
            let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                               body: Data(body.utf8)), peer: "127.0.0.1")
            let o = object(String(decoding: r.body, as: UTF8.self))
            log.append("> \(method) \(params)")
            log.append("< \(r.status) \(ComputerUseExitTests.masked(o))")
            return o
        }
        _ = rpc(1, "initialize", #"{"protocolVersion":"2025-06-18"}"#)
        let list = rpc(2, "tools/list", "{}")
        let names = (((list["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("computer_ui_tree") && names.contains("computer_find_element") && names.contains("computer_screen_capture"))
        XCTAssertFalse(names.contains("computer_click_element"), "input group is off")
        let tree = rpc(3, "tools/call", #"{"name":"computer_ui_tree","arguments":{"maxNodes":4}}"#)
        let treeResult = try XCTUnwrap(tree["result"] as? [String: Any])
        XCTAssertEqual(treeResult["isError"] as? Bool, false)
        let text = ((treeResult["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertEqual((object(text)["nodes"] as? [[String: Any]])?.count, 4)
        let shot = rpc(4, "tools/call", #"{"name":"screen_capture","arguments":{"target":"display"}}"#)
        let content = ((shot["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
        XCTAssertEqual(content.first?["type"] as? String, "image", "MCP clients still get the PNG itself")
        XCTAssertEqual(backend.calls.map { $0.tool }, ["screen_capture"])
        let printed = log.joined(separator: "\n")
        XCTAssertFalse(printed.contains(token))
        XCTAssertFalse(printed.contains("메모 1"), "screen texts are masked in the log")
        XCTAssertFalse(printed.contains(Data([1, 2, 3, 4]).base64EncodedString()))
        print("MCP-ROUNDTRIP computer (Authorization: Bearer ****, texts and image data masked)\n" + printed)
    }

    /// Replaces every string value inside tool results (titles, values, image data) by its length.
    static func masked(_ o: [String: Any]) -> String {
        func mask(_ v: Any, _ key: String) -> Any {
            switch v {
            case let d as [String: Any]: return d.reduce(into: [String: Any]()) { $0[$1.key] = mask($1.value, $1.key) }
            case let a as [Any]: return a.map { mask($0, key) }
            case let s as String:
                if key == "text", let inner = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                    return mask(inner, "")
                }
                return ["id", "role", "subrole", "type", "mimeType", "name", "scope", "protocolVersion"].contains(key) ? s : "<\(s.count) chars>"
            default: return v
            }
        }
        let m = mask(o, "")
        let data = (try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys])) ?? Data()
        let s = String(decoding: data, as: UTF8.self)
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }
}
