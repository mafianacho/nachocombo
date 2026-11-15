import XCTest
@testable import NachoComboCore

/// 기억 섹션(NACHO-273 U7)의 Core: 요청 바이트·응답 해석·입력 검증·되돌리기 만료. 가짜 응답만 쓰고 운영 서버는 부르지 않는다.
final class HubMemoryTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, body: Data(json.utf8)) }

    // MARK: request bytes

    func testListFactsQueryOrderAndBearer() {
        let r = HubMemoryAPI.listFacts(e, bearer: "T", limit: 50, before: "2026-11-01T00:00:00Z")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/memory/facts?limit=50&before=2026-11-01T00%3A00%3A00Z")
        XCTAssertEqual(r.headers["Authorization"], "Bearer T")
        XCTAssertNil(r.body)
        XCTAssertEqual(HubMemoryAPI.listFacts(e, bearer: "T", limit: 50).url.absoluteString, "https://nacho.example.com/api/v1/memory/facts?limit=50")
    }

    func testCreateFactBodyAndIdempotencyKey() {
        let r = HubMemoryAPI.createFact(e, bearer: "T", text: "커피는 라떼", category: "favorites", visibility: "shared", idempotencyKey: "K1")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/memory/facts")
        XCTAssertEqual(r.headers["Idempotency-Key"], "K1")
        XCTAssertEqual(body(r), "{\"category\":\"favorites\",\"text\":\"커피는 라떼\",\"visibility\":\"shared\"}")
    }

    func testUpdateFactPutsExpectedVersionInBody() {
        let r = HubMemoryAPI.updateFact(e, bearer: "T", id: "f1", text: "수정", category: "other", visibility: "shared", confirmGuess: true, expectedVersion: 4)
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.url.path, "/api/v1/memory/facts/f1")
        XCTAssertEqual(body(r), "{\"category\":\"other\",\"expected_version\":4,\"inferred\":false,\"text\":\"수정\",\"visibility\":\"shared\"}")
        XCTAssertNil(r.url.query)
    }

    func testForgetAndRestoreAndSeenAndSettings() {
        let d = HubMemoryAPI.forgetFact(e, bearer: "T", id: "f1")
        XCTAssertEqual(d.method, "DELETE"); XCTAssertEqual(d.url.path, "/api/v1/memory/facts/f1"); XCTAssertNil(d.body)
        let de = HubMemoryAPI.forgetEpisode(e, bearer: "T", id: "e1")
        XCTAssertEqual(de.method, "DELETE"); XCTAssertEqual(de.url.path, "/api/v1/memory/episodes/e1")
        let r = HubMemoryAPI.restore(e, bearer: "T", id: "f1")
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.url.path, "/api/v1/memory/f1/restore"); XCTAssertEqual(body(r), "{}")
        let s = HubMemoryAPI.markAllSeen(e, bearer: "T")
        XCTAssertEqual(s.url.path, "/api/v1/memory/facts/seen"); XCTAssertEqual(body(s), "{\"all\":true}")
        XCTAssertEqual(HubMemoryAPI.getSettings(e, bearer: "T").url.path, "/api/v1/me/memory-settings")
        let p = HubMemoryAPI.patchSettings(e, bearer: "T", paused: true, indicator: nil)
        XCTAssertEqual(p.method, "PATCH"); XCTAssertEqual(body(p), "{\"memory_paused\":true}")
        let both = HubMemoryAPI.patchSettings(e, bearer: "T", paused: false, indicator: false)
        XCTAssertEqual(body(both), "{\"memory_indicator_enabled\":false,\"memory_paused\":false}")
        let all = HubMemoryAPI.forgetAll(e, bearer: "T")
        XCTAssertEqual(all.method, "DELETE"); XCTAssertEqual(all.url.path, "/api/v1/me/memories")
    }

    func testEpisodeRequests() {
        XCTAssertEqual(HubMemoryAPI.listEpisodes(e, bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/memory/episodes")
        XCTAssertEqual(HubMemoryAPI.getEpisode(e, bearer: "T", id: "e1").url.path, "/api/v1/memory/episodes/e1")
        let u = HubMemoryAPI.updateEpisode(e, bearer: "T", id: "e1", title: "제목", content: "내용", expectedVersion: 2)
        XCTAssertEqual(u.method, "PATCH")
        XCTAssertEqual(body(u), "{\"content\":\"내용\",\"expected_version\":2,\"title\":\"제목\"}")
    }

    // MARK: responses

    func testDecodeFactList() throws {
        let json = "{\"facts\":[{\"id\":\"f1\",\"text\":\"라떼\",\"category\":\"favorites\",\"visibility\":\"shared\",\"source_type\":\"user\",\"inferred\":false,\"edited_by_user\":true,\"version\":3,\"created_at\":\"2026-11-02T01:00:00Z\",\"seen_at\":\"2026-11-02T02:00:00Z\"},"
            + "{\"id\":\"f2\",\"text\":\"산책\",\"category\":\"rhythm\",\"visibility\":\"own\",\"source_type\":\"inferred\",\"inferred\":true,\"edited_by_user\":false,\"version\":1,\"created_at\":\"2026-11-01T01:00:00Z\",\"author_name_snapshot\":\"나초\"}],\"unseen_count\":1,\"has_more\":true}"
        let l = try HubMemoryAPI.decodeFacts(resp(200, json)).get()
        XCTAssertEqual(l.facts.map { $0.id }, ["f1", "f2"])
        XCTAssertEqual(l.unseenCount, 1)
        XCTAssertTrue(l.hasMore)
        XCTAssertEqual(l.nextBefore, "2026-11-01T01:00:00Z")
        XCTAssertEqual(l.facts[0].version, 3)
        XCTAssertTrue(l.facts[0].editedByUser)
        XCTAssertFalse(l.facts[0].isUnseen)
        XCTAssertTrue(l.facts[1].isUnseen)
        XCTAssertTrue(l.facts[1].inferred)
        XCTAssertEqual(l.facts[1].authorName, "나초")
    }

    func testDecodeEmptyFactList() throws {
        let l = try HubMemoryAPI.decodeFacts(resp(200, "{\"facts\":[],\"unseen_count\":0,\"has_more\":false}")).get()
        XCTAssertTrue(l.facts.isEmpty)
        XCTAssertNil(l.nextBefore)
        XCTAssertFalse(l.hasMore)
    }

    func testDecodeEpisodesFlattensSections() throws {
        let json = "{\"sections\":[{\"key\":\"2026-11-02\",\"date_label\":\"11월 2일 (월)\",\"count\":1,\"items\":[{\"id\":\"e1\",\"title\":\"산책\",\"summary\":\"공원\",\"date\":\"2026-11-02\",\"visibility\":\"shared\",\"version\":2,\"edited_by_user\":false}]}],\"month\":\"2026-11\",\"day_counts\":[]}"
        let eps = try HubMemoryAPI.decodeEpisodes(resp(200, json)).get()
        XCTAssertEqual(eps.count, 1)
        XCTAssertEqual(eps[0].title, "산책")
        XCTAssertEqual(eps[0].dateLabel, "11월 2일 (월)")
        XCTAssertEqual(try HubMemoryAPI.decodeEpisodes(resp(200, "{\"sections\":[],\"month\":\"2026-11\",\"day_counts\":[]}")).get().count, 0)
    }

    func testDecodeEpisodeViewAndSettings() throws {
        let ep = try HubMemoryAPI.decodeEpisode(resp(200, "{\"id\":\"e1\",\"title\":\"T\",\"summary\":\"S\",\"date\":\"2026-11-02\",\"visibility\":\"own\",\"version\":5,\"edited_by_user\":true,\"content\":\"# 소제목\\n- 항목\",\"date_label\":\"11월 2일 (월)\"}")).get()
        XCTAssertEqual(ep.content, "# 소제목\n- 항목")
        XCTAssertEqual(ep.version, 5)
        let s = try HubMemoryAPI.decodeSettings(resp(200, "{\"memory_paused\":true,\"memory_indicator_enabled\":false}")).get()
        XCTAssertTrue(s.paused); XCTAssertFalse(s.indicatorEnabled)
        XCTAssertEqual(try HubMemoryAPI.decodeDeleted(resp(200, "{\"deleted\":12}")).get(), 12)
    }

    func testErrorsAre401404409AndServerKorean() {
        func code(_ r: Result<HubMemoryFactList, PetAPIError>) -> PetAPIError? { if case let .failure(e) = r { return e } else { return nil } }
        let e401 = code(HubMemoryAPI.decodeFacts(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")))
        XCTAssertEqual(e401?.status, 401)
        XCTAssertEqual(HubMemoryText.error(e401!), "로그인이 필요해요.")
        let e404 = code(HubMemoryAPI.decodeFacts(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")))
        XCTAssertEqual(HubMemoryText.error(e404!), "이 기억은 이제 없어요.")
        let e409 = code(HubMemoryAPI.decodeFacts(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"}}")))
        XCTAssertTrue(e409!.isVersionConflict)
        XCTAssertEqual(HubMemoryText.error(e409!), "다른 곳에서 바뀌었어요. 새로 불러올게요.")
        let e500 = code(HubMemoryAPI.decodeFacts(resp(500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"boom\"}}")))
        XCTAssertEqual(HubMemoryText.error(e500!), "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        let e422 = code(HubMemoryAPI.decodeFacts(resp(400, "{\"error\":{\"code\":\"validation_error\",\"message\":\"x\"}}")))
        XCTAssertEqual(HubMemoryText.error(e422!), "쓸 수 없는 내용이에요.")
        XCTAssertNotNil(code(HubMemoryAPI.decodeFacts(resp(200, "not json"))))
    }

    // MARK: 입력 검증 (앱·서버 규칙: 사실 1–4000자, 추억 제목 1–100자·내용 ≤20000자, 글자 수는 코드 포인트)

    func testFactTextValidation() {
        XCTAssertNotNil(HubMemoryRules.factTextProblem(""))
        XCTAssertNotNil(HubMemoryRules.factTextProblem("   \n "))
        XCTAssertNil(HubMemoryRules.factTextProblem("라떼를 좋아해요"))
        XCTAssertNil(HubMemoryRules.factTextProblem(String(repeating: "가", count: 4000)))
        XCTAssertEqual(HubMemoryRules.factTextProblem(String(repeating: "가", count: 4001)), "기억은 4000자까지 쓸 수 있어요.")
        XCTAssertNil(HubMemoryRules.factTextProblem(String(repeating: "😀", count: 4000)), "코드 포인트 기준")
    }

    func testEpisodeValidation() {
        XCTAssertEqual(HubMemoryRules.episodeProblem(title: "", content: "내용"), "제목과 내용을 모두 써 주세요.")
        XCTAssertEqual(HubMemoryRules.episodeProblem(title: "제목", content: "  "), "제목과 내용을 모두 써 주세요.")
        XCTAssertEqual(HubMemoryRules.episodeProblem(title: String(repeating: "a", count: 101), content: "x"), "제목은 100자까지 쓸 수 있어요.")
        XCTAssertEqual(HubMemoryRules.episodeProblem(title: "t", content: String(repeating: "a", count: 20001)), "내용은 20000자까지 쓸 수 있어요.")
        XCTAssertNil(HubMemoryRules.episodeProblem(title: String(repeating: "a", count: 100), content: String(repeating: "a", count: 20000)))
    }

    // MARK: 되돌리기: 10초, 지난 뒤는 서버 410 restore_expired

    func testUndoWindowIsTenSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let u = HubMemoryUndo(id: "f1", kind: .fact, forgottenAt: t0)
        XCTAssertFalse(u.isExpired(now: t0.addingTimeInterval(9.9)))
        XCTAssertTrue(u.isExpired(now: t0.addingTimeInterval(10)))
        XCTAssertTrue(u.isExpired(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(HubMemoryUndo.window, 10)
    }

    func testRestoreExpired410ShowsAppWording() {
        guard case let .failure(err) = HubMemoryAPI.decodeRestore(resp(410, "{\"error\":{\"code\":\"restore_expired\",\"message\":\"x\"}}")) else { return XCTFail("410 is a failure") }
        XCTAssertEqual(err.code, "restore_expired")
        XCTAssertEqual(HubMemoryText.error(err), "되돌릴 시간이 지났어요.")
        XCTAssertNoThrow(try HubMemoryAPI.decodeRestore(resp(200, "{\"kind\":\"fact\",\"item\":{}}")).get())
    }
}
