import XCTest
@testable import NachoComboCore

/// 그룹·요청 섹션(NACHO-270 U4, B17·B18)의 Core: 요청은 바이트 단위로, 응답·오류·입력 검증은 한국어 문구까지 확인한다. 가짜 HTTP만 쓴다.
final class HubGroupsTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String, headers: [String: String] = [:]) -> PetHTTPResponse {
        PetHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    // MARK: request bytes (B17)

    func testCreateAgentGroupBytes() {
        let r = HubGroups.createGroup(e, title: " 기획팀 ", memberAgentIDs: ["a2", "a1"], managerAgentID: "a1", idempotencyKey: "K1", bearer: "T")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/rooms/agent-group")
        XCTAssertEqual(r.headers["Idempotency-Key"], "K1")
        XCTAssertEqual(r.headers["Authorization"], "Bearer T")
        XCTAssertEqual(body(r), "{\"idempotency_key\":\"K1\",\"manager_agent_id\":\"a1\",\"member_agent_ids\":[\"a2\",\"a1\"],\"title\":\"기획팀\"}")
    }

    func testCreateOmitsEmptyTitleAndManager() {
        let r = HubGroups.createGroup(e, title: "  ", memberAgentIDs: ["a1", "a2"], managerAgentID: nil, idempotencyKey: "K", bearer: "T")
        XCTAssertEqual(body(r), "{\"idempotency_key\":\"K\",\"member_agent_ids\":[\"a1\",\"a2\"]}")
    }

    func testGetUpdateDeleteGroupBytes() {
        let g = HubGroups.getGroup(e, "r1", bearer: "T")
        XCTAssertEqual(g.method, "GET")
        XCTAssertEqual(g.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r1/agent-group")
        let p = HubGroups.updateGroup(e, "r1", title: "새 이름", memberAgentIDs: nil, managerAgentID: nil, clearManager: false, muted: true, expectedVersion: 4, bearer: "T")
        XCTAssertEqual(p.method, "PATCH")
        XCTAssertEqual(p.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r1/agent-group")
        XCTAssertEqual(body(p), "{\"expected_version\":4,\"muted\":true,\"title\":\"새 이름\"}")
        let c = HubGroups.updateGroup(e, "r1", title: nil, memberAgentIDs: ["a1", "a3"], managerAgentID: nil, clearManager: true, muted: nil, expectedVersion: 5, bearer: "T")
        XCTAssertEqual(body(c), "{\"expected_version\":5,\"manager_agent_id\":null,\"member_agent_ids\":[\"a1\",\"a3\"]}")
        let d = HubGroups.deleteGroup(e, "r1", bearer: "T")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r1/agent-group")
        XCTAssertNil(d.body)
    }

    func testMemberAndInvitationBytes() {
        let m = HubGroups.addMember(e, "r1", agentID: "a9", bearer: "T")
        XCTAssertEqual(m.method, "POST")
        XCTAssertEqual(m.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r1/members")
        XCTAssertEqual(body(m), "{\"agent_id\":\"a9\"}")
        let i = HubGroups.invite(e, "r1", userIDs: ["u1", "u2"], idempotencyKey: "K2", bearer: "T")
        XCTAssertEqual(i.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r1/invitations")
        XCTAssertEqual(body(i), "{\"user_ids\":[\"u1\",\"u2\"]}")
        XCTAssertEqual(i.headers["Idempotency-Key"], "K2")
        let l = HubGroups.listInvitations(e, query: [("before", "2026-11-01T00:00:00Z")], bearer: "T")
        XCTAssertEqual(l.method, "GET")
        XCTAssertEqual(l.url.absoluteString, "https://nacho.example.com/api/v1/invitations?before=2026-11-01T00%3A00%3A00Z")
        XCTAssertEqual(HubGroups.listInvitations(e, query: [], bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/invitations")
        let a = HubGroups.acceptInvitation(e, "i1", bearer: "T")
        XCTAssertEqual(a.method, "POST")
        XCTAssertEqual(a.url.absoluteString, "https://nacho.example.com/api/v1/invitations/i1/accept")
        let d = HubGroups.declineInvitation(e, "i1", block: false, bearer: "T")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/invitations/i1/decline")
        XCTAssertNil(d.body)
        XCTAssertEqual(body(HubGroups.declineInvitation(e, "i1", block: true, bearer: "T")), "{\"block\":true}")
        let my = HubGroups.myInvitation(e, "g1", bearer: "T")
        XCTAssertEqual(my.method, "GET")
        XCTAssertEqual(my.url.absoluteString, "https://nacho.example.com/api/v1/rooms/g1/my-invitation")
    }

    // MARK: request bytes (B18)

    func testMessageRequestBytes() {
        let a = HubGroups.acceptRequest(e, "r7", bearer: "T")
        XCTAssertEqual(a.method, "POST")
        XCTAssertEqual(a.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r7/request/accept")
        XCTAssertNil(a.body)
        let d = HubGroups.declineRequest(e, "r7", bearer: "T")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/rooms/r7/request/decline")
        let s = HubGroups.sendRequest(e, userID: "u3", text: " 안녕하세요 ", idempotencyKey: "K3", bearer: "T")
        XCTAssertEqual(s.url.absoluteString, "https://nacho.example.com/api/v1/social/message-requests")
        XCTAssertEqual(body(s), "{\"text\":\"안녕하세요\",\"user_id\":\"u3\"}")
        XCTAssertEqual(s.headers["Idempotency-Key"], "K3")
    }

    func testListRequestsAndReadsBytes() {
        XCTAssertEqual(HubGroups.listGroupRooms(e, query: [], bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/rooms?kinds=agent_group,group")
        XCTAssertEqual(HubGroups.listRequestRooms(e, query: [("before", "x")], bearer: "T").url.absoluteString,
                       "https://nacho.example.com/api/v1/rooms?kinds=direct&before=x")
        XCTAssertEqual(HubGroups.friends(e, bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/social/summary")
        XCTAssertEqual(HubGroups.agents(e, bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/agents")
    }

    // MARK: responses

    func testParseGroupRoom() throws {
        let json = "{\"room_id\":\"r1\",\"id\":\"r1\",\"room_kind\":\"agent_group\",\"title\":\"기획팀\",\"member_agent_ids\":[\"a1\",\"a2\"],\"manager_agent_id\":\"a1\","
            + "\"active_run\":{\"run_id\":\"x\"},\"muted\":true,\"version\":7}"
        let g = try XCTUnwrap(HubGroups.group(try HubAPI.object(resp(200, json)).get()))
        XCTAssertEqual(g.id, "r1")
        XCTAssertEqual(g.title, "기획팀")
        XCTAssertEqual(g.memberAgentIDs, ["a1", "a2"])
        XCTAssertEqual(g.managerAgentID, "a1")
        XCTAssertTrue(g.hasActiveRun)
        XCTAssertTrue(g.muted)
        XCTAssertEqual(g.version, 7)
    }

    func testParseGroupListEmptyAndPaged() throws {
        let empty = try HubAPI.page(resp(200, "{\"items\":[]}")).get()
        XCTAssertTrue(HubGroups.groups(empty.items).isEmpty)
        let json = "{\"items\":[{\"id\":\"r1\",\"kind\":\"agent_group\",\"title\":\"A\",\"member_agent_ids\":[\"a1\",\"a2\"],\"muted\":false,\"version\":1},"
            + "{\"id\":\"r2\",\"kind\":\"group\",\"title\":\"B\",\"member_agent_ids\":[],\"muted\":false,\"version\":2}]}"
        let p = try HubAPI.page(resp(200, json, headers: ["X-Next-Before": "cur"])).get()
        let gs = HubGroups.groups(p.items)
        XCTAssertEqual(gs.map { $0.id }, ["r1", "r2"])
        XCTAssertEqual(gs.map { $0.isAgentGroup }, [true, false])
        XCTAssertEqual(p.nextQuery?.first?.0, "before")
        XCTAssertEqual(p.nextQuery?.first?.1, "cur")
    }

    func testParseInvitations() throws {
        let json = "[{\"id\":\"i1\",\"room_title\":\"주말 모임\",\"status\":\"pending\",\"inviter\":{\"id\":\"u1\",\"name\":\"민수\"},"
            + "\"expires_at\":\"2026-11-20T00:00:00Z\",\"members\":[{\"kind\":\"user\",\"display_name\":\"민수\"},{\"kind\":\"agent\",\"display_name\":\"나초\"}],"
            + "\"member_counts\":{\"users\":1,\"agents\":1}},{\"id\":\"i2\",\"room_title\":\"가득\",\"status\":\"full\",\"inviter\":{\"id\":\"u2\",\"name\":\"지수\"},\"expires_at\":\"2026-11-21T00:00:00Z\"}]"
        let invs = HubGroups.invitations(try HubAPI.page(resp(200, json)).get().items)
        XCTAssertEqual(invs.count, 2)
        XCTAssertEqual(invs[0].id, "i1")
        XCTAssertEqual(invs[0].inviterName, "민수")
        XCTAssertEqual(invs[0].memberNames, ["민수", "나초"])
        XCTAssertEqual(invs[0].userCount, 1)
        XCTAssertEqual(invs[0].agentCount, 1)
        XCTAssertTrue(invs[0].canAnswer)
        XCTAssertFalse(invs[1].canAnswer, "정원이 찬 초대는 수락할 수 없다")
        XCTAssertTrue(HubGroups.invitations(try HubAPI.page(resp(200, "[]")).get().items).isEmpty)
    }

    func testParseFriendsAgentsAndRequestRooms() throws {
        let sum = try HubAPI.object(resp(200, "{\"friends\":[{\"user_id\":\"u1\",\"display_name\":\"민수\"},{\"user_id\":\"u2\",\"display_name\":\"지수\"}],\"requests_in\":[]}")).get()
        XCTAssertEqual(HubGroups.friends(sum).map { $0.name }, ["민수", "지수"])
        XCTAssertEqual(HubGroups.friends(sum).map { $0.userID }, ["u1", "u2"])
        let ag = try HubAPI.object(resp(200, "{\"agents\":[{\"id\":\"a1\",\"name\":\"나초\",\"status\":\"active\"},{\"id\":\"a2\",\"name\":\"쉬는\",\"status\":\"resting\"}],\"caps\":{\"max_group_members\":5}}")).get()
        XCTAssertEqual(HubGroups.agents(ag).map { $0.id }, ["a1", "a2"])
        XCTAssertEqual(HubGroups.agents(ag).map { $0.isActive }, [true, false])
        XCTAssertEqual(HubGroups.maxGroupMembers(ag), 5)
        let rooms = try HubAPI.page(resp(200, "{\"items\":[{\"id\":\"r1\",\"kind\":\"direct\",\"request_role\":\"target\",\"request_status\":\"pending\",\"peer_display_name\":\"낯선이\"},"
            + "{\"id\":\"r2\",\"kind\":\"direct\",\"request_role\":\"requester\",\"request_status\":\"pending\"},{\"id\":\"r3\",\"kind\":\"direct\"},"
            + "{\"id\":\"r4\",\"kind\":\"direct\",\"request_role\":\"target\",\"request_status\":\"accepted\"}]}")).get()
        let reqs = HubGroups.incomingRequests(rooms.items)
        XCTAssertEqual(reqs.map { $0.roomID }, ["r1"], "받은 요청 중 아직 답하지 않은 것만")
        XCTAssertEqual(reqs.first?.peerName, "낯선이")
    }

    func testMyInvitationStates() throws {
        let p = HubGroups.myInvitationState(try HubAPI.object(resp(200, "{\"state\":\"pending\",\"invitation\":{\"room_id\":\"g1\",\"room_title\":\"T\",\"inviter\":{\"display_name\":\"민수\"}}}")).get())
        XCTAssertEqual(p, .pending(title: "T", inviterName: "민수"))
        XCTAssertEqual(HubGroups.myInvitationState(try HubAPI.object(resp(200, "{\"state\":\"member\"}")).get()), .member)
        XCTAssertEqual(HubGroups.myInvitationState(try HubAPI.object(resp(200, "{\"state\":\"handled\"}")).get()), .handled)
        XCTAssertEqual(HubGroups.myInvitationState(try HubAPI.object(resp(200, "{\"state\":\"ended\",\"reason\":\"expired\",\"inviter_name\":\"민수\"}")).get()), .ended(reason: "expired"))
    }

    // MARK: errors → Korean (401·404·409·서버 오류)

    private func err(_ status: Int, _ code: String, reason: String? = nil) -> PetAPIError {
        let r = reason.map { ",\"reason\":\"\($0)\"" } ?? ""
        switch HubAPI.object(resp(status, "{\"error\":{\"code\":\"\(code)\",\"message\":\"x\"\(r)}}")) {
        case let .failure(e): return e
        case .success: return .badResponse
        }
    }

    func testErrorTextKorean() {
        XCTAssertEqual(HubGroups.errorText(err(401, "unauthorized")), "로그인이 필요해요.")
        XCTAssertEqual(HubGroups.errorText(err(404, "not_found")), "찾을 수 없어요. 이미 지워졌거나 만료됐을 수 있어요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "version_conflict")), "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "member_limit")), "더 넣을 수 없어요. 구성원 수 한도에 닿았어요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "group_limit")), "만들 수 있는 그룹 수를 넘었어요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "room_full")), "방이 가득 차서 들어갈 수 없어요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "run_active")), "진행 중인 단톡 일을 먼저 끝내 주세요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "already_member")), "이미 이 방의 구성원이에요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "already_invited")), "이미 초대했어요. 상대가 답할 때까지 기다려 주세요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "invite_expired")), "초대 기한이 지났어요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "invite_cancelled")), "초대가 취소됐어요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "invite_handled")), "이미 답한 초대예요.")
        XCTAssertEqual(HubGroups.errorText(err(409, "already_sent")), "이미 요청을 보냈어요. 답을 기다려 주세요.")
        XCTAssertEqual(HubGroups.errorText(err(429, "daily_limit")), "오늘 보낼 수 있는 요청을 다 썼어요.")
        XCTAssertEqual(HubGroups.errorText(err(500, "internal_error")), "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
    }

    func testStatesAreNotNetworkSuccess() {
        if case .success = HubAPI.object(resp(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"x\"}}")) { XCTFail("409는 실패") }
        if case .success = HubAPI.empty(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")) { XCTFail("404는 실패") }
        if case .failure = HubAPI.empty(resp(204, "")) { XCTFail("204는 성공") }
    }

    // MARK: 입력 검증 (그룹 이름·구성원·요청 글)

    func testTitleValidation() {
        XCTAssertNil(HubGroups.validateTitle("", required: false), "만들 때 비우면 서버가 구성원 이름을 잇는다")
        XCTAssertEqual(HubGroups.validateTitle("  ", required: true), "그룹 이름을(를) 입력해 주세요.")
        XCTAssertNil(HubGroups.validateTitle(String(repeating: "가", count: 40), required: true))
        XCTAssertEqual(HubGroups.validateTitle(String(repeating: "가", count: 41), required: false), "그룹 이름은(는) 40자까지 쓸 수 있어요.")
    }

    func testMemberCountValidation() {
        XCTAssertEqual(HubGroups.validateMemberCount(1, max: 5), "나초를 2명 이상 골라 주세요.")
        XCTAssertNil(HubGroups.validateMemberCount(2, max: 5))
        XCTAssertNil(HubGroups.validateMemberCount(5, max: 5))
        XCTAssertEqual(HubGroups.validateMemberCount(6, max: 5), "나초는 5명까지 넣을 수 있어요.")
        XCTAssertNil(HubGroups.validateMemberCount(6, max: nil), "한도를 모르면 서버가 판단한다")
    }

    func testRequestTextAndInviteValidation() {
        XCTAssertEqual(HubGroups.validateRequestText(""), "첫 메시지를 입력해 주세요.")
        XCTAssertNil(HubGroups.validateRequestText(String(repeating: "a", count: 1000)))
        XCTAssertEqual(HubGroups.validateRequestText(String(repeating: "a", count: 1001)), "첫 메시지는 1000자까지 쓸 수 있어요.")
        XCTAssertEqual(HubGroups.validateInviteCount(0), "초대할 친구를 골라 주세요.")
        XCTAssertNil(HubGroups.validateInviteCount(20))
        XCTAssertEqual(HubGroups.validateInviteCount(21), "한 번에 20명까지 초대할 수 있어요.")
    }

    // MARK: 초대 상태 전환

    func testInvitationStateTransitions() {
        func inv(_ s: String) -> HubInvitation { HubInvitation(id: "i", roomTitle: "t", status: s, inviterName: "n", expiresAt: nil, memberNames: [], userCount: 0, agentCount: 0) }
        XCTAssertTrue(inv("pending").canAnswer)
        for s in ["full", "accepted", "declined", "cancelled", "expired", "room_deleted"] { XCTAssertFalse(inv(s).canAnswer, s) }
        XCTAssertEqual(inv("pending").statusText, "답을 기다려요")
        XCTAssertEqual(inv("full").statusText, "방이 가득 차서 지금은 수락할 수 없어요")
        XCTAssertEqual(inv("expired").statusText, "기한이 지났어요")
        XCTAssertEqual(inv("room_deleted").statusText, "방이 없어졌어요")
        XCTAssertEqual(inv("accepted").statusText, "들어왔어요")
        XCTAssertEqual(inv("declined").statusText, "거절했어요")
        XCTAssertEqual(inv("cancelled").statusText, "취소됐어요")
        // 수락·거절 뒤에는 받은 목록에서 빠진다(서버 목록은 pending·full만 준다): 낙관적 갱신
        let list = [inv("pending"), HubInvitation(id: "j", roomTitle: "u", status: "pending", inviterName: "m", expiresAt: nil, memberNames: [], userCount: 0, agentCount: 0)]
        XCTAssertEqual(HubGroups.removing(invitationID: "i", from: list).map { $0.id }, ["j"])
    }
}
