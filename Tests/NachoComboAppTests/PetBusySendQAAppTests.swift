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
}
