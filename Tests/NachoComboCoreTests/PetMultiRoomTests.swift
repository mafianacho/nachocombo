import Foundation
import XCTest

@testable import NachoComboCore

// NACHO-276 (U10): the chat window opens the room the user picked, shows who spoke in a group room, and redacts own messages.
// Rooms must never mix: pending text, streamed pieces, read marks and the record belong to the room they were made in.

private func frameJSON(_ raw: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
}

private func frame(_ json: String) -> ServerFrame { ServerFrame.decode(json)! }

// MARK: - the reducer

final class PetMultiRoomStateTests: XCTestCase {
    private func connected() -> ChatState {
        var s = ChatState()
        s.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        return s
    }

    func testSwitchRoomStartsClean() {
        var s = connected()
        s.beginTurn(text: "안녕", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"message","room_id":"home","message":{"id":"h1","seq":4,"role":"assistant","text":"예전 말"}}"#))
        s.switchRoom(id: "g1", title: "주말 계획", kind: "group")
        XCTAssertEqual(s.roomID, "g1")
        XCTAssertEqual(s.defaultRoomID, "home")
        XCTAssertEqual(s.roomTitle, "주말 계획")
        XCTAssertTrue(s.viewingOtherRoom)
        XCTAssertTrue(s.isGroupRoom)
        XCTAssertTrue(s.turns.isEmpty)
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertFalse(s.historyLoaded)
        XCTAssertFalse(s.hasMoreHistory)
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(s.lastSeq, 0, "the read mark of the new room does not start from the old room's seq")
    }

    func testFramesOfAnotherRoomNeverTouchTheOpenRoom() {
        var s = connected()
        s.switchRoom(id: "g1", title: "주말 계획", kind: "group")
        s.beginTurn(text: "여기 질문", clientMsgID: "c-9")
        // The answer of the room we left is still streaming on the same socket.
        s.apply(frame(#"{"type":"turn_started","room_id":"home","turn_id":"t","duplicate":false,"client_id":"c-1"}"#))
        s.apply(frame(#"{"type":"text_delta","room_id":"home","text":"이전 방 조각"}"#))
        s.apply(frame(#"{"type":"message","room_id":"home","message":{"id":"h2","seq":9,"role":"assistant","text":"이전 방 답"}}"#))
        s.apply(frame(#"{"type":"done","room_id":"home","stopped":false}"#))
        s.apply(frame(#"{"type":"error","room_id":"home","code":"internal_error","message":"x"}"#))
        XCTAssertEqual(s.turns.count, 1)
        XCTAssertEqual(s.turns[0].assistantText, "")
        XCTAssertEqual(s.turns[0].status, .sending, "the other room's `done` did not finish this room's turn")
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertEqual(s.lastSeq, 0)
        XCTAssertNil(s.notice)
        // The same kinds of frames of the open room do apply.
        s.apply(frame(#"{"type":"text_delta","room_id":"g1","text":"이 방 조각","client_id":"c-9"}"#))
        XCTAssertEqual(s.turns[0].assistantText, "이 방 조각")
    }

    func testReconnectKeepsTheOpenRoom() {
        var s = connected()
        s.switchRoom(id: "g1", title: "주말 계획", kind: "group")
        s.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m1","seq":3,"role":"assistant","text":"안녕하세요"}}"#))
        s.connectionLost()
        s.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        XCTAssertEqual(s.roomID, "g1")
        XCTAssertEqual(s.defaultRoomID, "home")
        XCTAssertEqual(s.history.map { $0.text }, ["안녕하세요"], "the record of the open room stays; the delta fills the gap")
    }

    func testBackToDefaultRoom() {
        var s = connected()
        s.switchRoom(id: "g1", title: "주말 계획", kind: "group")
        s.beginTurn(text: "질문", clientMsgID: "c-9")
        s.switchRoom(id: "home", title: nil, kind: nil)
        XCTAssertEqual(s.roomID, "home")
        XCTAssertFalse(s.viewingOtherRoom)
        XCTAssertNil(s.roomTitle)
        XCTAssertFalse(s.isGroupRoom)
        XCTAssertTrue(s.turns.isEmpty, "the turn of the group room does not follow")
    }

    func testSenderOfGroupMessagesAndWhoIsMe() {
        var s = connected()
        s.switchRoom(id: "g1", title: "주말 계획", kind: "group")
        s.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m1","seq":1,"role":"assistant","sender_kind":"agent","sender_agent_id":"a2","sender_name_snapshot":"모카","text":"안녕"}}"#))
        s.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m2","seq":2,"role":"user","sender_kind":"user","sender_user_id":"u2","sender_name_snapshot":"민수","text":"나도 왔어"}}"#))
        s.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m3","seq":3,"role":"user","sender_kind":"user","sender_user_id":"u1","text":"내가 쓴 글"}}"#))
        XCTAssertEqual(s.history.map { $0.senderName }, ["모카", "민수", nil])
        XCTAssertFalse(s.isMine(s.history[0]))
        XCTAssertFalse(s.isMine(s.history[1]), "a person's message in a group is not mine")
        XCTAssertTrue(s.isMine(s.history[2]))
    }

    func testApplyRedactionReplacesTheTextEverywhere() {
        var s = connected()
        s.beginTurn(text: "비밀 얘기", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"message","room_id":"home","client_id":"c-1","message":{"id":"m1","seq":5,"role":"user","client_msg_id":"c-1","text":"비밀 얘기"}}"#))
        s.apply(frame(#"{"type":"message","room_id":"home","message":{"id":"m0","seq":2,"role":"user","text":"예전 비밀"}}"#))
        s.applyRedaction(seq: 5, text: "")
        s.applyRedaction(seq: 2, text: "")
        XCTAssertEqual(s.turns[0].userText, ChatState.redactedText)
        XCTAssertEqual(s.history[0].text, ChatState.redactedText)
    }
}

// MARK: - requests (bytes)

final class PetMultiRoomRequestTests: XCTestCase {
    let ep = try! ServerEndpoint.parse("https://api.example.test").get()

    func testRedactRequestBytes() {
        let r = PetServerAPI.redactRequest(ep, bearer: "tok", roomID: "0193aaaa-0000-7000-8000-000000000003", seq: 42)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://api.example.test/api/v1/rooms/0193aaaa-0000-7000-8000-000000000003/messages/42/redact")
        XCTAssertEqual(r.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(String(decoding: r.body ?? Data(), as: UTF8.self), "{}")
    }

    func testRedactIsRefusedLocallyForNonsenseSeq() {
        XCTAssertNil(PetServerAPI.redactRequestChecked(ep, bearer: "t", roomID: "r", seq: 0))
        XCTAssertNil(PetServerAPI.redactRequestChecked(ep, bearer: "t", roomID: "", seq: 3))
        XCTAssertNotNil(PetServerAPI.redactRequestChecked(ep, bearer: "t", roomID: "r", seq: 3))
    }
}

// MARK: - the session

final class PetMultiRoomSessionTests: XCTestCase {
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    var http: PetStubHTTP!
    var factory: PetTransportFactory!
    var browser: PetFakeBrowser!
    var session: PetSession!
    var chat: PetFakeTransport!

    override func setUp() {
        http = PetStubHTTP()
        factory = PetTransportFactory()
        browser = PetFakeBrowser()
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        http.on("POST", "/api/v1/agents/\(agent)/connector-binding", 200, #"{"token":"nct_feed","endpoint":"/ws/connector"}"#)
        http.on("GET", "/api/v1/rooms/home/history", 200, "[]")
        http.on("GET", "/api/v1/rooms/g1/history", 200,
                #"[{"id":"g-1","seq":7,"role":"assistant","sender_kind":"agent","sender_name_snapshot":"모카","text":"그룹 첫말"}]"#)
        http.on("GET", "/api/v1/rooms/g2/history", 200, "[]")
        var s = PetSettings()
        s.serverMode = .mock
        s.allowComboControl = false
        session = PetSession(settings: s, http: http, secrets: MemorySecretStore(), browser: browser,
                             makeTransport: factory.make, executor: PetRecordingExecutor(), random: PetFixedRandom())
        session.signIn(); settle()
        chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(#"{"type":"ready","user_id":"u1","agent_id":"\#(agent)","agent_name":"나초","room_id":"home"}"#); settle()
    }

    private func settle() { for _ in 0..<8 { session.flush(); Thread.sleep(forTimeInterval: 0.01) } }

    private func sentFrames(_ type: String) -> [[String: Any]] {
        chat.sent.map(frameJSON).filter { $0["type"] as? String == type }
    }

    private func send(_ text: String) {
        let e = expectation(description: "send \(text)")
        session.send(text: text) { XCTAssertNil($0); e.fulfill() }
        wait(for: [e], timeout: 5)
        settle()
    }

    func testMessagesGoToTheOpenRoom() {
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        XCTAssertEqual(session.snapshot.chat.roomID, "g1")
        send("그룹에 하는 말")
        XCTAssertEqual(sentFrames("message").last?["room_id"] as? String, "g1")
        // The record of that room was fetched (not the default room's).
        XCTAssertEqual(http.sent("GET", "/api/v1/rooms/g1/history").count, 1)
        XCTAssertEqual(session.snapshot.chat.history.map { $0.text }, ["그룹 첫말"])
        XCTAssertEqual(session.snapshot.chat.history.first?.senderName, "모카")
    }

    func testReadMarkIsForTheOpenRoomAndItsOwnSeq() {
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        let reads = sentFrames("read")
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads[0]["room_id"] as? String, "g1")
        XCTAssertEqual(reads[0]["seq"] as? Int, 7)
    }

    func testSwitchingDropsQueuedTextAndPendingTurn() {
        send("기본 방 질문")
        let id = sentFrames("message").last?["client_msg_id"] as? String ?? "?"
        chat.deliver(#"{"type":"turn_started","room_id":"home","turn_id":"t","duplicate":false,"client_id":"\#(id)"}"#); settle()
        let q = expectation(description: "queue")
        session.sendOrQueue(text: "기다리는 글") { _ in q.fulfill() }
        wait(for: [q], timeout: 5); settle()
        XCTAssertEqual(session.snapshot.queuedText, "기다리는 글")
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        XCTAssertNil(session.snapshot.queuedText, "text queued for the old room must not be sent to the new one")
        XCTAssertFalse(session.snapshot.chat.isBusy)
        // The old room's turn ends: nothing is sent anywhere.
        chat.deliver(#"{"type":"done","room_id":"home","stopped":false,"client_id":"\#(id)"}"#); settle()
        XCTAssertEqual(sentFrames("message").count, 1, "only the first message was ever sent")
    }

    func testStreamedPiecesOfTheOldRoomDoNotLandInTheNewOne() {
        send("기본 방 질문")
        let id = sentFrames("message").last?["client_msg_id"] as? String ?? "?"
        chat.deliver(#"{"type":"turn_started","room_id":"home","turn_id":"t","duplicate":false,"client_id":"\#(id)"}"#)
        chat.deliver(#"{"type":"text_delta","room_id":"home","text":"반가","client_id":"\#(id)"}"#); settle()
        session.openRoom(id: "g2", title: "다른 방", kind: "group"); settle()
        chat.deliver(#"{"type":"text_delta","room_id":"home","text":"워요","client_id":"\#(id)"}"#)
        chat.deliver(#"{"type":"message","room_id":"home","message":{"id":"a1","seq":3,"role":"assistant","text":"반가워요"},"client_id":"\#(id)"}"#)
        chat.deliver(#"{"type":"done","room_id":"home","stopped":false,"client_id":"\#(id)"}"#); settle()
        let c = session.snapshot.chat
        XCTAssertEqual(c.roomID, "g2")
        XCTAssertTrue(c.turns.isEmpty)
        XCTAssertTrue(c.history.isEmpty)
        XCTAssertEqual(c.lastSeq, 0)
    }

    func testComingBackFillsTheAnswerFromTheServer() {
        send("기본 방 질문")
        let id = sentFrames("message").last?["client_msg_id"] as? String ?? "?"
        chat.deliver(#"{"type":"turn_started","room_id":"home","turn_id":"t","duplicate":false,"client_id":"\#(id)"}"#); settle()
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        http.on("GET", "/api/v1/rooms/home/history", 200,
                #"[{"id":"u1","seq":1,"role":"user","client_msg_id":"\#(id)","text":"기본 방 질문"},{"id":"a1","seq":2,"role":"assistant","text":"서버가 끝낸 답"}]"#)
        session.returnToDefaultRoom(); settle()
        let c = session.snapshot.chat
        XCTAssertEqual(c.roomID, "home")
        XCTAssertFalse(c.viewingOtherRoom)
        XCTAssertEqual(c.history.map { $0.text }, ["기본 방 질문", "서버가 끝낸 답"])
    }

    func testSlowRecordOfTheOldRoomIsIgnoredAfterSwitching() {
        // Open g1 then g2 at once: g1's record must not end up in g2.
        session.openRoom(id: "g1", title: "첫 방", kind: "group")
        session.openRoom(id: "g2", title: "둘째 방", kind: "group"); settle()
        let c = session.snapshot.chat
        XCTAssertEqual(c.roomID, "g2")
        XCTAssertTrue(c.history.isEmpty, "g1's message never shows in g2")
        XCTAssertEqual(http.sent("GET", "/api/v1/rooms/g2/history").count, 1)
    }

    func testReconnectFillsTheOpenRoomFromItsDelta() {
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        http.on("GET", "/api/v1/rooms/g1/delta", 200,
                #"{"messages":[{"id":"g-2","seq":8,"role":"assistant","text":"끊긴 사이 온 말"}],"last_seq":8,"read_seq":7,"has_more":false}"#)
        chat.handler?(.closed(nil)); settle()
        // A second connection opens (reconnect) and the server says ready with the default room.
        let again = factory.with(path: "/ws/chat")
        XCTAssertGreaterThan(again.count, 1)
        again.last?.deliver(#"{"type":"ready","user_id":"u1","agent_id":"\#(agent)","agent_name":"나초","room_id":"home"}"#)
        settle()
        XCTAssertEqual(session.snapshot.chat.roomID, "g1")
        XCTAssertEqual(http.sent("GET", "/api/v1/rooms/g1/delta").first?.url.query?.contains("since_seq=7"), true)
        XCTAssertEqual(session.snapshot.chat.history.map { $0.text }, ["그룹 첫말", "끊긴 사이 온 말"])
    }

    // MARK: redact

    private func redact(_ seq: Int) -> String? {
        var out: String? = "unset"
        let e = expectation(description: "redact")
        session.redactMessage(seq: seq) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        settle()
        return out
    }

    func testRedactSendsOneRequestAndReplacesTheText() {
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        chat.deliver(#"{"type":"message","room_id":"g1","message":{"id":"m9","seq":9,"role":"user","sender_user_id":"u1","text":"지울 말"}}"#); settle()
        http.on("POST", "/api/v1/rooms/g1/messages/9/redact", 200, #"{"id":"m9","seq":9,"role":"user","text":""}"#)
        XCTAssertNil(redact(9))
        let reqs = http.sent("POST", "/api/v1/rooms/g1/messages/9/redact")
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(String(decoding: reqs[0].body ?? Data(), as: UTF8.self), "{}")
        XCTAssertEqual(session.snapshot.chat.history.last?.text, ChatState.redactedText)
    }

    func testRedactErrorsAreKorean() {
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        http.on("POST", "/api/v1/rooms/g1/messages/9/redact", 404, #"{"error":{"code":"not_found","message":"x"}}"#)
        XCTAssertEqual(redact(9), PetMultiRoomSessionTests.notFoundText)
        http.on("POST", "/api/v1/rooms/g1/messages/9/redact", 409, #"{"error":{"code":"conflict","message":"x"}}"#)
        XCTAssertEqual(redact(9), "이미 처리된 요청이에요.")
        http.on("POST", "/api/v1/rooms/g1/messages/9/redact", 500, #"{"error":{"code":"internal_error","message":"x"}}"#)
        XCTAssertEqual(redact(9), "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
    }

    static let notFoundText = "지울 메시지를 찾지 못했어요."

    func testRedact401SignsOutCleanly() {
        session.openRoom(id: "g1", title: "주말 계획", kind: "group"); settle()
        http.on("POST", "/api/v1/rooms/g1/messages/9/redact", 401, #"{"error":{"code":"unauthorized","message":"x"}}"#)
        XCTAssertEqual(redact(9), "로그인이 필요해요.")
        XCTAssertEqual(session.snapshot.auth, .signedOut)
    }

    func testRedactWithoutARoomOrSeqSendsNothing() {
        XCTAssertNotNil(redact(0))
        XCTAssertTrue(http.sent("POST", "/api/v1/rooms/home/messages/0/redact").isEmpty)
    }

    // MARK: token refresh for the hub (extra scope)

    func testRefreshAccessTokenForcesOneRefresh() {
        let before = http.sent("POST", "/realms/nachotown/protocol/openid-connect/token").count
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200,
                #"{"access_token":"at-2","token_type":"Bearer","expires_in":300,"refresh_token":"rt-2","refresh_expires_in":1800}"#)
        var got: String?
        let e = expectation(description: "refresh")
        session.refreshAccessToken { got = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(got, "at-2")
        let reqs = http.sent("POST", "/realms/nachotown/protocol/openid-connect/token")
        XCTAssertEqual(reqs.count, before + 1)
        XCTAssertEqual(PetStubHTTP.form(reqs.last!)["grant_type"], "refresh_token")
        XCTAssertEqual(PetStubHTTP.form(reqs.last!)["refresh_token"], "rt-1")
    }

    func testRefreshFailureEndsSignedOutWithoutLooping() {
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 400, #"{"error":"invalid_grant"}"#)
        var got: String? = "unset"
        let e = expectation(description: "refresh")
        session.refreshAccessToken { got = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        settle()
        XCTAssertNil(got)
        XCTAssertEqual(session.snapshot.auth, .signedOut)
        XCTAssertEqual(session.snapshot.notice, AuthProblem.rejected("").koreanMessage)
        // Asking again does not hit the token endpoint again: the login is gone.
        let n = http.sent("POST", "/realms/nachotown/protocol/openid-connect/token").count
        let e2 = expectation(description: "refresh again")
        session.refreshAccessToken { _ in e2.fulfill() }
        wait(for: [e2], timeout: 5)
        XCTAssertEqual(http.sent("POST", "/realms/nachotown/protocol/openid-connect/token").count, n)
    }

    func testHubClientRetriesOnceWithTheRefreshedToken() {
        // 401 → refresh → one retry with the new token; a second 401 ends (no loop).
        let hubHTTP = PetStubHTTP()
        hubHTTP.then("GET", "/api/v1/x", 401, #"{"error":{"code":"unauthorized","message":"x"}}"#)
        hubHTTP.then("GET", "/api/v1/x", 200, "{}")
        var calls: [Bool] = []
        let client = HubClient(endpoint: try! ServerEndpoint.parse("https://api.example.test").get(), http: hubHTTP) { force, done in
            calls.append(force)
            done(force ? "new" : "old")
        }
        let e = expectation(description: "hub")
        var out: Result<PetHTTPResponse, PetAPIError>?
        client.send({ tok in .get(URL(string: "https://api.example.test/api/v1/x")!, bearer: tok) }) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(calls, [false, true])
        XCTAssertEqual(hubHTTP.requests.map { $0.headers["Authorization"] }, ["Bearer old", "Bearer new"])
        if case .failure = out! { XCTFail("retry should succeed") }
    }

    func testHubClientStopsWhenTheRefreshFails() {
        let hubHTTP = PetStubHTTP()
        hubHTTP.on("GET", "/api/v1/x", 401, #"{"error":{"code":"unauthorized","message":"x"}}"#)
        var calls = 0
        let client = HubClient(endpoint: try! ServerEndpoint.parse("https://api.example.test").get(), http: hubHTTP) { force, done in
            calls += 1
            done(force ? nil : "old")  // refresh failed: no token
        }
        let e = expectation(description: "hub")
        var out: Result<PetHTTPResponse, PetAPIError>?
        client.send({ tok in .get(URL(string: "https://api.example.test/api/v1/x")!, bearer: tok) }) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(hubHTTP.requests.count, 1, "no second request without a token")
        guard case let .failure(err) = out! else { return XCTFail("must fail") }
        XCTAssertEqual(err.status, 401)
        XCTAssertEqual(err.text, "로그인이 필요해요.")
    }
}

// MARK: - what the window shows

final class PetMultiRoomTranscriptTests: XCTestCase {
    private func groupState() -> PetSessionState {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        st.chat.switchRoom(id: "g1", title: "주말 계획", kind: "group")
        st.chat.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m1","seq":1,"role":"assistant","sender_kind":"agent","sender_name_snapshot":"모카","text":"안녕"}}"#))
        st.chat.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m2","seq":2,"role":"user","sender_user_id":"u2","sender_name_snapshot":"민수","text":"나도 왔어"}}"#))
        st.chat.apply(frame(#"{"type":"message","room_id":"g1","message":{"id":"m3","seq":3,"role":"user","sender_user_id":"u1","text":"내 말"}}"#))
        return st
    }

    func testGroupRoomNamesWhoSpoke() {
        let items = PetTranscript.items(groupState(), undoSecondsLeft: { _ in nil })
        XCTAssertEqual(items.compactMap { i -> String? in if case let .sender(n) = i { return n }; return nil }, ["모카", "민수"])
        // A name sits right above the bubble it names; my own message has none.
        XCTAssertEqual(items[1], .sender("모카"))
        XCTAssertEqual(items[2], .nacho(text: "안녕", past: true, streaming: false))
        XCTAssertEqual(items[3], .sender("민수"))
        XCTAssertEqual(items[4], .nacho(text: "나도 왔어", past: true, streaming: false))
        XCTAssertEqual(items[5], .mine(text: "내 말", attachments: [], past: true))
    }

    func testSingleRoomItemsAreUnchanged() {
        var st = PetSessionState()
        st.chat.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        st.chat.apply(frame(#"{"type":"message","room_id":"home","message":{"id":"m1","seq":1,"role":"assistant","sender_kind":"agent","sender_name_snapshot":"나초","text":"안녕"}}"#))
        let items = PetTranscript.items(st, undoSecondsLeft: { _ in nil })
        XCTAssertFalse(items.contains { if case .sender = $0 { return true }; if case .redactable = $0 { return true }; return false })
    }

    func testRedactMarksOnlyMyTextMessages() {
        let items = PetTranscript.items(groupState(), undoSecondsLeft: { _ in nil }, redactable: true)
        let marks = items.compactMap { i -> Int? in if case let .redactable(seq) = i { return seq }; return nil }
        XCTAssertEqual(marks, [3])
        let at = items.firstIndex(of: .redactable(seq: 3))!
        XCTAssertEqual(items[at + 1], .mine(text: "내 말", attachments: [], past: true))
    }

    func testRedactedMessageHasNoMarkAndShowsTheNote() {
        var st = groupState()
        st.chat.applyRedaction(seq: 3, text: "")
        let items = PetTranscript.items(st, undoSecondsLeft: { _ in nil }, redactable: true)
        XCTAssertFalse(items.contains(.redactable(seq: 3)))
        XCTAssertTrue(items.contains(.mine(text: ChatState.redactedText, attachments: [], past: true)))
    }

    func testHeaderNamesTheRoom() {
        let st = groupState()
        XCTAssertEqual(PetTranscript.roomHeader(st.chat)?.title, "주말 계획")
        XCTAssertEqual(PetTranscript.roomHeader(st.chat)?.subtitle, "그룹 대화")
        var home = PetSessionState()
        home.chat.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        XCTAssertNil(PetTranscript.roomHeader(home.chat))
    }

    func testRoomTitleFallbackAndPlaceholder() {
        var c = ChatState()
        c.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        c.switchRoom(id: "d1", title: "  ", kind: "direct")
        XCTAssertEqual(PetTranscript.roomHeader(c)?.title, "이름 없는 대화")
        XCTAssertEqual(PetTranscript.inputPlaceholder(c), "메시지 쓰기…")
        c.switchRoom(id: "home", title: nil, kind: nil)
        XCTAssertEqual(PetTranscript.inputPlaceholder(c), "나초에게 말하기…")
    }
}
