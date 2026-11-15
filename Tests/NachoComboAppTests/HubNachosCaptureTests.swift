import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 나초·친구 섹션 시험 도구(NACHO-274 U8). 가짜 HTTP는 "METHOD /경로" 별로 답을 정해 두고 요청을 모두 기록한다.
/// 화면은 macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 데이터는 모두 가짜다.
final class HubSectionTestKit {
    final class Router: PetHTTPClient {
        struct Sent: Equatable { var method: String; var path: String; var body: String; var idempotencyKey: String? }
        var routes: [String: (Int, String)]
        private(set) var sent: [Sent] = []
        init(_ routes: [String: (Int, String)]) { self.routes = routes }
        var lines: [String] { sent.map { "\($0.method) \($0.path)" } }
        func count(_ line: String) -> Int { lines.filter { $0 == line }.count }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            let body = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
            sent.append(Sent(method: request.method, path: request.url.path, body: body, idempotencyKey: request.headers["Idempotency-Key"]))
            let key = "\(request.method) \(request.url.path)"
            let (status, json) = routes[key] ?? (404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
            completion(.success(PetHTTPResponse(status: status, body: Data(json.utf8))))
        }
    }

    /// 확인창 대역: 단계를 기록하고, `accept`일 때만 확인한 것으로 처리한다.
    final class Confirms {
        var steps: [[HubConfirmStep]] = []
        var accept = false
    }

    let http: Router
    let confirms = Confirms()
    var toasts: [(String, Bool)] = []
    let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)

    init(_ routes: [String: (Int, String)]) {
        _ = NSApplication.shared
        http = Router(routes)
    }

    func context() -> HubContext {
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
        return HubContext(client: client,
                          toast: { [unowned self] text, isError in self.toasts.append((text, isError)) },
                          confirm: { [unowned self] steps, done in
                              self.confirms.steps.append(steps)
                              if self.confirms.accept { done() }
                          })
    }

    func activate(_ section: HubSectionBase) { section.activate(context()) }

    static func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    static func joined(_ v: NSView) -> String { texts(v).joined(separator: "\n") }

    /// 캡처하는 동안 창이 사라지지 않게 쥐어 둔다(창이 없으면 다크 모양이 적용되지 않는다).
    static var windows: [NSWindow] = []

    /// 섹션을 창 오른쪽 내용 크기(752×640)로 놓은 뿌리.
    static func host(_ section: HubSectionBase, dark: Bool) -> NSView {
        let root = PetBox()
        root.fill = PetTheme.color(\.window)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 752, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = root
        windows.append(w)
        HubKit.pin(section.view, in: root)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        return root
    }

    static var outDir: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures") }

    /// 라이트·다크 두 장을 `.build/bento-captures`에 쓰고 base64를 로그(BENTO-CAPTURE 줄)에 남긴다.
    static func capture(_ section: HubSectionBase, name: String, in test: XCTestCase) throws {
        for dark in [false, true] {
            let root = host(section, dark: dark)
            try snapshot(root, name: "\(name)-\(dark ? "dark" : "light")", in: test)
        }
    }

    /// 확인창 카드 한 장(라이트·다크).
    static func captureCard(_ step: HubConfirmStep, name: String, in test: XCTestCase) throws {
        for dark in [false, true] {
            let card = HubConfirmCard(step: step, onCancel: {}, onConfirm: {})
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
            host.wantsLayer = true
            host.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor
            host.addSubview(card)
            NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: host.centerXAnchor), card.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.contentView = host
            windows.append(w)
            host.layoutSubtreeIfNeeded()
            try snapshot(host, name: "\(name)-\(dark ? "dark" : "light")", in: test)
        }
    }

    static func snapshot(_ root: NSView, name: String, in test: XCTestCase) throws {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("hub-\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE hub-\(name) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }
}

final class HubNachosCaptureTests: XCTestCase {
    private let A = "11111111-1111-1111-1111-111111111111"
    private let B = "22222222-2222-2222-2222-222222222222"

    private func agentJSON(_ id: String, _ name: String, status: String = "active", isDefault: Bool = false, version: Int = 3, extra: String = "") -> String {
        "{\"id\":\"\(id)\",\"agent_id\":\"\(id)\",\"name\":\"\(name)\",\"status\":\"\(status)\",\"is_default\":\(isDefault),\"version\":\(version),\"voice_id\":\"calm\",\"phone_name\":\"\","
            + "\"speech\":{\"honorific\":\"polite\",\"tone\":\"warm\",\"mimic\":false},\"role_note\":\"일정을 챙겨 줘요\",\"look\":{\"flavor\":\"matcha\"},"
            + "\"limits\":{\"memory_read\":\"shared\",\"memory_write\":\"shared\",\"documents\":\"own_only\",\"connections\":[],\"vault_cards\":false,\"auto_payment\":false},\"unread\":0,\"active_task_count\":0\(extra)}"
    }

    private var listJSON: String {
        "{\"agents\":[\(agentJSON(A, "나초", isDefault: true)),\(agentJSON(B, "초코", version: 5))],\"limits\":{\"max_agents\":3,\"used\":2,\"can_create\":true},\"caps\":{\"max_agents\":3,\"used\":2,\"can_create\":true}}"
    }

    private let previewJSON = "{\"agent_id\":\"22222222-2222-2222-2222-222222222222\",\"is_default\":false,\"can_delete\":true,\"active_tasks\":[{\"id\":\"t\",\"title\":\"주간 보고\",\"state\":\"running\",\"room_id\":\"r\"}],\"schedules\":[{\"id\":\"s\",\"title\":\"아침 알림\"}],\"pending_requests\":[],\"own_memories\":4,\"rooms\":[],\"restore_days\":14}"

    private let photosJSON = "{\"photos\":[{\"key\":\"k1\",\"agent_id\":\"a\",\"scene_id\":\"park\",\"url\":\"https://img.example.com/1.png\",\"in_use\":true},{\"key\":\"k2\",\"agent_id\":\"a\",\"scene_id\":\"cafe\",\"url\":\"https://img.example.com/2.png\",\"in_use\":false}],\"current_key\":\"k1\",\"remaining_today\":3,\"scenes\":[{\"scene_id\":\"park\",\"label\":\"공원\"},{\"scene_id\":\"cafe\",\"label\":\"카페\"}]}"
    private let usageJSON = "{\"plan_id\":\"free\",\"period\":\"week\",\"allowance\":300,\"remaining\":120,\"reset_at\":\"2026-11-20T00:00:00Z\",\"exhausted\":false,\"low_balance\":false,\"limits\":[]}"

    private func kit(_ extra: [String: (Int, String)] = [:]) -> HubSectionTestKit {
        var routes: [String: (Int, String)] = ["GET /api/v1/agents": (200, listJSON)]
        for (k, v) in extra { routes[k] = v }
        return HubSectionTestKit(routes)
    }

    private func open(_ k: HubSectionTestKit) -> NachosSection {
        let s = NachosSection()
        k.activate(s)
        return s
    }

    // MARK: 목록·상세 (F4)

    func testListShowsAgentsWithDefaultAndAsksOnlyForList() throws {
        let k = kit()
        let s = open(k)
        XCTAssertEqual(k.http.lines, ["GET /api/v1/agents"])
        let all = HubSectionTestKit.joined(s.view)
        XCTAssertTrue(all.contains("나초  · 대표"), all)
        XCTAssertTrue(all.contains("초코"), all)
        XCTAssertTrue(all.contains("새 나초 만들기"), all)
        XCTAssertTrue(all.contains("2/3마리"), all)
        try HubSectionTestKit.capture(s, name: "nachos-list", in: self)
    }

    func testEmptyListAndServerError() {
        let empty = kit(["GET /api/v1/agents": (200, "{\"agents\":[],\"limits\":{\"max_agents\":3,\"used\":0,\"can_create\":true}}")])
        XCTAssertTrue(HubSectionTestKit.joined(open(empty).view).contains("아직 나초가 없어요."))
        let bad = kit(["GET /api/v1/agents": (500, "boom")])
        XCTAssertTrue(HubSectionTestKit.joined(open(bad).view).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
        let unauthorized = kit(["GET /api/v1/agents": (401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")])
        XCTAssertTrue(HubSectionTestKit.joined(open(unauthorized).view).contains("로그인이 필요해요."))
    }

    func testDetailShowsActionsAndHidesRestForDefault() throws {
        let k = kit()
        let s = open(k)
        s.go(.detail(B))
        let all = HubSectionTestKit.joined(s.view)
        for t in ["초코", "프로필 고치기", "목소리", "닮은 점", "사진", "한도", "대표로 정하기", "쉬게 하기", "지우기"] { XCTAssertTrue(all.contains(t), "\(t)\n\(all)") }
        try HubSectionTestKit.capture(s, name: "nachos-detail", in: self)
        s.go(.detail(A))
        let d = HubSectionTestKit.joined(s.view)
        XCTAssertFalse(d.contains("쉬게 하기"), d)
        XCTAssertTrue(d.contains("대표 나초는 쉬게 하거나 지울 수 없어요."), d)
    }

    // MARK: 만들기 — 입력 검증, 요청 바이트, 서버 오류

    func testCreateRejectsBadNameWithoutRequest() throws {
        let k = kit(["GET /api/v1/agent-templates": (200, "[{\"template_id\":\"planner\",\"label\":\"일정 도우미\",\"role_note\":\"일정\",\"speech\":{\"honorific\":\"polite\",\"tone\":\"warm\",\"mimic\":false},\"suggested_limits\":{}}]")])
        let s = open(k)
        s.openCreate()
        XCTAssertEqual(k.http.lines, ["GET /api/v1/agents", "GET /api/v1/agent-templates"])
        try HubSectionTestKit.capture(s, name: "nachos-create", in: self)
        let tpl = HubChoiceField(title: "t", options: [("", "없음")], selected: nil)
        let h = HubChoiceField(title: "h", options: [("polite", "존댓말")], selected: "polite")
        let t = HubChoiceField(title: "t", options: [("warm", "다정")], selected: "warm")
        let err = HubKit.label("")
        for bad in ["", "   ", "a@b", String(repeating: "가", count: 21)] {
            let name = HubFormField(title: "이름", validator: { HubNachosValidation.name($0) })
            name.field.stringValue = bad
            let role = HubFormField(title: "역할", validator: { HubNachosValidation.roleNote($0) })
            s.submitCreate(name: name, role: role, template: tpl, honorific: h, tone: t, error: err)
        }
        XCTAssertEqual(k.http.count("POST /api/v1/agents"), 0, "검증을 못 넘으면 요청이 0건")
        let role = HubFormField(title: "역할", validator: { HubNachosValidation.roleNote($0) })
        role.field.stringValue = String(repeating: "가", count: 81)
        let name = HubFormField(title: "이름", validator: { HubNachosValidation.name($0) })
        name.field.stringValue = "하늘"
        s.submitCreate(name: name, role: role, template: tpl, honorific: h, tone: t, error: err)
        XCTAssertEqual(k.http.count("POST /api/v1/agents"), 0)
    }

    func testCreateSendsBodyAndShowsServerErrorInKorean() throws {
        let k = kit(["POST /api/v1/agents": (409, "{\"error\":{\"code\":\"duplicate_name\",\"message\":\"english\",\"reason\":\"name\"}}")])
        let s = open(k)
        s.openCreate()
        let name = HubFormField(title: "이름", validator: { HubNachosValidation.name($0) })
        name.field.stringValue = "초코"
        let role = HubFormField(title: "역할", validator: { HubNachosValidation.roleNote($0) })
        let tpl = HubChoiceField(title: "t", options: [("", "없음")], selected: nil)
        let h = HubChoiceField(title: "h", options: [("casual", "반말")], selected: "casual")
        let t = HubChoiceField(title: "t", options: [("calm", "차분")], selected: "calm")
        let err = HubKit.label("")
        s.submitCreate(name: name, role: role, template: tpl, honorific: h, tone: t, error: err)
        let post = try XCTUnwrap(k.http.sent.last { $0.method == "POST" })
        XCTAssertEqual(post.path, "/api/v1/agents")
        XCTAssertNotNil(post.idempotencyKey)
        XCTAssertTrue(post.body.contains("\"name\":\"초코\""), post.body)
        XCTAssertTrue(post.body.contains("\"honorific\":\"casual\""), post.body)
        XCTAssertTrue(post.body.contains("\"tone\":\"calm\""), post.body)
        XCTAssertTrue(post.body.contains("\"idempotency_key\":\"\(post.idempotencyKey ?? "")\""), post.body)
        XCTAssertEqual(err.stringValue, "같은 이름의 나초가 이미 있어요.")
        XCTAssertTrue(HubSectionTestKit.joined(name).contains("같은 이름의 나초가 이미 있어요."))
        XCTAssertFalse(HubSectionTestKit.joined(name).contains("english"))
    }

    // MARK: 삭제 — 서버 미리보기를 보여 주고 확인창 두 번

    func testDeleteShowsServerPreviewAndNeedsBothConfirms() throws {
        let k = kit(["GET /api/v1/agents/\(B)/removal-preview": (200, previewJSON),
                     "DELETE /api/v1/agents/\(B)": (200, "{\"agent\":\(agentJSON(B, "초코", status: "deleting", version: 6)),\"restore_until\":\"2026-11-29T00:00:00Z\"}")])
        let s = open(k)
        let b = try XCTUnwrap(s.agent(B))
        k.confirms.accept = false
        s.requestDelete(b)
        XCTAssertEqual(k.http.lines.last, "GET /api/v1/agents/\(B)/removal-preview")
        let steps = try XCTUnwrap(k.confirms.steps.last)
        XCTAssertEqual(steps.count, 2, "확인창이 두 번")
        XCTAssertTrue(steps[0].message.contains("주간 보고"), steps[0].message)
        XCTAssertTrue(steps[0].message.contains("아침 알림"), steps[0].message)
        XCTAssertTrue(steps[0].message.contains("기억 4개"), steps[0].message)
        XCTAssertEqual(k.http.count("DELETE /api/v1/agents/\(B)"), 0, "확인하지 않으면 삭제 요청이 0건")
        try HubSectionTestKit.captureCard(steps[0], name: "nachos-delete-confirm1", in: self)
        try HubSectionTestKit.captureCard(steps[1], name: "nachos-delete-confirm2", in: self)
        k.confirms.accept = true
        s.requestDelete(b)
        let del = try XCTUnwrap(k.http.sent.last { $0.method == "DELETE" })
        XCTAssertTrue(del.body.contains("\"expected_version\":5"), del.body)
        XCTAssertTrue(del.body.contains("\"task_policy\":\"wait\""), del.body)
        XCTAssertNotNil(del.idempotencyKey)
        XCTAssertTrue(k.toasts.contains { $0.0 == "초코을(를) 지웠어요." || $0.0.contains("지웠어요") })
    }

    func testDefaultAgentCannotBeDeletedAndAsksNoConfirm() throws {
        let k = kit(["GET /api/v1/agents/\(A)/removal-preview": (200, "{\"agent_id\":\"\(A)\",\"is_default\":true,\"can_delete\":false,\"restore_days\":14}")])
        let s = open(k)
        s.requestDelete(try XCTUnwrap(s.agent(A)))
        XCTAssertTrue(k.confirms.steps.isEmpty)
        XCTAssertEqual(k.http.count("DELETE /api/v1/agents/\(A)"), 0)
        XCTAssertTrue(k.toasts.contains { $0.1 && $0.0.contains("대표 나초") })
    }

    // MARK: 상태 바꾸기

    func testRestWakeDefaultRestoreRequests() throws {
        let k = kit(["POST /api/v1/agents/\(B)/rest": (200, agentJSON(B, "초코", status: "resting", version: 6)),
                     "POST /api/v1/agents/\(B)/wake": (200, agentJSON(B, "초코", version: 7)),
                     "POST /api/v1/agents/\(B)/default": (200, agentJSON(B, "초코", isDefault: true, version: 8)),
                     "POST /api/v1/agents/\(B)/restore": (200, agentJSON(B, "초코", version: 9))])
        let s = open(k)
        s.rest(try XCTUnwrap(s.agent(B)))
        XCTAssertEqual(k.http.sent.last?.body, "{\"expected_version\":5}")
        XCTAssertEqual(s.agent(B)?.status, "resting")
        s.wake(try XCTUnwrap(s.agent(B)))
        XCTAssertEqual(k.http.sent.last?.body, "{\"expected_version\":6}")
        s.setDefault(try XCTUnwrap(s.agent(B)))
        XCTAssertEqual(k.http.lines.last, "POST /api/v1/agents/\(B)/default")
        XCTAssertEqual(s.agent(B)?.isDefault, true)
        XCTAssertEqual(s.agent(A)?.isDefault, false, "대표는 한 명")
        s.restore(try XCTUnwrap(s.agent(B)))
        XCTAssertEqual(k.http.lines.last, "POST /api/v1/agents/\(B)/restore")
    }

    func testVersionConflictReloadsAndSaysSo() throws {
        let k = kit(["POST /api/v1/agents/\(B)/rest": (409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"}}")])
        let s = open(k)
        s.rest(try XCTUnwrap(s.agent(B)))
        XCTAssertTrue(k.toasts.contains { $0.0 == "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요." && $0.1 })
        XCTAssertEqual(k.http.count("GET /api/v1/agents"), 2, "새로 불러온다")
    }

    // MARK: 프로필 고치기 (F2)

    func testEditSendsOnlyChangedFieldsAndValidates() throws {
        let k = kit(["PATCH /api/v1/agents/\(B)": (200, agentJSON(B, "하늘", version: 6))])
        let s = open(k)
        let b = try XCTUnwrap(s.agent(B))
        let err = HubKit.label("")
        func fields(name: String, phone: String = "") -> (HubFormField, HubFormField, HubFormField, HubChoiceField, HubChoiceField) {
            let n = HubFormField(title: "이름", validator: { HubNachosValidation.name($0) }); n.field.stringValue = name
            let p = HubFormField(title: "전화", validator: { HubNachosValidation.phoneName($0) }); p.field.stringValue = phone
            let r = HubFormField(title: "역할", validator: { HubNachosValidation.roleNote($0) }); r.field.stringValue = b.roleNote
            return (n, p, r, HubChoiceField(title: "h", options: [("polite", "존댓말")], selected: "polite"), HubChoiceField(title: "t", options: [("warm", "다정")], selected: "warm"))
        }
        var f = fields(name: "")
        s.submitEdit(b, name: f.0, phone: f.1, role: f.2, honorific: f.3, tone: f.4, error: err)
        f = fields(name: "초코", phone: "12345")
        s.submitEdit(b, name: f.0, phone: f.1, role: f.2, honorific: f.3, tone: f.4, error: err)
        XCTAssertEqual(k.http.count("PATCH /api/v1/agents/\(B)"), 0, "검증을 못 넘으면 요청이 0건")
        f = fields(name: "초코")
        s.submitEdit(b, name: f.0, phone: f.1, role: f.2, honorific: f.3, tone: f.4, error: err)
        XCTAssertEqual(k.http.count("PATCH /api/v1/agents/\(B)"), 0, "바뀐 것이 없으면 요청하지 않는다")
        XCTAssertTrue(k.toasts.contains { $0.0 == "바꾼 것이 없어요." })
        f = fields(name: "하늘")
        s.submitEdit(b, name: f.0, phone: f.1, role: f.2, honorific: f.3, tone: f.4, error: err)
        XCTAssertEqual(k.http.sent.last?.body, "{\"expected_version\":5,\"name\":\"하늘\"}")
        XCTAssertEqual(s.agent(B)?.name, "하늘")
    }

    // MARK: 목소리·특성·사진·한도

    func testVoicesPreviewButtonOnlyWithServerSample() throws {
        let k = kit(["GET /api/v1/agents/\(B)/voices": (200, "[{\"voice_id\":\"calm\",\"name\":\"calm\",\"label\":\"차분한 목소리\",\"description\":\"낮고 부드러워요\",\"sample_url\":\"https://nacho.example.com/static/voices/calm\"},{\"voice_id\":\"bright\",\"name\":\"bright\",\"label\":\"밝은 목소리\",\"description\":\"\",\"sample_url\":null},{\"voice_id\":\"evil\",\"name\":\"evil\",\"label\":\"이상한 목소리\",\"description\":\"\",\"sample_url\":\"file:///etc/passwd\"}]")])
        let s = open(k)
        s.go(.voices(B))
        let all = HubSectionTestKit.joined(s.view)
        XCTAssertEqual(all.components(separatedBy: "미리 듣기").count - 1, 1, "서버가 https 주소를 준 목소리만 미리 듣기가 있다\n\(all)")
        XCTAssertTrue(all.contains("사용 중"), all)
        try HubSectionTestKit.capture(s, name: "nachos-voices", in: self)
        s.chooseVoice(try XCTUnwrap(s.agent(B)), HubVoice(HubObject(["voice_id": "bright", "label": "밝은 목소리"]))!)
        XCTAssertEqual(k.http.sent.last?.method, "PATCH")
        XCTAssertEqual(k.http.sent.last?.body, "{\"expected_version\":5,\"voice_id\":\"bright\"}")
    }

    func testTraitsListRefreshAndHideNeedsTwoConfirms() throws {
        let traits = "[{\"trait_id\":\"t1\",\"text\":\"산책을 좋아해요\",\"evidence\":\"자주 걷는다고 했어요\",\"created_at\":\"2026-11-01T00:00:00Z\"}]"
        let k = kit(["GET /api/v1/agents/\(B)/traits": (200, traits), "POST /api/v1/agents/\(B)/traits/refresh": (200, traits),
                     "DELETE /api/v1/agents/\(B)/traits/t1": (204, "")])
        let s = open(k)
        s.go(.traits(B))
        XCTAssertTrue(HubSectionTestKit.joined(s.view).contains("산책을 좋아해요"))
        try HubSectionTestKit.capture(s, name: "nachos-traits", in: self)
        s.refreshTraits(try XCTUnwrap(s.agent(B)))
        XCTAssertEqual(k.http.count("POST /api/v1/agents/\(B)/traits/refresh"), 1)
        k.confirms.accept = false
        s.hideTrait(try XCTUnwrap(s.agent(B)), HubTrait(HubObject(["trait_id": "t1", "text": "산책을 좋아해요"]))!)
        XCTAssertEqual(k.confirms.steps.last?.count, 2)
        XCTAssertEqual(k.http.count("DELETE /api/v1/agents/\(B)/traits/t1"), 0)
        k.confirms.accept = true
        s.hideTrait(try XCTUnwrap(s.agent(B)), HubTrait(HubObject(["trait_id": "t1", "text": "산책을 좋아해요"]))!)
        XCTAssertEqual(k.http.count("DELETE /api/v1/agents/\(B)/traits/t1"), 1)
    }

    /// 크레딧 확인창에서 거절하면 사진 만들기 요청은 0건이다. 확인창에는 오늘 남은 장수와 크레딧 잔량이 보인다.
    func testPhotoCreateDeclinedSendsNoCreateRequest() throws {
        let k = kit(["GET /api/v1/agents/\(B)/photos": (200, photosJSON), "GET /api/v1/me/usage": (200, usageJSON),
                     "POST /api/v1/agents/\(B)/photos": (201, "{\"photos\":\(photosJSON),\"photo\":{\"key\":\"k3\",\"scene_id\":\"cafe\"}}")])
        let s = open(k)
        s.go(.photos(B))
        let all = HubSectionTestKit.joined(s.view)
        XCTAssertTrue(all.contains("사진 만들기"), all)
        XCTAssertTrue(all.contains("오늘 3장"), all)
        try HubSectionTestKit.capture(s, name: "nachos-photos", in: self)
        let b = try XCTUnwrap(s.agent(B))
        k.confirms.accept = false
        s.requestPhoto(b, sceneID: "cafe")
        let step = try XCTUnwrap(k.confirms.steps.last?.first)
        XCTAssertTrue(step.message.contains("크레딧을 써요"), step.message)
        XCTAssertTrue(step.message.contains("오늘 3장"), step.message)
        XCTAssertTrue(step.message.contains("120"), step.message)
        XCTAssertEqual(k.http.count("POST /api/v1/agents/\(B)/photos"), 0, "거절하면 요청 0건")
        try HubSectionTestKit.captureCard(step, name: "nachos-photo-credit-confirm", in: self)
        k.confirms.accept = true
        s.requestPhoto(b, sceneID: "cafe")
        let post = try XCTUnwrap(k.http.sent.last { $0.method == "POST" && $0.path.hasSuffix("/photos") })
        XCTAssertEqual(post.body.contains("\"scene_id\":\"cafe\""), true, post.body)
        XCTAssertNotNil(post.idempotencyKey)
    }

    func testPhotoRateLimitShowsRetryTimeInKorean() throws {
        let k = kit(["GET /api/v1/agents/\(B)/photos": (200, photosJSON), "GET /api/v1/me/usage": (200, usageJSON),
                     "POST /api/v1/agents/\(B)/photos": (429, "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"x\",\"reason\":\"2026-11-20T01:00:00Z\"}}")])
        let s = open(k)
        s.go(.photos(B))
        k.confirms.accept = true
        s.requestPhoto(try XCTUnwrap(s.agent(B)), sceneID: "park")
        XCTAssertTrue(k.toasts.contains { $0.1 && $0.0.hasPrefix("잠시 너무 많이 요청했어요.") }, "\(k.toasts)")
    }

    func testPhotoSelectDeleteAndClear() throws {
        let k = kit(["GET /api/v1/agents/\(B)/photos": (200, photosJSON), "POST /api/v1/agents/\(B)/photos/k2/select": (200, agentJSON(B, "초코", version: 6)),
                     "DELETE /api/v1/agents/\(B)/photos/k2": (200, photosJSON), "POST /api/v1/agents/\(B)/avatar/clear": (200, agentJSON(B, "초코", version: 7))])
        let s = open(k)
        s.go(.photos(B))
        let b = try XCTUnwrap(s.agent(B))
        let p2 = HubPhoto(HubObject(["key": "k2", "scene_id": "cafe"]))!
        s.selectPhoto(b, p2)
        XCTAssertEqual(k.http.count("POST /api/v1/agents/\(B)/photos/k2/select"), 1)
        k.confirms.accept = false
        s.requestDeletePhoto(b, p2)
        XCTAssertEqual(k.confirms.steps.last?.count, 2)
        XCTAssertEqual(k.http.count("DELETE /api/v1/agents/\(B)/photos/k2"), 0)
        k.confirms.accept = true
        s.requestDeletePhoto(b, p2)
        XCTAssertEqual(k.http.count("DELETE /api/v1/agents/\(B)/photos/k2"), 1)
        s.clearAvatar(b)
        XCTAssertEqual(k.http.count("POST /api/v1/agents/\(B)/avatar/clear"), 1)
    }

    func testLimitsSwitchesSendOnlyChangedField() throws {
        let k = kit(["PUT /api/v1/agents/\(B)/limits": (200, agentJSON(B, "초코", version: 6))])
        let s = open(k)
        s.go(.limits(B))
        let all = HubSectionTestKit.joined(s.view)
        XCTAssertTrue(all.contains("기억 읽기를 이 나초만"), all)
        XCTAssertTrue(all.contains("휴대폰의 나초 앱에서만 바꿀 수 있어요."), all)
        try HubSectionTestKit.capture(s, name: "nachos-limits", in: self)
        s.changeLimits(try XCTUnwrap(s.agent(B)), HubLimitsPatch(memoryRead: "own_only"))
        XCTAssertEqual(k.http.sent.last?.body, "{\"expected_version\":5,\"memory_read\":\"own_only\"}")
    }

    // MARK: 창 안에서: 다른 섹션으로 옮겨도 결과가 사라지지 않는다

    func testResultOfWriteSurvivesLeavingAndReturningToSection() throws {
        _ = NSApplication.shared
        let http = HubSectionTestKit.Router(["GET /api/v1/agents": (200, listJSON), "POST /api/v1/agents/\(B)/rest": (200, agentJSON(B, "초코", status: "resting", version: 6))])
        var pending: [(String?) -> Void] = []
        // 요청마다 새 실행기를 만들고 아무도 붙잡지 않는다. 토큰은 나중에 준다.
        let env = HubEnvironment(isSignedIn: { true },
                                 client: { HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: http, tokens: { _, done in pending.append(done) }) },
                                 signIn: {})
        let w = PetHubWindow(env: env, autosaveName: nil, initial: .nachos)
        XCTAssertEqual(pending.count, 1)
        pending.removeFirst()("T")
        let section = try XCTUnwrap(w.currentSection as? NachosSection)
        XCTAssertEqual(section.list?.agents.count, 2)
        section.rest(try XCTUnwrap(section.agent(B)))
        XCTAssertEqual(pending.count, 1, "쓰기 요청이 토큰을 기다린다")
        w.select(.usage)
        w.select(.nachos)   // 다시 들어오면 새 실행기로 바뀐다
        let waiting = pending.removeFirst()
        waiting("T")
        let exp = expectation(description: "toast")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 3)
        XCTAssertTrue(HubSectionTestKit.joined(w.toastContainer).contains("쉬어요."), HubSectionTestKit.joined(w.toastContainer))
        XCTAssertEqual(http.count("POST /api/v1/agents/\(B)/rest"), 1)
    }
}
