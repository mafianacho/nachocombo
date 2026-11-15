import XCTest
@testable import NachoComboCore

/// 알림·활동 Core (NACHO-268 U2, 표 행 A7). 요청은 바이트 단위로, 응답·오류는 한국어 문구까지 확인한다.
final class HubNotificationsTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, body: Data(json.utf8)) }

    // MARK: 요청 바이트

    func testListRequestBytes() {
        let r = HubNotificationsAPI.listRequest(e, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me/notifications?limit=50")
        XCTAssertEqual(r.headers["Authorization"], "Bearer T")
        XCTAssertNil(r.body)
        let p = HubNotificationsAPI.listRequest(e, unreadOnly: true, limit: 20, before: "2026-11-01T09:00:00Z", bearer: "T")
        XCTAssertEqual(p.url.absoluteString, "https://nacho.example.com/api/v1/me/notifications?unread=true&limit=20&before=2026-11-01T09%3A00%3A00Z")
    }

    func testMarkReadRequestBytes() {
        let r = HubNotificationsAPI.markReadRequest(e, id: "n-1", bearer: "T")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me/notifications/n-1/read")
        XCTAssertEqual(body(r), "{}")
    }

    func testSettingsRequestBytes() throws {
        let g = HubNotificationSettingsAPI.getRequest(e, bearer: "T")
        XCTAssertEqual(g.method, "GET")
        XCTAssertEqual(g.url.absoluteString, "https://nacho.example.com/api/v1/me/notification-settings")
        let p = try XCTUnwrap(HubNotificationSettingsAPI.patchItemRequest(e, id: "task_done", on: false, bearer: "T"))
        XCTAssertEqual(p.method, "PATCH")
        XCTAssertEqual(p.url.absoluteString, "https://nacho.example.com/api/v1/me/notification-settings")
        XCTAssertEqual(body(p), "{\"items\":{\"task_done\":false}}")
        XCTAssertFalse(body(p).contains("expected_version"), "이 경로는 낙관적 잠금이 없다")
    }

    func testAutoPaymentCannotBeTurnedOffButCanBeOn() {
        XCTAssertNil(HubNotificationSettingsAPI.patchItemRequest(e, id: "auto_payment", on: false, bearer: "T"))
        XCTAssertNotNil(HubNotificationSettingsAPI.patchItemRequest(e, id: "auto_payment", on: true, bearer: "T"))
    }

    func testActivityRequestBytes() {
        let f = HubActivityAPI.feedRequest(e, bearer: "T")
        XCTAssertEqual(f.method, "GET")
        XCTAssertEqual(f.url.absoluteString, "https://nacho.example.com/api/v1/activity")
        let s = HubActivityAPI.seenRequest(e, bearer: "T")
        XCTAssertEqual(s.method, "POST")
        XCTAssertEqual(s.url.absoluteString, "https://nacho.example.com/api/v1/activity/seen")
        XCTAssertEqual(body(s), "{}")
    }

    // MARK: 목록 해석

    private func row(_ id: String, kind: String = "task_done", read: Bool = false, at: String = "2026-11-15T09:00:00Z", data: String = "{}") -> String {
        "{\"id\":\"\(id)\",\"user_id\":\"u\",\"kind\":\"\(kind)\",\"title\":\"제목\(id)\",\"body\":\"본문\",\"data\":\(data),\"read_at\":\(read ? "\"2026-11-15T10:00:00Z\"" : "null"),\"created_at\":\"\(at)\"}"
    }

    func testParseListAndUnreadCount() throws {
        let page = try HubNotificationsAPI.parseList(resp(200, "[\(row("a")),\(row("b", read: true))]"), limit: 50).get()
        XCTAssertEqual(page.items.map { $0.id }, ["a", "b"])
        XCTAssertEqual(page.items.map { $0.isUnread }, [true, false])
        XCTAssertFalse(page.hasMore)
        XCTAssertNil(page.nextBefore)
        XCTAssertEqual(HubNotificationsAPI.badgeCount(notifications: page.items, activityUnread: 3), 4)
        XCTAssertEqual(HubNotificationsAPI.badgeCount(notifications: [], activityUnread: -2), 0)
    }

    func testFullPageGivesNextBeforeFromLastCreatedAt() throws {
        let rows = [row("a", at: "2026-11-15T09:00:00Z"), row("b", at: "2026-11-14T08:00:00Z")].joined(separator: ",")
        let page = try HubNotificationsAPI.parseList(resp(200, "[\(rows)]"), limit: 2).get()
        XCTAssertEqual(page.nextBefore, "2026-11-14T08:00:00Z")
        XCTAssertTrue(page.hasMore)
    }

    func testEmptyList() throws {
        let page = try HubNotificationsAPI.parseList(resp(200, "[]")).get()
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
    }

    func testErrorsAreKorean() {
        XCTAssertEqual(HubNotificationsAPI.parseList(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failure?.text, "로그인이 필요해요.")
        XCTAssertEqual(HubNotificationsAPI.parseList(resp(404, "{}")).failure?.text, "찾지 못했어요.")
        XCTAssertEqual(HubNotificationsAPI.parseList(resp(500, "oops")).failure?.text, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        XCTAssertEqual(HubNotificationsAPI.parseList(resp(200, "<html>")).failure, .badResponse)
        XCTAssertEqual(HubNotificationSettingsAPI.parse(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}")).failure?.text,
                       "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요.")
        XCTAssertEqual(HubActivityAPI.parseFeed(resp(404, "{}")).failure?.text, "찾지 못했어요.")
        XCTAssertEqual(HubActivityAPI.parseSeen(resp(500, "oops")).failure?.text, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
    }

    // MARK: 이동·표시 규칙

    func testDestinationBySectionOrNilForJustRead() throws {
        func n(_ kind: String, data: String = "{}") throws -> HubNotification {
            try XCTUnwrap(HubNotificationsAPI.parseList(resp(200, "[\(row("x", kind: kind, data: data))]")).get().items.first)
        }
        XCTAssertEqual(HubNotificationsAPI.destination(try n("usage_low")), .usage)
        XCTAssertEqual(HubNotificationsAPI.destination(try n("connection_expired")), .trust)
        XCTAssertEqual(HubNotificationsAPI.destination(try n("task_done", data: "{\"task_id\":\"t1\"}")), .tasks)
        XCTAssertEqual(HubNotificationsAPI.destination(try n("mention", data: "{\"room_id\":\"r1\"}")), .rooms)
        XCTAssertNil(HubNotificationsAPI.destination(try n("something_new")), "갈 곳을 모르면 읽음 처리만")
    }

    func testPeopleKindsLiveInActivityNotInbox() {
        XCTAssertFalse(HubNotificationsAPI.isInboxKind("friend_request"))
        XCTAssertFalse(HubNotificationsAPI.isInboxKind("agreement_confirm"))
        XCTAssertTrue(HubNotificationsAPI.isInboxKind("task_done"))
    }

    func testPaymentBodyIsHiddenTaskBodyShown() throws {
        let paid = try XCTUnwrap(HubNotificationsAPI.parseList(resp(200, "[\(row("p", kind: "payment_confirmed"))]")).get().items.first)
        XCTAssertNil(HubNotificationsAPI.shownBody(paid))
        let done = try XCTUnwrap(HubNotificationsAPI.parseList(resp(200, "[\(row("d"))]")).get().items.first)
        XCTAssertEqual(HubNotificationsAPI.shownBody(done), "본문")
    }

    // MARK: 설정

    func testParseSettingsAndDefaults() throws {
        let s = try HubNotificationSettingsAPI.parse(resp(200, "{\"all_enabled\":true,\"items\":{\"task_done\":false},\"muted_agent_ids\":[\"a1\",\"a2\"]}")).get()
        XCTAssertTrue(s.allEnabled)
        XCTAssertFalse(s.isOn("task_done"))
        XCTAssertTrue(s.isOn("task_failed"), "없는 항목은 기본 켜짐")
        XCTAssertFalse(s.isOn("task_delayed"), "기본 꺼짐")
        XCTAssertFalse(s.isOn("nacho_checkin"))
        XCTAssertEqual(s.mutedAgentIDs, ["a1", "a2"])
    }

    func testCatalogHasSeventeenItemsInAppOrder() {
        let ids = HubNotificationCatalog.groups.flatMap { $0.items.map { $0.id } }
        XCTAssertEqual(ids.count, 17)
        XCTAssertEqual(Set(ids).count, 17)
        XCTAssertEqual(ids.first, "approval_input")
        XCTAssertTrue(HubNotificationCatalog.needsWarning("approval_input"))
        XCTAssertFalse(HubNotificationCatalog.needsWarning("task_done"))
    }

    // MARK: 활동

    func testParseFeedDropsUnknownKindsAndActions() throws {
        let json = """
        {"sections":[{"key":"2026-11-15","date_label":"오늘","items":[
          {"id":"1","kind":"friend_request","created_at_ms":1,"time_label":"14:05","unread":true,"actor":{"user_id":"u","actor_kind":"person","display_name":"가짜친구"},"action":"accept_decline"},
          {"id":"2","kind":"alien","created_at_ms":1,"time_label":"14:06","unread":false},
          {"id":"3","kind":"memory","created_at_ms":1,"time_label":"13:00","unread":false,"name_text":"나초","body_text":"산책","day":"2026-11-15","agent_id":"a"},
          {"id":"4","kind":"friend_chat","created_at_ms":1,"time_label":"12:00","unread":false,"action":"teleport"}]},
          {"key":"2026-11-14","date_label":"어제","items":[{"id":"5","kind":"nope","created_at_ms":1,"time_label":"1","unread":false}]}],
         "activity_unread_count":1}
        """
        let feed = try HubActivityAPI.parseFeed(resp(200, json)).get()
        XCTAssertEqual(feed.unreadCount, 1)
        XCTAssertEqual(feed.sections.count, 1, "빈 날짜 묶음은 뺀다")
        XCTAssertEqual(feed.sections[0].items.map { $0.id }, ["1", "3"])
        XCTAssertEqual(feed.sections[0].items[0].sentence, "가짜친구님이 친구 요청을 보냈어요")
        XCTAssertEqual(feed.sections[0].items[0].destination, .friends)
        XCTAssertEqual(feed.sections[0].items[1].destination, .memory)
        XCTAssertFalse(feed.isEmpty)
    }

    func testEmptyFeedAndSeen() throws {
        let feed = try HubActivityAPI.parseFeed(resp(200, "{\"sections\":[],\"activity_unread_count\":0}")).get()
        XCTAssertTrue(feed.isEmpty)
        XCTAssertEqual(try HubActivityAPI.parseSeen(resp(200, "{\"ok\":true,\"seen_at\":\"2026-11-15T10:00:00Z\",\"activity_unread_count\":0}")).get(), 0)
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e }; return nil }
}
