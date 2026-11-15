import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 맥에서 가입 마치기(NACHO-277 U11): 단계마다 가짜 HTTP로 그리고(라이트·다크), 화면에서 나가는 요청 바이트·입력 검증·전화 인증 안내를 확인한다.
/// macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 운영 서버는 부르지 않는다. 데이터는 모두 가짜다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 테스트 로그(BENTO-CAPTURE 줄)로 CI에 남긴다.
final class HubOnboardingCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: fakes

    private final class FakeHTTP: PetHTTPClient {
        var answers: [String: [(Int, String)]] = [:]
        var sent: [PetHTTPRequest] = []
        /// 이 경로의 답을 바꾼다(그 뒤로는 이 답을 되풀이한다).
        func on(_ key: String, _ status: Int, _ body: String) { answers[key] = [(status, body)] }
        /// 지금 답 뒤에 한 번 더 줄 세운다(마지막 답은 되풀이한다).
        func then(_ key: String, _ status: Int, _ body: String) { answers[key, default: []].append((status, body)) }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            let key = request.method + " " + request.url.path
            var list = answers[key] ?? []
            let a = list.first ?? (404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
            if list.count > 1 { list.removeFirst(); answers[key] = list }
            completion(.success(PetHTTPResponse(status: a.0, body: Data(a.1.utf8))))
        }
        func bodies(_ key: String) -> [String] {
            sent.filter { $0.method + " " + $0.url.path == key }.map { String(data: $0.body ?? Data(), encoding: .utf8) ?? "" }
        }
        var writes: [String] { sent.filter { $0.method != "GET" }.map { $0.method + " " + $0.url.path } }
    }

    private static let voices = "[{\"voice_id\":\"v_a\",\"name\":\"a\",\"label\":\"차분한 목소리\",\"description\":\"조용하고 또렷해요\"},{\"voice_id\":\"v_b\",\"name\":\"b\",\"label\":\"밝은 목소리\",\"description\":\"통통 튀어요\"}]"

    private func state(_ step: String, flags: String = "\"terms\":false,\"privacy\":false,\"marketing\":false", extra: String = "", back: Bool = true) -> String {
        "{\"step\":\"\(step)\",\"stage\":\"profile\",\"can_go_back\":\(back),\"account_status\":\"active\",\"display_name\":\"나초팬\",\"name_suggestions\":[\"나초팬\",\"초코\"],"
            + "\"consents\":[],\"consent_flags\":{\(flags)},\"consent_version\":\"2026-11-01\",\"character_name\":\"콤보\",\"voices\":\(HubOnboardingCaptureTests.voices),"
            + "\"invite_waitlist_joined\":false,\"region_waitlist_joined\":false,\"invite_only\":true,\"invited_by\":\"친구\"\(extra)}"
    }

    private final class Rig {
        let http = FakeHTTP()
        let host = OnboardingHost()
        var cleared = 0
        var signedOut = 0
    }

    private func makeRig(_ step: String, flags: String = "\"terms\":false,\"privacy\":false,\"marketing\":false", extra: String = "", back: Bool = true) -> Rig {
        let r = Rig()
        r.http.on("GET /api/v1/me/onboarding", 200, state(step, flags: flags, extra: extra, back: back))
        let client = HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: r.http, tokens: { _, done in done("fake-token") })
        r.host.today = { AccountRules.Day(year: 2026, month: 11, day: 15) }
        r.host.onCleared = { [unowned r] in r.cleared += 1 }
        r.host.onSignOut = { [unowned r] in r.signedOut += 1 }
        r.host.activate(client: client)
        spin(0.05)
        return r
    }

    // MARK: view helpers

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField, !f.isHidden { out.append(f.stringValue) }
        if let b = v as? NSButton, !b.isHidden { out.append(b.title) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func all<T: NSView>(_ type: T.Type, in v: NSView) -> [T] {
        var out: [T] = []
        if let t = v as? T { out.append(t) }
        for s in v.subviews { out += all(type, in: s) }
        return out
    }

    private func pill(_ name: String, _ r: Rig) -> PetPill? { all(PetPill.self, in: r.host.view).first { $0.accessibilityLabel() == name && !$0.isHidden } }

    private func press(_ name: String, _ r: Rig, file: StaticString = #filePath, line: UInt = #line) {
        guard let p = pill(name, r) else { XCTFail("no button \(name): \(texts(r.host.view))", file: file, line: line); return }
        p.onClick?()
        spin(0.05)
    }

    private func enabled(_ name: String, _ r: Rig) -> Bool { pill(name, r)?.isEnabled ?? false }

    private func field(_ id: String, _ r: Rig) -> NSTextField? { all(NSTextField.self, in: r.host.view).first { $0.identifier?.rawValue == id } }

    private func type(_ id: String, _ text: String, _ r: Rig, file: StaticString = #filePath, line: UInt = #line) {
        guard let f = field(id, r) else { XCTFail("no field \(id)", file: file, line: line); return }
        f.stringValue = text
        r.host.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: f))
    }

    private func spin(_ s: TimeInterval = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func shows(_ r: Rig, _ s: String) -> Bool { texts(r.host.view).contains { $0.contains(s) } }

    // MARK: capture

    private var outDir: URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures") }

    private func capture(_ r: Rig, name: String) throws {
        for dark in [false, true] {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = PetBox()
            root.fill = PetTheme.color(\.window)
            w.contentView = root
            HubKit.pin(r.host.view, in: root)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "onboarding-\(name)-\(dark ? "dark" : "light")")
            r.host.view.removeFromSuperview()
        }
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

    // MARK: 초대 코드

    func testInviteGateCodeNeedsSixDigitsAndPostsTheCode() throws {
        let r = makeRig("invite_gate", back: false)
        XCTAssertTrue(shows(r, "초대 코드가 있나요?"))
        XCTAssertFalse(enabled("코드 확인", r), "6자리 전에는 못 보낸다")
        type("inviteCode", "12a-345", r)
        XCTAssertEqual(field("inviteCode", r)?.stringValue, "12345", "숫자만 남는다")
        XCTAssertFalse(enabled("코드 확인", r))
        try capture(r, name: "invite-gate")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"name\",\"stage\":\"profile\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("name"))
        type("inviteCode", "123456", r)
        XCTAssertTrue(enabled("코드 확인", r))
        press("코드 확인", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit"), ["{\"step\":\"invite_gate\",\"value\":{\"invite_code\":\"123456\"}}"])
        XCTAssertTrue(shows(r, "나초가 뭐라고 부르면 좋을까요?"), "서버가 준 다음 단계가 그려진다")
    }

    func testNoInviteCodeSendsAnEmptyCodeAndRefusalIsKorean() throws {
        let r = makeRig("invite_gate", back: false)
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"invite_gate\",\"stage\":\"invite\",\"rejection\":{\"code\":\"invite_invalid\"}}")
        type("inviteCode", "000000", r)
        press("코드 확인", r)
        XCTAssertTrue(shows(r, "이 코드는 쓸 수 없어요. 코드를 확인해 주세요."))
        XCTAssertTrue(shows(r, "초대 코드가 있나요?"), "단계는 그대로")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"invite_waitlist\",\"stage\":\"invite\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("invite_waitlist", back: false))
        press("초대 코드가 없어요", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit").last, "{\"step\":\"invite_gate\",\"value\":{\"invite_code\":\"\"}}")
        XCTAssertTrue(shows(r, "아직 시작할 수 없어요"))
        try capture(r, name: "invite-waitlist")
        r.http.on("POST /api/v1/me/onboarding/invite-waitlist", 200, state("invite_waitlist"))
        r.http.on("GET /api/v1/me/onboarding", 200, state("invite_waitlist").replacingOccurrences(of: "\"invite_waitlist_joined\":false", with: "\"invite_waitlist_joined\":true"))
        press("대기 등록", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/invite-waitlist"), ["{}"])
        XCTAssertTrue(shows(r, "대기 등록을 마쳤어요."))
        press("로그아웃", r)
        XCTAssertEqual(r.signedOut, 1)
    }

    // MARK: 이름·생일

    func testNameIsCheckedBeforeSendingAndPostsTrimmed() throws {
        let r = makeRig("name")
        XCTAssertTrue(shows(r, "친구님이 초대했어요."))
        try capture(r, name: "name")
        XCTAssertEqual(field("name", r)?.stringValue, "나초팬", "서버 추천 이름이 들어 있다")
        type("name", "", r)
        XCTAssertFalse(enabled("계속", r), "빈 값은 못 보낸다")
        type("name", String(repeating: "가", count: 41), r)
        press("계속", r)
        XCTAssertTrue(shows(r, "이름은 줄바꿈 없이 1~40자로 써 주세요."))
        XCTAssertTrue(r.http.writes.isEmpty, "검증에 걸리면 서버로 보내지 않는다")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"birthday\",\"stage\":\"profile\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("birthday"))
        type("name", "  초코  ", r)
        press("계속", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit"), ["{\"step\":\"name\",\"value\":\"초코\"}"])
        XCTAssertTrue(shows(r, "생일을 알려 주세요"))
    }

    func testServerRefusesTheNameWithAKoreanReasonAndKeepsTheInput() {
        let r = makeRig("name")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"name\",\"stage\":\"profile\",\"rejection\":{\"code\":\"blocked_word\"}}")
        type("name", "나쁜말", r)
        press("계속", r)
        XCTAssertTrue(shows(r, "쓸 수 없는 표현이 들어 있어요. 다른 이름으로 해 주세요."))
        XCTAssertEqual(field("name", r)?.stringValue, "나쁜말", "오류가 나도 입력은 그대로")
    }

    func testBirthdayChecksTheDateAndPostsIso() throws {
        let r = makeRig("birthday")
        try capture(r, name: "birthday")
        XCTAssertFalse(enabled("계속", r))
        type("year", "1999", r); type("month", "2", r); type("day", "30", r)
        press("계속", r)
        XCTAssertTrue(shows(r, "날짜를 다시 확인해 주세요. 없는 날짜나 미래 날짜는 쓸 수 없어요."))
        XCTAssertTrue(r.http.writes.isEmpty)
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"consent\",\"stage\":\"consents\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("consent"))
        type("day", "3", r)
        press("계속", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit"), ["{\"step\":\"birthday\",\"value\":\"1999-02-03\"}"])
    }

    func testUnderageOffersLogout() {
        let r = makeRig("birthday")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"birthday\",\"stage\":\"profile\",\"rejection\":{\"code\":\"underage\"}}")
        type("year", "2020", r); type("month", "1", r); type("day", "1", r)
        press("계속", r)
        XCTAssertTrue(shows(r, "아직 나초를 쓸 수 있는 나이가 아니에요."))
        press("로그아웃", r)
        XCTAssertEqual(r.signedOut, 1)
    }

    // MARK: 약관

    func testConsentNeedsTheFourRequiredAndPostsTheSpecKeys() throws {
        let r = makeRig("consent")
        XCTAssertFalse(enabled("계속", r))
        let boxes = all(OnboardingCheck.self, in: r.host.view)
        XCTAssertEqual(boxes.count, 6, "모두 동의 + 문서 다섯")
        try capture(r, name: "consent")
        for b in boxes where b.title.contains("(필수)") { b.state = .on; b.onToggle?(true) }
        XCTAssertTrue(enabled("계속", r), "혜택 알림(선택) 없이도 계속")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"guide\",\"stage\":\"consents\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("guide"))
        press("계속", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit"),
                       ["{\"step\":\"consent\",\"value\":{\"consent_version\":\"2026-11-01\",\"marketing\":false,\"privacy\":true,\"terms\":true}}"])
        XCTAssertTrue(shows(r, "나초는 실제로 일을 해요"))
    }

    func testAllAgreeTogglesEveryRow() {
        let r = makeRig("consent")
        let boxes = all(OnboardingCheck.self, in: r.host.view)
        let allBox = boxes.first { $0.title == "모두 동의" }!
        allBox.state = .on; allBox.onToggle?(true)
        XCTAssertTrue(boxes.allSatisfy { $0.state == .on })
        XCTAssertTrue(enabled("계속", r))
        allBox.state = .off; allBox.onToggle?(false)
        XCTAssertTrue(boxes.allSatisfy { $0.state == .off })
        XCTAssertFalse(enabled("계속", r))
    }

    func testDocumentTextOpensUnderItsRow() {
        let r = makeRig("consent")
        XCTAssertFalse(texts(r.host.view).contains { $0.contains("임시 문서예요") })
        press("이용약관 보기", r)
        XCTAssertTrue(texts(r.host.view).contains { $0.contains("임시 문서예요") && $0.contains("시험판 이용약관") })
    }

    // MARK: 안내·캐릭터·끝

    func testGuideEggNameVoiceThenHatchFinishesOnce() throws {
        let r = makeRig("guide")
        try capture(r, name: "guide")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"egg_meet\",\"stage\":\"character\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("egg_meet"))
        press("계속", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit").last, "{\"step\":\"guide\"}")
        XCTAssertTrue(shows(r, "나초팬, 나초가 기다리고 있어요"))
        try capture(r, name: "egg-meet")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"character_name\",\"stage\":\"character\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("character_name"))
        press("봉지 뜯기", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit").last, "{\"step\":\"egg_meet\"}")
        try capture(r, name: "character-name")
        type("characterName", "@콤보", r)
        press("계속", r)
        XCTAssertTrue(shows(r, "AI 친구 이름은 줄바꿈과 @ 없이 1~20자로 써 주세요."))
        let before = r.http.bodies("POST /api/v1/me/onboarding/submit").count
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"character_voice\",\"stage\":\"character\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("character_voice"))
        type("characterName", "콤보", r)
        press("계속", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit").count, before + 1)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit").last, "{\"step\":\"character_name\",\"value\":\"콤보\"}")
        XCTAssertTrue(shows(r, "콤보가 어떤 목소리로 말할까요?"))
        XCTAssertFalse(enabled("계속", r), "목소리를 고르기 전에는 못 보낸다")
        try capture(r, name: "character-voice")
        let radios = all(OnboardingCheck.self, in: r.host.view)
        XCTAssertEqual(radios.count, 2)
        radios[1].state = .on; radios[1].onToggle?(true)
        XCTAssertEqual(radios[0].state, .off)
        // 완료: 서버가 loading을 그리면 알아서 완료를 보내고, done이 되면 끝 인사를 보여 준다.
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"done\",\"stage\":\"complete\",\"agent_id\":\"a\",\"room_id\":\"r\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("loading"))
        r.http.then("GET /api/v1/me/onboarding", 200, state("done", flags: "\"terms\":true,\"privacy\":true,\"marketing\":false"))
        press("계속", r)
        spin(0.3)
        let posts = r.http.bodies("POST /api/v1/me/onboarding/submit")
        XCTAssertEqual(posts.suffix(2), ["{\"step\":\"character_voice\",\"value\":\"v_b\"}", "{\"step\":\"loading\"}"], "목소리를 보내고, loading이 되면 알아서 완료를 한 번 보낸다")
        XCTAssertEqual(r.cleared, 0, "끝 인사에서 누를 때까지는 그대로")
        XCTAssertTrue(shows(r, "안녕, 나초팬. 나 콤보야."))
        try capture(r, name: "greeting")
        press("같이 시작하기", r)
        XCTAssertEqual(r.cleared, 1)
    }

    func testAlreadyFinishedAccountClearsAtOnce() {
        let r = makeRig("done", flags: "\"terms\":true,\"privacy\":true,\"marketing\":false", back: false)
        XCTAssertEqual(r.cleared, 1)
        XCTAssertTrue(r.http.writes.isEmpty)
    }

    func testBackGoesToTheServerPreviousScreen() {
        let r = makeRig("birthday")
        r.http.on("POST /api/v1/me/onboarding/back", 200, "{\"step\":\"name\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("name"))
        press("뒤로", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/back"), ["{\"from\":\"birthday\"}"])
        XCTAssertTrue(shows(r, "나초가 뭐라고 부르면 좋을까요?"))
    }

    // MARK: 전화번호 인증(G3) · 약관 갱신 · 멈춘 계정

    func testPhoneStepOnlyAsksToFinishOnThePhoneApp() throws {
        let r = makeRig("phone_verify")
        XCTAssertTrue(shows(r, "휴대폰의 나초 앱에서 마쳐 주세요"))
        XCTAssertTrue(shows(r, HubOnboardingRules.phoneNotice))
        XCTAssertNil(field("phone", r), "전화번호 입력 칸이 없다")
        XCTAssertNotNil(pill("다시 확인", r))
        try capture(r, name: "phone-on-phone")
        r.http.on("GET /api/v1/me/onboarding", 200, state("consent"))
        press("다시 확인", r)
        XCTAssertTrue(r.http.writes.isEmpty, "맥에서는 SMS 인증을 하지 않는다: 쓰기 요청이 없다")
        XCTAssertTrue(shows(r, "약관을 확인해 주세요"), "휴대폰에서 마쳤다면 다음 단계로")
    }

    func testReconsentAgreesAndKeepsMarketing() throws {
        let r = makeRig("done", flags: "\"terms\":false,\"privacy\":false,\"marketing\":true", back: false)
        XCTAssertTrue(shows(r, "약관이 바뀌었어요"))
        XCTAssertEqual(r.cleared, 0)
        try capture(r, name: "reconsent")
        r.http.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"done\",\"stage\":\"complete\"}")
        r.http.on("GET /api/v1/me/onboarding", 200, state("done", flags: "\"terms\":true,\"privacy\":true,\"marketing\":true", back: false))
        press("동의하고 계속", r)
        XCTAssertEqual(r.http.bodies("POST /api/v1/me/onboarding/submit"),
                       ["{\"step\":\"consent\",\"value\":{\"consent_version\":\"2026-11-01\",\"marketing\":true,\"privacy\":true,\"terms\":true}}"])
        XCTAssertEqual(r.cleared, 1)
    }

    func testRegionClosedOffersTheWaitlist() throws {
        let closed = state("name", extra: ",\"region_name\":\"서울\"").replacingOccurrences(of: "\"account_status\":\"active\"", with: "\"account_status\":\"region_closed\"")
        let h = FakeHTTP()
        h.on("GET /api/v1/me/onboarding", 200, closed)
        let host = OnboardingHost()
        host.activate(client: HubClient(endpoint: ServerEndpoint(base: URL(string: "https://nacho.example.com")!), http: h, tokens: { _, done in done("T") }))
        spin(0.05)
        XCTAssertTrue(texts(host.view).contains { $0.contains("이 지역은 아직 열리지 않았어요") })
        let join = all(PetPill.self, in: host.view).first { $0.accessibilityLabel() == "대기 등록" }
        XCTAssertNotNil(join)
        h.on("POST /api/v1/me/onboarding/region-waitlist", 200, closed)
        h.on("GET /api/v1/me/onboarding", 200, closed.replacingOccurrences(of: "\"region_waitlist_joined\":false", with: "\"region_waitlist_joined\":true"))
        join?.onClick?()
        spin(0.05)
        XCTAssertEqual(h.bodies("POST /api/v1/me/onboarding/region-waitlist"), ["{}"])
        XCTAssertTrue(texts(host.view).contains { $0.contains("대기 등록을 마쳤어요") })
    }
}
