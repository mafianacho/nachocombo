import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 허브 대화 섹션(NACHO-269 U3)을 가짜 HTTP로 장면별·라이트/다크로 그린다. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 테스트 로그(BENTO-CAPTURE 줄)로 CI에 남긴다. 데이터는 모두 가짜다. 운영 서버는 부르지 않는다.
final class HubRoomsCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    // MARK: 가짜 서버

    private struct Reply {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        init(_ status: Int = 200, _ json: String = "", headers: [String: String] = [:]) {
            self.status = status
            body = Data(json.utf8)
            self.headers = headers
        }
        init(bytes: Data) { body = bytes }
    }

    private final class FakeHTTP: PetHTTPClient {
        var routes: [String: Reply] = [:]
        var sent: [PetHTTPRequest] = []
        var hold = false
        var held: [(PetHTTPRequest, (Result<PetHTTPResponse, Error>) -> Void)] = []
        var lines: [String] { sent.map { $0.method + " " + ($0.url.path + ($0.url.query.map { "?" + $0 } ?? "")) } }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            if hold { held.append((request, completion)); return }
            completion(.success(answer(request)))
        }
        func answer(_ request: PetHTTPRequest) -> PetHTTPResponse {
            let r = routes[request.method + " " + request.url.path] ?? Reply(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
            return PetHTTPResponse(status: r.status, headers: r.headers, body: r.body)
        }
    }

    private let r1 = "{\"id\":\"r1\",\"kind\":\"direct\",\"title\":\"제주 여행 계획\",\"stored\":false,\"version\":3,\"last_seq\":12,\"read_seq\":10,\"muted\":false,\"updated_at\":\"2026-11-14T01:00:00Z\"}"
    private let c1 = "{\"id\":\"c1\",\"kind\":\"character\",\"stored\":false,\"version\":1,\"last_seq\":3,\"read_seq\":3,\"updated_at\":\"2026-11-13T01:00:00Z\"}"
    private let g1 = "{\"id\":\"g1\",\"kind\":\"group\",\"title\":\"가족 단톡\",\"stored\":false,\"version\":2,\"last_seq\":40,\"read_seq\":40,\"member_counts\":{\"users\":3,\"agents\":2},\"updated_at\":\"2026-11-12T01:00:00Z\"}"
    private let s1 = "{\"id\":\"s1\",\"kind\":\"direct\",\"title\":\"지난 프로젝트\",\"stored\":true,\"version\":5,\"last_seq\":99,\"read_seq\":99,\"updated_at\":\"2026-10-01T01:00:00Z\"}"

    private func fake() -> FakeHTTP {
        let h = FakeHTTP()
        h.routes["GET /api/v1/rooms/sync"] = Reply(200, "{\"rooms\":[\(c1)],\"extra_conversations\":[\(r1),\(g1)],\"unseen_request_count\":0}")
        h.routes["GET /api/v1/rooms"] = Reply(200, "[\(s1)]")
        h.routes["GET /api/v1/rooms/r1"] = Reply(200, r1)
        h.routes["PATCH /api/v1/rooms/r1"] = Reply(200, r1.replacingOccurrences(of: "제주 여행 계획", with: "제주 3박 4일"))
        h.routes["DELETE /api/v1/rooms/r1"] = Reply(204)
        h.routes["GET /api/v1/rooms/r1/history"] = Reply(200, "["
            + "{\"seq\":10,\"role\":\"user\",\"sender_kind\":\"user\",\"text\":\"제주도 일정 짜 줘\",\"created_at\":\"2026-11-14T00:50:00Z\",\"attachments\":[]},"
            + "{\"seq\":11,\"role\":\"assistant\",\"sender_kind\":\"agent\",\"sender_name_snapshot\":\"나초\",\"text\":\"3박 4일 일정을 문서로 만들었어요.\",\"created_at\":\"2026-11-14T00:51:00Z\",\"attachments\":[],"
            + "\"attachment\":{\"file_id\":\"p1\",\"name\":\"제주 3박 4일\",\"kind\":\"page\",\"deleted\":false}},"
            + "{\"seq\":12,\"role\":\"user\",\"sender_kind\":\"user\",\"text\":\"사진도 보낼게\",\"created_at\":\"2026-11-14T01:00:00Z\","
            + "\"attachments\":[{\"kind\":\"image\",\"attachment_id\":\"a1\",\"name\":\"해변.png\",\"mime\":\"image/png\",\"deleted\":false}]}]",
            headers: ["X-Has-More": "true"])
        h.routes["GET /api/v1/rooms/r1/media"] = Reply(200, "{\"photos\":[{\"kind\":\"image\",\"attachment_id\":\"a1\",\"name\":\"해변.png\",\"mime\":\"image/png\",\"bytes\":204800},"
            + "{\"kind\":\"video\",\"attachment_id\":\"a3\",\"name\":\"파도.mp4\",\"mime\":\"video/mp4\",\"bytes\":5242880}],\"total\":2,\"backfill_complete\":true}")
        h.routes["GET /api/v1/rooms/r1/files"] = Reply(200, "{\"items\":[{\"seq\":8,\"name\":\"항공권.pdf\",\"mime\":\"application/pdf\",\"bytes\":102400,\"attachment_id\":\"a2\"}]}")
        h.routes["GET /api/v1/rooms/r1/links"] = Reply(200, "{\"items\":[{\"seq\":6,\"url\":\"https://example.com/jeju\"},{\"seq\":5,\"url\":\"https://example.com/hotel\"}]}")
        h.routes["POST /api/v1/messages/search"] = Reply(200, "[{\"id\":\"m1\",\"kind\":\"chat\",\"segments\":[{\"text\":\"올해는 \",\"match\":false},{\"text\":\"제주\",\"match\":true},{\"text\":\"도에 가요\",\"match\":false}],"
            + "\"label\":\"제주 여행 계획\",\"date_label\":\"2026.11.14\",\"room_id\":\"r1\",\"seq\":10,\"created_at\":\"2026-11-14T00:50:00Z\"}]")
        h.routes["GET /api/v1/pages/p1"] = Reply(200, "{\"id\":\"p1\",\"title\":\"제주 3박 4일\",\"blocks\":[{\"type\":\"heading\",\"text\":\"1일차\"},"
            + "{\"type\":\"paragraph\",\"text\":\"**공항**에서 만나 렌터카를 받아요.\"},{\"type\":\"list\",\"items\":[\"여권\",\"충전기\",\"선글라스\"]},"
            + "{\"type\":\"table\",\"rows\":[[\"시간\",\"할 일\"],[\"9시\",\"출발\"],[\"12시\",\"점심\"]]},{\"type\":\"link\",\"text\":\"숙소 지도\",\"href\":\"https://example.com/map\"},{\"type\":\"hologram\"}]}")
        h.routes["GET /api/v1/pages/p1/download"] = Reply(200, "# 제주 3박 4일\n")
        h.routes["GET /api/v1/media/a1"] = Reply(bytes: png())
        h.routes["DELETE /api/v1/media/a1"] = Reply(204)
        return h
    }

    private func png() -> Data {
        let img = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor(calibratedRed: 0.35, green: 0.6, blue: 0.85, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 230, y: 100, width: 50, height: 50)).fill()
            return true
        }
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func make(_ http: FakeHTTP, signedIn: Bool = true) -> (PetHubWindow, RoomsSection) {
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
        let env = HubEnvironment(isSignedIn: { signedIn }, client: { signedIn ? client : nil }, signIn: {})
        let w = PetHubWindow(env: env, autosaveName: nil, initial: .rooms)
        return (w, (w.currentSection as? RoomsSection) ?? RoomsSection())
    }

    private func room(_ json: String) -> HubRoom {
        HubRoom(HubObject((try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]))!
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        if let t = v as? NSTextView { out.append(t.string) }
        if let p = v as? PetPill, let l = p.accessibilityLabel() { out.append(l) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all(_ w: PetHubWindow) -> String { texts(w.contentView!).joined(separator: "\n") }

    private func pill(_ w: PetHubWindow, _ title: String) -> PetPill? {
        func find(_ v: NSView) -> PetPill? {
            if let p = v as? PetPill, p.accessibilityLabel() == title { return p }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return find(w.contentView!)
    }

    private func capture(_ w: PetHubWindow, name: String) throws {
        for dark in [false, true] {
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.setContentSize(PetHubWindow.defaultSize)
            let root = try XCTUnwrap(w.contentView)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            try snapshot(root, dark: dark, name: name)
        }
    }

    private func snapshot(_ root: NSView, dark: Bool, name: String) throws {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try emit(data, name: "rooms-\(name)-\(dark ? "dark" : "light")")
    }

    // MARK: B6 목록·보관함

    func testListShowsRoomsFromSyncAndCaptures() throws {
        let http = fake()
        let (w, _) = make(http)
        XCTAssertEqual(http.lines, ["GET /api/v1/rooms/sync"])
        let t = all(w)
        for s in ["제주 여행 계획", "가족 단톡", "나초와의 대화", "안 읽음 2", "단톡방 · 5명", "대화", "보관한 대화"] { XCTAssertTrue(t.contains(s), "\(s) in:\n\(t)") }
        try capture(w, name: "list")
    }

    func testStoredTabAsksForStoredRooms() throws {
        let http = fake()
        let (w, section) = make(http)
        pill(w, "보관한 대화")?.onClick?()
        XCTAssertEqual(section.listTab, .stored)
        XCTAssertEqual(http.lines.last, "GET /api/v1/rooms?stored=true&limit=50")
        XCTAssertTrue(all(w).contains("지난 프로젝트"))
        try capture(w, name: "stored")
    }

    func testEmptyStoredShowsGuide() throws {
        let http = fake()
        http.routes["GET /api/v1/rooms"] = Reply(200, "[]")
        let (w, section) = make(http)
        section.listTab = .stored
        section.load()
        XCTAssertTrue(all(w).contains("넣어둔 대화가 없어요."))
    }

    func testListErrorShowsKoreanAndRetry() throws {
        let http = fake()
        http.routes["GET /api/v1/rooms/sync"] = Reply(500, "oops")
        let (w, _) = make(http)
        let t = all(w)
        XCTAssertTrue(t.contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."), t)
        XCTAssertTrue(t.contains("다시 시도"), t)
        try capture(w, name: "list-error")
    }

    func testSignedOutAsksNothing() {
        let http = fake()
        let (w, _) = make(http, signedIn: false)
        XCTAssertTrue(http.sent.isEmpty)
        XCTAssertTrue(all(w).contains("나초 계정으로 로그인해 주세요"))
    }

    // MARK: B8 검색

    func testSearchRejectsBlankWithoutAskingAndShowsResults() throws {
        let http = fake()
        let (w, section) = make(http)
        section.searchForm.field.stringValue = "  •• "
        section.searchSubmitted()
        XCTAssertEqual(http.lines, ["GET /api/v1/rooms/sync"], "빈 검색어는 서버를 부르지 않는다")
        XCTAssertTrue(all(w).contains("검색어를 입력해 주세요."))
        section.searchForm.field.stringValue = " 제주 "
        section.searchSubmitted()
        XCTAssertEqual(http.lines.last, "POST /api/v1/messages/search")
        XCTAssertEqual(String(data: http.sent.last!.body ?? Data(), encoding: .utf8), "{\"limit\":50,\"query\":\"제주\"}")
        let t = all(w)
        XCTAssertTrue(t.contains("‘제주’ 검색 결과"), t)
        XCTAssertTrue(t.contains("올해는 제주도에 가요"), t)
        try capture(w, name: "search")
    }

    func testSearchNoResultAndServerError() throws {
        let http = fake()
        http.routes["POST /api/v1/messages/search"] = Reply(200, "[]")
        let (w, section) = make(http)
        section.searchForm.field.stringValue = "없는말"
        section.searchSubmitted()
        XCTAssertTrue(all(w).contains("찾는 말이 없어요."))
        http.routes["POST /api/v1/messages/search"] = Reply(400, "{\"error\":{\"code\":\"validation_error\",\"message\":\"x\"}}")
        section.searchForm.field.stringValue = "제주"
        section.searchSubmitted()
        XCTAssertTrue(all(w).contains("제주 여행 계획"), "오류면 목록으로 돌아간다")
        XCTAssertFalse(all(w).isEmpty)
    }

    func testSearchResultOpensItsRoom() throws {
        let http = fake()
        let (w, section) = make(http)
        section.openRoom("r1")
        XCTAssertEqual(http.lines.suffix(2), ["GET /api/v1/rooms/r1", "GET /api/v1/rooms/r1/history?view=app&limit=50"])
        XCTAssertTrue(all(w).contains("제주도 일정 짜 줘"))
    }

    // MARK: B6 읽기 전용 기록 · B7 관리

    func testRoomHistoryShowsMessagesNewestFirstAndDisabledContinueButton() throws {
        let http = fake()
        let (w, _) = make(http)
        (w.currentSection as! RoomsSection).openRoom("r1")
        let t = all(w)
        for s in ["제주 여행 계획", "자유 대화", "이름 바꾸기", "보관", "삭제", "대화창에서 이어 말하기", "기록", "사진·동영상", "파일", "링크",
                  "제주도 일정 짜 줘", "문서: 제주 3박 4일", "첨부: 해변.png", "더 보기"] { XCTAssertTrue(t.contains(s), "\(s) in:\n\(t)") }
        let a = t.range(of: "사진도 보낼게")!.lowerBound, b = t.range(of: "제주도 일정 짜 줘")!.lowerBound
        XCTAssertTrue(a < b, "최근 대화가 위")
        let cont = try XCTUnwrap(pill(w, "대화창에서 이어 말하기"))
        XCTAssertFalse(cont.isEnabled, "U10 전까지 꺼 둔다")
        cont.onClick?()
        XCTAssertFalse(HubRooms.continueInChatEnabled)
        try capture(w, name: "room-history")
    }

    func testOneToOneRoomCannotBeRenamedOrDeleted() throws {
        let http = fake()
        http.routes["GET /api/v1/rooms/c1"] = Reply(200, c1)
        http.routes["GET /api/v1/rooms/c1/history"] = Reply(200, "[]")
        let (w, section) = make(http)
        section.openRoom("c1")
        XCTAssertNil(pill(w, "이름 바꾸기"))
        XCTAssertNil(pill(w, "삭제"))
        XCTAssertTrue(all(w).contains("아직 대화가 없어요."))
    }

    func testRenameValidationAndRequest() throws {
        let http = fake()
        let (w, section) = make(http)
        section.openRoom("r1")
        pill(w, "이름 바꾸기")?.onClick?()
        XCTAssertTrue(all(w).contains("대화 이름"))
        let before = http.sent.count
        section.rename(room(r1), to: "제주 3박 4일", form: nil)
        let patch = try XCTUnwrap(http.sent.last { $0.method == "PATCH" })
        XCTAssertEqual(patch.url.path, "/api/v1/rooms/r1")
        XCTAssertEqual(String(data: patch.body ?? Data(), encoding: .utf8), "{\"expected_version\":3,\"title\":\"제주 3박 4일\"}")
        XCTAssertGreaterThan(http.sent.count, before)
        XCTAssertTrue(all(w).contains("제주 3박 4일"), "이름이 바뀐 방이 다시 그려진다")
        try capture(w, name: "room-renamed")
    }

    func testRenameVersionConflictReloadsRoom() throws {
        let http = fake()
        http.routes["PATCH /api/v1/rooms/r1"] = Reply(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}")
        let (w, section) = make(http)
        section.openRoom("r1")
        let n = http.sent.count
        section.rename(room(r1), to: "새 이름", form: nil)
        XCTAssertEqual(http.lines.suffix(3).first, "PATCH /api/v1/rooms/r1")
        XCTAssertTrue(http.lines.suffix(2).contains("GET /api/v1/rooms/r1"), "409면 새로 불러온다")
        XCTAssertGreaterThan(http.sent.count, n)
        _ = w
    }

    func testStoreSendsStoredAndExpectedVersion() throws {
        let http = fake()
        let (_, section) = make(http)
        section.setStored(room(r1), true)
        XCTAssertEqual(http.lines.suffix(2).first, "PATCH /api/v1/rooms/r1")
        XCTAssertEqual(String(data: http.sent[http.sent.count - 2].body ?? Data(), encoding: .utf8), "{\"expected_version\":3,\"stored\":true}")
        XCTAssertEqual(http.lines.last, "GET /api/v1/rooms/sync", "보관하면 목록을 새로 불러온다")
    }

    func testDeleteIsDoubleConfirmedAndSends() throws {
        let http = fake()
        let (w, section) = make(http)
        let steps = section.deleteSteps(room(r1))
        XCTAssertEqual(steps.count, 2, "확인창을 두 번")
        XCTAssertTrue(steps[0].message.contains("제주 여행 계획"))
        for dark in [false, true] {
            for (i, step) in steps.enumerated() {
                let card = HubConfirmCard(step: step, onCancel: {}, onConfirm: {})
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 240))
                host.wantsLayer = true
                host.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor
                host.addSubview(card)
                NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: host.centerXAnchor), card.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
                let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(texts(card).contains(step.title))
                try snapshot(host, dark: dark, name: "delete-confirm\(i + 1)")
            }
        }
        // 확인창은 시트라 시험에서 누를 수 없다: 확정 뒤에 불리는 `deleteRoom`이 요청을 보내고 목록을 새로 부르는지 본다.
        let before = http.sent.count
        section.deleteRoom(room(r1))
        XCTAssertEqual(http.lines[before], "DELETE /api/v1/rooms/r1")
        XCTAssertNil(http.sent[before].body)
        XCTAssertEqual(http.lines.last, "GET /api/v1/rooms/sync")
        _ = w
    }

    func testDeleteNotFoundAndForbiddenAreExplained() throws {
        let http = fake()
        let (w, section) = make(http)
        http.routes["DELETE /api/v1/rooms/r1"] = Reply(404, "{}")
        section.deleteRoom(room(r1))
        spin()
        XCTAssertTrue(texts(w.toastContainer).contains("이미 지워진 대화예요."), texts(w.toastContainer).joined())
        http.routes["DELETE /api/v1/rooms/r1"] = Reply(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"m\",\"reason\":\"agreement_active\"}}")
        let n = http.sent.count
        section.deleteRoom(room(r1))
        XCTAssertEqual(http.lines[n], "DELETE /api/v1/rooms/r1")
        XCTAssertEqual(http.sent.count, n + 1, "409면 목록을 다시 부르지 않는다")
    }

    func testWriteResultSurvivesSwitchingSection() throws {
        let http = fake()
        let (w, section) = make(http)
        http.hold = true
        section.rename(room(r1), to: "제주 3박 4일", form: nil)
        w.select(.usage)
        XCTAssertEqual(http.held.count, 2, "수정 요청과 사용량 요청")
        let patch = try XCTUnwrap(http.held.first { $0.0.method == "PATCH" })
        patch.1(.success(http.answer(patch.0)))
        spin()
        XCTAssertTrue(texts(w.toastContainer).contains("이름을 바꿨어요."), "다른 섹션에 있어도 결과 토스트가 뜬다: \(texts(w.toastContainer))")
    }

    // MARK: B12 미디어·파일·링크

    func testMediaFilesLinksTabs() throws {
        let http = fake()
        let (w, section) = make(http)
        section.openRoom("r1")
        pill(w, "사진·동영상")?.onClick?()
        XCTAssertEqual(http.lines.last, "GET /api/v1/rooms/r1/media")
        XCTAssertTrue(all(w).contains("해변.png") && all(w).contains("파도.mp4") && all(w).contains("200KB"), all(w))
        try capture(w, name: "media")
        pill(w, "파일")?.onClick?()
        XCTAssertEqual(http.lines.last, "GET /api/v1/rooms/r1/files")
        XCTAssertTrue(all(w).contains("항공권.pdf"))
        try capture(w, name: "files")
        pill(w, "링크")?.onClick?()
        XCTAssertEqual(http.lines.last, "GET /api/v1/rooms/r1/links")
        XCTAssertTrue(all(w).contains("https://example.com/jeju"))
        try capture(w, name: "links")
    }

    func testEmptyMediaAndErrorAreExplained() throws {
        let http = fake()
        http.routes["GET /api/v1/rooms/r1/media"] = Reply(200, "{\"photos\":[],\"total\":0}")
        http.routes["GET /api/v1/rooms/r1/files"] = Reply(404, "{\"error\":{\"code\":\"not_member\",\"message\":\"x\"}}")
        let (w, section) = make(http)
        section.showRoom(room(r1), tab: .photos)
        XCTAssertTrue(all(w).contains("아직 사진이나 동영상이 없어요."))
        section.showRoom(room(r1), tab: .files)
        XCTAssertTrue(all(w).contains("이 대화방에 들어갈 수 없어요."), all(w))
    }

    // MARK: B11 페이지·받은 파일

    func testPageViewShowsBlocksAndKeepsUnknownGraceful() throws {
        let http = fake()
        let (w, section) = make(http)
        section.openPage("p1", title: "제주 3박 4일", back: {})
        XCTAssertEqual(http.lines.last, "GET /api/v1/pages/p1")
        let t = all(w)
        for s in ["제주 3박 4일", "1일차", "공항에서 만나 렌터카를 받아요.", "•  여권", "시간", "출발", "숙소 지도", "이 부분은 표시할 수 없어요.", "내려받기"] {
            XCTAssertTrue(t.contains(s), "\(s) in:\n\(t)")
        }
        try capture(w, name: "page")
    }

    func testPageNotFoundGoesBackWithToast() throws {
        let http = fake()
        http.routes["GET /api/v1/pages/p1"] = Reply(404, "{}")
        let (w, section) = make(http)
        var backed = false
        section.openPage("p1", title: "x", back: { backed = true })
        spin()
        XCTAssertTrue(backed)
        XCTAssertTrue(texts(w.toastContainer).contains("지워졌거나 열 수 없는 문서예요."))
    }

    func testMediaPreviewAndDeleteRequest() throws {
        let http = fake()
        let (w, section) = make(http)
        let item = HubMediaItem(id: "a1", kind: "image", name: "해변.png", mime: "image/png", bytes: 204_800, seq: 12, deleted: false)
        section.openMedia(item, room: room(r1), tab: .photos)
        XCTAssertEqual(http.lines.last, "GET /api/v1/media/a1")
        XCTAssertTrue(all(w).contains("해변.png"))
        XCTAssertNotNil(pill(w, "삭제"))
        XCTAssertNotNil(pill(w, "저장…"))
        try capture(w, name: "media-preview")
        var backed = false
        section.deleteMedia(item, back: { backed = true })
        XCTAssertEqual(http.lines.last, "DELETE /api/v1/media/a1")
        XCTAssertNil(http.sent.last!.body)
        XCTAssertTrue(backed)
        http.routes["DELETE /api/v1/media/a1"] = Reply(404, "{}")
        backed = false
        section.deleteMedia(item, back: { backed = true })
        spin()
        XCTAssertTrue(backed, "이미 지워졌으면 목록으로 돌아간다")
    }

    func testFileWithoutPreviewShowsSaveOnly() throws {
        let http = fake()
        let (w, section) = make(http)
        let item = HubMediaItem(id: "a2", kind: "file", name: "항공권.pdf", mime: "application/pdf", bytes: 102_400, seq: 8, deleted: false)
        section.openMedia(item, room: room(r1), tab: .files)
        XCTAssertFalse(http.lines.contains("GET /api/v1/media/a2"), "이미지가 아니면 미리 받지 않는다")
        XCTAssertTrue(all(w).contains("이 파일은 미리 볼 수 없어요. 저장해서 열어 보세요."))
    }

    // MARK: 도우미

    private func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

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
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }
}
