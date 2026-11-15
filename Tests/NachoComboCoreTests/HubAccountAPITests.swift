import XCTest
@testable import NachoComboCore

/// 나초 앱 창(허브) 계정·설정 섹션(NACHO-267 U1)의 요청 바이트와 응답·오류 문구. 운영 서버는 부르지 않는다(가짜 HTTP).
final class HubAccountAPITests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String, headers: [String: String] = [:]) -> PetHTTPResponse {
        PetHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }
    private func failure<T>(_ r: Result<T, PetAPIError>) -> PetAPIError? { if case let .failure(f) = r { return f }; return nil }
    private func value<T>(_ r: Result<T, PetAPIError>) -> T? { if case let .success(v) = r { return v }; return nil }

    // MARK: request bytes — A5

    func testGetMe() {
        let r = HubAccountAPI.me(e, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me")
        XCTAssertEqual(r.headers["Authorization"], "Bearer T")
        XCTAssertNil(r.body)
    }

    func testPatchNameCarriesExpectedVersionInBody() {
        let r = HubAccountAPI.patchMe(e, bearer: "T", changes: ["display_name": "나초"], expectedVersion: 4)
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me")
        XCTAssertEqual(body(r), "{\"display_name\":\"나초\",\"expected_version\":4}")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
    }

    func testPatchHandleAndBirthdayBodies() {
        XCTAssertEqual(body(HubAccountAPI.patchMe(e, bearer: "T", changes: ["handle": "nacho_1"], expectedVersion: 1)),
                       "{\"expected_version\":1,\"handle\":\"nacho_1\"}")
        XCTAssertEqual(body(HubAccountAPI.patchMe(e, bearer: "T", changes: ["birthday": "1999-02-03"], expectedVersion: 1)),
                       "{\"birthday\":\"1999-02-03\",\"expected_version\":1}")
    }

    func testHandleCheckQueryIsEscaped() {
        let r = HubAccountAPI.handleCheck(e, handle: "na cho&", bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me/handle-check?handle=na%20cho%26")
    }

    // MARK: request bytes — A6

    func testPrivacySettingsRequests() {
        let g = HubAccountAPI.privacy(e, bearer: "T")
        XCTAssertEqual(g.method, "GET")
        XCTAssertEqual(g.url.path, "/api/v1/me/privacy-settings")
        let p = HubAccountAPI.patchPrivacy(e, bearer: "T", phoneDiscoverable: true)
        XCTAssertEqual(p.method, "PATCH")
        XCTAssertEqual(p.url.path, "/api/v1/me/privacy-settings")
        XCTAssertEqual(body(p), "{\"phone_discoverable\":true}")
        XCTAssertEqual(body(HubAccountAPI.patchPrivacy(e, bearer: "T", memoryPaused: false)), "{\"memory_paused\":false}")
        XCTAssertEqual(body(HubAccountAPI.patchPrivacy(e, bearer: "T", memoryIndicatorEnabled: true)), "{\"memory_indicator_enabled\":true}")
    }

    func testDeleteContactMatchesHasNoBody() {
        let r = HubAccountAPI.deleteContactMatches(e, bearer: "T")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me/contact-matches")
        XCTAssertNil(r.body)
    }

    // MARK: request bytes — A4

    func testExportPreviewStatusCancel() {
        XCTAssertEqual(HubAccountAPI.export(e, bearer: "T").url.path, "/api/v1/me/export")
        XCTAssertEqual(HubAccountAPI.export(e, bearer: "T").method, "GET")
        XCTAssertEqual(HubAccountAPI.deletionPreview(e, bearer: "T").url.path, "/api/v1/me/deletion-preview")
        XCTAssertEqual(HubAccountAPI.deletionStatus(e, bearer: "T").url.path, "/api/v1/me/deletion-status")
        let c = HubAccountAPI.cancelDeletion(e, bearer: "T", idempotencyKey: "K")
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url.absoluteString, "https://nacho.example.com/api/v1/me/deletion/cancel")
        XCTAssertEqual(c.headers["Idempotency-Key"], "K")
    }

    func testDeleteAccountRequestIsPlainDelete() {
        let r = HubAccountAPI.deleteAccount(e, bearer: "T")
        XCTAssertEqual(r.method, "DELETE")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me")
        XCTAssertNil(r.body)
    }

    // MARK: request bytes — A10

    func testIssueReportBodyWithCategoryAndDiagnostics() {
        let d = HubAccountAPI.Diagnostics(appVersion: "0.11.0", osVersion: "macOS 15", deviceModel: "Mac", language: "ko")
        let r = HubAccountAPI.issueReport(e, bearer: "T", description: "안 돼요", category: "chat", diagnostics: d, idempotencyKey: "K")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/issue-reports")
        XCTAssertEqual(r.headers["Idempotency-Key"], "K")
        XCTAssertEqual(body(r), "{\"category\":\"chat\",\"description\":\"안 돼요\",\"diagnostics\":{\"app_version\":\"0.11.0\",\"device_model\":\"Mac\",\"language\":\"ko\",\"os_version\":\"macOS 15\"}}")
    }

    func testIssueReportOmitsEmptyCategoryAndDiagnostics() {
        let r = HubAccountAPI.issueReport(e, bearer: "T", description: "x", category: nil, diagnostics: nil, idempotencyKey: "K")
        XCTAssertEqual(body(r), "{\"description\":\"x\"}")
    }

    func testReportUserPathAndBody() {
        let r = HubAccountAPI.reportUser(e, userID: "u-1", bearer: "T", description: "욕설", idempotencyKey: "K")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/users/u-1/report")
        XCTAssertEqual(r.headers["Idempotency-Key"], "K")
        XCTAssertEqual(body(r), "{\"description\":\"욕설\"}")
        XCTAssertEqual(HubAccountAPI.reportUser(e, userID: "a/../b?c", bearer: "T", description: "x", idempotencyKey: "K").url.path, "/api/v1/users/a..bc/report", "path-changing characters are dropped")
    }

    // MARK: responses

    func testParseMeReadsUserBlock() {
        let json = "{\"user\":{\"id\":\"u1\",\"display_name\":\"나초\",\"handle\":\"nacho_1\",\"birthday\":\"1999-02-03\",\"version\":7,"
            + "\"phone\":{\"masked\":\"010-****-1234\",\"verified\":true}},\"roles\":[],\"auth_provider\":\"google\"}"
        let p = try! XCTUnwrap(value(HubAccountAPI.parseMe(resp(200, json))))
        XCTAssertEqual(p.displayName, "나초")
        XCTAssertEqual(p.handle, "nacho_1")
        XCTAssertEqual(p.birthday, "1999-02-03")
        XCTAssertEqual(p.version, 7)
        XCTAssertEqual(p.phoneMasked, "010-****-1234")
        XCTAssertEqual(p.authProvider, "google")
        XCTAssertNil(p.purgeAt)
    }

    func testParseMeWithoutOptionalFields() {
        let p = try! XCTUnwrap(value(HubAccountAPI.parseMe(resp(200, "{\"user\":{\"version\":1}}"))))
        XCTAssertEqual(p.displayName, "")
        XCTAssertNil(p.handle)
        XCTAssertNil(p.birthday)
        XCTAssertNil(p.phoneMasked)
    }

    func testParsePatchResultIsTheUserItself() {
        let p = try! XCTUnwrap(value(HubAccountAPI.parseUser(resp(200, "{\"display_name\":\"새\",\"version\":8}"))))
        XCTAssertEqual(p.displayName, "새")
        XCTAssertEqual(p.version, 8)
    }

    func testParseMeBadBody() {
        XCTAssertEqual(failure(HubAccountAPI.parseMe(resp(200, "[]"))), .badResponse)
        XCTAssertEqual(failure(HubAccountAPI.parseMe(resp(200, "{\"x\":1}"))), .badResponse)
    }

    func testParseHandleCheck() {
        let c = try! XCTUnwrap(value(HubAccountAPI.parseHandleCheck(resp(200, "{\"handle\":\"abc\",\"status\":\"taken\",\"available\":false}"))))
        XCTAssertEqual(c.handle, "abc")
        XCTAssertEqual(c.status, .taken)
        let u = try! XCTUnwrap(value(HubAccountAPI.parseHandleCheck(resp(200, "{\"handle\":\"abc\",\"status\":\"mystery\",\"available\":false}"))))
        XCTAssertEqual(u.status, .unknown, "a status this build does not know reads like a failed check")
    }

    func testParsePrivacy() {
        let p = try! XCTUnwrap(value(HubAccountAPI.parsePrivacy(resp(200, "{\"memory_paused\":true,\"memory_indicator_enabled\":false,\"phone_discoverable\":true}"))))
        XCTAssertTrue(p.memoryPaused)
        XCTAssertFalse(p.memoryIndicatorEnabled)
        XCTAssertTrue(p.phoneDiscoverable)
    }

    func testParseDeletionPreviewAndStatus() {
        let json = "{\"running_tasks\":2,\"scheduled_actions\":3,\"agent_count\":4,\"running_group_runs\":1,\"subscription\":{\"active\":true,\"store\":\"google_play\"}}"
        let p = try! XCTUnwrap(value(HubAccountAPI.parseDeletionPreview(resp(200, json))))
        XCTAssertEqual([p.runningTasks, p.scheduledActions, p.agentCount, p.runningGroupRuns], [2, 3, 4, 1])
        XCTAssertTrue(p.subscriptionActive)
        let s = try! XCTUnwrap(value(HubAccountAPI.parseDeletionStatus(resp(200, "{\"status\":\"scheduled\",\"purge_at\":\"2026-11-22T00:00:00Z\"}"))))
        XCTAssertEqual(s.status, .scheduled)
        XCTAssertEqual(s.purgeAt, "2026-11-22T00:00:00Z")
        XCTAssertEqual(try! XCTUnwrap(value(HubAccountAPI.parseDeletionStatus(resp(200, "{\"status\":\"active\"}")))).status, .active)
    }

    func testParseContactMatchesDeletedCount() {
        XCTAssertEqual(value(HubAccountAPI.parseDeletedCount(resp(200, "{\"ok\":true,\"deleted\":5}"))), 5)
        XCTAssertEqual(value(HubAccountAPI.parseDeletedCount(resp(200, "{\"ok\":true}"))), 0)
    }

    func testExportFileNameAndBodyAreKept() {
        let r = resp(200, "{\"exported_at\":\"2026-11-15T00:00:00Z\"}", headers: ["Content-Disposition": "attachment; filename=\"nacho-export.json\""])
        let f = try! XCTUnwrap(value(HubAccountAPI.parseExport(r)))
        XCTAssertEqual(f.fileName, "nacho-export.json")
        XCTAssertEqual(f.data, r.body)
        let plain = try! XCTUnwrap(value(HubAccountAPI.parseExport(resp(200, "{}"))))
        XCTAssertEqual(plain.fileName, "nacho-data.json")
    }

    func testIssueReportCreatedAndUserReportAccepted() {
        XCTAssertTrue(value(HubAccountAPI.parseCreated(resp(201, "{\"id\":\"r1\",\"created_at\":\"2026-11-15T00:00:00Z\"}"))) != nil)
        XCTAssertTrue(value(HubAccountAPI.parseCreated(resp(201, "{\"status\":\"ok\"}"))) != nil)
        XCTAssertTrue(value(HubAccountAPI.parseCreated(resp(204, ""))) != nil)
    }

    // MARK: error text

    func testErrorsAreKorean() {
        func text(_ status: Int, _ code: String) -> String {
            HubAccountAPI.errorText(HubAPI.error(resp(status, "{\"error\":{\"code\":\"\(code)\",\"message\":\"m\"}}")))
        }
        XCTAssertEqual(text(400, "invalid_input"), "쓸 수 없는 값이에요. 다시 확인해 주세요")
        XCTAssertEqual(text(400, "blocked_word"), "쓸 수 없는 표현이 들어 있어요")
        XCTAssertEqual(text(409, "handle_taken"), "방금 누가 이 ID를 가져갔어요. 다른 ID를 골라 주세요")
        XCTAssertEqual(text(400, "underage"), "나이 제한 때문에 이 생일로 바꿀 수 없어요")
        XCTAssertEqual(text(409, "version_conflict"), "다른 기기에서 먼저 바뀌었어요. 나갔다가 다시 들어와 주세요")
        XCTAssertEqual(text(429, "too_many_requests"), "방금 바꿔서 잠시 뒤에 다시 바꿀 수 있어요")
        XCTAssertEqual(text(500, "internal_error"), "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        XCTAssertEqual(text(401, "unauthorized"), "로그인이 필요해요.")
        XCTAssertEqual(text(403, "account_deleting"), "삭제 중인 계정이에요.")
        XCTAssertEqual(HubAccountAPI.errorText(HubAPI.error(resp(404, "{}"))), "찾지 못했어요.")
        XCTAssertEqual(HubAccountAPI.errorText(.network), PetAPIError.network.text)
    }

    // MARK: client round trips (fake HTTP)

    private final class FakeHTTP: PetHTTPClient {
        var sent: [PetHTTPRequest] = []
        var answers: [PetHTTPResponse]
        init(_ a: [PetHTTPResponse]) { answers = a }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            completion(.success(answers.removeFirst()))
        }
    }

    func testPatchConflictFlowsThroughClientAsVersionConflict() {
        let http = FakeHTTP([resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}")])
        let client = HubClient(endpoint: e, http: http, tokens: { _, done in done("T") })
        var out: Result<PetHTTPResponse, PetAPIError>?
        client.send({ HubAccountAPI.patchMe(self.e, bearer: $0, changes: ["display_name": "a"], expectedVersion: 2) }) { out = $0 }
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertEqual(failure(out!)?.isVersionConflict, true)
    }

    func testClientConfigNeedsNoToken() {
        let r = HubAccountAPI.clientConfig(e)
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/client/config")
        XCTAssertNil(r.headers["Authorization"])
    }

    func testSubmitUserReportSendsOnceWithOneIdempotencyKeyAcross401() {
        let http = FakeHTTP([resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}"), resp(201, "{\"status\":\"ok\"}")])
        let client = HubClient(endpoint: e, http: http, tokens: { _, done in done("T") })
        var out: Result<Void, PetAPIError>?
        HubAccountAPI.submitUserReport(client: client, userID: "u-9", description: "나쁜 말", completion: { out = $0 })
        XCTAssertEqual(http.sent.count, 2)
        XCTAssertEqual(http.sent[0].url.path, "/api/v1/users/u-9/report")
        XCTAssertEqual(http.sent[0].headers["Idempotency-Key"], http.sent[1].headers["Idempotency-Key"])
        XCTAssertNotNil(http.sent[0].headers["Idempotency-Key"])
        XCTAssertNotNil(out.flatMap { try? $0.get() })
    }

    func testSubmitUserReportChecksInputBeforeSending() {
        let http = FakeHTTP([])
        let client = HubClient(endpoint: e, http: http, tokens: { _, done in done("T") })
        var out: Result<Void, PetAPIError>?
        HubAccountAPI.submitUserReport(client: client, userID: "u-9", description: "  ", completion: { out = $0 })
        XCTAssertEqual(failure(out!)?.text, "신고 내용을 입력해 주세요.")
        HubAccountAPI.submitUserReport(client: client, userID: "u-9", description: String(repeating: "a", count: 1001), completion: { out = $0 })
        XCTAssertEqual(failure(out!)?.text, "신고 내용은 1000자까지 쓸 수 있어요.")
        XCTAssertTrue(http.sent.isEmpty)
    }

    func testSubmitUserReportServerErrorIsKorean() {
        let http = FakeHTTP([resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"m\"}}")])
        let client = HubClient(endpoint: e, http: http, tokens: { _, done in done("T") })
        var out: Result<Void, PetAPIError>?
        HubAccountAPI.submitUserReport(client: client, userID: "u-9", description: "x", completion: { out = $0 })
        XCTAssertEqual(failure(out!)?.isNotFound, true)
    }

    func testPrivacyUnauthorizedRetriesOnceThenParses() {
        let http = FakeHTTP([resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}"),
                             resp(200, "{\"memory_paused\":false,\"memory_indicator_enabled\":true,\"phone_discoverable\":false}")])
        var forced: [Bool] = []
        let client = HubClient(endpoint: e, http: http, tokens: { f, done in forced.append(f); done("T") })
        var out: Result<PetHTTPResponse, PetAPIError>?
        client.send({ HubAccountAPI.privacy(self.e, bearer: $0) }) { out = $0 }
        XCTAssertEqual(forced, [false, true])
        let p = try! XCTUnwrap(value(HubAccountAPI.parsePrivacy(try! XCTUnwrap(value(out!)))))
        XCTAssertFalse(p.phoneDiscoverable)
    }
}

/// 입력 검증: 나초 앱(`name-rules.ts`·`handle-rules.ts`·`birthday-rules.ts`·`issue-rules.ts`·`report-screen.tsx`)의 규칙 그대로.
final class HubAccountRulesTests: XCTestCase {
    // 이름: 앞뒤 공백·줄바꿈 정리, 1~40자(코드 포인트).
    func testNameRules() {
        XCTAssertEqual(AccountRules.name("  나초  "), .ok("나초"))
        XCTAssertEqual(AccountRules.name("a\n b"), .ok("a b"))
        XCTAssertEqual(AccountRules.name("   "), .empty)
        XCTAssertEqual(AccountRules.name(""), .empty)
        XCTAssertEqual(AccountRules.name(String(repeating: "가", count: 40)), .ok(String(repeating: "가", count: 40)))
        XCTAssertEqual(AccountRules.name(String(repeating: "가", count: 41)), .tooLong)
        XCTAssertEqual(AccountRules.name(String(repeating: "😀", count: 40)), .ok(String(repeating: "😀", count: 40)), "an emoji counts once")
    }

    // 핸들: 소문자·숫자·밑줄 3~20자. 확인 결과는 물어본 글자에만 맞는다.
    func testHandleShape() {
        XCTAssertTrue(AccountRules.handleShapeOK("abc"))
        XCTAssertTrue(AccountRules.handleShapeOK("a_1" + String(repeating: "z", count: 17)))
        XCTAssertFalse(AccountRules.handleShapeOK("a_1" + String(repeating: "z", count: 18)), "21 characters")
        XCTAssertFalse(AccountRules.handleShapeOK("ab"))
        XCTAssertFalse(AccountRules.handleShapeOK("ab-c"))
        XCTAssertFalse(AccountRules.handleShapeOK("한글한글"))
    }

    func testHandleStates() {
        let ok = HandleCheckResult(handle: "newid", status: .available)
        XCTAssertEqual(AccountRules.handleState(input: "same", current: "same", check: nil, checkFailed: false), .same)
        XCTAssertEqual(AccountRules.handleState(input: "ab", current: "x", check: nil, checkFailed: false), .short)
        XCTAssertEqual(AccountRules.handleState(input: "Abc", current: "x", check: nil, checkFailed: false), .uppercase)
        XCTAssertEqual(AccountRules.handleState(input: "ab-c", current: "x", check: nil, checkFailed: false), .invalid)
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: nil, checkFailed: true), .failed)
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: nil, checkFailed: false), .checking)
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: ok, checkFailed: false), .available)
        XCTAssertEqual(AccountRules.handleState(input: "newid2", current: "x", check: ok, checkFailed: false), .checking, "a late answer for older typing changes nothing")
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: HandleCheckResult(handle: "newid", status: .taken), checkFailed: false), .taken)
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: HandleCheckResult(handle: "newid", status: .blocked), checkFailed: false), .blocked)
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: HandleCheckResult(handle: "newid", status: .unknown), checkFailed: false), .failed)
        XCTAssertEqual(AccountRules.handleState(input: "newid", current: "x", check: HandleCheckResult(handle: "newid", status: .invalid), checkFailed: false), .invalid)
        XCTAssertTrue(AccountRules.handleNeedsCheck(input: "newid", current: "x"))
        XCTAssertFalse(AccountRules.handleNeedsCheck(input: "x", current: "x"))
        XCTAssertFalse(AccountRules.handleNeedsCheck(input: "NEW", current: "x"))
    }

    func testHandleSaveOnlyWhenAvailable() {
        XCTAssertTrue(AccountRules.canSaveHandle(.available))
        for s in [AccountRules.HandleState.same, .short, .uppercase, .invalid, .checking, .failed, .taken, .blocked] {
            XCTAssertFalse(AccountRules.canSaveHandle(s), "\(s)")
        }
    }

    // 생일: 1900년부터 오늘까지의 실제 날짜. 최소 나이는 서버 몫이라 상수가 없다.
    func testBirthdayRules() {
        let today = AccountRules.Day(year: 2026, month: 11, day: 15)
        XCTAssertEqual(AccountRules.birthday("1999", "2", "3", today: today), .ok("1999-02-03"))
        XCTAssertEqual(AccountRules.birthday("2026", "11", "15", today: today), .ok("2026-11-15"))
        XCTAssertEqual(AccountRules.birthday("2026", "11", "16", today: today), .future)
        XCTAssertEqual(AccountRules.birthday("2027", "1", "1", today: today), .future)
        XCTAssertEqual(AccountRules.birthday("1899", "12", "31", today: today), .tooOld)
        XCTAssertEqual(AccountRules.birthday("1900", "1", "1", today: today), .ok("1900-01-01"))
        XCTAssertEqual(AccountRules.birthday("2001", "2", "29", today: today), .notADate)
        XCTAssertEqual(AccountRules.birthday("2000", "2", "29", today: today), .ok("2000-02-29"))
        XCTAssertEqual(AccountRules.birthday("1999", "13", "1", today: today), .notADate)
        XCTAssertEqual(AccountRules.birthday("1999", "4", "31", today: today), .notADate)
        XCTAssertEqual(AccountRules.birthday("199", "4", "3", today: today), .incomplete)
        XCTAssertEqual(AccountRules.birthday("1999", "", "3", today: today), .incomplete)
        XCTAssertEqual(AccountRules.birthday("1999", "4", "", today: today), .incomplete)
        XCTAssertEqual(AccountRules.birthday("19a9", "4", "3", today: today), .notADate)
    }

    // 이슈 신고: 앞뒤 공백 뺀 뒤 1~2000자(앱은 글자 수를 UTF-16으로 센다). 사용자 신고는 앱이 1000자.
    func testIssueDescriptionRules() {
        XCTAssertEqual(AccountRules.issueDescription(""), .empty)
        XCTAssertEqual(AccountRules.issueDescription("  \n "), .empty)
        XCTAssertEqual(AccountRules.issueDescription(" 문제 "), .ok(" 문제 "), "sent as typed, only the emptiness check trims")
        XCTAssertEqual(AccountRules.issueDescription(String(repeating: "a", count: 2000)), .ok(String(repeating: "a", count: 2000)))
        XCTAssertEqual(AccountRules.issueDescription(String(repeating: "a", count: 2001)), .tooLong)
        XCTAssertEqual(AccountRules.issueCategories, ["account", "chat", "tasks", "character", "friends", "connections", "privacy", "memories", "billing", "profile", "other"])
    }

    func testUserReportRules() {
        XCTAssertEqual(AccountRules.userReport(""), .empty)
        XCTAssertEqual(AccountRules.userReport(String(repeating: "a", count: 1000)), .ok(String(repeating: "a", count: 1000)))
        XCTAssertEqual(AccountRules.userReport(String(repeating: "a", count: 1001)), .tooLong)
    }

    // 법적 고지 링크: 기본 브라우저로 열되 http(s)만.
    func testWebLinkOnlyHttpAndHttps() {
        XCTAssertEqual(AccountRules.webLink("https://nachotown.com/legal/terms")?.absoluteString, "https://nachotown.com/legal/terms")
        XCTAssertEqual(AccountRules.webLink("http://example.com/a")?.absoluteString, "http://example.com/a")
        XCTAssertNil(AccountRules.webLink("file:///etc/passwd"))
        XCTAssertNil(AccountRules.webLink("javascript:alert(1)"))
        XCTAssertNil(AccountRules.webLink("nacho://x"))
        XCTAssertNil(AccountRules.webLink("https://"))
        XCTAssertNil(AccountRules.webLink(""))
        XCTAssertNil(AccountRules.webLink(nil))
    }

    func testLegalDocumentsPreferServerAddressesAndFallBackToPublicOnes() {
        let server = "{\"legal_docs\":{\"terms\":{\"url\":\"https://x.example/terms\",\"version\":\"1\"},\"privacy\":{\"url\":\"file:///bad\"},\"refund_policy\":{\"url\":\"https://x.example/refund\"}}}"
        let docs = AccountRules.legalDocuments(clientConfig: Data(server.utf8))
        XCTAssertEqual(docs.first { $0.kind == "terms" }?.url?.absoluteString, "https://x.example/terms")
        XCTAssertNil(docs.first { $0.kind == "privacy" }?.url, "a non-web address is never opened")
        XCTAssertEqual(docs.first { $0.kind == "refund_policy" }?.url?.absoluteString, "https://x.example/refund")
        let none = AccountRules.legalDocuments(clientConfig: nil)
        XCTAssertEqual(none.first { $0.kind == "terms" }?.url?.absoluteString, "https://nachotown.com/legal/terms/2026-10-01")
        XCTAssertEqual(none.first { $0.kind == "refund_policy" }?.url?.absoluteString, "https://nachotown.com/legal/refund-policy/2026-10-01")
        XCTAssertNil(none.first { $0.kind == "privacy" }?.url)
        XCTAssertEqual(none.map { $0.kind }, ["terms", "privacy", "third_party", "ai_transfer", "refund_policy"])
    }
}
