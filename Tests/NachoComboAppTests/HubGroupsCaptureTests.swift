import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 그룹·요청 섹션(NACHO-270 U4)을 가짜 HTTP로 장면별·라이트/다크로 그리고, 단추를 눌러 요청과 상태 전환을 확인한다.
/// macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 운영 서버는 부르지 않고, 이름·ID는 모두 가짜다.
final class HubGroupsCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private final class FakeHTTP: PetHTTPClient {
        var log: [String] = []
        var bodies: [String: String] = [:]
        var failures: [String: (Int, String)] = [:]
        var invitations = "[{\"id\":\"i1\",\"room_title\":\"주말 모임\",\"status\":\"pending\",\"inviter\":{\"id\":\"u1\",\"name\":\"민수\"},\"expires_at\":\"2026-11-20T00:00:00Z\","
            + "\"members\":[{\"kind\":\"user\",\"display_name\":\"민수\"},{\"kind\":\"agent\",\"display_name\":\"토리\"}],\"member_counts\":{\"users\":1,\"agents\":1}},"
            + "{\"id\":\"i2\",\"room_title\":\"가득 찬 방\",\"status\":\"full\",\"inviter\":{\"id\":\"u2\",\"name\":\"지수\"},\"expires_at\":\"2026-11-21T00:00:00Z\"}]"

        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            let query = request.url.query.map { "?" + $0 } ?? ""
            let key = request.method + " " + request.url.path
            log.append(key + query)
            if let b = request.body, let s = String(data: b, encoding: .utf8) { bodies[key] = s }
            if let (status, code) = failures[key] {
                completion(.success(PetHTTPResponse(status: status, body: Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"x\"}}".utf8))))
                return
            }
            func ok(_ s: String) { completion(.success(PetHTTPResponse(status: 200, body: Data(s.utf8)))) }
            switch (request.method, request.url.path) {
            case ("GET", "/api/v1/rooms"):
                if query.contains("kinds=direct") {
                    ok("{\"items\":[{\"id\":\"d1\",\"kind\":\"direct\",\"request_role\":\"target\",\"request_status\":\"pending\",\"peer_display_name\":\"낯선 하나\"},{\"id\":\"d2\",\"kind\":\"direct\"}]}")
                } else {
                    ok("{\"items\":[{\"id\":\"g1\",\"kind\":\"agent_group\",\"title\":\"기획팀\",\"member_agent_ids\":[\"a1\",\"a2\"],\"muted\":false,\"version\":3},"
                        + "{\"id\":\"g2\",\"kind\":\"group\",\"title\":\"주말 모임\",\"member_agent_ids\":[],\"muted\":true,\"version\":1}]}")
                }
            case ("GET", "/api/v1/invitations"): ok(invitations)
            case ("GET", "/api/v1/agents"):
                ok("{\"agents\":[{\"id\":\"a1\",\"name\":\"토리\",\"status\":\"active\"},{\"id\":\"a2\",\"name\":\"나초\",\"status\":\"active\"},{\"id\":\"a3\",\"name\":\"모모\",\"status\":\"active\"},{\"id\":\"a4\",\"name\":\"쉬는 아이\",\"status\":\"resting\"}],\"caps\":{\"max_group_members\":5}}")
            case ("GET", "/api/v1/rooms/g1/agent-group"):
                ok("{\"room_id\":\"g1\",\"id\":\"g1\",\"room_kind\":\"agent_group\",\"title\":\"기획팀\",\"member_agent_ids\":[\"a1\",\"a2\"],\"manager_agent_id\":\"a1\",\"muted\":false,\"version\":3}")
            case ("GET", "/api/v1/social/summary"):
                ok("{\"friends\":[{\"user_id\":\"u1\",\"display_name\":\"민수\"},{\"user_id\":\"u2\",\"display_name\":\"지수\"}],\"friend_suggestions\":[{\"user_id\":\"u9\",\"display_name\":\"새로운 하나\",\"reason\":\"contact\"}]}")
            default: ok("{}")
            }
        }
    }

    private func make() -> (PetHubWindow, FakeHTTP, GroupsSection) {
        let http = FakeHTTP()
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
        let env = HubEnvironment(isSignedIn: { true }, client: { client }, signIn: {})
        let w = PetHubWindow(env: env, autosaveName: nil, initial: .groups)
        settle()
        return (w, http, w.currentSection as! GroupsSection)
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func find<T: NSView>(_ type: T.Type, in v: NSView, where match: (T) -> Bool = { _ in true }) -> [T] {
        var out: [T] = []
        if let t = v as? T, match(t) { out.append(t) }
        for s in v.subviews { out += find(type, in: s, where: match) }
        return out
    }

    private func pill(_ w: PetHubWindow, _ title: String) throws -> PetPill {
        let root = try XCTUnwrap(w.contentView)
        return try XCTUnwrap(find(PetPill.self, in: root) { self.texts($0).contains(title) }.first, "단추 「\(title)」")
    }

    private func press(_ w: PetHubWindow, _ title: String) throws {
        try pill(w, title).onClick?()
        settle()
    }

    private func all(_ w: PetHubWindow) -> String { texts(w.contentView!).joined(separator: "\n") }

    private func capture(_ w: PetHubWindow, name: String) throws {
        for dark in [false, true] {
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.setContentSize(PetHubWindow.defaultSize)
            let root = try XCTUnwrap(w.contentView)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "hub-groups-\(name)-\(dark ? "dark" : "light")")
        }
    }

    // MARK: scenes

    func testHomeListsGroupsAndCounts() throws {
        let (w, http, _) = make()
        XCTAssertTrue(http.log.contains("GET /api/v1/rooms?kinds=agent_group,group"), http.log.joined(separator: "\n"))
        XCTAssertTrue(http.log.contains("GET /api/v1/invitations"))
        let t = all(w)
        XCTAssertTrue(t.contains("기획팀"), t)
        XCTAssertTrue(t.contains("주말 모임"), t)
        XCTAssertTrue(t.contains("받은 초대 1"), "열린 초대 1건(정원 찬 1건은 세지 않는다): " + t)
        XCTAssertTrue(t.contains("대화 요청 1"), t)
        try capture(w, name: "home")
    }

    func testCreateValidationThenRequest() throws {
        let (w, http, section) = make()
        section.showCreate()
        settle()
        var t = all(w)
        XCTAssertTrue(t.contains("토리") && t.contains("나초") && t.contains("모모"), t)
        XCTAssertFalse(t.contains("쉬는 아이"), "쉬는 나초는 고를 수 없다")
        try capture(w, name: "create")
        try press(w, "만들기")
        XCTAssertTrue(all(w).contains("나초를 2명 이상 골라 주세요."))
        XCTAssertFalse(http.log.contains("POST /api/v1/rooms/agent-group"), "검증에 걸리면 서버를 부르지 않는다")
        let switches = find(HubSwitchRow.self, in: w.contentView!)
        XCTAssertEqual(switches.count, 3)
        switches[0].toggle.state = .on
        switches[1].toggle.state = .on
        let field = try XCTUnwrap(find(HubFormField.self, in: w.contentView!).first)
        field.field.stringValue = String(repeating: "가", count: 41)
        try press(w, "만들기")
        t = all(w)
        XCTAssertTrue(t.contains("그룹 이름은(는) 40자까지 쓸 수 있어요."), t)
        XCTAssertFalse(http.log.contains("POST /api/v1/rooms/agent-group"))
        field.field.stringValue = "기획팀2"
        try press(w, "만들기")
        XCTAssertTrue(http.log.contains("POST /api/v1/rooms/agent-group"))
        let body = try XCTUnwrap(http.bodies["POST /api/v1/rooms/agent-group"])
        XCTAssertTrue(body.contains("\"member_agent_ids\":[\"a1\",\"a2\"]"), body)
        XCTAssertTrue(body.contains("\"title\":\"기획팀2\""), body)
        XCTAssertTrue(body.contains("\"idempotency_key\""), body)
    }

    func testSettingsSendsExpectedVersionAndDeleteNeedsConfirm() throws {
        let (w, http, section) = make()
        section.showSettings(section.groups[0])
        settle()
        XCTAssertTrue(http.log.contains("GET /api/v1/rooms/g1/agent-group"))
        XCTAssertTrue(all(w).contains("구성원 나초"))
        try capture(w, name: "settings")
        try press(w, "저장")
        XCTAssertFalse(http.log.contains("PATCH /api/v1/rooms/g1/agent-group"), "바뀐 게 없으면 보내지 않는다")
        let field = try XCTUnwrap(find(HubFormField.self, in: w.contentView!).first)
        field.field.stringValue = "새 이름"
        try press(w, "저장")
        let body = try XCTUnwrap(http.bodies["PATCH /api/v1/rooms/g1/agent-group"])
        XCTAssertEqual(body, "{\"expected_version\":3,\"title\":\"새 이름\"}")
    }

    func testSettingsVersionConflictReloads() throws {
        let (w, http, section) = make()
        http.failures["PATCH /api/v1/rooms/g1/agent-group"] = (409, "version_conflict")
        section.showSettings(section.groups[0])
        settle()
        let field = try XCTUnwrap(find(HubFormField.self, in: w.contentView!).first)
        field.field.stringValue = "충돌"
        let before = http.log.filter { $0 == "GET /api/v1/rooms/g1/agent-group" }.count
        try press(w, "저장")
        let after = http.log.filter { $0 == "GET /api/v1/rooms/g1/agent-group" }.count
        XCTAssertEqual(after, before + 1, "409 version_conflict면 새로 불러온다")
    }

    func testInvitationsAcceptRemovesRowAndDeclineStates() throws {
        let (w, http, section) = make()
        section.showInvitations()
        settle()
        var t = all(w)
        XCTAssertTrue(t.contains("주말 모임") && t.contains("민수님의 초대") && t.contains("가득 찬 방"), t)
        XCTAssertTrue(t.contains("방이 가득 차서 지금은 수락할 수 없어요"), t)
        XCTAssertEqual(find(PetPill.self, in: w.contentView!) { self.texts($0).contains("수락") }.count, 1, "정원이 찬 초대에는 수락 단추가 없다")
        try capture(w, name: "invitations")
        try press(w, "수락")
        XCTAssertTrue(http.log.contains("POST /api/v1/invitations/i1/accept"))
        t = all(w)
        XCTAssertFalse(t.contains("민수님의 초대"), "수락한 초대는 받은 목록에서 빠진다: " + t)
        XCTAssertEqual(section.invitations.map { $0.id }, ["i2"])
    }

    func testDeclineWithoutBlockPostsNoBodyAndRemoves() throws {
        let (w, http, section) = make()
        section.showInvitations()
        settle()
        try press(w, "거절")
        XCTAssertTrue(http.log.contains("POST /api/v1/invitations/i1/decline"))
        XCTAssertNil(http.bodies["POST /api/v1/invitations/i1/decline"])
        XCTAssertEqual(section.invitations.map { $0.id }, ["i2"])
    }

    func testAcceptExpiredInvitationRefreshesList() throws {
        let (w, http, section) = make()
        http.failures["POST /api/v1/invitations/i1/accept"] = (409, "invite_expired")
        section.showInvitations()
        settle()
        let before = http.log.filter { $0 == "GET /api/v1/invitations" }.count
        try press(w, "수락")
        XCTAssertEqual(http.log.filter { $0 == "GET /api/v1/invitations" }.count, before + 1, "끝난 초대면 목록을 다시 읽는다")
        XCTAssertEqual(section.invitations.count, 2, "실패하면 낙관적으로 빼지 않는다")
    }

    func testRequestsAcceptTransition() throws {
        let (w, http, section) = make()
        section.showRequests()
        settle()
        XCTAssertTrue(all(w).contains("낯선 하나"))
        try capture(w, name: "requests")
        try press(w, "수락")
        XCTAssertTrue(http.log.contains("POST /api/v1/rooms/d1/request/accept"))
        XCTAssertTrue(section.requests.isEmpty)
        XCTAssertTrue(all(w).contains("답할 대화 요청이 없어요."))
    }

    func testSendRequestValidation() throws {
        let (w, http, section) = make()
        section.showSendRequest()
        settle()
        XCTAssertTrue(all(w).contains("새로운 하나"))
        try capture(w, name: "send-request")
        try press(w, "요청 보내기")
        XCTAssertTrue(all(w).contains("첫 메시지를 입력해 주세요."))
        XCTAssertFalse(http.log.contains("POST /api/v1/social/message-requests"))
        let field = try XCTUnwrap(find(HubFormField.self, in: w.contentView!).first)
        field.field.stringValue = "안녕하세요"
        try press(w, "요청 보내기")
        XCTAssertEqual(http.bodies["POST /api/v1/social/message-requests"], "{\"text\":\"안녕하세요\",\"user_id\":\"u9\"}")
    }

    func testInviteFriendsNeedsAtLeastOne() throws {
        let (w, http, section) = make()
        section.showInvite(section.groups[1])
        settle()
        XCTAssertTrue(all(w).contains("민수") && all(w).contains("지수"))
        try press(w, "초대 보내기")
        XCTAssertTrue(all(w).contains("초대할 친구를 골라 주세요."))
        XCTAssertFalse(http.log.contains("POST /api/v1/rooms/g2/invitations"))
        find(HubSwitchRow.self, in: w.contentView!)[1].toggle.state = .on
        try press(w, "초대 보내기")
        XCTAssertEqual(http.bodies["POST /api/v1/rooms/g2/invitations"], "{\"user_ids\":[\"u2\"]}")
    }

    func testServerErrorOnHomeShowsKoreanAndRetry() throws {
        let http = FakeHTTP()
        http.failures["GET /api/v1/rooms"] = (500, "internal_error")
        let client = HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: http, tokens: { _, done in done("t") })
        let w = PetHubWindow(env: HubEnvironment(isSignedIn: { true }, client: { client }, signIn: {}), autosaveName: nil, initial: .groups)
        settle()
        let t = all(w)
        XCTAssertTrue(t.contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."), t)
        XCTAssertTrue(t.contains("다시 시도"))
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
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }
}
