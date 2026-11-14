import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-134: the real chat window (PetChatWindow) drawn off screen, light and dark, for the busy-send fix:
/// ① typing while Nacho answers (button = 보내기) ② the waiting bubble ③ after the automatic send ④ **bold** rendered
/// ⑤ the header line cut short, with its tooltip drawn beside it (an off-screen render has no real tooltip).
/// AppKit off-screen on macOS CI, not a real Mac. The conversation is a TEST FIXTURE.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class PetBusySendCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func frame(_ json: String) -> ServerFrame { ServerFrame.decode(json)! }

    private func state(turns: [(id: String, text: String, answer: String, done: Bool)], queued: String? = nil) -> PetSessionState {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.apply(frame(#"{"type":"ready","user_id":"u","agent_id":"a","agent_name":"나초","room_id":"r"}"#))
        for t in turns {
            st.chat.beginTurn(text: t.text, clientMsgID: t.id)
            st.chat.apply(frame(#"{"type":"turn_started","room_id":"r","turn_id":"t-\#(t.id)","duplicate":false,"client_id":"\#(t.id)"}"#))
            if !t.answer.isEmpty {
                let escaped = t.answer.replacingOccurrences(of: "\n", with: "\\n")
                st.chat.apply(frame(#"{"type":"text_delta","room_id":"r","client_id":"\#(t.id)","text":"\#(escaped)"}"#))
            }
            if t.done { st.chat.apply(frame(#"{"type":"done","room_id":"r","client_id":"\#(t.id)","message_id":null,"stopped":false}"#)) }
        }
        st.queuedText = queued
        return st
    }

    private func shoot(_ name: String, dark: Bool, typed: String = "", state st: PetSessionState,
                       prepare: (PetChatWindow) -> Void = { _ in }) throws {
        let chat = PetChatWindow(module: nil, size: nil)
        chat.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        chat.input.stringValue = typed
        chat.applySendButton(busy: st.chat.isBusy, hasText: !typed.isEmpty)
        chat.status.stringValue = PetTranscript.headerLine(st)
        chat.show(items: PetTranscript.items(st, undoSecondsLeft: { _ in nil }))
        prepare(chat)
        let content = try XCTUnwrap(chat.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
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

    private let first = (id: "c1", text: "이번 주 금요일 회식 장소 추천해 줘", answer: "좋아요. 사무실에서 가까운 곳 세 군데를 찾아볼게요. 인원과 예산을 알려 주시면", done: false)

    func testCaptures() throws {
        for dark in [false, true] {
            // ① typing while answering: the button is 보내기, not stop.
            try shoot("busysend-1-typing", dark: dark, typed: "추가로 12명이에요", state: state(turns: [first]))
            // ② the text waits under the answer.
            try shoot("busysend-2-waiting", dark: dark, state: state(turns: [first], queued: "추가로 12명이에요"))
            // ③ after the answer ended the text went out as the next turn.
            let done = (id: "c1", text: first.text, answer: "좋아요. 세 곳을 골랐어요. 인원과 예산을 알려 주세요.", done: true)
            let second = (id: "c2", text: "추가로 12명이에요", answer: "12명이면 단체석이 있는 **숯불 닭갈비집**이 좋아요.", done: false)
            try shoot("busysend-3-sent", dark: dark, state: state(turns: [done, second]))
            // ④ bold and inline markup in Nacho's answer, line breaks kept.
            let bold = (id: "c1", text: "추천해 줘", answer: "이건 **굵게** 보여야 해요.\n둘째 줄에는 *기울임*과 `코드`가 있어요.", done: true)
            try shoot("busysend-4-bold", dark: dark, state: state(turns: [bold]))
            // ⑤ the header line is cut short; its tooltip holds the whole text.
            var st = state(turns: [])
            st.auth = .failed("서버에 연결하는 중에 문제가 생겼어요. 잠시 뒤에 다시 해 주세요.")
            try shoot("busysend-5-header", dark: dark, state: st) { chat in
                chat.status.toolTip = PetTranscript.headerLine(st)
                let label = NSTextField(wrappingLabelWithString: "툴팁: " + PetTranscript.headerLine(st))
                label.font = NSFont.systemFont(ofSize: 12)
                label.textColor = .labelColor
                label.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.75, alpha: 1)
                label.drawsBackground = true
                label.isBordered = true
                label.preferredMaxLayoutWidth = 280
                label.frame = NSRect(x: 40, y: (chat.contentView?.bounds.height ?? 600) - 120, width: 290, height: 40)
                chat.contentView?.addSubview(label)
                XCTAssertEqual(chat.status.toolTip, PetTranscript.headerLine(st))
            }
        }
    }
}
