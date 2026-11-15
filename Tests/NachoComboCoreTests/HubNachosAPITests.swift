import XCTest
@testable import NachoComboCore

/// 나초 섹션(NACHO-274 U8: F2·F3·F4·F5) Core. 요청은 바이트 단위로(메서드·경로·쿼리·본문·Idempotency-Key), 응답·오류는 한국어 문구까지.
final class HubNachosAPITests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private let A = "11111111-1111-1111-1111-111111111111"

    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, body: Data(json.utf8)) }
    private func obj(_ json: String) throws -> HubObject { try HubAPI.object(resp(200, json)).get() }

    // MARK: F4 요청 바이트

    func testListAndTemplates() {
        let l = HubNachosAPI.list(e, bearer: "T")
        XCTAssertEqual(l.method, "GET")
        XCTAssertEqual(l.url.absoluteString, "https://nacho.example.com/api/v1/agents")
        XCTAssertEqual(l.headers["Authorization"], "Bearer T")
        XCTAssertNil(l.body)
        XCTAssertEqual(HubNachosAPI.templates(e, bearer: "T").url.absoluteString, "https://nacho.example.com/api/v1/agent-templates")
    }

    func testCreateBodyAndIdempotency() {
        let r = HubNachosAPI.create(e, bearer: "T", name: "초코", voiceID: "nacho_default", speech: HubSpeech(honorific: "casual", tone: "calm"),
                                    roleNote: "일정 담당", templateID: "planner", idempotencyKey: "K1")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/agents")
        XCTAssertEqual(r.headers["Idempotency-Key"], "K1")
        XCTAssertEqual(body(r), "{\"idempotency_key\":\"K1\",\"name\":\"초코\",\"role_note\":\"일정 담당\",\"speech\":{\"honorific\":\"casual\",\"mimic\":false,\"tone\":\"calm\"},\"template_id\":\"planner\",\"voice_id\":\"nacho_default\"}")
        // 고르지 않은 칸은 보내지 않는다(서버 기본값).
        XCTAssertEqual(body(HubNachosAPI.create(e, bearer: "T", name: "초코", idempotencyKey: "K2")), "{\"idempotency_key\":\"K2\",\"name\":\"초코\"}")
    }

    func testStateChanges() {
        let d = HubNachosAPI.setDefault(e, bearer: "T", id: A)
        XCTAssertEqual(d.method, "POST")
        XCTAssertEqual(d.url.path, "/api/v1/agents/\(A)/default")
        XCTAssertEqual(body(d), "{}")
        let rest = HubNachosAPI.rest(e, bearer: "T", id: A, version: 4)
        XCTAssertEqual(rest.url.path, "/api/v1/agents/\(A)/rest")
        XCTAssertEqual(body(rest), "{\"expected_version\":4}")
        let wake = HubNachosAPI.wake(e, bearer: "T", id: A, version: 5)
        XCTAssertEqual(wake.url.path, "/api/v1/agents/\(A)/wake")
        XCTAssertEqual(body(wake), "{\"expected_version\":5}")
        let res = HubNachosAPI.restore(e, bearer: "T", id: A)
        XCTAssertEqual(res.method, "POST")
        XCTAssertEqual(res.url.path, "/api/v1/agents/\(A)/restore")
        XCTAssertEqual(body(res), "{}")
    }

    func testRemovalPreviewAndDelete() {
        let p = HubNachosAPI.removalPreview(e, bearer: "T", id: A)
        XCTAssertEqual(p.method, "GET")
        XCTAssertEqual(p.url.path, "/api/v1/agents/\(A)/removal-preview")
        let d = HubNachosAPI.remove(e, bearer: "T", id: A, version: 2, idempotencyKey: "K")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.absoluteString, "https://nacho.example.com/api/v1/agents/\(A)")
        XCTAssertEqual(d.headers["Idempotency-Key"], "K")
        XCTAssertEqual(body(d), "{\"expected_version\":2,\"idempotency_key\":\"K\",\"own_memory_policy\":\"delete\",\"schedule_policy\":\"handoff\",\"task_policy\":\"wait\"}")
    }

    func testLimitsOnlyChangedFields() {
        let r = HubNachosAPI.limits(e, bearer: "T", id: A, patch: HubLimitsPatch(memoryRead: "own_only", autoPayment: false), version: 3)
        XCTAssertEqual(r.method, "PUT")
        XCTAssertEqual(r.url.path, "/api/v1/agents/\(A)/limits")
        XCTAssertEqual(body(r), "{\"auto_payment\":false,\"expected_version\":3,\"memory_read\":\"own_only\"}")
    }

    // MARK: F2 프로필·목소리·특성

    func testProfilePatchAndVoices() {
        let r = HubNachosAPI.patch(e, bearer: "T", id: A, patch: HubAgentPatch(name: "새이름", phoneName: "", roleNote: ""), version: 7)
        XCTAssertEqual(r.method, "PATCH")
        XCTAssertEqual(r.url.path, "/api/v1/agents/\(A)")
        // 빈 문자열은 그대로 보낸다(전화 이름은 기본으로, 역할은 지움).
        XCTAssertEqual(body(r), "{\"expected_version\":7,\"name\":\"새이름\",\"phone_name\":\"\",\"role_note\":\"\"}")
        let s = HubNachosAPI.patch(e, bearer: "T", id: A, patch: HubAgentPatch(voiceID: "v2", speech: HubSpeech(honorific: "polite", tone: "crisp", mimic: true, addressAs: "대장")), version: 1)
        XCTAssertEqual(body(s), "{\"expected_version\":1,\"speech\":{\"address_as\":\"대장\",\"honorific\":\"polite\",\"mimic\":true,\"tone\":\"crisp\"},\"voice_id\":\"v2\"}")
        XCTAssertEqual(HubNachosAPI.get(e, bearer: "T", id: A).url.path, "/api/v1/agents/\(A)")
        XCTAssertEqual(HubNachosAPI.agentVoices(e, bearer: "T", id: A).url.path, "/api/v1/agents/\(A)/voices")
        XCTAssertEqual(HubNachosAPI.voices(e, bearer: "T").url.path, "/api/v1/voices")
    }

    func testTraitRequests() {
        XCTAssertEqual(HubNachosAPI.traits(e, bearer: "T", id: A).url.path, "/api/v1/agents/\(A)/traits")
        let r = HubNachosAPI.refreshTraits(e, bearer: "T", id: A)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/agents/\(A)/traits/refresh")
        let d = HubNachosAPI.hideTrait(e, bearer: "T", id: A, traitID: "tr1")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.path, "/api/v1/agents/\(A)/traits/tr1")
        XCTAssertNil(d.body)
    }

    // MARK: F3 사진

    func testPhotoRequests() {
        XCTAssertEqual(HubNachosAPI.photos(e, bearer: "T", id: A).url.path, "/api/v1/agents/\(A)/photos")
        let t = HubNachosAPI.takePhoto(e, bearer: "T", id: A, sceneID: "park", idempotencyKey: "K")
        XCTAssertEqual(t.method, "POST")
        XCTAssertEqual(t.url.path, "/api/v1/agents/\(A)/photos")
        XCTAssertEqual(t.headers["Idempotency-Key"], "K")
        XCTAssertEqual(body(t), "{\"idempotency_key\":\"K\",\"scene_id\":\"park\"}")
        XCTAssertEqual(HubNachosAPI.selectPhoto(e, bearer: "T", id: A, key: "k1").url.path, "/api/v1/agents/\(A)/photos/k1/select")
        let d = HubNachosAPI.deletePhoto(e, bearer: "T", id: A, key: "k1")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.path, "/api/v1/agents/\(A)/photos/k1")
        let c = HubNachosAPI.clearAvatar(e, bearer: "T", id: A)
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url.path, "/api/v1/agents/\(A)/avatar/clear")
    }

    func testPhotoCreditMessageShowsBalanceAndRemaining() {
        let m = HubPhotos.creditConfirmMessage(sceneLabel: "공원", remainingToday: 3, credits: 1200)
        XCTAssertTrue(m.contains("크레딧을 써요"), m)
        XCTAssertTrue(m.contains("오늘 3장"), m)
        XCTAssertTrue(m.contains("1,200"), m)
        XCTAssertFalse(HubPhotos.creditConfirmMessage(sceneLabel: "공원", remainingToday: 3, credits: nil).contains("남은 크레딧"))
    }

    // MARK: F5 상대 프로필

    func testUserProfileRequestAndDecode() throws {
        let r = HubNachosAPI.userProfile(e, bearer: "T", userID: "u1")
        XCTAssertEqual(r.url.path, "/api/v1/users/u1/profile")
        let p = try XCTUnwrap(HubUserProfile(obj("{\"user_id\":\"u1\",\"display_name\":\"민지\",\"handle\":\"minji\",\"relationship\":\"friend\",\"character_name\":\"초코\",\"character_look\":{\"flavor\":\"cheese\"},\"friend_days\":12,\"mutual_count\":2,\"deleted\":false}")))
        XCTAssertEqual(p.displayName, "민지")
        XCTAssertEqual(p.flavor, "cheese")
        XCTAssertEqual(p.relationshipLabel, "친구")
        XCTAssertEqual(p.friendDays, 12)
        XCTAssertNil(HubUserProfile(HubObject([:])))
    }

    // MARK: 응답 모델

    func testAgentListDecodeAndEmpty() throws {
        let json = "{\"agents\":[{\"id\":\"\(A)\",\"agent_id\":\"\(A)\",\"name\":\"나초\",\"status\":\"active\",\"is_default\":true,\"version\":3,\"voice_id\":\"v\",\"speech\":{\"honorific\":\"polite\",\"tone\":\"warm\",\"mimic\":false},\"look\":{\"flavor\":\"matcha\"},\"limits\":{\"memory_read\":\"own_only\",\"memory_write\":\"shared\",\"documents\":\"shared\",\"connections\":[],\"vault_cards\":false,\"auto_payment\":false},\"avatar\":{\"key\":\"k\",\"url\":\"https://x/a.png\",\"scene_id\":\"s\"},\"unread\":2,\"active_task_count\":1},{\"id\":\"b\",\"name\":\"쉬는이\",\"status\":\"resting\",\"is_default\":false,\"version\":1}],\"limits\":{\"max_agents\":3,\"used\":2,\"can_create\":true}}"
        let l = try XCTUnwrap(HubAgentList(obj(json)))
        XCTAssertEqual(l.agents.map { $0.name }, ["나초", "쉬는이"])
        XCTAssertTrue(l.agents[0].isDefault)
        XCTAssertEqual(l.agents[0].flavor, "matcha")
        XCTAssertEqual(l.agents[0].limits.memoryRead, "own_only")
        XCTAssertEqual(l.agents[0].avatarURL, "https://x/a.png")
        XCTAssertEqual(l.agents[1].statusLabel, "쉬는 중")
        XCTAssertEqual(l.maxAgents, 3)
        XCTAssertTrue(l.canCreate)
        let empty = try XCTUnwrap(HubAgentList(obj("{\"agents\":[],\"limits\":{\"max_agents\":1,\"used\":0,\"can_create\":false}}")))
        XCTAssertTrue(empty.agents.isEmpty)
        XCTAssertFalse(empty.canCreate)
        XCTAssertNil(try HubAgentList(obj("{\"nope\":1}")))
    }

    func testTemplateAndVoiceAndTraitDecode() throws {
        let t = try XCTUnwrap(HubAgentTemplate(obj("{\"template_id\":\"planner\",\"label\":\"일정 도우미\",\"role_note\":\"일정\",\"speech\":{\"honorific\":\"casual\",\"tone\":\"playful\",\"mimic\":false},\"suggested_limits\":{}}")))
        XCTAssertEqual(t.label, "일정 도우미")
        XCTAssertEqual(t.speech.label, "반말 · 장난스럽게")
        let v = try XCTUnwrap(HubVoice(obj("{\"voice_id\":\"v1\",\"name\":\"n\",\"label\":\"차분한 목소리\",\"description\":\"d\",\"sample_url\":\"https://nacho.example.com/static/voices/v1\"}")))
        XCTAssertEqual(v.label, "차분한 목소리")
        XCTAssertEqual(v.sampleURL?.absoluteString, "https://nacho.example.com/static/voices/v1")
        let tr = try XCTUnwrap(HubTrait(obj("{\"trait_id\":\"t1\",\"text\":\"산책을 좋아해요\",\"evidence\":\"자주 걸어요\"}")))
        XCTAssertEqual(tr.text, "산책을 좋아해요")
    }

    /// 목소리 미리 듣기는 서버가 준 https 주소만 재생한다. null·빈 값·http·file·javascript는 버린다.
    func testVoiceSampleOnlyServerHTTPS() throws {
        for bad in ["null", "\"\"", "\"http://x.example.com/a.m4a\"", "\"file:///etc/passwd\"", "\"javascript:alert(1)\"", "\"//x.example.com/a\"", "\"not a url\""] {
            let v = try XCTUnwrap(HubVoice(obj("{\"voice_id\":\"v\",\"sample_url\":\(bad)}")), bad)
            XCTAssertNil(v.sampleURL, bad)
        }
        XCTAssertNil(HubVoice(HubObject(["name": "x"])), "voice_id가 없으면 읽지 않는다")
    }

    func testPhotosDecodeBothShapes() throws {
        let photos = "{\"photos\":[{\"key\":\"k1\",\"agent_id\":\"a\",\"scene_id\":\"park\",\"url\":\"https://x/1.png\",\"in_use\":true},{\"key\":\"k2\",\"scene_id\":\"cafe\",\"url\":\"https://x/2.png\",\"in_use\":false}],\"current_key\":\"k1\",\"remaining_today\":4,\"scenes\":[{\"scene_id\":\"park\",\"label\":\"공원\"}]}"
        let p = try XCTUnwrap(HubPhotos(obj(photos)))
        XCTAssertEqual(p.photos.map { $0.key }, ["k1", "k2"])
        XCTAssertEqual(p.currentKey, "k1")
        XCTAssertEqual(p.remainingToday, 4)
        XCTAssertEqual(p.scenes.map { $0.label }, ["공원"])
        // POST /photos 응답은 {photos: AgentPhotos, photo}
        let created = try XCTUnwrap(HubPhotos(obj("{\"photos\":\(photos),\"photo\":{\"key\":\"k2\"}}")))
        XCTAssertEqual(created.photos.count, 2)
        XCTAssertNil(try HubPhotos(obj("{\"x\":1}")))
    }

    func testRemovalPreviewLines() throws {
        let json = "{\"agent_id\":\"a\",\"is_default\":false,\"can_delete\":true,\"active_tasks\":[{\"id\":\"t\",\"title\":\"보고서\",\"state\":\"running\",\"room_id\":\"r\"}],\"schedules\":[{\"title\":\"아침 알림\"}],\"pending_requests\":[{\"id\":\"q\"}],\"own_memories\":3,\"rooms\":[],\"restore_days\":14}"
        let p = try XCTUnwrap(HubRemovalPreview(obj(json)))
        XCTAssertTrue(p.canDelete)
        let all = p.lines.joined(separator: "\n")
        XCTAssertTrue(all.contains("보고서"), all)
        XCTAssertTrue(all.contains("아침 알림"), all)
        XCTAssertTrue(all.contains("카드 1장"), all)
        XCTAssertTrue(all.contains("기억 3개"), all)
        XCTAssertTrue(all.contains("14일"), all)
        let none = try XCTUnwrap(HubRemovalPreview(obj("{\"agent_id\":\"a\",\"is_default\":false,\"can_delete\":true,\"restore_days\":0}")))
        XCTAssertEqual(none.lines, ["함께 사라지는 일이 없어요."])
        let def = try XCTUnwrap(HubRemovalPreview(obj("{\"agent_id\":\"a\",\"is_default\":true,\"can_delete\":false}")))
        XCTAssertFalse(def.canDelete)
    }

    // MARK: 입력 검증

    func testNameValidation() {
        XCTAssertEqual(HubNachosValidation.name(""), "이름을 입력해 주세요.")
        XCTAssertEqual(HubNachosValidation.name("   "), "이름을 입력해 주세요.")
        XCTAssertNil(HubNachosValidation.name("나초"))
        XCTAssertNil(HubNachosValidation.name(String(repeating: "가", count: 20)))
        XCTAssertEqual(HubNachosValidation.name(String(repeating: "가", count: 21)), "이름은 20자까지 쓸 수 있어요.")
        XCTAssertEqual(HubNachosValidation.name("a@b"), "이름에는 @를 쓸 수 없어요.")
        XCTAssertEqual(HubNachosValidation.name("a\nb"), "이름에는 줄바꿈을 쓸 수 없어요.")
    }

    func testPhoneNameAndRoleNoteValidation() {
        XCTAssertNil(HubNachosValidation.phoneName(""), "비우면 기본 AI 비서")
        XCTAssertNil(HubNachosValidation.phoneName("초코"))
        XCTAssertEqual(HubNachosValidation.phoneName("12345"), "전화 이름은 숫자만으로 정할 수 없어요.")
        XCTAssertEqual(HubNachosValidation.phoneName(String(repeating: "가", count: 13)), "전화 이름은 12자까지 쓸 수 있어요.")
        XCTAssertNil(HubNachosValidation.roleNote(String(repeating: "가", count: 80)))
        XCTAssertEqual(HubNachosValidation.roleNote(String(repeating: "가", count: 81)), "역할은 80자까지 쓸 수 있어요.")
    }

    // MARK: 응답·오류 (정상·빈 목록·401·404·409·서버 오류 → 한국어)

    final class FakeHTTP: PetHTTPClient {
        var sent: [PetHTTPRequest] = []
        var answers: [PetHTTPResponse]
        init(_ a: [PetHTTPResponse]) { answers = a }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            sent.append(request)
            completion(.success(answers.removeFirst()))
        }
    }

    private func fail(_ status: Int, _ json: String, request: @escaping (String?) -> PetHTTPRequest) -> PetAPIError? {
        let http = FakeHTTP([resp(status, json)] + (status == 401 ? [resp(status, json)] : []))
        let client = HubClient(endpoint: e, http: http, tokens: { _, done in done("T") })
        var out: PetAPIError?
        client.send(request) { if case let .failure(err) = $0 { out = err } }
        return out
    }

    func testErrorsAreKorean() {
        let get: (String?) -> PetHTTPRequest = { HubNachosAPI.list(self.e, bearer: $0) }
        XCTAssertEqual(fail(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}", request: get)?.text, "로그인이 필요해요.")
        let e404 = fail(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}", request: get)
        XCTAssertEqual(e404?.isNotFound, true)
        let e409 = fail(409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"}}", request: { HubNachosAPI.rest(self.e, bearer: $0, id: self.A, version: 1) })
        XCTAssertEqual(e409?.isVersionConflict, true)
        XCTAssertEqual(e409.map(HubNachosText.message), "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요.")
        XCTAssertEqual(fail(500, "boom", request: get)?.text, "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        XCTAssertEqual(fail(409, "{\"error\":{\"code\":\"duplicate_name\",\"message\":\"x\",\"reason\":\"name\"}}", request: get).map(HubNachosText.message), "같은 이름의 나초가 이미 있어요.")
        XCTAssertEqual(fail(400, "{\"error\":{\"code\":\"blocked_word\",\"message\":\"x\",\"reason\":\"name\"}}", request: get).map(HubNachosText.message), "쓸 수 없는 말이 들어 있어요.")
        XCTAssertEqual(fail(403, "{\"error\":{\"code\":\"default_agent\",\"message\":\"x\"}}", request: get).map(HubNachosText.message), "대표 나초에는 할 수 없어요. 다른 나초를 대표로 정한 뒤 해 주세요.")
        XCTAssertEqual(fail(409, "{\"error\":{\"code\":\"last_agent\",\"message\":\"x\"}}", request: get).map(HubNachosText.message), "마지막 나초는 지울 수 없어요.")
        XCTAssertEqual(fail(402, "{\"error\":{\"code\":\"agent_limit\",\"message\":\"x\"}}", request: get).map(HubNachosText.message), "만들 수 있는 나초 수를 넘었어요.")
        // 서버 영어 message는 보이지 않는다.
        XCTAssertFalse((fail(409, "{\"error\":{\"code\":\"duplicate_name\",\"message\":\"english text\"}}", request: get).map(HubNachosText.message) ?? "").contains("english"))
        // 사진 한도(429)는 다시 가능한 시각을 한국어로.
        let e429 = fail(429, "{\"error\":{\"code\":\"too_many_requests\",\"message\":\"x\",\"reason\":\"2026-11-20T01:00:00Z\"}}", request: get)
        XCTAssertTrue(e429.map(HubNachosText.message)?.hasPrefix("잠시 너무 많이 요청했어요.") == true)
    }
}
