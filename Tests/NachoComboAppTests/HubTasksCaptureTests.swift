import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 작업 섹션(NACHO-271 U5)을 가짜 HTTP로 장면별·라이트/다크로 그린다. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다.
/// 그림은 .build/bento-captures에 쓰고 base64 조각은 로그(BENTO-CAPTURE 줄)로 남는다. 데이터는 모두 가짜다.
final class HubTasksCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures") }

    private static let t1 = "{\"id\":\"t1\",\"kind\":\"phone\",\"state\":\"running\",\"title\":\"식당 예약\",\"request_text\":\"이번 주 금요일 저녁 7시 두 명\","
        + "\"version\":3,\"steps\":[{\"text\":\"전화 걸기\"},{\"text\":\"자리 확인\"}],\"current_step\":{\"text\":\"자리 확인\",\"index\":2,\"total\":2},"
        + "\"plan_blocks\":[{\"kind\":\"text\",\"text\":\"1. 식당에 전화해 금요일 7시 자리를 물어요\"},{\"kind\":\"text\",\"text\":\"2. 가능하면 두 명으로 예약해요\"}],"
        + "\"credit\":{\"used\":12,\"cap\":40,\"refund_status\":\"none\"},\"requested_at\":\"2026-11-15T01:00:00Z\","
        + "\"call\":{\"call_id\":\"c1\",\"call_state\":\"in_call\",\"counterpart_label\":\"맛있는 식당\",\"phone_name\":\"내 번호\",\"attempts\":1,\"max_attempts\":3}}"
    private static let t2 = "{\"id\":\"t2\",\"kind\":\"task\",\"state\":\"waiting\",\"wait_reason\":\"browser\",\"pending_request_id\":\"r1\",\"title\":\"은행 로그인\","
        + "\"version\":1,\"requested_at\":\"2026-11-15T02:00:00Z\"}"
    private static let t3 = "{\"id\":\"t3\",\"kind\":\"task\",\"state\":\"failed\",\"title\":\"가격 비교\",\"requested_at\":\"2026-11-14T02:00:00Z\","
        + "\"failure\":{\"code\":\"site_blocked\",\"message\":\"m\",\"retryable\":true,\"next_actions\":[\"retry\"],\"completed_actions\":[\"두 곳 확인\"],\"pending_actions\":[\"세 번째 곳\"],\"uncertain_actions\":[]}}"
    private static let t4 = "{\"id\":\"t4\",\"kind\":\"task\",\"state\":\"done\",\"title\":\"일정 정리\",\"requested_at\":\"2026-11-13T02:00:00Z\",\"result_blocks\":[{\"kind\":\"text\",\"text\":\"3건을 옮겼어요\"}]}"

    private final class FakeHTTP: PetHTTPClient {
        var sent: [(method: String, path: String, body: String)] = []
        var empty = false
        func send(_ r: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append((r.method, r.url.path, String(data: r.body ?? Data(), encoding: .utf8) ?? ""))
            var body = "{}"
            switch (r.method, r.url.path) {
            case ("GET", "/api/v1/tasks"):
                body = empty ? "{\"active_items\":[],\"recent_items\":[],\"concurrency\":{\"limit\":3,\"running\":0,\"queued\":0}}"
                    : "{\"active_items\":[\(HubTasksCaptureTests.t1),\(HubTasksCaptureTests.t2)],\"recent_items\":[],\"concurrency\":{\"limit\":3,\"running\":1,\"queued\":0}}"
            case ("GET", "/api/v1/tasks/history"):
                body = empty ? "{\"items\":[]}" : "{\"items\":[\(HubTasksCaptureTests.t3),\(HubTasksCaptureTests.t4)]}"
            case ("GET", "/api/v1/tasks/t1"): body = HubTasksCaptureTests.t1
            case ("GET", "/api/v1/tasks/t1/logs"):
                body = "[{\"id\":1,\"kind\":\"requested\",\"text\":\"요청을 받았어요\",\"created_at\":\"2026-11-15T01:00:00Z\"},{\"id\":2,\"kind\":\"call\",\"text\":\"전화를 걸었어요\",\"created_at\":\"2026-11-15T01:01:00Z\"}]"
            case ("GET", "/api/v1/calls/c1"):
                body = "{\"call\":{\"id\":\"c1\",\"task_id\":\"t1\",\"state\":\"in_call\",\"phone_masked\":\"02-****-1234\",\"counterpart_label\":\"맛있는 식당\",\"purpose\":\"금요일 7시 두 명 예약\","
                    + "\"attempts\":1,\"max_attempts\":3,\"stage\":\"inquiring\",\"credits_used\":2},\"lines\":[{\"id\":1,\"seq\":1,\"speaker\":\"agent\",\"text\":\"안녕하세요, 예약 문의드려요. 저는 AI 비서예요.\"},"
                    + "{\"id\":2,\"seq\":2,\"speaker\":\"counterpart\",\"text\":\"네, 금요일 몇 시요?\"},{\"id\":3,\"seq\":3,\"speaker\":\"user_note\",\"text\":\"창가 자리면 좋아요\"}],"
                    + "\"footer\":{\"credits_used\":2,\"disclosure\":\"나초는 AI 비서예요. 통화 시작에 그렇게 밝혀요.\"}}"
            case ("POST", "/api/v1/live-view/sessions"):
                completion(.success(PetHTTPResponse(status: 201, body: Data("{\"attempt_id\":\"at1\",\"ticket\":\"vt_fake\",\"ws_url\":\"wss://nacho.example.com/ws\",\"viewer_url\":\"https://nacho.example.com/api/v1/remote/viewer#t=vt_fake\",\"expires_at\":\"2026-11-15T02:03:00Z\",\"verified_host\":\"bank.example.com\"}".utf8))))
                return
            default: break
            }
            completion(.success(PetHTTPResponse(status: 200, body: Data(body.utf8))))
        }
    }

    private struct Rig {
        let window: PetHubWindow
        let http: FakeHTTP
        let section: TasksSection
    }

    private func makeRig(empty: Bool = false) throws -> Rig {
        let http = FakeHTTP()
        http.empty = empty
        let client = HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: http, tokens: { _, done in done("fake-token") })
        let env = HubEnvironment(isSignedIn: { true }, client: { client }, signIn: {})
        let w = PetHubWindow(env: env, autosaveName: nil, initial: .tasks)
        return Rig(window: w, http: http, section: try XCTUnwrap(w.currentSection as? TasksSection))
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all(_ r: Rig) -> String { texts(r.window.contentView!).joined(separator: "\n") }

    private func capture(_ r: Rig, name: String) throws {
        for dark in [false, true] {
            r.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            r.window.setContentSize(PetHubWindow.defaultSize)
            let root = try XCTUnwrap(r.window.contentView)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "hub-tasks-\(name)-\(dark ? "dark" : "light")")
        }
    }

    // MARK: scenes

    func testListShowsActivePastAndRequests() throws {
        let r = try makeRig()
        XCTAssertEqual(r.http.sent.map { "\($0.method) \($0.path)" }.sorted(), ["GET /api/v1/tasks", "GET /api/v1/tasks/history"])
        let s = all(r)
        XCTAssertTrue(s.contains("2개 진행 중"), s)
        XCTAssertTrue(s.contains("식당 예약") && s.contains("은행 로그인") && s.contains("가격 비교") && s.contains("일정 정리"), s)
        XCTAssertTrue(s.contains("답하기"), s)
        XCTAssertTrue(s.contains("동시에 1개 하는 중 (최대 3개)"), s)
        try capture(r, name: "list")
    }

    func testEmptyList() throws {
        let r = try makeRig(empty: true)
        XCTAssertTrue(all(r).contains("아직 맡긴 작업이 없어요"), all(r))
        try capture(r, name: "empty")
    }

    func testDetailLogsAndFailure() throws {
        let r = try makeRig()
        r.section.openTask(HubTask(HubObject(["id": "t1", "title": "식당 예약", "state": "running"])))
        XCTAssertTrue(r.http.sent.contains { $0.method == "GET" && $0.path == "/api/v1/tasks/t1" })
        let s = all(r)
        XCTAssertTrue(s.contains("2/2단계 · 자리 확인") && s.contains("이번 주 금요일 저녁 7시 두 명"), s)
        XCTAssertTrue(s.contains("계획 보기") && s.contains("기록 보기") && s.contains("통화 보기"), s)
        XCTAssertTrue(s.contains("지시 추가"), s)
        XCTAssertFalse(s.contains("예약으로 저장"), "끝난 작업만")
        r.section.showDetail(HubTask(HubObject(["id": "t3", "title": "가격 비교", "state": "failed",
                                                "failure": ["code": "site_blocked", "message": "m", "next_actions": ["retry"], "completed_actions": ["두 곳 확인"], "pending_actions": ["세 번째 곳"]]])))
        let f = all(r)
        XCTAssertTrue(f.contains("사이트가 자동 접근을 막았어요") && f.contains("두 곳 확인") && f.contains("세 번째 곳") && f.contains("예약으로 저장"), f)
        XCTAssertFalse(f.contains("지시 추가"), "끝난 작업은 지시를 더할 수 없다")
        try capture(r, name: "detail-failed")
        r.section.openTask(HubTask(HubObject(["id": "t1", "title": "식당 예약", "state": "running"])))
        try capture(r, name: "detail")
    }

    func testLogsAreFetchedOnDemand() throws {
        let r = try makeRig()
        r.section.openTask(HubTask(HubObject(["id": "t1", "title": "식당 예약", "state": "running"])))
        r.section.view.layoutSubtreeIfNeeded()
        let btn = try XCTUnwrap(findButton(r.window.contentView!, "기록 보기"))
        btn.onClick?()
        XCTAssertTrue(r.http.sent.contains { $0.path == "/api/v1/tasks/t1/logs" })
        let s = all(r)
        XCTAssertTrue(s.contains("전화를 걸었어요") && s.contains("요청을 받았어요"), s)
        try capture(r, name: "logs")
    }

    func testPlanScreen() throws {
        let r = try makeRig()
        r.section.showPlan(HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t1.utf8)) as! [String: Any])))
        let s = all(r)
        XCTAssertTrue(s.contains("1. 식당에 전화해 금요일 7시 자리를 물어요") && s.contains("전화 걸기"), s)
        try capture(r, name: "plan")
    }

    func testCallMonitorAndHangupNeedsTwoConfirmations() throws {
        let http = FakeHTTP()
        let client = HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: http, tokens: { _, done in done("T") })
        let section = TasksSection()
        var steps: [[HubConfirmStep]] = []
        var toasts: [String] = []
        section.activate(HubContext(client: client, toast: { t, _ in toasts.append(t) }, confirm: { s, done in steps.append(s); done() }))
        let t = HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t1.utf8)) as! [String: Any]))
        section.openCall(callID: "c1", from: t)
        let s = texts(section.view).joined(separator: "\n")
        XCTAssertTrue(s.contains("통화 중") && s.contains("02-****-1234") && s.contains("안녕하세요, 예약 문의드려요") && s.contains("내 메모: 창가 자리면 좋아요"), s)
        let hang = try XCTUnwrap(findButton(section.view, "끊기"))
        hang.onClick?()
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].count, 2, "끊기는 확인창을 두 번 거친다")
        XCTAssertTrue(http.sent.contains { $0.method == "POST" && $0.path == "/api/v1/tasks/t1/call/hangup" })
        XCTAssertTrue(toasts.contains("전화를 끊었어요"), "\(toasts)")
    }

    func testCallMonitorCapture() throws {
        let r = try makeRig()
        let t = HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t1.utf8)) as! [String: Any]))
        r.section.openCall(callID: "c1", from: t)
        XCTAssertTrue(all(r).contains("메모 보내기"), all(r))
        try capture(r, name: "call")
    }

    func testNoteIsValidatedBeforeSending() throws {
        let http = FakeHTTP()
        let client = HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: http, tokens: { _, done in done("T") })
        let section = TasksSection()
        section.activate(HubContext(client: client, toast: { _, _ in }, confirm: { _, done in done() }))
        section.openCall(callID: "c1", from: HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t1.utf8)) as! [String: Any])))
        let field = try XCTUnwrap(findField(section.view))
        field.field.stringValue = "비밀번호는 1234예요"
        try XCTUnwrap(findButton(section.view, "보내기")).onClick?()
        XCTAssertFalse(http.sent.contains { $0.path.hasSuffix("/call/note") }, "비밀번호가 든 메모는 보내지 않는다")
        field.field.stringValue = "창가로 부탁해요"
        try XCTUnwrap(findButton(section.view, "보내기")).onClick?()
        let note = try XCTUnwrap(http.sent.first { $0.path == "/api/v1/tasks/t1/call/note" })
        XCTAssertEqual(note.body, "{\"text\":\"창가로 부탁해요\"}")
    }

    func testLiveViewOpensOnlyAllowedURLAndShowsFakePage() throws {
        let r = try makeRig()
        let t = HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t2.utf8)) as! [String: Any]))
        XCTAssertTrue(t.canOpenLiveView)
        r.section.liveSurface = { _, _ in HubKit.label("가짜 페이지(시험용)") }
        r.section.showDetail(t)
        try XCTUnwrap(findButton(r.window.contentView!, "원격 화면 열기")).onClick?()
        let sess = try XCTUnwrap(r.http.sent.first { $0.path == "/api/v1/live-view/sessions" })
        XCTAssertEqual(sess.body, "{\"request_id\":\"r1\"}")
        let s = all(r)
        XCTAssertTrue(s.contains("bank.example.com 원격 화면") && s.contains("맥 화면은 서버로 보내지 않아요"), s)
        try capture(r, name: "liveview-sheet")
    }

    func testLiveViewCaptureWithFakePage() throws {
        let r = try makeRig()
        let t = HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t2.utf8)) as! [String: Any]))
        let ticket = try HubTasks.decodeTicket(PetHTTPResponse(status: 201, body: Data("{\"viewer_url\":\"https://nacho.example.com/api/v1/remote/viewer#t=x\",\"verified_host\":\"bank.example.com\"}".utf8))).get()
        r.section.showLiveView(ticket, task: t, makeSurface: { _, _ in
            let box = PetBox(frame: .zero)
            box.fill = PetTheme.color(\.surface)
            box.stroke = PetTheme.color(\.edge)
            let l = HubKit.label("가짜 페이지(시험용): 은행 로그인 화면 자리", color: PetTheme.secondary)
            HubKit.pin(l, in: box, inset: 24)
            return box
        })
        XCTAssertTrue(all(r).contains("가짜 페이지(시험용)"), all(r))
        try capture(r, name: "liveview")
    }

    func testLiveViewRefusesNonServerHostAndHttp() throws {
        let r = try makeRig()
        let t = HubTask(HubObject(try! JSONSerialization.jsonObject(with: Data(Self.t2.utf8)) as! [String: Any]))
        for bad in ["http://nacho.example.com/v#t=x", "https://evil.example.org/v#t=x"] {
            r.section.showDetail(t)
            let ticket = HubViewerTicket(viewerURL: bad, verifiedHost: nil, expiresAt: nil)
            r.section.showLiveView(ticket, task: t)
            XCTAssertFalse(all(r).contains("nacho.example.com 원격 화면"), "\(bad)는 열지 않는다")
            XCTAssertEqual(r.section.screenName, "detail:t2")
        }
    }

    // MARK: helpers

    private func findButton(_ v: NSView, _ title: String) -> PetPill? {
        if let p = v as? PetPill, texts(p).contains(title) { return p }
        for s in v.subviews { if let f = findButton(s, title) { return f } }
        return nil
    }

    private func findField(_ v: NSView) -> HubFormField? {
        if let f = v as? HubFormField { return f }
        for s in v.subviews { if let f = findField(s) { return f } }
        return nil
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
    }
}
