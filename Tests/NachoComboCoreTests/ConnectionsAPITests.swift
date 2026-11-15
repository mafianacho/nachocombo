import XCTest
@testable import NachoComboCore

/// NACHO-239: the calls of the Connections tab, byte for byte against the nacho-server contract.
final class ConnectionsAPITests: XCTestCase {
    final class Fetcher: PetHTTPClient {
        var sent: [PetHTTPRequest] = []
        var answer: (PetHTTPRequest) -> Result<PetHTTPResponse, Error> = { _ in .success(PetHTTPResponse(status: 200, body: Data("{}".utf8))) }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            completion(answer(request))
        }
    }

    private func api(_ f: Fetcher) -> ConnectionsAPI {
        ConnectionsAPI(endpoint: try! ServerEndpoint.parse("https://nacho.example.com").get(), fetcher: f, token: { "tok" })
    }

    private func respond(_ status: Int, _ body: String = "{}") -> (PetHTTPRequest) -> Result<PetHTTPResponse, Error> {
        { _ in .success(PetHTTPResponse(status: status, body: Data(body.utf8))) }
    }

    private func fail<T>(_ r: Result<T, ConnectionsFailure>?) -> ConnectionsFailure? {
        if case let .failure(e)? = r { return e }
        return nil
    }

    private func bodyJSON(_ r: PetHTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
    }

    // MARK: tool switch (NACHO-132 contract)

    func testToolSwitchRequestIsPutWithEnabledOnly() {
        let r = api(Fetcher()).toolSwitchRequest(id: "5f1c", enabled: false)!
        XCTAssertEqual(r.method, "PUT")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/tools/5f1c/switch")
        XCTAssertEqual(r.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(r.body.flatMap { String(data: $0, encoding: .utf8) }, #"{"enabled":false}"#)
    }

    func testToolSwitchSuccessReturnsTheUpdatedRow() {
        let f = Fetcher()
        f.answer = respond(200, #"{"id":"t","name":"search_web","config":{"kind":"builtin"},"enabled":true,"user_enabled":false,"locked":false}"#)
        var out: Result<ToolRow, ConnectionsFailure>?
        api(f).setToolEnabled(id: "t", enabled: false) { out = $0 }
        XCTAssertEqual(try? out?.get().userEnabled, false)
    }

    func testLockedToolIs409ToolLocked() {
        let f = Fetcher()
        f.answer = respond(409, #"{"error":{"code":"conflict","message":"x","reason":"tool_locked"}}"#)
        var out: Result<ToolRow, ConnectionsFailure>?
        api(f).setToolEnabled(id: "t", enabled: false) { out = $0 }
        XCTAssertEqual(fail(out), ConnectionsFailure.locked)
        XCTAssertEqual(ConnectionsFailure.locked.koreanMessage, "나초가 대화하는 데 꼭 필요한 도구라서 끌 수 없어요.")
    }

    func testAServerWithoutTheSwitchYetFailsInsteadOfPretending() {
        let f = Fetcher()
        for status in [404, 405, 501] {
            f.answer = respond(status, "")
            var out: Result<ToolRow, ConnectionsFailure>?
            api(f).setToolEnabled(id: "t", enabled: false) { out = $0 }
            XCTAssertEqual(fail(out), ConnectionsFailure.notAvailable, "HTTP \(status)")
        }
        // A server that answers 200 but ignores the field looks like an on switch: that is no success for "off".
        f.answer = respond(200, #"{"id":"t","name":"x","config":{"kind":"builtin"},"enabled":true}"#)
        var out: Result<ToolRow, ConnectionsFailure>?
        api(f).setToolEnabled(id: "t", enabled: false) { out = $0 }
        XCTAssertEqual(fail(out), ConnectionsFailure.notAvailable)
        XCTAssertTrue(ConnectionsFailure.notAvailable.koreanMessage.contains("아직 이 기능을 지원하지 않아요"))
    }

    func testAMissingToolWithAServerErrorBodyIsNotFound() {
        let f = Fetcher()
        f.answer = respond(404, #"{"error":{"code":"not_found","message":"x"}}"#)
        var out: Result<ToolRow, ConnectionsFailure>?
        api(f).setToolEnabled(id: "t", enabled: true) { out = $0 }
        XCTAssertEqual(fail(out), .notFound)
    }

    // MARK: connections

    func testServiceSwitchIsPatchWithTheVersion() {
        let r = api(Fetcher()).connectionSwitchRequest(id: "0a1b", enabled: false, version: 3)!
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.url.path, "/api/v1/connections/0a1b")
        XCTAssertEqual(r.body.flatMap { String(data: $0, encoding: .utf8) }, #"{"enabled":false,"expected_version":3}"#)
    }

    func testScopeIsPatchedAtScopeAndReconsentIsNamed() {
        let f = Fetcher()
        let r = api(f).scopeRequest(id: "0a1b", level: "read_write", version: 4)!
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.url.path, "/api/v1/connections/0a1b/scope")
        XCTAssertEqual(bodyJSON(r)["level"] as? String, "read_write")
        XCTAssertEqual(bodyJSON(r)["expected_version"] as? Int, 4)
        f.answer = respond(409, #"{"error":{"code":"needs_reconsent","message":"x","reason":"gmail"},"begin_hint":{"source":"gmail"}}"#)
        var out: Result<Void, ConnectionsFailure>?
        api(f).setScopeLevel(id: "0a1b", level: "read_write", version: 4) { out = $0 }
        XCTAssertEqual(fail(out), ConnectionsFailure.needsReconsent)
    }

    func testDisconnectIsDelete() {
        let f = Fetcher()
        var out: Result<Void, ConnectionsFailure>?
        api(f).disconnect(id: "0a1b") { out = $0 }
        XCTAssertEqual(f.sent.last?.method, "DELETE")
        XCTAssertEqual(f.sent.last?.url.path, "/api/v1/connections/0a1b")
        XCTAssertNotNil(try? out?.get())
    }

    func testIdsThatAreNotIdsAreRefusedBeforeAnyRequest() {
        let f = Fetcher()
        let a = api(f)
        XCTAssertNil(a.disconnectRequest(id: "../tools"))
        XCTAssertNil(a.disconnectRequest(id: "a/b"))
        XCTAssertNil(a.disconnectRequest(id: ""))
        XCTAssertNil(a.attemptRequest(id: "x?y=1"))
        var out: Result<Void, ConnectionsFailure>?
        a.disconnect(id: "a/b") { out = $0 }
        XCTAssertEqual(fail(out), .notFound)
        XCTAssertTrue(f.sent.isEmpty)
        XCTAssertNotNil(a.detailRequest(source: "custom:12"), "a requested service is `custom:{id}`")
    }

    func testStatusMapping() {
        let f = Fetcher()
        var out: Result<Void, ConnectionsFailure>?
        for (status, expected) in [(401, ConnectionsFailure.unauthorized), (500, .server(500))] {
            f.answer = respond(status, "")
            api(f).disconnect(id: "x") { out = $0 }
            XCTAssertEqual(fail(out), expected)
        }
        f.answer = { _ in .failure(URLError(.notConnectedToInternet)) }
        api(f).disconnect(id: "x") { out = $0 }
        XCTAssertEqual(fail(out), ConnectionsFailure.network)
        f.answer = respond(409, #"{"error":{"code":"conflict","message":"x","reason":"stale_version"}}"#)
        api(f).setConnectionEnabled(id: "x", enabled: true, version: 1) { out = $0 }
        XCTAssertEqual(fail(out), ConnectionsFailure.conflict("stale_version"))
    }

    // MARK: catalog and connecting

    func testCatalogSearchGoesInTheQueryAndIsDecoded() {
        let f = Fetcher()
        f.answer = respond(200, #"""
            {"categories":[],"bundles":[],"builtins":[],"enabled_count":0,
             "items":[{"source":"gmail","label":"Gmail","summary":"메일","connect_kind":"oauth","support_status":"available","connected":false},
                      {"source":"kakao","label":"카카오톡","connect_kind":"qr","support_status":"limited","support_reason":"브라우저 연결이 필요해요","connected":false},
                      {"label":"no source"}]}
            """#)
        var rows: [CatalogRow] = []
        api(f).catalog(query: " 메일 & 캘린더 ") { rows = (try? $0.get()) ?? [] }
        XCTAssertEqual(f.sent[0].method, "GET")
        XCTAssertEqual(f.sent[0].url.path, "/api/v1/connections/catalog")
        XCTAssertEqual(URLComponents(url: f.sent[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "메일 & 캘린더")
        XCTAssertEqual(rows.map { $0.source }, ["gmail", "kakao"])
        XCTAssertEqual(rows[0].plan, .browser)
        guard case .unsupported = rows[1].plan else { return XCTFail("qr is not done from the Mac") }
        XCTAssertNil(api(f).catalogRequest(query: "").url.query, "no query when the search is empty")
    }

    func testBeginSendsTheSourceAnIdempotencyKeyAndReadsOnlyWebLinks() {
        let f = Fetcher()
        f.answer = respond(201, #"{"attempt_id":"a1","connect_kind":"oauth","next":"oauth","authorize_url":"https://accounts.example.com/consent?x=1","expires_at":"2026-11-15T00:00:00Z"}"#)
        var info: BeginInfo?
        api(f).begin(source: "gmail") { info = try? $0.get() }
        XCTAssertEqual(f.sent[0].method, "POST")
        XCTAssertEqual(f.sent[0].url.path, "/api/v1/connections/begin")
        XCTAssertEqual(bodyJSON(f.sent[0])["source"] as? String, "gmail")
        XCTAssertFalse((f.sent[0].headers["Idempotency-Key"] ?? "").isEmpty)
        XCTAssertEqual(info?.attemptID, "a1")
        XCTAssertEqual(info?.authorizeURL?.host, "accounts.example.com")
        f.answer = respond(201, #"{"attempt_id":"a2","connect_kind":"oauth","next":"oauth","authorize_url":"file:///etc/passwd"}"#)
        api(f).begin(source: "gmail") { info = try? $0.get() }
        XCTAssertNil(info?.authorizeURL, "a file: or custom-scheme link is never opened")
    }

    func testAttemptCompletionIsRead() {
        let f = Fetcher()
        f.answer = respond(200, #"{"attempt_id":"a1","source":"gmail","state":"completed","connect_kind":"oauth","connection":{"id":"c9"}}"#)
        var a: AttemptInfo?
        api(f).attempt(id: "a1") { a = try? $0.get() }
        XCTAssertEqual(f.sent[0].url.path, "/api/v1/connections/attempts/a1")
        XCTAssertEqual(a?.state, "completed")
        XCTAssertEqual(a?.connectionID, "c9")
        f.answer = respond(200, "garbage")
        var out: Result<AttemptInfo, ConnectionsFailure>?
        api(f).attempt(id: "a1") { out = $0 }
        XCTAssertEqual(fail(out), ConnectionsFailure.badResponse)
    }

    func testAppPasswordGoesOnlyInThatRequestAndNeverInAnErrorText() {
        let f = Fetcher()
        let secret = "abcd-efgh-ijkl-mnop"
        f.answer = respond(400, #"{"error":{"code":"authentication_failed","message":"bad \#(secret)"}}"#)
        var out: Result<Void, ConnectionsFailure>?
        api(f).submitAppPassword(attemptID: "a1", email: "me@naver.com", password: secret) { out = $0 }
        let r = f.sent[0]
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/connections/attempts/a1/app-password")
        XCTAssertEqual(bodyJSON(r)["app_password"] as? String, secret)
        XCTAssertEqual(bodyJSON(r)["email"] as? String, "me@naver.com")
        XCTAssertFalse(r.url.absoluteString.contains(secret), "never in the URL")
        guard case let .failure(e)? = out else { return XCTFail() }
        XCTAssertEqual(e, .conflict("authentication_failed"))
        XCTAssertFalse(e.koreanMessage.contains(secret))
        XCTAssertFalse("\(e)".contains(secret), "not even in a debug print")
        XCTAssertEqual(e.koreanMessage, "로그인에 실패했어요. 입력한 내용을 확인해 주세요.")
    }

    func testCancelAttemptIsDelete() {
        let f = Fetcher()
        api(f).cancelAttempt(id: "a1") { _ in }
        XCTAssertEqual(f.sent[0].method, "DELETE")
        XCTAssertEqual(f.sent[0].url.path, "/api/v1/connections/attempts/a1")
    }
}
