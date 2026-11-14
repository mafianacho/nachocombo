import Foundation
import XCTest

@testable import NachoComboCore

// NACHO-137 QA: extra end-to-end cases for NACHO-134 (not product code).
private func fj(_ raw: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
}

final class PetBusySendQATests: XCTestCase {
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
        http.on("POST", "/api/v1/media/uploads", 201, #"{"attachment_id":"0193aaaa-0000-7000-8000-0000000000a1","kind":"file","name":"n.md","mime":"text/markdown","bytes":2}"#)
        var s = PetSettings()
        s.serverMode = .mock
        s.allowComboControl = false
        session = PetSession(settings: s, http: http, secrets: MemorySecretStore(), browser: browser,
                             makeTransport: factory.make, executor: PetRecordingExecutor(), random: PetFixedRandom())
        session.signIn(); settle()
        chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(#"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"r"}"#); settle()
    }

    private func settle() { for _ in 0..<8 { session.flush(); Thread.sleep(forTimeInterval: 0.02) } }
    private var messages: [[String: Any]] { chat.sent.map(fj).filter { $0["type"] as? String == "message" } }
    private var texts: [String] { messages.compactMap { $0["text"] as? String } }
    private var stops: Int { chat.sent.map(fj).filter { $0["type"] as? String == "stop" }.count }

    private func startBusy() {
        let e = expectation(description: "first")
        session.send(text: "첫 질문") { XCTAssertNil($0); e.fulfill() }
        wait(for: [e], timeout: 5)
        let id = messages.last?["client_msg_id"] as? String ?? "?"
        chat.deliver(#"{"type":"turn_started","room_id":"r","turn_id":"t","duplicate":false,"client_id":"\#(id)"}"#); settle()
        XCTAssertTrue(session.snapshot.chat.isBusy)
    }
    private func lastID() -> String { session.snapshot.chat.turns.last?.clientMsgID ?? "?" }
    private func queue(_ t: String) -> String? {
        var out: String? = "unset"
        let e = expectation(description: "q")
        session.sendOrQueue(text: t) { out = $0; e.fulfill() }
        wait(for: [e], timeout: 5); settle(); return out
    }
    private func file() throws -> PetOutgoingFile { try PetMedia.prepare(name: "n.md", data: Data("hi".utf8)).get() }

    func testErrorEndAlsoSendsQueuedExactlyOnce() {
        startBusy()
        XCTAssertNil(queue("오류 뒤에도"))
        chat.deliver(#"{"type":"error","room_id":"r","client_id":"\#(lastID())","code":"upstream_error","message":"x"}"#); settle()
        XCTAssertEqual(texts, ["첫 질문", "오류 뒤에도"])
        XCTAssertNil(session.snapshot.queuedText)
        XCTAssertEqual(stops, 0)
        settle()
        XCTAssertEqual(texts.filter { $0 == "오류 뒤에도" }.count, 1, "no duplicate send")
    }

    func testDoneThenStrayFramesDoNotResend() {
        startBusy()
        XCTAssertNil(queue("한 번만"))
        let id = lastID()
        chat.deliver(#"{"type":"done","room_id":"r","stopped":false,"client_id":"\#(id)"}"#); settle()
        chat.deliver(#"{"type":"done","room_id":"r","stopped":false,"client_id":"\#(id)"}"#); settle()
        XCTAssertEqual(texts.filter { $0 == "한 번만" }.count, 1)
    }

    func testQueueAfterCancelStillWorks() {
        startBusy()
        XCTAssertNil(queue("취소할 글")); session.cancelQueued(); settle()
        XCTAssertNil(queue("새 글")); XCTAssertEqual(session.snapshot.queuedText, "새 글")
        chat.deliver(#"{"type":"done","room_id":"r","stopped":false,"client_id":"\#(lastID())"}"#); settle()
        XCTAssertEqual(texts, ["첫 질문", "새 글"])
    }

    func testAttachmentOnlyQueueSendsWithChip() throws {
        startBusy()
        XCTAssertNil(session.attach(try file()))
        XCTAssertNil(queue(""))
        XCTAssertEqual(session.snapshot.queuedText, "")
        XCTAssertEqual(session.snapshot.pending.count, 1, "chip stays while waiting")
        let items = PetTranscript.items(session.snapshot, undoSecondsLeft: { _ in nil })
        XCTAssertTrue(items.contains(.mine(text: "첨부 파일 1개", attachments: [], past: true)))
        chat.deliver(#"{"type":"done","room_id":"r","stopped":false,"client_id":"\#(lastID())"}"#)
        Thread.sleep(forTimeInterval: 0.5); settle()
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages.last?["attachments"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(session.snapshot.pending.isEmpty)
    }

    func testChipRemovedAfterWaitingGivesTheEmptyTextBack() throws {
        startBusy()
        XCTAssertNil(session.attach(try file()))
        XCTAssertNil(queue(""))
        session.removePending(id: session.snapshot.pending[0].id); settle()
        chat.deliver(#"{"type":"done","room_id":"r","stopped":false,"client_id":"\#(lastID())"}"#); settle()
        XCTAssertEqual(messages.count, 1, "an empty message is not sent")
        XCTAssertNil(session.snapshot.queuedText)
        XCTAssertNotNil(session.snapshot.returnedText)
        print("QA-NOTE returnedText=\(String(describing: session.snapshot.returnedText)) notice=\(String(describing: session.snapshot.notice))")
    }

    func testChipAddedAfterWaitingGoesWithTheText() throws {
        startBusy()
        XCTAssertNil(queue("글과 함께"))
        XCTAssertNil(session.attach(try file()))
        chat.deliver(#"{"type":"done","room_id":"r","stopped":false,"client_id":"\#(lastID())"}"#)
        Thread.sleep(forTimeInterval: 0.5); settle()
        XCTAssertEqual(texts.last, "글과 함께")
        XCTAssertEqual((messages.last?["attachments"] as? [[String: Any]])?.count, 1)
    }

    func testNormalSendAndStopStillWork() {
        let e = expectation(description: "s")
        session.send(text: "평상시") { XCTAssertNil($0); e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(texts, ["평상시"])
        let id = messages.last?["client_msg_id"] as? String ?? "?"
        chat.deliver(#"{"type":"turn_started","room_id":"r","turn_id":"t","duplicate":false,"client_id":"\#(id)"}"#); settle()
        session.stop(); settle()
        XCTAssertEqual(stops, 1)
        XCTAssertNil(session.snapshot.queuedText)
    }
}
