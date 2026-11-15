import XCTest
@testable import NachoComboCore

/// 친구·공유 섹션(NACHO-274 U8: G1·G4·G5) Core. 요청 바이트·응답 모델·입력 검증.
final class HubFriendsAPITests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, body: Data(json.utf8)) }
    private func obj(_ json: String) throws -> HubObject { try HubAPI.object(resp(200, json)).get() }

    // MARK: G1

    func testSummaryAndLookup() {
        let s = HubFriendsAPI.summary(e, bearer: "T")
        XCTAssertEqual(s.method, "GET")
        XCTAssertEqual(s.url.absoluteString, "https://nacho.example.com/api/v1/social/summary")
        let l = HubFriendsAPI.lookup(e, bearer: "T", handle: "minji_1")
        XCTAssertEqual(l.method, "GET")
        XCTAssertEqual(l.url.absoluteString, "https://nacho.example.com/api/v1/users/lookup?query=minji_1")
        XCTAssertNil(l.body)
    }

    func testFriendRequestRoutes() {
        let r = HubFriendsAPI.sendRequest(e, bearer: "T", userID: "u1")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/social/friend-requests")
        XCTAssertEqual(body(r), "{\"user_id\":\"u1\"}")
        for action in ["accept", "decline", "cancel"] {
            let a = HubFriendsAPI.answerRequest(e, bearer: "T", userID: "u1", action: action)
            XCTAssertEqual(a.method, "POST")
            XCTAssertEqual(a.url.path, "/api/v1/social/friend-requests/u1/\(action)")
            XCTAssertEqual(body(a), "{}")
        }
        let d = HubFriendsAPI.removeFriend(e, bearer: "T", userID: "u1")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.path, "/api/v1/social/friends/u1")
        XCTAssertNil(d.body)
    }

    func testBlockAndUnblock() {
        let b = HubFriendsAPI.block(e, bearer: "T", userID: "u1")
        XCTAssertEqual(b.method, "POST")
        XCTAssertEqual(b.url.path, "/api/v1/social/blocks")
        XCTAssertEqual(body(b), "{\"user_id\":\"u1\"}")
        let u = HubFriendsAPI.unblock(e, bearer: "T", userID: "u1")
        XCTAssertEqual(u.method, "DELETE")
        XCTAssertEqual(u.url.path, "/api/v1/social/blocks/u1")
        XCTAssertNil(u.body)
    }

    func testSummaryDecodeAndEmpty() throws {
        let json = "{\"friends\":[{\"user_id\":\"u1\",\"display_name\":\"민지\",\"handle\":\"minji\",\"character_look\":{\"flavor\":\"cheese\"}}],\"requests_in\":[{\"user_id\":\"u2\",\"display_name\":\"철수\",\"received_at_ms\":1,\"unseen\":true}],\"blocked\":[{\"user_id\":\"u3\",\"display_name\":\"차단\"}],\"friend_suggestions\":[],\"birthday_friends\":[],\"invites_total\":3,\"invites_used\":1}"
        let s = try XCTUnwrap(HubSocialSummary(obj(json)))
        XCTAssertEqual(s.friends.map { $0.displayName }, ["민지"])
        XCTAssertEqual(s.friends[0].handleText, "@minji")
        XCTAssertEqual(s.friends[0].flavor, "cheese")
        XCTAssertTrue(s.requestsIn[0].unseen)
        XCTAssertEqual(s.blocked.count, 1)
        let empty = try XCTUnwrap(HubSocialSummary(obj("{\"friends\":[],\"requests_in\":[],\"blocked\":[]}")))
        XCTAssertTrue(empty.friends.isEmpty && empty.requestsIn.isEmpty && empty.blocked.isEmpty)
        XCTAssertNil(try HubSocialSummary(obj("{\"x\":1}")))
    }

    // MARK: 사용자 ID 검증

    func testHandleValidation() {
        XCTAssertNil(HubFriendsValidation.handle("minji_1"))
        XCTAssertNil(HubFriendsValidation.handle("@MinJi"), "@와 대문자는 고쳐 준다")
        XCTAssertEqual(HubFriendsValidation.normalizeHandle("  @MinJi "), "minji")
        XCTAssertEqual(HubFriendsValidation.handle(""), "찾을 사용자 ID를 입력해 주세요.")
        XCTAssertEqual(HubFriendsValidation.handle("@"), "찾을 사용자 ID를 입력해 주세요.")
        XCTAssertEqual(HubFriendsValidation.handle("ab"), "사용자 ID는 3자 이상이에요. (영어 소문자, 숫자, 밑줄)")
        XCTAssertEqual(HubFriendsValidation.handle(String(repeating: "a", count: 21)), "사용자 ID는 20자까지예요.")
        XCTAssertEqual(HubFriendsValidation.handle("민지민지"), "사용자 ID는 영어 소문자, 숫자, 밑줄만 쓸 수 있어요.")
        XCTAssertEqual(HubFriendsValidation.handle("a b c"), "사용자 ID는 영어 소문자, 숫자, 밑줄만 쓸 수 있어요.")
        XCTAssertEqual(HubFriendsValidation.handle("01012345678"), "전화번호로 찾는 것은 휴대폰의 나초 앱에서 해 주세요.")
        XCTAssertEqual(HubFriendsValidation.handle("+82 10-1234-5678"), "전화번호로 찾는 것은 휴대폰의 나초 앱에서 해 주세요.")
    }

    func testInviteCodeValidation() {
        XCTAssertNil(HubFriendsValidation.inviteCode("123456"))
        XCTAssertNotNil(HubFriendsValidation.inviteCode("12345"))
        XCTAssertNotNil(HubFriendsValidation.inviteCode("12345a"))
        XCTAssertNotNil(HubFriendsValidation.inviteCode(""))
    }

    // MARK: G4

    func testInviteRequests() {
        let i = HubFriendsAPI.invites(e, bearer: "T")
        XCTAssertEqual(i.method, "GET")
        XCTAssertEqual(i.url.path, "/api/v1/me/invites")
        let d = HubFriendsAPI.dismissInvite(e, bearer: "T", userID: "u1")
        XCTAssertEqual(d.method, "POST")
        XCTAssertEqual(d.url.path, "/api/v1/social/invites/u1/dismiss")
        let r = HubFriendsAPI.redeem(e, bearer: "T", code: "123456")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/me/onboarding/invite/redeem")
        XCTAssertEqual(body(r), "{\"code\":\"123456\"}")
        XCTAssertEqual(HubFriendsAPI.landingPath(code: "123456"), "/i/123456")
    }

    func testInviteInfoDecodeAndCopyOnlyHTTPS() throws {
        let json = "{\"invite_only\":true,\"invite_url\":\"https://nacho.example.com/i/123456\",\"invite_code\":\"123456\",\"total\":5,\"used\":2,\"signups\":[{\"user_id\":\"u1\",\"display_name\":\"민지\",\"joined_at\":\"2026-11-01T00:00:00Z\",\"dismissed\":false}],\"rewards\":[]}"
        let i = try XCTUnwrap(HubInviteInfo(obj(json)))
        XCTAssertEqual(i.code, "123456")
        XCTAssertEqual(i.remaining, 3)
        XCTAssertEqual(i.signups.map { $0.person.displayName }, ["민지"])
        XCTAssertEqual(i.copyableURL, "https://nacho.example.com/i/123456")
        let bad = try XCTUnwrap(HubInviteInfo(obj("{\"invite_url\":\"javascript:1\",\"invite_code\":\"1\",\"total\":0,\"used\":0,\"signups\":[]}")))
        XCTAssertNil(bad.copyableURL)
        XCTAssertEqual(bad.remaining, 0)
    }

    // MARK: G5

    func testSharingRequests() {
        XCTAssertEqual(HubFriendsAPI.sharing(e, bearer: "T").url.path, "/api/v1/sharing")
        let p = HubFriendsAPI.patchSharing(e, bearer: "T", patch: HubSharingPatch(shareFriends: "checkin", birthdayMonthDay: true))
        XCTAssertEqual(p.method, "PATCH")
        XCTAssertEqual(p.url.path, "/api/v1/sharing")
        XCTAssertEqual(body(p), "{\"share_birthday_month_day\":true,\"share_friends\":\"checkin\"}")
        let x = HubFriendsAPI.putExclusions(e, bearer: "T", text: "병원 이야기", version: 3)
        XCTAssertEqual(x.method, "PUT")
        XCTAssertEqual(x.url.path, "/api/v1/sharing/exclusions")
        XCTAssertEqual(body(x), "{\"expected_version\":3,\"text\":\"병원 이야기\"}")
        XCTAssertEqual(HubFriendsAPI.person(e, bearer: "T", userID: "u1").url.path, "/api/v1/sharing/people/u1")
        let n = HubFriendsAPI.putPerson(e, bearer: "T", userID: "u1", note: "조심", version: 0)
        XCTAssertEqual(n.method, "PUT")
        XCTAssertEqual(n.url.path, "/api/v1/sharing/people/u1")
        XCTAssertEqual(body(n), "{\"expected_version\":0,\"person_note\":\"조심\"}")
    }

    func testSharingDecode() throws {
        let json = "{\"share_friends\":\"everyday\",\"share_strangers\":\"public_profile\",\"share_plans_free_only\":true,\"share_birthday_month_day\":false,\"stranger_chat_enabled\":false,\"exclusions\":\"병원\",\"exclusions_version\":4,\"exclusions_max\":2000,\"person_note_max\":500,\"sensitive_categories\":[\"건강\"],\"people\":[{\"user_id\":\"u1\",\"display_name\":\"민지\",\"person_note_preview\":\"조심\"}],\"connections\":[],\"connections_shared_count\":0,\"default_agent\":null}"
        let s = try XCTUnwrap(HubSharing(obj(json)))
        XCTAssertEqual(s.shareFriends, "everyday")
        XCTAssertTrue(s.plansFreeOnly)
        XCTAssertFalse(s.strangerChatEnabled)
        XCTAssertEqual(s.exclusionsVersion, 4)
        XCTAssertEqual(s.people.first?.note, "조심")
        XCTAssertEqual(s.sensitive, ["건강"])
        let n = try XCTUnwrap(HubPersonNote(obj("{\"user_id\":\"u1\",\"display_name\":\"민지\",\"person_note\":\"\",\"pair_room_id\":null,\"version\":0}")))
        XCTAssertEqual(n.version, 0)
        XCTAssertEqual(HubSharingValidation.text(String(repeating: "가", count: 11), max: 10, name: "당부"), "당부은(는) 10자까지 쓸 수 있어요.")
        XCTAssertNil(HubSharingValidation.text("가", max: 10, name: "당부"))
    }

    // MARK: 오류

    func testFriendErrorsAreKorean() {
        func err(_ status: Int, _ code: String) -> PetAPIError { HubAPI.error(PetHTTPResponse(status: status, body: Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"english\"}}".utf8))) }
        XCTAssertEqual(HubFriendsText.message(err(404, "not_found")), "찾을 수 없어요.")
        XCTAssertEqual(HubFriendsText.message(err(429, "limit_exceeded")), "친구 요청을 너무 많이 보냈어요. 내일 다시 해 주세요.")
        XCTAssertEqual(HubFriendsText.message(err(409, "version_conflict")), "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요.")
        XCTAssertEqual(HubFriendsText.message(err(500, "internal_error")), "일시적인 문제가 생겼어요. 다시 시도해 주세요.")
        XCTAssertEqual(HubFriendsText.message(err(401, "unauthorized")), "로그인이 필요해요.")
    }
}
