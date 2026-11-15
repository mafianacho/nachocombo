import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 예약 섹션(NACHO-272 U6)을 가짜 HTTP로 장면별·라이트/다크로 그리고 동작을 확인한다.
/// macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 데이터는 모두 가짜. 운영 서버는 부르지 않는다.
final class HubSchedulesCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures") }

    private func sched(_ id: String, title: String, recurrence: String = "repeat", paused: Bool = false, reason: String? = nil,
                       estimate: String = "E1", test: String? = nil) -> String {
        var s = "{\"schedule_id\":\"\(id)\",\"id\":\"\(id)\",\"agent_id\":\"a1\",\"agent_name\":\"나초\",\"header_title\":\"\(title)\",\"title\":\"\(title)\","
        s += "\"subtitle\":\"\",\"action_text\":\"새 메일을 확인해 줘\",\"action_blocks\":[],\"schedule_text\":\"매일 09:00\",\"recurrence\":\"\(recurrence)\",\"paused\":\(paused),"
        if let r = reason { s += "\"paused_reason\":\"\(r)\"," }
        s += "\"registered\":true,\"next_run_at\":\"2026-11-16T00:00:00Z\",\"credential_mode\":\"per_use_approval\",\"deletable\":true,"
        s += "\"credit\":{\"estimate_min\":5,\"estimate_max\":10,\"task_label\":\"메일\"},\"estimate_id\":\"\(estimate)\",\"last_run_status\":\"done\","
        s += "\"monthly_estimate_text\":\"한 달 약 150~300크레딧\",\"over_plan_warning\":false,"
        if let t = test { s += "\"test_unavailable_reason\":\"\(t)\"," }
        s += "\"runs\":[{\"run_id\":\"R1\",\"id\":\"R1\",\"started_at\":\"2026-11-15T00:00:00Z\",\"status\":\"done\",\"has_result\":true},"
        s += "{\"run_id\":\"R2\",\"id\":\"R2\",\"started_at\":\"2026-11-14T00:00:00Z\",\"status\":\"skipped\",\"has_result\":false,\"skipped_reason\":\"credits_exhausted\"}],"
        s += "\"draft_steps\":[],\"variable_fields\":[],\"fixed_fields\":[],\"connections\":[],\"version\":3,\"created_at\":\"2026-11-01T00:00:00Z\",\"updated_at\":\"2026-11-01T00:00:00Z\"}"
        return s
    }

    private var listJSON: String {
        "{\"active\":[\(sched("S1", title: "아침 메일")),\(sched("S2", title: "주간 정리", recurrence: "once"))],\"paused\":[\(sched("S3", title: "저녁 일정", paused: true, reason: "user"))],"
            + "\"has_user_actions\":true,\"active_once_count\":1,\"active_repeat_count\":1}"
    }

    private let runLogJSON = "{\"run_id\":\"R1\",\"schedule_id\":\"S1\",\"date_text\":\"11월 15일 09:00\",\"agent_id\":\"a1\",\"status\":\"done\","
        + "\"log_nodes\":[{\"id\":1,\"kind\":\"step\",\"text\":\"메일을 읽었어요\",\"created_at\":\"2026-11-15T00:00:00Z\"}],"
        + "\"result_blocks\":[{\"kind\":\"text\",\"text\":\"새 메일 3통이 있어요\"}],\"credit\":{\"used\":7,\"refund_status\":\"none\"},\"next_run_at\":\"2026-11-16T00:00:00Z\"}"

    /// 가짜 서버: 경로로 답한다. `held`가 켜지면 지금 실행 답을 쥐고 있다가 `release()`로 준다.
    private final class FakeHTTP: PetHTTPClient {
        var requests: [PetHTTPRequest] = []
        var routes: [String: (Int, String)] = [:]
        var hold: Set<String> = []
        private var held: [(String, (Result<PetHTTPResponse, Error>) -> Void)] = []
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            requests.append(request)
            let key = request.method + " " + request.url.path
            let (status, body) = routes[key] ?? (404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
            let r = PetHTTPResponse(status: status, body: Data(body.utf8))
            if hold.contains(key) { held.append((key, completion)); return }
            completion(.success(r))
            _ = r
        }
        func release(_ key: String, status: Int, body: String) {
            for (k, c) in held where k == key { c(.success(PetHTTPResponse(status: status, body: Data(body.utf8)))) }
            held.removeAll { $0.0 == key }
        }
        func count(_ key: String) -> Int { requests.filter { $0.method + " " + $0.url.path == key }.count }
    }

    private final class Rig {
        let http = FakeHTTP()
        var toasts: [(String, Bool)] = []
        var confirmSteps: [[HubConfirmStep]] = []
        var accept = true
        var section: SchedulesSection?

        init(_ routes: [String: (Int, String)]) {
            http.routes = routes
            let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
            let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
            let s = SchedulesSection()
            section = s
            let ctx = HubContext(client: client, toast: { [unowned self] t, e in self.toasts.append((t, e)) },
                                 confirm: { [unowned self] steps, done in self.confirmSteps.append(steps); if self.accept { done() } })
            s.activate(ctx)
        }
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all(_ s: SchedulesSection) -> String { texts(s.view).joined(separator: "\n") }

    private func capture(_ s: SchedulesSection, name: String) throws {
        for dark in [false, true] {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSView(frame: w.contentLayoutRect)
            w.contentView = host
            s.view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(s.view)
            NSLayoutConstraint.activate([s.view.leadingAnchor.constraint(equalTo: host.leadingAnchor), s.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                         s.view.topAnchor.constraint(equalTo: host.topAnchor), s.view.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "schedules-\(name)-\(dark ? "dark" : "light")")
            s.view.removeFromSuperview()
        }
    }

    private func base(_ extra: [String: (Int, String)] = [:]) -> [String: (Int, String)] {
        var r: [String: (Int, String)] = [
            "GET /api/v1/scheduled-actions": (200, listJSON),
            "GET /api/v1/scheduled-actions/S1": (200, sched("S1", title: "아침 메일")),
            "GET /api/v1/scheduled-actions/S1/runs/R1": (200, runLogJSON),
            "GET /api/v1/me/usage": (200, "{\"plan_id\":\"free\",\"period\":\"week\",\"allowance\":300,\"remaining\":120,\"exhausted\":false,\"low_balance\":false}"),
            "GET /api/v1/agents": (200, "{\"agents\":[{\"id\":\"a1\",\"agent_id\":\"a1\",\"name\":\"나초\",\"status\":\"active\"},{\"id\":\"a2\",\"agent_id\":\"a2\",\"name\":\"콤보\",\"status\":\"active\"}],\"limits\":{},\"caps\":{}}"),
        ]
        for (k, v) in extra { r[k] = v }
        return r
    }

    private func openDetail(_ rig: Rig) throws -> SchedulesSection {
        let s = try XCTUnwrap(rig.section)
        s.go(.detail("S1"))
        return s
    }

    // MARK: 장면

    func testListGroupsAndCapture() throws {
        let rig = Rig(base())
        let s = try XCTUnwrap(rig.section)
        XCTAssertEqual(rig.http.requests.first.map { $0.method + " " + $0.url.path }, "GET /api/v1/scheduled-actions")
        let t = all(s)
        for want in ["한 번 (1)", "반복 (1)", "일시 정지", "아침 메일", "주간 정리", "저녁 일정"] { XCTAssertTrue(t.contains(want), "\(want)\n\(t)") }
        try capture(s, name: "list")
    }

    func testEmptyListSaysSo() throws {
        let rig = Rig(base(["GET /api/v1/scheduled-actions": (200, "{\"active\":[],\"paused\":[],\"has_user_actions\":false,\"active_once_count\":0,\"active_repeat_count\":0}")]))
        XCTAssertTrue(all(try XCTUnwrap(rig.section)).contains("아직 예약이 없어요."))
    }

    func testListServerErrorShowsKoreanAndRetry() throws {
        let rig = Rig(base(["GET /api/v1/scheduled-actions": (500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"boom\"}}")]))
        let t = all(try XCTUnwrap(rig.section))
        XCTAssertTrue(t.contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."), t)
        XCTAssertTrue(t.contains("다시 시도"), t)
        XCTAssertFalse(t.contains("boom"))
    }

    func testDetailShowsActionsAndRunsThenCapture() throws {
        let rig = Rig(base())
        let s = try openDetail(rig)
        let t = all(s)
        for want in ["아침 메일", "매일 09:00", "지금 한 번 실행", "시험 실행", "일시 정지", "담당 바꾸기", "삭제", "실행 기록", "건너뛰었어요 · 사용량을 다 썼어요", "쓸 때마다 휴대폰에서 승인해야 해요."] {
            XCTAssertTrue(t.contains(want), "\(want)\n\(t)")
        }
        try capture(s, name: "detail")
    }

    func testRunLogScreenAndCapture() throws {
        let rig = Rig(base())
        let s = try XCTUnwrap(rig.section)
        s.go(.runLog("S1", "R1"))
        let t = all(s)
        for want in ["11월 15일 09:00", "끝났어요", "새 메일 3통이 있어요", "메일을 읽었어요", "쓴 크레딧"] { XCTAssertTrue(t.contains(want), "\(want)\n\(t)") }
        try capture(s, name: "run-log")
    }

    func testTestUnavailableHidesTestButton() throws {
        let rig = Rig(base(["GET /api/v1/scheduled-actions/S1": (200, sched("S1", title: "아침 메일", test: "전화를 쓰는 예약이에요"))]))
        let t = all(try openDetail(rig))
        XCTAssertFalse(t.contains("시험 실행\n") || texts(try XCTUnwrap(rig.section).view).contains("시험 실행"))
        XCTAssertTrue(t.contains("전화를 쓰는 예약이에요"))
    }

    // MARK: 크레딧 확인창

    func testRunNowConfirmTextAndRequest() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/run-now": (200, "{\"id\":\"T1\",\"title\":\"메일\"}")]))
        let s = try openDetail(rig)
        s.runNowTapped()
        let step = try XCTUnwrap(rig.confirmSteps.first?.first)
        XCTAssertTrue(step.message.contains("크레딧을 씁니다"), step.message)
        XCTAssertTrue(step.message.contains("지금 남은 크레딧 120"), step.message)
        let post = try XCTUnwrap(rig.http.requests.last { $0.method == "POST" })
        XCTAssertEqual(post.url.path, "/api/v1/scheduled-actions/S1/run-now")
        XCTAssertEqual(String(data: post.body ?? Data(), encoding: .utf8), "{\"expected_estimate_id\":\"E1\"}")
        XCTAssertTrue(rig.toasts.contains { $0.0.contains("실행을 시작했어요") && !$0.1 })
    }

    func testRejectedConfirmSendsNoRunNowRequest() throws {
        let rig = Rig(base())
        rig.accept = false
        let s = try openDetail(rig)
        let before = rig.http.requests.count
        s.runNowTapped()
        s.testTapped()
        XCTAssertEqual(rig.confirmSteps.count, 2, "둘 다 확인창을 거친다")
        XCTAssertEqual(rig.http.requests.count, before, "거절하면 요청이 0건")
        XCTAssertEqual(rig.http.requests.filter { $0.method == "POST" }.count, 0)
    }

    func testTestRunAlsoAsksFirst() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/test": (200, "{\"id\":\"T2\",\"title\":\"[시험] 메일\"}")]))
        let s = try openDetail(rig)
        s.testTapped()
        XCTAssertTrue(try XCTUnwrap(rig.confirmSteps.first?.first).message.contains("크레딧을 씁니다"))
        XCTAssertEqual(rig.http.count("POST /api/v1/scheduled-actions/S1/test"), 1)
    }

    func testEstimateChangedToastsAndRereads() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/run-now": (409, "{\"error\":{\"code\":\"estimate_changed\",\"message\":\"x\"}}")]))
        let s = try openDetail(rig)
        let reads = rig.http.count("GET /api/v1/scheduled-actions/S1")
        s.runNowTapped()
        XCTAssertTrue(rig.toasts.contains { $0.0 == "계획이 바뀌었어요. 확인하고 다시 눌러 주세요." && $0.1 })
        XCTAssertEqual(rig.http.count("GET /api/v1/scheduled-actions/S1"), reads + 1)
    }

    func testRunNowCreditsRefusedShowsKoreanReason() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/run-now": (402, "{\"error\":{\"code\":\"task_not_startable\",\"message\":\"x\",\"reason\":\"credits_exhausted\"}}")]))
        let s = try openDetail(rig)
        s.runNowTapped()
        XCTAssertTrue(rig.toasts.contains { $0.0.contains("크레딧이 모자라요.") && $0.1 }, "\(rig.toasts)")
    }

    // MARK: 일시정지·삭제·전달

    func testPauseThenResumeFlipsStateAndBody() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/pause": (200, "{\"status\":\"ok\",\"schedule\":\(sched("S1", title: "아침 메일", paused: true, reason: "user"))}")]))
        let s = try openDetail(rig)
        s.pauseTapped()
        let post = try XCTUnwrap(rig.http.requests.last { $0.method == "POST" })
        XCTAssertEqual(String(data: post.body ?? Data(), encoding: .utf8), "{\"paused\":true}")
        XCTAssertTrue(try XCTUnwrap(s.current).paused)
        XCTAssertTrue(texts(s.view).contains("다시 시작"), all(s))
        // 다시 시작
        rig.http.routes["POST /api/v1/scheduled-actions/S1/pause"] = (200, "{\"status\":\"ok\",\"schedule\":\(sched("S1", title: "아침 메일"))}")
        s.pauseTapped()
        let post2 = try XCTUnwrap(rig.http.requests.last { $0.method == "POST" })
        XCTAssertEqual(String(data: post2.body ?? Data(), encoding: .utf8), "{\"paused\":false}")
        XCTAssertFalse(try XCTUnwrap(s.current).paused)
    }

    func testRestingScheduleHasNoPauseButton() throws {
        let rig = Rig(base(["GET /api/v1/scheduled-actions/S1": (200, sched("S1", title: "아침 메일", paused: true, reason: "agent_resting"))]))
        let s = try openDetail(rig)
        XCTAssertFalse(texts(s.view).contains("다시 시작"))
        XCTAssertFalse(texts(s.view).contains("일시 정지"))
        XCTAssertTrue(all(s).contains("쉬는 중이라 멈춤"))
    }

    func testDeleteNeedsTwoConfirmationsAndRejectingFirstSendsNothing() throws {
        let rig = Rig(base(["DELETE /api/v1/scheduled-actions/S1": (200, "{\"status\":\"deleted\"}")]))
        rig.accept = false
        let s = try openDetail(rig)
        s.deleteTapped()
        XCTAssertEqual(rig.confirmSteps.first?.count, 2)
        XCTAssertEqual(rig.http.count("DELETE /api/v1/scheduled-actions/S1"), 0)
        rig.accept = true
        s.deleteTapped()
        XCTAssertEqual(rig.http.count("DELETE /api/v1/scheduled-actions/S1"), 1)
        XCTAssertEqual(s.screen, .list, "지운 뒤 목록으로")
        XCTAssertTrue(rig.toasts.contains { $0.0 == "예약을 지웠어요." })
    }

    func testTransferListsOtherActiveAgentsAndPostsChoice() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/transfer": (200, "{\"status\":\"ok\",\"schedule\":\(sched("S1", title: "아침 메일"))}")]))
        let s = try openDetail(rig)
        s.go(.transfer("S1"))
        XCTAssertEqual(s.transferChoices.map { $0.name }, ["콤보"])
        XCTAssertTrue(all(s).contains("승인 규칙은 따라가지 않아요."))
        try capture(s, name: "transfer")
        s.transfer(to: try XCTUnwrap(s.transferChoices.first))
        let post = try XCTUnwrap(rig.http.requests.last { $0.method == "POST" })
        XCTAssertEqual(post.url.path, "/api/v1/scheduled-actions/S1/transfer")
        XCTAssertEqual(String(data: post.body ?? Data(), encoding: .utf8), "{\"agent_id\":\"a2\"}")
        XCTAssertEqual(s.screen, .detail("S1"))
    }

    // MARK: 섹션을 옮겨도 결과가 남는다

    func testWriteResultSurvivesLeavingTheSection() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/run-now": (200, "{\"id\":\"T1\",\"title\":\"메일\"}")]))
        rig.http.hold = ["POST /api/v1/scheduled-actions/S1/run-now"]
        weak var weakSection: SchedulesSection?
        do {
            let s = try openDetail(rig)
            weakSection = s
            s.runNowTapped()
            XCTAssertEqual(rig.http.count("POST /api/v1/scheduled-actions/S1/run-now"), 1)
        }
        rig.section = nil   // 창이 이 섹션을 놓았다(다른 섹션으로 옮김)
        XCTAssertNotNil(weakSection, "요청이 가는 동안은 섹션이 살아 있다")
        rig.http.release("POST /api/v1/scheduled-actions/S1/run-now", status: 200, body: "{\"id\":\"T1\",\"title\":\"메일\"}")
        XCTAssertTrue(rig.toasts.contains { $0.0.contains("실행을 시작했어요") }, "토스트가 사라지지 않는다: \(rig.toasts)")
    }

    func testSecondPressWhileInFlightSendsOnce() throws {
        let rig = Rig(base(["POST /api/v1/scheduled-actions/S1/pause": (200, "{\"status\":\"ok\",\"schedule\":\(sched("S1", title: "아침 메일", paused: true, reason: "user"))}")]))
        rig.http.hold = ["POST /api/v1/scheduled-actions/S1/pause"]
        let s = try openDetail(rig)
        s.pauseTapped()
        s.pauseTapped()
        XCTAssertEqual(rig.http.count("POST /api/v1/scheduled-actions/S1/pause"), 1)
    }

    func testGoneScheduleReturnsToListWithNotice() throws {
        let rig = Rig(base(["GET /api/v1/scheduled-actions/S1": (404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")]))
        let s = try openDetail(rig)
        XCTAssertEqual(s.screen, .list)
        XCTAssertTrue(rig.toasts.contains { $0.0 == "이미 삭제된 예약이에요." })
    }

    func testSignedOutAsksNothing() throws {
        let s = SchedulesSection()
        let ctx = HubContext(client: nil, toast: { _, _ in }, confirm: { _, _ in })
        s.activate(ctx)
        XCTAssertTrue(all(s).contains("로그인이 필요해요."))
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
