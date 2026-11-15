import XCTest
@testable import NachoComboCore

/// 보관함(NACHO-264 U9: I2). 요청 바이트·목록 해석·저장 이름.
final class HubArchiveTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, headers: [:], body: Data(json.utf8)) }

    func testRequestBytes() {
        let l = HubArchiveAPI.list(e, bearer: "T")
        XCTAssertEqual(l.method, "GET")
        XCTAssertEqual(l.url.absoluteString, "https://nacho.example.com/api/v1/archive/files")
        XCTAssertEqual(HubArchiveAPI.list(e, bearer: "T", cursor: "2026-11-01T00:00:00Z").url.absoluteString,
                       "https://nacho.example.com/api/v1/archive/files?cursor=2026-11-01T00%3A00%3A00Z")
        let d = HubArchiveAPI.remove(e, id: "f-1", bearer: "T")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.path, "/api/v1/archive/files/f-1")
        XCTAssertNil(d.body)
        XCTAssertEqual(HubArchiveAPI.createOptions(e, bearer: "T").url.path, "/api/v1/archive/create-options")
        XCTAssertEqual(HubArchiveAPI.downloadPage(e, id: "p1", bearer: "T").url.path, "/api/v1/pages/p1/download")
        XCTAssertEqual(HubArchiveAPI.downloadMedia(e, id: "m1", bearer: "T").url.path, "/api/v1/media/m1")
    }

    func testDecodeList() throws {
        let json = "{\"file_sections\":[{\"key\":\"2026-11-14\",\"date_label\":\"11월 14일 (토)\",\"items\":[{\"id\":\"p1\",\"name\":\"여행 계획\",\"kind\":\"page\",\"source_label\":\"나초와의 대화\",\"author_name_snapshot\":\"나초\"},{\"id\":\"f1\",\"name\":\"메모.pdf\",\"kind\":\"file\",\"author_name_snapshot\":\"나\"}]}],\"media_sections\":[{\"key\":\"2026-11-13\",\"date_label\":\"11월 13일\",\"items\":[{\"id\":\"m1\",\"is_video\":true,\"duration_label\":\"1:05\",\"author_name_snapshot\":\"나초\"}]}],\"backfill_complete\":true,\"next_cursor\":\"2026-11-01T00:00:00Z\"}"
        let l = try HubArchiveAPI.decodeList(resp(200, json)).get()
        XCTAssertEqual(l.files.map { $0.id }, ["p1", "f1", "m1"])
        XCTAssertEqual(l.files.map { $0.canSave }, [true, false, true])
        XCTAssertTrue(l.files[2].isVideo)
        XCTAssertEqual(l.files[0].dateLabel, "11월 14일 (토)")
        XCTAssertEqual(l.nextCursor, "2026-11-01T00:00:00Z")
        XCTAssertTrue(l.hasMore)
        let empty = try HubArchiveAPI.decodeList(resp(200, "{\"file_sections\":[],\"media_sections\":[]}")).get()
        XCTAssertTrue(empty.files.isEmpty)
        XCTAssertFalse(empty.hasMore)
    }

    func testErrorsAndDelete() {
        XCTAssertEqual(HubArchiveAPI.decodeList(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failureValue?.text, "로그인이 필요해요.")
        XCTAssertEqual(HubArchiveAPI.decodeDeleted(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")).failureValue?.isNotFound, true)
        XCTAssertNotNil(try? HubArchiveAPI.decodeDeleted(resp(200, "{\"status\":\"ok\"}")).get())
        XCTAssertNotNil(try? HubArchiveAPI.decodeDeleted(resp(204, "")).get())
        XCTAssertTrue(HubArchiveAPI.decodeList(resp(500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")).failureValue?.text.contains("일시적인 문제") ?? false)
    }

    func testCreateOptions() throws {
        let json = "{\"options\":[{\"kind\":\"document\",\"formats\":[\"md\"],\"prompt_text\":\"문서를 만들어 줘\",\"credit\":{\"estimate_min\":5,\"estimate_max\":5,\"task_label\":\"x\"}}],\"last_agent_id\":\"a\",\"restrictions\":[{\"agent_id\":\"b\",\"reason\":\"resting\"}]}"
        let o = try HubArchiveAPI.decodeCreateOptions(resp(200, json)).get()
        XCTAssertEqual(o.options, [HubCreateOption(kind: "document", title: "문서", formats: ["md"], promptText: "문서를 만들어 줘", creditText: "예상 5 크레딧")])
        XCTAssertEqual(o.restrictionCount, 1)
    }

    func testSafeFileName() {
        XCTAssertEqual(HubArchiveAPI.safeFileName("여행/계획: 최종?", fallback: "page", ext: "md"), "여행_계획_ 최종.md")
        XCTAssertEqual(HubArchiveAPI.safeFileName("../..", fallback: "page", ext: "md"), "page.md")
        XCTAssertEqual(HubArchiveAPI.safeFileName("a.MD", fallback: "p", ext: "md"), "a.MD")
        XCTAssertEqual(HubArchiveAPI.safeFileName(String(repeating: "가", count: 200), fallback: "p", ext: "md").count, 83)
    }
}

private extension Result {
    var failureValue: PetAPIError? { if case let .failure(e) = self { return e as? PetAPIError }; return nil }
}
