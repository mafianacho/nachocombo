import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-38: the real chat window (PetChatWindow) with the transcript and approval card built by the real rules
/// (PetTranscript / PetCardRules), drawn off screen in light and dark, for the desktop tidy flow:
/// ① the preview (Nacho shows the plan, nothing moved) ② the approval card ③ the result after approval ④ the undo result,
/// and for the window arrangement: ⑤ proposal ⑥ approval card ⑦ applied. The numbers in the texts come from the real
/// engine run on a temporary folder. The server draws the approval card in production; here the same card model is
/// rendered by the app. AppKit off-screen on macOS CI, not a real Mac. The conversation is a TEST FIXTURE.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class DesktopTidyCaptureTests: XCTestCase {
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

    /// A temporary desktop with sample files; the real engine makes the plan, applies it and undoes it.
    private func runEngine() throws -> (plan: DesktopTidyPlan, applied: DesktopTidyApplied, undone: DesktopTidyUndone) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("desktop-capture-\(UUID().uuidString)", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let t0 = Date()
        let names = ["스크린샷 2026-11-14 오후 3.04.05.png", "스크린샷 2026-11-14 오후 3.05.11.png", "여행 사진.jpg", "견적서.pdf", "회의록.docx",
                     "자료.zip", "Nacho.dmg", "메모"]
        for name in names {
            let url = desktop.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            try fm.setAttributes([.modificationDate: t0.addingTimeInterval(-7200)], ofItemAtPath: url.path)
        }
        let engine = DesktopTidyEngine(desktop: desktop, journalURL: root.appendingPathComponent("journal.json"), now: { Date() })
        let plan = try engine.plan().get()
        let applied = try engine.apply(planID: plan.id).get()
        let undone = try engine.undo().get()
        return (plan, applied, undone)
    }

    func testTidyScenes() throws {
        let run = try runEngine()
        XCTAssertEqual(run.plan.total, 8)
        XCTAssertEqual(run.applied.moves.count, 8)
        XCTAssertEqual(run.undone.restored, 8)
        let counts = DesktopCategory.allCases.compactMap { c in run.plan.counts[c].map { "\(c.folderName) \($0)개" } }.joined(separator: " · ")
        let question = "바탕화면 좀 정리해 줘"
        let pending = approval(id: "dt", title: "바탕화면 파일 \(run.plan.total)개를 정리됨 폴더로 옮길까요?", action: "desktop_tidy",
                               text: "한 번에 되돌릴 수 있어요. 지우거나 덮어쓰지 않아요")
        var approved = pending
        approved.status = "answered"
        approved.answeredAction = "approve"
        for dark in [false, true] {
            try shoot("desktop-tidy-1-preview", dark: dark,
                      st: state(question, answer: "바탕화면을 훑어 봤어요. 아직 아무것도 옮기지 않았어요.\n\n**\(run.plan.total)개**를 정리할 수 있어요: \(counts)\n\n"
                                + "스크린샷 2개 · 여행 사진.jpg · 견적서.pdf · 회의록.docx · 자료.zip · Nacho.dmg · 메모\n\n"
                                + "`~/Desktop/정리됨/<분류>/`로 옮길게요. 해도 될까요?"))
            try shoot("desktop-tidy-2-approval", dark: dark,
                      st: state(question, answer: "옮기기 전에 확인할게요.", cards: [pending]))
            try shoot("desktop-tidy-3-result", dark: dark,
                      st: state(question, answer: "**\(run.applied.moves.count)개**를 정리됨 폴더로 옮겼어요. 건너뛴 파일은 없어요.\n마음에 안 들면 \"되돌려 줘\"라고 말해 주세요.",
                                cards: [approved]))
            try shoot("desktop-tidy-4-undo", dark: dark,
                      st: state("방금 정리 되돌려 줘", answer: "**\(run.undone.restored)개**를 원래 자리로 돌려놨어요. 되돌리지 못한 파일은 없어요."))
        }
    }

    func testArrangeScenes() throws {
        let pending = approval(id: "da", title: "열린 창 4개를 2×2로 배치할까요?", action: "desktop_arrange",
                               text: "창 배치 되돌리기로 한 번에 되돌릴 수 있어요")
        var approved = pending
        approved.status = "answered"
        approved.answeredAction = "approve"
        let question = "열려 있는 창 정리해 줘"
        for dark in [false, true] {
            try shoot("desktop-arrange-1-suggest", dark: dark,
                      st: state(question, answer: "열린 창이 있는 앱은 **Safari · Notes · Terminal · Mail** 4개예요.\n2×2로 나눠 놓으면 어떨까요? 아직 아무것도 옮기지 않았어요."))
            try shoot("desktop-arrange-2-approval", dark: dark, st: state(question, answer: "배치하기 전에 확인할게요.", cards: [pending]))
            try shoot("desktop-arrange-3-applied", dark: dark,
                      st: state(question, answer: "4개 창을 2×2로 놓았어요. 마음에 안 들면 \"창 배치 되돌려 줘\"라고 말해 주세요.", cards: [approved]))
        }
    }
}
