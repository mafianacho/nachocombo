import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-147: Nacho's Computer Use calls are declared with `"approval": "required"` (content_out / input_inject), so
/// nacho-server shows its approval card before the request reaches the Mac. The card is the server's: for a chat turn
/// `build_payload` titles it "실행 · <capability>" (action_type other, no arguments on the card). Scenes: the screenshot
/// card waits, approved (the picture is attached to the chat), the click card waits, approved (clicked and checked).
/// The real chat window (PetChatWindow) and cards (PetTranscript / PetCardRules), drawn off screen on macOS CI, not a
/// real Mac. The conversation and cards are TEST FIXTURES. Pictures go to .build/bento-captures and, base64 in chunks,
/// to the test log (BENTO-CAPTURE lines) for CI.
final class ComputerUseApprovalCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let screen = NSRect(x: 0, y: 0, width: 520, height: 760)
    private let now = ISO8601DateFormatter().date(from: "2026-11-14T06:00:00Z")!
    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func card(_ id: String, capability: String) -> PetCard {
        PetCard.decode(["id": id, "kind": "approval", "status": "pending", "version": 1, "expires_at": "2026-11-14T06:10:00Z",
                        "payload": ["title": "실행 · \(capability)", "action_type": "other", "reversibility": "conditional",
                                    "details": ["tool": capability]]])
    }

    private func state(_ question: String, answer: String, cards: [PetCard]) -> PetSessionState {
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

    private func rows(in view: NSView) -> [PetChoiceRow] {
        view.subviews.flatMap { ($0 as? PetChoiceRow).map { [$0] } ?? rows(in: $0) }
    }

    @discardableResult
    private func render(_ name: String, st: PetSessionState, dark: Bool, caption: String) throws -> PetChatWindow {
        let chat = PetChatWindow(module: nil, size: PetChatSize(width: 380, height: 540))
        chat.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let pet = NSRect(x: screen.width - CGFloat(PetTokens.Size.pet) - 24, y: 24, width: CGFloat(PetTokens.Size.pet), height: CGFloat(PetTokens.Size.pet))
        chat.place(petFrame: pet, screen: screen)
        chat.show(items: PetTranscript.items(st, undoSecondsLeft: { _ in nil }, cards: [:], now: now))
        let content = try XCTUnwrap(chat.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let chatImage = NSImage(size: content.bounds.size)
        chatImage.addRepresentation(rep)

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let canvas = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(screen.width), pixelsHigh: Int(screen.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        appearance.performAsCurrentDrawingAppearance {
            PetTheme.color(\.desktop).setFill()
            screen.fill()
            chatImage.draw(in: chat.frame.offsetBy(dx: -screen.minX, dy: -screen.minY))
            let art = pet.insetBy(dx: CGFloat(PetTokens.Size.petArtInset), dy: CGFloat(PetTokens.Size.petArtInset))
            if let image = PetArt.image(named: "idle") {
                image.draw(in: art)
            } else {
                PetTheme.accent.setFill()
                NSBezierPath(ovalIn: pet.insetBy(dx: 20, dy: 20)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black]
            let lines = [caption, "\(dark ? "dark" : "light") · macOS CI off-screen render, not a real Mac"] as [NSString]
            let w = min(pet.minX - 24, (lines.map { $0.size(withAttributes: attrs).width }.max() ?? 0) + 16)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: w, height: 38), xRadius: 6, yRadius: 6).fill()
            lines[0].draw(in: NSRect(x: 16, y: 26, width: w - 16, height: 16), withAttributes: attrs)
            lines[1].draw(in: NSRect(x: 16, y: 11, width: w - 16, height: 16), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
        try emit(png, name: "\(name)-\(dark ? "dark" : "light")")
        return chat
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

    func testComputerUseApprovalCards() throws {
        // What hello declares: the card comes from these names (approval every time, "always allow" off by default).
        let caps = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: [])
        for name in ["combo_computer_screen_capture", "combo_computer_click_element", "combo_computer_ui_tree"] {
            XCTAssertEqual(caps.first { $0["name"] as? String == name }?["approval"] as? String, "required", name)
        }

        var shot = card("cu1", capability: "combo_computer_screen_capture")
        for dark in [false, true] {
            let chat = try render("computer-capture-approval", st: state("지금 화면에 뭐가 떠 있는지 봐 줘",
                                                                         answer: "화면을 찍기 전에 확인할게요.", cards: [shot]),
                                  dark: dark, caption: "컴퓨터 사용 승인 카드: 스크린샷(content_out), 승인 전에는 찍지 않음")
            XCTAssertEqual(rows(in: try XCTUnwrap(chat.contentView)).count, 2, "실행 and 거절")
        }
        shot.status = "answered"
        shot.answeredAction = "approve"
        for dark in [false, true] {
            try render("computer-capture-approved", st: state("지금 화면에 뭐가 떠 있는지 봐 줘",
                                                              answer: "화면을 찍어 입력 칸에 붙였어요. 보내기를 누르면 바로 보고 알려 드릴게요.",
                                                              cards: [shot]),
                       dark: dark, caption: "승인 뒤: 스크린샷은 대화 입력 칸에 첨부(서버가 이미지 결과를 못 받음)")
        }

        var click = card("cu2", capability: "combo_computer_click_element")
        for dark in [false, true] {
            let chat = try render("computer-click-approval", st: state("메모 앱에서 새로운 메모 버튼 눌러 줘",
                                                                       answer: "'새로운 메모' 버튼을 찾았어요. 누르기 전에 확인해 주세요.", cards: [click]),
                                  dark: dark, caption: "컴퓨터 사용 승인 카드: 클릭(input_inject)")
            XCTAssertEqual(rows(in: try XCTUnwrap(chat.contentView)).count, 2)
        }
        click.status = "answered"
        click.answeredAction = "approve"
        for dark in [false, true] {
            try render("computer-click-approved", st: state("메모 앱에서 새로운 메모 버튼 눌러 줘",
                                                            answer: "'새로운 메모' 버튼을 눌렀어요. 화면 요소를 다시 읽어 보니 새 메모가 열렸어요.",
                                                            cards: [click]),
                       dark: dark, caption: "승인 뒤: 클릭하고 트리를 다시 읽어 확인")
        }
    }
}
