import XCTest
@testable import NachoComboCore

/// 허브 대화 섹션(NACHO-269 U3: B6·B7·B8·B11·B12) Core. 요청은 바이트 단위로, 응답·오류·입력 검증·내려받기 이름까지 확인한다.
final class HubRoomsTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private let rid = "11111111-1111-1111-1111-111111111111"

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String, headers: [String: String] = [:]) -> PetHTTPResponse {
        PetHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    // MARK: request bytes

    func testSyncAndGetAndList() {
        let s = HubRoomsAPI.syncRequest(e, bearer: "T")
        XCTAssertEqual(s.method, "GET")
        XCTAssertEqual(s.url.absoluteString, "https://nacho.example.com/api/v1/rooms/sync")
        XCTAssertEqual(s.headers["Authorization"], "Bearer T")
        XCTAssertNil(s.body)
        XCTAssertEqual(HubRoomsAPI.getRequest(e, id: rid, bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/rooms/\(rid)")
        let l = HubRoomsAPI.listRequest(e, stored: true, limit: 50, next: nil, bearer: "T")
        XCTAssertEqual(l.url.absoluteString, "https://nacho.example.com/api/v1/rooms?stored=true&limit=50")
        let l2 = HubRoomsAPI.listRequest(e, stored: true, limit: 50, next: [("before", "CUR")], bearer: "T")
        XCTAssertEqual(l2.url.absoluteString, "https://nacho.example.com/api/v1/rooms?stored=true&limit=50&before=CUR")
    }

    func testRenameStoreAndDeleteBodies() {
        let r = HubRoomsAPI.renameRequest(e, id: rid, title: "점심 약속", version: 4, bearer: "T")
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/rooms/\(rid)")
        XCTAssertEqual(body(r), "{\"expected_version\":4,\"title\":\"점심 약속\"}")
        let s = HubRoomsAPI.storeRequest(e, id: rid, stored: true, version: 5, bearer: "T")
        XCTAssertEqual(s.method, "PATCH")
        XCTAssertEqual(body(s), "{\"expected_version\":5,\"stored\":true}")
        // nacho-server spec: DELETE /rooms/{id}는 본문이 없다.
        let d = HubRoomsAPI.deleteRequest(e, id: rid, bearer: "T")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/rooms/\(rid)")
        XCTAssertNil(d.body)
    }

    func testSearchRequestIsPostWithQueryInBodyNotUrl() {
        let r = HubRoomsAPI.searchRequest(e, query: "비밀 메모", roomID: nil, limit: 50, next: nil, bearer: "T")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/messages/search")
        XCTAssertEqual(body(r), "{\"limit\":50,\"query\":\"비밀 메모\"}")
        let r2 = HubRoomsAPI.searchRequest(e, query: "a", roomID: rid, limit: 20, next: [("before", "CUR")], bearer: "T")
        XCTAssertEqual(body(r2), "{\"before\":\"CUR\",\"limit\":20,\"query\":\"a\",\"room_id\":\"\(rid)\"}")
    }

    func testMediaFilesLinksHistoryRequests() {
        XCTAssertEqual(HubRoomsAPI.roomMediaRequest(e, id: rid, kind: .photos, next: nil, bearer: "T").url.absoluteString,
                       "https://nacho.example.com/api/v1/rooms/\(rid)/media")
        XCTAssertEqual(HubRoomsAPI.roomMediaRequest(e, id: rid, kind: .files, next: [("cursor", "N")], bearer: "T").url.absoluteString,
                       "https://nacho.example.com/api/v1/rooms/\(rid)/files?cursor=N")
        XCTAssertEqual(HubRoomsAPI.roomMediaRequest(e, id: rid, kind: .links, next: nil, bearer: "T").url.absoluteString,
                       "https://nacho.example.com/api/v1/rooms/\(rid)/links")
        XCTAssertEqual(HubRoomsAPI.historyRequest(e, id: rid, beforeSeq: nil, limit: 50, bearer: "T").url.absoluteString,
                       "https://nacho.example.com/api/v1/rooms/\(rid)/history?view=app&limit=50")
        XCTAssertEqual(HubRoomsAPI.historyRequest(e, id: rid, beforeSeq: 31, limit: 50, bearer: "T").url.absoluteString,
                       "https://nacho.example.com/api/v1/rooms/\(rid)/history?view=app&limit=50&before_seq=31")
    }

    func testPageAndMediaRequests() {
        XCTAssertEqual(HubRoomsAPI.pageRequest(e, id: "p1", bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/pages/p1")
        XCTAssertEqual(HubRoomsAPI.pageDownloadRequest(e, id: "p1", bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/pages/p1/download")
        XCTAssertEqual(HubRoomsAPI.mediaRequest(e, id: "m1", bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/media/m1")
        let d = HubRoomsAPI.mediaDeleteRequest(e, id: "m1", bearer: "T")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/media/m1")
        XCTAssertNil(d.body)
    }

    // MARK: decode

    private let roomJSON = "{\"id\":\"r1\",\"kind\":\"direct\",\"title\":\"여행\",\"stored\":false,\"version\":3,\"last_seq\":12,\"read_seq\":10,\"muted\":false,\"updated_at\":\"2026-11-14T01:00:00Z\"}"

    func testDecodeSyncMergesRoomsAndExtraConversations() throws {
        let json = "{\"rooms\":[{\"id\":\"c1\",\"kind\":\"character\",\"version\":1,\"stored\":false,\"last_seq\":3,\"read_seq\":3}],"
            + "\"extra_conversations\":[\(roomJSON)],\"unseen_request_count\":2}"
        let s = try HubRoomsAPI.decodeSync(resp(200, json)).get()
        XCTAssertEqual(s.rooms.map { $0.id }, ["c1", "r1"])
        XCTAssertEqual(s.unseenRequestCount, 2)
        XCTAssertEqual(s.rooms[1].title, "여행")
        XCTAssertEqual(s.rooms[1].version, 3)
        XCTAssertEqual(s.rooms[1].unread, 2)
    }

    func testRoomAbilitiesFollowServerRules() throws {
        func room(_ kind: String) -> HubRoom { HubRoom(HubObject(["id": "x", "kind": kind, "version": 1]))! }
        XCTAssertFalse(room("character").canRename)   // 1:1 방은 이름을 바꿀 수 없다(403)
        XCTAssertTrue(room("direct").canRename)
        XCTAssertFalse(room("character").canDelete)
        XCTAssertTrue(room("direct").canDelete)
        XCTAssertTrue(room("character_pair").canDelete)
        XCTAssertFalse(room("agent_group").canDelete)
        XCTAssertNil(HubRoom(HubObject(["kind": "direct"])), "id 없는 방은 버린다")
    }

    func testDecodeRoomListUsesBeforeCursorAndEmpty() throws {
        let p = try HubRoomsAPI.decodeRooms(resp(200, "[\(roomJSON)]", headers: ["X-Next-Before": "CUR"])).get()
        XCTAssertEqual(p.rooms.count, 1)
        XCTAssertEqual(p.next?.map { "\($0.0)=\($0.1)" }, ["before=CUR"])
        let empty = try HubRoomsAPI.decodeRooms(resp(200, "[]")).get()
        XCTAssertTrue(empty.rooms.isEmpty)
        XCTAssertNil(empty.next)
    }

    func testDisplayTitleFallsBack() {
        XCTAssertEqual(HubRoom(HubObject(["id": "x", "kind": "direct", "title": "  "]))!.displayTitle, "이름 없는 대화")
        XCTAssertEqual(HubRoom(HubObject(["id": "x", "kind": "direct", "peer_display_name": "민수"]))!.displayTitle, "민수")
    }

    func testDecodeSearchSegmentsAndCursor() throws {
        let json = "[{\"id\":\"m1\",\"kind\":\"chat\",\"segments\":[{\"text\":\"앞 \",\"match\":false},{\"text\":\"비밀\",\"match\":true},{\"text\":\" 뒤\",\"match\":false}],"
            + "\"label\":\"여행\",\"date_label\":\"2026.11.14\",\"room_id\":\"r1\",\"seq\":7,\"created_at\":\"2026-11-14T01:00:00Z\"},"
            + "{\"id\":\"line-3\",\"kind\":\"phone\",\"segments\":[],\"label\":\"통화\",\"date_label\":\"2026.11.13\"}]"
        let p = try HubRoomsAPI.decodeSearch(resp(200, json, headers: ["X-Next-Before": "S2"])).get()
        XCTAssertEqual(p.items.count, 2)
        XCTAssertEqual(p.items[0].roomID, "r1")
        XCTAssertEqual(p.items[0].seq, 7)
        XCTAssertEqual(p.items[0].segments.map { $0.match }, [false, true, false])
        XCTAssertEqual(p.items[0].plainText, "앞 비밀 뒤")
        XCTAssertNil(p.items[1].roomID, "통화 자막은 방으로 가지 않는다")
        XCTAssertEqual(p.next?.first?.1, "S2")
        XCTAssertTrue(try HubRoomsAPI.decodeSearch(resp(200, "[]")).get().items.isEmpty)
    }

    func testDecodeMediaFilesLinks() throws {
        let m = try HubRoomsAPI.decodeMedia(resp(200, "{\"photos\":[{\"kind\":\"image\",\"attachment_id\":\"a1\",\"name\":\"사진.png\",\"mime\":\"image/png\",\"bytes\":2048,\"url\":\"https://s/x?sig=1\"}],\"total\":9,\"next_cursor\":\"N\"}"), kind: .photos).get()
        XCTAssertEqual(m.items.count, 1)
        XCTAssertEqual(m.items[0].id, "a1")
        XCTAssertEqual(m.items[0].name, "사진.png")
        XCTAssertEqual(m.total, 9)
        XCTAssertEqual(m.next?.map { "\($0.0)=\($0.1)" }, ["cursor=N"])
        let f = try HubRoomsAPI.decodeMedia(resp(200, "{\"items\":[{\"seq\":4,\"name\":\"표.pdf\",\"mime\":\"application/pdf\",\"bytes\":10,\"attachment_id\":\"a2\"}]}"), kind: .files).get()
        XCTAssertEqual(f.items.first?.id, "a2")
        XCTAssertNil(f.next)
        let l = try HubRoomsAPI.decodeLinks(resp(200, "{\"items\":[{\"seq\":2,\"url\":\"https://example.com/a\"},{\"seq\":3,\"url\":\"javascript:alert(1)\"},{\"seq\":4,\"url\":\"file:///etc/passwd\"}]}")).get()
        XCTAssertEqual(l.items.map { $0.url }, ["https://example.com/a"], "http/https만 남긴다")
        XCTAssertTrue(try HubRoomsAPI.decodeMedia(resp(200, "{\"photos\":[],\"total\":0}"), kind: .photos).get().items.isEmpty)
    }

    func testDecodeHistoryWithHasMoreAndPageAttachment() throws {
        let json = "[{\"seq\":5,\"role\":\"user\",\"sender_kind\":\"user\",\"text\":\"안녕\",\"created_at\":\"2026-11-14T01:00:00Z\",\"attachments\":[]},"
            + "{\"seq\":6,\"role\":\"assistant\",\"sender_kind\":\"agent\",\"sender_name_snapshot\":\"나초\",\"text\":\"문서를 만들었어요\",\"attachments\":[{\"kind\":\"image\",\"attachment_id\":\"a1\",\"name\":\"그림.png\",\"mime\":\"image/png\",\"deleted\":false}],"
            + "\"attachment\":{\"file_id\":\"p1\",\"name\":\"여행 계획\",\"kind\":\"page\",\"deleted\":false}}]"
        let h = try HubRoomsAPI.decodeHistory(resp(200, json, headers: ["X-Has-More": "true"])).get()
        XCTAssertEqual(h.messages.map { $0.seq }, [5, 6])
        XCTAssertTrue(h.hasMore)
        XCTAssertEqual(h.messages[0].isMine, true)
        XCTAssertEqual(h.messages[1].senderName, "나초")
        XCTAssertEqual(h.messages[1].pageRef?.id, "p1")
        XCTAssertEqual(h.messages[1].pageRef?.title, "여행 계획")
        XCTAssertEqual(h.messages[1].attachments.first?.id, "a1")
        XCTAssertFalse(try HubRoomsAPI.decodeHistory(resp(200, "[]")).get().hasMore)
    }

    func testDecodePageDocBlocks() throws {
        let json = "{\"id\":\"p1\",\"title\":\"여행 계획\",\"blocks\":[{\"type\":\"heading\",\"text\":\"1일차\"},{\"type\":\"paragraph\",\"text\":\"**공항**에서 만나요\"},"
            + "{\"type\":\"list\",\"items\":[\"여권\",\"충전기\"]},{\"type\":\"table\",\"rows\":[[\"시간\",\"할 일\"],[\"9시\",\"출발\"]]},{\"type\":\"link\",\"text\":\"지도\",\"href\":\"https://example.com\"},{\"type\":\"hologram\"}]}"
        let d = try HubRoomsAPI.decodePage(resp(200, json)).get()
        XCTAssertEqual(d.title, "여행 계획")
        XCTAssertEqual(d.blocks.map { $0.type }, ["heading", "paragraph", "list", "table", "link", "hologram"])
        XCTAssertEqual(d.blocks[2].items, ["여권", "충전기"])
        XCTAssertEqual(d.blocks[3].rows, [["시간", "할 일"], ["9시", "출발"]])
        XCTAssertEqual(d.blocks[4].href, "https://example.com")
    }

    // MARK: errors (404·409·401·서버 오류 → 한국어)

    func testErrorsAreKorean() {
        XCTAssertEqual(HubRoomsAPI.decodeSync(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failure?.text, "로그인이 필요해요.")
        XCTAssertEqual(HubRoomsAPI.decodeSync(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failure?.isUnauthorized, true)
        XCTAssertEqual(HubRoomsAPI.decodePage(resp(404, "{}")).failure?.text, "찾지 못했어요.")
        XCTAssertEqual(HubRoomsAPI.decodePage(resp(404, "{}")).failure?.isNotFound, true)
        let conflict = HubRoomsAPI.decodeRoom(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}"))
        XCTAssertEqual(conflict.failure?.isVersionConflict, true)
        XCTAssertEqual(conflict.failure?.text, "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요.")
        XCTAssertEqual(HubRoomsAPI.decodeSearch(resp(400, "{\"error\":{\"code\":\"validation_error\",\"message\":\"m\"}}")).failure?.status, 400)
        XCTAssertEqual(HubRoomsAPI.decodeSearch(resp(500, "oops")).failure?.text, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        XCTAssertEqual(HubRoomsAPI.decodeDone(resp(404, "{}")).failure?.isNotFound, true)
        XCTAssertNotNil(try? HubRoomsAPI.decodeDone(resp(204, "")).get())
        XCTAssertEqual(HubRoomsAPI.decodeSync(resp(200, "<html>")).failure, .badResponse)
    }

    // MARK: 입력 검증 (앱 규칙 그대로)

    func testTitleRules() {
        XCTAssertEqual(try? HubRoomsAPI.normalizeTitle("  여행  ").get(), "여행")
        XCTAssertEqual(HubRoomsAPI.normalizeTitle("   ").failure, "이름을 적어 주세요.")
        XCTAssertEqual(HubRoomsAPI.normalizeTitle("가\n나").failure, "이름에 줄바꿈은 쓸 수 없어요.")
        XCTAssertEqual(HubRoomsAPI.normalizeTitle(String(repeating: "가", count: 41)).failure, "이름은 40자까지 쓸 수 있어요.")
        XCTAssertNotNil(try? HubRoomsAPI.normalizeTitle(String(repeating: "가", count: 40)).get())
        // 이모지 하나는 한 글자(코드 포인트)로 센다.
        XCTAssertNotNil(try? HubRoomsAPI.normalizeTitle(String(repeating: "😀", count: 40)).get())
    }

    func testSearchQueryRules() {
        XCTAssertEqual(try? HubRoomsAPI.normalizeQuery("  비밀 ").get(), "비밀")
        XCTAssertEqual(HubRoomsAPI.normalizeQuery("").failure, "검색어를 입력해 주세요.")
        XCTAssertEqual(HubRoomsAPI.normalizeQuery(" \t ").failure, "검색어를 입력해 주세요.")
        XCTAssertEqual(HubRoomsAPI.normalizeQuery("•••").failure, "검색어를 입력해 주세요.", "가린 구간 글자(•)만으로는 찾지 않는다")
        XCTAssertNotNil(try? HubRoomsAPI.normalizeQuery("•a").get())
    }

    // MARK: 내려받기 경로

    func testSafeFileName() {
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: "여행 계획"), "여행 계획.md")
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: "../../etc/passwd"), "etc-passwd.md")
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: "a/b\\c:d"), "a-b-c-d.md")
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: "  "), "문서.md")
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: ".hidden"), "hidden.md")
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: "a\nb\u{0}c"), "abc.md")
        XCTAssertLessThanOrEqual(HubRoomsAPI.downloadFileName(title: String(repeating: "가", count: 300)).count, 83)
        XCTAssertEqual(HubRoomsAPI.downloadFileName(title: "x.md"), "x.md")
        XCTAssertEqual(HubRoomsAPI.attachmentFileName("표/2.pdf", fallback: "파일"), "표-2.pdf")
        XCTAssertEqual(HubRoomsAPI.attachmentFileName(nil, fallback: "파일"), "파일")
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e }; return nil }
}
