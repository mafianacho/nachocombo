import Foundation

// 그룹·요청 섹션의 Core (NACHO-270 U4, 표 B17·B18). 요청은 순수 함수라 시험이 바이트를 그대로 확인한다.
// 경로·필드는 nacho-server spec(`groups.tsp`·`group-invites.tsp`·`message-requests.tsp`)과 같다. 새 네트워크 층은 없고 `HubAPI`만 쓴다.
// 외부 발송(문자·공유)은 없다: 초대는 서버의 앱 내 초대(`POST /rooms/{id}/invitations`)만 쓴다.

/// 나초끼리 단톡방(`agent_group`) 또는 사람+나초 단톡방(`group`) 한 곳.
public struct HubGroupRoom: Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var memberAgentIDs: [String]
    public var managerAgentID: String?
    public var hasActiveRun: Bool
    public var muted: Bool
    public var version: Int?

    public var isAgentGroup: Bool { kind == "agent_group" }
}

/// 받은 초대 한 건.
public struct HubInvitation: Equatable {
    public var id: String
    public var roomTitle: String
    public var status: String
    public var inviterName: String
    public var expiresAt: String?
    public var memberNames: [String]
    public var userCount: Int
    public var agentCount: Int

    public init(id: String, roomTitle: String, status: String, inviterName: String, expiresAt: String?, memberNames: [String], userCount: Int, agentCount: Int) {
        self.id = id
        self.roomTitle = roomTitle
        self.status = status
        self.inviterName = inviterName
        self.expiresAt = expiresAt
        self.memberNames = memberNames
        self.userCount = userCount
        self.agentCount = agentCount
    }

    /// 수락·거절 단추를 보일 수 있는가(열린 초대만. 정원이 찬 `full`은 수락할 수 없다).
    public var canAnswer: Bool { status == "pending" }

    public var statusText: String {
        switch status {
        case "pending": return "답을 기다려요"
        case "full": return "방이 가득 차서 지금은 수락할 수 없어요"
        case "accepted": return "들어왔어요"
        case "declined": return "거절했어요"
        case "cancelled": return "취소됐어요"
        case "expired": return "기한이 지났어요"
        case "room_deleted": return "방이 없어졌어요"
        default: return status
        }
    }
}

public struct HubFriend: Equatable {
    public var userID: String
    public var name: String
}

/// 그룹에 넣을 내 나초.
public struct HubAgentChoice: Equatable {
    public var id: String
    public var name: String
    public var isActive: Bool
}

/// 모르는 사람이 보낸 대화 요청(받은 쪽, 아직 답 안 함).
public struct HubIncomingRequest: Equatable {
    public var roomID: String
    public var peerName: String
}

/// `GET /rooms/{room}/my-invitation`(호환 경로)의 상태.
public enum HubMyInvitation: Equatable {
    case pending(title: String, inviterName: String)
    case member
    case handled
    case ended(reason: String?)
    case unknown
}

public enum HubGroups {
    public static let titleMax = 40
    public static let requestTextMax = 1000
    public static let inviteMax = 20

    private static func rooms(_ rest: String) -> String { "/api/v1/rooms/" + rest }

    // MARK: requests — B17

    /// 나초끼리 그룹 만들기(멱등). 이름을 비우면 서버가 구성원 이름을 잇는다.
    public static func createGroup(_ e: ServerEndpoint, title: String, memberAgentIDs: [String], managerAgentID: String?, idempotencyKey: String, bearer: String?) -> PetHTTPRequest {
        var json: [String: Any] = ["member_agent_ids": memberAgentIDs, "idempotency_key": idempotencyKey]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { json["title"] = t }
        if let m = managerAgentID, !m.isEmpty { json["manager_agent_id"] = m }
        return HubAPI.post(e, "/api/v1/rooms/agent-group", bearer: bearer, json: json, idempotencyKey: idempotencyKey)
    }

    public static func getGroup(_ e: ServerEndpoint, _ id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, rooms("\(id)/agent-group"), bearer: bearer)
    }

    /// 이름·구성원·진행 맡기·알림 바꾸기. `expected_version`은 본문. `clearManager`면 `manager_agent_id: null`(해제).
    public static func updateGroup(_ e: ServerEndpoint, _ id: String, title: String?, memberAgentIDs: [String]?, managerAgentID: String?, clearManager: Bool,
                                   muted: Bool?, expectedVersion: Int?, bearer: String?) -> PetHTTPRequest {
        var json: [String: Any] = [:]
        if let t = title { json["title"] = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let m = memberAgentIDs { json["member_agent_ids"] = m }
        if clearManager { json["manager_agent_id"] = NSNull() } else if let m = managerAgentID { json["manager_agent_id"] = m }
        if let m = muted { json["muted"] = m }
        return HubAPI.patch(e, rooms("\(id)/agent-group"), bearer: bearer, json: json, expectedVersion: expectedVersion)
    }

    public static func deleteGroup(_ e: ServerEndpoint, _ id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, rooms("\(id)/agent-group"), bearer: bearer)
    }

    /// 내 나초 하나 더하기(사람 단톡방). 사람은 여기로 더하지 않고 초대한다.
    public static func addMember(_ e: ServerEndpoint, _ id: String, agentID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, rooms("\(id)/members"), bearer: bearer, json: ["agent_id": agentID])
    }

    /// 내 친구들을 방에 초대(앱 내 초대. 문자·링크 공유 없음).
    public static func invite(_ e: ServerEndpoint, _ id: String, userIDs: [String], idempotencyKey: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, rooms("\(id)/invitations"), bearer: bearer, json: ["user_ids": userIDs], idempotencyKey: idempotencyKey)
    }

    public static func listInvitations(_ e: ServerEndpoint, query: [(String, String)], bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/invitations", query: query, bearer: bearer)
    }

    public static func acceptInvitation(_ e: ServerEndpoint, _ id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/invitations/\(id)/accept", bearer: bearer)
    }

    /// 거절(멱등). `block`이면 초대한 사람도 차단한다.
    public static func declineInvitation(_ e: ServerEndpoint, _ id: String, block: Bool, bearer: String?) -> PetHTTPRequest {
        if block { return HubAPI.post(e, "/api/v1/invitations/\(id)/decline", bearer: bearer, json: ["block": true]) }
        var r = HubAPI.get(e, "/api/v1/invitations/\(id)/decline", bearer: bearer)
        r.method = "POST"
        return r
    }

    public static func myInvitation(_ e: ServerEndpoint, _ room: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, rooms("\(room)/my-invitation"), bearer: bearer)
    }

    // MARK: requests — B18

    public static func acceptRequest(_ e: ServerEndpoint, _ roomID: String, bearer: String?) -> PetHTTPRequest {
        postNoBody(e, rooms("\(roomID)/request/accept"), bearer)
    }

    public static func declineRequest(_ e: ServerEndpoint, _ roomID: String, bearer: String?) -> PetHTTPRequest {
        postNoBody(e, rooms("\(roomID)/request/decline"), bearer)
    }

    /// 낯선 사람에게 대화 요청(첫 메시지 1–1000자).
    public static func sendRequest(_ e: ServerEndpoint, userID: String, text: String, idempotencyKey: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/social/message-requests", bearer: bearer,
                    json: ["user_id": userID, "text": text.trimmingCharacters(in: .whitespacesAndNewlines)], idempotencyKey: idempotencyKey)
    }

    private static func postNoBody(_ e: ServerEndpoint, _ path: String, _ bearer: String?) -> PetHTTPRequest {
        var r = HubAPI.get(e, path, bearer: bearer)
        r.method = "POST"
        return r
    }

    // MARK: reads

    /// 그룹방 목록(`kinds=agent_group,group`). 쉼표는 서버가 그대로 읽는다.
    public static func listGroupRooms(_ e: ServerEndpoint, query: [(String, String)], bearer: String?) -> PetHTTPRequest {
        listRooms(e, kinds: "agent_group,group", query: query, bearer: bearer)
    }

    /// 받은 대화 요청을 찾으려고 1:1(`direct`) 방을 읽는다.
    public static func listRequestRooms(_ e: ServerEndpoint, query: [(String, String)], bearer: String?) -> PetHTTPRequest {
        listRooms(e, kinds: "direct", query: query, bearer: bearer)
    }

    private static func listRooms(_ e: ServerEndpoint, kinds: String, query: [(String, String)], bearer: String?) -> PetHTTPRequest {
        var r = HubAPI.get(e, "/api/v1/rooms", bearer: bearer)
        var s = "kinds=" + kinds
        if !query.isEmpty { s += "&" + query.map { "\(PetHTTPRequest.formEscape($0.0))=\(PetHTTPRequest.formEscape($0.1))" }.joined(separator: "&") }
        r.url = URL(string: r.url.absoluteString + "?" + s) ?? r.url
        return r
    }

    /// 친구 고르기는 읽기만(친구 관리는 다른 섹션).
    public static func friends(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/social/summary", bearer: bearer)
    }

    public static func agents(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/agents", bearer: bearer)
    }

    // MARK: parse

    public static func group(_ o: HubObject) -> HubGroupRoom? {
        guard let id = o.str("room_id") ?? o.str("id") else { return nil }
        return HubGroupRoom(id: id, kind: o.str("room_kind") ?? o.str("kind") ?? "agent_group", title: o.str("title") ?? "",
                            memberAgentIDs: o.strs("member_agent_ids"), managerAgentID: o.str("manager_agent_id"),
                            hasActiveRun: o.obj("active_run") != nil, muted: o.bool("muted") ?? false, version: o.int("version"))
    }

    public static func groups(_ items: [HubObject]) -> [HubGroupRoom] { items.compactMap(group) }

    public static func invitations(_ items: [HubObject]) -> [HubInvitation] {
        items.compactMap { o in
            guard let id = o.str("id") else { return nil }
            let counts = o.obj("member_counts")
            return HubInvitation(id: id, roomTitle: o.str("room_title") ?? "", status: o.str("status") ?? "pending",
                                 inviterName: o.obj("inviter")?.str("name") ?? "", expiresAt: o.str("expires_at"),
                                 memberNames: o.objs("members").compactMap { $0.str("display_name") },
                                 userCount: counts?.int("users") ?? 0, agentCount: counts?.int("agents") ?? 0)
        }
    }

    public static func friends(_ summary: HubObject) -> [HubFriend] {
        summary.objs("friends").compactMap { o in
            guard let id = o.str("user_id") else { return nil }
            return HubFriend(userID: id, name: o.str("display_name") ?? "친구")
        }
    }

    /// 요청을 보낼 만한 사람(`friend_suggestions`: 연락처·초대로 알게 된 사람). 이미 친구인 사람은 요청 없이 바로 대화한다.
    public static func suggestions(_ summary: HubObject) -> [HubFriend] {
        summary.objs("friend_suggestions").compactMap { o in
            guard let id = o.str("user_id") else { return nil }
            return HubFriend(userID: id, name: o.str("display_name") ?? "알 수 없는 사람")
        }
    }

    public static func agents(_ list: HubObject) -> [HubAgentChoice] {
        list.objs("agents").compactMap { o in
            guard let id = o.str("id") ?? o.str("agent_id") else { return nil }
            return HubAgentChoice(id: id, name: o.str("name") ?? "나초", isActive: (o.str("status") ?? "active") == "active")
        }
    }

    public static func maxGroupMembers(_ list: HubObject) -> Int? {
        (list.obj("caps") ?? list.obj("limits"))?.int("max_group_members")
    }

    /// 받은 대화 요청(내가 받는 쪽 + 아직 답 안 함)만.
    public static func incomingRequests(_ rooms: [HubObject]) -> [HubIncomingRequest] {
        rooms.compactMap { o in
            guard o.str("request_role") == "target", o.str("request_status") == "pending", let id = o.str("id") else { return nil }
            return HubIncomingRequest(roomID: id, peerName: o.str("peer_display_name") ?? "알 수 없는 사람")
        }
    }

    public static func myInvitationState(_ o: HubObject) -> HubMyInvitation {
        switch o.str("state") {
        case "pending":
            let inv = o.obj("invitation")
            return .pending(title: inv?.str("room_title") ?? "", inviterName: inv?.obj("inviter")?.str("display_name") ?? "")
        case "member": return .member
        case "handled": return .handled
        case "ended": return .ended(reason: o.str("reason"))
        default: return .unknown
        }
    }

    /// 수락·거절한 초대를 받은 목록에서 뺀다(서버 목록은 열린 초대만 준다).
    public static func removing(invitationID: String, from list: [HubInvitation]) -> [HubInvitation] {
        list.filter { $0.id != invitationID }
    }

    // MARK: 입력 검증 (한국어)

    /// 그룹 이름: 1–40자. 만들 때는 비워도 된다(`required: false`).
    public static func validateTitle(_ s: String, required: Bool) -> String? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return required ? "그룹 이름을(를) 입력해 주세요." : nil }
        if v.count > titleMax { return "그룹 이름은(는) \(titleMax)자까지 쓸 수 있어요." }
        return nil
    }

    /// 구성원 2명 이상, 한도(`caps.max_group_members`)를 알면 그 이하.
    public static func validateMemberCount(_ n: Int, max: Int?) -> String? {
        if n < 2 { return "나초를 2명 이상 골라 주세요." }
        if let m = max, n > m { return "나초는 \(m)명까지 넣을 수 있어요." }
        return nil
    }

    public static func validateRequestText(_ s: String) -> String? {
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "첫 메시지를 입력해 주세요." }
        if v.count > requestTextMax { return "첫 메시지는 \(requestTextMax)자까지 쓸 수 있어요." }
        return nil
    }

    public static func validateInviteCount(_ n: Int) -> String? {
        if n < 1 { return "초대할 친구를 골라 주세요." }
        if n > inviteMax { return "한 번에 \(inviteMax)명까지 초대할 수 있어요." }
        return nil
    }

    // MARK: 오류 문구

    /// 서버 오류 → 한국어. 이 섹션에 나오는 코드를 먼저 풀고, 나머지는 공용 문구(`PetAPIError.text`)를 쓴다.
    public static func errorText(_ e: PetAPIError) -> String {
        switch e.code ?? "" {
        case "member_limit": return "더 넣을 수 없어요. 구성원 수 한도에 닿았어요."
        case "group_limit": return "만들 수 있는 그룹 수를 넘었어요."
        case "room_full": return "방이 가득 차서 들어갈 수 없어요."
        case "already_member": return "이미 이 방의 구성원이에요."
        case "already_invited": return "이미 초대했어요. 상대가 답할 때까지 기다려 주세요."
        case "invite_expired": return "초대 기한이 지났어요."
        case "invite_cancelled": return "초대가 취소됐어요."
        case "invite_handled": return "이미 답한 초대예요."
        case "room_deleted": return "방이 없어졌어요."
        case "already_sent": return "이미 요청을 보냈어요. 답을 기다려 주세요."
        case "daily_limit": return "오늘 보낼 수 있는 요청을 다 썼어요."
        case "not_found": return "찾을 수 없어요. 이미 지워졌거나 만료됐을 수 있어요."
        default: return e.status == 404 ? "찾을 수 없어요. 이미 지워졌거나 만료됐을 수 있어요." : e.text
        }
    }
}
