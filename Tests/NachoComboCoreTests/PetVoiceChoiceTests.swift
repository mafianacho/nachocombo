import Foundation
import XCTest

@testable import NachoComboCore

// 선택 UI (cards by kind, numbers, keys, states) and 길게 눌러 말하기 (2 s ring vs click vs drag, spoken replies).
// Handoff A / 나초파더 1570802313768083457.

private let seoulNow = ISO8601DateFormatter().date(from: "2026-11-13T05:00:00Z")!  // 14:00 KST

private func card(_ kind: String, status: String = "pending", task: String? = "t1", multiple: Bool = false,
                  options: [(String, String)] = [("a", "저녁 7시"), ("b", "저녁 8시"), ("c", "저녁 9시")],
                  extra: [String: Any] = [:], top: [String: Any] = [:]) -> PetCard {
    var payload: [String: Any] = ["question": "어느 시간이 좋아요?", "multiple": multiple,
                                  "options": options.map { ["id": $0.0, "label": $0.1] }]
    for (k, v) in extra { payload[k] = v }
    var o: [String: Any] = ["id": "k-\(kind)", "kind": kind, "status": status, "version": 1, "payload": payload]
    if let t = task { o["task_id"] = t }
    for (k, v) in top { o[k] = v }
    return PetCard.decode(o)
}

final class PetCardRulesTests: XCTestCase {
    func testApprovalSaysWhatResultAndUndoThenRunAboveDeny() {
        let c = PetCard.decode(["id": "ap", "kind": "approval", "status": "pending", "version": 3, "expires_at": "2026-11-13T06:20:00Z",
                                "payload": ["title": "선물가게에서 결제할까요?", "action_type": "payment", "merchant": "선물가게", "amount": 39000,
                                            "reversibility": "conditional", "reversibility_text": "배송 전이면 취소할 수 있어요"]])
        XCTAssertEqual(PetCardStyle.of(c), .approval)
        XCTAssertEqual(PetCardRules.approvalSummary(c), ["무엇을: 결제 · 선물가게 · 39,000원", "되돌리기: 배송 전이면 취소할 수 있어요"])
        let rows = PetCardRules.rows(c)
        XCTAssertEqual(rows.map { "\($0.number) \($0.label) \($0.role)" }, ["1 실행 primary", "2 거절 quiet"])
        XCTAssertEqual(rows.map { $0.answer?.action }, ["approve", "deny"])
        let item = PetTranscript.card(c, now: seoulNow)
        XCTAssertTrue(item.options.allSatisfy { $0.link != nil }, "거절 is never disabled while it waits")
        XCTAssertEqual(item.hint, "숫자키를 누르고 Enter · 오후 3:20 KST까지")
        XCTAssertNil(item.detail, "the summary carries it")
        var noText = c
        noText.reversibilityText = nil
        noText.reversibility = "cannot_cancel"
        XCTAssertEqual(PetCardRules.approvalSummary(noText).last, "되돌리기: 되돌릴 수 없어요")
    }

    func testOneChoiceIsNumberedAndAClickAnswers() {
        let c = card("choice")
        let item = PetTranscript.card(c, now: seoulNow)
        XCTAssertEqual(item.style, .single)
        XCTAssertEqual(item.options.map { "\($0.number) \($0.label)" }, ["1 저녁 7시", "2 저녁 8시", "3 저녁 9시"])
        XCTAssertEqual(item.options[1].link, PetLinks.url("cardrow", ["id": "k-choice", "n": "2"]))
        XCTAssertEqual(PetCardRules.rows(c)[1].answer, PetCardAnswer(action: "choose", optionIDs: ["b"]))
        XCTAssertNil(item.confirm)
        // ask_choice (no task): the chosen label also goes to the chat as the next message.
        XCTAssertEqual(PetCardRules.rows(card("choice", task: nil))[1].answer?.followUpText, "저녁 8시")
    }

    func testSeveralChoicesTickThenConfirmInCardOrder() {
        let c = card("choice", task: nil, multiple: true)
        XCTAssertEqual(PetCardStyle.of(c), .multiple)
        var local = PetCardLocal()
        XCTAssertNil(PetCardRules.confirm(c, ticked: []))
        XCTAssertNil(PetTranscript.card(c, local: local, now: seoulNow).confirm?.link, "확정 waits for a tick")
        local.ticked = ["c", "a"]
        let item = PetTranscript.card(c, local: local, now: seoulNow)
        XCTAssertEqual(item.options.map { $0.marked }, [true, false, true])
        XCTAssertTrue(item.options.allSatisfy { $0.tickable })
        XCTAssertEqual(item.confirm?.label, "확정 (2개)")
        XCTAssertNotNil(item.confirm?.link)
        XCTAssertEqual(PetCardRules.confirm(c, ticked: local.ticked),
                       PetCardAnswer(action: "choose", optionIDs: ["a", "c"], followUpText: "저녁 7시, 저녁 9시"))
        XCTAssertEqual(item.hint, "숫자키로 고르고 Enter로 확정")
    }

    func testSuggestionsAreQuickRepliesThatSendTheirText() {
        let c = card("suggestions", task: nil, options: [("0", "내일로 미뤄 줘"), ("1", "지금 해 줘")])
        let item = PetTranscript.card(c, now: seoulNow)
        XCTAssertEqual(item.style, .suggestions)
        XCTAssertEqual(item.options.map { "\($0.number) \($0.label)" }, ["1 내일로 미뤄 줘", "2 지금 해 줘"])
        XCTAssertEqual(PetCardRules.rows(c)[0].answer, PetCardAnswer(action: "choose", optionIDs: ["0"], followUpText: "내일로 미뤄 줘"))
        XCTAssertNil(item.hint, "chips need no key hint")
    }

    // NACHO-36: an approval with `rule_options` offers 이번만 실행 / 실행하고 항상 허용 / 거절.
    private func ruleApproval(_ extra: [String: Any] = [:]) -> PetCard {
        var payload: [String: Any] = ["title": "배달앱 12,000원 결제할까요?", "action_type": "payment", "merchant": "배달앱", "amount": 12000,
                                      "rule_options": [["id": "pay_day", "summary": "하루 30,000원까지 묻지 않고 결제", "action_type": "payment"],
                                                       ["id": "pay_week", "summary": "배달앱 건당 20,000원 · 일주일 60,000원", "action_type": "payment"]]]
        for (k, v) in extra { payload[k] = v }
        return PetCard.decode(["id": "ra", "kind": "approval", "status": "pending", "version": 1, "task_id": "t1", "payload": payload])
    }

    func testApprovalWithRuleOptionsShowsOnceOrAlwaysChoices() {
        let c = ruleApproval()
        XCTAssertEqual(c.ruleOptions.map { $0.id }, ["pay_day", "pay_week"])
        let rows = PetCardRules.rows(c)
        XCTAssertEqual(rows.map { "\($0.number) \($0.label)" }, ["1 이번만 실행", "2 실행하고 항상 허용", "3 실행하고 항상 허용", "4 거절"])
        XCTAssertEqual(rows.map { $0.detail }, [nil, "하루 30,000원까지 묻지 않고 결제", "배달앱 건당 20,000원 · 일주일 60,000원", nil])
        XCTAssertEqual(rows.map { $0.answer }, [PetCardAnswer(action: "approve"), PetCardAnswer(action: "approve", allowRuleID: "pay_day"),
                                                PetCardAnswer(action: "approve", allowRuleID: "pay_week"), PetCardAnswer(action: "deny")])
        // the number keys reach the rule rows too (3 + Enter = the weekly rule)
        var local = PetCardLocal()
        XCTAssertEqual(PetCardKeys.handle(.digit(3), card: c, local: local), .highlight(3))
        local.highlighted = 3
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .answer(PetCardAnswer(action: "approve", allowRuleID: "pay_week")))
    }

    func testApprovalWithoutRuleOptionsIsUnchanged() {
        for extra in [["rule_options": []], ["rule_options": [["id": "x", "summary": ""]]]] as [[String: Any]] {
            let c = ruleApproval(extra)
            XCTAssertEqual(PetCardRules.rows(c).map { "\($0.number) \($0.label)" }, ["1 실행", "2 거절"])
        }
        let plain = PetCard.decode(["id": "pa", "kind": "approval", "status": "pending", "version": 1, "payload": ["title": "t"]])
        XCTAssertEqual(PetCardRules.rows(plain).map { $0.answer }, [PetCardAnswer(action: "approve"), PetCardAnswer(action: "deny")])
        // rule_options on other kinds of card is not read as approval rules
        XCTAssertTrue(card("choice").ruleOptions.isEmpty)
    }

    func testAnsweredApprovalMarksTheChosenRule() {
        var c = ruleApproval()
        c.status = "answered"
        c.answeredAction = "approve"
        c.answeredRuleID = "pay_week"
        XCTAssertEqual(PetCardRules.chosenNumbers(c), [3])
        c.answeredRuleID = nil
        XCTAssertEqual(PetCardRules.chosenNumbers(c), [1], "이번만 실행")
        c.answeredAction = "deny"
        XCTAssertEqual(PetCardRules.chosenNumbers(c), [4])
        let decoded = PetCard.decode(["id": "ra", "kind": "approval", "status": "answered", "version": 2, "answered_action": "approve",
                                      "answer": ["action": "approve", "allow_rule": ["rule_option_id": "pay_day"]],
                                      "payload": ["rule_options": [["id": "pay_day", "summary": "하루 30,000원"]]]])
        XCTAssertEqual(decoded.answeredRuleID, "pay_day")
        XCTAssertEqual(PetCardRules.chosenNumbers(decoded), [2])
    }

    func testAnswerRequestCarriesAllowRuleOnlyWithApprove() {
        let e = ServerEndpoint(base: URL(string: "https://api.example.com")!)
        let c = ruleApproval()
        let j = PetStubHTTP.json(PetServerAPI.answerCardRequest(e, bearer: "t", card: c, action: "approve", allowRuleID: "pay_week"))
        XCTAssertEqual(j["action"] as? String, "approve")
        XCTAssertEqual((j["allow_rule"] as? [String: Any])?["rule_option_id"] as? String, "pay_week")
        XCTAssertEqual(j["expected_version"] as? Int, 1)
        XCTAssertNil(PetStubHTTP.json(PetServerAPI.answerCardRequest(e, bearer: "t", card: c, action: "approve"))["allow_rule"], "이번만 실행: no rule")
        XCTAssertNil(PetStubHTTP.json(PetServerAPI.answerCardRequest(e, bearer: "t", card: c, action: "deny", allowRuleID: "pay_week"))["allow_rule"])
    }

    func testRuleProposalApplyOrNo() {
        let one = PetCard.decode(["id": "r1", "kind": "rule_proposal", "status": "pending", "version": 1,
                                  "payload": ["said_text": "3만 원까지 괜찮아", "rule_options": [["id": "o1", "summary": "배달앱에서 건당 30,000원 이하"]]]])
        let item = PetTranscript.card(one, now: seoulNow)
        XCTAssertEqual(item.style, .ruleProposal)
        XCTAssertEqual(item.options.map { "\($0.number) \($0.label) \($0.role)" }, ["1 적용 primary", "2 아니요 quiet"])
        XCTAssertEqual(item.summary, ["배달앱에서 건당 30,000원 이하"], "the rule itself, above the buttons")
        XCTAssertEqual(item.detail, "“3만 원까지 괜찮아”라고 하셨어요. 적용하면 이 범위는 다시 묻지 않아요.")
        XCTAssertEqual(PetCardRules.rows(one).map { $0.answer }, [PetCardAnswer(action: "choose", optionIDs: ["o1"]), PetCardAnswer(action: "dismiss")])
        let two = PetCard.decode(["id": "r2", "kind": "rule_proposal", "status": "pending", "version": 1,
                                  "payload": ["rule_options": [["id": "o1", "summary": "건당 20,000원"], ["id": "o2", "summary": "일주일 60,000원"]]]])
        XCTAssertEqual(PetCardRules.rows(two).map { "\($0.number) \($0.label)" }, ["1 건당 20,000원", "2 일주일 60,000원", "3 아니요"])
        var done = one
        done.status = "answered"
        done.answeredAction = "choose"
        done.answeredOptionIDs = ["o1"]
        XCTAssertEqual(PetTranscript.card(done, now: seoulNow).status, "규칙을 만들었어요")
        XCTAssertEqual(PetTranscript.card(done, now: seoulNow).options.map { $0.chosen }, [true, false])
        done.status = "dismissed"
        XCTAssertEqual(PetTranscript.card(done, now: seoulNow).status, "만들지 않았어요")
    }

    func testStatesSendingFailedRetryAnsweredExpiredSupersededDismissed() {
        let c = card("choice")
        var local = PetCardLocal()
        local.sending = PetCardAnswer(action: "choose", optionIDs: ["b"])
        local.lastAnswer = local.sending
        var item = PetTranscript.card(c, local: local, now: seoulNow)
        XCTAssertEqual(item.status, "보내는 중…")
        XCTAssertTrue(item.statusWaits)
        XCTAssertTrue(item.options.allSatisfy { $0.link == nil }, "no second click while it is on its way")
        XCTAssertEqual(PetCardKeys.handle(.digit(1), card: c, local: local), .pass)

        local.sending = nil
        local.failure = "서버에 연결하지 못했어요. 네트워크를 확인해 주세요."
        item = PetTranscript.card(c, local: local, now: seoulNow)
        XCTAssertEqual(item.status, "보내지 못했어요. 서버에 연결하지 못했어요. 네트워크를 확인해 주세요.")
        XCTAssertEqual(item.retry, PetLinks.url("cardretry", ["id": "k-choice"]))
        XCTAssertTrue(item.options.allSatisfy { $0.link != nil }, "still answerable after a failure")

        let answered = PetCard.decode(["id": "k", "kind": "choice", "status": "answered", "version": 2, "answered_action": "choose",
                                       "answer": ["action": "choose", "option_id": "b", "answered_at": "2026-11-13T05:01:00Z"],
                                       "payload": ["question": "q", "options": [["id": "a", "label": "7시"], ["id": "b", "label": "8시"]]]])
        item = PetTranscript.card(answered, now: seoulNow)
        XCTAssertEqual(item.status, "골랐어요")
        XCTAssertEqual(item.options.map { $0.chosen }, [false, true], "the chosen row is marked")
        XCTAssertTrue(item.options.allSatisfy { $0.link == nil })
        XCTAssertNil(item.hint)

        let approved = PetCard.decode(["id": "ap", "kind": "approval", "status": "answered", "version": 2, "answered_action": "decline",
                                       "payload": ["title": "보낼까요?"]])
        XCTAssertEqual(PetTranscript.card(approved, now: seoulNow).options.map { $0.chosen }, [false, true])
        XCTAssertEqual(PetTranscript.card(approved, now: seoulNow).status, "거절했어요")

        let expired = card("choice", status: "expired", top: ["expires_at": "2026-11-12T09:30:00Z"])
        XCTAssertEqual(PetTranscript.card(expired, now: seoulNow).status, "시간이 지나 만료됐어요 (11월 12일 오후 6:30 KST)")
        XCTAssertEqual(PetTranscript.card(card("choice", status: "superseded"), now: seoulNow).status, "새 요청으로 바뀌었어요")
        XCTAssertEqual(PetTranscript.card(card("choice", status: "dismissed"), now: seoulNow).status, "닫았어요")
        XCTAssertEqual(PetCardKeys.handle(.digit(1), card: expired, local: PetCardLocal()), .pass, "a closed card takes no keys")
    }

    func testInputCardsStayOnThePhone() {
        let login = PetCard.decode(["id": "l", "kind": "login", "status": "pending", "version": 1, "payload": ["source": "naver", "verified_host": "nid.naver.com"]])
        let item = PetTranscript.card(login, now: seoulNow)
        XCTAssertEqual(item.style, .elsewhere)
        XCTAssertTrue(item.options.isEmpty)
        XCTAssertEqual(item.status, "휴대폰의 나초 앱에서 이어서 해 주세요")
        XCTAssertEqual(PetCardKeys.handle(.digit(1), card: login, local: PetCardLocal()), .pass)
    }

    func testKstTimes() {
        XCTAssertEqual(PetCardRules.kst("2026-11-13T06:20:00Z", now: seoulNow), "오후 3:20 KST")
        XCTAssertEqual(PetCardRules.kst("2026-11-13T15:05:00.123Z", now: seoulNow), "11월 14일 오전 12:05 KST")
        XCTAssertNil(PetCardRules.kst("soon", now: seoulNow))
    }
}

final class PetDesktopToolNameTests: XCTestCase {
    /// B lane's combo_* tools (PetCommands.swift @ feat/pet-desktop-actions 1eef601) read in Korean, never "도구".
    func testDesktopActionToolsHaveKoreanNames() {
        let names = ["combo_list_apps": "앱 목록 보기", "combo_open_app": "앱 열기", "combo_focus_app": "앱 전환",
                     "combo_hide_app": "앱 숨기기", "combo_quit_app": "앱 종료", "combo_list_windows": "창 목록 보기",
                     "combo_layout_windows": "여러 창 배치", "combo_set_system": "소리·밝기·방해금지",
                     "combo_set_dim_strength": "디밍 강도", "combo_clear_shelf": "선반 비우기",
                     "combo_workspace_save": "작업 공간 저장", "combo_workspace_apply": "작업 공간 적용",
                     "combo_workspace_list": "작업 공간 목록",
                     "combo_arrange_window": "창 배치", "combo_set_gadget": "가젯 켜기·끄기", "combo_list_gadgets": "가젯 목록 보기"]
        for (raw, korean) in names { XCTAssertEqual(PetText.toolName(raw), korean, raw) }
        XCTAssertEqual(Set(names.values).count, names.count, "every tool reads differently")
        XCTAssertEqual(PetText.toolName("combo_something_new"), "도구")
    }
}

final class PetCardKeysTests: XCTestCase {
    func testNumberMarksEnterSendsEscClears() {
        let c = card("choice")
        var local = PetCardLocal()
        XCTAssertEqual(PetCardKeys.handle(.digit(2), card: c, local: local), .highlight(2))
        XCTAssertEqual(PetCardKeys.handle(.digit(4), card: c, local: local), .pass, "no row 4: the key types as usual")
        XCTAssertEqual(PetCardKeys.handle(.digit(0), card: c, local: local), .pass)
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .pass, "Enter without a mark sends the field as before")
        XCTAssertEqual(PetCardKeys.handle(.escape, card: c, local: local), .pass, "Esc without a mark closes the chat as before")
        local.highlighted = 2
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .answer(PetCardAnswer(action: "choose", optionIDs: ["b"])))
        XCTAssertEqual(PetCardKeys.handle(.escape, card: c, local: local), .clear)
        XCTAssertTrue(PetTranscript.card(c, local: local, now: seoulNow).options[1].marked)
    }

    func testApprovalNeedsTheNumberThenEnter() {
        let c = PetCard.decode(["id": "ap", "kind": "approval", "status": "pending", "version": 1, "payload": ["title": "지울까요?", "action_type": "delete"]])
        XCTAssertEqual(PetCardKeys.handle(.digit(1), card: c, local: PetCardLocal()), .highlight(1), "a number alone never runs it")
        var local = PetCardLocal()
        local.highlighted = 1
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .answer(PetCardAnswer(action: "approve")))
        local.highlighted = 2
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .answer(PetCardAnswer(action: "deny")))
    }

    func testSeveralChoicesToggleWithNumbersAndConfirmWithEnter() {
        let c = card("choice", multiple: true)
        var local = PetCardLocal()
        XCTAssertEqual(PetCardKeys.handle(.digit(3), card: c, local: local), .toggle("c"))
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .pass, "nothing ticked")
        local.ticked = ["c"]
        XCTAssertEqual(PetCardKeys.handle(.enter, card: c, local: local), .answer(PetCardAnswer(action: "choose", optionIDs: ["c"])))
        XCTAssertEqual(PetCardKeys.handle(.escape, card: c, local: local), .clear)
    }

    func testTheNewestWaitingCardTakesTheKeys() {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.phase = .connected
        var t1 = ChatTurn(clientMsgID: "c1", userText: "예약해 줘")
        t1.status = .done
        t1.cardIDs = ["k-choice", "ap"]
        st.chat.turns = [t1]
        let ap = PetCard.decode(["id": "ap", "kind": "approval", "status": "answered", "answered_action": "approve", "version": 2, "payload": ["title": "결제?"]])
        st.chat.cards = [card("choice"), ap]
        let items = PetTranscript.items(st, undoSecondsLeft: { _ in nil }, now: seoulNow)
        XCTAssertEqual(PetTranscript.activeCardID(items), "k-choice", "the answered approval is skipped")
        st.chat.cards[0].status = "expired"
        XCTAssertNil(PetTranscript.activeCardID(PetTranscript.items(st, undoSecondsLeft: { _ in nil }, now: seoulNow)))
    }
}

final class PetHoldGestureTests: XCTestCase {
    func testLetGoBeforeTheRingIsFullIsTheOldClick() {
        var g = PetHoldGesture()
        g.down(at: 10, x: 100, y: 100, talk: true)
        XCTAssertEqual(g.tick(at: 10.5), .none)
        XCTAssertEqual(g.progress(at: 11), 0.5, accuracy: 0.0001, "half way at 1 s")
        XCTAssertEqual(g.tick(at: 11.9), .none)
        XCTAssertEqual(g.up(at: 11.95), .click)
        XCTAssertEqual(g.phase, .idle)
    }

    func testHoldTwoSecondsRecordsUntilLetGo() {
        XCTAssertEqual(PetVoice.holdSeconds, 2.0)
        var g = PetHoldGesture()
        g.down(at: 0, x: 100, y: 100, talk: true)
        XCTAssertEqual(g.progress(at: 2.5), 1)
        XCTAssertEqual(g.tick(at: 2.0), .startRecording)
        XCTAssertTrue(g.isRecording)
        XCTAssertEqual(g.tick(at: 3), .none, "starts once")
        XCTAssertEqual(g.move(at: 3, x: 140, y: 100, insidePet: true), .none, "moving inside the pet while talking is no drag")
        XCTAssertEqual(g.up(at: 5.25), .finishRecording(seconds: 3.25))
        XCTAssertEqual(g.phase, .idle)
    }

    func testMoveThreePointsIsTheOldDrag() {
        var g = PetHoldGesture()
        g.down(at: 0, x: 100, y: 100, talk: true)
        XCTAssertEqual(g.move(at: 0.1, x: 102, y: 101, insidePet: true), .none, "under 3 px")
        XCTAssertEqual(g.move(at: 0.2, x: 103, y: 100, insidePet: true), .dragStarted)
        XCTAssertEqual(g.progress(at: 1.5), 0, "no ring while dragging")
        XCTAssertEqual(g.tick(at: 3), .none, "a long drag never records")
        XCTAssertEqual(g.up(at: 3), .dragEnded)
    }

    func testDragOutOrEscCancelsTheRecording() {
        var g = PetHoldGesture()
        g.down(at: 0, x: 100, y: 100, talk: true)
        _ = g.tick(at: 2)
        XCTAssertEqual(g.move(at: 3, x: 400, y: 100, insidePet: false), .cancelRecording)
        XCTAssertEqual(g.up(at: 4), .none, "letting go after the cancel sends nothing")
        g.down(at: 10, x: 100, y: 100, talk: true)
        _ = g.tick(at: 12)
        XCTAssertEqual(g.escape(), .cancelRecording)
        XCTAssertEqual(g.up(at: 13), .none)
    }

    func testMovedPastTheEndOfTheRingBeforeTheTimerFired() {
        var g = PetHoldGesture()
        g.down(at: 0, x: 100, y: 100, talk: true)
        XCTAssertEqual(g.move(at: 2.1, x: 101, y: 100, insidePet: true), .startRecording)
        XCTAssertTrue(g.isRecording)
        var h = PetHoldGesture()
        h.down(at: 0, x: 100, y: 100, talk: true)
        XCTAssertEqual(h.up(at: 2.05), .none, "let go just as it filled: neither a click nor a recording")
    }

    func testSignedOutALongPressIsStillAClick() {
        var g = PetHoldGesture()
        g.down(at: 0, x: 0, y: 0, talk: false)
        XCTAssertEqual(g.progress(at: 1), 0)
        XCTAssertFalse(g.isFilling)
        XCTAssertEqual(g.tick(at: 5), .none)
        XCTAssertEqual(g.up(at: 5), .click)
    }
}

final class PetSpokenReplyTests: XCTestCase {
    private func turn(_ id: String, _ text: String, _ status: TurnStatus) -> ChatTurn {
        var t = ChatTurn(clientMsgID: id, userText: "질문")
        t.assistantText = text
        t.status = status
        return t
    }

    func testOnlySpokenTurnsAreReadOnceFirstSentenceWhenComplete() {
        var r = PetVoiceReplies()
        r.began("v1")
        XCTAssertNil(r.next([turn("v1", "오늘은 맑", .streaming)], enabled: true), "not a whole sentence yet")
        let streaming = turn("v1", "오늘은 맑고 따뜻해요. 오후에는 바람이", .streaming)
        XCTAssertEqual(r.next([streaming], enabled: true)?.text, "오늘은 맑고 따뜻해요.")
        XCTAssertNil(r.next([turn("v1", "오늘은 맑고 따뜻해요. 오후에는 바람이 불어요.", .done)], enabled: true), "once per turn")
        XCTAssertNil(r.next([turn("t1", "글로 물은 답이에요.", .done)], enabled: true), "typed turns are never read")
        r.began("v2")
        XCTAssertEqual(r.next([turn("v2", "네", .done)], enabled: true)?.text, "네", "a short answer without a full stop, once done")
    }

    func testNewInputStopOrSettingOffSilences() {
        var r = PetVoiceReplies()
        r.began("v1")
        r.silenceAll()
        XCTAssertNil(r.next([turn("v1", "답이에요.", .done)], enabled: true))
        r.began("v2")
        XCTAssertNil(r.next([turn("v2", "답이에요.", .done)], enabled: false))
        XCTAssertNil(r.next([turn("v2", "답이에요.", .done)], enabled: true), "turned off meanwhile: that answer stays unread")
        r.began("v3")
        XCTAssertNil(r.next([turn("v3", "", .failed("x"))], enabled: true))
        XCTAssertNil(r.next([turn("v3", "늦은 글.", .done)], enabled: true), "a failed turn is dropped")
    }

    func testFirstSentenceCleansMarkdownLinksAndNumbers() {
        XCTAssertEqual(PetSpeech.firstSentence("**결과**: 1.5배 빨라졌어요! 자세한 건 아래를 보세요.", final: false), "결과: 1.5배 빨라졌어요!")
        XCTAssertEqual(PetSpeech.firstSentence("## 요약\n- 3곳을 찾았어요", final: true), "요약")
        XCTAssertEqual(PetSpeech.firstSentence("[숯불집](https://example.com)이 좋아요. 다음은", final: false), "숯불집이 좋아요.")
        XCTAssertEqual(PetSpeech.firstSentence("https://example.com 여기 있어요?! 네", final: false), "여기 있어요?!")
        XCTAssertNil(PetSpeech.firstSentence("   ", final: true))
        let long = String(repeating: "가나다라마바사, ", count: 30) + "끝."
        XCTAssertLessThanOrEqual(PetSpeech.firstSentence(long, final: true)!.count, 140)
    }

    func testDictationErrorsInKorean() {
        XCTAssertEqual(PetVoiceText.dictationFailure(code: "payload_too_large", reason: nil, maxSec: 60), "말이 너무 길어요. 60초 안으로 말해 주세요.")
        XCTAssertEqual(PetVoiceText.dictationFailure(code: "not_implemented", reason: nil, maxSec: 60), PetVoiceText.unavailable)
        XCTAssertEqual(PetVoiceText.dictationFailure(code: "too_many_requests", reason: nil, maxSec: 60), "잠시 뒤에 다시 말해 주세요.")
        XCTAssertEqual(PetVoiceText.dictationFailure(code: "upstream_error", reason: nil, maxSec: 60), "받아쓰기 서버가 답하지 않았어요. 잠시 뒤 다시 말해 주세요.")
        XCTAssertEqual(PetVoiceText.dictationFailure(code: nil, reason: nil, maxSec: 60), "받아 적지 못했어요. 다시 말해 주세요.")
    }

    func testSpeakSettingIsOnByDefaultAndSurvivesOldFiles() throws {
        XCTAssertTrue(PetSettings().speakVoiceReplies)
        let old = try JSONDecoder().decode(PetSettings.self, from: Data(#"{"serverMode":"production","allowComboControl":true}"#.utf8))
        XCTAssertTrue(old.speakVoiceReplies)
        var s = PetSettings()
        s.speakVoiceReplies = false
        let back = try JSONDecoder().decode(PetSettings.self, from: JSONEncoder().encode(s))
        XCTAssertFalse(back.speakVoiceReplies)
    }
}
