import Foundation

// 예약 섹션(NACHO-272 U6, 표 행 C3)의 Core. 경로·필드는 nacho-server spec/schedules.tsp와 같다.
// 요청 만들기는 순수 함수(HubAPI 재사용), 응답 읽기는 HubAPI.object/empty 위에 얹는다.
// 쓰기 요청은 앱처럼 Idempotency-Key 없이 보낸다(서버가 받지 않는다). 이 파일은 읽기·쓰기 모두 가짜 HTTP로 시험한다.

public struct HubScheduleRun: Equatable {
    public var runID: String
    public var startedAt: String
    public var finishedAt: String?
    public var status: String
    public var hasResult: Bool
    public var skippedReason: String?
    public var taskID: String?
}

public struct HubSchedule: Equatable {
    public var id: String
    public var agentID: String
    public var agentName: String
    public var headerTitle: String
    public var title: String
    public var subtitle: String
    public var actionText: String
    /// 행동 본문 블록을 줄로 푼 것(text → 글, items → "• 항목").
    public var actionLines: [String]
    public var scheduleText: String
    /// once | repeat | manual
    public var recurrence: String
    public var paused: Bool
    /// user | agent_resting
    public var pausedReason: String?
    public var registered: Bool
    public var nextRunAt: String?
    /// delegated | per_use_approval | nil
    public var credentialMode: String?
    public var deletable: Bool
    public var estimateMin: Int
    public var estimateMax: Int
    public var estimateLabel: String
    public var estimateID: String?
    public var lastRunStatus: String?
    public var runs: [HubScheduleRun]
    public var monthlyEstimateText: String
    public var overPlanWarning: Bool
    public var testUnavailableReason: String?
    public var approvalWaitText: String?
    public var draftSteps: [String]
    public var connections: [String]
    public var version: Int
}

public struct HubScheduleList: Equatable {
    public var active: [HubSchedule]
    public var paused: [HubSchedule]
    public var hasUserActions: Bool
    public var onceCount: Int
    public var repeatCount: Int
    public var isEmpty: Bool { active.isEmpty && paused.isEmpty }
}

public struct HubScheduleRunLog: Equatable {
    public var runID: String
    public var scheduleID: String
    public var dateText: String
    public var agentID: String
    public var taskID: String?
    public var status: String
    public var logLines: [String]
    public var resultLines: [String]
    public var creditUsed: Int
    public var failureMessage: String?
    public var skippedReason: String?
    public var stopReason: String?
    public var nextRunAt: String?
}

/// 지금 실행·시험 실행이 시작한 작업.
public struct HubStartedTask: Equatable {
    public var id: String
    public var title: String
}

/// 담당 바꾸기에서 고를 수 있는 나초.
public struct HubAgentChoice: Equatable {
    public var id: String
    public var name: String
}

public enum HubSchedulesAPI {
    private static let base = "/api/v1/scheduled-actions"

    private static func path(_ id: String, _ tail: String = "") -> String { "\(base)/\(id)\(tail)" }

    // MARK: requests (pure)

    public static func list(_ e: ServerEndpoint, agentID: String? = nil, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, base, query: agentID.map { [("agent_id", $0)] } ?? [], bearer: bearer)
    }

    public static func get(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, path(id), bearer: bearer)
    }

    public static func runLog(_ e: ServerEndpoint, id: String, runID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, path(id, "/runs/\(runID)"), bearer: bearer)
    }

    /// 초안 → 등록. 고칠 것이 없으면 본문 `{}`.
    public static func confirm(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, path(id, "/confirm"), bearer: bearer, json: [:])
    }

    public static func pause(_ e: ServerEndpoint, id: String, paused: Bool, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, path(id, "/pause"), bearer: bearer, json: ["paused": paused])
    }

    /// 크레딧을 쓴다. 상세에서 본 예상 id를 실으면 그사이 바뀐 경우 서버가 409 `estimate_changed`로 막는다.
    public static func runNow(_ e: ServerEndpoint, id: String, expectedEstimateID: String?, bearer: String?) -> PetHTTPRequest {
        var json: [String: Any] = [:]
        if let x = expectedEstimateID, !x.isEmpty { json["expected_estimate_id"] = x }
        return HubAPI.post(e, path(id, "/run-now"), bearer: bearer, json: json)
    }

    public static func test(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, path(id, "/test"), bearer: bearer, json: [:])
    }

    public static func transfer(_ e: ServerEndpoint, id: String, agentID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, path(id, "/transfer"), bearer: bearer, json: ["agent_id": agentID])
    }

    public static func remove(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, path(id), bearer: bearer)
    }

    /// 담당 바꾸기 후보(나초 목록).
    public static func agents(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/agents", bearer: bearer)
    }

    // MARK: responses

    public static func decodeList(_ resp: PetHTTPResponse) -> Result<HubScheduleList, PetAPIError> {
        HubAPI.object(resp).map { o in
            HubScheduleList(active: o.objs("active").map(schedule), paused: o.objs("paused").map(schedule),
                            hasUserActions: o.bool("has_user_actions") ?? false,
                            onceCount: o.int("active_once_count") ?? 0, repeatCount: o.int("active_repeat_count") ?? 0)
        }
    }

    /// `GET /scheduled-actions/{id}`: 본문이 곧 예약.
    public static func decodeSchedule(_ resp: PetHTTPResponse) -> Result<HubSchedule, PetAPIError> {
        HubAPI.object(resp).map(schedule)
    }

    /// confirm·pause·transfer: `{status:"ok", schedule}`.
    public static func decodeOk(_ resp: PetHTTPResponse) -> Result<HubSchedule, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<HubSchedule, PetAPIError> in
            guard o.str("status") == "ok", let s = o.obj("schedule") else { return .failure(.badResponse) }
            return .success(schedule(s))
        }
    }

    public static func decodeDeleted(_ resp: PetHTTPResponse) -> Result<Void, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<Void, PetAPIError> in o.str("status") == "deleted" ? .success(()) : .failure(.badResponse) }
    }

    public static func decodeStartedTask(_ resp: PetHTTPResponse) -> Result<HubStartedTask, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<HubStartedTask, PetAPIError> in
            guard let id = o.str("id") else { return .failure(.badResponse) }
            return .success(HubStartedTask(id: id, title: o.str("title") ?? ""))
        }
    }

    public static func decodeRunLog(_ resp: PetHTTPResponse) -> Result<HubScheduleRunLog, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<HubScheduleRunLog, PetAPIError> in
            guard let rid = o.str("run_id") else { return .failure(.badResponse) }
            return .success(HubScheduleRunLog(
                runID: rid, scheduleID: o.str("schedule_id") ?? "", dateText: o.str("date_text") ?? "", agentID: o.str("agent_id") ?? "",
                taskID: o.str("task_id"), status: o.str("status") ?? "",
                logLines: o.objs("log_nodes").compactMap { $0.str("text") },
                resultLines: lines(o.objs("result_blocks")),
                creditUsed: o.obj("credit")?.int("used") ?? 0,
                failureMessage: o.obj("failure")?.str("message"), skippedReason: o.str("skipped_reason"),
                stopReason: o.str("stop_reason"), nextRunAt: o.str("next_run_at")))
        }
    }

    /// 담당 바꾸기 후보: active 나초 중 지금 담당(`excluding`)을 뺀다(앱과 같다).
    public static func decodeAgentChoices(_ resp: PetHTTPResponse, excluding current: String) -> Result<[HubAgentChoice], PetAPIError> {
        HubAPI.object(resp).map { o in
            o.objs("agents").compactMap { a in
                guard let id = a.str("agent_id") ?? a.str("id"), id != current, a.str("status") == "active" else { return nil }
                return HubAgentChoice(id: id, name: a.str("name") ?? "")
            }
        }
    }

    // MARK: mapping

    static func lines(_ blocks: [HubObject]) -> [String] {
        blocks.flatMap { b -> [String] in
            var out: [String] = []
            if let t = b.str("text"), !t.isEmpty { out.append(t) }
            out += b.strs("items").map { "• \($0)" }
            return out
        }
    }

    static func schedule(_ o: HubObject) -> HubSchedule {
        let credit = o.obj("credit")
        return HubSchedule(
            id: o.str("schedule_id") ?? o.str("id") ?? "", agentID: o.str("agent_id") ?? "", agentName: o.str("agent_name") ?? "",
            headerTitle: o.str("header_title") ?? o.str("title") ?? "", title: o.str("title") ?? "", subtitle: o.str("subtitle") ?? "",
            actionText: o.str("action_text") ?? "", actionLines: lines(o.objs("action_blocks")),
            scheduleText: o.str("schedule_text") ?? "", recurrence: o.str("recurrence") ?? "repeat",
            paused: o.bool("paused") ?? false, pausedReason: o.str("paused_reason"), registered: o.bool("registered") ?? true,
            nextRunAt: o.str("next_run_at"), credentialMode: o.str("credential_mode"), deletable: o.bool("deletable") ?? false,
            estimateMin: credit?.int("estimate_min") ?? 0, estimateMax: credit?.int("estimate_max") ?? 0,
            estimateLabel: credit?.str("task_label") ?? "", estimateID: o.str("estimate_id"),
            lastRunStatus: o.str("last_run_status"), runs: o.objs("runs").map(run),
            monthlyEstimateText: o.str("monthly_estimate_text") ?? "", overPlanWarning: o.bool("over_plan_warning") ?? false,
            testUnavailableReason: o.str("test_unavailable_reason"), approvalWaitText: o.str("approval_wait_text"),
            draftSteps: o.strs("draft_steps"), connections: o.strs("connections"), version: o.int("version") ?? 0)
    }

    static func run(_ o: HubObject) -> HubScheduleRun {
        HubScheduleRun(runID: o.str("run_id") ?? o.str("id") ?? "", startedAt: o.str("started_at") ?? "", finishedAt: o.str("finished_at"),
                       status: o.str("status") ?? "", hasResult: o.bool("has_result") ?? false,
                       skippedReason: o.str("skipped_reason"), taskID: o.str("task_id"))
    }
}

/// 확인창 한 단계(앱 쪽 `HubConfirmStep`으로 옮겨 쓴다).
public struct HubScheduleStep: Equatable {
    public var title: String
    public var message: String
    public var confirmTitle: String
    public var destructive: Bool
}

public enum HubScheduleAction { case pause, runNow, test, transfer, delete, confirm, read }

public enum HubScheduleRules {
    /// 직접 실행(manual)과 쉬는 나초의 예약은 멈출 수 없다(앱과 같다).
    public static func canPause(_ s: HubSchedule) -> Bool { s.recurrence != "manual" && s.pausedReason != "agent_resting" }

    public static func pauseTitle(_ s: HubSchedule) -> String { s.paused ? "다시 시작" : "일시 정지" }

    /// 기능 스위치(`HubFeatureFlags.scheduleRunNow`)가 꺼지면 지금 실행·시험 실행 단추를 숨긴다.
    public static func runNowAvailable(flag: Bool) -> Bool { flag }

    /// 지금 실행은 크레딧을 쓴다. 누르기 전에 「크레딧을 씁니다」와 남은 크레딧을 보여 준다.
    public static func runNowStep(_ s: HubSchedule, remaining: Int?) -> HubScheduleStep {
        let range = s.estimateMax > s.estimateMin ? "약 \(PetText.number(s.estimateMin))~\(PetText.number(s.estimateMax)) 크레딧"
            : "약 \(PetText.number(s.estimateMax)) 크레딧"
        var msg = "크레딧을 씁니다. 1회 \(range)가 들어요."
        msg += remaining.map { " 지금 남은 크레딧 \(PetText.number($0))." } ?? " 남은 크레딧을 확인하지 못했어요."
        return HubScheduleStep(title: "지금 한 번 실행", message: msg, confirmTitle: "실행", destructive: false)
    }

    /// 삭제는 되돌릴 수 없어 확인창을 두 번 거친다.
    public static func deleteSteps(_ s: HubSchedule) -> [HubScheduleStep] {
        [HubScheduleStep(title: "예약 삭제", message: "지난 실행 기록도 함께 지워져요.", confirmTitle: "삭제하기", destructive: true),
         HubScheduleStep(title: "정말 삭제할까요?", message: "「\(s.title)」을 지우면 되돌릴 수 없어요.", confirmTitle: "삭제", destructive: true)]
    }
}

public enum HubScheduleText {
    public static func runStatus(_ s: String) -> String {
        switch s {
        case "running": return "진행 중"
        case "waiting": return "답을 기다려요"
        case "done": return "끝났어요"
        case "failed": return "실패했어요"
        case "interrupted": return "중단됐어요"
        case "canceled": return "취소했어요"
        case "skipped": return "건너뛰었어요"
        case "stopped_at_cap": return "상한에서 멈췄어요"
        default: return s
        }
    }

    public static func skipped(_ r: String) -> String {
        switch r {
        case "credits_exhausted": return "사용량을 다 썼어요"
        case "plan_cost_cap": return "요금제 사용 한도에 닿았어요"
        case "heavy_daily_limit": return "오늘 전화와 브라우저 한도에 닿았어요"
        case "free_call_limit": return "무료 전화를 다 썼어요"
        case "approval_expired": return "승인을 받지 못해 멈췄어요"
        case "reauth_required": return "다시 로그인하지 않았어요"
        case "key_delegation_off": return "접근이 꺼져 있어요"
        case "connection_missing": return "커넥터 연결이 끊겼어요"
        case "concurrency_full": return "다른 작업이 끝나지 않았어요"
        default: return r
        }
    }

    public static func credentialNotice(_ mode: String?) -> String? {
        switch mode {
        case "delegated": return "며칠에 한 번은 앱을 열어 주세요. 기간이 지나면 건너뛰어요."
        case "per_use_approval": return "쓸 때마다 휴대폰에서 승인해야 해요. 자리에 없으면 그 실행은 일어나지 않아요."
        default: return nil
        }
    }

    /// 실패를 한국어 한 줄로. 서버 영어 문구는 보이지 않는다(코드로만 가른다).
    public static func failure(_ err: PetAPIError, reason: String?, action: HubScheduleAction) -> String {
        switch (err.code ?? "", action) {
        case ("outcome_unknown", _): return "처리됐는지 확인하지 못했어요. 지금 상태를 다시 읽어요."
        case ("estimate_changed", .runNow): return "계획이 바뀌었어요. 확인하고 다시 눌러 주세요."
        case ("conflict", .test): return "이 예약은 시험 실행을 할 수 없어요."
        case ("not_found", .transfer): return "고른 나초를 찾지 못했어요."
        case ("not_found", _): return "이미 삭제된 예약이에요."
        default: break
        }
        if !err.text.isEmpty { return err.text }
        return ErrorText.userMessage(code: err.code ?? "internal_error", reason: reason, fallback: "")
    }
}

public extension PetAPIError {
    /// 로그인이 안 된 상태(앱 쪽은 `PetAPIError`를 직접 만들 수 없어 여기서 준다).
    static let signedOut = PetAPIError(status: 401, code: "unauthorized", text: "로그인이 필요해요.")
}
