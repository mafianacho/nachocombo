import XCTest
@testable import NachoComboCore

/// 맥에서 가입 마치기(NACHO-277 U11, 표 행 A2): 요청 바이트·응답 읽기·입력 규칙. 운영 서버는 부르지 않는다(가짜 HTTP).
final class HubOnboardingAPITests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, body: Data(json.utf8)) }
    private func value<T>(_ r: Result<T, PetAPIError>) -> T? { if case let .success(v) = r { return v }; return nil }
    private func failure<T>(_ r: Result<T, PetAPIError>) -> PetAPIError? { if case let .failure(f) = r { return f }; return nil }

    // MARK: request bytes

    func testStateIsAGetWithTheBearer() {
        let r = HubOnboardingAPI.state(e, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me/onboarding")
        XCTAssertEqual(r.headers["Authorization"], "Bearer T")
        XCTAssertNil(r.body)
    }

    func testSubmitCarriesStepAndValue() {
        let name = HubOnboardingAPI.submit(e, bearer: "T", step: .name, value: "나초")
        XCTAssertEqual(name.method, "POST")
        XCTAssertEqual(name.url.absoluteString, "https://nacho.example.com/api/v1/me/onboarding/submit")
        XCTAssertEqual(body(name), "{\"step\":\"name\",\"value\":\"나초\"}")
        XCTAssertEqual(name.headers["Content-Type"], "application/json")
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .birthday, value: "1999-02-03")), "{\"step\":\"birthday\",\"value\":\"1999-02-03\"}")
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .guide, value: nil)), "{\"step\":\"guide\"}")
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .loading, value: nil)), "{\"step\":\"loading\"}")
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .characterVoice, value: "v_rosa")), "{\"step\":\"character_voice\",\"value\":\"v_rosa\"}")
    }

    func testInviteGateValueIsAnObjectAndEmptyMeansWaitlist() {
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .inviteGate, value: ["invite_code": "123456"])),
                       "{\"step\":\"invite_gate\",\"value\":{\"invite_code\":\"123456\"}}")
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .inviteGate, value: ["invite_code": ""])),
                       "{\"step\":\"invite_gate\",\"value\":{\"invite_code\":\"\"}}")
    }

    func testConsentValueHasTheSpecKeysAndTheDocumentVersion() {
        let v = HubOnboardingRules.consentValue(terms: true, privacy: true, thirdParty: true, aiTransfer: true, marketing: false, version: "2026-11-01")
        XCTAssertEqual(body(HubOnboardingAPI.submit(e, bearer: "T", step: .consent, value: v)),
                       "{\"step\":\"consent\",\"value\":{\"ai_transfer\":true,\"consent_version\":\"2026-11-01\",\"marketing\":false,\"privacy\":true,\"terms\":true,\"third_party\":true}}")
    }

    func testBackWaitlistsAndRedeem() {
        let back = HubOnboardingAPI.back(e, bearer: "T", from: .birthday)
        XCTAssertEqual(back.method, "POST")
        XCTAssertEqual(back.url.path, "/api/v1/me/onboarding/back")
        XCTAssertEqual(body(back), "{\"from\":\"birthday\"}")
        let inv = HubOnboardingAPI.inviteWaitlist(e, bearer: "T")
        XCTAssertEqual(inv.method, "POST"); XCTAssertEqual(inv.url.path, "/api/v1/me/onboarding/invite-waitlist"); XCTAssertEqual(body(inv), "{}")
        let reg = HubOnboardingAPI.regionWaitlist(e, bearer: "T")
        XCTAssertEqual(reg.url.path, "/api/v1/me/onboarding/region-waitlist"); XCTAssertEqual(body(reg), "{}")
        let red = HubOnboardingAPI.redeem(e, bearer: "T", code: "123456")
        XCTAssertEqual(red.url.path, "/api/v1/me/onboarding/invite/redeem"); XCTAssertEqual(body(red), "{\"code\":\"123456\"}")
    }

    // MARK: responses

    private let fullState = """
    {"step":"consent","stage":"consents","can_go_back":true,"account_status":"active","display_name":"나초","name_suggestions":["나초","초코"],
     "birthday":"1999-02-03","consents":[],"consent_flags":{"terms":true,"privacy":false,"marketing":true},"consent_version":"2026-11-01",
     "character_name":"콤보","voice":"v_a","voices":[{"voice_id":"v_a","name":"a","label":"차분한","description":"조용해요","sample_url":"/m/a.mp3"},{"voice_id":"v_b","name":"b","label":"밝은","description":"통통 튀어요"}],
     "invite_waitlist_joined":true,"region_waitlist_joined":false,"invite_only":true,"invited_by":"친구","region_name":"서울","advanced_steps":[]}
    """

    func testStateParsesEveryFieldTheScreensUse() throws {
        let s = try XCTUnwrap(value(HubOnboardingAPI.parseState(resp(200, fullState))))
        XCTAssertEqual(s.step, .consent)
        XCTAssertTrue(s.canGoBack)
        XCTAssertEqual(s.accountStatus, .active)
        XCTAssertEqual(s.displayName, "나초")
        XCTAssertEqual(s.nameSuggestions, ["나초", "초코"])
        XCTAssertEqual(s.birthday, "1999-02-03")
        XCTAssertEqual(s.consentTerms, true); XCTAssertEqual(s.consentPrivacy, false); XCTAssertEqual(s.consentMarketing, true)
        XCTAssertEqual(s.consentVersion, "2026-11-01")
        XCTAssertEqual(s.voices.map { $0.voiceID }, ["v_a", "v_b"])
        XCTAssertEqual(s.voices[0].label, "차분한")
        XCTAssertEqual(s.voice, "v_a")
        XCTAssertTrue(s.inviteWaitlistJoined); XCTAssertFalse(s.regionWaitlistJoined)
        XCTAssertEqual(s.invitedBy, "친구"); XCTAssertEqual(s.regionName, "서울")
    }

    func testStepNamesMatchTheServerEnum() {
        let names = ["login", "invite_gate", "invite_waitlist", "name", "birthday", "consent", "guide", "guide_privacy", "egg_meet",
                     "character_name", "character_voice", "loading", "done"]
        XCTAssertEqual(names.map { HubOnboardingStep(raw: $0).raw }, names)
        XCTAssertEqual(HubOnboardingStep(raw: "character_voice"), .characterVoice)
    }

    func testAPhoneStepAndAnUnknownStepAreKept() {
        XCTAssertEqual(HubOnboardingStep(raw: "phone_verify"), .phone("phone_verify"))
        XCTAssertEqual(HubOnboardingStep(raw: "phone"), .phone("phone"))
        XCTAssertEqual(HubOnboardingStep(raw: "something_new"), .unknown("something_new"))
        XCTAssertEqual(HubOnboardingStep.phone("phone").raw, "phone")
        XCTAssertEqual(HubOnboardingStep.unknown("something_new").raw, "something_new")
    }

    func testStateWithoutAStepIsABadResponse() {
        XCTAssertEqual(failure(HubOnboardingAPI.parseState(resp(200, "{\"stage\":\"consents\"}")))?.code, PetAPIError.badResponse.code)
        XCTAssertNotNil(failure(HubOnboardingAPI.parseState(resp(200, "[]"))))
    }

    func testSubmitResultKeepsOnlyTheRejectionCode() throws {
        let ok = try XCTUnwrap(value(HubOnboardingAPI.parseSubmit(resp(200, "{\"step\":\"birthday\",\"stage\":\"profile\"}"))))
        XCTAssertEqual(ok.step, .birthday); XCTAssertNil(ok.rejection)
        let no = try XCTUnwrap(value(HubOnboardingAPI.parseSubmit(resp(200, "{\"step\":\"name\",\"stage\":\"profile\",\"rejection\":{\"code\":\"blocked_word\",\"value\":\"내가 쓴 글\"}}"))))
        XCTAssertEqual(no.rejection, "blocked_word")
        let done = try XCTUnwrap(value(HubOnboardingAPI.parseSubmit(resp(200, "{\"step\":\"done\",\"stage\":\"complete\",\"agent_id\":\"a\",\"room_id\":\"r\"}"))))
        XCTAssertEqual(done.step, .done)
    }

    func testBackResultIsTheStep() {
        XCTAssertEqual(value(HubOnboardingAPI.parseBack(resp(200, "{\"step\":\"name\"}"))), .name)
    }

    func testErrorsAreKoreanAndKeepTheirCode() {
        let unauth = failure(HubOnboardingAPI.parseState(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")))
        XCTAssertEqual(unauth?.isUnauthorized, true)
        XCTAssertEqual(unauth?.text, "로그인이 필요해요.")
        XCTAssertEqual(failure(HubOnboardingAPI.parseState(resp(404, "{}")))?.isNotFound, true)
        XCTAssertEqual(failure(HubOnboardingAPI.parseSubmit(resp(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"m\"}}")))?.isVersionConflict, true)
        let server = failure(HubOnboardingAPI.parseSubmit(resp(500, "{\"error\":{\"code\":\"internal\",\"message\":\"boom\"}}")))
        XCTAssertNotNil(server)
        XCTAssertFalse(server!.text.isEmpty)
    }

    // MARK: rules (앱 규칙 그대로)

    func testNameRule() {
        XCTAssertEqual(HubOnboardingRules.name("  나초 "), .ok("나초"))
        XCTAssertEqual(HubOnboardingRules.name("   "), .empty)
        XCTAssertEqual(HubOnboardingRules.name(String(repeating: "가", count: 41)), .tooLong)
        XCTAssertEqual(HubOnboardingRules.name(String(repeating: "가", count: 40)), .ok(String(repeating: "가", count: 40)))
        XCTAssertEqual(HubOnboardingRules.nameProblem("   "), "부를 이름을 입력해 주세요.")
        XCTAssertEqual(HubOnboardingRules.nameProblem(String(repeating: "가", count: 41)), "이름은 줄바꿈 없이 1~40자로 써 주세요.")
        XCTAssertNil(HubOnboardingRules.nameProblem("나초"))
    }

    func testBirthdayRuleMessages() {
        let today = AccountRules.Day(year: 2026, month: 11, day: 15)
        XCTAssertEqual(HubOnboardingRules.birthday("1999", "2", "3", today: today), .ok("1999-02-03"))
        XCTAssertEqual(HubOnboardingRules.birthdayProblem("1999", "2", "30", today: today), "날짜를 다시 확인해 주세요. 없는 날짜나 미래 날짜는 쓸 수 없어요.")
        XCTAssertEqual(HubOnboardingRules.birthdayProblem("2027", "1", "1", today: today), "날짜를 다시 확인해 주세요. 없는 날짜나 미래 날짜는 쓸 수 없어요.")
        XCTAssertEqual(HubOnboardingRules.birthdayProblem("", "", "", today: today), "생일을 입력해 주세요.")
        XCTAssertNil(HubOnboardingRules.birthdayProblem("1999", "2", "3", today: today))
    }

    func testInviteCodeIsSixDigits() {
        XCTAssertTrue(HubOnboardingRules.inviteCodeValid("123456"))
        XCTAssertFalse(HubOnboardingRules.inviteCodeValid("12345"))
        XCTAssertFalse(HubOnboardingRules.inviteCodeValid("1234567"))
        XCTAssertFalse(HubOnboardingRules.inviteCodeValid("12345a"))
        XCTAssertEqual(HubOnboardingRules.inviteCodeClean(" 12-34 56 "), "123456")
        XCTAssertEqual(HubOnboardingRules.inviteCodeClean("1234567890"), "123456")
    }

    func testCharacterNameRule() {
        XCTAssertEqual(HubOnboardingRules.characterName(" 콤보 "), .ok("콤보"))
        XCTAssertEqual(HubOnboardingRules.characterName(""), .empty)
        XCTAssertEqual(HubOnboardingRules.characterName(String(repeating: "가", count: 21)), .tooLong)
        XCTAssertEqual(HubOnboardingRules.characterName("나\n초"), .invalid)
        XCTAssertEqual(HubOnboardingRules.characterName("@나초"), .invalid)
        XCTAssertEqual(HubOnboardingRules.characterNameProblem("@나초"), "AI 친구 이름은 줄바꿈과 @ 없이 1~20자로 써 주세요.")
    }

    func testConsentNeedsTheFourRequiredOnesAndNotMarketing() {
        XCTAssertFalse(HubOnboardingRules.consentsReady(terms: true, privacy: true, thirdParty: true, aiTransfer: false))
        XCTAssertFalse(HubOnboardingRules.consentsReady(terms: false, privacy: true, thirdParty: true, aiTransfer: true))
        XCTAssertTrue(HubOnboardingRules.consentsReady(terms: true, privacy: true, thirdParty: true, aiTransfer: true))
    }

    func testRejectionTextsAreKorean() {
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .name, code: "invalid_input"), "이름은 줄바꿈 없이 1~40자로 써 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .characterName, code: "invalid_input"), "AI 친구 이름은 줄바꿈과 @ 없이 1~20자로 써 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .birthday, code: "invalid_input"), "날짜를 다시 확인해 주세요. 없는 날짜나 미래 날짜는 쓸 수 없어요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .consent, code: "invalid_input"), "입력한 내용을 다시 확인해 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .name, code: "blocked_word"), "쓸 수 없는 표현이 들어 있어요. 다른 이름으로 해 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .inviteGate, code: "invite_invalid"), "이 코드는 쓸 수 없어요. 코드를 확인해 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .inviteGate, code: "invite_expired"), "기간이 지난 코드예요. 새 초대를 받아 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .inviteGate, code: "invite_exhausted"), "이 코드의 초대 수가 다 찼어요. 새 초대를 받아 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .inviteGate, code: "too_many_requests"), "시도가 너무 많았어요. 잠시 뒤에 다시 해 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .birthday, code: "underage"), "아직 나초를 쓸 수 있는 나이가 아니에요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .name, code: "impersonation"), "다른 사람이나 서비스로 오해할 수 있는 이름이에요. 다른 이름으로 해 주세요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .name, code: "suspended"), "계정을 쓸 수 없는 상태예요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .name, code: "region_closed"), "이 지역은 아직 열리지 않았어요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .inviteGate, code: "invite_required"), "초대 확인이 먼저 필요해요.")
        XCTAssertEqual(HubOnboardingRules.rejectionText(step: .name, code: "brand_new_code"), "문제가 생겨 진행하지 못했어요. 잠시 뒤에 다시 해 주세요.")
    }

    func testParticleFollowsTheLastSyllable() {
        XCTAssertEqual(HubOnboardingRules.particle("콤보", "이", "가"), "가")
        XCTAssertEqual(HubOnboardingRules.particle("나초", "이", "가"), "가")
        XCTAssertEqual(HubOnboardingRules.particle("달곰", "이", "가"), "이")
        XCTAssertEqual(HubOnboardingRules.particle("Bob", "이", "가"), "가")
        XCTAssertEqual(HubOnboardingRules.particle("", "이야", "야"), "야")
    }

    func testPhoneNoticeSaysToFinishOnThePhoneApp() {
        XCTAssertTrue(HubOnboardingRules.phoneNotice.contains("휴대폰의 나초 앱에서"))
        XCTAssertTrue(HubOnboardingRules.phoneNotice.contains("마쳐"))
    }
}
