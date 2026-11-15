import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 계정·설정 섹션(NACHO-267 U1)을 가짜 HTTP로 장면별·라이트/다크로 그리고, 화면에서 나가는 요청 바이트·확인창·입력 검증을 확인한다.
/// macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 운영 서버는 부르지 않는다. 데이터는 모두 가짜다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 테스트 로그(BENTO-CAPTURE 줄)로 CI에 남긴다.
final class HubAccountCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    // MARK: fakes

    private final class FakeHTTP: PetHTTPClient {
        struct Answer { var status: Int; var body: String; var headers: [String: String] = [:] }
        var routes: [String: Answer] = [:]
        var sent: [PetHTTPRequest] = []
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            let a = routes[request.method + " " + request.url.path] ?? Answer(status: 404, body: "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
            completion(.success(PetHTTPResponse(status: a.status, headers: a.headers, body: Data(a.body.utf8))))
        }
        func requests(_ key: String) -> [PetHTTPRequest] { sent.filter { $0.method + " " + $0.url.path == key } }
        func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    }

    private static let meJSON = "{\"user\":{\"id\":\"u1\",\"display_name\":\"나초팬\",\"handle\":\"nacho_fan\",\"birthday\":\"1999-02-03\",\"version\":7,"
        + "\"phone\":{\"masked\":\"010-****-1234\",\"verified\":true}},\"roles\":[],\"auth_provider\":\"google\"}"
    private static let patchedUser = "{\"id\":\"u1\",\"display_name\":\"새이름\",\"handle\":\"nacho_fan\",\"birthday\":\"1999-02-03\",\"version\":8}"

    private func standard() -> FakeHTTP {
        let h = FakeHTTP()
        h.routes["GET /api/v1/me"] = .init(status: 200, body: HubAccountCaptureTests.meJSON)
        h.routes["GET /api/v1/me/privacy-settings"] = .init(status: 200, body: "{\"memory_paused\":false,\"memory_indicator_enabled\":true,\"phone_discoverable\":true}")
        h.routes["GET /api/v1/me/deletion-status"] = .init(status: 200, body: "{\"status\":\"active\"}")
        return h
    }

    private struct Rig {
        var section: AccountSection
        var http: FakeHTTP
        var toasts: Box<[(String, Bool)]>
        var confirms: Box<[[HubConfirmStep]]>
        var signedOut: Box<Int>
        var opened: Box<[URL]>
    }

    private final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func makeRig(_ http: FakeHTTP, deleteEnabled: Bool = false, autoConfirm: Bool = true) -> Rig {
        let toasts = Box<[(String, Bool)]>([])
        let confirms = Box<[[HubConfirmStep]]>([])
        let out = Box(0)
        let opened = Box<[URL]>([])
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
        let s = AccountSection()
        s.accountDeleteEnabled = deleteEnabled
        s.signOut = { out.value += 1 }
        s.openLink = { opened.value.append($0) }
        s.today = { AccountRules.Day(year: 2026, month: 11, day: 15) }
        s.handleCheckDelay = 0
        s.diagnostics = { HubAccountAPI.Diagnostics(appVersion: "0.11.0", osVersion: "macOS 15.0.0", deviceModel: "Mac14,2", language: "ko") }
        s.saveExport = { _ in URL(fileURLWithPath: "/dev/null") }
        s.activate(HubContext(client: client, toast: { t, e in toasts.value.append((t, e)) },
                              confirm: { steps, done in confirms.value.append(steps); if autoConfirm { done() } }))
        return Rig(section: s, http: http, toasts: toasts, confirms: confirms, signedOut: out, opened: opened)
    }

    // MARK: view helpers

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField, !f.isHidden { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all<T: NSView>(_ type: T.Type, in v: NSView) -> [T] {
        var out: [T] = []
        if let t = v as? T { out.append(t) }
        for s in v.subviews { out += all(type, in: s) }
        return out
    }

    private func pill(_ name: String, in v: NSView) -> PetPill? {
        all(PetPill.self, in: v).first { $0.accessibilityLabel() == name && !$0.isHidden }
    }

    private func press(_ name: String, _ r: Rig, file: StaticString = #filePath, line: UInt = #line) {
        guard let p = pill(name, in: r.section.view) else { XCTFail("no button \(name)", file: file, line: line); return }
        if p.isEnabled { p.onClick?() }
    }

    private func edit(_ field: NSTextField, _ text: String, _ r: Rig) {
        field.stringValue = text
        r.section.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func editable(_ r: Rig) -> [NSTextField] { all(NSTextField.self, in: r.section.view).filter { $0.isEditable } }

    private func row(_ title: String, _ r: Rig) -> HubRow? {
        all(HubRow.self, in: r.section.view).first { texts($0).contains(title) }
    }

    private func spin(_ s: TimeInterval = 0.15) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    // MARK: capture

    private func capture(_ r: Rig, name: String) throws {
        for dark in [false, true] {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = try XCTUnwrap(w.contentView)
            HubKit.pin(r.section.view, in: root)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "account-\(name)-\(dark ? "dark" : "light")")
            r.section.view.removeFromSuperview()
        }
    }

    // MARK: A5 이름·핸들·생일

    func testMainListsProfileAndAsksThreeReads() throws {
        let r = makeRig(standard())
        XCTAssertEqual(r.http.sent.map { $0.method + " " + $0.url.path }.sorted(),
                       ["GET /api/v1/me", "GET /api/v1/me/deletion-status", "GET /api/v1/me/privacy-settings"])
        let t = texts(r.section.view).joined(separator: "\n")
        for want in ["나초팬", "@nacho_fan", "1999-02-03", "010-****-1234", "전화번호로 나를 찾을 수 있게", "기억 일시 중지", "연락처 매칭 자료 삭제",
                     "내 데이터 내려받기", "문제 신고", "약관·법적 고지", "로그아웃"] {
            XCTAssertTrue(t.contains(want), "\(want)\n\(t)")
        }
        try capture(r, name: "main")
    }

    func testLoadFailureShowsKoreanTextAndRetry() throws {
        let h = standard()
        h.routes["GET /api/v1/me"] = .init(status: 500, body: "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
        let r = makeRig(h)
        let t = texts(r.section.view).joined(separator: "\n")
        XCTAssertTrue(t.contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."), t)
        XCTAssertTrue(t.contains("다시 시도"), t)
        try capture(r, name: "load-error")
    }

    func testPrivacyReadFailureDoesNotHideTheRestAndOffersRetry() throws {
        let h = standard()
        h.routes["GET /api/v1/me/privacy-settings"] = .init(status: 403, body: "{\"error\":{\"code\":\"account_deleting\",\"message\":\"x\"}}")
        let r = makeRig(h)
        let t = texts(r.section.view).joined(separator: "\n")
        XCTAssertTrue(t.contains("설정을 불러오지 못했어요"), t)
        XCTAssertTrue(t.contains("나초팬"), t)
        XCTAssertNil(all(HubSwitchRow.self, in: r.section.view).first)
    }

    func testNameSaveSendsVersionInBodyAndReturnsToMain() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me"] = .init(status: 200, body: HubAccountCaptureTests.patchedUser)
        let r = makeRig(h)
        r.section.open(.name)
        let f = try XCTUnwrap(editable(r).first)
        XCTAssertEqual(f.stringValue, "나초팬")
        XCTAssertEqual(pill("저장", in: r.section.view)?.alphaValue, 0.45, "unchanged name cannot be saved")
        edit(f, "  새이름  ", r)
        try capture(r, name: "name")
        press("저장", r)
        let sent = h.requests("PATCH /api/v1/me")
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(h.body(sent[0]), "{\"display_name\":\"새이름\",\"expected_version\":7}")
        XCTAssertEqual(r.toasts.value.last?.0, "저장했어요.")
        XCTAssertEqual(r.section.profile?.version, 8, "the next save carries the new version")
        XCTAssertEqual(r.section.page, .main)
        XCTAssertTrue(texts(r.section.view).contains("새이름"))
    }

    func testNameValidationBlocksEmptyAndTooLongWithoutSending() throws {
        let h = standard()
        let r = makeRig(h)
        r.section.open(.name)
        let f = try XCTUnwrap(editable(r).first)
        edit(f, "   ", r)
        XCTAssertTrue(texts(r.section.view).contains("이름을 입력해 주세요."))
        press("저장", r)
        edit(f, String(repeating: "가", count: 41), r)
        XCTAssertTrue(texts(r.section.view).contains("이름은 40자까지 쓸 수 있어요"))
        press("저장", r)
        XCTAssertTrue(h.requests("PATCH /api/v1/me").isEmpty)
        try capture(r, name: "name-too-long")
    }

    func testServerRejectionIsShownUnderTheFieldInKorean() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me"] = .init(status: 400, body: "{\"error\":{\"code\":\"blocked_word\",\"message\":\"x\"}}")
        let r = makeRig(h)
        r.section.open(.name)
        edit(try XCTUnwrap(editable(r).first), "나쁜말", r)
        press("저장", r)
        XCTAssertTrue(texts(r.section.view).contains("쓸 수 없는 표현이 들어 있어요"))
        XCTAssertEqual(r.section.page, .name, "the typed text stays")
    }

    func testVersionConflictToastsAndReloads() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me"] = .init(status: 409, body: "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"}}")
        let r = makeRig(h)
        r.section.open(.name)
        edit(try XCTUnwrap(editable(r).first), "다른이름", r)
        let before = h.requests("GET /api/v1/me").count
        press("저장", r)
        XCTAssertEqual(r.toasts.value.last?.0, "다른 기기에서 먼저 바뀌었어요. 나갔다가 다시 들어와 주세요")
        XCTAssertEqual(h.requests("GET /api/v1/me").count, before + 1)
        XCTAssertEqual(r.section.page, .main)
    }

    func testHandleChecksAskedTextOnlyThenSavesWhenAvailable() throws {
        let h = standard()
        h.routes["GET /api/v1/me/handle-check"] = .init(status: 200, body: "{\"handle\":\"new_id\",\"status\":\"available\",\"available\":true}")
        h.routes["PATCH /api/v1/me"] = .init(status: 200, body: "{\"id\":\"u1\",\"display_name\":\"나초팬\",\"handle\":\"new_id\",\"version\":8}")
        let r = makeRig(h)
        r.section.open(.handle)
        let f = try XCTUnwrap(editable(r).first)
        edit(f, "ab", r)
        XCTAssertTrue(texts(r.section.view).contains("영어 소문자, 숫자, 밑줄로 3~20자를 써 주세요"))
        edit(f, "Bad", r)
        XCTAssertTrue(texts(r.section.view).contains("대문자는 쓸 수 없어요. 소문자로 써 주세요"))
        edit(f, "bad-id", r)
        XCTAssertTrue(texts(r.section.view).contains("영어 소문자, 숫자, 밑줄로 3~20자만 쓸 수 있어요"))
        spin()
        XCTAssertTrue(h.requests("GET /api/v1/me/handle-check").isEmpty, "malformed text is never sent to the server")
        edit(f, "new_id", r)
        spin()
        XCTAssertEqual(h.requests("GET /api/v1/me/handle-check").last?.url.absoluteString, "https://nacho.example.com/api/v1/me/handle-check?handle=new_id")
        XCTAssertTrue(texts(r.section.view).contains("쓸 수 있는 ID예요"))
        try capture(r, name: "handle-available")
        press("저장", r)
        XCTAssertEqual(h.body(h.requests("PATCH /api/v1/me")[0]), "{\"expected_version\":7,\"handle\":\"new_id\"}")
        XCTAssertEqual(r.section.profile?.handle, "new_id")
    }

    func testHandleTakenAndFailedChecksCannotSave() throws {
        let h = standard()
        h.routes["GET /api/v1/me/handle-check"] = .init(status: 200, body: "{\"handle\":\"taken_id\",\"status\":\"taken\",\"available\":false}")
        let r = makeRig(h)
        r.section.open(.handle)
        let f = try XCTUnwrap(editable(r).first)
        edit(f, "taken_id", r)
        spin()
        XCTAssertTrue(texts(r.section.view).contains("이미 누가 쓰는 ID예요"))
        try capture(r, name: "handle-taken")
        press("저장", r)
        h.routes["GET /api/v1/me/handle-check"] = .init(status: 500, body: "{}")
        edit(f, "other_id", r)
        spin()
        XCTAssertTrue(texts(r.section.view).contains("확인하지 못했어요. 눌러서 다시 시도해 주세요"))
        press("저장", r)
        XCTAssertTrue(h.requests("PATCH /api/v1/me").isEmpty)
    }

    func testBirthdayValidationAndSave() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me"] = .init(status: 200, body: "{\"id\":\"u1\",\"display_name\":\"나초팬\",\"birthday\":\"2000-02-29\",\"version\":8}")
        let r = makeRig(h)
        r.section.open(.birthday)
        let f = editable(r)
        XCTAssertEqual(f.map { $0.stringValue }, ["1999", "2", "3"])
        edit(f[0], "2001", r); edit(f[1], "2", r); edit(f[2], "29", r)
        XCTAssertTrue(texts(r.section.view).contains("없는 날짜예요"))
        try capture(r, name: "birthday-invalid")
        press("저장", r)
        edit(f[0], "2027", r); edit(f[1], "1", r); edit(f[2], "1", r)
        XCTAssertTrue(texts(r.section.view).contains("오늘 이후 날짜는 쓸 수 없어요"))
        edit(f[0], "1899", r)
        XCTAssertTrue(texts(r.section.view).contains("1900년부터 쓸 수 있어요"))
        XCTAssertTrue(h.requests("PATCH /api/v1/me").isEmpty)
        edit(f[0], "2000", r); edit(f[1], "2", r); edit(f[2], "29", r)
        press("저장", r)
        XCTAssertEqual(h.body(h.requests("PATCH /api/v1/me")[0]), "{\"birthday\":\"2000-02-29\",\"expected_version\":7}")
    }

    func testUnderageFromServerIsExplained() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me"] = .init(status: 400, body: "{\"error\":{\"code\":\"underage\",\"message\":\"x\"}}")
        let r = makeRig(h)
        r.section.open(.birthday)
        let f = editable(r)
        edit(f[0], "2020", r); edit(f[1], "1", r); edit(f[2], "1", r)
        press("저장", r)
        XCTAssertTrue(texts(r.section.view).contains("나이 제한 때문에 이 생일로 바꿀 수 없어요"))
    }

    func testRowsOpenTheirPages() throws {
        let r = makeRig(standard())
        try XCTUnwrap(row("이름", r)).onClick?()
        XCTAssertEqual(r.section.page, .name)
        press("계정·설정", r)
        XCTAssertEqual(r.section.page, .main)
        try XCTUnwrap(row("사용자 ID", r)).onClick?()
        XCTAssertEqual(r.section.page, .handle)
        press("계정·설정", r)
        try XCTUnwrap(row("생일", r)).onClick?()
        XCTAssertEqual(r.section.page, .birthday)
    }

    // MARK: A6 개인정보·안전

    func testPrivacyToggleSendsPartialPatchAndKeepsServerAnswer() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me/privacy-settings"] = .init(status: 200, body: "{\"memory_paused\":true,\"memory_indicator_enabled\":true,\"phone_discoverable\":true}")
        let r = makeRig(h)
        let sw = all(HubSwitchRow.self, in: r.section.view)
        XCTAssertEqual(sw.map { $0.toggle.state == .on }, [true, false, true])
        sw[1].toggle.state = .on
        sw[1].onChange?(true)
        XCTAssertEqual(h.body(h.requests("PATCH /api/v1/me/privacy-settings")[0]), "{\"memory_paused\":true}")
        XCTAssertEqual(r.section.privacy?.memoryPaused, true)
    }

    func testPrivacyToggleRevertsAndExplainsOnError() throws {
        let h = standard()
        h.routes["PATCH /api/v1/me/privacy-settings"] = .init(status: 500, body: "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
        let r = makeRig(h)
        let sw = all(HubSwitchRow.self, in: r.section.view)
        sw[0].toggle.state = .off
        sw[0].onChange?(false)
        XCTAssertEqual(h.body(h.requests("PATCH /api/v1/me/privacy-settings")[0]), "{\"phone_discoverable\":false}")
        XCTAssertEqual(sw[0].toggle.state, .on, "back to the saved value")
        XCTAssertEqual(r.toasts.value.last?.1, true)
        XCTAssertTrue(r.toasts.value.last?.0.contains("저장하지 못해서 이전 값으로 돌렸어요") == true)
    }

    func testDeleteContactMatchesNeedsTwoConfirmsThenSendsDelete() throws {
        let h = standard()
        h.routes["DELETE /api/v1/me/contact-matches"] = .init(status: 200, body: "{\"ok\":true,\"deleted\":3}")
        let r = makeRig(h, autoConfirm: false)
        press("연락처 매칭 자료 삭제", r)
        XCTAssertEqual(r.confirms.value.count, 1)
        XCTAssertEqual(r.confirms.value[0].count, 2, "two confirmation steps")
        XCTAssertTrue(h.requests("DELETE /api/v1/me/contact-matches").isEmpty, "nothing is sent before both confirmations")
        let r2 = makeRig(h, autoConfirm: true)
        press("연락처 매칭 자료 삭제", r2)
        let d = h.requests("DELETE /api/v1/me/contact-matches")
        XCTAssertEqual(d.count, 1)
        XCTAssertNil(d[0].body)
        XCTAssertTrue(r2.toasts.value.last?.0.contains("자료를 지웠어요") == true)
    }

    func testResultOfAWriteStillArrivesAfterTheContextWasReplaced() throws {
        // 쓰기 중에 다른 섹션으로 옮겨 컨텍스트(와 요청 실행기)가 바뀌어도 결과 토스트가 사라지지 않는다.
        let h = standard()
        h.routes["PATCH /api/v1/me/privacy-settings"] = .init(status: 500, body: "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
        var pendingTokens: [(String?) -> Void] = []
        var hold = false
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let firstToasts = Box<[(String, Bool)]>([])
        let secondToasts = Box<[(String, Bool)]>([])
        let s = AccountSection()
        func ctx(_ toasts: Box<[(String, Bool)]>) -> HubContext {
            let client = HubClient(endpoint: endpoint, http: h, tokens: { _, done in if hold { pendingTokens.append(done) } else { done("T") } })
            return HubContext(client: client, toast: { t, e in toasts.value.append((t, e)) }, confirm: { _, done in done() })
        }
        s.activate(ctx(firstToasts))
        let sw = all(HubSwitchRow.self, in: s.view)
        hold = true
        sw[0].toggle.state = .off
        sw[0].onChange?(false)
        XCTAssertEqual(pendingTokens.count, 1)
        hold = false
        s.activate(ctx(secondToasts))      // 사용자가 다른 섹션에 갔다 돌아왔다(새 컨텍스트)
        pendingTokens.removeFirst()("T")   // 이제 옛 요청의 토큰이 도착한다
        XCTAssertEqual(h.requests("PATCH /api/v1/me/privacy-settings").count, 1)
        XCTAssertTrue(secondToasts.value.contains { $0.0.contains("저장하지 못해서 이전 값으로 돌렸어요") }, "\(secondToasts.value)")
    }

    // MARK: A4 내 데이터·계정 삭제

    func testExportSavesTheServerFileAsIs() throws {
        let h = standard()
        h.routes["GET /api/v1/me/export"] = .init(status: 200, body: "{\"exported_at\":\"2026-11-15T00:00:00Z\"}",
                                                  headers: ["Content-Disposition": "attachment; filename=\"nacho-export.json\""])
        let r = makeRig(h)
        var saved: AccountExportFile?
        r.section.saveExport = { saved = $0; return URL(fileURLWithPath: "/dev/null") }
        press("내 데이터 내려받기", r)
        XCTAssertEqual(h.requests("GET /api/v1/me/export").count, 1)
        XCTAssertEqual(saved?.fileName, "nacho-export.json")
        XCTAssertEqual(saved.flatMap { String(data: $0.data, encoding: .utf8) }, "{\"exported_at\":\"2026-11-15T00:00:00Z\"}")
        XCTAssertEqual(r.toasts.value.last?.0, "파일을 저장했어요.")
    }

    func testExportFailureIsExplained() throws {
        let h = standard()
        h.routes["GET /api/v1/me/export"] = .init(status: 500, body: "{}")
        let r = makeRig(h)
        press("내 데이터 내려받기", r)
        XCTAssertEqual(r.toasts.value.last?.1, true)
        XCTAssertTrue(r.toasts.value.last?.0.hasPrefix("받지 못했어요.") == true)
    }

    func testDeleteButtonIsOffByFlagAndShowsPhoneAppNotice() throws {
        let r = makeRig(standard(), deleteEnabled: false)
        let t = texts(r.section.view)
        XCTAssertTrue(t.contains("계정 삭제는 휴대폰의 나초 앱에서 할 수 있어요."), "\(t)")
        XCTAssertNil(pill("계정 삭제", in: r.section.view), "no delete button while the flag is off")
        XCTAssertFalse(HubFeatureFlags.accountDelete, "the shipped default stays off")
        r.section.deleteAccount()
        XCTAssertTrue(r.http.requests("DELETE /api/v1/me").isEmpty, "the request is never built while the flag is off")
        try capture(r, name: "delete-flag-off")
    }

    func testDeleteFlowWithFlagOnShowsPreviewAndNeedsTwoConfirms() throws {
        let h = standard()
        h.routes["GET /api/v1/me/deletion-preview"] = .init(status: 200, body: "{\"running_tasks\":2,\"scheduled_actions\":3,\"agent_count\":4,\"running_group_runs\":1,\"subscription\":{\"active\":true}}")
        h.routes["DELETE /api/v1/me"] = .init(status: 200, body: "{\"status\":\"scheduled\",\"purge_at\":\"2026-11-22T00:00:00Z\"}")
        let r = makeRig(h, deleteEnabled: true, autoConfirm: false)
        XCTAssertNotNil(pill("계정 삭제", in: r.section.view))
        try capture(r, name: "delete-flag-on")
        press("계정 삭제", r)
        XCTAssertEqual(h.requests("GET /api/v1/me/deletion-preview").count, 1)
        let steps = try XCTUnwrap(r.confirms.value.first)
        XCTAssertEqual(steps.count, 2)
        XCTAssertTrue(steps[0].message.contains("나초 4명, 진행 중인 일 2개, 단톡 일 1개, 예약 3개"), steps[0].message)
        XCTAssertTrue(steps[0].message.contains("구독이 있어요"), steps[0].message)
        XCTAssertTrue(h.requests("DELETE /api/v1/me").isEmpty, "nothing is deleted before both confirmations")
        let r2 = makeRig(h, deleteEnabled: true, autoConfirm: true)
        press("계정 삭제", r2)
        let del = h.requests("DELETE /api/v1/me")
        XCTAssertEqual(del.count, 1)
        XCTAssertNil(del[0].body)
    }

    func testDeleteDoesNotStartWithoutAPreview() throws {
        let h = standard()
        h.routes["GET /api/v1/me/deletion-preview"] = .init(status: 500, body: "{}")
        let r = makeRig(h, deleteEnabled: true)
        press("계정 삭제", r)
        XCTAssertTrue(r.confirms.value.isEmpty)
        XCTAssertTrue(h.requests("DELETE /api/v1/me").isEmpty)
        XCTAssertEqual(r.toasts.value.last?.1, true)
    }

    func testScheduledDeletionOffersCancel() throws {
        let h = standard()
        h.routes["GET /api/v1/me/deletion-status"] = .init(status: 200, body: "{\"status\":\"scheduled\",\"purge_at\":\"2026-11-22T00:00:00Z\"}")
        h.routes["POST /api/v1/me/deletion/cancel"] = .init(status: 200, body: "{\"status\":\"active\"}")
        let r = makeRig(h, deleteEnabled: true)
        let t = texts(r.section.view).joined(separator: "\n")
        XCTAssertTrue(t.contains("계정 삭제가 예약돼 있어요."), t)
        XCTAssertNil(pill("계정 삭제", in: r.section.view), "no second delete while one is scheduled")
        try capture(r, name: "deletion-scheduled")
        h.routes["GET /api/v1/me/deletion-status"] = .init(status: 200, body: "{\"status\":\"active\"}")
        press("삭제 취소", r)
        let c = h.requests("POST /api/v1/me/deletion/cancel")
        XCTAssertEqual(c.count, 1)
        XCTAssertNotNil(c[0].headers["Idempotency-Key"])
        XCTAssertEqual(r.toasts.value.last?.0, "삭제를 취소했어요.")
        XCTAssertNil(pill("삭제 취소", in: r.section.view), "after cancelling the notice is gone")
    }

    // MARK: A10 신고

    func testIssueReportValidationAndRequest() throws {
        let h = standard()
        h.routes["POST /api/v1/issue-reports"] = .init(status: 201, body: "{\"id\":\"r1\",\"created_at\":\"2026-11-15T00:00:00Z\"}")
        let r = makeRig(h)
        r.section.open(.issue)
        XCTAssertEqual(pill("보내기", in: r.section.view)?.alphaValue, 0.45, "empty text cannot be sent")
        press("보내기", r)
        XCTAssertTrue(h.requests("POST /api/v1/issue-reports").isEmpty)
        let tv = try XCTUnwrap(all(NSTextView.self, in: r.section.view).first)
        tv.string = "   "
        r.section.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        press("보내기", r)
        tv.string = String(repeating: "가", count: 2001)
        r.section.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        XCTAssertTrue(texts(r.section.view).contains { $0.contains("2000자까지 쓸 수 있어요") })
        press("보내기", r)
        XCTAssertTrue(h.requests("POST /api/v1/issue-reports").isEmpty)
        tv.string = "창이 안 열려요"
        r.section.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        let pop = try XCTUnwrap(all(NSPopUpButton.self, in: r.section.view).first)
        pop.selectItem(at: 2)   // chat
        try capture(r, name: "issue")
        press("보내기", r)
        let sent = h.requests("POST /api/v1/issue-reports")
        XCTAssertEqual(sent.count, 1)
        XCTAssertNotNil(sent[0].headers["Idempotency-Key"])
        XCTAssertEqual(h.body(sent[0]), "{\"category\":\"chat\",\"description\":\"창이 안 열려요\",\"diagnostics\":{\"app_version\":\"0.11.0\",\"device_model\":\"Mac14,2\",\"language\":\"ko\",\"os_version\":\"macOS 15.0.0\"}}")
        XCTAssertTrue(r.toasts.value.last?.0.contains("접수됐어요") == true)
        XCTAssertEqual(r.section.page, .main)
    }

    func testIssueReportFailureKeepsTheText() throws {
        let h = standard()
        h.routes["POST /api/v1/issue-reports"] = .init(status: 500, body: "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")
        let r = makeRig(h)
        r.section.open(.issue)
        let tv = try XCTUnwrap(all(NSTextView.self, in: r.section.view).first)
        tv.string = "문제"
        r.section.textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
        press("보내기", r)
        XCTAssertEqual(r.section.page, .issue)
        XCTAssertEqual(tv.string, "문제")
        XCTAssertEqual(r.toasts.value.last?.1, true)
        press("보내기", r)
        let keys = h.requests("POST /api/v1/issue-reports").compactMap { $0.headers["Idempotency-Key"] }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1, "a retry of the same report reuses its idempotency key")
    }

    // MARK: A9 약관·법적 고지

    func testLegalOpensOnlyWebLinksInTheDefaultBrowser() throws {
        let h = standard()
        h.routes["GET /client/config"] = .init(status: 200, body: "{\"legal_docs\":{\"terms\":{\"url\":\"https://x.example/terms\"},\"privacy\":{\"url\":\"file:///etc/passwd\"}}}")
        let r = makeRig(h)
        r.section.open(.legal)
        let t = texts(r.section.view).joined(separator: "\n")
        for want in ["이용약관", "개인정보 처리방침", "환불 정책", "MIT 라이선스"] { XCTAssertTrue(t.contains(want), "\(want)\n\(t)") }
        try XCTUnwrap(row("이용약관", r)).onClick?()
        try XCTUnwrap(row("개인정보 처리방침", r)).onClick?()
        XCTAssertEqual(r.opened.value.map { $0.absoluteString }, ["https://x.example/terms"], "the file:// address is never opened")
        XCTAssertEqual(r.toasts.value.last?.1, true)
        try capture(r, name: "legal")
    }

    func testLegalFallsBackToPublicAddressesWhenConfigFails() throws {
        let h = standard()
        h.routes["GET /client/config"] = .init(status: 500, body: "{}")
        let r = makeRig(h)
        r.section.open(.legal)
        try XCTUnwrap(row("이용약관", r)).onClick?()
        XCTAssertEqual(r.opened.value.first?.absoluteString, "https://nachotown.com/legal/terms/2026-10-01")
    }

    // MARK: 로그아웃

    func testSignOutAsksOnceThenCallsTheExistingSignOut() throws {
        let r = makeRig(standard(), autoConfirm: false)
        press("로그아웃", r)
        XCTAssertEqual(r.confirms.value.count, 1)
        XCTAssertEqual(r.signedOut.value, 0)
        let r2 = makeRig(standard(), autoConfirm: true)
        press("로그아웃", r2)
        XCTAssertEqual(r2.signedOut.value, 1)
    }

    // MARK: 허브 창 안에서

    func testHubWindowShowsTheAccountSectionAfterSignIn() throws {
        let http = standard()
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("T") })
        let env = HubEnvironment(isSignedIn: { true }, client: { client }, signIn: {})
        let w = PetHubWindow(env: env, autosaveName: nil, initial: .account)
        let t = texts(try XCTUnwrap(w.contentView)).joined(separator: "\n")
        XCTAssertTrue(t.contains("나초팬"), t)
        XCTAssertFalse(t.contains("준비 중이에요."), t)
        w.appearance = NSAppearance(named: .aqua)
        w.setContentSize(PetHubWindow.defaultSize)
        let root = try XCTUnwrap(w.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        try emit(try XCTUnwrap(rep.representation(using: .png, properties: [:])), name: "account-in-hub-window-light")
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
