import XCTest
@testable import NachoComboCore

// Ported from nacho-gadget-app (PR #1 @1d685fa) Tests/ChatTests.swift. Class names carry a Pet prefix; the pet face
// moved to PetFace (more states, see PetFaceTests).

final class PetFramesTests: XCTestCase {
    func testDecodeReadyAndUnknownFields() {
        let f = ServerFrame.decode(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"r","extra":1}"#)
        XCTAssertEqual(f?.event, .ready(ReadyInfo(userID: "u", agentID: "a", agentName: "나초", roomID: "r")))
    }

    func testDecodeStreamFramesCarryClientID() {
        let d = ServerFrame.decode(#"{"type":"text_delta","room_id":"r","text":"좋아요, ","client_id":"c-1"}"#)
        XCTAssertEqual(d?.event, .textDelta("좋아요, "))
        XCTAssertEqual(d?.clientID, "c-1")
        let a = ServerFrame.decode(#"{"type":"activity","room_id":"r","activity":{"kind":"tool","tool":"search_web"}}"#)
        XCTAssertEqual(a?.event, .activity(.tool, tool: "search_web"))
        let done = ServerFrame.decode(#"{"type":"done","room_id":"r","message_id":null,"stopped":true}"#)
        XCTAssertEqual(done?.event, .done(messageID: nil, stopped: true))
    }

    func testUnknownTypeAndGarbage() {
        XCTAssertEqual(ServerFrame.decode(#"{"type":"card_update"}"#)?.event, .unknown(type: "card_update"))
        XCTAssertNil(ServerFrame.decode("not json"))
        XCTAssertNil(ServerFrame.decode(#"{"no_type":1}"#))
        XCTAssertNil(ServerFrame.decode(#"[1,2]"#))
        XCTAssertNil(ServerFrame.decode(#"{"type":5}"#))
    }

    func testUnknownActivityKindFallsBackToIdle() {
        let a = ServerFrame.decode(#"{"type":"activity","activity":{"kind":"dancing"}}"#)
        XCTAssertEqual(a?.event, .activity(.idle, tool: nil))
    }

    func testEncodeIsDeterministicJSON() {
        XCTAssertEqual(ClientFrame.ping.encode(), #"{"type":"ping"}"#)
        XCTAssertEqual(ClientFrame.stop(roomID: "r").encode(), #"{"room_id":"r","type":"stop"}"#)
        let m = ClientFrame.message(text: "안녕 \"나초\"", roomID: "r", clientMsgID: "c-1").encode()
        let obj = try! JSONSerialization.jsonObject(with: Data(m.utf8)) as! [String: Any]
        XCTAssertEqual(obj["text"] as? String, "안녕 \"나초\"")
        XCTAssertEqual(obj["client_msg_id"] as? String, "c-1")
        XCTAssertEqual(obj["client_id"] as? String, "c-1")
        XCTAssertEqual(obj["room_id"] as? String, "r")
    }
}

final class PetChatStateTests: XCTestCase {
    private func frame(_ json: String) -> ServerFrame { ServerFrame.decode(json)! }

    private func connected() -> ChatState {
        var s = ChatState()
        s.apply(frame(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"r"}"#))
        return s
    }

    func testStreamingTurnHappyPath() {
        var s = connected()
        XCTAssertEqual(s.phase, .connected)
        s.beginTurn(text: "안녕", clientMsgID: "c-1")
        XCTAssertEqual(s.turns[0].status, .sending)
        s.apply(frame(#"{"type":"turn_started","room_id":"r","turn_id":"t","duplicate":false,"client_id":"c-1"}"#))
        XCTAssertEqual(s.turns[0].status, .streaming)
        s.apply(frame(#"{"type":"text_delta","room_id":"r","text":"반가","client_id":"c-1"}"#))
        s.apply(frame(#"{"type":"text_delta","room_id":"r","text":"워요","client_id":"c-1"}"#))
        XCTAssertEqual(s.turns[0].assistantText, "반가워요")
        XCTAssertEqual(PetFace.derive(dictating: false, chat: s, now: Date(), lastInteraction: Date()), .speaking)
        s.apply(frame(#"{"type":"message","room_id":"r","message":{"id":"m","role":"assistant","text":"반가워요!"},"client_id":"c-1"}"#))
        XCTAssertEqual(s.turns[0].assistantText, "반가워요!")  // committed message wins
        s.apply(frame(#"{"type":"done","room_id":"r","stopped":false,"client_id":"c-1"}"#))
        XCTAssertEqual(s.turns[0].status, .done)
        XCTAssertFalse(s.isBusy)
        XCTAssertEqual(PetFace.derive(dictating: false, chat: s, now: Date(), lastInteraction: Date()), .happy)
        XCTAssertEqual(PetFace.derive(dictating: false, chat: s, now: Date().addingTimeInterval(5), lastInteraction: Date()), .idle)
    }

    func testStopKeepsPartialText() {
        var s = connected()
        s.beginTurn(text: "길게", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"text_delta","text":"문장 1. ","client_id":"c-1"}"#))
        s.markStopRequested()
        XCTAssertTrue(s.turns[0].stopRequested)
        s.apply(frame(#"{"type":"done","room_id":"r","stopped":true,"client_id":"c-1"}"#))
        XCTAssertEqual(s.turns[0].status, .stopped)
        XCTAssertEqual(s.turns[0].assistantText, "문장 1. ")
    }

    func testDuplicateTurnEndsWithoutNewText() {
        var s = connected()
        s.beginTurn(text: "again", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"turn_started","room_id":"r","duplicate":true,"client_id":"c-1"}"#))
        XCTAssertEqual(s.turns[0].status, .done)
    }

    func testTurnErrorUsesKoreanText() {
        var s = connected()
        s.beginTurn(text: "x", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"error","room_id":"r","code":"upstream_error","message":"external service openrouter: 500","client_id":"c-1"}"#))
        guard case let .failed(m) = s.turns[0].status else { return XCTFail("expected failed") }
        XCTAssertFalse(m.contains("openrouter"))
        XCTAssertTrue(m.contains("다시 시도"))
    }

    func testPreTurnRejectionBecomesNoticeOrTurnFailure() {
        var s = connected()
        s.apply(frame(#"{"type":"error","code":"bad_frame","message":"x"}"#))  // no room_id, no active turn
        XCTAssertNotNil(s.notice)
        s.beginTurn(text: "x", clientMsgID: "c-2")
        s.apply(frame(#"{"type":"error","code":"credits_exhausted","message":"x","client_id":"c-2"}"#))
        XCTAssertEqual(s.turns[0].status, .failed("사용량이 모두 소진됐어요."))
    }

    func testOtherSessionsTurnIsIgnored() {
        var s = connected()
        s.beginTurn(text: "mine", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"text_delta","text":"not mine","client_id":"other"}"#))
        XCTAssertEqual(s.turns[0].assistantText, "")
    }

    func testConnectionLostInterruptsUnfinishedTurnsOnly() {
        var s = connected()
        s.beginTurn(text: "a", clientMsgID: "c-1")
        s.apply(frame(#"{"type":"done","stopped":false,"client_id":"c-1"}"#))
        s.beginTurn(text: "b", clientMsgID: "c-2")
        s.connectionLost()
        XCTAssertEqual(s.turns[0].status, .done)
        XCTAssertEqual(s.turns[1].status, .interrupted)
    }

    func testUnauthorizedSetsAuthFailed() {
        var s = ChatState()
        s.apply(frame(#"{"type":"error","code":"unauthorized","message":"x"}"#))
        XCTAssertEqual(s.phase, .authFailed)
    }

    func testPetStates() {
        var s = connected()
        XCTAssertEqual(PetFace.derive(dictating: true, chat: s, now: Date(), lastInteraction: Date()), .listening)
        s.beginTurn(text: "q", clientMsgID: "c-1")
        XCTAssertEqual(PetFace.derive(dictating: false, chat: s, now: Date(), lastInteraction: Date()), .thinking)
        s.apply(frame(#"{"type":"activity","activity":{"kind":"tool","tool":"search_web"}}"#))
        XCTAssertEqual(s.activeTool, "search_web")
        XCTAssertEqual(PetFace.derive(dictating: false, chat: s, now: Date(), lastInteraction: Date()), .thinking)
        XCTAssertEqual(PetFace.allCases.count, 8)
    }

    func testOutgoingTextValidation() {
        XCTAssertEqual(OutgoingText.validate("  \n "), .failure(.empty))
        XCTAssertEqual(try! OutgoingText.validate("  hi \u{0} ").get(), "hi")
        let ok = String(repeating: "가", count: OutgoingText.maxCodePoints)
        XCTAssertNoThrow(try OutgoingText.validate(ok).get())
        XCTAssertEqual(OutgoingText.validate(ok + "가"), .failure(.tooLong))
        // astral characters count as one code point each
        let emoji = String(repeating: "😀", count: OutgoingText.maxCodePoints)
        XCTAssertNoThrow(try OutgoingText.validate(emoji).get())
        XCTAssertEqual(OutgoingText.validate(emoji + "😀"), .failure(.tooLong))
    }
}

final class PetReconnectPolicyTests: XCTestCase {
    func testBackoffDoublesAndCaps() {
        let p = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        XCTAssertEqual(p.delay(attempt: 1), 1)
        XCTAssertEqual(p.delay(attempt: 2), 2)
        XCTAssertEqual(p.delay(attempt: 5), 16)
        XCTAssertEqual(p.delay(attempt: 6), 30)
        XCTAssertEqual(p.delay(attempt: 99), 30)
        XCTAssertEqual(p.delay(attempt: 3, jitter: 0), 2)  // 50% floor
        XCTAssertEqual(p.delay(attempt: 3, jitter: 5), 4)  // clamped
    }

    func testAuthFailuresAndLimitStopRetrying() {
        let p = ReconnectPolicy(maxAttempts: 3)
        XCTAssertFalse(p.shouldRetry(attempt: 1, failure: TransportFailure(httpStatus: 401, message: "")))
        XCTAssertFalse(p.shouldRetry(attempt: 1, failure: TransportFailure(httpStatus: 403, message: "")))
        XCTAssertTrue(p.shouldRetry(attempt: 3, failure: TransportFailure(message: "net")))
        XCTAssertFalse(p.shouldRetry(attempt: 4, failure: TransportFailure(message: "net")))
    }
}

// MARK: ChatClient with a fake transport

final class PetFakeTransport: WebSocketTransport {
    var url: URL?
    var bearer: String?
    var sent: [String] = []
    var closed = false
    var handler: ((TransportEvent) -> Void)?
    func connect(url: URL, bearer: String?, handler: @escaping (TransportEvent) -> Void) {
        self.url = url; self.bearer = bearer; self.handler = handler
    }
    func send(_ text: String) { sent.append(text) }
    func close() { closed = true }
    func deliver(_ json: String) { handler?(.text(json)) }
}

final class PetChatClientTests: XCTestCase {
    var transports: [PetFakeTransport] = []
    var scheduled: [(TimeInterval, () -> Void)] = []

    private func makeClient(maxAttempts: Int = 3) -> ChatClient {
        let ep = try! ServerEndpoint.parse("http://127.0.0.1:8787").get()
        return ChatClient(
            endpoint: ep, token: { "mock-t" },
            makeTransport: {
                let t = PetFakeTransport(); self.transports.append(t); return t
            },
            policy: ReconnectPolicy(baseDelay: 1, maxDelay: 30, maxAttempts: maxAttempts),
            jitter: { 1 },
            schedule: { d, w in self.scheduled.append((d, w)) })
    }

    private let ready = #"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"r"}"#

    func testConnectUsesWSURLAndBearerThenReady() {
        let c = makeClient()
        c.connect(); c.flush()
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].url?.absoluteString, "ws://127.0.0.1:8787/ws/chat")
        XCTAssertEqual(transports[0].bearer, "mock-t")
        XCTAssertEqual(c.state.phase, .connecting)
        transports[0].deliver(ready); c.flush()
        XCTAssertEqual(c.state.phase, .connected)
        XCTAssertEqual(c.state.roomID, "r")
    }

    func testSendRefusals() {
        let c = makeClient()
        XCTAssertEqual(c.send(text: "hi"), .failure(.notConnected))
        XCTAssertEqual(c.send(text: "  "), .failure(.invalidText(.empty)))
        c.connect(); c.flush()
        transports[0].deliver(ready); c.flush()
        guard case let .success(id) = c.send(text: "안녕") else { return XCTFail("send failed") }
        XCTAssertTrue(id.hasPrefix("g-"))
        XCTAssertEqual(c.send(text: "again"), .failure(.busy))
        let frame = transports[0].sent.last!
        XCTAssertTrue(frame.contains("\"client_msg_id\":\"\(id)\""))
        XCTAssertTrue(frame.contains("\"room_id\":\"r\""))
    }

    func testStopSendsFrameOnlyWhileBusy() {
        let c = makeClient()
        c.connect(); c.flush()
        transports[0].deliver(ready); c.flush()
        c.stop(); c.flush()
        XCTAssertTrue(transports[0].sent.isEmpty)
        _ = c.send(text: "긴 답")
        c.stop(); c.flush()
        XCTAssertEqual(transports[0].sent.last, #"{"room_id":"r","type":"stop"}"#)
        XCTAssertTrue(c.state.turns[0].stopRequested)
    }

    func testDropMidTurnReconnectsWithBackoffAndResetsOnReady() {
        let c = makeClient()
        c.connect(); c.flush()
        transports[0].deliver(ready); c.flush()
        _ = c.send(text: "q")
        transports[0].handler?(.closed(TransportFailure(message: "reset"))); c.flush()
        XCTAssertEqual(c.state.phase, .reconnecting(attempt: 1))
        XCTAssertEqual(c.state.turns[0].status, .interrupted)
        XCTAssertEqual(scheduled.last!.0, 1)  // (an earlier entry is the ping timer)
        scheduled.last!.1(); c.flush()
        XCTAssertEqual(transports.count, 2)
        transports[1].handler?(.closed(TransportFailure(message: "refused"))); c.flush()
        XCTAssertEqual(c.state.phase, .reconnecting(attempt: 2))
        XCTAssertEqual(scheduled.last!.0, 2)
        scheduled.last!.1(); c.flush()
        transports[2].deliver(ready); c.flush()
        XCTAssertEqual(c.state.phase, .connected)
        // after a successful ready the counter restarts at 1
        transports[2].handler?(.closed(nil)); c.flush()
        XCTAssertEqual(c.state.phase, .reconnecting(attempt: 1))
    }

    func testStaleTransportEventsAreIgnored() {
        let c = makeClient()
        c.connect(); c.flush()
        transports[0].handler?(.closed(TransportFailure(message: "x"))); c.flush()
        scheduled[0].1(); c.flush()
        transports[0].deliver(ready); c.flush()  // late frame from the dead connection
        XCTAssertNotEqual(c.state.phase, .connected)
    }

    func testHTTP401StopsRetryingAndShowsLoginNotice() {
        let c = makeClient()
        c.connect(); c.flush()
        transports[0].handler?(.closed(TransportFailure(httpStatus: 401, message: "401"))); c.flush()
        XCTAssertEqual(c.state.phase, .authFailed)
        XCTAssertEqual(c.state.notice, "로그인이 필요해요.")
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testGivesUpAfterMaxAttempts() {
        let c = makeClient(maxAttempts: 2)
        c.connect(); c.flush()
        for n in 0..<3 {
            transports[n].handler?(.closed(TransportFailure(message: "down"))); c.flush()
            if n < 2 { scheduled.last!.1(); c.flush() }
        }
        XCTAssertEqual(c.state.phase, .disconnected)
        XCTAssertNotNil(c.state.notice)
    }

    func testDisconnectClosesAndCancelsRetry() {
        let c = makeClient()
        c.connect(); c.flush()
        transports[0].handler?(.closed(TransportFailure(message: "x"))); c.flush()
        c.disconnect(); c.flush()
        scheduled[0].1(); c.flush()  // timer fires after the user disconnected
        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(c.state.phase, .disconnected)
    }

    func testPingScheduledAfterReady() {
        let c = makeClient()
        c.connect(); c.flush()
        transports[0].deliver(ready); c.flush()
        XCTAssertEqual(scheduled.last?.0, 30)
        scheduled.last!.1(); c.flush()
        XCTAssertEqual(transports[0].sent.last, #"{"type":"ping"}"#)
    }
}

final class PetWSFramingTests: XCTestCase {
    private func serverFrame(opcode: UInt8, payload: [UInt8], fin: Bool = true) -> Data {
        var d = Data([(fin ? 0x80 : 0) | opcode])
        if payload.count < 126 {
            d.append(UInt8(payload.count))
        } else {
            d.append(126); d.append(UInt8(payload.count >> 8)); d.append(UInt8(payload.count & 0xff))
        }
        d.append(contentsOf: payload)
        return d
    }

    func testClientFrameIsMaskedAndRoundTrips() {
        let key: [UInt8] = [1, 2, 3, 4]
        let f = [UInt8](WSEncoder.text("안녕", maskKey: key))
        XCTAssertEqual(f[0], 0x81)
        XCTAssertEqual(f[1] & 0x80, 0x80)
        XCTAssertEqual(Array(f[2..<6]), key)
        let unmasked = (0..<(f.count - 6)).map { f[6 + $0] ^ key[$0 % 4] }
        XCTAssertEqual(String(decoding: unmasked, as: UTF8.self), "안녕")
    }

    func testLargeClientFrameUses16BitLength() {
        let f = [UInt8](WSEncoder.clientFrame(opcode: 1, payload: Data(repeating: 0x61, count: 300), maskKey: [0, 0, 0, 0]))
        XCTAssertEqual(f[1], 0x80 | 126)
        XCTAssertEqual(Int(f[2]) << 8 | Int(f[3]), 300)
    }

    func testDecodesSplitAndMultipleFrames() throws {
        var d = WSDecoder()
        let a = serverFrame(opcode: 1, payload: Array("hello".utf8))
        let b = serverFrame(opcode: 9, payload: [7])
        let all = a + b
        XCTAssertEqual(try d.feed(all.prefix(3)), [])
        XCTAssertEqual(try d.feed(all.dropFirst(3)), [.text("hello"), .ping(Data([7]))])
    }

    func testFragmentedTextMessage() throws {
        var d = WSDecoder()
        let m1 = serverFrame(opcode: 1, payload: Array("ab".utf8), fin: false)
        let m2 = serverFrame(opcode: 0, payload: Array("cd".utf8), fin: true)
        XCTAssertEqual(try d.feed(m1 + m2), [.text("abcd")])
    }

    func testRejectsBadFrames() {
        var d = WSDecoder()
        XCTAssertThrowsError(try d.feed(Data([0x81, 0x80, 0, 0, 0, 0])))  // masked server frame
        var d2 = WSDecoder()
        XCTAssertThrowsError(try d2.feed(Data([0xC1, 0x00])))  // reserved bit
        var d3 = WSDecoder()
        XCTAssertThrowsError(try d3.feed(Data([0x83, 0x00])))  // unknown opcode
        var d4 = WSDecoder()
        XCTAssertThrowsError(try d4.feed(Data([0x81, 127, 0, 0, 0, 0, 0, 0x7f, 0xff, 0xff])))  // too large
        var d5 = WSDecoder()
        XCTAssertThrowsError(try d5.feed(serverFrame(opcode: 1, payload: [0xff, 0xfe])))  // invalid UTF-8
        var d6 = WSDecoder()
        XCTAssertThrowsError(try d6.feed(serverFrame(opcode: 0, payload: [1])))  // continuation without start
    }

    func testCloseCode() throws {
        var d = WSDecoder()
        XCTAssertEqual(try d.feed(serverFrame(opcode: 8, payload: [0x03, 0xe8])), [.close(code: 1000)])
    }
}
