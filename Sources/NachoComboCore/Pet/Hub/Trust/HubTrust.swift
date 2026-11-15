import Foundation

// 연결 보안 섹션(NACHO-264 U9: E5·E7·E8)의 Core. 요청은 순수 함수(시험이 바이트를 확인), 응답은 화면용 값으로 푼다.
// 경로·필드는 nacho-server spec(connections.tsp·sharing.tsp·secure.tsp·approval-rules.tsp)을 따른다.
// 연결 켜기/끄기·연동은 이 파일에 없다(연결 탭 몫). 비밀 값은 서버가 줘도 화면 값으로 옮기지 않는다.

public enum HubAudience: String, CaseIterable, Equatable {
    case nobody, friends, everyone

    public var label: String {
        switch self {
        case .nobody: return "아무에게도 안 보여요"
        case .friends: return "친구의 나초에게만"
        case .everyone: return "모두에게 (기존 값)"
        }
    }

    /// 새로 고를 수 있는 값(`everyone`은 이미 그 값일 때만 서버가 받는다).
    public static let selectable: [HubAudience] = [.nobody, .friends]
}

public struct HubConnection: Equatable {
    public var id: String
    public var source: String
    public var label: String
    public var accountLabel: String?
    public var status: String
    public var enabled: Bool
    public var scopeSummary: String?

    public var statusText: String {
        switch status {
        case "connected": return enabled ? "연결됨" : "꺼져 있음"
        case "needs_reauth": return "다시 로그인 필요"
        case "degraded": return "일시 장애"
        default: return status
        }
    }
}

public struct HubAgentRef: Equatable {
    public var id: String
    public var name: String
}

public struct HubAllowance: Equatable {
    public var agentID: String
    public var allowed: Bool
    /// nil이면 계정 범위 그대로.
    public var writeKinds: [String]?

    public init(agentID: String, allowed: Bool, writeKinds: [String]?) {
        self.agentID = agentID
        self.allowed = allowed
        self.writeKinds = writeKinds
    }
}

public struct HubSharingRow: Equatable {
    public var source: String
    public var label: String
    public var category: String
    public var audience: HubAudience
    public var sharePlansFreeOnly: Bool

    public init(source: String, label: String, category: String, audience: HubAudience, sharePlansFreeOnly: Bool) {
        self.source = source
        self.label = label
        self.category = category
        self.audience = audience
        self.sharePlansFreeOnly = sharePlansFreeOnly
    }
}

/// 접근 기록 한 묶음(서버 `AccessGroup`). 화면에 쓰는 칸만 옮긴다 — `context`·`target_label`·`requests[]`는 옮기지 않는다.
public struct HubAccessRow: Equatable {
    public var id: String
    public var date: String
    public var timeText: String
    public var title: String
    public var subtitle: String?
    public var outcome: String
    public var count: Int
    public var flagged: Bool
}

public struct HubAccessSummary: Equatable {
    public var reads: Int
    public var sends: Int
    public var changes: Int
    public var browserWork: Int
}

public struct HubAccessLog: Equatable {
    public var summary: HubAccessSummary?
    public var rows: [HubAccessRow]
    public var hasMore: Bool
    /// 다음 쪽 쿼리(`before_ms`, `before_id`). 없으면 끝.
    public var nextQuery: [(String, String)]?

    public static func == (a: HubAccessLog, b: HubAccessLog) -> Bool {
        a.summary == b.summary && a.rows == b.rows && a.hasMore == b.hasMore
            && (a.nextQuery ?? []).map { "\($0.0)=\($0.1)" } == (b.nextQuery ?? []).map { "\($0.0)=\($0.1)" }
    }
}

public struct HubApprovalRule: Equatable {
    public var id: String
    public var summary: String
    public var expired: Bool
    public var expiresAt: String?
    public var used: Int
    public var appliesToAgentIDs: [String]
}

public struct HubApprovalRules: Equatable {
    public var rules: [HubApprovalRule]
    /// nil이면 한도 없음.
    public var limitValue: Int?
    public var limitCurrency: String
    public var limitUsed: Int
}

public extension PetAPIError {
    /// 로그인이 안 된 채 요청하려 할 때(앱 쪽에서 쓴다).
    static let hubNotSignedIn = PetAPIError(status: 401, code: "unauthorized", text: "로그인이 필요해요.")
}

public enum HubTrustAPI {
    // MARK: requests

    public static func connections(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/connections", bearer: bearer)
    }

    /// 나초 이름을 붙이려고 읽기만 한다.
    public static func agents(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/agents", bearer: bearer)
    }

    public static func allowances(_ e: ServerEndpoint, connectionID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/connections/\(connectionID)/agents", bearer: bearer)
    }

    /// 본문은 배열이다(`AllowanceInput[]`). 글자 순서 고정을 위해 키를 정렬한다.
    public static func putAllowances(_ e: ServerEndpoint, connectionID: String, items: [HubAllowance], bearer: String?, idempotencyKey: String? = nil) -> PetHTTPRequest {
        let arr: [[String: Any]] = items.map { a in
            var o: [String: Any] = ["agent_id": a.agentID, "allowed": a.allowed]
            if let w = a.writeKinds { o["write_kinds"] = w }
            return o
        }
        let data = (try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys])) ?? Data("[]".utf8)
        var r = HubAPI.get(e, "/api/v1/connections/\(connectionID)/agents", bearer: bearer)
        r.method = "PUT"
        r.headers["Content-Type"] = "application/json"
        r.body = data
        if let k = idempotencyKey, !k.isEmpty { r.headers["Idempotency-Key"] = k }
        return r
    }

    public static func sharing(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/connections/sharing", bearer: bearer)
    }

    /// 경로의 id는 source다. 캘린더의 friends는 `share_plans_free_only=true`를 함께 보낸다(서버가 같이 저장).
    public static func putSharing(_ e: ServerEndpoint, source: String, category: String, audience: HubAudience, bearer: String?) -> PetHTTPRequest {
        var json: [String: Any] = ["audience": audience.rawValue]
        if category == "calendar", audience == .friends { json["share_plans_free_only"] = true }
        return HubAPI.put(e, "/api/v1/connections/\(source)/sharing", bearer: bearer, json: json)
    }

    /// `X-Device-Auth`는 보내지 않는다(그러면 서버가 대상 이름을 뺀다).
    public static func accessLog(_ e: ServerEndpoint, bearer: String?, limit: Int = 50, next: [(String, String)]? = nil) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/secure/log", query: [("limit", String(limit))] + (next ?? []), bearer: bearer)
    }

    public static func approvalRules(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/me/approval-rules", bearer: bearer)
    }

    /// `value: nil`은 JSON null(한도 없음).
    public static func patchAccountLimit(_ e: ServerEndpoint, value: Int?, currency: String = "KRW", bearer: String?) -> PetHTTPRequest {
        let v: Any = value.map { $0 as Any } ?? NSNull()
        return HubAPI.patch(e, "/api/v1/me/approval-rules", bearer: bearer, json: ["account_limit": ["currency": currency, "value": v]])
    }

    public static func deleteRule(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/me/approval-rules/\(id)", bearer: bearer)
    }

    // MARK: input validation

    /// 계정 합계 한도 입력: 빈 칸 = 한도 없음(nil), 아니면 1 이상 정수(서버: 0 이하는 400).
    public static func parseLimit(_ text: String) -> Result<Int?, HubInputError> {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        if t.isEmpty { return .success(nil) }
        guard t.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(t) else { return .failure(HubInputError("숫자만 넣어 주세요.")) }
        if n <= 0 { return .failure(HubInputError("1원 이상으로 넣어 주세요. 한도를 없애려면 칸을 비워 주세요.")) }
        if n > 1_000_000_000 { return .failure(HubInputError("너무 큰 금액이에요.")) }
        return .success(n)
    }

    // MARK: responses

    public static func decodeConnections(_ resp: PetHTTPResponse) -> Result<[HubConnection], PetAPIError> {
        HubAPI.page(resp).map { p in
            p.items.compactMap { o in
                guard let id = o.str("id"), let source = o.str("source") else { return nil }
                return HubConnection(id: id, source: source, label: o.str("label") ?? source, accountLabel: o.str("account_label"),
                                     status: o.str("status") ?? "", enabled: o.bool("enabled") ?? true, scopeSummary: o.str("scope_summary"))
            }
        }
    }

    public static func decodeAgents(_ resp: PetHTTPResponse) -> Result<[HubAgentRef], PetAPIError> {
        HubAPI.page(resp, key: "agents").map { p in
            p.items.compactMap { o in o.str("id").map { HubAgentRef(id: $0, name: o.str("name") ?? "나초") } }
        }
    }

    public static func decodeAllowances(_ resp: PetHTTPResponse) -> Result<[HubAllowance], PetAPIError> {
        HubAPI.page(resp).map { p in
            p.items.compactMap { o in
                guard let id = o.str("agent_id") else { return nil }
                let w = o.raw["write_kinds"] == nil ? nil : o.strs("write_kinds")
                return HubAllowance(agentID: id, allowed: o.bool("allowed") ?? false, writeKinds: w)
            }
        }
    }

    public static func decodeSharing(_ resp: PetHTTPResponse) -> Result<[HubSharingRow], PetAPIError> {
        HubAPI.page(resp).map { p in p.items.compactMap(sharingRow) }
    }

    public static func decodeSharingRow(_ resp: PetHTTPResponse) -> Result<HubSharingRow, PetAPIError> {
        HubAPI.object(resp).flatMap { o in sharingRow(o).map { .success($0) } ?? .failure(.badResponse) }
    }

    private static func sharingRow(_ o: HubObject) -> HubSharingRow? {
        guard let source = o.str("source") else { return nil }
        return HubSharingRow(source: source, label: o.str("label") ?? source, category: o.str("category") ?? "",
                             audience: HubAudience(rawValue: o.str("audience") ?? "") ?? .nobody,
                             sharePlansFreeOnly: o.bool("share_plans_free_only") ?? false)
    }

    public static func actionLabel(_ a: String) -> String {
        switch a {
        case "read": return "읽었어요"
        case "send": return "보냈어요"
        case "change": return "바꿨어요"
        case "delete": return "지웠어요"
        case "payment_request": return "결제를 요청했어요"
        case "connect": return "연결했어요"
        case "disconnect": return "연결을 끊었어요"
        case "scope_change": return "허용 범위를 바꿨어요"
        case "login_ok": return "로그인했어요"
        case "session_expired": return "로그인이 만료됐어요"
        case "logout": return "로그아웃했어요"
        case "delegation_on": return "열쇠 빌려주기를 켰어요"
        case "delegation_off": return "열쇠 빌려주기를 껐어요"
        case "delegation_extend": return "열쇠 빌려주기를 늘렸어요"
        case "card_saved": return "카드를 저장했어요"
        case "card_deleted": return "카드를 지웠어요"
        case "login_saved": return "로그인 정보를 저장했어요"
        case "key_rotated": return "열쇠를 바꿨어요"
        case "secret_entered": return "비밀 칸을 썼어요"
        case "otp_entered": return "인증 코드를 넣었어요"
        case "browser_work": return "브라우저로 일했어요"
        case "blocked": return "막았어요"
        default: return "기록"
        }
    }

    /// 어떤 비밀 칸이 쓰였는지만(값은 없다).
    public static func secretFieldLabel(_ f: String) -> String {
        switch f {
        case "password": return "비밀번호 칸"
        case "card_number": return "카드번호 칸"
        case "security_code": return "보안 코드 칸"
        case "otp": return "인증 코드 칸"
        default: return "비밀 칸"
        }
    }

    public static func outcomeLabel(_ o: String) -> String {
        switch o {
        case "ok": return "완료"
        case "failed": return "실패"
        case "blocked": return "막힘"
        case "pending": return "기다리는 중"
        default: return o
        }
    }

    /// 접근 기록. 비밀 값 비표시: 쓰는 칸은 서버의 `group.id/action/service/agent/count/outcome/field/detail/time_text`뿐이다.
    /// 비밀 칸(`field`)이 있는 묶음은 `detail`도 버린다(서버가 지워 줘도 한 번 더 막는다).
    public static func decodeAccessLog(_ resp: PetHTTPResponse) -> Result<HubAccessLog, PetAPIError> {
        HubAPI.object(resp).map { o in
            var rows: [HubAccessRow] = []
            for day in o.objs("days") {
                let date = day.str("date") ?? ""
                for g in day.objs("groups") {
                    guard let id = g.str("id") else { continue }
                    let service = g.str("service_name") ?? g.str("provider_name") ?? g.str("source") ?? ""
                    let agent = g.str("agent_name_snapshot")
                    let action = actionLabel(g.str("action") ?? "")
                    var title = service.isEmpty ? action : "\(service) · \(action)"
                    let field = g.str("field")
                    if let f = field { title += " (\(secretFieldLabel(f)))" }
                    var parts: [String] = []
                    if let a = agent, !a.isEmpty { parts.append(a) }
                    if field == nil, let d = g.str("detail"), !d.isEmpty { parts.append(d) }
                    rows.append(HubAccessRow(id: id, date: date, timeText: g.str("time_text") ?? "", title: title,
                                             subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                             outcome: outcomeLabel(g.str("outcome") ?? ""), count: g.int("count") ?? 1,
                                             flagged: g.bool("flagged") ?? false))
                }
            }
            var summary: HubAccessSummary?
            if let s = o.obj("summary") {
                summary = HubAccessSummary(reads: s.int("reads") ?? 0, sends: s.int("sends") ?? 0, changes: s.int("changes") ?? 0, browserWork: s.int("browser_work") ?? 0)
            }
            var next: [(String, String)]?
            if o.bool("has_more") ?? false, let n = o.obj("next"), let ms = n.int("before_ms"), let id = n.str("before_id") {
                next = [("before_ms", String(ms)), ("before_id", id)]
            }
            return HubAccessLog(summary: summary, rows: rows, hasMore: (o.bool("has_more") ?? false) && next != nil, nextQuery: next)
        }
    }

    public static func decodeApprovalRules(_ resp: PetHTTPResponse) -> Result<HubApprovalRules, PetAPIError> {
        HubAPI.object(resp).map { o in decodeRulesObject(o) }
    }

    /// `PATCH` 응답은 `{ok, rules}`.
    public static func decodePatchedRules(_ resp: PetHTTPResponse) -> Result<HubApprovalRules, PetAPIError> {
        HubAPI.object(resp).flatMap { o in o.obj("rules").map { .success(decodeRulesObject($0)) } ?? .failure(.badResponse) }
    }

    private static func decodeRulesObject(_ o: HubObject) -> HubApprovalRules {
        let rules = o.objs("rules").compactMap { r -> HubApprovalRule? in
            guard let id = r.str("rule_id") else { return nil }
            return HubApprovalRule(id: id, summary: r.str("summary") ?? "허용 규칙", expired: r.bool("expired") ?? false,
                                   expiresAt: r.str("expires_at"), used: r.int("used") ?? 0, appliesToAgentIDs: r.strs("applies_to_agent_ids"))
        }
        let lim = o.obj("account_limit")
        return HubApprovalRules(rules: rules, limitValue: lim?.int("value"), limitCurrency: lim?.str("currency") ?? "KRW", limitUsed: lim?.int("used") ?? 0)
    }
}

/// 입력 검증 오류(한국어).
public struct HubInputError: Error, Equatable {
    public var text: String
    public init(_ t: String) { text = t }
}
