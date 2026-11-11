import Foundation
import XCTest

@testable import NachoComboCore

// Nacho Pet ↔ nacho-server LLM features: frames, reducer, REST requests and the session wiring.
// Shapes follow nacho-server origin/main spec/*.tsp and docs/ws-protocol.md (see docs/pet-server-gap.md).

private let room = "0193aaaa-0000-7000-8000-0000000000r1"

private func frame(_ json: String) -> ServerFrame { ServerFrame.decode(json)! }

private func msg(_ id: String, seq: Int, role: String, text: String, client: String? = nil, extra: String = "") -> String {
    let c = client.map { #","client_msg_id":"\#($0)""# } ?? ""
    return #"{"id":"\#(id)","room_id":"\#(room)","seq":\#(seq),"role":"\#(role)","sender_kind":"\#(role == "user" ? "user" : "agent")","text":"\#(text)","content":{"type":"text","text":"\#(text)"},"used_memory_ids":[],"redactions":[],"attachments":[]\#(c)\#(extra)}"#
}

final class PetServerFrameTests: XCTestCase {
    func testToolCardTaskMemoryUsageNotificationFrames() {
        let started = frame(#"{"type":"tool_call_started","room_id":"r","client_id":"c1","call_id":"k1","name":"search_web","arguments":{"q":"x"}}"#)
        XCTAssertEqual(started.event, .toolStarted(callID: "k1", name: "search_web"))
        XCTAssertEqual(started.clientID, "c1")
        let finished = frame(#"{"type":"tool_call_finished","room_id":"r","client_id":"c1","call_id":"k1","name":"search_web","preview":"…","meta":{"source":"builtin","is_error":true,"duration_ms":120}}"#)
        XCTAssertEqual(finished.event, .toolFinished(callID: "k1", name: "search_web", isError: true, durationMs: 120))

        let card = frame(#"{"type":"card_update","room_id":"r","request":{"id":"cd1","request_id":"cd1","kind":"choice","status":"pending","version":2,"payload":{"question":"어느 쪽?","options":[{"id":"a","label":"강남"},{"id":"b","label":"홍대"}]}}}"#)
        guard case let .card(c) = card.event else { return XCTFail("card") }
        XCTAssertEqual(c.title, "어느 쪽?")
        XCTAssertEqual(c.options.map { $0.label }, ["강남", "홍대"])
        XCTAssertTrue(c.answerableHere)
        XCTAssertEqual(c.version, 2)

        let approval = PetCard.decode(["id": "x", "kind": "approval", "status": "pending", "version": 1,
                                       "payload": ["title": "예약", "amount": 30000, "merchant": "파스타집", "action_type": "payment"]])
        XCTAssertFalse(approval.answerableHere, "approvals stay on the phone app")
        XCTAssertEqual(approval.statusText, "휴대폰의 나초 앱에서 승인해 주세요")
        XCTAssertEqual(approval.detail, "파스타집 · 30,000원")

        let task = frame(#"{"type":"task_update","room_id":"r","task":{"id":"t1","state":"running","title":"파스타집 예약","current_step":{"text":"자리 찾는 중","index":2,"total":4}}}"#)
        guard case let .task(t) = task.event else { return XCTFail("task") }
        XCTAssertEqual(t.statusText, "자리 찾는 중 (2/4)")
        XCTAssertTrue(t.isOpen)
        XCTAssertEqual(PetTask.decode(["id": "t", "state": "waiting", "wait_reason": "approval"]).statusText, "승인을 기다려요")
        XCTAssertEqual(PetTask.decode(["id": "t", "state": "failed", "failure": ["code": "upstream_error"]]).statusText,
                       ErrorText.userMessage(code: "upstream_error", reason: nil, fallback: ""))

        let mem = frame(#"{"type":"memory_update","room_id":"r","update":{"update_id":"u1","action":"created","memory_ids":["m1"],"kind":"fact","preview":"파스타 좋아함","source":"chat","always_show":false,"items":[{"memory_id":"m1","kind":"fact","preview":"파스타 좋아함"}]}}"#)
        guard case let .memory(n) = mem.event else { return XCTFail("memory") }
        XCTAssertEqual(n.items, [PetMemoryNote.Item(memoryID: "m1", kind: "fact", preview: "파스타 좋아함")])
        XCTAssertEqual(n.text, "기억했어요: 파스타 좋아함")
        // Without items[]: memory_ids + kind + preview.
        let old = PetMemoryNote.decode(["update_id": "u2", "action": "created", "memory_ids": ["m2"], "kind": "episode", "preview": "여행"])
        XCTAssertEqual(old.items, [PetMemoryNote.Item(memoryID: "m2", kind: "episode", preview: "여행")])

        let usage = frame(#"{"type":"usage","room_id":"r","remaining":40,"available_to_start":30,"light_chat_used":3,"light_chat_cap":50,"state":{"plan_id":"free","allowance":100,"remaining":40,"period":"day","exhausted":false,"low_balance":true,"limits":[]}}"#)
        guard case let .usage(u) = usage.event else { return XCTFail("usage") }
        XCTAssertEqual(u.summary, "크레딧 40/100 · 가벼운 대화 3/50 · 얼마 안 남았어요")

        let done = frame(#"{"type":"done","room_id":"r","client_id":"c1","message_id":null,"task_id":"t1","stopped":false}"#)
        XCTAssertEqual(done.taskID, "t1")
        XCTAssertEqual(frame(#"{"type":"notification","notification":{"kind":"credit_granted","title":"크레딧","body":"10 받았어요"}}"#).event,
                       .notification(kind: "credit_granted", title: "크레딧", body: "10 받았어요"))
        XCTAssertEqual(frame(#"{"type":"compacted","room_id":"r"}"#).event, .unknown(type: "compacted"))
    }

    func testMessageDecodeKeepsFilesMemoriesCardsAndFlags() {
        let json = #"{"id":"m9","seq":9,"role":"assistant","text":"정리했어요","content":{"type":"text","text":"정리했어요"},"used_memory_ids":["f1","f2"],"interim":false,"task_result":true,"task_id":"t1","attachments":[{"kind":"file","attachment_id":"a1","name":"표.csv","mime":"text/csv","bytes":10,"url":"https://x/s","origin":"agent"},{"kind":"image","deleted":true}],"attachment":{"file_id":"p1","name":"메모","kind":"page","deleted":false}}"#
        let m = ChatMessage.decode(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        XCTAssertEqual(m.usedMemoryIDs, ["f1", "f2"])
        XCTAssertTrue(m.taskResult)
        XCTAssertEqual(m.files.count, 3)
        XCTAssertTrue(m.files[0].byNacho)
        XCTAssertTrue(m.files[1].deleted)
        XCTAssertEqual(m.files[2].kind, "page")
        let tool = ChatMessage.decode(["id": "x", "role": "tool", "content": ["type": "tool_result"]])
        XCTAssertFalse(tool.isVisible)
        let note = ChatMessage.decode(["id": "y", "role": "system", "text": "", "content": ["type": "system_note", "kind": "page_created", "text": "문서를 만들었어요"]])
        XCTAssertEqual(note.text, "문서를 만들었어요")
        XCTAssertTrue(note.isVisible)
    }
}

final class PetServerReducerTests: XCTestCase {
    private func connected() -> ChatState {
        var s = ChatState()
        s.apply(frame(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"\#(room)"}"#))
        return s
    }

    func testChatTurnWithToolsInterimFilesAndMemories() {
        var s = connected()
        s.beginTurn(text: "찾아줘", clientMsgID: "c1")
        s.apply(frame(#"{"type":"turn_started","room_id":"\#(room)","client_id":"c1","turn_id":"t","duplicate":false}"#))
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","client_id":"c1","message":\#(msg("u1", seq: 11, role: "user", text: "찾아줘", client: "c1"))}"#))
        s.apply(frame(#"{"type":"tool_call_started","room_id":"\#(room)","client_id":"c1","call_id":"k1","name":"search_web"}"#))
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","client_id":"c1","message":\#(msg("i1", seq: 12, role: "assistant", text: "찾아보고 있어요", extra: #","interim":true"#))}"#))
        s.apply(frame(#"{"type":"tool_call_finished","room_id":"\#(room)","client_id":"c1","call_id":"k1","name":"search_web","meta":{"is_error":false}}"#))
        s.apply(frame(#"{"type":"text_delta","room_id":"\#(room)","client_id":"c1","text":"찾았"}"#))
        let answer = msg("a1", seq: 13, role: "assistant", text: "찾았어요", extra: #","used_memory_ids":["f1"],"attachments":[{"kind":"file","name":"결과.md","origin":"agent","attachment_id":"x"}]"#)
            .replacingOccurrences(of: #""used_memory_ids":[],"redactions":[],"attachments":[]"#, with: #""redactions":[]"#)
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","client_id":"c1","message":\#(answer)}"#))
        s.apply(frame(#"{"type":"memory_update","room_id":"\#(room)","client_id":"c1","update":{"update_id":"u1","action":"created","items":[{"memory_id":"f9","kind":"fact","preview":"강남 좋아함"}]}}"#))
        // The hub sends the same update again: one line.
        s.apply(frame(#"{"type":"memory_update","room_id":"\#(room)","update":{"update_id":"u1","action":"created","items":[{"memory_id":"f9","kind":"fact","preview":"강남 좋아함"}]}}"#))
        s.apply(frame(#"{"type":"done","room_id":"\#(room)","client_id":"c1","message_id":"a1","stopped":false}"#))

        let t = s.turns[0]
        XCTAssertEqual(t.status, .done)
        XCTAssertEqual(t.userSeq, 11)
        XCTAssertEqual(t.answerSeq, 13)
        XCTAssertEqual(t.assistantText, "찾았어요")
        XCTAssertEqual(t.progress, ["찾아보고 있어요"], "interim = progress line, not an answer")
        XCTAssertEqual(t.tools, [ToolStep(callID: "k1", name: "search_web", finished: true, isError: false)])
        XCTAssertEqual(t.usedMemoryIDs, ["f1"])
        XCTAssertEqual(t.files.map { $0.name }, ["결과.md"])
        XCTAssertEqual(s.memoryNotes.count, 1)
        XCTAssertEqual(s.memoryNotes[0].turnClientID, "c1")
        XCTAssertTrue(s.history.isEmpty, "nothing of this turn lands in the record")
        XCTAssertEqual(s.lastSeq, 13)
    }

    func testTurnHandedToATaskGetsItsAnswerLaterFromTheHub() {
        var s = connected()
        s.beginTurn(text: "예약해줘", clientMsgID: "c2")
        s.apply(frame(#"{"type":"turn_started","room_id":"\#(room)","client_id":"c2","turn_id":"t","task_id":"tk","duplicate":false}"#))
        s.apply(frame(#"{"type":"done","room_id":"\#(room)","client_id":"c2","message_id":null,"task_id":"tk","stopped":false}"#))
        XCTAssertEqual(s.turns[0].taskID, "tk")
        XCTAssertEqual(s.turns[0].status, .done)
        XCTAssertEqual(s.turns[0].assistantText, "")
        // Later, without client_id:
        s.apply(frame(#"{"type":"task_update","room_id":"\#(room)","task":{"id":"tk","state":"running","title":"예약"}}"#))
        XCTAssertEqual(s.task?.statusText, "하고 있어요")
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","message":\#(msg("i2", seq: 21, role: "assistant", text: "자리를 보고 있어요", extra: #","interim":true,"task_id":"tk""#))}"#))
        s.apply(frame(#"{"type":"card_update","room_id":"\#(room)","request":{"id":"cd","kind":"approval","status":"pending","version":1,"task_id":"tk","payload":{"title":"예약할까요?"}}}"#))
        s.apply(frame(#"{"type":"card_update","room_id":"\#(room)","request":{"id":"cd","kind":"approval","status":"answered","answered_action":"approve","version":2,"task_id":"tk","payload":{"title":"예약할까요?"}}}"#))
        s.apply(frame(#"{"type":"card_update","room_id":"\#(room)","request":{"id":"cd","kind":"approval","status":"pending","version":1,"payload":{"title":"old"}}}"#))
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","message":\#(msg("r2", seq: 23, role: "assistant", text: "7시에 예약했어요", extra: #","task_result":true,"task_id":"tk""#))}"#))
        s.apply(frame(#"{"type":"task_update","room_id":"\#(room)","task":{"id":"tk","state":"done","title":"예약"}}"#))
        XCTAssertEqual(s.turns[0].progress, ["자리를 보고 있어요"])
        XCTAssertEqual(s.turns[0].assistantText, "7시에 예약했어요")
        XCTAssertEqual(s.cards.count, 1)
        XCTAssertEqual(s.cards[0].status, "answered", "an older version never overwrites a newer one")
        XCTAssertEqual(s.cards[0].statusText, "승인했어요")
        XCTAssertTrue(s.pendingCards.isEmpty)
        XCTAssertEqual(s.task?.state, "done")
        XCTAssertTrue(s.history.isEmpty)
        // Another device's message goes to the record.
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","message":\#(msg("o1", seq: 30, role: "user", text: "폰에서 보냄", client: "phone-1"))}"#))
        XCTAssertEqual(s.history.map { $0.text }, ["폰에서 보냄"])
    }

    func testHistoryMergeAndRecoveryAfterADroppedConnection() {
        var s = connected()
        let page = [msg("h1", seq: 1, role: "user", text: "어제 말", client: "x"), msg("h2", seq: 2, role: "assistant", text: "어제 답"),
                    #"{"id":"h3","seq":3,"role":"tool","content":{"type":"tool_result"}}"#]
            .map { ChatMessage.decode(try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]) }
        s.mergeHistory(page, hasMore: true, older: false)
        XCTAssertEqual(s.history.map { $0.seq }, [1, 2], "tool messages are not shown")
        XCTAssertTrue(s.hasMoreHistory)
        XCTAssertTrue(s.historyLoaded)
        s.mergeHistory([ChatMessage(id: "h0", seq: 0, role: "user", text: "그제")], hasMore: false, older: true)
        XCTAssertEqual(s.history.map { $0.id }, ["h0", "h1", "h2"])
        XCTAssertFalse(s.hasMoreHistory)
        s.mergeHistory(page, hasMore: false, older: false)  // same page again: no duplicates
        XCTAssertEqual(s.history.count, 3)

        s.beginTurn(text: "오늘 날씨", clientMsgID: "c3")
        s.apply(frame(#"{"type":"turn_started","room_id":"\#(room)","client_id":"c3","turn_id":"t","duplicate":false}"#))
        s.apply(frame(#"{"type":"text_delta","room_id":"\#(room)","client_id":"c3","text":"맑"}"#))
        s.connectionLost()
        XCTAssertEqual(s.turns[0].status, .interrupted)
        let delta = [msg("u3", seq: 4, role: "user", text: "오늘 날씨", client: "c3"),
                     msg("i3", seq: 5, role: "assistant", text: "보는 중", extra: #","interim":true"#),
                     msg("a3", seq: 6, role: "assistant", text: "맑아요"),
                     msg("p1", seq: 7, role: "user", text: "폰에서", client: "phone")]
            .map { ChatMessage.decode(try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]) }
        s.recover(delta)
        XCTAssertEqual(s.turns[0].status, .done)
        XCTAssertEqual(s.turns[0].assistantText, "맑아요")
        XCTAssertEqual(s.turns[0].progress, ["보는 중"])
        XCTAssertEqual(s.history.map { $0.text }, ["그제", "어제 말", "어제 답", "폰에서"])
        XCTAssertEqual(s.lastSeq, 7)
        // The echo of the question came before the drop: the delta holds only the answer.
        s.beginTurn(text: "내일은?", clientMsgID: "c4")
        s.apply(frame(#"{"type":"message","room_id":"\#(room)","client_id":"c4","message":\#(msg("u4", seq: 8, role: "user", text: "내일은?", client: "c4"))}"#))
        s.connectionLost()
        s.recover([ChatMessage.decode(try! JSONSerialization.jsonObject(with: Data(msg("a4", seq: 9, role: "assistant", text: "비 와요").utf8)) as! [String: Any])])
        XCTAssertEqual(s.turns[1].status, .done)
        XCTAssertEqual(s.turns[1].assistantText, "비 와요")
        XCTAssertEqual(s.history.count, 4)
        // A new room (other account): the record starts over.
        s.apply(frame(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"other"}"#))
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertFalse(s.historyLoaded)
    }

    func testForgetEchoUpdatesTheLine() {
        var s = connected()
        s.apply(frame(#"{"type":"memory_update","room_id":"\#(room)","update":{"update_id":"u1","action":"created","items":[{"memory_id":"f1","kind":"fact","preview":"고양이"}]}}"#))
        s.apply(frame(#"{"type":"memory_update","room_id":"\#(room)","update":{"update_id":"u2","action":"forgotten","items":[{"memory_id":"f1","kind":"fact","preview":""}]}}"#))
        XCTAssertEqual(s.memoryNotes.count, 1)
        XCTAssertEqual(s.memoryNotes[0].action, "forgotten")
        s.apply(frame(#"{"type":"memory_update","room_id":"\#(room)","update":{"update_id":"u3","action":"restored","items":[{"memory_id":"f1","kind":"fact","preview":"고양이"}]}}"#))
        XCTAssertEqual(s.memoryNotes.count, 1)
        XCTAssertEqual(s.memoryNotes[0].action, "created")
        XCTAssertEqual(s.memoryNotes[0].text, "기억했어요: 고양이")
    }

    func testErrorCodesFromTheServerList() {
        let codes = ["unauthorized", "validation_error", "invalid_input", "bad_frame", "credits_exhausted", "task_not_startable",
                     "light_chat_limit", "quota_exceeded", "phone_verification_required", "forbidden", "suspended", "account_deleting",
                     "not_member", "not_found", "conflict", "version_conflict", "expired", "superseded", "already_answered",
                     "character_unavailable", "agent_unavailable", "connection_required", "connection_needs_reauth", "scope_blocked",
                     "payload_too_large", "unsupported_media_type", "restore_expired", "too_many_requests", "internal_error",
                     "not_implemented", "upstream_error", "transport", "outcome_unknown", "connector_unavailable", "service_disabled",
                     "agent_limit", "payment_error", "estimate_changed", "vault_not_ready"]
        for c in codes {
            let t = ErrorText.userMessage(code: c, reason: nil, fallback: "english")
            XCTAssertFalse(t.contains("(\(c))"), "\(c) has its own text")
            XCTAssertFalse(t.contains("english"))
        }
        XCTAssertEqual(ErrorText.userMessage(code: "brand_new", reason: nil, fallback: "english"), "문제가 생겼어요. (brand_new)")
        XCTAssertEqual(ErrorText.userMessage(code: "task_not_startable", reason: "heavy_daily_limit", fallback: ""),
                       "지금은 일을 맡길 수 없어요. 오늘 맡길 수 있는 큰 일을 다 썼어요.")
        XCTAssertEqual(ErrorText.userMessage(code: "character_unavailable", reason: "deleting", fallback: ""), "이 나초는 지워지는 중이에요.")
        XCTAssertTrue(ErrorText.userMessage(code: "too_many_requests", reason: "2030-01-02T03:04:05Z", fallback: "").contains("에 다시 해 주세요"))
        XCTAssertEqual(ErrorText.userMessage(code: "too_many_requests", reason: nil, fallback: ""), "잠시 너무 많이 요청했어요. 잠시 뒤 다시 해 주세요.")
        XCTAssertEqual(ErrorText.fromBody(Data(#"{"error":{"code":"light_chat_limit","message":"x"}}"#.utf8), status: 402),
                       ErrorText.userMessage(code: "light_chat_limit", reason: nil, fallback: ""))
        XCTAssertEqual(ErrorText.fromBody(Data("<html>".utf8), status: 502), ErrorText.userMessage(code: "internal_error", reason: nil, fallback: ""))
        XCTAssertEqual(ErrorText.fromBody(Data("<html>".utf8), status: 418), "문제가 생겼어요. (HTTP 418)")
    }
}

final class PetServerRequestTests: XCTestCase {
    let e = ServerEndpoint(base: URL(string: "https://api.example.com")!)

    private func query(_ r: PetHTTPRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testHistoryDeltaUsageConfig() {
        let h = PetServerAPI.historyRequest(e, bearer: "tk", roomID: "r1", beforeSeq: 40)
        XCTAssertEqual(h.method, "GET")
        XCTAssertEqual(h.url.path, "/api/v1/rooms/r1/history")
        XCTAssertEqual(query(h), ["view": "app", "limit": "50", "before_seq": "40"])
        XCTAssertEqual(h.headers["Authorization"], "Bearer tk")
        XCTAssertNil(query(PetServerAPI.historyRequest(e, bearer: nil, roomID: "r1", beforeSeq: nil))["before_seq"])
        let d = PetServerAPI.deltaRequest(e, bearer: "tk", roomID: "r1", sinceSeq: 7)
        XCTAssertEqual(d.url.path, "/api/v1/rooms/r1/delta")
        XCTAssertEqual(query(d), ["view": "app", "since_seq": "7"])
        XCTAssertEqual(PetServerAPI.usageRequest(e, bearer: "tk").url.path, "/api/v1/me/usage")
        let c = PetServerAPI.clientConfigRequest(e)
        XCTAssertEqual(c.url.path, "/client/config", "not under /api/v1")
        XCTAssertNil(c.headers["Authorization"])

        let page = PetServerAPI.decodeHistory(PetHTTPResponse(status: 200, headers: ["x-has-more": "true"], body: Data("[\(msg("a", seq: 1, role: "user", text: "hi"))]".utf8)))
        XCTAssertEqual(page?.messages.first?.text, "hi")
        XCTAssertEqual(page?.hasMore, true)
        let delta = PetServerAPI.decodeDelta(Data(#"{"room_id":"r","messages":[],"last_seq":9,"read_seq":8,"has_more":false,"activity":{"kind":"typing"}}"#.utf8))
        XCTAssertEqual(delta?.lastSeq, 9)
        XCTAssertEqual(delta?.activity, .typing)
        let usage = PetServerAPI.decodeUsage(Data(#"{"plan_id":"free","allowance":100,"remaining":0,"available_to_start":0,"exhausted":true,"block_reason":"credits_exhausted","limits":[{"kind":"light_chat","used":50,"cap":50}]}"#.utf8))
        XCTAssertEqual(usage?.summary, "크레딧 0/100 · 가벼운 대화 50/50 · 크레딧이 모자라요.")
        let cfg = PetClientConfig.decode(Data(#"{"service_status":{"state":"maintenance","message":"3시까지"},"dictation":{"enabled":true,"max_sec":60,"max_bytes":2000000},"media_max_bytes":20971520}"#.utf8))
        XCTAssertEqual(cfg?.dictationEnabled, true)
        XCTAssertEqual(cfg?.mediaMaxBytes, 20_971_520)
        XCTAssertEqual(cfg?.serviceNotice, "나초 서버 점검 중이에요. 3시까지")
        XCTAssertEqual(PetClientConfig.decode(Data("{}".utf8))?.dictationEnabled, false)
    }

    func testDictationMultipart() {
        let r = PetServerAPI.dictationRequest(e, bearer: "tk", audio: Data([0x41, 0x42]), mime: "audio/mp4", fileName: "d.m4a",
                                              language: "ko", durationSec: 3.5, boundary: "BND")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/dictation")
        XCTAssertEqual(r.headers["Content-Type"], "multipart/form-data; boundary=BND")
        XCTAssertEqual(r.headers["Authorization"], "Bearer tk")
        let body = String(decoding: r.body!, as: UTF8.self)
        XCTAssertTrue(body.contains("--BND\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nko\r\n"))
        XCTAssertTrue(body.contains("name=\"duration_sec\"\r\n\r\n3.50\r\n"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"d.m4a\"\r\nContent-Type: audio/mp4\r\n\r\nAB\r\n--BND--\r\n"))
        XCTAssertEqual(PetServerAPI.decodeDictation(Data(#"{"text":"안녕","language":"ko"}"#.utf8)), "안녕")
    }

    func testMemoryAndCardRequests() {
        let f = PetServerAPI.feedbackRequest(e, bearer: "tk", text: "틀렸어", kind: "correction", memoryIDs: ["f1"], roomID: "r1",
                                             agentID: "a1", idempotencyKey: "k1")
        XCTAssertEqual(f.url.path, "/api/v1/memory/feedback")
        XCTAssertEqual(f.headers["Idempotency-Key"], "k1")
        let fj = PetStubHTTP.json(f)
        XCTAssertEqual(fj["text"] as? String, "틀렸어")
        XCTAssertEqual(fj["kind"] as? String, "correction")
        XCTAssertEqual(fj["memory_ids"] as? [String], ["f1"])
        XCTAssertEqual(fj["room_id"] as? String, "r1")
        let forgetFact = PetServerAPI.forgetRequest(e, bearer: "tk", memoryID: "f1", kind: "fact")
        XCTAssertEqual(forgetFact.method, "DELETE")
        XCTAssertEqual(forgetFact.url.path, "/api/v1/memory/facts/f1")
        XCTAssertEqual(PetServerAPI.forgetRequest(e, bearer: "tk", memoryID: "e1", kind: "episode").url.path, "/api/v1/memory/episodes/e1")
        let restore = PetServerAPI.restoreRequest(e, bearer: "tk", memoryID: "f1")
        XCTAssertEqual(restore.method, "POST")
        XCTAssertEqual(restore.url.path, "/api/v1/memory/f1/restore")

        var card = PetCard.decode(["id": "cd", "kind": "choice", "status": "pending", "version": 3, "payload": ["question": "q"]])
        let a = PetServerAPI.answerCardRequest(e, bearer: "tk", card: card, action: "choose", optionIDs: ["b"])
        XCTAssertEqual(a.url.path, "/api/v1/chat/requests/cd/answer")
        let aj = PetStubHTTP.json(a)
        XCTAssertEqual(aj["action"] as? String, "choose")
        XCTAssertEqual(aj["option_id"] as? String, "b")
        XCTAssertEqual(aj["expected_version"] as? Int, 3)
        card.multiple = true
        XCTAssertEqual(PetStubHTTP.json(PetServerAPI.answerCardRequest(e, bearer: "tk", card: card, action: "choose", optionIDs: ["a", "b"]))["option_ids"] as? [String], ["a", "b"])
    }
}

final class PetServerSessionTests: XCTestCase {
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    var http: PetStubHTTP!
    var factory: PetTransportFactory!
    var browser: PetFakeBrowser!
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        http = PetStubHTTP()
        factory = PetTransportFactory()
        browser = PetFakeBrowser()
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        http.on("GET", "/client/config", 200, #"{"service_status":{"state":"ok"},"dictation":{"enabled":true,"max_sec":60,"max_bytes":2000000},"media_max_bytes":20971520}"#)
        http.on("GET", "/api/v1/me/usage", 200, #"{"plan_id":"free","allowance":100,"remaining":70,"available_to_start":70,"limits":[]}"#)
        http.on("GET", "/api/v1/rooms/\(room)/history", 200, "[\(msg("h1", seq: 1, role: "user", text: "어제", client: "x")),\(msg("h2", seq: 2, role: "assistant", text: "응"))]")
    }

    private func session() -> PetSession {
        var s = PetSettings()
        s.serverMode = .mock
        s.allowComboControl = false
        return PetSession(settings: s, http: http, secrets: MemorySecretStore(), browser: browser, makeTransport: factory.make,
                          executor: nil, random: PetFixedRandom(), now: { [unowned self] in self.clock })
    }

    private func settle(_ s: PetSession) { for _ in 0..<8 { s.flush(); Thread.sleep(forTimeInterval: 0.01) } }

    private func connectedSession() -> (PetSession, PetFakeTransport) {
        let s = session()
        s.signIn(); settle(s)
        let chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"\#(room)"}"#)
        settle(s)
        return (s, chat)
    }

    func testConnectingLoadsConfigHistoryAndUsageThenRecoversFromTheDelta() {
        let (s, chat) = connectedSession()
        XCTAssertEqual(http.sent("GET", "/client/config").count, 1)
        XCTAssertNil(http.sent("GET", "/client/config")[0].headers["Authorization"])
        XCTAssertEqual(http.sent("GET", "/api/v1/rooms/\(room)/history")[0].headers["Authorization"], "Bearer at-1")
        XCTAssertEqual(s.snapshot.chat.history.map { $0.text }, ["어제", "응"])
        XCTAssertEqual(s.snapshot.chat.usage?.remaining, 70)
        XCTAssertEqual(s.snapshot.config?.dictationEnabled, true)

        s.send(text: "오늘은?")
        settle(s)
        let id = s.snapshot.chat.turns[0].clientMsgID
        chat.deliver(#"{"type":"turn_started","room_id":"\#(room)","client_id":"\#(id)","turn_id":"t","duplicate":false}"#)
        chat.deliver(#"{"type":"message","room_id":"\#(room)","client_id":"\#(id)","message":\#(msg("u3", seq: 3, role: "user", text: "오늘은?", client: id))}"#)
        settle(s)
        // The socket drops; the server finishes the answer meanwhile.
        http.on("GET", "/api/v1/rooms/\(room)/delta", 200, #"{"room_id":"\#(room)","messages":[\#(msg("u3", seq: 3, role: "user", text: "오늘은?", client: id)),\#(msg("a3", seq: 4, role: "assistant", text: "맑아요"))],"last_seq":4,"read_seq":2,"has_more":false}"#)
        chat.handler?(.closed(TransportFailure(message: "drop")))
        settle(s)
        XCTAssertEqual(s.snapshot.chat.turns[0].status, .interrupted)
        let again = factory.with(path: "/ws/chat")
        let deadline = Date().addingTimeInterval(5)
        while factory.with(path: "/ws/chat").count < 2, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(factory.with(path: "/ws/chat").count, 2, "reconnected (had \(again.count))")
        factory.with(path: "/ws/chat")[1].deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"\#(room)"}"#)
        settle(s)
        let delta = http.sent("GET", "/api/v1/rooms/\(room)/delta")
        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual(URLComponents(url: delta[0].url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "since_seq" }?.value, "3")
        XCTAssertEqual(s.snapshot.chat.turns[0].status, .done)
        XCTAssertEqual(s.snapshot.chat.turns[0].assistantText, "맑아요")
        XCTAssertEqual(http.sent("GET", "/api/v1/rooms/\(room)/history").count, 1, "the record is not loaded twice")
        XCTAssertEqual(http.sent("GET", "/client/config").count, 1)
    }

    func testOlderHistoryAndReadMark() {
        http.on("GET", "/api/v1/rooms/\(room)/history", 200, "[\(msg("h5", seq: 5, role: "user", text: "최근", client: "x"))]")
        let s = session()
        s.signIn(); settle(s)
        let chat = factory.with(path: "/ws/chat")[0]
        // First page says there is more.
        http.headers["GET /api/v1/rooms/\(room)/history"] = ["X-Has-More": "true"]
        chat.deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"\#(room)"}"#)
        settle(s)
        XCTAssertTrue(s.snapshot.chat.hasMoreHistory)
        http.on("GET", "/api/v1/rooms/\(room)/history", 200, "[\(msg("h4", seq: 4, role: "assistant", text: "예전"))]")
        http.headers["GET /api/v1/rooms/\(room)/history"] = ["X-Has-More": "false"]
        s.loadOlderHistory(); settle(s)
        let older = http.sent("GET", "/api/v1/rooms/\(room)/history").last!
        XCTAssertEqual(URLComponents(url: older.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before_seq" }?.value, "5")
        XCTAssertEqual(s.snapshot.chat.history.map { $0.seq }, [4, 5])
        XCTAssertFalse(s.snapshot.chat.hasMoreHistory)

        s.send(text: "안녕"); settle(s)
        let id = s.snapshot.chat.turns[0].clientMsgID
        chat.deliver(#"{"type":"message","room_id":"\#(room)","client_id":"\#(id)","message":\#(msg("a6", seq: 7, role: "assistant", text: "안녕!"))}"#)
        chat.deliver(#"{"type":"done","room_id":"\#(room)","client_id":"\#(id)","message_id":"a6","stopped":false}"#)
        settle(s)
        XCTAssertTrue(chat.sent.contains { $0.contains(#""type":"read""#) && $0.contains(#""seq":7"#) }, chat.sent.joined(separator: "\n"))
    }

    func testDictationGoesToTheServerWithinTheLimits() {
        http.on("POST", "/api/v1/dictation", 200, #"{"text":"내일 일정 알려줘","language":"ko","duration_sec":2.5}"#)
        let (s, _) = connectedSession()
        var got: Result<String, PetAPIError>?
        s.dictate(audio: Data(repeating: 1, count: 100), mime: "audio/mp4", fileName: "d.m4a", durationSec: 2.5) { got = $0 }
        settle(s)
        XCTAssertEqual(try got?.get(), "내일 일정 알려줘")
        XCTAssertEqual(http.sent("POST", "/api/v1/dictation").count, 1)
        XCTAssertFalse(s.snapshot.dictating)

        // Refused locally: too long, wrong type, empty. No request.
        for (audio, mime, sec) in [(Data(repeating: 1, count: 10), "audio/mp4", 62.0), (Data([1]), "video/mp4", 1.0), (Data(), "audio/mp4", 1.0)] {
            got = nil
            s.dictate(audio: audio, mime: mime, fileName: "d", durationSec: sec) { got = $0 }
            settle(s)
            if case .success = got { XCTFail("must refuse") }
        }
        XCTAssertEqual(http.sent("POST", "/api/v1/dictation").count, 1)

        // Server limit: 429 with the time it is allowed again.
        http.on("POST", "/api/v1/dictation", 429, #"{"error":{"code":"too_many_requests","message":"x","reason":"2030-01-02T03:04:05Z"}}"#)
        s.dictate(audio: Data([1]), mime: "audio/webm;codecs=opus", fileName: "d.webm", durationSec: 1) { got = $0 }
        settle(s)
        guard case let .failure(e)? = got else { return XCTFail("429") }
        XCTAssertEqual(e.code, "too_many_requests")
        XCTAssertTrue(e.text.contains("다시 해 주세요"))
    }

    func testDictationOffOnThisServer() {
        http.on("GET", "/client/config", 200, #"{"service_status":{"state":"ok"},"dictation":{"enabled":false,"max_sec":60,"max_bytes":2000000}}"#)
        let (s, _) = connectedSession()
        var got: Result<String, PetAPIError>?
        s.dictate(audio: Data([1]), mime: "audio/mp4", fileName: "d", durationSec: 1) { got = $0 }
        settle(s)
        if case .success = got { XCTFail("off") }
        XCTAssertTrue(http.sent("POST", "/api/v1/dictation").isEmpty)
    }

    func testForgetUndoWithinTenSecondsAndFeedback() {
        http.on("DELETE", "/api/v1/memory/facts/f1", 204, "")
        http.on("POST", "/api/v1/memory/f1/restore", 200, #"{"kind":"fact","item":{"id":"f1"}}"#)
        http.on("POST", "/api/v1/memory/feedback", 201, #"{"id":"fb","kind":"correction","classified_by":"client","actions":[{"action":"updated","memory_id":"f1"}],"created_at":"2026-11-11T00:00:00Z"}"#)
        let (s, chat) = connectedSession()
        chat.deliver(#"{"type":"memory_update","room_id":"\#(room)","update":{"update_id":"u1","action":"created","items":[{"memory_id":"f1","kind":"fact","preview":"매운 거 좋아함"}]}}"#)
        settle(s)
        s.forgetMemory(updateID: "u1"); settle(s)
        XCTAssertEqual(http.sent("DELETE", "/api/v1/memory/facts/f1").count, 1)
        XCTAssertEqual(s.snapshot.chat.memoryNotes[0].action, "forgotten")
        XCTAssertTrue(s.canUndoForget(updateID: "u1"))
        clock += 4
        s.undoForget(updateID: "u1"); settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/memory/f1/restore").count, 1)
        XCTAssertEqual(s.snapshot.chat.memoryNotes[0].action, "created")
        XCTAssertNil(s.snapshot.chat.memoryNotes[0].forgottenAt)

        s.forgetMemory(updateID: "u1"); settle(s)
        clock += 11
        XCTAssertFalse(s.canUndoForget(updateID: "u1"))
        s.undoForget(updateID: "u1"); settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/memory/f1/restore").count, 1, "too late: no call")
        XCTAssertEqual(s.snapshot.notice, ErrorText.userMessage(code: "restore_expired", reason: nil, fallback: ""))

        // "기억이 틀렸어요" on an answer that used f1.
        s.send(text: "내 취향 알아?"); settle(s)
        let id = s.snapshot.chat.turns[0].clientMsgID
        let answer = msg("a1", seq: 9, role: "assistant", text: "매운 거요").replacingOccurrences(of: #""used_memory_ids":[]"#, with: #""used_memory_ids":["f1"]"#)
        chat.deliver(#"{"type":"message","room_id":"\#(room)","client_id":"\#(id)","message":\#(answer)}"#)
        chat.deliver(#"{"type":"done","room_id":"\#(room)","client_id":"\#(id)","message_id":"a1","stopped":false}"#)
        settle(s)
        var reply: String??
        s.sendMemoryFeedback(turnID: id, text: "  이제 매운 거 못 먹어  ") { reply = $0 }
        settle(s)
        XCTAssertEqual(reply, .some(nil))
        let fb = http.sent("POST", "/api/v1/memory/feedback")
        XCTAssertEqual(fb.count, 1)
        let j = PetStubHTTP.json(fb[0])
        XCTAssertEqual(j["text"] as? String, "이제 매운 거 못 먹어")
        XCTAssertEqual(j["kind"] as? String, "correction")
        XCTAssertEqual(j["memory_ids"] as? [String], ["f1"])
        XCTAssertEqual(j["room_id"] as? String, room)
        XCTAssertNotNil(fb[0].headers["Idempotency-Key"])
        s.sendMemoryFeedback(turnID: id, text: "   ") { reply = $0 }
        settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/memory/feedback").count, 1, "empty text: no call")
    }

    func testChoiceCardAnsweredHereAndConflictsRefresh() {
        http.on("POST", "/api/v1/chat/requests/cd/answer", 200, #"{"id":"cd","kind":"choice","status":"answered","answered_action":"choose","version":2,"payload":{"question":"어디?","options":[{"id":"a","label":"강남"}]}}"#)
        let (s, chat) = connectedSession()
        chat.deliver(#"{"type":"card_update","room_id":"\#(room)","request":{"id":"cd","kind":"choice","status":"pending","version":1,"payload":{"question":"어디?","options":[{"id":"a","label":"강남"}]}}}"#)
        settle(s)
        XCTAssertEqual(s.snapshot.chat.pendingCards.count, 1)
        s.answerCard(id: "cd", action: "choose", optionIDs: ["a"]); settle(s)
        XCTAssertEqual(PetStubHTTP.json(http.sent("POST", "/api/v1/chat/requests/cd/answer")[0])["expected_version"] as? Int, 1)
        XCTAssertEqual(s.snapshot.chat.cards[0].status, "answered")
        XCTAssertTrue(s.snapshot.chat.pendingCards.isEmpty)

        // Someone answered on the phone first: 409 → the current card is read again.
        http.on("POST", "/api/v1/chat/requests/cd2/answer", 409, #"{"error":{"code":"already_answered","message":"x"}}"#)
        http.on("GET", "/api/v1/chat/requests/cd2", 200, #"{"id":"cd2","kind":"choice","status":"answered","answered_action":"choose","version":5,"payload":{"question":"q"}}"#)
        chat.deliver(#"{"type":"card_update","room_id":"\#(room)","request":{"id":"cd2","kind":"choice","status":"pending","version":4,"payload":{"question":"q"}}}"#)
        settle(s)
        var reply: String??
        s.answerCard(id: "cd2", action: "choose", optionIDs: ["x"]) { reply = $0 }
        settle(s)
        XCTAssertEqual(reply, .some(ErrorText.userMessage(code: "already_answered", reason: nil, fallback: "")))
        XCTAssertEqual(s.snapshot.chat.cards.first { $0.id == "cd2" }?.version, 5)
    }
}
