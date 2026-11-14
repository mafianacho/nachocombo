import Foundation
import XCTest

@testable import NachoComboCore

// NACHO-134: text sent while Nacho is answering waits and goes out when the answer ends. It never stops the answer.

private func frameJSON(_ raw: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
}

final class PetBusySendTests: XCTestCase {
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    var http: PetStubHTTP!
    var factory: PetTransportFactory!
    var browser: PetFakeBrowser!  // PetSession holds it weakly
    var session: PetSession!
    var chat: PetFakeTransport!

    override func setUp() {
        http = PetStubHTTP()
        factory = PetTransportFactory()
        browser = PetFakeBrowser()
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        http.on("POST", "/api/v1/agents/\(agent)/connector-binding", 200, #"{"token":"nct_feed","endpoint":"/ws/connector"}"#)
        var s = PetSettings()
        s.serverMode = .mock
        s.allowComboControl = false
        session = PetSession(settings: s, http: http, secrets: MemorySecretStore(), browser: browser,
                             makeTransport: factory.make, executor: PetRecordingExecutor(), random: PetFixedRandom())
        session.signIn(); settle()
        chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"r"}"#); settle()
    }

    private func settle() { for _ in 0..<6 { session.flush(); Thread.sleep(forTimeInterval: 0.01) } }

    private var types: [String] { chat.sent.compactMap { frameJSON($0)["type"] as? String } }
    private var messageTexts: [String] { chat.sent.map(frameJSON).filter { $0["type"] as? String == "message" }.compactMap { $0["text"] as? String } }

    /// One turn is running (the first message is out and the server started it).
    private func startBusyTurn() {
        let sent = expectation(description: "first send")
        session.send(text: "첫 질문") { XCTAssertNil($0); sent.fulfill() }
        wait(for: [sent], timeout: 5)
        let id = chat.sent.map(frameJSON).last { $0["type"] as? String == "message" }?["client_msg_id"] as? String ?? "?"
        chat.deliver(#"{"type":"turn_started","room_id":"r","turn_id":"t","duplicate":false,"client_id":"\#(id)"}"#); settle()
        XCTAssertTrue(session.snapshot.chat.isBusy)
    }

    private func finishTurn(stopped: Bool = false) {
        let id = session.snapshot.chat.turns.last?.clientMsgID ?? "?"
        chat.deliver(#"{"type":"done","room_id":"r","stopped":\#(stopped),"client_id":"\#(id)"}"#); settle()
    }

    private func queue(_ text: String) -> String? {
        var out: String? = "unset"
        let e = expectation(description: "queue")
        session.sendOrQueue(text: text) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        settle()
        return out
    }

    func testTextWhileBusyWaitsAndNeverStopsTheAnswer() {
        startBusyTurn()
        XCTAssertNil(queue("추가로 이것도"))
        XCTAssertEqual(session.snapshot.queuedText, "추가로 이것도")
        XCTAssertFalse(types.contains("stop"), "Enter with text must not stop the answer")
        XCTAssertEqual(messageTexts, ["첫 질문"], "nothing is sent while the answer runs")
        XCTAssertTrue(session.snapshot.chat.isBusy)
    }

    func testQueuedTextGoesOutWhenTheAnswerEnds() {
        startBusyTurn()
        XCTAssertNil(queue("추가로 이것도"))
        finishTurn(); settle()
        XCTAssertEqual(messageTexts, ["첫 질문", "추가로 이것도"])
        XCTAssertNil(session.snapshot.queuedText)
        XCTAssertEqual(session.snapshot.chat.turns.last?.userText, "추가로 이것도")
        XCTAssertFalse(types.contains("stop"))
    }

    func testQueuedTextAlsoGoesOutAfterAStoppedAnswer() {
        startBusyTurn()
        XCTAssertNil(queue("멈춘 뒤에도 보내요"))
        session.stop(); settle()
        XCTAssertEqual(types.filter { $0 == "stop" }.count, 1, "the stop button still stops")
        finishTurn(stopped: true); settle()
        XCTAssertEqual(messageTexts.last, "멈춘 뒤에도 보내요")
    }

    func testCancelledQueueSendsNothing() {
        startBusyTurn()
        XCTAssertNil(queue("보내지 말아요"))
        session.cancelQueued(); settle()
        XCTAssertNil(session.snapshot.queuedText)
        finishTurn(); settle()
        XCTAssertEqual(messageTexts, ["첫 질문"])
    }

    func testASecondQueuedTextJoinsTheFirstOnANewLine() {
        startBusyTurn()
        XCTAssertNil(queue("하나"))
        XCTAssertNil(queue("둘"))
        XCTAssertEqual(session.snapshot.queuedText, "하나\n둘")
        finishTurn(); settle()
        XCTAssertEqual(messageTexts, ["첫 질문", "하나\n둘"])
    }

    func testEmptyTextIsNotQueued() {
        startBusyTurn()
        XCTAssertNotNil(queue("   "))
        XCTAssertNil(session.snapshot.queuedText)
    }

    func testNotBusySendsAtOnce() {
        XCTAssertNil(queue("바로 보내요"))
        XCTAssertEqual(messageTexts, ["바로 보내요"])
        XCTAssertNil(session.snapshot.queuedText)
    }

    func testARefusedAutomaticSendGivesTheTextBack() {
        startBusyTurn()
        XCTAssertNil(queue("돌려받을 글"))
        // The connection drops while answering: the turn ends as interrupted and the automatic send is refused.
        chat.handler?(.closed(nil)); settle()
        let st = session.snapshot
        XCTAssertNil(st.queuedText)
        XCTAssertEqual(st.returnedText, "돌려받을 글", "the text is not lost: the window puts it back in the input")
        XCTAssertFalse(types.contains("stop"))
        session.clearReturned(); settle()
        XCTAssertNil(session.snapshot.returnedText)
    }

    func testQueuedLinesInTheTranscript() {
        var st = PetSessionState()
        st.auth = .signedIn
        st.queuedText = "나중에 보낼 글"
        let items = PetTranscript.items(st, undoSecondsLeft: { _ in nil })
        XCTAssertTrue(items.contains(.mine(text: "나중에 보낼 글", attachments: [], past: true)))
        let note = items.compactMap { i -> PetChatLine? in if case let .line(l) = i { return l }; return nil }.first
        XCTAssertEqual(note?.parts.map { $0.text }, [PetTranscript.queuedNote, " · ", "취소"])
        XCTAssertEqual(note?.parts.last?.link, PetLinks.url("cancelqueued"))
        st.queuedText = nil
        XCTAssertFalse(PetTranscript.items(st, undoSecondsLeft: { _ in nil }).contains { if case .line = $0 { return true }; return false })
    }
}

final class PetMarkdownTests: XCTestCase {
    func testBoldRendersWithoutMarkers() {
        let spans = PetMarkdown.spans("이건 **중요해요** 정말")
        XCTAssertEqual(spans.map { $0.text }, ["이건 ", "중요해요", " 정말"])
        XCTAssertEqual(spans.map { $0.bold }, [false, true, false])
        XCTAssertFalse(spans.map { $0.text }.joined().contains("*"))
    }

    func testLineBreaksAndSpacesStay() {
        let text = PetMarkdown.spans("첫 줄\n\n  둘째 **줄**\n셋째").map { $0.text }.joined()
        XCTAssertEqual(text, "첫 줄\n\n  둘째 줄\n셋째")
    }

    func testItalicCodeAndLink() {
        let spans = PetMarkdown.spans("*기울임* `코드` [문서](https://example.com/a)")
        XCTAssertTrue(spans.contains { $0.text == "기울임" && $0.italic })
        XCTAssertTrue(spans.contains { $0.text == "코드" && $0.code })
        XCTAssertTrue(spans.contains { $0.text == "문서" && $0.link?.absoluteString == "https://example.com/a" })
    }

    func testOnlyWebAndMailLinksStayClickable() {
        let spans = PetMarkdown.spans("[승인](nachopet://card?id=c1&action=approve) [파일](file:///Applications/Calculator.app) [스크립트](javascript:alert(1)) [메일](mailto:a@b.co)")
        XCTAssertTrue(spans.contains { $0.text.contains("승인") && $0.link == nil })
        XCTAssertTrue(spans.contains { $0.text.contains("파일") && $0.link == nil })
        XCTAssertTrue(spans.contains { $0.text.contains("스크립트") && $0.link == nil })
        XCTAssertTrue(spans.contains { $0.text == "메일" && $0.link?.absoluteString == "mailto:a@b.co" })
        XCTAssertFalse(spans.contains { $0.link?.scheme == "nachopet" || $0.link?.scheme == "file" })
    }

    func testPlainTextAndHalfWrittenMarkersStayAsTyped() {
        XCTAssertEqual(PetMarkdown.spans("그냥 글"), [PetMarkdownSpan("그냥 글")])
        XCTAssertEqual(PetMarkdown.spans("아직 **쓰는 중").map { $0.text }.joined(), "아직 **쓰는 중")
        XCTAssertEqual(PetMarkdown.spans("").map { $0.text }.joined(), "")
    }
}

final class PetHeaderTooltipTests: XCTestCase {
    func testHeaderLineIsTheWholeStatusWithCredits() {
        var st = PetSessionState()
        st.auth = .failed("서버에 연결하는 중에 문제가 생겼어요. 잠시 뒤에 다시 해 주세요.")
        XCTAssertEqual(PetTranscript.headerLine(st), "서버에 연결하는 중에 문제가 생겼어요. 잠시 뒤에 다시 해 주세요.")
        st.auth = .signedIn
        XCTAssertEqual(PetTranscript.headerLine(st), PetTranscript.headerStatus(st).text + (PetTranscript.headerCredits(st).map { " · \($0)" } ?? ""))
    }
}
