import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 알림·활동 섹션(NACHO-268 U2)을 가짜 HTTP로 장면별·라이트/다크로 그린다. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 테스트 로그(BENTO-CAPTURE 줄)로 CI에 남긴다. 데이터는 모두 가짜다.
final class HubNotificationsCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func n(_ id: String, kind: String = "task_done", title: String, body: String = "", read: Bool, at: String, data: String = "{}") -> String {
        "{\"id\":\"\(id)\",\"user_id\":\"u\",\"kind\":\"\(kind)\",\"title\":\"\(title)\",\"body\":\"\(body)\",\"data\":\(data),"
            + "\"read_at\":\(read ? "\"2026-11-15T10:00:00Z\"" : "null"),\"created_at\":\"\(at)\"}"
    }

    private lazy var listJSON = "[" + [
        n("n1", title: "작업이 끝났어요", body: "가짜 주간 보고서 정리", read: false, at: "2026-11-15T09:00:00Z", data: "{\"task_id\":\"t1\"}"),
        n("n2", kind: "usage_low", title: "사용량이 얼마 안 남았어요", read: false, at: "2026-11-15T08:00:00Z"),
        n("n3", kind: "connection_expiring", title: "연결이 곧 만료돼요", body: "가짜서비스 연결을 다시 해 주세요", read: true, at: "2026-11-14T08:00:00Z"),
    ].joined(separator: ",") + "]"

    private let feedJSON = """
    {"sections":[{"key":"2026-11-15","date_label":"오늘","items":[
      {"id":"a1","kind":"friend_request","created_at_ms":1,"time_label":"14:05","unread":true,"actor":{"user_id":"u1","actor_kind":"person","display_name":"가짜친구"},"action":"accept_decline"},
      {"id":"a2","kind":"memory","created_at_ms":1,"time_label":"13:00","unread":false,"name_text":"가짜나초","body_text":"공원 산책","day":"2026-11-15","agent_id":"ag"}]}],
     "activity_unread_count":1}
    """
    private let settingsJSON = "{\"all_enabled\":true,\"items\":{\"task_done\":false},\"muted_agent_ids\":[\"x\"]}"

    private final class FakeHTTP: PetHTTPClient {
        var routes: [String: (Int, String)] = [:]
        var sent: [PetHTTPRequest] = []
        var held: [(PetHTTPRequest, (Result<PetHTTPResponse, Error>) -> Void)] = []
        var hold = false
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            if hold && request.method != "GET" { held.append((request, completion)); return }
            completion(.success(answer(request)))
        }
        func answer(_ request: PetHTTPRequest) -> PetHTTPResponse {
            let key = request.method + " " + request.url.path
            let (status, body) = routes[key] ?? (200, "{}")
            return PetHTTPResponse(status: status, body: Data(body.utf8))
        }
        func keys() -> [String] { sent.map { $0.method + " " + $0.url.path } }
        func body(_ i: Int) -> String { String(data: sent[i].body ?? Data(), encoding: .utf8) ?? "" }
    }

    private final class Box { var toasts: [(String, Bool)] = []; var dest: [HubSectionID] = []; var badges: [Int] = [] }

    private func make(_ http: FakeHTTP, signedIn: Bool = true) -> (NotificationsSection, Box) {
        let box = Box()
        let client = HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: http, tokens: { _, done in done("fake-token") })
        let s = NotificationsSection()
        s.onNavigate = { box.dest.append($0) }
        s.onBadgeChange = { box.badges.append($0) }
        s.activate(HubContext(client: signedIn ? client : nil, toast: { box.toasts.append(($0, $1)) }, confirm: { _, _ in }))
        return (s, box)
    }

    private func standard() -> FakeHTTP {
        let h = FakeHTTP()
        h.routes["GET /api/v1/me/notifications"] = (200, listJSON)
        h.routes["GET /api/v1/activity"] = (200, feedJSON)
        h.routes["POST /api/v1/activity/seen"] = (200, "{\"ok\":true,\"seen_at\":\"2026-11-15T10:00:00Z\",\"activity_unread_count\":0}")
        h.routes["GET /api/v1/me/notification-settings"] = (200, settingsJSON)
        h.routes["POST /api/v1/me/notifications/n1/read"] = (200, "{\"ok\":true}")
        return h
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all(_ s: NotificationsSection) -> String { texts(s.view).joined(separator: "\n") }

    private func capture(_ section: NotificationsSection, dark: Bool, name: String) throws {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 752, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = PetBox()
        root.fill = PetTheme.color(\.window)
        w.contentView = root
        HubKit.pin(section.view, in: root)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try emit(png, name: "notifications-\(name)-\(dark ? "dark" : "light")")
    }

    // MARK: scenes

    func testListLoadsNotificationsAndActivityAndShowsBadge() throws {
        let http = standard()
        let (s, box) = make(http)
        XCTAssertEqual(http.keys(), ["GET /api/v1/me/notifications", "GET /api/v1/activity"])
        XCTAssertEqual(http.sent[0].url.query, "limit=50")
        let t = all(s)
        XCTAssertTrue(t.contains("작업이 끝났어요"), t)
        XCTAssertTrue(t.contains("안 읽은 알림 2개"), t)
        XCTAssertTrue(t.contains("가짜 주간 보고서 정리"), "작업 알림은 본문도 보인다")
        XCTAssertEqual(s.badge, 3, "안 읽은 알림 2 + 활동 1")
        XCTAssertEqual(box.badges.last, 3)
        for dark in [false, true] { try capture(s, dark: dark, name: "list") }
    }

    func testEmptyList() throws {
        let http = standard()
        http.routes["GET /api/v1/me/notifications"] = (200, "[]")
        let (s, _) = make(http)
        XCTAssertTrue(all(s).contains("알림이 없어요."))
        for dark in [false, true] { try capture(s, dark: dark, name: "empty") }
    }

    func testServerErrorShowsKoreanTextAndRetry() {
        let http = standard()
        http.routes["GET /api/v1/me/notifications"] = (500, "oops")
        let (s, _) = make(http)
        XCTAssertTrue(all(s).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
        XCTAssertTrue(all(s).contains("다시 시도"))
    }

    func testSignedOutAsksNothing() {
        let http = standard()
        let (s, _) = make(http, signedIn: false)
        XCTAssertTrue(http.sent.isEmpty)
        XCTAssertTrue(all(s).contains("로그인이 필요해요."))
    }

    func testTapUnreadMarksReadAndNavigates() throws {
        let http = standard()
        let (s, box) = make(http)
        let target = try XCTUnwrap(s.notifications.first { $0.id == "n1" })
        s.open(target)
        XCTAssertTrue(http.keys().contains("POST /api/v1/me/notifications/n1/read"))
        XCTAssertEqual(box.dest, [.tasks])
        XCTAssertFalse(try XCTUnwrap(s.notifications.first { $0.id == "n1" }).isUnread)
        XCTAssertEqual(s.badge, 2)
        // 이미 읽은 알림은 다시 보내지 않는다.
        let before = http.sent.count
        s.open(try XCTUnwrap(s.notifications.first { $0.id == "n1" }))
        XCTAssertEqual(http.sent.count, before)
    }

    func testTapWithoutDestinationOnlyMarksRead() throws {
        let http = standard()
        http.routes["GET /api/v1/me/notifications"] = (200, "[" + n("z1", kind: "something_new", title: "새 소식", read: false, at: "2026-11-15T09:00:00Z") + "]")
        http.routes["POST /api/v1/me/notifications/z1/read"] = (200, "{\"ok\":true}")
        let (s, box) = make(http)
        s.open(try XCTUnwrap(s.notifications.first))
        XCTAssertTrue(box.dest.isEmpty)
        XCTAssertTrue(http.keys().contains("POST /api/v1/me/notifications/z1/read"))
    }

    func testMarkReadFailureRevertsAndShowsToast() throws {
        let http = standard()
        http.routes["POST /api/v1/me/notifications/n1/read"] = (404, "{}")
        let (s, box) = make(http)
        s.open(try XCTUnwrap(s.notifications.first { $0.id == "n1" }))
        XCTAssertTrue(try XCTUnwrap(s.notifications.first { $0.id == "n1" }).isUnread)
        XCTAssertEqual(box.toasts.last?.0, "찾지 못했어요.")
        XCTAssertEqual(box.toasts.last?.1, true)
    }

    /// 요청이 가는 동안 사용자가 다른 섹션으로 옮겨도(섹션 화면이 창에서 빠져도) 결과가 버려지지 않는다.
    func testWriteResultSurvivesNavigatingAway() throws {
        let http = standard()
        let (s, box) = make(http)
        http.hold = true
        s.open(try XCTUnwrap(s.notifications.first { $0.id == "n1" }))
        s.view.removeFromSuperview()
        XCTAssertEqual(http.held.count, 1)
        let (_, done) = http.held[0]
        http.routes["POST /api/v1/me/notifications/n1/read"] = (500, "oops")
        done(.success(http.answer(http.held[0].0)))
        XCTAssertTrue(try XCTUnwrap(s.notifications.first { $0.id == "n1" }).isUnread, "실패는 되돌린다")
        XCTAssertEqual(box.toasts.last?.0, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
    }

    func testActivityTabSendsSeenAndClearsBadge() throws {
        let http = standard()
        let (s, box) = make(http)
        s.select(.activity)
        XCTAssertTrue(http.keys().contains("POST /api/v1/activity/seen"))
        let t = all(s)
        XCTAssertTrue(t.contains("가짜친구님이 친구 요청을 보냈어요"), t)
        XCTAssertTrue(t.contains("가짜나초가 추억을 만들었어요"), t)
        XCTAssertEqual(s.badge, 2, "활동 안 읽은 수는 0, 알림 2")
        XCTAssertEqual(box.badges.last, 2)
        for dark in [false, true] { try capture(s, dark: dark, name: "activity") }
    }

    func testEmptyActivity() throws {
        let http = standard()
        http.routes["GET /api/v1/activity"] = (200, "{\"sections\":[],\"activity_unread_count\":0}")
        let (s, _) = make(http)
        s.select(.activity)
        XCTAssertTrue(all(s).contains("아직 소식이 없어요."))
        XCTAssertFalse(http.keys().contains("POST /api/v1/activity/seen"), "안 읽은 게 없으면 seen을 보내지 않는다")
    }

    func testSettingsShowPhoneNoteAndPatchOneItem() throws {
        let http = standard()
        http.routes["PATCH /api/v1/me/notification-settings"] = (200, "{\"all_enabled\":true,\"items\":{\"task_done\":false,\"task_failed\":false},\"muted_agent_ids\":[\"x\"]}")
        let (s, box) = make(http)
        s.select(.settings)
        let t = all(s)
        XCTAssertTrue(t.contains("휴대폰 알림 설정"), t)
        XCTAssertTrue(t.contains("푸시를 받지 않는 나초: 1마리"), t)
        XCTAssertTrue(t.contains("승인과 입력 요청"), t)
        for dark in [false, true] { try capture(s, dark: dark, name: "settings") }
        s.setItem("task_failed", false)
        let i = try XCTUnwrap(http.sent.firstIndex { $0.method == "PATCH" })
        XCTAssertEqual(http.sent[i].url.path, "/api/v1/me/notification-settings")
        XCTAssertEqual(http.body(i), "{\"items\":{\"task_failed\":false}}")
        XCTAssertEqual(s.settings?.isOn("task_failed"), false)
        XCTAssertEqual(box.toasts.last?.0, "알림 설정을 바꿨어요.")
    }

    func testSettingsPatchFailureRevertsAndAutoPaymentIsLocked() throws {
        let http = standard()
        http.routes["PATCH /api/v1/me/notification-settings"] = (400, "{\"error\":{\"code\":\"invalid_input\",\"message\":\"x\"}}")
        let (s, box) = make(http)
        s.select(.settings)
        s.setItem("task_failed", false)
        XCTAssertEqual(s.settings?.isOn("task_failed"), true, "실패하면 되돌린다")
        XCTAssertEqual(box.toasts.last?.1, true)
        let patches = http.sent.filter { $0.method == "PATCH" }.count
        s.setItem("auto_payment", false)
        XCTAssertEqual(http.sent.filter { $0.method == "PATCH" }.count, patches, "끌 수 없는 항목은 요청을 보내지 않는다")
        XCTAssertEqual(box.toasts.last?.0, "이 알림은 끌 수 없어요.")
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let count = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(count) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }
}
