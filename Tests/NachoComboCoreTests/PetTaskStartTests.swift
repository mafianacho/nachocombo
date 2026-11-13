import Foundation
import XCTest

@testable import NachoComboCore

// A big task is held by the server (plan_mode full, estimate above credit_policy.inline_plan_max_estimate): it stays
// `planned` and posts a plan note "… · 약 N~M크레딧 · 확인 후 시작해 주세요" until POST /tasks/{id}/start.
// nacho-server origin/main: crates/application/src/services/tasks/create.rs (PlanMode::Full), spec/tasks.tsp
// (StartTask.expected_estimate_id, EstimateChanged 409, cancel). Reference client: nacho-app src/api/nacho-api.ts startTask.

private let roomID = "0193aaaa-0000-7000-8000-0000000000r7"
private let taskID = "0193aaaa-0000-7000-8000-00000000t001"

private func frame(_ json: String) -> ServerFrame { ServerFrame.decode(json)! }

private func taskJSON(state: String, estimateID: String = "e1", min: Int = 40, max: Int = 60, version: Int = 1,
                      title: String = "휴대폰 전화해줘") -> String {
    #"{"id":"\#(taskID)","room_id":"\#(roomID)","kind":"task","state":"\#(state)","title":"\#(title)","request_text":"x","plan_mode":"full","steps":[],"stalled":false,"credit":{"estimate":{"estimate_min":\#(min),"estimate_max":\#(max),"task_label":"전화"},"estimate_id":"\#(estimateID)","used":0,"cap":\#(max),"refund_status":"none"},"accessed_items":[],"plan_blocks":[],"result_blocks":[],"estimate_id":"\#(estimateID)","version":\#(version)}"#
}

private func planNoteJSON(seq: Int, min: Int = 40, max: Int = 60) -> String {
    let text = "휴대폰 전화해줘 · 약 \(min)~\(max)크레딧 · 확인 후 시작해 주세요"
    return #"{"id":"n\#(seq)","room_id":"\#(roomID)","seq":\#(seq),"role":"system","sender_kind":"system","text":"\#(text)","content":{"type":"system_note","kind":"plan","text":"\#(text)"},"task_id":"\#(taskID)","used_memory_ids":[],"attachments":[]}"#
}

private func planCardItem(_ items: [PetChatItem]) -> PetCardItem? {
    for i in items { if case let .card(c) = i, c.id == "plan-\(taskID)" { return c } }
    return nil
}

final class PetTaskStartModelTests: XCTestCase {
    func testPlannedTaskDecodesItsEstimateAndAsksForConfirmation() {
        guard case let .task(t) = frame(#"{"type":"task_update","room_id":"\#(roomID)","task":\#(taskJSON(state: "planned"))}"#).event else {
            return XCTFail("task_update")
        }
        XCTAssertEqual(t.estimateID, "e1")
        XCTAssertEqual(t.estimateText, "약 40~60크레딧")
        XCTAssertEqual(t.version, 1)
        XCTAssertTrue(t.needsStartConfirm)
        XCTAssertEqual(t.statusText, "시작 확인 필요", "planned no longer reads 곧 시작해요")
        XCTAssertEqual(PetTask(id: "q", state: "queued", title: "x").statusText, "곧 시작해요")
        // The top-level estimate_id is what the server compares; credit.estimate_id is the fallback.
        let onlyCredit = PetTask.decode(Data(#"{"id":"a","state":"planned","title":"t","credit":{"estimate_id":"c9","used":0,"refund_status":"none"}}"#.utf8))
        XCTAssertEqual(onlyCredit?.estimateID, "c9")
        XCTAssertNil(onlyCredit?.estimateText)
    }

    func testRequestsFollowTheContract() {
        let e = ServerEndpoint(base: URL(string: "https://api.example")!)
        let start = PetServerAPI.startTaskRequest(e, bearer: "tk", taskID: taskID, expectedEstimateID: "e1")
        XCTAssertEqual(start.method, "POST")
        XCTAssertEqual(start.url.path, "/api/v1/tasks/\(taskID)/start")
        XCTAssertEqual(start.headers["Authorization"], "Bearer tk")
        XCTAssertEqual(PetStubHTTP.json(start)["expected_estimate_id"] as? String, "e1")
        XCTAssertTrue(PetStubHTTP.json(PetServerAPI.startTaskRequest(e, bearer: "tk", taskID: taskID, expectedEstimateID: nil)).isEmpty)
        let cancel = PetServerAPI.cancelTaskRequest(e, bearer: "tk", taskID: taskID)
        XCTAssertEqual(cancel.method, "POST")
        XCTAssertEqual(cancel.url.path, "/api/v1/tasks/\(taskID)/cancel")
        XCTAssertEqual(PetServerAPI.taskRequest(e, bearer: "tk", taskID: taskID).url.path, "/api/v1/tasks/\(taskID)")
    }

    func testPlanNoteBecomesACardUnderTheTurnWithStartAndCancel() {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.apply(frame(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"\#(roomID)"}"#))
        st.chat.beginTurn(text: "휴대폰 전화해줘", clientMsgID: "c1")
        st.chat.apply(frame(#"{"type":"turn_started","room_id":"\#(roomID)","client_id":"c1","turn_id":"t","task_id":"\#(taskID)","duplicate":false}"#))
        st.chat.apply(frame(#"{"type":"task_update","room_id":"\#(roomID)","task":\#(taskJSON(state: "planned"))}"#))
        st.chat.apply(frame(#"{"type":"message","room_id":"\#(roomID)","message":\#(planNoteJSON(seq: 5))}"#))
        st.chat.apply(frame(#"{"type":"done","room_id":"\#(roomID)","client_id":"c1","message_id":null,"task_id":"\#(taskID)","stopped":false}"#))

        let header = PetTranscript.headerStatus(st)
        XCTAssertEqual(header.text, "휴대폰 전화해줘 · 시작 확인 필요")
        XCTAssertEqual(header.dot, .wait)

        let items = PetTranscript.items(st, undoSecondsLeft: { _ in nil })
        XCTAssertFalse(items.contains { if case let .note(n) = $0 { return n.contains("확인 후 시작") }; return false },
                       "the plan note is not a grey line any more")
        guard let card = planCardItem(items) else { return XCTFail("plan card: \(items)") }
        XCTAssertEqual(card.title, "휴대폰 전화해줘")
        XCTAssertEqual(card.detail, "약 40~60크레딧")
        XCTAssertEqual(card.options.map { $0.label }, ["시작", "취소"])
        XCTAssertEqual(card.options[0].link, PetLinks.url("task", ["id": taskID, "action": "start"]))
        XCTAssertEqual(card.options[1].link, PetLinks.url("task", ["id": taskID, "action": "cancel"]))
        XCTAssertTrue(card.statusWaits)
        XCTAssertEqual(card.options.map { $0.role }, [.primary, .quiet])
        XCTAssertNil(PetTranscript.activeCardID(items), "number keys never go to a plan card")
        // The card sits under the turn that asked (after its answer), not above it in the record.
        let mine = items.firstIndex { if case .mine = $0 { return true }; return false }!
        let cardAt = items.firstIndex { if case let .card(c) = $0 { return c.id == card.id }; return false }!
        XCTAssertGreaterThan(cardAt, mine)
        XCTAssertTrue(items.contains { if case let .nacho(text, _, _) = $0 { return text.contains("확인해 주시면 시작할게요") }; return false })

        // Pressed: both buttons off, the pressed one says so.
        st.chat.taskActions[taskID] = "start"
        let pressed = planCardItem(PetTranscript.items(st, undoSecondsLeft: { _ in nil }))!
        XCTAssertEqual(pressed.options.map { $0.label }, ["시작하는 중…", "취소"])
        XCTAssertTrue(pressed.options.allSatisfy { $0.link == nil })
    }

    func testAnOlderTaskVersionNeverOverwritesANewerOne() {
        var s = ChatState()
        s.applyTask(PetTask.decode(Data(taskJSON(state: "running", version: 3).utf8))!, current: true)
        s.applyTask(PetTask.decode(Data(taskJSON(state: "planned", version: 1).utf8))!, current: true)
        XCTAssertEqual(s.tasks[taskID]?.state, "running")
        XCTAssertEqual(s.task?.state, "running")
    }
}

final class PetTaskStartSessionTests: XCTestCase {
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    var http: PetStubHTTP!
    var factory: PetTransportFactory!
    var browser: PetFakeBrowser!
    var history = "[]"

    override func setUp() {
        http = PetStubHTTP()
        factory = PetTransportFactory()
        browser = PetFakeBrowser()
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        http.on("GET", "/client/config", 200, #"{"service_status":{"state":"ok"},"dictation":{"enabled":false}}"#)
        http.on("GET", "/api/v1/me/usage", 200, #"{"plan_id":"free","allowance":100,"remaining":70,"limits":[]}"#)
    }

    private func settle(_ s: PetSession) { for _ in 0..<8 { s.flush(); Thread.sleep(forTimeInterval: 0.01) } }

    /// Signed in, connected, and a turn the server turned into a planned task.
    private func plannedSession() -> (PetSession, PetFakeTransport) {
        http.on("GET", "/api/v1/rooms/\(roomID)/history", 200, history)
        var settings = PetSettings()
        settings.serverMode = .mock
        settings.allowComboControl = false
        let s = PetSession(settings: settings, http: http, secrets: MemorySecretStore(), browser: browser, makeTransport: factory.make,
                           executor: nil, random: PetFixedRandom())
        s.signIn(); settle(s)
        let chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"\#(roomID)"}"#)
        settle(s)
        s.send(text: "휴대폰 전화해줘"); settle(s)
        let id = s.snapshot.chat.turns[0].clientMsgID
        chat.deliver(#"{"type":"turn_started","room_id":"\#(roomID)","client_id":"\#(id)","turn_id":"t","task_id":"\#(taskID)","duplicate":false}"#)
        chat.deliver(#"{"type":"task_update","room_id":"\#(roomID)","task":\#(taskJSON(state: "planned"))}"#)
        chat.deliver(#"{"type":"message","room_id":"\#(roomID)","message":\#(planNoteJSON(seq: 5))}"#)
        chat.deliver(#"{"type":"done","room_id":"\#(roomID)","client_id":"\#(id)","message_id":null,"task_id":"\#(taskID)","stopped":false}"#)
        settle(s)
        return (s, chat)
    }

    private func card(_ s: PetSession) -> PetCardItem? { planCardItem(PetTranscript.items(s.snapshot, undoSecondsLeft: { _ in nil })) }

    func testStartSendsTheEstimateTheUserSawAndTheTaskRuns() {
        http.on("POST", "/api/v1/tasks/\(taskID)/start", 200, taskJSON(state: "running", version: 2))
        let (s, _) = plannedSession()
        XCTAssertEqual(card(s)?.options.map { $0.label }, ["시작", "취소"])
        var reply: String??
        s.startTask(id: taskID) { reply = $0 }
        settle(s)
        XCTAssertEqual(reply, .some(nil))
        let sent = http.sent("POST", "/api/v1/tasks/\(taskID)/start")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(PetStubHTTP.json(sent[0])["expected_estimate_id"] as? String, "e1")
        XCTAssertEqual(sent[0].headers["Authorization"], "Bearer at-1")
        XCTAssertEqual(s.snapshot.chat.task?.state, "running")
        XCTAssertEqual(PetTranscript.headerStatus(s.snapshot).text, "휴대폰 전화해줘 · 하고 있어요")
        XCTAssertEqual(card(s)?.options, [], "no buttons once it runs")
        XCTAssertEqual(card(s)?.status, "하고 있어요")
        XCTAssertTrue(s.snapshot.chat.taskActions.isEmpty)
    }

    func testASecondPressWhileTheFirstIsOutSendsNothing() {
        http.on("POST", "/api/v1/tasks/\(taskID)/start", 200, taskJSON(state: "running", version: 2))
        let (s, _) = plannedSession()
        var second: String??
        s.startTask(id: taskID)
        s.startTask(id: taskID) { second = $0 }
        s.cancelTask(id: taskID)
        settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/tasks/\(taskID)/start").count, 1)
        XCTAssertTrue(http.sent("POST", "/api/v1/tasks/\(taskID)/cancel").isEmpty)
        XCTAssertEqual(second, .some("처리하고 있어요. 잠시만요."))
        // Answered: a new press goes out again (start is idempotent on the server: not planned → current task).
        s.startTask(id: taskID); settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/tasks/\(taskID)/start").count, 2)
    }

    func testChangedEstimateShowsTheNewOneAndTheNextPressSendsIt() {
        http.on("POST", "/api/v1/tasks/\(taskID)/start", 409,
                #"{"error":{"code":"estimate_changed","message":"x"},"task":\#(taskJSON(state: "planned", estimateID: "e2", min: 70, max: 90, version: 2))}"#)
        let (s, _) = plannedSession()
        var reply: String??
        s.startTask(id: taskID) { reply = $0 }
        settle(s)
        XCTAssertEqual(reply, .some("예상 사용량이 바뀌었어요 (약 70~90크레딧). 확인하고 다시 눌러 주세요."))
        XCTAssertEqual(s.snapshot.chat.tasks[taskID]?.estimateID, "e2")
        let c = card(s)!
        XCTAssertEqual(c.detail, "약 70~90크레딧")
        XCTAssertEqual(c.status, "예상 사용량이 바뀌었어요 (약 70~90크레딧). 확인하고 다시 눌러 주세요.")
        XCTAssertEqual(c.options.map { $0.label }, ["시작", "취소"])
        XCTAssertTrue(c.options.allSatisfy { $0.link != nil }, "buttons on again")

        http.on("POST", "/api/v1/tasks/\(taskID)/start", 200, taskJSON(state: "queued", estimateID: "e2", version: 3))
        s.startTask(id: taskID); settle(s)
        XCTAssertEqual(PetStubHTTP.json(http.sent("POST", "/api/v1/tasks/\(taskID)/start")[1])["expected_estimate_id"] as? String, "e2")
        XCTAssertEqual(card(s)?.status, "곧 시작해요")
        XCTAssertNil(s.snapshot.chat.taskNotices[taskID])
    }

    func testRefusedStartIsOneLineAndTheButtonsStay() {
        http.on("POST", "/api/v1/tasks/\(taskID)/start", 402, #"{"error":{"code":"task_not_startable","message":"x","reason":"credits_exhausted"}}"#)
        let (s, _) = plannedSession()
        var reply: String??
        s.startTask(id: taskID) { reply = $0 }
        settle(s)
        let line = "지금은 일을 맡길 수 없어요. 크레딧이 모자라요."
        XCTAssertEqual(reply, .some(line))
        XCTAssertEqual(card(s)?.status, line)
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(card(s)?.options.compactMap { $0.link }.count, 2)
        XCTAssertEqual(s.snapshot.chat.task?.state, "planned")
        XCTAssertEqual(PetTranscript.headerStatus(s.snapshot).text, "휴대폰 전화해줘 · 시작 확인 필요")

        // A task that is gone: about the task, not an attachment.
        http.on("POST", "/api/v1/tasks/\(taskID)/start", 404, #"{"error":{"code":"not_found","message":"x"}}"#)
        s.startTask(id: taskID) { reply = $0 }
        settle(s)
        XCTAssertEqual(reply, .some("이 작업을 찾지 못했어요."))
    }

    func testCancelEndsTheTask() {
        http.on("POST", "/api/v1/tasks/\(taskID)/cancel", 200,
                taskJSON(state: "canceled", version: 2).replacingOccurrences(of: #""version":2"#, with: #""version":2,"failure":{"code":"user_canceled"}"#))
        let (s, _) = plannedSession()
        s.cancelTask(id: taskID); settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/tasks/\(taskID)/cancel").count, 1)
        XCTAssertTrue(http.sent("POST", "/api/v1/tasks/\(taskID)/start").isEmpty)
        XCTAssertEqual(s.snapshot.chat.task?.state, "canceled")
        XCTAssertEqual(card(s)?.options, [])
        XCTAssertEqual(card(s)?.status, "취소했어요")
    }

    func testAPlanNoteFromTheRecordIsLookedUpOnceBeforeItGetsButtons() {
        history = "[\(planNoteJSON(seq: 2))]"
        http.on("GET", "/api/v1/tasks/\(taskID)", 200, taskJSON(state: "planned"))
        http.on("GET", "/api/v1/rooms/\(roomID)/history", 200, history)
        var settings = PetSettings()
        settings.serverMode = .mock
        settings.allowComboControl = false
        let s = PetSession(settings: settings, http: http, secrets: MemorySecretStore(), browser: browser, makeTransport: factory.make,
                           executor: nil, random: PetFixedRandom())
        s.signIn(); settle(s)
        let chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"\#(roomID)"}"#)
        settle(s)
        XCTAssertEqual(http.sent("GET", "/api/v1/tasks/\(taskID)").count, 1)
        let c = card(s)!
        XCTAssertEqual(c.options.map { $0.label }, ["시작", "취소"])
        XCTAssertEqual(c.detail, "약 40~60크레딧")
        chat.deliver(#"{"type":"usage","room_id":"\#(roomID)","remaining":69}"#)
        settle(s)
        XCTAssertEqual(http.sent("GET", "/api/v1/tasks/\(taskID)").count, 1, "looked up once")
    }

    func testAPlanNoteWhoseTaskIsUnknownHasNoButtons() {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.apply(frame(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"\#(roomID)"}"#))
        st.chat.mergeHistory([ChatMessage.decode((try! JSONSerialization.jsonObject(with: Data(planNoteJSON(seq: 2).utf8))) as! [String: Any])],
                             hasMore: false, older: false)
        let c = planCardItem(PetTranscript.items(st, undoSecondsLeft: { _ in nil }))!
        XCTAssertEqual(c.title, "휴대폰 전화해줘")
        XCTAssertEqual(c.detail, "약 40~60크레딧")
        XCTAssertEqual(c.options, [], "no start before the task's state is known")
    }
}
