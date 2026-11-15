import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-152 (QA of NACHO-144): the real chat window (PetChatWindow) with the transcript and approval card built by the real
/// rules (PetTranscript / PetCardRules), drawn off screen in light and dark: ① a data read answered (monitor numbers)
/// ② the approval card of a content tool (clipboard item) ③ the answer to a switched-off gadget ④ the approval card of
/// `combo_clear_shelf` (destructive: the card comes even with always-allow). Every value is a FIXED FIXTURE (fake numbers, no
/// clipboard or file content). The server draws the approval card in production; here the same card model is rendered by the
/// app. AppKit off-screen on macOS CI, not a real Mac and not a live Nacho conversation.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class NachoConversationCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let now = ISO8601DateFormatter().date(from: "2026-11-14T05:00:00Z")!
    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func state(_ question: String, answer: String, cards: [PetCard] = []) -> PetSessionState {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.phase = .connected
        var t = ChatTurn(clientMsgID: "c1", userText: question)
        t.assistantText = answer
        t.status = .done
        t.cardIDs = cards.map { $0.id }
        st.chat.turns = [t]
        st.chat.cards = cards
        return st
    }

    private func approval(id: String, title: String, action: String, status: String = "pending", answered: String? = nil,
                          reversibility: String = "reversible", text: String) -> PetCard {
        var o: [String: Any] = ["id": id, "kind": "approval", "status": status, "version": 1, "task_id": "t-\(id)",
                                "expires_at": "2026-11-14T06:20:00Z",
                                "payload": ["title": title, "action_type": action, "reversibility": reversibility, "reversibility_text": text]]
        if let a = answered { o["answered_action"] = a }
        return PetCard.decode(o)
    }

    private func shoot(_ name: String, dark: Bool, st: PetSessionState) throws {
        let chat = PetChatWindow(module: nil, size: PetChatSize(width: 380, height: 540))
        chat.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        chat.show(items: PetTranscript.items(st, undoSecondsLeft: { _ in nil }, now: now))
        let content = try XCTUnwrap(chat.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let label = "\(name)-\(dark ? "dark" : "light")"
        try png.write(to: outDir.appendingPathComponent("\(label).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(label) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 2_000, "\(label) is not empty")
    }

    func testConversationScenes() throws {
        let read = state("내 맥 지금 느려?", answer: "CPU 42%, 메모리 61%, 배터리 64%(충전 중)예요. 지금은 여유 있어요.")
        let clip = approval(id: "cb", title: "클립보드 1번 항목의 내용을 나초에게 보여 줄까요?", action: "content_read",
                            reversibility: "irreversible", text: "내용이 나초에게 전달돼요. 보내고 나면 되돌릴 수 없어요")
        let clipState = state("클립보드에 복사한 거 읽어 줘", answer: "내용을 읽기 전에 확인할게요.", cards: [clip])
        let off = state("파일 선반에 뭐 있어?", answer: "파일 선반 가젯이 꺼져 있어요. 켤까요? 켜 주시면 바로 확인할게요.")
        let clear = approval(id: "cs", title: "파일 선반을 비울까요?", action: "shelf_clear", reversibility: "irreversible",
                             text: "선반 목록만 비워요. 원본 파일은 그대로예요. 항상 허용을 켜 두어도 매번 물어봐요")
        let clearState = state("선반 비워 줘", answer: "비우기 전에 확인할게요.", cards: [clear])
        for dark in [false, true] {
            try shoot("nacho-1-monitor-answer", dark: dark, st: read)
            try shoot("nacho-2-clipboard-approval", dark: dark, st: clipState)
            try shoot("nacho-3-gadget-off", dark: dark, st: off)
            try shoot("nacho-4-clear-shelf-approval", dark: dark, st: clearState)
        }
    }
}
