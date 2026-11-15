import XCTest
@testable import NachoComboCore

/// 가입 단계 전환 상태 기계, 전화 인증 단계 안내, 가입 전에는 대화 소켓을 열지 않는다는 것(NACHO-277 U11).
final class HubOnboardingFlowTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)

    /// "METHOD path"별로 답을 줄 세워 놓는다. 마지막 답은 되풀이한다. `hold`면 답을 쥐고 있다가 `release()`로 보낸다.
    private final class Router: PetHTTPClient {
        private let lock = NSLock()
        private var answers: [String: [PetHTTPResponse]] = [:]
        private(set) var sent: [PetHTTPRequest] = []
        var hold = false
        private var held: [() -> Void] = []

        func on(_ key: String, _ status: Int, _ body: String) { lock.lock(); answers[key, default: []].append(PetHTTPResponse(status: status, body: Data(body.utf8))); lock.unlock() }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            lock.lock()
            sent.append(request)
            let key = "\(request.method) \(request.url.path)"
            var list = answers[key] ?? []
            let r = list.first ?? PetHTTPResponse(status: 404, body: Data("{}".utf8))
            if list.count > 1 { list.removeFirst(); answers[key] = list }
            let hold = self.hold
            lock.unlock()
            if hold { lock.lock(); held.append { completion(.success(r)) }; lock.unlock() } else { completion(.success(r)) }
        }
        func release() { lock.lock(); let h = held; held = []; lock.unlock(); h.forEach { $0() } }
        func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return sent.map { "\($0.method) \($0.url.path)" } }
        func bodies(_ key: String) -> [String] {
            lock.lock(); defer { lock.unlock() }
            return sent.filter { "\($0.method) \($0.url.path)" == key }.map { String(data: $0.body ?? Data(), encoding: .utf8) ?? "" }
        }
    }

    private func state(_ step: String, extra: String = "") -> String {
        "{\"step\":\"\(step)\",\"stage\":\"profile\",\"can_go_back\":true,\"account_status\":\"active\",\"name_suggestions\":[],\"consents\":[],\"consent_flags\":{\"terms\":false,\"privacy\":false,\"marketing\":false},\"consent_version\":\"v1\",\"voices\":[{\"voice_id\":\"v_a\",\"name\":\"a\",\"label\":\"A\",\"description\":\"d\"}],\"invite_waitlist_joined\":false,\"region_waitlist_joined\":false,\"invite_only\":false\(extra)}"
    }
    private func submitOK(_ step: String) -> String { "{\"step\":\"\(step)\",\"stage\":\"profile\"}" }
    private func submitNo(_ step: String, _ code: String) -> String { "{\"step\":\"\(step)\",\"stage\":\"profile\",\"rejection\":{\"code\":\"\(code)\"}}" }

    private func makeFlow(_ r: Router) -> HubOnboardingFlow {
        HubOnboardingFlow(client: HubClient(endpoint: e, http: r, tokens: { _, done in done("T") }))
    }

    // MARK: 단계 전환

    func testLoadReadsTheServerStep() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("name"))
        let f = makeFlow(r)
        f.load()
        XCTAssertEqual(f.snapshot.state?.step, .name)
        XCTAssertEqual(f.snapshot.phase, .step)
        XCTAssertEqual(r.paths(), ["GET /api/v1/me/onboarding"])
    }

    func testSubmitSendsTheStepThenReadsTheNextScreen() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("name")); r.on("GET /api/v1/me/onboarding", 200, state("birthday"))
        r.on("POST /api/v1/me/onboarding/submit", 200, submitOK("birthday"))
        let f = makeFlow(r); f.load()
        f.submit(.name, value: "나초")
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/submit"), ["{\"step\":\"name\",\"value\":\"나초\"}"])
        XCTAssertEqual(f.snapshot.state?.step, .birthday)
        XCTAssertNil(f.snapshot.error)
        XCTAssertFalse(f.snapshot.busy)
    }

    func testARejectionKeepsTheScreenAndShowsKoreanText() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("name"))
        r.on("POST /api/v1/me/onboarding/submit", 200, submitNo("name", "blocked_word"))
        let f = makeFlow(r); f.load()
        f.submit(.name, value: "나쁜말")
        XCTAssertEqual(f.snapshot.state?.step, .name)
        XCTAssertEqual(f.snapshot.error, .rejected("blocked_word"))
        XCTAssertEqual(f.snapshot.errorText, "쓸 수 없는 표현이 들어 있어요. 다른 이름으로 해 주세요.")
        XCTAssertEqual(r.paths().filter { $0 == "GET /api/v1/me/onboarding" }.count, 1, "화면이 그대로면 다시 읽지 않는다")
    }

    func testARejectionOnAStaleScreenReadsTheCurrentOne() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("name")); r.on("GET /api/v1/me/onboarding", 200, state("consent"))
        r.on("POST /api/v1/me/onboarding/submit", 200, submitNo("consent", "invalid_input"))
        let f = makeFlow(r); f.load()
        f.submit(.name, value: "나초")
        XCTAssertEqual(f.snapshot.state?.step, .consent)
    }

    func testSuspendedAndRegionClosedReadTheAccountAgain() {
        for code in ["suspended", "region_closed"] {
            let r = Router()
            r.on("GET /api/v1/me/onboarding", 200, state("name")); r.on("GET /api/v1/me/onboarding", 200, state("name", extra: ",\"x\":1").replacingOccurrences(of: "\"active\"", with: "\"\(code)\""))
            r.on("POST /api/v1/me/onboarding/submit", 200, submitNo("name", code))
            let f = makeFlow(r); f.load()
            f.submit(.name, value: "나초")
            XCTAssertEqual(f.snapshot.state?.accountStatus, code == "suspended" ? .suspended : .regionClosed, code)
            XCTAssertEqual(f.snapshot.error, .rejected(code))
        }
    }

    func testBackAsksTheServerAndReadsTheScreen() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("birthday")); r.on("GET /api/v1/me/onboarding", 200, state("name"))
        r.on("POST /api/v1/me/onboarding/back", 200, "{\"step\":\"name\"}")
        let f = makeFlow(r); f.load()
        f.back()
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/back"), ["{\"from\":\"birthday\"}"])
        XCTAssertEqual(f.snapshot.state?.step, .name)
    }

    func testBackIsIgnoredWhereTheServerHasNone() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("name").replacingOccurrences(of: "\"can_go_back\":true", with: "\"can_go_back\":false"))
        let f = makeFlow(r); f.load()
        f.back()
        XCTAssertTrue(r.bodies("POST /api/v1/me/onboarding/back").isEmpty)
    }

    func testThePrivacyGuideIsPassedByTheClientForward() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("guide_privacy")); r.on("GET /api/v1/me/onboarding", 200, state("egg_meet"))
        r.on("POST /api/v1/me/onboarding/submit", 200, submitOK("egg_meet"))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/submit"), ["{\"step\":\"guide_privacy\"}"])
        XCTAssertEqual(f.snapshot.state?.step, .eggMeet)
    }

    func testBackFromTheStepAfterThePrivacyGuideGoesBackTwice() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("egg_meet")); r.on("GET /api/v1/me/onboarding", 200, state("consent"))
        r.on("POST /api/v1/me/onboarding/back", 200, "{\"step\":\"guide_privacy\"}"); r.on("POST /api/v1/me/onboarding/back", 200, "{\"step\":\"consent\"}")
        let f = makeFlow(r); f.load()
        f.back()
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/back"), ["{\"from\":\"egg_meet\"}", "{\"from\":\"guide_privacy\"}"])
        XCTAssertEqual(f.snapshot.state?.step, .consent)
    }

    func testASecondSubmitWhileOneIsOutSendsNothing() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("name"))
        r.on("POST /api/v1/me/onboarding/submit", 200, submitOK("birthday"))
        let f = makeFlow(r); f.load()
        r.hold = true
        f.submit(.name, value: "나초")
        XCTAssertTrue(f.snapshot.busy)
        f.submit(.name, value: "나초")
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/submit").count, 1)
        r.hold = false; r.release()
    }

    func testANetworkFailureKeepsTheScreenAndTheInput() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("name"))
        let f = makeFlow(r); f.load()
        r.on("POST /api/v1/me/onboarding/submit", 500, "{\"error\":{\"code\":\"internal\",\"message\":\"x\"}}")
        f.submit(.name, value: "나초")
        XCTAssertEqual(f.snapshot.state?.step, .name)
        XCTAssertNotNil(f.snapshot.error)
        XCTAssertFalse(f.snapshot.busy)
    }

    func testAFailedFirstReadIsARetryableFailure() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 500, "{\"error\":{\"code\":\"internal\",\"message\":\"x\"}}"); r.on("GET /api/v1/me/onboarding", 200, state("name"))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(f.snapshot.phase, .failed)
        XCTAssertNil(f.snapshot.state)
        f.load()
        XCTAssertEqual(f.snapshot.phase, .step)
    }

    func testAStepThatCannotBeAnsweredWithoutItsValuesFailsTheLoad() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("consent").replacingOccurrences(of: "\"consent_version\":\"v1\"", with: "\"consent_version\":\"\""))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(f.snapshot.phase, .failed)
        let r2 = Router(); r2.on("GET /api/v1/me/onboarding", 200, state("character_voice").replacingOccurrences(of: "\"voices\":[{\"voice_id\":\"v_a\",\"name\":\"a\",\"label\":\"A\",\"description\":\"d\"}]", with: "\"voices\":[]"))
        let f2 = makeFlow(r2); f2.load()
        XCTAssertEqual(f2.snapshot.phase, .failed)
    }

    func testFinishingTheHatchLeavesOnboardingOnDone() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("loading")); r.on("GET /api/v1/me/onboarding", 200, state("done").replacingOccurrences(of: "\"terms\":false,\"privacy\":false", with: "\"terms\":true,\"privacy\":true"))
        r.on("POST /api/v1/me/onboarding/submit", 200, "{\"step\":\"done\",\"stage\":\"complete\",\"agent_id\":\"a\",\"room_id\":\"r\"}")
        let f = makeFlow(r); f.load()
        f.submit(.loading, value: nil)
        XCTAssertEqual(f.snapshot.state?.step, .done)
        XCTAssertEqual(f.snapshot.phase, .finished)
    }

    func testWaitlistsPostAndReadAgain() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("invite_waitlist")); r.on("GET /api/v1/me/onboarding", 200, state("invite_waitlist", extra: "").replacingOccurrences(of: "\"invite_waitlist_joined\":false", with: "\"invite_waitlist_joined\":true"))
        r.on("POST /api/v1/me/onboarding/invite-waitlist", 200, state("invite_waitlist"))
        let f = makeFlow(r); f.load()
        f.joinInviteWaitlist()
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/invite-waitlist"), ["{}"])
        XCTAssertEqual(f.snapshot.state?.inviteWaitlistJoined, true)
        let r2 = Router(); r2.on("GET /api/v1/me/onboarding", 200, state("name")); r2.on("POST /api/v1/me/onboarding/region-waitlist", 500, "{}")
        let f2 = makeFlow(r2); f2.load()
        f2.joinRegionWaitlist()
        XCTAssertEqual(f2.snapshot.error, .joinFailed)
    }

    // MARK: 전화 인증 단계(G3)

    func testAPhoneStepSendsNothingAndAsksToFinishOnThePhoneApp() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("phone_verify"))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(f.snapshot.state?.step, .phone("phone_verify"))
        XCTAssertEqual(f.snapshot.phase, .phoneOnPhone)
        XCTAssertEqual(f.snapshot.notice, HubOnboardingRules.phoneNotice)
        f.submit(.phone("phone_verify"), value: "010-1234-5678")
        XCTAssertEqual(r.paths(), ["GET /api/v1/me/onboarding"], "SMS 인증은 맥에서 하지 않는다: 어떤 쓰기도 보내지 않는다")
        XCTAssertTrue(r.paths().allSatisfy { !$0.contains("/phone") })
    }

    func testPhoneStepRecheckReadsTheServerAgain() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("phone_verify")); r.on("GET /api/v1/me/onboarding", 200, state("consent"))
        let f = makeFlow(r); f.load()
        f.recheck()
        XCTAssertEqual(f.snapshot.state?.step, .consent)
        XCTAssertEqual(f.snapshot.phase, .step)
    }

    func testAnUnknownStepIsLeftToThePhoneAppToo() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state("kyc_selfie"))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(f.snapshot.phase, .phoneOnPhone)
    }

    // MARK: 약관 갱신 동의

    func testDoneWithOldConsentsAsksAgreementAgain() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("done").replacingOccurrences(of: "\"terms\":false,\"privacy\":false,\"marketing\":false", with: "\"terms\":true,\"privacy\":false,\"marketing\":true"))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(f.snapshot.phase, .reconsent)
    }

    func testDoneWithThirdPartyOrAiTransferFalseAsksAgain() {
        for key in ["third_party", "ai_transfer"] {
            let r = Router()
            r.on("GET /api/v1/me/onboarding", 200, state("done").replacingOccurrences(of: "\"terms\":false,\"privacy\":false,\"marketing\":false", with: "\"terms\":true,\"privacy\":true,\"marketing\":true,\"\(key)\":false"))
            let f = makeFlow(r); f.load()
            XCTAssertEqual(f.snapshot.phase, .reconsent, key)
        }
    }

    func testDoneWithoutThirdPartyOrAiTransferFlagsDoesNotAskAgain() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("done").replacingOccurrences(of: "\"terms\":false,\"privacy\":false,\"marketing\":false", with: "\"terms\":true,\"privacy\":true,\"marketing\":false"))
        let f = makeFlow(r); f.load()
        XCTAssertEqual(f.snapshot.phase, .finished)
    }

    func testReconsentAgreesKeepingTheMarketingChoice() {
        let r = Router()
        r.on("GET /api/v1/me/onboarding", 200, state("done").replacingOccurrences(of: "\"terms\":false,\"privacy\":false,\"marketing\":false", with: "\"terms\":false,\"privacy\":false,\"marketing\":true"))
        r.on("GET /api/v1/me/onboarding", 200, state("done").replacingOccurrences(of: "\"terms\":false,\"privacy\":false,\"marketing\":false", with: "\"terms\":true,\"privacy\":true,\"marketing\":true"))
        r.on("POST /api/v1/me/onboarding/submit", 200, submitOK("done"))
        let f = makeFlow(r); f.load()
        f.agreeAgain()
        XCTAssertEqual(r.bodies("POST /api/v1/me/onboarding/submit"),
                       ["{\"step\":\"consent\",\"value\":{\"ai_transfer\":true,\"consent_version\":\"v1\",\"marketing\":true,\"privacy\":true,\"terms\":true,\"third_party\":true}}"])
        XCTAssertEqual(f.snapshot.phase, .finished)
    }

    // MARK: 대화 소켓은 가입 뒤에

    func testGateDecidesFromTheServerState() {
        func decide(_ step: String, flags: String = "\"terms\":true,\"privacy\":true,\"marketing\":false") -> HubOnboardingGate.Decision {
            let r = Router(); r.on("GET /api/v1/me/onboarding", 200, state(step).replacingOccurrences(of: "\"terms\":false,\"privacy\":false,\"marketing\":false", with: flags))
            var out: HubOnboardingGate.Decision?
            HubOnboardingGate.check(endpoint: e, http: r, token: "T") { out = $0 }
            return out!
        }
        XCTAssertEqual(decide("done"), .proceed)
        XCTAssertEqual(decide("name"), .needsOnboarding)
        XCTAssertEqual(decide("loading"), .needsOnboarding)
        XCTAssertEqual(decide("phone_verify"), .needsOnboarding)
        XCTAssertEqual(decide("done", flags: "\"terms\":true,\"privacy\":false,\"marketing\":false"), .needsOnboarding)
    }

    func testGateLetsTheChatTryWhenTheServerCannotSay() {
        let r = Router(); r.on("GET /api/v1/me/onboarding", 500, "{}")
        var out: HubOnboardingGate.Decision?
        HubOnboardingGate.check(endpoint: e, http: r, token: "T") { out = $0 }
        XCTAssertEqual(out, .proceed)
        let r2 = Router(); r2.on("GET /api/v1/me/onboarding", 404, "{}")
        HubOnboardingGate.check(endpoint: e, http: r2, token: "T") { out = $0 }
        XCTAssertEqual(out, .proceed)
    }
}

/// 가입이 덜 끝났으면 대화 소켓·커넥터를 열지 않는다(PetSession).
final class PetSessionOnboardingGateTests: XCTestCase {
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    var http: PetStubHTTP!
    var factory: PetTransportFactory!
    var browser: PetFakeBrowser!
    var secrets: MemorySecretStore!

    override func setUp() {
        browser = PetFakeBrowser()
        secrets = MemorySecretStore()
        http = PetStubHTTP()
        factory = PetTransportFactory()
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        http.on("POST", "/api/v1/agents/\(agent)/connector-binding", 200, #"{"token":"nct_feed","endpoint":"/ws/connector"}"#)
    }

    private func session() -> PetSession {
        var s = PetSettings(); s.serverMode = .mock
        return PetSession(settings: s, http: http, secrets: secrets, browser: browser, makeTransport: factory.make,
                          executor: PetRecordingExecutor(), random: PetFixedRandom())
    }
    private func settle(_ s: PetSession) { for _ in 0..<6 { s.flush(); Thread.sleep(forTimeInterval: 0.01) } }
    private let incomplete = #"{"step":"birthday","stage":"profile","can_go_back":true,"account_status":"active","consent_flags":{"terms":false,"privacy":false,"marketing":false}}"#
    private let complete = #"{"step":"done","stage":"complete","can_go_back":false,"account_status":"active","consent_flags":{"terms":true,"privacy":true,"marketing":false}}"#

    func testNoChatSocketWhileSignUpIsUnfinished() {
        http.on("GET", "/api/v1/me/onboarding", 200, incomplete)
        let s = session()
        s.signIn(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        XCTAssertTrue(factory.with(path: "/ws/chat").isEmpty, "가입 전에는 대화 소켓을 열지 않는다")
        XCTAssertTrue(factory.with(path: "/ws/connector").isEmpty)
        XCTAssertTrue(s.snapshot.onboardingPending)
        XCTAssertEqual(s.snapshot.notice, "가입을 마치면 나초와 대화할 수 있어요. 나초 앱 창에서 이어 가 주세요.")
        s.open(); s.reconnect(); settle(s)
        XCTAssertTrue(factory.with(path: "/ws/chat").isEmpty, "다시 열어도 마찬가지")
    }

    func testFinishingSignUpConnectsTheChat() {
        http.on("GET", "/api/v1/me/onboarding", 200, incomplete)
        let s = session()
        s.signIn(); settle(s)
        XCTAssertTrue(factory.with(path: "/ws/chat").isEmpty)
        http.on("GET", "/api/v1/me/onboarding", 200, complete)
        s.onboardingFinished(); settle(s)
        XCTAssertFalse(s.snapshot.onboardingPending)
        XCTAssertEqual(factory.with(path: "/ws/chat").count, 1)
    }

    func testFinishedAccountsConnectAsBefore() {
        http.on("GET", "/api/v1/me/onboarding", 200, complete)
        let s = session()
        s.signIn(); settle(s)
        XCTAssertEqual(factory.with(path: "/ws/chat").count, 1)
        XCTAssertFalse(s.snapshot.onboardingPending)
    }
}
