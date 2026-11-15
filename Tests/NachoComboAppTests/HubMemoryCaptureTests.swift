import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 기억 섹션(NACHO-273 U7)을 가짜 HTTP로 장면별·라이트/다크로 그린다. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 테스트 로그(BENTO-CAPTURE 줄)로 CI에 남긴다. 데이터는 모두 가짜다.
final class HubMemoryCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    struct Seen { var method: String; var path: String; var query: String?; var body: String; var key: String? }

    private final class FakeHTTP: PetHTTPClient {
        var seen: [Seen] = []
        var paused = false
        /// (method path) → 상태·본문을 덮어쓴다(오류 시험).
        var overrides: [String: (Int, String)] = [:]
        func count(_ method: String, _ path: String) -> Int { seen.filter { $0.method == method && $0.path == path }.count }

        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            let body = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
            seen.append(Seen(method: request.method, path: request.url.path, query: request.url.query, body: body, key: request.headers["Idempotency-Key"]))
            let key = request.method + " " + request.url.path
            if let o = overrides[key] { return completion(.success(PetHTTPResponse(status: o.0, body: Data(o.1.utf8)))) }
            let ok: (String) -> Void = { completion(.success(PetHTTPResponse(status: 200, body: Data($0.utf8)))) }
            switch key {
            case "GET /api/v1/memory/facts":
                ok("{\"facts\":[" + Self.fact("f1", "커피는 라떼를 좋아해요", "favorites", "user", false, true, seen: true)
                    + "," + Self.fact("f2", "아침에 산책을 해요", "rhythm", "inferred", true, false, seen: false)
                    + "," + Self.fact("f3", "동생 이름은 하나예요", "people", "chat", false, false, seen: true)
                    + "],\"unseen_count\":1,\"has_more\":false}")
            case "GET /api/v1/memory/episodes":
                ok("{\"sections\":[{\"key\":\"2026-11-02\",\"date_label\":\"11월 2일 (월)\",\"count\":1,\"items\":[{\"id\":\"e1\",\"title\":\"공원 산책\",\"summary\":\"하나와 공원을 걸었어요\",\"date\":\"2026-11-02\",\"visibility\":\"shared\",\"version\":2,\"edited_by_user\":false}]}],\"month\":\"2026-11\",\"day_counts\":[]}")
            case "GET /api/v1/memory/episodes/e1":
                ok("{\"id\":\"e1\",\"title\":\"공원 산책\",\"summary\":\"하나와 공원을 걸었어요\",\"date\":\"2026-11-02\",\"visibility\":\"shared\",\"version\":2,\"edited_by_user\":false,\"content\":\"# 공원\\n- 하나와 산책\",\"date_label\":\"11월 2일 (월)\"}")
            case "GET /api/v1/me/memory-settings":
                ok("{\"memory_paused\":\(paused),\"memory_indicator_enabled\":true}")
            case "POST /api/v1/memory/facts":
                completion(.success(PetHTTPResponse(status: 201, body: Data(Self.fact("f9", "새 기억", "other", "user", false, false, seen: false).utf8))))
            case "PATCH /api/v1/memory/facts/f1":
                ok(Self.fact("f1", "커피는 아메리카노를 좋아해요", "favorites", "user", false, true, seen: true, version: 4))
            case "PATCH /api/v1/me/memory-settings":
                ok("{\"memory_paused\":true,\"memory_indicator_enabled\":true}")
            case "POST /api/v1/memory/f3/restore":
                ok("{\"kind\":\"fact\",\"item\":{}}")
            case "DELETE /api/v1/memory/facts/f3", "DELETE /api/v1/memory/episodes/e1":
                completion(.success(PetHTTPResponse(status: 204, body: Data())))
            case "DELETE /api/v1/me/memories":
                ok("{\"deleted\":3}")
            default:
                completion(.success(PetHTTPResponse(status: 404, body: Data("{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}".utf8))))
            }
        }

        static func fact(_ id: String, _ text: String, _ cat: String, _ src: String, _ inferred: Bool, _ edited: Bool, seen: Bool, version: Int = 3) -> String {
            "{\"id\":\"\(id)\",\"text\":\"\(text)\",\"category\":\"\(cat)\",\"visibility\":\"shared\",\"source_type\":\"\(src)\",\"inferred\":\(inferred),\"edited_by_user\":\(edited),\"version\":\(version),\"created_at\":\"2026-11-0\(version)T01:00:00Z\"" + (seen ? ",\"seen_at\":\"2026-11-04T01:00:00Z\"" : "") + "}"
        }
    }

    private func make(_ http: FakeHTTP = FakeHTTP()) -> (PetHubWindow, MemorySection, FakeHTTP) {
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
        let env = HubEnvironment(isSignedIn: { true }, client: { client }, signIn: {})
        let w = PetHubWindow(env: env, autosaveName: nil, initial: .memory)
        settle()
        return (w, w.currentSection as! MemorySection, http)
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all(_ w: PetHubWindow) -> String { texts(w.contentView!).joined(separator: "\n") }

    private func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let t = find(type, in: s) { return t } }
        return nil
    }

    private func capture(_ w: PetHubWindow, name: String) throws {
        for dark in [false, true] {
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.setContentSize(PetHubWindow.defaultSize)
            let root = try XCTUnwrap(w.contentView)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "hub-memory-\(name)-\(dark ? "dark" : "light")")
        }
    }

    // MARK: 장면

    func testListShowsFactsAndLoadsOnlyMemoryPaths() throws {
        let (w, _, http) = make()
        XCTAssertEqual(Set(http.seen.map { $0.method + " " + $0.path }),
                       ["GET /api/v1/memory/facts", "GET /api/v1/memory/episodes", "GET /api/v1/me/memory-settings"])
        let t = all(w)
        for s in ["커피는 라떼를 좋아해요", "아침에 산책을 해요", "새로 기억한 것 1개", "짐작", "내가 고침", "알려 주기", "기억 설정"] { XCTAssertTrue(t.contains(s), "\(s)\n\(t)") }
        XCTAssertFalse(t.contains("지금은 새로 기억하지 않아요"))
        try capture(w, name: "list")
    }

    func testDetailShowsSourceAndActions() throws {
        let (w, sec, _) = make()
        sec.showFact(sec.facts[1])
        let t = all(w)
        for s in ["어디서 알았나요", "대화를 보고 짐작함", "맞아요", "고치기", "잊기"] { XCTAssertTrue(t.contains(s), "\(s)\n\(t)") }
        try capture(w, name: "detail")
    }

    func testEditSendsOnlyChangedFieldWithExpectedVersion() throws {
        let (w, sec, http) = make()
        sec.showFactForm(editing: sec.facts[0])
        let form = try XCTUnwrap(find(MemoryFactForm.self, in: w.contentView!))
        try capture(w, name: "edit")
        form.text.field.stringValue = "커피는 아메리카노를 좋아해요"
        form.submit()
        let patch = try XCTUnwrap(http.seen.first { $0.method == "PATCH" && $0.path == "/api/v1/memory/facts/f1" })
        XCTAssertEqual(patch.body, "{\"expected_version\":3,\"text\":\"커피는 아메리카노를 좋아해요\"}")
        XCTAssertTrue(all(w).contains("커피는 아메리카노를 좋아해요"))
    }

    func testEditConflictReloadsList() throws {
        let http = FakeHTTP()
        http.overrides["PATCH /api/v1/memory/facts/f1"] = (409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"}}")
        let (w, sec, _) = make(http)
        sec.showFactForm(editing: sec.facts[0])
        let form = try XCTUnwrap(find(MemoryFactForm.self, in: w.contentView!))
        form.text.field.stringValue = "다른 내용"
        let before = http.count("GET", "/api/v1/memory/facts")
        form.submit()
        settle()
        XCTAssertEqual(http.count("GET", "/api/v1/memory/facts"), before + 1, "409 → 새로 불러온다")
        XCTAssertTrue(all(w).contains("다른 곳에서 바뀌었어요. 새로 불러올게요."), all(w))
    }

    func testInvalidInputIsNotSent() throws {
        let (w, sec, http) = make()
        sec.showFactForm(editing: nil)
        let form = try XCTUnwrap(find(MemoryFactForm.self, in: w.contentView!))
        form.text.field.stringValue = "   "
        form.submit()
        XCTAssertTrue(all(w).contains("기억할 내용을 써 주세요."))
        form.text.field.stringValue = String(repeating: "가", count: 4001)
        form.submit()
        XCTAssertTrue(all(w).contains("기억은 4000자까지 쓸 수 있어요."))
        XCTAssertEqual(http.count("POST", "/api/v1/memory/facts"), 0)
        try capture(w, name: "add-invalid")
    }

    func testAddSendsBodyAndKeepsKeyAcrossRetry() throws {
        let http = FakeHTTP()
        http.overrides["POST /api/v1/memory/facts"] = (500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
        let (w, sec, _) = make(http)
        sec.showFactForm(editing: nil)
        try capture(w, name: "add")
        let form = try XCTUnwrap(find(MemoryFactForm.self, in: w.contentView!))
        form.text.field.stringValue = "고양이를 좋아해요"
        form.submit()
        XCTAssertTrue(all(w).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."), "입력은 그대로, 오류는 한국어")
        XCTAssertEqual(form.text.field.stringValue, "고양이를 좋아해요")
        form.submit()
        let posts = http.seen.filter { $0.method == "POST" && $0.path == "/api/v1/memory/facts" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].body, "{\"category\":\"other\",\"text\":\"고양이를 좋아해요\",\"visibility\":\"shared\"}")
        XCTAssertNotNil(posts[0].key)
        XCTAssertEqual(posts[0].key, posts[1].key, "재시도는 같은 Idempotency-Key")
    }

    func testPausedShowsBannerAndToggleSendsPatch() throws {
        let http = FakeHTTP()
        http.paused = true
        let (w, sec, _) = make(http)
        XCTAssertTrue(all(w).contains("지금은 새로 기억하지 않아요"))
        try capture(w, name: "paused")
        sec.showSettings()
        let row = try XCTUnwrap(find(HubSwitchRow.self, in: w.contentView!))
        row.toggle.state = .off
        row.onChange?(false)
        let p = try XCTUnwrap(http.seen.first { $0.method == "PATCH" && $0.path == "/api/v1/me/memory-settings" })
        XCTAssertEqual(p.body, "{\"memory_paused\":false}")
        try capture(w, name: "settings")
    }

    func testDeleteAllFlagOffGuidesToPhoneAndSendsNothing() throws {
        let (w, sec, http) = make()
        XCTAssertFalse(sec.deleteAllEnabled, "기본 꺼짐")
        sec.showSettings()
        let t = all(w)
        XCTAssertTrue(t.contains("기억 전체 삭제는 지금은 휴대폰 앱의 설정에서 할 수 있어요."), t)
        XCTAssertFalse(t.contains("기억 전부 지우기"))
        XCTAssertEqual(http.count("DELETE", "/api/v1/me/memories"), 0)
        try capture(w, name: "delete-all-flag-off")
    }

    func testDeleteAllFlagOnShowsButtonAndDeletes() throws {
        let (w, sec, http) = make()
        sec.deleteAllEnabled = true
        sec.showSettings()
        XCTAssertTrue(all(w).contains("기억 전체 삭제"))
        XCTAssertFalse(all(w).contains("휴대폰 앱의 설정"))
        sec.deleteAll()
        XCTAssertEqual(http.count("DELETE", "/api/v1/me/memories"), 1)
    }

    func testForgetThenUndoWithinWindowRestores() throws {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let (_, sec, http) = make()
        var clock = t0
        sec.now = { clock }
        sec.forget(id: "f3", kind: .fact)
        XCTAssertEqual(http.count("DELETE", "/api/v1/memory/facts/f3"), 1)
        XCTAssertFalse(sec.facts.contains { $0.id == "f3" })
        clock = t0.addingTimeInterval(9)
        sec.restore()
        XCTAssertEqual(http.count("POST", "/api/v1/memory/f3/restore"), 1)
    }

    func testUndoAfterTenSecondsDoesNotCallServer() throws {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let (w, sec, http) = make()
        var clock = t0
        sec.now = { clock }
        sec.forget(id: "f3", kind: .fact)
        clock = t0.addingTimeInterval(11)
        sec.restore()
        XCTAssertEqual(http.count("POST", "/api/v1/memory/f3/restore"), 0)
        settle()
        XCTAssertTrue(all(w).contains("되돌릴 시간이 지났어요."), all(w))
    }

    func testServer410RestoreExpiredShowsAppWording() throws {
        let http = FakeHTTP()
        http.overrides["POST /api/v1/memory/f3/restore"] = (410, "{\"error\":{\"code\":\"restore_expired\",\"message\":\"x\"}}")
        let (w, sec, _) = make(http)
        var clock = Date(timeIntervalSince1970: 5_000)
        sec.now = { clock }
        sec.forget(id: "f3", kind: .fact)
        clock = clock.addingTimeInterval(5)
        sec.restore()
        XCTAssertEqual(http.count("POST", "/api/v1/memory/f3/restore"), 1)
        settle()
        XCTAssertTrue(all(w).contains("되돌릴 시간이 지났어요."), all(w))
    }

    func testEpisodeDetailAndEdit() throws {
        let (w, sec, http) = make()
        let ep = try XCTUnwrap(sec.episodes.first)
        sec.showEpisode(ep)
        XCTAssertTrue(all(w).contains("이 추억 잊기"))
        sec.showEpisodeForm(ep)
        let form = try XCTUnwrap(find(MemoryEpisodeForm.self, in: w.contentView!))
        form.title.field.stringValue = ""
        form.submit()
        XCTAssertTrue(all(w).contains("제목과 내용을 모두 써 주세요."))
        XCTAssertEqual(http.count("PATCH", "/api/v1/memory/episodes/e1"), 0)
        try capture(w, name: "episode-edit")
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
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }
}
