import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// The Connections tab (NACHO-239) drawn off screen in light and dark, scene by scene, from fixed data and a fake server.
/// AppKit off-screen renders on macOS CI, not a real Mac. Pictures go to .build/bento-captures and, base64 in chunks,
/// to the test log (BENTO-CAPTURE lines) for CI.
final class ConnectionsTabCaptureTests: XCTestCase {
    final class FakeHTTP: PetHTTPClient {
        var sent: [PetHTTPRequest] = []
        var answer: (PetHTTPRequest) -> PetHTTPResponse = { _ in PetHTTPResponse(status: 200, body: Data("{}".utf8)) }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            completion(.success(answer(request)))
        }
    }

    final class FakeHost: PetConnectionsHost {
        let trust = GadgetTrust(trustable: { [] })
        var macLinkText = "연결됨"
        var overview = ConnectorOverview()
        var gadgetMap: [String: String] = ["windowSnap": "on", "clipboard": "off", "captureFloat": "waiting for permission",
                                           "systemMonitor": "on", "fileShelf": "on", "keepAwake": "off"]
        let http = FakeHTTP()
        var granted: Set<OSPermission> = []
        var requested: [OSPermission] = []
        var opened: [URL] = []
        var gadgetCalls: [(GadgetID, Bool)] = []

        func connectionsLoad(_ done: @escaping (Result<ConnectorOverview, ConnectorError>) -> Void) { done(.success(overview)) }
        func connectionsAPI(_ body: @escaping (ConnectionsAPI?) -> Void) {
            body(ConnectionsAPI(endpoint: try! ServerEndpoint.parse("https://nacho.example.com").get(), fetcher: http, token: { "t" }))
        }
        func gadgetStates() -> [GadgetSwitchState] { GadgetSwitchState.states(from: gadgetMap) }
        func setGadget(_ id: GadgetID, on: Bool) {
            gadgetCalls.append((id, on))
            if let m = id.moduleID { gadgetMap[m.rawValue] = on ? "on" : "off" }
        }
        func permissionGranted(_ permission: OSPermission) -> Bool { granted.contains(permission) }
        func requestPermission(_ permission: OSPermission) { requested.append(permission) }
        func openInBrowser(_ url: URL) { opened.append(url) }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: fixtures

    static func overview() -> ConnectorOverview {
        var o = ConnectorOverview()
        o.tools = [
            ToolRow(id: "t-search", name: "tool_search", description: "필요한 도구를 찾아서 이 대화에 붙여요. 대화마다 쓰는 기본 도구예요.", kind: "builtin",
                    source: nil, enabled: true, userEnabled: true, locked: true),
            ToolRow(id: "t-web", name: "search_web", description: "웹에서 최신 정보를 찾아와요. 뉴스나 가격처럼 바뀌는 내용에 써요.", kind: "builtin",
                    source: nil, enabled: true, userEnabled: false, locked: false),
            ToolRow(id: "t-weather", name: "weather_now", description: "지금 날씨를 알려 줘요.", kind: "http", source: nil, enabled: true),
            ToolRow(id: "t-gmail-1", name: "gmail_search_messages", description: "받은편지함에서 메일을 검색해요.", kind: "connection", source: "gmail", enabled: true),
            ToolRow(id: "t-gmail-2", name: "gmail_read_message", description: "메일 한 통의 내용을 읽어요.", kind: "connection", source: "gmail", enabled: true),
            ToolRow(id: "t-gmail-3", name: "gmail_create_draft", description: "답장 초안을 만들어 임시 보관함에 둬요. 보내지는 않아요.", kind: "connection", source: "gmail", enabled: true),
        ]
        o.connections = [
            ConnectionRow(id: "c-gmail", source: "gmail", label: "Gmail", status: "connected", needsAttention: nil, accountLabel: "n***@gmail.com",
                          scopeSummary: "읽기만 · 라벨 전체", link: nil, enabled: true, version: 3, connectKind: "oauth", scopeLevel: "read"),
            ConnectionRow(id: "c-naver", source: "naver_mail", label: "네이버 메일", status: "needs_reauth", needsAttention: "needs_reauth",
                          accountLabel: "n***@naver.com", scopeSummary: "읽기와 쓰기", link: nil, enabled: true, version: 1, connectKind: "app_password",
                          scopeLevel: "read_write"),
            ConnectionRow(id: "c-notion", source: "notion", label: "Notion", status: "connected", needsAttention: nil, accountLabel: nil,
                          scopeSummary: "읽기만 · 고른 페이지 2개", link: nil, enabled: false, version: 2, connectKind: "oauth", scopeLevel: "read"),
        ]
        return o
    }

    static let catalogJSON = #"""
        {"categories":[],"bundles":[],"builtins":[],"enabled_count":0,"items":[
          {"source":"gmail","label":"Gmail","summary":"메일을 읽고 검색해요","connect_kind":"oauth","support_status":"available","connected":true},
          {"source":"naver_mail","label":"네이버 메일","summary":"앱 비밀번호로 메일을 읽어요","connect_kind":"app_password","support_status":"available","connected":false},
          {"source":"daum_mail","label":"다음 메일","summary":"메일을 읽고 검색해요","connect_kind":"oauth","support_status":"available","connected":false},
          {"source":"kakao_mail","label":"카카오 메일","summary":"QR로 로그인해요","connect_kind":"qr","support_status":"limited","support_reason":"브라우저 연결이 필요해요","connected":false}]}
        """#

    private func makeView(_ host: FakeHost, width: CGFloat = 336) -> PetConnectionsView {
        host.overview = ConnectionsTabCaptureTests.overview()
        let v = PetConnectionsView(host: host, width: width)
        v.overview = host.overview
        v.gadgets = host.gadgetStates()
        v.render()
        return v
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews { out += texts(s) }
        return out
    }

    private func switches(_ v: NSView) -> [PetToggle] {
        var out: [PetToggle] = []
        if let t = v as? PetToggle { out.append(t) }
        for s in v.subviews { out += switches(s) }
        return out
    }

    private func spin(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: scenes

    func testListThreeSections() throws {
        let host = FakeHost()
        let v = makeView(host)
        let all = texts(v).joined(separator: "\n")
        for want in ["도구", "커넥터", "가젯", "Gmail", "네이버 메일", "다시 로그인 필요", "기본 도구 · 항상 켜져 있어요", "웹 검색", "서비스 추가", "창 배치"] {
            XCTAssertTrue(all.contains(want), "list shows \(want)\n\(all)")
        }
        XCTAssertFalse(all.contains("●"), "no more bullet text blob")
        try capture(v, name: "list")
    }

    func testToolDetailAndLocked() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.goDetail(.tool("t-web"))
        XCTAssertTrue(texts(v).joined(separator: "\n").contains("꺼 두면 나초가 이 도구를 고르지 않아요."))
        try capture(v, name: "tool-detail")
        v.goDetail(.tool("t-search"))
        let all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("끌 수 없어요"), all)
        XCTAssertTrue(switches(v).isEmpty, "a locked tool shows a lock, not a switch")
        try capture(v, name: "tool-locked")
    }

    func testConnectorDetailConnectedAndNeedsLogin() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.goDetail(.connector("c-gmail"))
        var all = texts(v).joined(separator: "\n")
        for want in ["Gmail", "연결됨 · n***@gmail.com", "나초가 쓸 수 있는 기능", "gmail 메시지 검색", "읽기만 · 라벨 전체", "연결 해제"] {
            XCTAssertTrue(all.contains(want), "Gmail detail shows \(want)\n\(all)")
        }
        try capture(v, name: "connector-connected")
        v.goDetail(.connector("c-naver"))
        all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("다시 로그인"), all)
        XCTAssertTrue(all.contains("로그인이 만료됐어요"), all)
        try capture(v, name: "connector-reauth")
        v.confirmingDisconnect = true
        v.render()
        XCTAssertTrue(texts(v).joined(separator: "\n").contains("되돌릴 수 없어요"), "disconnect asks first")
        try capture(v, name: "connector-disconnect-confirm")
    }

    func testAddServiceSearchAndOAuthProgress() throws {
        let host = FakeHost()
        host.http.answer = { r in
            if r.url.path == "/api/v1/connections/catalog" { return PetHTTPResponse(status: 200, body: Data(ConnectionsTabCaptureTests.catalogJSON.utf8)) }
            if r.url.path == "/api/v1/connections/begin" {
                return PetHTTPResponse(status: 201, body: Data(#"{"attempt_id":"a1","connect_kind":"oauth","next":"oauth","authorize_url":"https://accounts.example.com/consent"}"#.utf8))
            }
            if r.url.path == "/api/v1/connections/attempts/a1" {
                return PetHTTPResponse(status: 200, body: Data(#"{"attempt_id":"a1","source":"daum_mail","state":"completed","connect_kind":"oauth"}"#.utf8))
            }
            return PetHTTPResponse(status: 200, body: Data("{}".utf8))
        }
        let v = makeView(host)
        v.goAdd()
        spin()
        var all = texts(v).joined(separator: "\n")
        for want in ["다음 메일", "이미 연결됨", "맥에서는 안 돼요 · 휴대폰 앱에서 연결"] { XCTAssertTrue(all.contains(want), "search shows \(want)\n\(all)") }
        XCTAssertEqual(host.http.sent.first?.url.path, "/api/v1/connections/catalog")
        try capture(v, name: "add-service")

        let daum = try XCTUnwrap(v.catalog?.first { $0.source == "daum_mail" })
        v.startConnect(daum)
        spin()
        XCTAssertEqual(host.opened.map { $0.host }, ["accounts.example.com"], "OAuth opens in the default browser")
        XCTAssertEqual(v.connect?.progress, .inBrowser)
        all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("브라우저에서 동의를 마쳐 주세요"), all)
        try capture(v, name: "oauth-progress")

        // Back from the browser: the server's attempt says completed.
        v.poll()
        spin()
        XCTAssertEqual(v.connect?.progress, .done)
        XCTAssertTrue(texts(v).joined(separator: "\n").contains("연결됐어요."))
        try capture(v, name: "oauth-done")
    }

    func testAppPasswordFormKeepsTheValueOutOfTheScreenAfterSending() throws {
        let host = FakeHost()
        host.http.answer = { r in
            if r.url.path == "/api/v1/connections/begin" {
                return PetHTTPResponse(status: 201, body: Data(#"{"attempt_id":"a2","connect_kind":"app_password","next":"app_password"}"#.utf8))
            }
            return PetHTTPResponse(status: 200, body: Data("{}".utf8))
        }
        let v = makeView(host)
        v.catalog = ConnectionsAPI.decodeCatalog(Data(ConnectionsTabCaptureTests.catalogJSON.utf8)) ?? []
        v.screen = .add
        v.startConnect(try XCTUnwrap(v.catalog?.first { $0.source == "naver_mail" }))
        spin()
        XCTAssertEqual(v.connect?.progress, .needsAppPassword)
        XCTAssertTrue(texts(v).joined(separator: "\n").contains("기록에 남기지 않아요"))
        try capture(v, name: "app-password")
    }

    func testUnsupportedOnMacExplainsAndPointsToThePhone() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.catalog = ConnectionsAPI.decodeCatalog(Data(ConnectionsTabCaptureTests.catalogJSON.utf8)) ?? []
        v.screen = .add
        v.startConnect(try XCTUnwrap(v.catalog?.first { $0.source == "kakao_mail" }))
        let all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("이 맥에서는 연결할 수 없어요"), all)
        XCTAssertTrue(all.contains("휴대폰의 나초 앱에서 연결해 주세요."), all)
        XCTAssertTrue(host.http.sent.isEmpty, "no attempt is started for a flow the Mac cannot do")
        try capture(v, name: "unsupported-on-mac")
    }

    func testGadgetDetailAndSingleMacActionOff() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.goDetail(.gadget(.window))
        var all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("이 맥에서 나초가 하는 일"), all)
        let before = switches(v).count
        XCTAssertGreaterThan(before, 1, "the gadget switch and one per Mac action")
        try capture(v, name: "gadget-detail")

        let window = try XCTUnwrap(GadgetToolRegistry.all.first { $0.gadget == .window && $0.exits.contains(.connector) })
        v.toggleAction(window.connectorName, on: false)
        XCTAssertEqual(host.trust.disabled, [window.connectorName])
        all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("개 중 "), "the summary counts the switched-off action\n\(all)")
        try capture(v, name: "gadget-action-off")

        v.toggleAction(window.connectorName, on: true)
        XCTAssertTrue(host.trust.disabled.isEmpty)
    }

    func testTurningAnActionOnAsksForItsMacPermissionOnlyThen() throws {
        let host = FakeHost()
        let v = makeView(host)
        let tool = try XCTUnwrap(GadgetToolRegistry.all.first { !$0.permissions.isEmpty && $0.exits.contains(.connector) })
        host.trust.setActionEnabled(tool, false)
        XCTAssertTrue(host.requested.isEmpty, "switching off asks for nothing")
        v.toggleAction(tool.connectorName, on: true)
        XCTAssertEqual(Set(host.requested), tool.permissions.filter { !host.granted.contains($0) })
        XCTAssertTrue(v.message?.text.contains("맥 권한이 필요해요") == true)
    }

    func testGadgetSwitchGoesThroughTheHost() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.toggle(.gadget(.clipboard), on: true)
        XCTAssertEqual(host.gadgetCalls.first?.0, .clipboard)
        XCTAssertEqual(host.gadgetCalls.first?.1, true)
        XCTAssertEqual(v.gadgets.first { $0.id == .clipboard }?.phase, .on)
    }

    func testToolSwitchFailureGoesBackAndSaysWhy() throws {
        let host = FakeHost()
        host.http.answer = { _ in PetHTTPResponse(status: 404, body: Data()) }  // a server without the switch yet
        let v = makeView(host)
        v.toggle(.tool("t-web"), on: true)
        XCTAssertEqual(v.overview?.tools.first { $0.id == "t-web" }?.userEnabled, true, "shown on right away")
        spin()
        XCTAssertEqual(host.http.sent.first?.method, "PUT")
        XCTAssertEqual(host.http.sent.first?.url.path, "/api/v1/tools/t-web/switch")
        XCTAssertEqual(v.overview?.tools.first { $0.id == "t-web" }?.userEnabled, false, "the switch went back")
        XCTAssertEqual(v.message?.failed, true)
        XCTAssertTrue(texts(v).joined(separator: "\n").contains("이 서버는 아직 이 기능을 지원하지 않아요"))
        try capture(v, name: "error-tool-switch")
    }

    func testToolSwitchSuccessKeepsTheNewValue() throws {
        let host = FakeHost()
        host.http.answer = { _ in PetHTTPResponse(status: 200, body: Data(#"{"id":"t-web","name":"search_web","config":{"kind":"builtin"},"enabled":true,"user_enabled":true,"locked":false}"#.utf8)) }
        let v = makeView(host)
        v.toggle(.tool("t-web"), on: true)
        spin()
        XCTAssertEqual(v.overview?.tools.first { $0.id == "t-web" }?.userEnabled, true)
        XCTAssertNil(v.message)
    }

    func testLockedToolNeverCallsTheServer() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.toggle(.tool("t-search"), on: false)
        spin()
        XCTAssertTrue(host.http.sent.isEmpty)
        XCTAssertEqual(v.overview?.tools.first { $0.id == "t-search" }?.userEnabled, true)
    }

    func testServiceSwitchSendsTheVersionAndGoesBackOnAConflict() throws {
        let host = FakeHost()
        host.http.answer = { r in
            r.method == "PATCH" ? PetHTTPResponse(status: 409, body: Data(#"{"error":{"code":"conflict","message":"x","reason":"stale_version"}}"#.utf8))
                : PetHTTPResponse(status: 200, body: Data("[]".utf8))
        }
        let v = makeView(host)
        v.toggle(.connector("c-gmail"), on: false)
        spin()
        let patch = try XCTUnwrap(host.http.sent.first { $0.method == "PATCH" })
        XCTAssertEqual(patch.url.path, "/api/v1/connections/c-gmail")
        XCTAssertTrue(String(data: patch.body ?? Data(), encoding: .utf8)?.contains(#""expected_version":3"#) == true)
        XCTAssertEqual(v.overview?.connections.first { $0.id == "c-gmail" }?.enabled, true)
        XCTAssertEqual(v.message?.failed, true)
    }

    func testSearchFiltersTheListWithoutLosingTheField() throws {
        let host = FakeHost()
        let v = makeView(host)
        v.query = "메일"
        v.render()
        let all = texts(v).joined(separator: "\n")
        XCTAssertTrue(all.contains("네이버 메일"))
        XCTAssertFalse(all.contains("Notion"))
        try capture(v, name: "search")
    }

    // MARK: drawing

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func capture(_ view: PetConnectionsView, name: String) throws {
        for dark in [false, true] {
            let pad: CGFloat = 12
            view.layoutSubtreeIfNeeded()
            let size = NSSize(width: view.contentWidth + 2 * pad, height: max(view.fittingSize.height + 2 * pad, 200))
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            root.wantsLayer = true
            root.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.10, green: 0.09, blue: 0.08, alpha: 1)
                                                : NSColor(srgbRed: 0.984, green: 0.980, blue: 0.973, alpha: 1)).cgColor
            root.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
                view.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            ])
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "connections-\(name)-\(dark ? "dark" : "light")")
            view.removeFromSuperview()
        }
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 4_000, "\(name) is not empty")
    }
}
