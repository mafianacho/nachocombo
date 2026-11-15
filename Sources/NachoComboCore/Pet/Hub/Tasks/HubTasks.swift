import Foundation

// 작업 섹션 Core (NACHO-271 U5: C2·B16·C4). 경로·필드는 nacho-server spec/tasks.tsp·phone.tsp·live-view.tsp·schedules.tsp와 같다.
// 요청은 순수 함수(HubAPI 위)라 시험이 바이트를 확인한다. 시작·취소는 PetServerAPI.startTaskRequest/cancelTaskRequest를 그대로 쓴다.

/// `POST /tasks/{id}/continue`의 선택(spec ContinueChoice). rawValue가 본문 값이다.
public enum HubContinueChoice: String, CaseIterable, Equatable {
    case summarize, more, stop
    case resumeAfterReset = "resume_after_reset"

    public var title: String {
        switch self {
        case .summarize: return "정리해서 끝내기"
        case .more: return "계속하기"
        case .stop: return "여기서 멈추기"
        case .resumeAfterReset: return "채워지면 이어서 하기"
        }
    }
}

/// 작업 한 건(spec Task에서 화면에 쓰는 것만).
public struct HubTask {
    public let raw: HubObject
    public init(_ o: HubObject) { raw = o }

    public var id: String { raw.str("id") ?? "" }
    public var title: String { raw.str("title") ?? "" }
    public var state: String { raw.str("state") ?? "" }
    public var kind: String { raw.str("kind") ?? "" }
    public var waitReason: String? { raw.str("wait_reason") }
    public var version: Int { raw.int("version") ?? 0 }
    public var requestText: String { raw.str("request_text") ?? "" }
    public var requestedAt: String? { raw.str("requested_at") }
    public var estimateID: String? { raw.str("estimate_id") ?? raw.obj("credit")?.str("estimate_id") }
    public var steps: [String] { raw.objs("steps").compactMap { $0.str("text") } }
    public var creditUsed: Int { raw.obj("credit")?.int("used") ?? 0 }
    public var creditCap: Int? { raw.obj("credit")?.int("cap") }
    public var callID: String? { raw.obj("call")?.str("call_id") }
    public var counterpart: String? { raw.obj("call")?.str("counterpart_label") }
    public var callState: String? { raw.obj("call")?.str("call_state") }
    public var awaySummary: String? { raw.str("away_summary") }
    public var pendingRequestID: String? { raw.str("pending_request_id") }
    /// 브라우저·로그인 카드를 기다리는 작업만 원격 화면(라이브 뷰)을 연다.
    public var canOpenLiveView: Bool { state == "waiting" && ["browser", "login"].contains(waitReason ?? "") && pendingRequestID != nil }

    public var stepLine: String? {
        guard let s = raw.obj("current_step"), let text = s.str("text"), !text.isEmpty else { return nil }
        if let i = s.int("index"), let n = s.int("total"), n > 0 { return "\(i)/\(n)단계 · \(text)" }
        return text
    }

    /// 계획 글(`plan_blocks`). 비면 「계획 보기」를 숨긴다.
    public var planLines: [String] { HubTask.lines(raw.objs("plan_blocks")) }
    public var resultLines: [String] { HubTask.lines(raw.objs("result_blocks")) }

    static func lines(_ blocks: [HubObject]) -> [String] {
        var out: [String] = []
        for b in blocks {
            if let t = b.str("text"), !t.isEmpty { out.append(t) }
            out += b.strs("items").filter { !$0.isEmpty }
        }
        return out
    }

    public var isFinished: Bool { ["done", "failed", "canceled"].contains(state) }
    public var isActive: Bool { ["planned", "queued", "running", "waiting", "interrupted"].contains(state) }
    public var needsAnswer: Bool { state == "waiting" }
    /// 끝난 작업만 루틴 초안을 만든다(서버: 끝나지 않으면 409).
    public var canRoutine: Bool { isFinished }
    /// 서버: 끝난 작업의 추가 지시는 409.
    public var canInstruct: Bool { ["planned", "queued", "running", "waiting"].contains(state) }
    public var canStart: Bool { state == "planned" }
    public var canCancel: Bool { ["planned", "queued", "running", "waiting"].contains(state) }
    public var isLiveCall: Bool { kind == "phone" && callID != nil && callState != "ended" && !isFinished }

    /// D3 멈추고 묻기(waiting/over_cap)의 선택. 기한이 지나 다시 묻는 작업(queued/resume_confirm)은 「이어서」 하나뿐이다.
    public var choices: [HubContinueChoice] {
        if state == "waiting", waitReason == "over_cap" { return HubContinueChoice.allCases }
        if state == "queued", waitReason == "resume_confirm" { return [.resumeAfterReset] }
        return []
    }

    public var statusText: String {
        switch state {
        case "planned": return "시작 전"
        case "queued":
            if waitReason == "resume_confirm" { return "이어서 할지 알려 주세요" }
            return raw.str("queue_reason") == "reset" ? "채워지면 시작하거나 이어서 해요" : "대기 중"
        case "running": return raw.bool("stalled") == true ? "진행 소식이 없어요" : "진행 중"
        case "waiting":
            switch waitReason {
            case "approval": return "승인이 필요해요"
            case "input": return "입력이 필요해요"
            case "login": return "다시 로그인이 필요해요"
            case "connection": return "커넥터 연결이 필요해요"
            case "browser": return "직접 조작이 필요해요"
            case "agent_limit": return "나초 권한 때문에 멈췄어요"
            case "over_cap": return "정한 양을 넘어 멈췄어요"
            case "resume_confirm": return "이어서 할지 알려 주세요"
            default: return "답이 필요해요"
            }
        case "done": return "끝났어요"
        case "failed": return "못 끝냈어요"
        case "interrupted": return "중간에 끊겼어요"
        case "canceled": return "취소했어요"
        default: return "상태를 확인하고 있어요"
        }
    }

    // MARK: failure

    private var failure: HubObject? { raw.obj("failure") }
    public var failureCode: String? { failure?.str("code") }
    public var failureTitle: String? { failureCode.map { HubTask.failTitles[$0] ?? HubTask.failTitles["unknown"]! } }
    public var failureWhy: String? { failureCode.map { HubTask.failWhy[$0] ?? HubTask.failWhy["unknown"]! } }
    public var completedActions: [String] { failure?.strs("completed_actions") ?? [] }
    public var pendingActions: [String] { failure?.strs("pending_actions") ?? [] }
    public var uncertainActions: [String] { failure?.strs("uncertain_actions") ?? [] }
    public var nextActionTexts: [String] { (failure?.strs("next_actions") ?? []).compactMap { HubTask.nextTitles[$0] } }

    static let nextTitles: [String: String] = [
        "retry": "다시 부탁하기", "find_other": "다른 곳 찾기", "call_myself": "내가 직접 걸기",
        "call_later": "나중에 다시 걸기", "fix_number": "번호 고치기",
    ]
    static let failTitles: [String: String] = [
        "server_error": "서버에 문제가 생겼어요", "external_error": "외부 서비스에 문제가 생겼어요", "site_blocked": "사이트가 자동 접근을 막았어요",
        "login_failed": "로그인하지 못했어요", "approval_denied": "승인을 거절했어요", "approval_expired": "승인 시간이 지났어요",
        "user_canceled": "취소했어요", "connection_missing": "필요한 커넥터가 없어요", "no_answer": "전화를 받지 않았어요",
        "busy": "통화 중이었어요", "invalid_number": "없는 번호예요", "call_not_allowed": "나초가 걸 수 없는 번호예요",
        "over_cap_stopped": "정한 양을 넘어 멈췄어요", "agent_limit": "동시에 할 수 있는 작업이 다 찼어요",
        "action_blocked": "막혀서 하지 못했어요", "unknown": "끝내지 못했어요",
    ]
    static let failWhy: [String: String] = [
        "server_error": "서버에 문제가 생겨 작업을 마치지 못했어요.", "external_error": "외부 서비스에서 오류가 나서 작업을 마치지 못했어요.",
        "site_blocked": "사이트가 나초의 접속을 받아 주지 않았어요.", "login_failed": "로그인을 마치지 못했어요.",
        "approval_denied": "승인하지 않아서 작업을 멈췄어요.", "approval_expired": "승인을 기다리다 시간이 지나 작업을 멈췄어요.",
        "user_canceled": "직접 취소해서 작업을 멈췄어요.", "connection_missing": "이 작업에 필요한 커넥터가 없어서 멈췄어요.",
        "no_answer": "상대가 전화를 받지 않았어요.", "busy": "상대가 다른 통화 중이라 연결되지 않았어요.",
        "invalid_number": "걸려던 번호가 없는 번호라 연결되지 않았어요.", "call_not_allowed": "이 번호는 나초가 걸 수 없어서 전화를 걸지 않았어요.",
        "over_cap_stopped": "예상한 양을 넘을 것 같아서 멈췄어요.", "agent_limit": "한꺼번에 할 수 있는 작업이 가득 차서 시작하지 못했어요.",
        "action_blocked": "허락이나 연결이 더 필요하거나 지금은 쓸 수 없는 기능이라 작업을 하지 못했어요.",
        "unknown": "이유를 알 수 없어 작업을 끝내지 못했어요.",
    ]
}

public struct HubTaskList {
    public var active: [HubTask]
    public var recent: [HubTask]
    public var running: Int
    public var limit: Int
    public var queued: Int
    public var isEmpty: Bool { active.isEmpty && recent.isEmpty }
}

/// 실행 기록 한 줄(spec LogNode).
public struct HubLogNode {
    public let id: Int
    public let kind: String
    public let text: String
    public let createdAt: String?
}

public struct HubCallLine {
    public let speaker: String
    public let text: String
    public let relayed: Bool
    public var speakerText: String {
        switch speaker {
        case "agent": return "나초"
        case "counterpart": return "상대"
        case "user_note": return "내 메모"
        default: return "안내"
        }
    }
}

/// `GET /calls/{id}` (spec CallDetail).
public struct HubCallDetail {
    public let raw: HubObject
    public init(_ o: HubObject) { raw = o }
    private var call: HubObject? { raw.obj("call") }
    private var footer: HubObject? { raw.obj("footer") }

    public var id: String { call?.str("id") ?? "" }
    public var taskID: String { call?.str("task_id") ?? "" }
    public var state: String { call?.str("state") ?? "" }
    public var isLive: Bool { state != "ended" }
    public var counterpart: String { call?.str("counterpart_label") ?? "" }
    public var phoneMasked: String { call?.str("phone_masked") ?? "" }
    public var purpose: String { call?.str("purpose") ?? "" }
    public var stateText: String {
        switch state {
        case "dialing": return "전화 거는 중"
        case "ringing": return "신호 가는 중"
        case "in_call": return "통화 중"
        case "ended": return "통화 끝"
        default: return "상태를 확인하고 있어요"
        }
    }
    public var outcomeText: String? {
        guard let o = call?.str("outcome") else { return nil }
        return HubCallDetail.outcomes[o] ?? "통화가 끝났어요"
    }
    public var attemptLine: String? {
        guard let a = call?.int("attempts"), let m = call?.int("max_attempts"), a > 0, m > 0 else { return nil }
        return "\(a)번째 시도 (최대 \(m)번)"
    }
    public var creditsUsed: Int { footer?.int("credits_used") ?? call?.int("credits_used") ?? 0 }
    public var disclosure: String { footer?.str("disclosure") ?? "" }
    public var headline: String? { footer?.obj("result")?.str("headline") }
    public var resultItems: [String] {
        (footer?.obj("result")?.objs("items") ?? []).compactMap { i in
            guard let t = i.str("text"), !t.isEmpty else { return nil }
            let kind = ["agreed": "합의", "changed": "달라진 점", "relayed": "전한 말", "condition": "조건"][i.str("kind") ?? ""] ?? "결과"
            return "\(kind): \(t)"
        }
    }
    public var lines: [HubCallLine] {
        raw.objs("lines").map { HubCallLine(speaker: $0.str("speaker") ?? "", text: $0.str("text") ?? "", relayed: $0.bool("relayed") ?? false) }
    }

    static let outcomes: [String: String] = [
        "answered": "답을 받았어요", "answered_partial": "답을 일부만 받았어요", "no_answer": "전화를 받지 않았어요", "busy": "통화 중이었어요",
        "voicemail": "음성 사서함으로 넘어갔어요", "invalid_number": "없는 번호였어요", "declined_by_other": "상대가 AI 통화를 원하지 않았어요",
        "ars_blocked": "자동 응답을 지나가지 못했어요", "call_failed": "전화를 걸지 못했어요", "user_ended": "내가 끊었어요",
        "wait_expired": "확인을 기다리다 시간이 지나 마무리했어요",
    ]
}

/// 원격 화면 티켓(spec LiveViewTicket). 티켓(`vt_…`)은 1회용이라 저장·로그 금지: 화면에는 `viewerURL`만 쓰고 출력은 가린다.
public struct HubViewerTicket: CustomStringConvertible, CustomDebugStringConvertible {
    public let viewerURL: String
    public let verifiedHost: String?
    public let expiresAt: String?
    public var description: String { "HubViewerTicket(host: \(verifiedHost ?? "-"), <redacted>)" }
    public var debugDescription: String { description }
}

public enum HubTasks {
    /// 추가 지시·통화 메모 길이 상한. 서버 spec에 상한이 없어 앱처럼 짧게 둔다(NACHO-271 PR에 적음).
    public static let textMax = 2000

    // MARK: requests (pure)

    private static func seg(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private static func taskPath(_ id: String) -> String { "/api/v1/tasks/\(seg(id))" }

    /// 쿼리 값 인코딩은 HubAPI가 한다. 경로는 `%2F`를 URLComponents가 다시 바꾸지 않게 percentEncodedPath로 만든다.
    private static func fix(_ r: PetHTTPRequest, _ e: ServerEndpoint, _ path: String, query: [(String, String)] = []) -> PetHTTPRequest {
        var c = URLComponents(url: e.base, resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        if !query.isEmpty {
            c.percentEncodedQuery = query.map { "\(PetHTTPRequest.formEscape($0.0))=\(PetHTTPRequest.formEscape($0.1))" }.joined(separator: "&")
        }
        var r = r
        r.url = c.url!
        return r
    }

    public static func list(_ e: ServerEndpoint, bearer: String?, agentID: String? = nil) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/tasks", query: agentID.map { [("agent_id", $0)] } ?? [], bearer: bearer)
    }

    /// 끝난 작업 이력. `next`는 `HubPage.nextQuery` 그대로(`before`).
    public static func history(_ e: ServerEndpoint, bearer: String?, agentID: String? = nil, next: [(String, String)]? = nil, limit: Int? = nil) -> PetHTTPRequest {
        var q: [(String, String)] = []
        if let a = agentID { q.append(("agent_id", a)) }
        q += next ?? []
        if let l = limit { q.append(("limit", String(l))) }
        return HubAPI.get(e, "/api/v1/tasks/history", query: q, bearer: bearer)
    }

    public static func get(_ e: ServerEndpoint, bearer: String?, taskID: String) -> PetHTTPRequest {
        fix(HubAPI.get(e, "/", bearer: bearer), e, taskPath(taskID))
    }

    public static func logs(_ e: ServerEndpoint, bearer: String?, taskID: String) -> PetHTTPRequest {
        fix(HubAPI.get(e, "/", bearer: bearer), e, taskPath(taskID) + "/logs")
    }

    public static func continueTask(_ e: ServerEndpoint, bearer: String?, taskID: String, choice: HubContinueChoice, expectedEstimateID: String?) -> PetHTTPRequest {
        var json: [String: Any] = ["choice": choice.rawValue]
        if let id = expectedEstimateID, !id.isEmpty { json["expected_estimate_id"] = id }
        return fix(HubAPI.post(e, "/", bearer: bearer, json: json), e, taskPath(taskID) + "/continue")
    }

    /// 키를 두지 않는다: 5xx·시간 초과 뒤 다시 보내면 초안이 또 생길 수 있어, 누른 사람이 확인하고 다시 누른다(앱과 같다).
    public static func routineDraft(_ e: ServerEndpoint, bearer: String?, taskID: String) -> PetHTTPRequest {
        fix(HubAPI.post(e, "/", bearer: bearer, json: [:]), e, taskPath(taskID) + "/routine-draft")
    }

    public static func instruction(_ e: ServerEndpoint, bearer: String?, taskID: String, text: String, idempotencyKey: String) -> PetHTTPRequest {
        fix(HubAPI.post(e, "/", bearer: bearer, json: ["text": text], idempotencyKey: idempotencyKey), e, taskPath(taskID) + "/instruction")
    }

    public static func call(_ e: ServerEndpoint, bearer: String?, callID: String) -> PetHTTPRequest {
        fix(HubAPI.get(e, "/", bearer: bearer), e, "/api/v1/calls/\(seg(callID))")
    }

    public static func callNote(_ e: ServerEndpoint, bearer: String?, taskID: String, text: String, idempotencyKey: String) -> PetHTTPRequest {
        fix(HubAPI.post(e, "/", bearer: bearer, json: ["text": text], idempotencyKey: idempotencyKey), e, taskPath(taskID) + "/call/note")
    }

    public static func callHangup(_ e: ServerEndpoint, bearer: String?, taskID: String) -> PetHTTPRequest {
        fix(HubAPI.post(e, "/", bearer: bearer, json: [:]), e, taskPath(taskID) + "/call/hangup")
    }

    /// `attempt_id` 또는 `request_id` 중 하나(spec LiveViewRequest).
    public static func liveViewSession(_ e: ServerEndpoint, bearer: String?, attemptID: String?, requestID: String?) -> PetHTTPRequest {
        var json: [String: Any] = [:]
        if let a = attemptID, !a.isEmpty { json["attempt_id"] = a }
        if let r = requestID, !r.isEmpty { json["request_id"] = r }
        return HubAPI.post(e, "/api/v1/live-view/sessions", bearer: bearer, json: json)
    }

    public static func viewerTicket(_ e: ServerEndpoint, bearer: String?, attemptID: String) -> PetHTTPRequest {
        fix(HubAPI.post(e, "/", bearer: bearer, json: [:]), e, "/api/v1/connections/attempts/\(seg(attemptID))/viewer-ticket")
    }

    // MARK: responses

    public static func decodeList(_ resp: PetHTTPResponse) -> Result<HubTaskList, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            guard o.raw["active_items"] != nil || o.raw["recent_items"] != nil else { return .failure(.badResponse) }
            let c = o.obj("concurrency")
            return .success(HubTaskList(active: o.objs("active_items").map(HubTask.init), recent: o.objs("recent_items").map(HubTask.init),
                                        running: c?.int("running") ?? 0, limit: c?.int("limit") ?? 0, queued: c?.int("queued") ?? 0))
        }
    }

    public static func decodeTask(_ resp: PetHTTPResponse) -> Result<HubTask, PetAPIError> {
        HubAPI.object(resp).map(HubTask.init)
    }

    public static func decodeLogs(_ resp: PetHTTPResponse) -> Result<[HubLogNode], PetAPIError> {
        guard (200...299).contains(resp.status) else { return .failure(HubAPI.error(resp)) }
        guard let arr = (try? JSONSerialization.jsonObject(with: resp.body)) as? [Any] else { return .failure(.badResponse) }
        return .success(arr.compactMap { ($0 as? [String: Any]).map(HubObject.init) }.map {
            HubLogNode(id: $0.int("id") ?? 0, kind: $0.str("kind") ?? "", text: $0.str("text") ?? "", createdAt: $0.str("created_at"))
        })
    }

    public static func decodeCall(_ resp: PetHTTPResponse) -> Result<HubCallDetail, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o): return o.obj("call") == nil ? .failure(.badResponse) : .success(HubCallDetail(o))
        }
    }

    public static func decodeTicket(_ resp: PetHTTPResponse) -> Result<HubViewerTicket, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            guard let u = o.str("viewer_url"), !u.isEmpty else { return .failure(.badResponse) }
            return .success(HubViewerTicket(viewerURL: u, verifiedHost: o.str("verified_host"), expiresAt: o.str("expires_at")))
        }
    }

    /// 409 `estimate_changed`면 새 예상이 담긴 작업.
    public static func estimateChangedTask(_ resp: PetHTTPResponse) -> HubTask? {
        guard resp.status == 409, PetServerError.code(resp.body) == "estimate_changed",
              let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any], let t = o["task"] as? [String: Any] else { return nil }
        return HubTask(HubObject(t))
    }

    public static let estimateChangedText = "계획이 바뀌었어요. 확인하고 다시 눌러 주세요."

    public static func continueFailureText(_ e: PetAPIError) -> String {
        e.code == "estimate_changed" ? estimateChangedText : e.text
    }

    public static func continueFailureText(_ resp: PetHTTPResponse) -> String { continueFailureText(HubAPI.error(resp)) }

    /// 429의 `Retry-After`(초).
    public static func retryAfterSeconds(_ resp: PetHTTPResponse) -> Int? {
        guard resp.status == 429, let h = resp.header("Retry-After"), let n = Int(h.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return n
    }

    // MARK: input validation

    public static func validateText(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "내용을 적어 주세요." }
        if t.count > textMax { return "\(textMax)자까지 쓸 수 있어요." }
        return nil
    }

    /// 통화 메모: 비밀번호·카드 번호·인증번호는 보낼 수 없다(앱 `phone.control.noteSecret`).
    public static func validateCallNote(_ raw: String) -> String? {
        if let p = validateText(raw) { return p }
        let lower = raw.lowercased()
        let words = ["비밀번호", "패스워드", "password", "암호", "인증번호", "인증 번호", "인증코드", "인증 코드", "otp", "cvc", "cvv", "보안코드", "보안 코드"]
        let digits = raw.filter { !" -".contains($0) }
        var run = 0
        var longest = 0
        for ch in digits { if ch.isASCII && ch.isNumber { run += 1; longest = max(longest, run) } else { run = 0 } }
        if words.contains(where: { lower.contains($0) }) || longest >= 13 { return "비밀번호, 카드 번호, 인증번호는 메모로 보낼 수 없어요" }
        return nil
    }
}

/// 라이브 뷰(C4): 서버 → 맥 방향 보기만 한다. 맥 화면은 서버로 보내지 않는다.
public enum HubLiveView {
    /// 나초딥 호스팅 뷰어 호스트(spec live-view.tsp `viewer_url` = `https://<나초딥>/api/v1/remote/viewer#t=…`,
    /// 나초서버 config/default.toml `dip.base_url`). 정확히 같은 이름만, 기본 포트(443)만 허용한다(하위·상위 도메인 불허).
    public static let viewerHosts: [String] = ["dip.mafianacho.com"]

    /// 서버가 준 보기 주소 중 https이고 서버 호스트(와 포트) 또는 나초딥 뷰어 호스트(443)인 것만 연다.
    /// userinfo가 있거나 다른 호스트·스킴·포트면 nil.
    public static func allowedURL(_ raw: String, serverHost: String, serverPort: Int? = nil, viewerHosts: [String] = HubLiveView.viewerHosts) -> URL? {
        let host = serverHost.lowercased()
        guard !host.isEmpty, let c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil, let h = c.host?.lowercased(), !h.isEmpty, let url = c.url else { return nil }
        let port = c.port ?? 443
        if h == host, port == (serverPort ?? 443) { return url }
        if port == 443, viewerHosts.contains(where: { $0.lowercased() == h }) { return url }
        return nil
    }

    /// 보기 창 안내(앱 `browser.live.*`와 같은 뜻).
    public static let helpLines: [String] = [
        "이 창은 나초 서버가 열어 둔 원격 브라우저 화면을 보여 줘요.",
        "서버에서 맥으로 보는 방향뿐이에요. 맥 화면은 서버로 보내지 않아요.",
        "이 브라우저는 나만 쓰는 따로 닫힌 공간이에요. 여기에 입력한 내용은 그 사이트로만 가고, 앱에는 남기지 않아요.",
        "주소가 서버 밖으로 바뀌면 화면을 열지 않아요. 시간이 다 되면 카드에서 다시 열어 주세요.",
    ]
}
