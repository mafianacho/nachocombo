import XCTest
@testable import NachoComboCore

/// 작업 섹션 Core (NACHO-271 U5: C2·B16·C4). 요청은 바이트 단위로, 응답·오류는 한국어 문구까지 확인한다. 가짜 응답만 쓴다.
final class HubTasksTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private let tid = "11111111-1111-1111-1111-111111111111"

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String, headers: [String: String] = [:]) -> PetHTTPResponse {
        PetHTTPResponse(status: status, headers: headers, body: Data(json.utf8))
    }

    // MARK: request bytes

    func testListAndHistoryRequests() {
        let l = HubTasks.list(e, bearer: "T")
        XCTAssertEqual(l.method, "GET")
        XCTAssertEqual(l.url.absoluteString, "https://nacho.example.com/api/v1/tasks")
        XCTAssertEqual(l.headers["Authorization"], "Bearer T")
        XCTAssertEqual(HubTasks.list(e, bearer: "T", agentID: "A1").url.absoluteString, "https://nacho.example.com/api/v1/tasks?agent_id=A1")
        let h = HubTasks.history(e, bearer: "T", next: [("before", "2026-11-01T00:00:00Z~abc")], limit: 20)
        XCTAssertEqual(h.url.absoluteString, "https://nacho.example.com/api/v1/tasks/history?before=2026-11-01T00%3A00%3A00Z~abc&limit=20")
    }

    func testGetAndLogsRequests() {
        XCTAssertEqual(HubTasks.get(e, bearer: "T", taskID: tid).url.path, "/api/v1/tasks/\(tid)")
        let g = HubTasks.logs(e, bearer: "T", taskID: tid)
        XCTAssertEqual(g.method, "GET")
        XCTAssertEqual(g.url.path, "/api/v1/tasks/\(tid)/logs")
    }

    func testPathIDIsEscaped() {
        XCTAssertEqual(HubTasks.get(e, bearer: "T", taskID: "a/b c").url.absoluteString, "https://nacho.example.com/api/v1/tasks/a%2Fb%20c")
    }

    func testContinueBody() {
        let r = HubTasks.continueTask(e, bearer: "T", taskID: tid, choice: .resumeAfterReset, expectedEstimateID: "E1")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/tasks/\(tid)/continue")
        XCTAssertEqual(body(r), "{\"choice\":\"resume_after_reset\",\"expected_estimate_id\":\"E1\"}")
        XCTAssertEqual(body(HubTasks.continueTask(e, bearer: "T", taskID: tid, choice: .stop, expectedEstimateID: nil)), "{\"choice\":\"stop\"}")
        XCTAssertEqual(HubContinueChoice.allCases.map { $0.rawValue }, ["summarize", "more", "stop", "resume_after_reset"])
    }

    func testRoutineDraftHasNoBodyAndNoIdempotencyKey() {
        let r = HubTasks.routineDraft(e, bearer: "T", taskID: tid)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/tasks/\(tid)/routine-draft")
        XCTAssertNil(r.headers["Idempotency-Key"], "다시 누르면 초안이 또 생기니 키를 두지 않는다(앱과 같다)")
    }

    func testInstructionAndNoteCarryIdempotencyKey() {
        let i = HubTasks.instruction(e, bearer: "T", taskID: tid, text: "더 싸게", idempotencyKey: "K1")
        XCTAssertEqual(i.url.path, "/api/v1/tasks/\(tid)/instruction")
        XCTAssertEqual(i.headers["Idempotency-Key"], "K1")
        XCTAssertEqual(body(i), "{\"text\":\"더 싸게\"}")
        let n = HubTasks.callNote(e, bearer: "T", taskID: tid, text: "5시로", idempotencyKey: "K2")
        XCTAssertEqual(n.url.path, "/api/v1/tasks/\(tid)/call/note")
        XCTAssertEqual(n.headers["Idempotency-Key"], "K2")
        XCTAssertEqual(body(n), "{\"text\":\"5시로\"}")
    }

    func testHangupAndCallGetRequests() {
        let h = HubTasks.callHangup(e, bearer: "T", taskID: tid)
        XCTAssertEqual(h.method, "POST")
        XCTAssertEqual(h.url.path, "/api/v1/tasks/\(tid)/call/hangup")
        XCTAssertEqual(HubTasks.call(e, bearer: "T", callID: "C1").url.path, "/api/v1/calls/C1")
    }

    func testLiveViewRequests() {
        let a = HubTasks.liveViewSession(e, bearer: "T", attemptID: "AT", requestID: nil)
        XCTAssertEqual(a.method, "POST")
        XCTAssertEqual(a.url.path, "/api/v1/live-view/sessions")
        XCTAssertEqual(body(a), "{\"attempt_id\":\"AT\"}")
        XCTAssertEqual(body(HubTasks.liveViewSession(e, bearer: "T", attemptID: nil, requestID: "RQ")), "{\"request_id\":\"RQ\"}")
        let v = HubTasks.viewerTicket(e, bearer: "T", attemptID: "AT")
        XCTAssertEqual(v.method, "POST")
        XCTAssertEqual(v.url.path, "/api/v1/connections/attempts/AT/viewer-ticket")
    }

    // MARK: decoding

    private let taskJSON = """
    {"id":"t1","agent_id":"a1","kind":"phone","state":"waiting","wait_reason":"over_cap","title":"식당 예약","request_text":"저녁 7시",
     "version":4,"estimate_id":"E9","steps":[{"text":"전화 걸기"},{"text":"확인"}],"current_step":{"text":"전화 걸기","index":1,"total":2},
     "plan_blocks":[{"kind":"text","text":"1. 전화"},{"kind":"list","items":["a","b"]}],"result_blocks":[],
     "credit":{"used":12,"cap":30,"refund_status":"none"},"requested_at":"2026-11-15T01:00:00Z",
     "call":{"call_id":"c1","call_state":"in_call","counterpart_label":"맛집","phone_name":"내 번호","attempts":1,"max_attempts":3}}
    """

    func testDecodeListSplitsActiveAndRecent() throws {
        let body = "{\"active_items\":[\(taskJSON)],\"recent_items\":[{\"id\":\"t2\",\"state\":\"done\",\"title\":\"끝\"}],\"concurrency\":{\"limit\":3,\"running\":1,\"queued\":0}}"
        let list = try HubTasks.decodeList(resp(200, body)).get()
        XCTAssertEqual(list.active.map { $0.id }, ["t1"])
        XCTAssertEqual(list.recent.map { $0.id }, ["t2"])
        XCTAssertEqual(list.limit, 3)
        XCTAssertEqual(list.running, 1)
        XCTAssertTrue(try HubTasks.decodeList(resp(200, "{\"active_items\":[],\"recent_items\":[]}")).get().isEmpty)
    }

    func testDecodeTaskFields() throws {
        let t = try HubTasks.decodeTask(resp(200, taskJSON)).get()
        XCTAssertEqual(t.title, "식당 예약")
        XCTAssertEqual(t.state, "waiting")
        XCTAssertEqual(t.statusText, "정한 양을 넘어 멈췄어요")
        XCTAssertEqual(t.version, 4)
        XCTAssertEqual(t.steps, ["전화 걸기", "확인"])
        XCTAssertEqual(t.stepLine, "1/2단계 · 전화 걸기")
        XCTAssertEqual(t.planLines, ["1. 전화", "a", "b"])
        XCTAssertEqual(t.estimateID, "E9")
        XCTAssertEqual(t.creditUsed, 12)
        XCTAssertEqual(t.callID, "c1")
        XCTAssertEqual(t.counterpart, "맛집")
        XCTAssertEqual(t.choices, [.summarize, .more, .stop, .resumeAfterReset])
        XCTAssertTrue(t.canInstruct)
        XCTAssertFalse(t.canRoutine)
        XCTAssertTrue(t.isLiveCall)
    }

    func testStateRulesForActions() throws {
        func task(_ state: String, _ extra: String = "") -> HubTask {
            HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data("{\"id\":\"x\",\"title\":\"t\",\"state\":\"\(state)\"\(extra)}".utf8)) as! [String: Any]))
        }
        XCTAssertTrue(task("done").canRoutine)
        XCTAssertTrue(task("failed").canRoutine)
        XCTAssertTrue(task("canceled").canRoutine)
        XCTAssertFalse(task("running").canRoutine)
        XCTAssertTrue(task("planned").canInstruct)
        XCTAssertTrue(task("running").canInstruct)
        XCTAssertFalse(task("done").canInstruct, "끝난 작업은 서버가 409")
        XCTAssertTrue(task("waiting", ",\"wait_reason\":\"browser\",\"pending_request_id\":\"R1\"").canOpenLiveView)
        XCTAssertFalse(task("waiting", ",\"wait_reason\":\"approval\",\"pending_request_id\":\"R1\"").canOpenLiveView)
        XCTAssertFalse(task("waiting", ",\"wait_reason\":\"browser\"").canOpenLiveView)
        XCTAssertTrue(task("planned").canStart)
        XCTAssertFalse(task("running").canStart)
        XCTAssertTrue(task("running").canCancel)
        XCTAssertFalse(task("failed").canCancel)
        XCTAssertEqual(task("queued", ",\"wait_reason\":\"resume_confirm\"").choices, [.resumeAfterReset])
        XCTAssertEqual(task("running").choices, [])
        XCTAssertEqual(task("failed").statusText, "못 끝냈어요")
    }

    func testFailureTextsAreKorean() throws {
        let t = try HubTasks.decodeTask(resp(200, "{\"id\":\"x\",\"title\":\"t\",\"state\":\"failed\",\"failure\":{\"code\":\"no_answer\",\"message\":\"m\",\"retryable\":true,\"next_actions\":[\"call_later\",\"call_myself\"],\"completed_actions\":[\"메모 저장\"],\"pending_actions\":[],\"uncertain_actions\":[\"예약\"]}}")).get()
        XCTAssertEqual(t.failureTitle, "전화를 받지 않았어요")
        XCTAssertEqual(t.failureWhy, "상대가 전화를 받지 않았어요.")
        XCTAssertEqual(t.nextActionTexts, ["나중에 다시 걸기", "내가 직접 걸기"])
        XCTAssertEqual(t.completedActions, ["메모 저장"])
        XCTAssertEqual(t.uncertainActions, ["예약"])
    }

    func testDecodeLogs() throws {
        let logs = try HubTasks.decodeLogs(resp(200, "[{\"id\":1,\"kind\":\"started\",\"text\":\"시작\",\"created_at\":\"2026-11-15T01:00:00Z\"},{\"id\":2,\"kind\":\"step\",\"text\":\"전화\"}]")).get()
        XCTAssertEqual(logs.map { $0.text }, ["시작", "전화"])
        XCTAssertEqual(logs.map { $0.id }, [1, 2])
        XCTAssertTrue(try HubTasks.decodeLogs(resp(200, "[]")).get().isEmpty)
        XCTAssertEqual(HubTasks.decodeLogs(resp(200, "{}")).failure, .badResponse)
    }

    func testDecodeCallDetail() throws {
        let json = """
        {"call":{"id":"c1","task_id":"t1","state":"in_call","phone_masked":"010-****-1234","counterpart_label":"맛집","purpose":"예약","attempts":1,"max_attempts":3,"stage":"inquiring","credits_used":2},
         "lines":[{"id":1,"seq":1,"speaker":"agent","text":"안녕하세요"},{"id":2,"seq":2,"speaker":"counterpart","text":"네"},{"id":3,"seq":3,"speaker":"user_note","text":"5시"},{"id":4,"seq":4,"speaker":"agent","text":"전해요","relayed":true}],
         "footer":{"credits_used":2,"disclosure":"AI가 걸었어요","result":{"headline":"예약됨","items":[{"kind":"agreed","text":"7시"}]}}}
        """
        let c = try HubTasks.decodeCall(resp(200, json)).get()
        XCTAssertEqual(c.taskID, "t1")
        XCTAssertTrue(c.isLive)
        XCTAssertEqual(c.stateText, "통화 중")
        XCTAssertEqual(c.lines.map { $0.speakerText }, ["나초", "상대", "내 메모", "나초"])
        XCTAssertEqual(c.lines.map { $0.text }, ["안녕하세요", "네", "5시", "전해요"])
        XCTAssertTrue(c.lines[3].relayed)
        XCTAssertEqual(c.headline, "예약됨")
        XCTAssertEqual(c.resultItems, ["합의: 7시"])
        XCTAssertEqual(c.disclosure, "AI가 걸었어요")
        XCTAssertEqual(c.attemptLine, "1번째 시도 (최대 3번)")
        let ended = try HubTasks.decodeCall(resp(200, "{\"call\":{\"id\":\"c1\",\"task_id\":\"t1\",\"state\":\"ended\",\"outcome\":\"no_answer\"},\"lines\":[],\"footer\":{\"credits_used\":0,\"disclosure\":\"\"}}")).get()
        XCTAssertFalse(ended.isLive)
        XCTAssertEqual(ended.outcomeText, "전화를 받지 않았어요")
    }

    func testDecodeViewerTicket() throws {
        let t = try HubTasks.decodeTicket(resp(201, "{\"attempt_id\":\"AT\",\"ticket\":\"vt_secret\",\"ws_url\":\"wss://x/ws\",\"viewer_url\":\"https://nacho.example.com/api/v1/remote/viewer#t=vt_secret\",\"expires_at\":\"2026-11-15T01:03:00Z\",\"verified_host\":\"bank.example.com\"}")).get()
        XCTAssertEqual(t.viewerURL, "https://nacho.example.com/api/v1/remote/viewer#t=vt_secret")
        XCTAssertEqual(t.verifiedHost, "bank.example.com")
        XCTAssertFalse("\(t)".contains("vt_secret"), "티켓은 로그·출력에 나오지 않는다")
    }

    // MARK: errors → Korean

    func testErrorCases() {
        XCTAssertEqual(HubTasks.decodeList(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failure?.text, "로그인이 필요해요.")
        XCTAssertEqual(HubTasks.decodeTask(resp(404, "{}")).failure?.text, "찾지 못했어요.")
        XCTAssertEqual(HubTasks.decodeTask(resp(500, "oops")).failure?.text, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        XCTAssertEqual(HubTasks.decodeCall(resp(404, "{}")).failure?.isNotFound, true)
        XCTAssertEqual(HubTasks.decodeTask(resp(200, "[]")).failure, .badResponse)
        XCTAssertEqual(HubTasks.decodeList(resp(200, "[]")).failure, .badResponse)
    }

    func testEstimateChangedConflictCarriesNewTask() {
        let r = resp(409, "{\"error\":{\"code\":\"estimate_changed\",\"message\":\"m\"},\"task\":{\"id\":\"t1\",\"title\":\"새\",\"state\":\"planned\",\"estimate_id\":\"E2\"}}")
        XCTAssertEqual(HubTasks.estimateChangedTask(r)?.estimateID, "E2")
        XCTAssertNil(HubTasks.estimateChangedTask(resp(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"m\"}}")))
        XCTAssertEqual(HubTasks.continueFailureText(r), "계획이 바뀌었어요. 확인하고 다시 눌러 주세요.")
        XCTAssertEqual(HubTasks.continueFailureText(resp(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"m\"}}")), HubAPI.error(resp(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"m\"}}")).text)
    }

    func testViewerTicketRetryLater() {
        let r = resp(429, "{\"error\":{\"code\":\"rate_limited\",\"message\":\"m\"}}", headers: ["retry-after": "12"])
        XCTAssertEqual(HubTasks.retryAfterSeconds(r), 12)
        XCTAssertNil(HubTasks.retryAfterSeconds(resp(200, "{}")))
    }

    // MARK: input validation

    func testTextValidation() {
        XCTAssertEqual(HubTasks.validateText(""), "내용을 적어 주세요.")
        XCTAssertEqual(HubTasks.validateText("  \n "), "내용을 적어 주세요.")
        XCTAssertNil(HubTasks.validateText("더 싸게 해 줘"))
        XCTAssertNil(HubTasks.validateText(String(repeating: "가", count: HubTasks.textMax)))
        XCTAssertEqual(HubTasks.validateText(String(repeating: "가", count: HubTasks.textMax + 1)), "\(HubTasks.textMax)자까지 쓸 수 있어요.")
    }

    func testCallNoteRefusesSecrets() {
        XCTAssertEqual(HubTasks.validateCallNote("비밀번호는 1234"), "비밀번호, 카드 번호, 인증번호는 메모로 보낼 수 없어요")
        XCTAssertEqual(HubTasks.validateCallNote("카드 4111 1111 1111 1111"), "비밀번호, 카드 번호, 인증번호는 메모로 보낼 수 없어요")
        XCTAssertEqual(HubTasks.validateCallNote("인증번호 123456"), "비밀번호, 카드 번호, 인증번호는 메모로 보낼 수 없어요")
        XCTAssertNil(HubTasks.validateCallNote("5시로 바꿔 주세요"))
        XCTAssertEqual(HubTasks.validateCallNote(""), "내용을 적어 주세요.")
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e }; return nil }
}
