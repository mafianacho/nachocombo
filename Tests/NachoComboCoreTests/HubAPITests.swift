import XCTest
@testable import NachoComboCore

/// 나초 앱 창(허브)의 공용 API (NACHO-266 U0). 요청은 바이트 단위로, 응답·오류는 한국어 문구까지 확인한다.
final class HubAPITests: XCTestCase {
    private let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }

    // MARK: request bytes

    func testGetWithQueryAndBearer() {
        let r = HubAPI.get(endpoint, "/api/v1/notifications", query: [("limit", "20"), ("before", "a b&c")], bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/notifications?limit=20&before=a%20b%26c")
        XCTAssertEqual(r.headers["Authorization"], "Bearer T")
        XCTAssertEqual(r.headers["Accept"], "application/json")
        XCTAssertNil(r.body)
        XCTAssertNil(r.headers["Content-Type"])
    }

    func testPostJSONSortedKeysIdempotencyAndExpectedVersion() {
        let r = HubAPI.post(endpoint, "/api/v1/tasks", bearer: "T", json: ["title": "일", "a": 1], idempotencyKey: "K1", expectedVersion: 3)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/tasks")
        XCTAssertEqual(r.headers["Idempotency-Key"], "K1")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertEqual(body(r), "{\"a\":1,\"expected_version\":3,\"title\":\"일\"}")
    }

    func testPatchAndPutBodies() {
        let p = HubAPI.patch(endpoint, "/api/v1/me/settings", bearer: "T", json: ["lang": "ko"], expectedVersion: 7)
        XCTAssertEqual(p.method, "PATCH")
        XCTAssertEqual(body(p), "{\"expected_version\":7,\"lang\":\"ko\"}")
        XCTAssertNil(p.headers["Idempotency-Key"])
        let u = HubAPI.put(endpoint, "/api/v1/x/1", bearer: nil, json: [:])
        XCTAssertEqual(u.method, "PUT")
        XCTAssertEqual(body(u), "{}")
        XCTAssertNil(u.headers["Authorization"])
    }

    func testDeleteHasNoBodyAndVersionGoesInQuery() {
        let d = HubAPI.delete(endpoint, "/api/v1/schedules/s1", bearer: "T", expectedVersion: 2)
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/schedules/s1?expected_version=2")
        XCTAssertNil(d.body)
        let d2 = HubAPI.delete(endpoint, "/api/v1/schedules/s1", bearer: "T")
        XCTAssertEqual(d2.url.absoluteString, "https://nacho.example.com/api/v1/schedules/s1")
    }

    func testEmptyKeysAreDropped() {
        let r = HubAPI.post(endpoint, "/p", bearer: "", json: [:], idempotencyKey: "")
        XCTAssertNil(r.headers["Authorization"])
        XCTAssertNil(r.headers["Idempotency-Key"])
    }

    func testIdempotencyKeysAreUnique() {
        XCTAssertNotEqual(HubAPI.newIdempotencyKey(), HubAPI.newIdempotencyKey())
        XCTAssertGreaterThanOrEqual(HubAPI.newIdempotencyKey().count, 16)
    }

    // MARK: responses

    private func resp(_ status: Int, _ json: String, headers: [String: String] = [:]) -> PetHTTPResponse {
        PetHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    func testDecodePageFromArrayWithNextBeforeHeader() throws {
        let page = try HubAPI.page(resp(200, "[{\"id\":\"a\"},{\"id\":\"b\"}]", headers: ["x-next-before": "CUR"])).get()
        XCTAssertEqual(page.items.map { $0.str("id") }, ["a", "b"])
        XCTAssertEqual(page.nextCursor, "CUR")
        XCTAssertTrue(page.hasMore)
    }

    func testDecodePageFromObjectKeys() throws {
        let p1 = try HubAPI.page(resp(200, "{\"items\":[{\"id\":\"a\"}],\"next_cursor\":\"N\"}")).get()
        XCTAssertEqual(p1.items.count, 1)
        XCTAssertEqual(p1.nextCursor, "N")
        let p2 = try HubAPI.page(resp(200, "{\"facts\":[{\"id\":\"a\"}],\"has_more\":true}"), key: "facts").get()
        XCTAssertEqual(p2.items.count, 1)
        XCTAssertTrue(p2.hasMore)
        XCTAssertNil(p2.nextCursor)
    }

    func testEmptyPage() throws {
        let p = try HubAPI.page(resp(200, "[]")).get()
        XCTAssertTrue(p.items.isEmpty)
        XCTAssertFalse(p.hasMore)
        XCTAssertNil(p.nextCursor)
    }

    func testGarbageBodyIsBadResponse() {
        XCTAssertEqual(HubAPI.page(resp(200, "<html>")).failure, .badResponse)
        XCTAssertEqual(HubAPI.object(resp(200, "[1]")).failure, .badResponse)
    }

    // MARK: errors → Korean

    func testErrorMapping() {
        let e401 = HubAPI.error(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}"))
        XCTAssertEqual(e401.text, "로그인이 필요해요.")
        XCTAssertTrue(e401.isUnauthorized)
        XCTAssertEqual(HubAPI.error(resp(404, "{}")).text, "찾지 못했어요.")
        let e409 = HubAPI.error(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}"))
        XCTAssertEqual(e409.text, "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요.")
        XCTAssertEqual(e409.code, "version_conflict")
        XCTAssertTrue(HubAPI.error(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}")).isVersionConflict)
        let e500 = HubAPI.error(resp(500, "oops"))
        XCTAssertEqual(e500.text, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        let e402 = HubAPI.error(resp(402, "{\"error\":{\"code\":\"credits_exhausted\",\"message\":\"m\",\"reason\":\"heavy_daily_limit\"}}"))
        XCTAssertEqual(e402.text, "오늘 맡길 수 있는 큰 일을 다 썼어요.")
    }

    // MARK: client (401 → one token refresh)

    final class FakeHTTP: PetHTTPClient {
        var sent: [PetHTTPRequest] = []
        var answers: [Result<PetHTTPResponse, Error>]
        init(_ a: [Result<PetHTTPResponse, Error>]) { answers = a }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            completion(answers.removeFirst())
        }
    }
    struct Boom: Error {}

    private func ok(_ s: String = "{}") -> Result<PetHTTPResponse, Error> { .success(PetHTTPResponse(status: 200, body: Data(s.utf8))) }
    private func unauth() -> Result<PetHTTPResponse, Error> {
        .success(PetHTTPResponse(status: 401, body: Data("{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}".utf8)))
    }

    func testClientRetriesOnceAfter401WithNewToken() {
        let http = FakeHTTP([unauth(), ok("{\"remaining\":5}")])
        var asked: [Bool] = []
        let client = HubClient(endpoint: endpoint, http: http, tokens: { force, done in
            asked.append(force)
            done(force ? "NEW" : "OLD")
        })
        var result: Result<PetHTTPResponse, PetAPIError>?
        client.send { HubAPI.get(self.endpoint, "/api/v1/me/usage", bearer: $0) } completion: { result = $0 }
        XCTAssertEqual(http.sent.map { $0.headers["Authorization"] }, ["Bearer OLD", "Bearer NEW"])
        XCTAssertEqual(asked, [false, true])
        XCTAssertEqual(try? result?.get().status, 200)
    }

    func testClientGivesUpAfterSecond401() {
        let http = FakeHTTP([unauth(), unauth()])
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("T") })
        var result: Result<PetHTTPResponse, PetAPIError>?
        client.send { HubAPI.get(self.endpoint, "/x", bearer: $0) } completion: { result = $0 }
        XCTAssertEqual(http.sent.count, 2)
        XCTAssertEqual(result?.failure?.isUnauthorized, true)
    }

    func testClientNoTokenIsUnauthorizedWithoutSending() {
        let http = FakeHTTP([])
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done(nil) })
        var result: Result<PetHTTPResponse, PetAPIError>?
        client.send { HubAPI.get(self.endpoint, "/x", bearer: $0) } completion: { result = $0 }
        XCTAssertTrue(http.sent.isEmpty)
        XCTAssertEqual(result?.failure?.text, "로그인이 필요해요.")
    }

    func testClientNetworkFailure() {
        let http = FakeHTTP([.failure(Boom())])
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("T") })
        var result: Result<PetHTTPResponse, PetAPIError>?
        client.send { HubAPI.get(self.endpoint, "/x", bearer: $0) } completion: { result = $0 }
        XCTAssertEqual(result?.failure, .network)
    }

    func testClientMapsServerErrorsAndDoesNotRetryThem() {
        let http = FakeHTTP([.success(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}"))])
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("T") })
        var result: Result<PetHTTPResponse, PetAPIError>?
        client.send { HubAPI.patch(self.endpoint, "/x", bearer: $0, json: [:], expectedVersion: 1) } completion: { result = $0 }
        XCTAssertEqual(http.sent.count, 1)
        XCTAssertEqual(result?.failure?.isVersionConflict, true)
    }

    // MARK: usage through the hub (H1)

    func testUsageRequestAndDecodeViaHub() throws {
        let r = HubAPI.get(endpoint, "/api/v1/me/usage", bearer: "T")
        XCTAssertEqual(r, PetServerAPI.usageRequest(endpoint, bearer: "T"))
        let u = try XCTUnwrap(PetServerAPI.decodeUsage(Data("{\"remaining\":120,\"allowance\":300,\"plan_id\":\"free\",\"period\":\"week\",\"reset_at\":\"2026-11-20T00:00:00Z\",\"exhausted\":false,\"low_balance\":false}".utf8)))
        XCTAssertEqual(u.remaining, 120)
    }

    // MARK: feature flags

    func testFeatureFlagDefaults() {
        XCTAssertFalse(HubFeatureFlags.accountDelete)
        XCTAssertFalse(HubFeatureFlags.memoryDeleteAll)
        XCTAssertTrue(HubFeatureFlags.scheduleRunNow)
        XCTAssertTrue(HubFeatureFlags.agentPhotoCreate)
    }

    func testSectionIDsFixedOrder() {
        XCTAssertEqual(HubSectionID.allCases.map { $0.rawValue },
                       ["account", "notifications", "rooms", "groups", "tasks", "schedules", "memory", "nachos", "friends", "trust", "usage", "explore", "archive"])
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e }; return nil }
}
