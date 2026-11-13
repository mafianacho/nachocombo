import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// The real chat window (PetChatWindow) placed next to a pet by its own rule and drawn off screen onto a 1280 × 800
/// "screen": before and after the pet is dragged (with text being typed), flipped below a pet at the top, resized
/// large and small, and restored from the saved settings as after a relaunch. AppKit off-screen renders on macOS CI,
/// not a real Mac (no window shadow, no real mouse). The conversation below is a TEST FIXTURE.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class PetChatFollowResizeCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private let screen = NSRect(x: 0, y: 0, width: 1280, height: 800)
    private let petSize = CGFloat(PetTokens.Size.pet)
    private let typed = "내일 오전 회의 일정 정리해 "
    private let conversation: [PetChatItem] = [
        .mine(text: "이번 주 금요일 저녁 7시에 팀 회식 장소 좀 추천해 줘", attachments: [], past: false),
        .nacho(text: "좋아요. 사무실에서 걸어서 10분 안쪽으로 세 곳을 골랐어요. 1) 숯불 닭갈비집: 단체석 12명, 예약 가능. 2) 이탈리안 비스트로: 조용하고 코스 메뉴가 있어요. 3) 이자카야: 늦게까지 열어요. 인원과 예산을 알려 주시면 한 곳으로 좁혀 볼게요.",
               past: false, streaming: false),
        .mine(text: "12명이고 1인 3만 원 정도", attachments: [], past: false),
        .nacho(text: "그럼 숯불 닭갈비집이 딱 맞아요. 1인 2만 8천 원 세트에 음료가 포함돼요. 예약 문구를 만들어 드릴까요?", past: false, streaming: false),
    ]

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func pet(_ x: CGFloat, _ y: CGFloat) -> NSRect { NSRect(x: x, y: y, width: petSize, height: petSize) }

    private func makeChat(size: PetChatSize? = nil) -> PetChatWindow {
        let chat = PetChatWindow(module: nil, size: size)
        chat.appearance = NSAppearance(named: .aqua)
        chat.input.stringValue = typed
        XCTAssertTrue(chat.makeFirstResponder(chat.input))
        return chat
    }

    /// Places the chat for `pet` with the window's own rule and returns the screen picture.
    private func shot(_ name: String, chat: PetChatWindow, pet: NSRect, caption: String) throws {
        chat.place(petFrame: pet, screen: screen)
        chat.show(items: conversation)
        let content = try XCTUnwrap(chat.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let chatRep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: chatRep)
        let chatImage = NSImage(size: content.bounds.size)
        chatImage.addRepresentation(chatRep)

        let canvas = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(screen.width), pixelsHigh: Int(screen.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            PetTheme.color(\.desktop).setFill()
            screen.fill()
            chatImage.draw(in: chat.frame.offsetBy(dx: -screen.minX, dy: -screen.minY))
            let petRect = pet.offsetBy(dx: -screen.minX, dy: -screen.minY)
            if let art = PetArt.image(named: "idle") {
                art.draw(in: petRect.insetBy(dx: CGFloat(PetTokens.Size.petArtInset), dy: CGFloat(PetTokens.Size.petArtInset)))
            } else {
                PetTheme.accent.setFill()
                NSBezierPath(ovalIn: petRect.insetBy(dx: 20, dy: 20)).fill()
            }
            let label = "\(caption)  ·  chat \(Int(chat.frame.width))×\(Int(chat.frame.height - PetChatBackground.tail)) at (\(Int(chat.frame.minX)), \(Int(chat.frame.minY)))  ·  AppKit off-screen render on macOS CI, not a real Mac"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black]
            let text = label as NSString
            let box = NSRect(x: 8, y: screen.height - 30, width: text.size(withAttributes: attrs).width + 16, height: 22)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: 16, y: screen.height - 27), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(canvas.representation(using: .png, properties: [:]))
        try emit(png, name: name)
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

    private func tailTipX(_ chat: PetChatWindow) -> CGFloat {
        guard let bg = chat.contentView as? PetChatBackground else { return .nan }
        return chat.frame.maxX - bg.tailFromRight
    }

    /// ① The pet is dragged while the user types: the chat comes along, the text and the focus stay.
    func testFollowsTheDraggedPetWhileTyping() throws {
        let chat = makeChat()
        let start = pet(1280 - petSize - 24, 24)
        try shot("petchat-follow-before", chat: chat, pet: start, caption: "① before the drag")
        let before = chat.frame
        let editor = chat.firstResponder
        // The drag: the window follows every event of the pet, then the drop.
        var p = start
        for _ in 0..<20 {
            p = p.offsetBy(dx: -24, dy: 3)
            chat.place(petFrame: p, screen: screen)
            XCTAssertEqual(chat.frame.maxX, p.maxX, accuracy: 0.5)
            XCTAssertEqual(tailTipX(chat), p.midX, accuracy: 0.5)
        }
        try shot("petchat-follow-after", chat: chat, pet: p, caption: "① after dragging the pet (chat followed, typing kept)")
        XCTAssertEqual(chat.frame.minX - before.minX, p.minX - start.minX, accuracy: 0.5)
        XCTAssertEqual(chat.frame.minY - before.minY, p.minY - start.minY, accuracy: 0.5)
        XCTAssertEqual(chat.input.stringValue, typed)
        XCTAssertTrue(chat.firstResponder === editor, "focus stays in the input while the chat follows")
    }

    /// ② Dragged to the top of the screen: the chat flips below the pet and the tail points up at it.
    func testFlipsBelowAtTheTop() throws {
        let chat = makeChat()
        let high = pet(760, 800 - petSize - 30)
        try shot("petchat-flip", chat: chat, pet: high, caption: "② pet at the top: chat below, tail up")
        let bg = try XCTUnwrap(chat.contentView as? PetChatBackground)
        XCTAssertTrue(bg.tailOnTop)
        XCTAssertLessThanOrEqual(chat.frame.maxY, high.minY)
        XCTAssertEqual(tailTipX(chat), high.midX, accuracy: 0.5)
    }

    /// ③ Resized large and small: rows follow the width, the chat still sits on the pet with the tail on it.
    func testLargeAndSmall() throws {
        let p = pet(1280 - petSize - 24, 24)
        let large = makeChat(size: PetChatSize(width: 640, height: 600))
        try shot("petchat-size-large", chat: large, pet: p, caption: "③ resized large (640 × 600)")
        XCTAssertEqual(large.frame.width, 640)
        XCTAssertEqual(large.frame.height, 600 + PetChatBackground.tail)
        XCTAssertEqual(tailTipX(large), p.midX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(large.frame.minY, p.maxY, "above the pet, not over it")
        let small = makeChat(size: PetChatLayout.minimumSize)
        try shot("petchat-size-small", chat: small, pet: p, caption: "③ resized to the minimum (320 × 420)")
        XCTAssertEqual(small.frame.width, CGFloat(PetChatLayout.minimumSize.width))
        XCTAssertEqual(tailTipX(small), p.midX, accuracy: 0.5)
        // Every row is as wide as the window (header, log, composer).
        for chat in [large, small] {
            let content = try XCTUnwrap(chat.contentView)
            content.layoutSubtreeIfNeeded()
            let column = try XCTUnwrap(content.subviews.first?.subviews.first as? NSStackView)
            for row in column.arrangedSubviews where !row.isHidden {
                XCTAssertEqual(row.frame.width, chat.frame.width, accuracy: 0.5, "\(type(of: row)) follows the window width")
            }
        }
        // Bigger than the screen: clamped to it, shown in the room above the pet without covering it.
        let huge = makeChat(size: PetChatSize(width: 5000, height: 5000))
        huge.place(petFrame: p, screen: screen)
        XCTAssertLessThanOrEqual(huge.frame.width, screen.width - 2 * CGFloat(PetChatLayout.screenMargin))
        XCTAssertLessThanOrEqual(huge.frame.maxY, screen.maxY)
        XCTAssertGreaterThanOrEqual(huge.frame.minY, p.maxY)
        XCTAssertEqual(huge.bodySize, PetChatLayout.clamp(PetChatSize(width: 5000, height: 5000), screen: nil), "the chosen size is kept")
    }

    /// ④ Saved when the resize ends, read back by a new settings store (as after quitting and opening the app), and
    /// "대화창 크기 원래대로" goes back to the design's size.
    func testRestoredAfterRelaunchAndReset() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("petchat-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pet.json")
        var s = PetSettings()
        s.chatSize = PetChatLayout.saved(PetChatSize(width: 560, height: 600))
        try PetSettingsStore(url: file).save(s)

        let relaunched = PetSettingsStore(url: file).load()
        XCTAssertEqual(relaunched.chatSize, PetChatSize(width: 560, height: 600))
        let chat = makeChat(size: relaunched.chatSize)
        let p = pet(1280 - petSize - 24, 24)
        try shot("petchat-restore", chat: chat, pet: p, caption: "④ after a relaunch: the saved size (560 × 600) is back")
        XCTAssertEqual(chat.frame.width, 560)
        XCTAssertEqual(chat.frame.height, 600 + PetChatBackground.tail)

        chat.setBodySize(nil)
        chat.place(petFrame: p, screen: screen)
        XCTAssertEqual(chat.frame.width, CGFloat(PetTokens.Size.chatWidth))
        XCTAssertEqual(chat.frame.height, CGFloat(PetTokens.Size.chatHeight + PetTokens.Size.chatTail))
        XCTAssertNil(PetChatLayout.saved(chat.bodySize), "the default is saved as nil")
    }
}
