import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-276 (U10): the real chat window (PetChatWindow) drawn off screen, light and dark: ① a room from the hub open
/// (name in the header, way back) ② a group room with who spoke ③ the two questions before a message is erased.
/// Also: the erase menu on my own bubble, and the hub's 「대화창에서 이어 말하기」 handing the room over.
/// AppKit off-screen render on macOS CI, not a real Mac. All names and messages are TEST FIXTURES.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class PetMultiRoomCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func frame(_ json: String) -> ServerFrame { ServerFrame.decode(json)! }

    private func groupState() -> PetSessionState {
        var st = PetSessionState()
        st.auth = .signedIn
        st.chat.apply(frame(#"{"type":"ready","user_id":"u1","agent_id":"a","agent_name":"나초","room_id":"home"}"#))
        st.chat.apply(frame(#"{"type":"usage","usage":{"remaining":180}}"#))
        st.chat.switchRoom(id: "g1", title: "주말 제주 여행", kind: "group")
        let msgs = [
            #"{"id":"m1","seq":1,"role":"user","sender_user_id":"u2","sender_name_snapshot":"민수","text":"토요일 아침 비행기 어때?"}"#,
            #"{"id":"m2","seq":2,"role":"assistant","sender_kind":"agent","sender_name_snapshot":"모카","text":"오전 9시 출발이 제일 싸요. 렌터카는 제가 알아볼게요."}"#,
            #"{"id":"m3","seq":3,"role":"user","sender_user_id":"u1","text":"좋아요, 그걸로 해요"}"#,
            #"{"id":"m4","seq":4,"role":"assistant","sender_kind":"agent","sender_name_snapshot":"나초","text":"일정표를 문서로 만들어 둘게요."}"#,
        ]
        for m in msgs { st.chat.apply(frame(#"{"type":"message","room_id":"g1","message":\#(m)}"#)) }
        return st
    }

    private func shoot(_ name: String, dark: Bool, state st: PetSessionState, ask: Int? = nil) throws {
        let chat = PetChatWindow(module: nil, size: nil)
        chat.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        chat.applyRoomHeader(PetTranscript.roomHeader(st.chat))
        chat.status.stringValue = (PetTranscript.roomHeader(st.chat).map { $0.subtitle + " · " } ?? "") + PetTranscript.headerLine(st)
        var items = PetTranscript.items(st, undoSecondsLeft: { _ in nil }, redactable: true)
        if let step = ask { items.append(.line(PetTranscript.redactConfirm(step: step))) }
        chat.show(items: items)
        let content = try XCTUnwrap(chat.contentView)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let label = "multiroom-\(name)-\(dark ? "dark" : "light")"
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
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

    func testCaptures() throws {
        for dark in [false, true] {
            // ① another room open: the header names it, the chevron goes back to the Nacho.
            var empty = groupState()
            empty.chat.switchRoom(id: "d1", title: "민수", kind: "direct")
            empty.chat.apply(frame(#"{"type":"message","room_id":"d1","message":{"id":"x1","seq":1,"role":"user","sender_user_id":"u2","sender_name_snapshot":"민수","text":"오늘 저녁에 시간 돼?"}}"#))
            empty.chat.apply(frame(#"{"type":"message","room_id":"d1","message":{"id":"x2","seq":2,"role":"user","sender_user_id":"u1","text":"응, 7시 이후에 괜찮아"}}"#))
            try shoot("1-other-room", dark: dark, state: empty)
            // ② group room: a name above each bubble that is not mine.
            try shoot("2-group", dark: dark, state: groupState())
            // ③ erasing: the first question, then the one that says it cannot be undone.
            try shoot("3-redact-ask1", dark: dark, state: groupState(), ask: 1)
            try shoot("4-redact-ask2", dark: dark, state: groupState(), ask: 2)
        }
    }

    func testOnlyMyBubbleHasTheEraseMenu() throws {
        let chat = PetChatWindow(module: nil, size: nil)
        chat.show(items: PetTranscript.items(groupState(), undoSecondsLeft: { _ in nil }, redactable: true))
        var menus: [(String, NSMenu?)] = []
        func walk(_ v: NSView) {
            if let t = v as? PetLinkText { menus.append((t.string, t.messageMenu)) }
            v.subviews.forEach(walk)
        }
        walk(try XCTUnwrap(chat.contentView))
        let mine = try XCTUnwrap(menus.first { $0.0 == "좋아요, 그걸로 해요" })
        XCTAssertEqual(mine.1?.items.map { $0.title }, ["메시지 지우기…"])
        for (text, menu) in menus where text != "좋아요, 그걸로 해요" { XCTAssertNil(menu, "\(text) has no erase menu") }
    }

    func testHeaderBackButtonShowsOnlyInAnotherRoom() throws {
        let chat = PetChatWindow(module: nil, size: nil)
        func labels(_ v: NSView) -> [String] {
            var out: [String] = []
            if let p = v as? PetPill, !p.isHidden, let l = p.accessibilityLabel() { out.append(l) }
            for s in v.subviews where !s.isHidden { out += labels(s) }
            return out
        }
        let root = try XCTUnwrap(chat.contentView)
        XCTAssertFalse(labels(root).contains("나초와 대화로 돌아가기"))
        chat.applyRoomHeader(PetTranscript.roomHeader(groupState().chat))
        XCTAssertTrue(labels(root).contains("나초와 대화로 돌아가기"))
        chat.applyRoomHeader(nil)
        XCTAssertFalse(labels(root).contains("나초와 대화로 돌아가기"))
    }

    func testHubHandsTheRoomToTheChat() throws {
        let room = HubRoom(HubObject(["id": "g1", "kind": "group", "title": "주말 제주 여행"]))!
        XCTAssertFalse(HubRooms.continueInChatEnabled, "nothing to open it with yet")
        var opened: [HubRoom] = []
        HubRooms.chatOpener = { opened.append($0) }
        defer { HubRooms.chatOpener = nil }
        XCTAssertTrue(HubRooms.continueInChatEnabled)
        HubRooms.openInChat(room: room)
        XCTAssertEqual(opened.map { $0.id }, ["g1"])
        XCTAssertEqual(opened.first?.displayTitle, "주말 제주 여행")
    }
}
