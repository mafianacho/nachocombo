import Foundation
import XCTest
@testable import NachoComboCore

/// The chat bubble's content rules (the confirmed web mockup's scenes, ported): Korean tool names, comma amounts,
/// one place for a task's state, memory lines in the order things happened, file chips.
final class PetTranscriptTests: XCTestCase {
    private func signedIn() -> PetSessionState {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.phase = .connected
        return st
    }

    private func text(_ items: [PetChatItem]) -> [String] {
        items.map { item in
            switch item {
            case let .older(loading): return loading ? "older…" : "older"
            case let .hello(title, examples): return "hello \(title) [\(examples.joined(separator: "|"))]"
            case let .mine(t, a, past): return "mine\(past ? "(past)" : "") \(t)\(a.isEmpty ? "" : " +\(a.joined(separator: ","))")"
            case let .nacho(t, past, streaming): return "nacho\(past ? "(past)" : "")\(streaming ? "(streaming)" : "") \(t)"
            case let .line(l): return "line.\(l.kind) \(l.plainText)"
            case let .files(f, mine): return "files\(mine ? "(mine)" : "") " + f.map { "\($0.name)\($0.deleted ? "(지워짐)" : "")" }.joined(separator: ",")
            case let .card(c): return "card \(c.title) [\(c.options.map { $0.label }.joined(separator: "|"))] \(c.status ?? "-")"
            case let .note(n): return "note \(n)"
            case let .divider(d): return "divider \(d)"
            case let .requestChip(c): return "chip \(c)"
            case let .answerActions(id, open): return "actions \(id)\(open ? "(open)" : "")"
            case let .sentContext(rows): return "sent \(rows.count)"
            case let .selectionPreview(p): return "preview \(p.title)"
            case .selectionIntro: return "intro"
            }
        }
    }

    func testFirstScreenIsAQuestionWithShortExampleChips() {
        let items = PetTranscript.items(signedIn(), undoSecondsLeft: { _ in nil })
        XCTAssertEqual(text(items), ["hello 무엇을 도와드릴까요? [창 왼쪽으로 붙여 줘|킵 어웨이크 켜 줘|이 캡처 뭐야?]"])
    }

    func testToolLinesUseKoreanNamesAndKeepTheRawNameAsTooltip() {
        var st = signedIn()
        var turn = ChatTurn(clientMsgID: "c1", userText: "맥북 배터리 오래 쓰는 법")
        turn.status = .streaming
        turn.tools = [ToolStep(callID: "1", name: "search_web", finished: true), ToolStep(callID: "2", name: "read_page"),
                      ToolStep(callID: "3", name: PetCommands.arrangeWindow, finished: true, isError: true)]
        st.chat.turns = [turn]
        guard case let .line(l)? = PetTranscript.items(st, undoSecondsLeft: { _ in nil }).first(where: {
            if case let .line(l) = $0 { return l.kind == .tool }; return false
        }) else { return XCTFail("no tool line") }
        XCTAssertEqual(l.plainText, "웹 검색 ✓ · 페이지 읽기 … · 창 배치 ✕")
        XCTAssertEqual(l.parts.compactMap { $0.tooltip }, ["search_web", "read_page", "combo_arrange_window"])
        XCTAssertFalse(l.plainText.contains("_"), "no raw tool names on screen")
        XCTAssertEqual(PetText.toolName("something_new"), "도구")
    }

    func testAmountsHaveThousandsSeparators() {
        XCTAssertEqual(PetText.amount(39000, currency: nil), "39,000원")
        XCTAssertEqual(PetText.amount(1_234_567, currency: "KRW"), "1,234,567원")
        XCTAssertEqual(PetText.amount(990, currency: "USD"), "990 USD")
        XCTAssertEqual(PetText.number(-12000), "-12,000")
        let card = PetCard.decode(["id": "a1", "kind": "approval", "status": "pending",
                                   "payload": ["title": "결제할까요?", "merchant": "선물가게", "amount": 39000]])
        XCTAssertEqual(card.detail, "선물가게 · 39,000원")
        let usage = PetUsage(remaining: 1200, availableToStart: nil, blockReason: nil, lightChatUsed: 48, lightChatCap: 50,
                             planID: nil, allowance: 20000, period: nil, resetAt: nil, exhausted: false, lowBalance: true)
        XCTAssertEqual(usage.summary, "크레딧 1,200/20,000 · 가벼운 대화 48/50 · 얼마 안 남았어요")
    }

    func testTaskAndChoiceStateShowOnlyInTheHeader() {
        var st = signedIn()
        var turn = ChatTurn(clientMsgID: "c1", userText: "내일 저녁 파스타집 예약해 줘")
        turn.status = .done
        turn.taskID = "t1"
        turn.cardIDs = ["k1"]
        st.chat.turns = [turn]
        st.chat.task = PetTask(id: "t1", state: "waiting", title: "파스타집 예약", step: nil, waitReason: "input", pendingRequestID: "k1", failure: nil)
        st.chat.cards = [PetCard(id: "k1", kind: "choice", status: "pending", version: 1, taskID: "t1", title: "어느 시간이 좋아요?", detail: nil,
                                 options: [.init(id: "o1", label: "저녁 7시"), .init(id: "o2", label: "저녁 8시")], multiple: false,
                                 answeredAction: nil, expiresAt: nil)]
        st.chat.usage = PetUsage(remaining: 180, availableToStart: nil, blockReason: nil, lightChatUsed: nil, lightChatCap: nil, planID: nil,
                                 allowance: nil, period: nil, resetAt: nil, exhausted: false, lowBalance: false)
        let items = text(PetTranscript.items(st, undoSecondsLeft: { _ in nil }))
        XCTAssertEqual(items, ["mine 내일 저녁 파스타집 예약해 줘", "nacho 일로 맡았어요. 진행 상황은 여기에 보여 드릴게요.",
                               "card 어느 시간이 좋아요? [저녁 7시|저녁 8시] -"])
        XCTAssertFalse(items.joined().contains("답을 기다려요"))
        let header = PetTranscript.headerStatus(st)
        XCTAssertEqual(header.text, "파스타집 예약 · 답을 기다려요")
        XCTAssertEqual(header.dot, .wait)
        XCTAssertNil(PetTranscript.headerCredits(st), "the task's state takes the space")
        // An approval stays on the phone: no options, the note says where.
        st.chat.cards[0].kind = "approval"
        guard case let .card(c)? = PetTranscript.items(st, undoSecondsLeft: { _ in nil }).last else { return XCTFail() }
        XCTAssertEqual(c.status, "휴대폰의 나초 앱에서 승인해 주세요")
        XCTAssertTrue(c.options.isEmpty)
        st.chat.task = nil
        XCTAssertEqual(PetTranscript.headerCredits(st), "크레딧 180")
    }

    func testMemoryLinesFollowTheFlowAndForgetChangesTheLineInPlace() {
        var st = signedIn()
        var t1 = ChatTurn(clientMsgID: "c1", userText: "나 요즘 고양이 키워")
        t1.assistantText = "와, 좋겠어요!"
        t1.status = .done
        var t2 = ChatTurn(clientMsgID: "c2", userText: "내가 좋아하는 음식 알아?")
        t2.assistantText = "매운 음식을 좋아하신다고 기억해요."
        t2.status = .done
        t2.usedMemoryIDs = ["m9"]
        st.chat.turns = [t1, t2]
        var note = PetMemoryNote(updateID: "u1", action: "created", items: [.init(memoryID: "m1", kind: "fact", preview: "고양이를 키워요")],
                                 source: "chat", visibility: nil, afterSeq: nil, turnClientID: "c1", forgottenAt: nil)
        var note2 = note
        note2.updateID = "u2"
        note2.items = [.init(memoryID: "m2", kind: "fact", preview: "매운 음식 대신 순한 맛")]
        note2.turnClientID = "c2"
        st.chat.memoryNotes = [note, note2]
        XCTAssertEqual(text(PetTranscript.items(st, undoSecondsLeft: { _ in nil })), [
            "mine 나 요즘 고양이 키워", "nacho 와, 좋겠어요!", "line.memory 기억했어요: 고양이를 키워요 · 잊어 줘",
            "mine 내가 좋아하는 음식 알아?", "nacho 매운 음식을 좋아하신다고 기억해요.",
            "line.memory 이 답에 기억 1개를 썼어요 · 기억이 틀렸어요", "line.memory 기억했어요: 매운 음식 대신 순한 맛 · 잊어 줘"])
        note.forgottenAt = Date()
        st.chat.memoryNotes[0] = note
        let after = text(PetTranscript.items(st, undoSecondsLeft: { $0 == "u1" ? 7 : nil }))
        XCTAssertEqual(after[2], "line.memory 잊었어요: 고양이를 키워요 · 7초 안에 되돌리기")
        XCTAssertEqual(after.filter { $0.contains("고양이를 키워요") }.count, 1, "never two lines for one memory")
        XCTAssertEqual(text(PetTranscript.items(st, undoSecondsLeft: { _ in nil }))[2], "line.memory 잊었어요: 고양이를 키워요")
    }

    func testFileChipsOnlyLinkWebFilesAndMarkDeletedOnes() {
        var st = signedIn()
        var turn = ChatTurn(clientMsgID: "c1", userText: "회의 메모를 표로 정리해 줘")
        turn.status = .done
        turn.assistantText = "정리했어요."
        turn.files = [PetFileLink(attachmentID: "a", name: "회의 정리.csv", kind: "file", mime: nil, bytes: nil, url: "https://x.test/a", deleted: false, byNacho: true),
                      PetFileLink(attachmentID: "b", name: "예전 캡처.png", kind: "image", mime: nil, bytes: nil, url: nil, deleted: true, byNacho: false),
                      PetFileLink(attachmentID: "c", name: "local.txt", kind: "file", mime: nil, bytes: nil, url: "file:///etc/passwd", deleted: false, byNacho: true)]
        st.chat.turns = [turn]
        guard case let .files(chips, mine)? = PetTranscript.items(st, undoSecondsLeft: { _ in nil }).last else { return XCTFail() }
        XCTAssertFalse(mine)
        XCTAssertEqual(chips.map { $0.url?.absoluteString }, ["https://x.test/a", nil, nil])
        XCTAssertEqual(chips.map { $0.deleted }, [false, true, false])
        XCTAssertTrue(chips[1].isImage)
    }

    func testStreamingAndFailures() {
        var st = signedIn()
        var turn = ChatTurn(clientMsgID: "c1", userText: "오늘 일정 알려줘")
        turn.status = .failed("서버가 답을 만들지 못했어요. 잠시 뒤 다시 시도해 주세요.")
        var t2 = ChatTurn(clientMsgID: "c2", userText: "다시")
        t2.status = .streaming
        t2.assistantText = "오늘은"
        st.chat.turns = [turn, t2]
        st.chat.activity = .typing
        XCTAssertEqual(text(PetTranscript.items(st, undoSecondsLeft: { _ in nil })), [
            "mine 오늘 일정 알려줘", "line.danger 서버가 답을 만들지 못했어요. 잠시 뒤 다시 시도해 주세요.",
            "mine 다시", "nacho(streaming) 오늘은"])
        XCTAssertEqual(PetTranscript.headerStatus(st).text, "답하는 중")
        st.auth = .signedOut
        XCTAssertEqual(PetTranscript.headerStatus(st).text, "로그인 전")
    }
}
