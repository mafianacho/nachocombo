import XCTest
@testable import NachoComboCore

/// NACHO-152 (QA of NACHO-144): JSON-RPC round trips through the real NachoComboMCPService for what the lane tests do not
/// reach: the desktop tidy tools (NACHO-38 / PR #42) and "server on, Computer Use gadget off". The key is masked in the
/// printed log; no file names or contents are printed.
final class McpRoundTripQATests: XCTestCase {
    private final class FakeHost: DesktopTidyHost {
        func windowApps(done: @escaping ([String]?) -> Void) { done(["Safari", "Notes", "Terminal", "Mail"]) }
        func arrange(apps: [String], arrangement: String, done: @escaping (PetCommandOutcome) -> Void) {
            done(PetCommandOutcome(ok: true, message: "Arranged"))
        }
    }

    private let fm = FileManager.default
    private var root: URL!
    private var log: [String] = []

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("qa-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Desktop", isDirectory: true), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func makeService(settings: ComputerUseSettings, backend: ComputerUseBackend = FakeBackend(),
                             dispatcher: GadgetToolDispatcher = GadgetToolDispatcher()) throws -> (NachoComboMCPService, String) {
        let keys = APIKeyStore(url: nil, random: CountingRandom())
        let token = try keys.create(label: "QA Key").token
        let service = NachoComboMCPService(settings: { settings }, keys: keys, backend: backend, gadgets: dispatcher)
        return (service, token)
    }

    private func rpc(_ service: NachoComboMCPService, _ token: String, _ id: Int, _ method: String, _ params: String = "{}") -> (status: Int, json: [String: Any]) {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                           body: Data(body.utf8)), peer: "127.0.0.1")
        let text = String(decoding: r.body, as: UTF8.self)
        log.append("> \(method) \(params)")
        log.append("< \(r.status) \(text.count > 200 ? String(text.prefix(200)) + "…" : text)")
        return (r.status, (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:])
    }

    private func toolNames(_ o: [String: Any]) -> [String] {
        ((o["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    private func isRefused(_ o: [String: Any]) -> Bool {
        if o["error"] != nil { return true }
        return (o["result"] as? [String: Any])?["isError"] as? Bool == true
    }

    /// Desktop gadget switch on: the three read/propose tools are listed and callable; apply/undo are neither listed nor callable.
    func testDesktopTidyToolsThroughTheMCPService() throws {
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        for n in ["a.png", "b.pdf"] { try Data("x".utf8).write(to: desktop.appendingPathComponent(n)) }
        let engine = DesktopTidyEngine(desktop: desktop, journalURL: root.appendingPathComponent("journal.json"))
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(DesktopToolRunner(engine: engine, host: FakeHost()), for: DesktopToolRunner.gadgets)
        var settings = ComputerUseSettings()
        settings.serverEnabled = true
        settings.setGadgetEnabled(.desktop, true)
        let (service, token) = try makeService(settings: settings, dispatcher: dispatcher)

        _ = rpc(service, token, 1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"qa","version":"1"}}"#)
        let names = toolNames(rpc(service, token, 2, "tools/list").json)
        for n in ["desktop_tidy_plan", "desktop_arrange_suggest", "desktop_tidy_history"] { XCTAssertTrue(names.contains(n), n) }
        for n in ["desktop_tidy_apply", "desktop_tidy_undo", "desktop_arrange_apply"] { XCTAssertFalse(names.contains(n), "\(n) is Nacho's only") }
        XCTAssertFalse(rpc(service, token, 3, "resources/read", #"{"uri":"nachocombo://gadgets/desktop/guide"}"#).json.isEmpty)

        for (i, n) in ["desktop_tidy_plan", "desktop_arrange_suggest", "desktop_tidy_history"].enumerated() {
            let o = rpc(service, token, 10 + i, "tools/call", #"{"name":"\#(n)","arguments":{}}"#).json
            XCTAssertNotNil(o["result"], "\(n) answers with a result")
            XCTAssertFalse(isRefused(o), n)
        }
        for (i, n) in ["desktop_tidy_apply", "desktop_tidy_undo", "desktop_arrange_apply"].enumerated() {
            let o = rpc(service, token, 20 + i, "tools/call", #"{"name":"\#(n)","arguments":{"plan_id":"x"}}"#).json
            XCTAssertTrue(isRefused(o), "\(n) is refused on the MCP exit")
        }
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("a.png").path), "nothing was moved by the round trip")
        let text = log.joined(separator: "\n")
        XCTAssertFalse(text.contains(token))
        print("MCP-ROUNDTRIP-NACHO-152-DESKTOP (Authorization: Bearer ****)\n" + text)
    }

    /// Server on, Computer Use gadget off (NACHO-195): no computer tools in the list, the call is refused, the key is still checked;
    /// the same call with the group on works.
    func testServerOnWithTheComputerUseGadgetOff() throws {
        var s = ComputerUseSettings()
        s.serverEnabled = true
        s.setEnabled(.screen, true)
        let backend = FakeBackend()
        let (off, offToken) = try makeService(settings: s.withoutComputerGroups(), backend: backend)
        let names = toolNames(rpc(off, offToken, 1, "tools/list").json)
        XCTAssertFalse(names.contains { $0.hasPrefix("computer_") || $0 == "screen_capture" }, "no computer tools while the gadget is off")
        let denied = rpc(off, offToken, 2, "tools/call", #"{"name":"screen_capture","arguments":{"target":"display"}}"#).json
        XCTAssertTrue(isRefused(denied))
        XCTAssertTrue(backend.calls.isEmpty, "the backend was never reached")
        XCTAssertEqual(rpc(off, "wrong-key", 3, "tools/list").status, 401, "wrong key")
        let noKey = off.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653"], body: Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#.utf8)), peer: "127.0.0.1")
        XCTAssertEqual(noKey.status, 401, "no key")

        let (on, onToken) = try makeService(settings: s, backend: backend)
        let ok = rpc(on, onToken, 5, "tools/call", #"{"name":"screen_capture","arguments":{"target":"display"}}"#).json
        XCTAssertFalse(isRefused(ok), "with the group on the call reaches the backend")
        XCTAssertEqual(backend.calls.count, 1)
        let text = log.joined(separator: "\n")
        XCTAssertFalse(text.contains(offToken) || text.contains(onToken))
        print("MCP-ROUNDTRIP-NACHO-152-COMPUTER-OFF (Authorization: Bearer ****)\n" + text)
    }

    /// Always-allow never lifts the approval of destructive tools; content tools lose it only with the gadget's switch.
    func testApprovalDeclarationWithAndWithoutAlwaysAllow() {
        func approval(_ allowed: Set<GadgetID>, _ name: String) -> String? {
            let caps = PetCommands.capabilities(allowQuit: true, alwaysAllowed: allowed, disabled: [])
            return caps.first { $0["name"] as? String == name }?["approval"] as? String
        }
        for allowed: Set<GadgetID> in [[], [.shelf, .clipboard, .desktop]] {
            XCTAssertEqual(approval(allowed, "combo_clear_shelf"), "required", "destructive: always, allowed=\(allowed.count)")
            XCTAssertEqual(approval(allowed, "combo_desktop_tidy_apply"), "required")
            XCTAssertNil(approval(allowed, "combo_monitor_stats"), "read runs at once")
        }
        XCTAssertEqual(approval([], "combo_clipboard_get_item"), "required")
        XCTAssertNil(approval([.clipboard], "combo_clipboard_get_item"), "content tool: the gadget's always-allow lifts it")
    }
}
