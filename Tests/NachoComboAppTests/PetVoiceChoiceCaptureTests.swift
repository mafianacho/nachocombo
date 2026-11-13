import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// The real chat window (PetChatWindow) with cards built by the real rules (PetTranscript / PetCardRules) and the real
/// hold-to-talk ring (PetHoldRing) over the pet, drawn off screen in light and dark: approval, one choice (number key
/// mark), several + 확정, suggestion chips, rule proposal, answered, expired, sending/failed, the ring half and full,
/// recording, the bubble after sending, and the microphone-denied notice. AppKit off-screen renders on macOS CI, not a
/// real Mac (no window shadow, no real mouse or microphone). The conversation and cards are TEST FIXTURES.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class PetVoiceChoiceCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let screen = NSRect(x: 0, y: 0, width: 520, height: 760)
    private let now = ISO8601DateFormatter().date(from: "2026-11-13T05:00:00Z")!  // 14:00 KST
    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    // MARK: fixtures

    private func state(_ question: String, answer: String, cards: [PetCard], status: TurnStatus = .done) -> PetSessionState {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.phase = .connected
        var t = ChatTurn(clientMsgID: "c1", userText: question)
        t.assistantText = answer
        t.status = status
        t.cardIDs = cards.map { $0.id }
        st.chat.turns = question.isEmpty ? [] : [t]
        st.chat.cards = cards
        return st
    }

    private func decode(_ o: [String: Any]) -> PetCard { PetCard.decode(o) }

    private var approval: PetCard {
        decode(["id": "ap", "kind": "approval", "status": "pending", "version": 1, "task_id": "t1", "expires_at": "2026-11-13T06:20:00Z",
                "payload": ["title": "선물가게에서 39,000원 결제할까요?", "action_type": "payment", "merchant": "선물가게", "amount": 39000,
                            "reversibility": "conditional", "reversibility_text": "배송 전이면 취소할 수 있어요"]])
    }

    private func choice(multiple: Bool = false, status: String = "pending", answer: [String: Any]? = nil) -> PetCard {
        var o: [String: Any] = ["id": multiple ? "mc" : "sc", "kind": "choice", "status": status, "version": 1, "task_id": "t1",
                                "expires_at": "2026-11-13T06:00:00Z",
                                "payload": ["question": multiple ? "같이 갈 사람을 골라 주세요" : "몇 시가 좋아요?", "multiple": multiple,
                                            "options": multiple
                                                ? [["id": "a", "label": "지민"], ["id": "b", "label": "서연"], ["id": "c", "label": "도윤"], ["id": "d", "label": "하준"]]
                                                : [["id": "a", "label": "저녁 7시", "reason": "단체석이 비어 있어요"], ["id": "b", "label": "저녁 8시"],
                                                   ["id": "c", "label": "저녁 9시"]]]]
        if let a = answer { o["answer"] = a; o["answered_action"] = "choose" }
        return decode(o)
    }

    private func render(_ name: String, st: PetSessionState, local: [String: PetCardLocal] = [:], extra: [PetChatItem] = [],
                        dark: Bool, size: PetChatSize = PetChatSize(width: 380, height: 540), caption: String) throws -> PetChatWindow {
        let chat = PetChatWindow(module: nil, size: size)
        chat.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let pet = NSRect(x: screen.width - CGFloat(PetTokens.Size.pet) - 24, y: 24, width: CGFloat(PetTokens.Size.pet), height: CGFloat(PetTokens.Size.pet))
        chat.place(petFrame: pet, screen: screen)
        let items = PetTranscript.items(st, undoSecondsLeft: { _ in nil }, cards: local, now: now) + extra
        chat.show(items: items)
        try emitScreen(name, chat: chat, pet: pet, dark: dark, caption: caption, ring: nil)
        return chat
    }

    // MARK: drawing

    private func emitScreen(_ name: String, chat: PetChatWindow?, pet: NSRect, dark: Bool, caption: String,
                            ring: (progress: Double?, level: Double?)?, face: PetFace = .idle) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var chatImage: NSImage?
        if let chat = chat {
            let content = try XCTUnwrap(chat.contentView)
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let img = NSImage(size: content.bounds.size)
            img.addRepresentation(rep)
            chatImage = img
        }
        let canvas = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(screen.width), pixelsHigh: Int(screen.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: canvas)!
        NSGraphicsContext.current = ctx
        appearance.performAsCurrentDrawingAppearance {
            PetTheme.color(\.desktop).setFill()
            screen.fill()
            if let img = chatImage, let chat = chat { img.draw(in: chat.frame.offsetBy(dx: -screen.minX, dy: -screen.minY)) }
            let art = pet.insetBy(dx: CGFloat(PetTokens.Size.petArtInset), dy: CGFloat(PetTokens.Size.petArtInset))
            if let image = PetArt.image(named: face.assetName) ?? PetArt.image(named: "idle") {
                image.draw(in: art)
            } else {
                PetTheme.accent.setFill()
                NSBezierPath(ovalIn: pet.insetBy(dx: 20, dy: 20)).fill()
            }
            if let r = ring {
                let ringLayer = PetHoldRing()
                ringLayer.layout(in: CGRect(origin: .zero, size: pet.size))
                ringLayer.show(progress: r.progress, recordingLevel: r.level, appearance: appearance)
                let cg = ctx.cgContext
                cg.saveGState()
                cg.translateBy(x: pet.minX, y: pet.minY)
                ringLayer.render(in: cg)
                cg.restoreGState()
            }
            // Bottom left, beside the pet: never over the chat. Two lines: the scene, then what kind of picture it is.
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black]
            let lines = [caption, "\(dark ? "dark" : "light") · macOS CI off-screen render, not a real Mac"] as [NSString]
            let w = min(pet.minX - 24, (lines.map { $0.size(withAttributes: attrs).width }.max() ?? 0) + 16)
            let box = NSRect(x: 8, y: 8, width: w, height: 38)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            lines[0].draw(in: NSRect(x: 16, y: 26, width: w - 16, height: 16), withAttributes: attrs)
            lines[1].draw(in: NSRect(x: 16, y: 11, width: w - 16, height: 16), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
        try emit(png, name: "\(name)-\(dark ? "dark" : "light")")
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 2_000, "\(name) is not empty")
    }

    private func rows(in view: NSView) -> [PetChoiceRow] {
        var out: [PetChoiceRow] = []
        for v in view.subviews {
            if let r = v as? PetChoiceRow { out.append(r) }
            out += rows(in: v)
        }
        return out
    }

    // MARK: scenes

    func testApprovalRunAboveDenySameSize() throws {
        for dark in [false, true] {
            let chat = try render("voice-approval", st: state("선물 하나 주문해 줘", answer: "선물가게에서 찾았어요. 결제 전에 확인해 주세요.", cards: [approval]),
                                  dark: dark, caption: "승인: 무엇을·결과·되돌리기, 실행 위 / 거절 아래")
            let content = try XCTUnwrap(chat.contentView)
            content.layoutSubtreeIfNeeded()
            let rs = rows(in: content)
            XCTAssertEqual(rs.count, 2)
            let a = rs[0].convert(rs[0].bounds, to: content), b = rs[1].convert(rs[1].bounds, to: content)
            XCTAssertEqual(a.width, b.width, accuracy: 0.5, "실행 and 거절 have the same width")
            XCTAssertEqual(a.height, b.height, accuracy: 0.5, "and the same height")
            XCTAssertEqual(abs(a.minY - b.maxY), CGFloat(PetTokens.Space.s), accuracy: 0.5, "8 pt apart, 실행 above")
            XCTAssertGreaterThan(a.midY, b.midY, "실행 is above 거절")
            XCTAssertTrue(rs[1].isAccessibilityEnabled(), "거절 is never disabled")
        }
    }

    func testOneChoiceWithANumberKeyMark() throws {
        var local = PetCardLocal()
        local.highlighted = 2
        for dark in [false, true] {
            _ = try render("voice-choice-one", st: state("회식 예약해 줘", answer: "단체석은 세 시간대가 비어 있어요.", cards: [choice()]),
                           local: ["sc": local], dark: dark, caption: "하나 고르기: 번호 행, 숫자키 2 = 표시, Enter = 답")
        }
    }

    func testSeveralChoicesAndConfirm() throws {
        var local = PetCardLocal()
        local.ticked = ["a", "c"]
        for dark in [false, true] {
            _ = try render("voice-choice-many", st: state("같이 갈 사람 정해 줘", answer: "연락처에서 네 명을 찾았어요.", cards: [choice(multiple: true)]),
                           local: ["mc": local], dark: dark, caption: "여러 개 고르기: 체크 행 + 확정 (2개)")
        }
    }

    func testSuggestionChipsUnderTheAnswer() throws {
        let s = decode(["id": "sg", "kind": "suggestions", "status": "pending", "version": 1,
                        "payload": ["options": [["id": "0", "label": "내일로 미뤄 줘"], ["id": "1", "label": "지금 보내 줘"], ["id": "2", "label": "문구 고쳐 줘"]]]])
        for dark in [false, true] {
            _ = try render("voice-suggestions", st: state("팀에 회의 공지 보내 줘", answer: "공지 문구를 만들었어요. 언제 보낼까요?", cards: [s]),
                           dark: dark, caption: "제안 칩: 나초 답 아래 번호 빠른 답")
        }
    }

    func testRuleProposal() throws {
        let r = decode(["id": "rp", "kind": "rule_proposal", "status": "pending", "version": 1, "expires_at": "2026-11-13T07:00:00Z",
                        "payload": ["said_text": "배달은 3만 원까지 괜찮아",
                                    "rule_options": [["id": "o1", "summary": "배달앱에서 건당 30,000원 이하는 묻지 않고 결제", "action_type": "payment"]]]])
        for dark in [false, true] {
            _ = try render("voice-rule", st: state("배달은 3만 원까지 괜찮아", answer: "알겠어요. 규칙으로 만들어 둘까요?", cards: [r]),
                           dark: dark, caption: "규칙 제안: 규칙 문장 + 적용 / 아니요")
        }
    }

    func testAnsweredAndExpired() throws {
        let answered = choice(status: "answered", answer: ["action": "choose", "option_id": "b", "answered_at": "2026-11-13T05:01:00Z"])
        var approved = approval
        approved.status = "answered"
        approved.answeredAction = "approve"
        for dark in [false, true] {
            _ = try render("voice-answered", st: state("회식 예약해 줘", answer: "단체석은 세 시간대가 비어 있어요.", cards: [answered, approved]),
                           dark: dark, caption: "답함: 고른 항목 표시, 나머지 흐리게")
            let expired = decode(["id": "ex", "kind": "choice", "status": "expired", "version": 2, "task_id": "t1", "expires_at": "2026-11-13T04:30:00Z",
                                  "payload": ["question": "몇 시가 좋아요?", "options": [["id": "a", "label": "저녁 7시"], ["id": "b", "label": "저녁 8시"]]]])
            _ = try render("voice-expired", st: state("회식 예약해 줘", answer: "단체석은 두 시간대가 비어 있어요.", cards: [expired]),
                           dark: dark, caption: "만료: 시각(KST)과 함께, 더 고를 수 없음")
        }
    }

    func testSendingAndFailedRetry() throws {
        var sending = PetCardLocal()
        sending.sending = PetCardAnswer(action: "approve")
        var failed = PetCardLocal()
        failed.failure = "서버에 연결하지 못했어요. 네트워크를 확인해 주세요."
        failed.lastAnswer = PetCardAnswer(action: "approve")
        for dark in [false, true] {
            _ = try render("voice-sending", st: state("선물 하나 주문해 줘", answer: "결제 전에 확인해 주세요.", cards: [approval]),
                           local: ["ap": sending], dark: dark, caption: "보내는 중: 두 번 누를 수 없음")
            _ = try render("voice-failed", st: state("선물 하나 주문해 줘", answer: "결제 전에 확인해 주세요.", cards: [approval]),
                           local: ["ap": failed], dark: dark, caption: "실패: 다시 시도")
        }
    }

    func testHoldRingHalfFullRecordingThenTheBubble() throws {
        let pet = NSRect(x: screen.width - CGFloat(PetTokens.Size.pet) - 24, y: 24, width: CGFloat(PetTokens.Size.pet), height: CGFloat(PetTokens.Size.pet))
        var g = PetHoldGesture()
        g.down(at: 0, x: 0, y: 0, talk: true)
        let half = g.progress(at: PetVoice.holdSeconds / 2)
        XCTAssertEqual(half, 0.5, accuracy: 0.001)
        for dark in [false, true] {
            try emitScreen("voice-ring-half", chat: nil, pet: pet, dark: dark, caption: "길게 누르기: 게이지 반 (1초)", ring: (half, nil))
            try emitScreen("voice-ring-full", chat: nil, pet: pet, dark: dark, caption: "게이지 가득 (2초) → 녹음 시작", ring: (g.progress(at: 2), nil))
            // Recording: the listening face, the sound level ring, and the open chat says it listens.
            let listening = PetChatWindow(module: nil)
            listening.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            listening.place(petFrame: pet, screen: screen)
            var st = state("", answer: "", cards: [])
            st.chat.turns = []
            listening.show(items: PetTranscript.items(st, undoSecondsLeft: { _ in nil }, now: now)
                           + [.line(PetChatLine(kind: .notice, symbol: "mic.fill", parts: [PetTextPart("듣고 있어요 · 다 말하면 손을 떼세요 (Esc: 취소)")]))])
            try emitScreen("voice-recording", chat: listening, pet: pet, dark: dark, caption: "녹음 중: 듣는 표정 + 소리 크기 링", ring: (nil, 0.7), face: .listening)

            // After letting go: the server wrote it down, it went out by itself as the user's bubble.
            var sent = state("내일 오후 3시에 팀 회의 잡아 줘", answer: "내일 오후 3시로 팀 회의를 잡았어요. 참석자에게 알림도 보낼까요?", cards: [], status: .streaming)
            sent.voiceTurns = ["c1"]
            _ = try render("voice-sent", st: sent, dark: dark, caption: "전송 후: 받아 적은 글이 내 말풍선, 답 첫 문장을 읽음")
            var r = PetVoiceReplies()
            r.began("c1")
            XCTAssertEqual(r.next(sent.chat.turns, enabled: true)?.text, "내일 오후 3시로 팀 회의를 잡았어요.")

            // Microphone refused: the notice and the link to the settings.
            let denied = PetChatLine(kind: .notice, symbol: "info.circle",
                                     parts: [PetTextPart(PetVoiceText.micDenied), PetTextPart(" · ", style: .secondary),
                                             PetTextPart(PetVoiceText.openSettings, link: PetLinks.url("micsettings"))])
            _ = try render("voice-mic-denied", st: state("", answer: "", cards: []), extra: [.line(denied)], dark: dark,
                           caption: "마이크 권한 거부: 안내 + 설정 열기")
        }
    }
}
