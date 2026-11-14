import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

// NACHO-137 QA (not product code): the real window's button and rendered markdown.
final class PetBusySendQAAppTests: XCTestCase {
    override func setUp() { super.setUp(); _ = NSApplication.shared }

    private func button(_ w: PetChatWindow) -> NSView? {
        func walk(_ v: NSView) -> NSView? {
            if v.toolTip?.hasPrefix("보내기") == true || v.toolTip == "멈추기" { return v }
            for c in v.subviews { if let r = walk(c) { return r } }
            return nil
        }
        return w.contentView.flatMap(walk)
    }

    func testButtonStopOnlyWhenBusyAndEmpty() {
        let w = PetChatWindow(module: nil, size: nil)
        w.contentView?.layoutSubtreeIfNeeded()
        w.applySendButton(busy: true, hasText: false)
        XCTAssertEqual(button(w)!.accessibilityLabel(), "답변 멈추기")
        w.applySendButton(busy: true, hasText: true)
        XCTAssertEqual(button(w)!.accessibilityLabel(), "보내기")
        XCTAssertEqual(button(w)!.toolTip, "보내기 (답이 끝나면 보내요)")
        w.applySendButton(busy: false, hasText: false)
        XCTAssertEqual(button(w)!.accessibilityLabel(), "보내기")
        XCTAssertEqual(button(w)!.toolTip, "보내기")
    }

    func testRenderedBoldAndUnsafeLinks() {
        let s = PetLinkText.markdown("**굵게**\n[승인](nachopet://card?id=1&action=approve) [웹](https://a.co) [파일](file:///x) [js](javascript:alert(1))",
                                     font: NSFont.systemFont(ofSize: 13), color: .labelColor)
        XCTAssertFalse(s.string.contains("**"))
        XCTAssertTrue(s.string.contains("\n"))
        var bold = false
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: 3)) { v, _, _ in
            if let f = v as? NSFont, f.fontDescriptor.symbolicTraits.contains(.bold) { bold = true }
        }
        XCTAssertTrue(bold)
        var schemes: [String] = []
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { v, _, _ in
            if let u = v as? URL { schemes.append(u.scheme ?? "") }
        }
        XCTAssertEqual(schemes, ["https"])
        let mine = PetLinkText.plain("**내 말** 그대로", font: NSFont.systemFont(ofSize: 13), color: .labelColor)
        XCTAssertEqual(mine.string, "**내 말** 그대로")
    }

    /// The dark header capture was cut in the CI log (one chunk lost at the test-case boundary): shoot it again, flushed.
    func testDarkHeaderCaptureAgain() throws {
        var st = PetSessionState()
        st.auth = .failed("서버에 연결하는 중에 문제가 생겼어요. 잠시 뒤에 다시 해 주세요.")
        let chat = PetChatWindow(module: nil, size: nil)
        chat.appearance = NSAppearance(named: .darkAqua)
        chat.applySendButton(busy: false, hasText: false)
        chat.status.stringValue = PetTranscript.headerLine(st)
        chat.status.toolTip = PetTranscript.headerLine(st)
        chat.show(items: PetTranscript.items(st, undoSecondsLeft: { _ in nil }))
        let label = NSTextField(wrappingLabelWithString: "툴팁: " + PetTranscript.headerLine(st))
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.75, alpha: 1)
        label.drawsBackground = true
        label.isBordered = true
        label.preferredMaxLayoutWidth = 280
        label.frame = NSRect(x: 40, y: (chat.contentView?.bounds.height ?? 600) - 120, width: 290, height: 40)
        chat.contentView?.addSubview(label)
        let content = try XCTUnwrap(chat.contentView)
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let b64 = png.base64EncodedString()
        var i = 0, idx = b64.startIndex
        let n = (b64.count + 1999) / 2000
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: 2000, limitedBy: b64.endIndex) ?? b64.endIndex
            print("QACAP hdrdark \(i + 1)/\(n) \(b64[idx..<end])\n")
            fflush(stdout)
            idx = end; i += 1
        }
        Thread.sleep(forTimeInterval: 1)
    }
}
