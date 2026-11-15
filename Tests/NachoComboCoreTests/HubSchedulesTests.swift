import XCTest
@testable import NachoComboCore

/// 예약 섹션 Core (NACHO-272 U6, 표 행 C3). 요청은 바이트 단위로, 응답·오류는 한국어 문구까지 확인한다. 가짜 HTTP만 쓴다.
final class HubSchedulesTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private let sid = "11111111-1111-1111-1111-111111111111"
    private let rid = "22222222-2222-2222-2222-222222222222"

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String, headers: [String: String] = [:]) -> PetHTTPResponse {
        PetHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    private func scheduleJSON(id: String = "11111111-1111-1111-1111-111111111111", paused: Bool = false, recurrence: String = "repeat",
                              reason: String? = nil, deletable: Bool = true, estimateID: String? = "33333333-3333-3333-3333-333333333333") -> String {
        var s = "{\"schedule_id\":\"\(id)\",\"id\":\"\(id)\",\"agent_id\":\"a1\",\"agent_name\":\"나초\",\"header_title\":\"아침 메일\",\"title\":\"메일 확인\","
        s += "\"subtitle\":\"매일\",\"action_text\":\"새 메일을 확인해 줘\",\"action_blocks\":[{\"kind\":\"text\",\"text\":\"새 메일을 확인해요\"},{\"kind\":\"list\",\"items\":[\"하나\",\"둘\"]}],"
        s += "\"schedule_text\":\"매일 09:00\",\"recurrence\":\"\(recurrence)\",\"paused\":\(paused),"
        if let r = reason { s += "\"paused_reason\":\"\(r)\"," }
        s += "\"registered\":true,\"next_run_at\":\"2026-11-16T00:00:00Z\",\"credential_mode\":\"per_use_approval\",\"deletable\":\(deletable),"
        s += "\"credit\":{\"estimate_min\":5,\"estimate_max\":10,\"task_label\":\"메일 확인\"},"
        if let eid = estimateID { s += "\"estimate_id\":\"\(eid)\"," }
        s += "\"last_run_status\":\"done\",\"monthly_estimate_text\":\"한 달 약 150~300크레딧\",\"over_plan_warning\":false,"
        s += "\"runs\":[{\"run_id\":\"\(rid)\",\"id\":\"\(rid)\",\"started_at\":\"2026-11-15T00:00:00Z\",\"status\":\"skipped\",\"has_result\":false,\"skipped_reason\":\"credits_exhausted\"}],"
        s += "\"draft_steps\":[],\"variable_fields\":[],\"fixed_fields\":[],\"connections\":[],\"version\":4,\"created_at\":\"2026-11-01T00:00:00Z\",\"updated_at\":\"2026-11-02T00:00:00Z\"}"
        return s
    }

    // MARK: request bytes

    func testListRequestWithAndWithoutAgentFilter() {
        let all = HubSchedulesAPI.list(e, bearer: "T")
        XCTAssertEqual(all.method, "GET")
        XCTAssertEqual(all.url.absoluteString, "https://nacho.example.com/api/v1/scheduled-actions")
        XCTAssertEqual(all.headers["Authorization"], "Bearer T")
        XCTAssertNil(all.body)
        let one = HubSchedulesAPI.list(e, agentID: "a 1", bearer: "T")
        XCTAssertEqual(one.url.absoluteString, "https://nacho.example.com/api/v1/scheduled-actions?agent_id=a%201")
    }

    func testGetAndRunLogPaths() {
        XCTAssertEqual(HubSchedulesAPI.get(e, id: sid, bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/scheduled-actions/\(sid)")
        let r = HubSchedulesAPI.runLog(e, id: sid, runID: rid, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/scheduled-actions/\(sid)/runs/\(rid)")
    }

    func testPauseBodyBothWays() {
        let p = HubSchedulesAPI.pause(e, id: sid, paused: true, bearer: "T")
        XCTAssertEqual(p.method, "POST")
        XCTAssertEqual(p.url.path, "/api/v1/scheduled-actions/\(sid)/pause")
        XCTAssertEqual(body(p), "{\"paused\":true}")
        XCTAssertEqual(body(HubSchedulesAPI.pause(e, id: sid, paused: false, bearer: "T")), "{\"paused\":false}")
    }

    func testRunNowCarriesExpectedEstimateWhenKnown() {
        let r = HubSchedulesAPI.runNow(e, id: sid, expectedEstimateID: "E1", bearer: "T")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/scheduled-actions/\(sid)/run-now")
        XCTAssertEqual(body(r), "{\"expected_estimate_id\":\"E1\"}")
        XCTAssertEqual(body(HubSchedulesAPI.runNow(e, id: sid, expectedEstimateID: nil, bearer: "T")), "{}")
    }

    func testTestTransferRemoveConfirm() {
        let t = HubSchedulesAPI.test(e, id: sid, bearer: "T")
        XCTAssertEqual(t.method, "POST")
        XCTAssertEqual(t.url.path, "/api/v1/scheduled-actions/\(sid)/test")
        let x = HubSchedulesAPI.transfer(e, id: sid, agentID: "A2", bearer: "T")
        XCTAssertEqual(x.url.path, "/api/v1/scheduled-actions/\(sid)/transfer")
        XCTAssertEqual(body(x), "{\"agent_id\":\"A2\"}")
        let d = HubSchedulesAPI.remove(e, id: sid, bearer: "T")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/scheduled-actions/\(sid)")
        XCTAssertNil(d.body)
        let c = HubSchedulesAPI.confirm(e, id: sid, bearer: "T")
        XCTAssertEqual(c.url.path, "/api/v1/scheduled-actions/\(sid)/confirm")
        XCTAssertEqual(body(c), "{}")
    }

    func testAgentsRequestForTransferChoices() {
        let r = HubSchedulesAPI.agents(e, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/agents")
    }

    // MARK: responses

    func testDecodeListGroupsAndCounts() throws {
        let json = "{\"active\":[\(scheduleJSON())],\"paused\":[\(scheduleJSON(id: "44444444-4444-4444-4444-444444444444", paused: true, reason: "user"))],"
            + "\"has_user_actions\":true,\"active_once_count\":0,\"active_repeat_count\":1}"
        let list = try HubSchedulesAPI.decodeList(resp(200, json)).get()
        XCTAssertEqual(list.active.count, 1)
        XCTAssertEqual(list.paused.count, 1)
        XCTAssertEqual(list.onceCount, 0)
        XCTAssertEqual(list.repeatCount, 1)
        XCTAssertTrue(list.hasUserActions)
        XCTAssertTrue(list.paused[0].paused)
        XCTAssertEqual(list.paused[0].pausedReason, "user")
        XCTAssertEqual(list.active[0].estimateID, "33333333-3333-3333-3333-333333333333")
    }

    func testDecodeListEmpty() throws {
        let list = try HubSchedulesAPI.decodeList(resp(200, "{\"active\":[],\"paused\":[],\"has_user_actions\":false,\"active_once_count\":0,\"active_repeat_count\":0}")).get()
        XCTAssertTrue(list.isEmpty)
        XCTAssertFalse(list.hasUserActions)
    }

    func testDecodeScheduleFields() throws {
        let s = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON())).get()
        XCTAssertEqual(s.id, sid)
        XCTAssertEqual(s.title, "메일 확인")
        XCTAssertEqual(s.headerTitle, "아침 메일")
        XCTAssertEqual(s.scheduleText, "매일 09:00")
        XCTAssertEqual(s.recurrence, "repeat")
        XCTAssertEqual(s.version, 4)
        XCTAssertEqual(s.estimateMin, 5)
        XCTAssertEqual(s.estimateMax, 10)
        XCTAssertEqual(s.credentialMode, "per_use_approval")
        XCTAssertEqual(s.actionLines, ["새 메일을 확인해요", "• 하나", "• 둘"])
        XCTAssertEqual(s.runs.count, 1)
        XCTAssertEqual(s.runs[0].status, "skipped")
        XCTAssertEqual(s.runs[0].skippedReason, "credits_exhausted")
        XCTAssertTrue(s.deletable)
    }

    func testDecodeOkEnvelopeAndDeleted() throws {
        let ok = try HubSchedulesAPI.decodeOk(resp(200, "{\"status\":\"ok\",\"schedule\":\(scheduleJSON(paused: true, reason: "user"))}")).get()
        XCTAssertTrue(ok.paused)
        XCTAssertNoThrow(try HubSchedulesAPI.decodeDeleted(resp(200, "{\"status\":\"deleted\"}")).get())
        XCTAssertThrowsError(try HubSchedulesAPI.decodeDeleted(resp(200, "{\"status\":\"nope\"}")).get())
    }

    func testDecodeStartedTask() throws {
        let t = try HubSchedulesAPI.decodeStartedTask(resp(200, "{\"id\":\"T1\",\"title\":\"[시험] 메일\",\"state\":\"running\"}")).get()
        XCTAssertEqual(t.id, "T1")
        XCTAssertEqual(t.title, "[시험] 메일")
    }

    func testDecodeRunLog() throws {
        let json = "{\"run_id\":\"\(rid)\",\"schedule_id\":\"\(sid)\",\"date_text\":\"11월 4일 09:05\",\"agent_id\":\"a1\",\"status\":\"done\","
            + "\"log_nodes\":[{\"id\":1,\"kind\":\"step\",\"text\":\"메일을 읽었어요\",\"created_at\":\"2026-11-04T00:05:00Z\"}],"
            + "\"result_blocks\":[{\"kind\":\"text\",\"text\":\"새 메일 3통\"}],\"credit\":{\"used\":7,\"refund_status\":\"none\"},\"next_run_at\":\"2026-11-05T00:00:00Z\"}"
        let log = try HubSchedulesAPI.decodeRunLog(resp(200, json)).get()
        XCTAssertEqual(log.dateText, "11월 4일 09:05")
        XCTAssertEqual(log.status, "done")
        XCTAssertEqual(log.logLines, ["메일을 읽었어요"])
        XCTAssertEqual(log.resultLines, ["새 메일 3통"])
        XCTAssertEqual(log.creditUsed, 7)
        XCTAssertNil(log.skippedReason)
        let skipped = "{\"run_id\":\"\(rid)\",\"schedule_id\":\"\(sid)\",\"date_text\":\"x\",\"agent_id\":\"a1\",\"status\":\"skipped\",\"skipped_reason\":\"connection_missing\",\"log_nodes\":[],\"credit\":{\"used\":0,\"refund_status\":\"none\"}}"
        XCTAssertEqual(try HubSchedulesAPI.decodeRunLog(resp(200, skipped)).get().skippedReason, "connection_missing")
    }

    func testDecodeAgentChoicesKeepsActiveAndRestingOthersOnly() throws {
        let json = "{\"agents\":[{\"id\":\"a1\",\"agent_id\":\"a1\",\"name\":\"나초\",\"status\":\"active\",\"is_default\":true},"
            + "{\"id\":\"a2\",\"agent_id\":\"a2\",\"name\":\"콤보\",\"status\":\"active\"},{\"id\":\"a3\",\"agent_id\":\"a3\",\"name\":\"쉬는 나초\",\"status\":\"resting\"},"
            + "{\"id\":\"a4\",\"agent_id\":\"a4\",\"name\":\"지워지는\",\"status\":\"deleting\"}],\"limits\":{},\"caps\":{}}"
        let choices = try HubSchedulesAPI.decodeAgentChoices(resp(200, json), excluding: "a1").get()
        XCTAssertEqual(choices.map { $0.id }, ["a2"], "앱처럼 active 나초만, 지금 담당은 뺀다")
        XCTAssertEqual(choices.map { $0.name }, ["콤보"])
    }

    // MARK: errors → 한국어

    func testErrorsAre401404409AndServerCodes() {
        XCTAssertEqual(HubSchedulesAPI.decodeList(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failureValue?.status, 401)
        let nf = HubSchedulesAPI.decodeSchedule(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")).failureValue
        XCTAssertTrue(nf?.isNotFound ?? false)
        let vc = HubSchedulesAPI.decodeOk(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"}}")).failureValue
        XCTAssertTrue(vc?.isVersionConflict ?? false)
        XCTAssertEqual(HubSchedulesAPI.decodeStartedTask(resp(500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")).failureValue?.text,
                       "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
    }

    func testRunNowFailureTextsAreKorean() {
        let credits = PetAPIError(status: 402, code: "task_not_startable", text: "")
        XCTAssertTrue(HubScheduleText.failure(credits, reason: "credits_exhausted", action: .runNow).contains("크레딧이 모자라요."))
        let changed = PetAPIError(status: 409, code: "estimate_changed", text: "")
        XCTAssertEqual(HubScheduleText.failure(changed, reason: nil, action: .runNow), "계획이 바뀌었어요. 확인하고 다시 눌러 주세요.")
        let test = PetAPIError(status: 409, code: "conflict", text: "")
        XCTAssertEqual(HubScheduleText.failure(test, reason: nil, action: .test), "이 예약은 시험 실행을 할 수 없어요.")
        let gone = PetAPIError(status: 404, code: "not_found", text: "")
        XCTAssertEqual(HubScheduleText.failure(gone, reason: nil, action: .transfer), "고른 나초를 찾지 못했어요.")
        XCTAssertEqual(HubScheduleText.failure(gone, reason: nil, action: .delete), "이미 삭제된 예약이에요.")
        let unknown = PetAPIError(status: 0, code: "outcome_unknown", text: "")
        XCTAssertEqual(HubScheduleText.failure(unknown, reason: nil, action: .runNow), "처리됐는지 확인하지 못했어요. 지금 상태를 다시 읽어요.")
        XCTAssertEqual(HubScheduleText.failure(.network, reason: nil, action: .pause), PetAPIError.network.text)
        XCTAssertEqual(HubScheduleText.failure(PetAPIError(status: 500, code: "internal_error", text: "일시적인 문제가 생겼어요. 다시 시도해 주세요."), reason: nil, action: .delete),
                       "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
    }

    // MARK: 규칙

    func testPauseOnlyForRepeatingNotRestingSchedules() throws {
        let repeating = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON())).get()
        XCTAssertTrue(HubScheduleRules.canPause(repeating))
        XCTAssertEqual(HubScheduleRules.pauseTitle(repeating), "일시 정지")
        let paused = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON(paused: true, reason: "user"))).get()
        XCTAssertEqual(HubScheduleRules.pauseTitle(paused), "다시 시작")
        XCTAssertTrue(HubScheduleRules.canPause(paused))
        let resting = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON(paused: true, reason: "agent_resting"))).get()
        XCTAssertFalse(HubScheduleRules.canPause(resting), "쉬는 나초의 예약은 나초를 깨워야 돌아온다")
        let manual = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON(recurrence: "manual"))).get()
        XCTAssertFalse(HubScheduleRules.canPause(manual))
    }

    func testRunNowConfirmStepSaysCreditsAndBalance() throws {
        let s = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON())).get()
        let step = HubScheduleRules.runNowStep(s, remaining: 120)
        XCTAssertTrue(step.message.contains("크레딧을 씁니다"), step.message)
        XCTAssertTrue(step.message.contains("약 5~10 크레딧"), step.message)
        XCTAssertTrue(step.message.contains("지금 남은 크레딧 120"), step.message)
        XCTAssertFalse(step.destructive, "되돌릴 수 없는 삭제가 아니라 비용 확인이다")
        XCTAssertTrue(HubScheduleRules.runNowStep(s, remaining: nil).message.contains("남은 크레딧을 확인하지 못했어요"))
    }

    func testRunNowFlagOff() {
        XCTAssertEqual(HubScheduleRules.runNowAvailable(flag: false), false)
        XCTAssertEqual(HubScheduleRules.runNowAvailable(flag: true), true)
        XCTAssertEqual(HubScheduleRules.runNowAvailable(flag: HubFeatureFlags.scheduleRunNow), HubFeatureFlags.scheduleRunNow)
    }

    func testDeleteIsTwoSteps() throws {
        let s = try HubSchedulesAPI.decodeSchedule(resp(200, scheduleJSON())).get()
        let steps = HubScheduleRules.deleteSteps(s)
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps.allSatisfy { $0.destructive })
        XCTAssertTrue(steps[0].message.contains("지난 실행 기록도 함께 지워져요."))
        XCTAssertTrue(steps[1].message.contains("메일 확인"))
    }

    func testStatusAndSkippedTexts() {
        XCTAssertEqual(HubScheduleText.runStatus("done"), "끝났어요")
        XCTAssertEqual(HubScheduleText.runStatus("stopped_at_cap"), "상한에서 멈췄어요")
        XCTAssertEqual(HubScheduleText.runStatus("weird"), "weird")
        XCTAssertEqual(HubScheduleText.skipped("credits_exhausted"), "사용량을 다 썼어요")
        XCTAssertEqual(HubScheduleText.skipped("concurrency_full"), "다른 작업이 끝나지 않았어요")
        XCTAssertEqual(HubScheduleText.credentialNotice("delegated"), "며칠에 한 번은 앱을 열어 주세요. 기간이 지나면 건너뛰어요.")
        XCTAssertNil(HubScheduleText.credentialNotice(nil))
    }
}

private extension Result {
    var failureValue: Failure? { if case let .failure(e) = self { return e }; return nil }
}
