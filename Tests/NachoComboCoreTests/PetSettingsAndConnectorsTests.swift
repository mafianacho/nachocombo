import XCTest
@testable import NachoComboCore

// Ported from nacho-gadget-app (PR #1 @1d685fa) Tests/SettingsAndConnectorsTests.swift; settings part rewritten
// for Nacho Combo (production default, login issuer). Class names carry a Pet prefix.

final class PetEndpointTests: XCTestCase {
    func testAcceptsHTTPSAndLoopbackHTTP() {
        XCTAssertEqual(try! ServerEndpoint.parse("https://nacho.example.com").get().base.absoluteString, "https://nacho.example.com")
        let l = try! ServerEndpoint.parse(" http://localhost:8787 ").get()
        XCTAssertEqual(l.webSocketURL.absoluteString, "ws://localhost:8787/ws/chat")
        XCTAssertEqual(try! ServerEndpoint.parse("https://a.b:8443/").get().webSocketURL.absoluteString, "wss://a.b:8443/ws/chat")
        XCTAssertEqual(try! ServerEndpoint.parse("https://a.b/").get().rest("/api/v1/tools").absoluteString, "https://a.b/api/v1/tools")
    }

    func testRejections() {
        XCTAssertEqual(ServerEndpoint.parse(""), .failure(.empty))
        XCTAssertEqual(ServerEndpoint.parse("   "), .failure(.empty))
        XCTAssertEqual(ServerEndpoint.parse("ftp://x.com"), .failure(.invalidScheme))
        XCTAssertEqual(ServerEndpoint.parse("javascript:alert(1)"), .failure(.invalidScheme))
        XCTAssertEqual(ServerEndpoint.parse("nacho.example.com"), .failure(.invalidScheme))
        XCTAssertEqual(ServerEndpoint.parse("https://"), .failure(.noHost))
        XCTAssertEqual(ServerEndpoint.parse("https://u:p@x.com"), .failure(.hasCredentials))
        XCTAssertEqual(ServerEndpoint.parse("https://x.com/?a=1"), .failure(.hasQueryOrFragment))
        XCTAssertEqual(ServerEndpoint.parse("https://x.com/#f"), .failure(.hasQueryOrFragment))
        XCTAssertEqual(ServerEndpoint.parse("http://example.com"), .failure(.plainHTTPNotLoopback))
        XCTAssertEqual(ServerEndpoint.parse("http://192.168.0.5:8787"), .failure(.plainHTTPNotLoopback))
        XCTAssertEqual(ServerEndpoint.parse("https://" + String(repeating: "a", count: 200) + ".com"), .failure(.tooLong))
        XCTAssertEqual(ServerEndpoint.parse("https://x.com:99999"), .failure(.noHost))
    }

    func testErrorsHaveKoreanMessages() {
        let all: [ServerURLError] = [.empty, .tooLong, .invalidScheme, .noHost, .hasCredentials, .hasQueryOrFragment, .plainHTTPNotLoopback, .badPath]
        for e in all { XCTAssertFalse(e.koreanMessage.isEmpty) }
    }
}

final class PetSettingsTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pet-test-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testDefaultsArePositionlessProduction() {
        let s = PetSettings()
        XCTAssertEqual(s.serverMode, .production)
        XCTAssertEqual(s.endpoint?.base.absoluteString, "https://nacho.nachotown.com")
        XCTAssertEqual(s.oidc?.issuer.absoluteString, "https://auth.nachotown.com/realms/nachotown")
        XCTAssertNil(s.petPosition)
        XCTAssertTrue(s.allowComboControl)
        XCTAssertNil(s.validationProblem())
    }

    func testModesResolveToTheirServers() {
        var s = PetSettings()
        s.serverMode = .local
        XCTAssertEqual(s.endpoint?.base.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(s.oidc?.issuer.absoluteString, "http://localhost:18180/realms/nachotown")
        s.serverMode = .mock
        XCTAssertEqual(s.oidc?.issuer.absoluteString, "http://127.0.0.1:8787/realms/nachotown")
        s.serverMode = .custom
        XCTAssertNil(s.endpoint)
        XCTAssertNotNil(s.validationProblem())
        s.customServerURL = "https://nacho.example.com"
        s.customIssuerURL = "https://id.example.com/auth/realms/nachotown/"
        XCTAssertNil(s.validationProblem())
        XCTAssertEqual(s.oidc?.issuer.absoluteString, "https://id.example.com/auth/realms/nachotown")
        XCTAssertNotEqual(s.accountScope, PetSettings().accountScope, "tokens of one server never go to another")
    }

    func testIssuerValidation() {
        XCTAssertEqual(IssuerURL.parse("https://x.com"), .failure(.badPath))
        XCTAssertEqual(IssuerURL.parse("https://x.com/realms/"), .failure(.badPath))
        XCTAssertEqual(IssuerURL.parse("https://x.com/realms/a/../b"), .failure(.badPath))
        XCTAssertEqual(IssuerURL.parse("https://x.com/realms/na cho"), .failure(.badPath))
        XCTAssertEqual(IssuerURL.parse("http://x.com/realms/a"), .failure(.plainHTTPNotLoopback))
        XCTAssertEqual(IssuerURL.parse("https://x.com/realms/a?x=1"), .failure(.hasQueryOrFragment))
        XCTAssertEqual(try? IssuerURL.parse("https://X.com/realms/nachotown").get().absoluteString,
                       "https://x.com/realms/nachotown")
    }

    func testRoundTripAndPersistedPosition() throws {
        let store = PetSettingsStore(url: dir.appendingPathComponent("pet.json"))
        var s = PetSettings()
        s.serverMode = .custom
        s.customServerURL = "https://nacho.example.com"
        s.customIssuerURL = "https://id.example.com/realms/nachotown"
        s.petPosition = PetPosition(x: 120.5, y: 300)
        s.allowComboControl = false
        try store.save(s)
        XCTAssertEqual(store.load(), s)
    }

    func testMissingFileGivesDefaults() {
        XCTAssertEqual(PetSettingsStore(url: dir.appendingPathComponent("none.json")).load(), PetSettings())
    }

    func testCorruptFileMovedAsideAndDefaultsReturned() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pet.json")
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(PetSettingsStore(url: url).load(), PetSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHandEditedBadValuesAreSanitized() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pet.json")
        let bad = #"{"serverMode":"custom","customServerURL":"http://evil.example.com","customIssuerURL":"https://e.com/realms/x","petPosition":{"x":1e300,"y":2},"future":1}"#
        try Data(bad.utf8).write(to: url)
        let s = PetSettingsStore(url: url).load()
        XCTAssertEqual(s.serverMode, .production)
        XCTAssertEqual(s.customServerURL, "")
        XCTAssertNil(s.petPosition)
        let unknownMode = #"{"serverMode":"moon","allowComboControl":false}"#
        try Data(unknownMode.utf8).write(to: url)
        let t = PetSettingsStore(url: url).load()
        XCTAssertEqual(t.serverMode, .production)
        XCTAssertFalse(t.allowComboControl)
    }
}

final class PetConnectorsAPITests: XCTestCase {
    func testSafeLinkOnlyAllowsWebLinks() {
        XCTAssertNotNil(SafeLink.openable("https://example.com/a"))
        XCTAssertNotNil(SafeLink.openable("http://127.0.0.1:8787/x"))
        XCTAssertNil(SafeLink.openable("http://example.com"))
        XCTAssertNil(SafeLink.openable("file:///etc/passwd"))
        XCTAssertNil(SafeLink.openable("javascript:alert(1)"))
        XCTAssertNil(SafeLink.openable("nacho://connections"))
        XCTAssertNil(SafeLink.openable("https://u:p@example.com"))
        XCTAssertNil(SafeLink.openable(""))
        XCTAssertNil(SafeLink.openable(nil))
    }

    func testDecodeConnections() {
        let json = #"""
            [{"id":"i1","source":"google_calendar","label":"Google 캘린더","status":"connected","scope_summary":"읽기만","link":"https://x.com/m"},
             {"source":"naver_mail","status":"needs_reauth","needs_attention":"needs_reauth"},
             {"label":"no source"}]
            """#
        let rows = ConnectorDecoder.connections(Data(json.utf8))!
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].label, "Google 캘린더")
        XCTAssertTrue(rows[0].isHealthy)
        XCTAssertEqual(rows[0].link?.absoluteString, "https://x.com/m")
        XCTAssertEqual(rows[1].label, "naver_mail")
        XCTAssertEqual(rows[1].statusText, "다시 로그인이 필요해요")
        XCTAssertFalse(rows[1].isHealthy)
        XCTAssertNil(ConnectorDecoder.connections(Data(#"{"a":1}"#.utf8)))
    }

    func testDecodeTools() {
        let json = #"""
            {"tools":[{"id":"t1","name":"search_web","search_description":"웹 검색","config":{"kind":"builtin"},"enabled":true},
                      {"name":"mail_search","config":{"kind":"connection"},"source":"naver_mail","enabled":false},{"x":1}],
             "connector_capabilities":[{"name":"browser_open","description":"열기"}]}
            """#
        let r = ConnectorDecoder.tools(Data(json.utf8))!
        XCTAssertEqual(r.tools.count, 2)
        XCTAssertEqual(r.tools[0].kindText, "기본")
        XCTAssertEqual(r.tools[1].kindText, "서비스 연결")
        XCTAssertFalse(r.tools[1].enabled)
        XCTAssertEqual(r.capabilities, [CapabilityRow(name: "browser_open", description: "열기")])
        XCTAssertNil(ConnectorDecoder.tools(Data("[]".utf8)))
    }

    final class StubFetcher: PetHTTPClient {
        var responses: [String: Result<(Int, Data), Error>] = [:]
        var bearers: [String?] = []
        private let lock = NSLock()
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            lock.lock()
            bearers.append(request.headers["Authorization"].map { String($0.dropFirst("Bearer ".count)) })
            let r = responses[request.url.path] ?? .success((404, Data()))
            lock.unlock()
            completion(r.map { PetHTTPResponse(status: $0.0, body: $0.1) })
        }
    }

    private func load(_ f: StubFetcher) -> Result<ConnectorOverview, ConnectorError> {
        let ep = try! ServerEndpoint.parse("http://127.0.0.1:8787").get()
        let ex = expectation(description: "load")
        var out: Result<ConnectorOverview, ConnectorError>!
        ConnectorsAPI(endpoint: ep, fetcher: f, token: { "mock-t" }).load {
            out = $0; ex.fulfill()
        }
        wait(for: [ex], timeout: 5)
        return out
    }

    func testLoadSuccessAndBearer() {
        let f = StubFetcher()
        f.responses["/api/v1/connections"] = .success((200, Data(#"[{"source":"s","label":"L","status":"connected"}]"#.utf8)))
        f.responses["/api/v1/tools"] = .success((200, Data(#"{"tools":[],"connector_capabilities":[]}"#.utf8)))
        let r = load(f)
        XCTAssertEqual((try? r.get())?.connections.count, 1)
        XCTAssertEqual(f.bearers.count, 2)
        XCTAssertTrue(f.bearers.allSatisfy { $0 == "mock-t" })
    }

    func testLoadErrorMapping() {
        let f = StubFetcher()
        f.responses["/api/v1/connections"] = .success((401, Data()))
        f.responses["/api/v1/tools"] = .success((200, Data(#"{"tools":[]}"#.utf8)))
        XCTAssertEqual(load(f), .failure(.unauthorized))
        f.responses["/api/v1/connections"] = .success((500, Data()))
        XCTAssertEqual(load(f), .failure(.server(500)))
        f.responses["/api/v1/connections"] = .success((200, Data("garbage".utf8)))
        XCTAssertEqual(load(f), .failure(.badResponse))
    }
}

final class PetDictationTests: XCTestCase {
    func testFlowKeepsPrefixAndReplacesPartials() {
        var d = DictationState()
        d.start(existingText: "오늘")
        XCTAssertEqual(d.phase, .requestingPermission)
        d.hypothesis("무시", isFinal: false)  // not listening yet
        XCTAssertEqual(d.text, "오늘")
        d.permissionGranted()
        XCTAssertTrue(d.isListening)
        d.hypothesis("날씨", isFinal: false)
        d.hypothesis("날씨 어때", isFinal: false)
        XCTAssertEqual(d.text, "오늘 날씨 어때")
        d.hypothesis("날씨 어때?", isFinal: true)
        XCTAssertEqual(d.phase, .idle)
        XCTAssertEqual(d.text, "오늘 날씨 어때?")
    }

    func testDenialAndUnavailable() {
        var d = DictationState()
        d.start(existingText: "")
        d.permissionDenied(.microphone)
        XCTAssertEqual(d.phase, .denied(.microphone))
        XCTAssertFalse(DictationDenial.speech.koreanMessage.isEmpty)
        d.start(existingText: "x")
        d.unavailable("한국어 음성 인식을 쓸 수 없어요")
        XCTAssertEqual(d.text, "x")
    }

    func testStopMidwayKeepsHeardText() {
        var d = DictationState()
        d.start(existingText: "")
        d.permissionGranted()
        d.hypothesis("안녕", isFinal: false)
        d.stop()
        XCTAssertEqual(d.text, "안녕")
        XCTAssertFalse(d.isListening)
    }
}

