import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 친구·공유 섹션(NACHO-274 U8: G1·G4·G5, F5). macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 데이터는 모두 가짜다.
final class HubFriendsCaptureTests: XCTestCase {
    private let U1 = "aaaaaaaa-0000-0000-0000-000000000001"
    private let U2 = "aaaaaaaa-0000-0000-0000-000000000002"
    private let U3 = "aaaaaaaa-0000-0000-0000-000000000003"

    private var summaryJSON: String {
        "{\"friends\":[{\"user_id\":\"\(U1)\",\"display_name\":\"민지\",\"handle\":\"minji_1\",\"character_look\":{\"flavor\":\"cheese\"}}],"
            + "\"requests_in\":[{\"user_id\":\"\(U2)\",\"display_name\":\"철수\",\"handle\":\"chulsu\",\"received_at_ms\":1,\"unseen\":true}],"
            + "\"blocked\":[{\"user_id\":\"\(U3)\",\"display_name\":\"차단한사람\",\"handle\":\"blocked_one\"}],\"friend_suggestions\":[],\"birthday_friends\":[],\"invites_total\":5,\"invites_used\":2}"
    }

    private func profileJSON(_ rel: String) -> String {
        "{\"user_id\":\"\(U1)\",\"display_name\":\"민지\",\"handle\":\"minji_1\",\"relationship\":\"\(rel)\",\"character_name\":\"초코\",\"deleted\":false,\"chat_state\":\"allowed\",\"character_chat\":\"ok\",\"friend_days\":12,\"conversations\":[],\"active_agreement\":null,\"mutual_count\":2,\"mutual_names\":[]}"
    }

    private let inviteJSON = "{\"invite_only\":true,\"invite_url\":\"https://nacho.example.com/i/123456\",\"invite_code\":\"123456\",\"total\":5,\"used\":2,\"signups\":[{\"user_id\":\"aaaaaaaa-0000-0000-0000-000000000009\",\"display_name\":\"영희\",\"handle\":\"younghee\",\"joined_at\":\"2026-11-01T00:00:00Z\",\"dismissed\":false}],\"rewards\":[]}"

    private let sharingJSON = "{\"share_friends\":\"everyday\",\"share_strangers\":\"public_profile\",\"share_plans_free_only\":true,\"share_birthday_month_day\":false,\"stranger_chat_enabled\":true,\"exclusions\":\"병원 이야기\",\"exclusions_version\":4,\"exclusions_max\":2000,\"person_note_max\":500,\"sensitive_categories\":[\"건강\",\"종교\"],\"people\":[{\"user_id\":\"aaaaaaaa-0000-0000-0000-000000000001\",\"display_name\":\"민지\",\"person_note_preview\":\"생일을 먼저 말하지 마세요\"}],\"connections\":[],\"connections_shared_count\":0,\"default_agent\":null}"

    private func kit(_ extra: [String: (Int, String)] = [:]) -> HubSectionTestKit {
        var routes: [String: (Int, String)] = ["GET /api/v1/social/summary": (200, summaryJSON)]
        for (k, v) in extra { routes[k] = v }
        return HubSectionTestKit(routes)
    }

    private func open(_ k: HubSectionTestKit) -> FriendsSection {
        let s = FriendsSection()
        k.activate(s)
        return s
    }

    private func person(_ id: String, _ name: String, _ rel: String = "none") -> HubPerson {
        HubPerson(HubObject(["user_id": id, "display_name": name, "handle": "h_\(name.count)", "relationship": rel]))!
    }

    // MARK: G1 목록·요청·차단

    func testFriendsListRequestsAndBlocked() throws {
        let k = kit()
        let s = open(k)
        XCTAssertEqual(k.http.lines, ["GET /api/v1/social/summary"])
        var all = HubSectionTestKit.joined(s.view)
        for t in ["민지", "@minji_1", "친구 추가", "받은 요청 1", "차단", "초대", "공유"] { XCTAssertTrue(all.contains(t), "\(t)\n\(all)") }
        try HubSectionTestKit.capture(s, name: "friends-list", in: self)
        s.go(.requests)
        all = HubSectionTestKit.joined(s.view)
        XCTAssertTrue(all.contains("철수") && all.contains("수락") && all.contains("거절"), all)
        try HubSectionTestKit.capture(s, name: "friends-requests", in: self)
        s.go(.blocked)
        XCTAssertTrue(HubSectionTestKit.joined(s.view).contains("차단 풀기"))
    }

    func testEmptySummaryAndServerError() {
        let empty = kit(["GET /api/v1/social/summary": (200, "{\"friends\":[],\"requests_in\":[],\"blocked\":[]}")])
        let all = HubSectionTestKit.joined(open(empty).view)
        XCTAssertTrue(all.contains("아직 친구가 없어요."), all)
        let bad = kit(["GET /api/v1/social/summary": (500, "boom")])
        XCTAssertTrue(HubSectionTestKit.joined(open(bad).view).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
    }

    func testAcceptDeclineSendRequests() throws {
        let k = kit(["POST /api/v1/social/friend-requests/\(U2)/accept": (200, "{\"ok\":true,\"relationship\":\"friend\"}"),
                     "POST /api/v1/social/friend-requests/\(U2)/decline": (200, "{\"ok\":true,\"relationship\":\"none\"}"),
                     "POST /api/v1/social/friend-requests": (200, "{\"ok\":true,\"relationship\":\"outgoing_request\"}")])
        let s = open(k)
        s.answer(person(U2, "철수", "incoming_request"), action: "accept", done: "친구가 됐어요.", next: .friends)
        XCTAssertEqual(k.http.count("POST /api/v1/social/friend-requests/\(U2)/accept"), 1)
        XCTAssertEqual(k.http.count("GET /api/v1/social/summary"), 2, "관계가 바뀌면 요약을 다시 받는다")
        s.answer(person(U2, "철수", "incoming_request"), action: "decline", done: "거절했어요.", next: .friends)
        XCTAssertEqual(k.http.count("POST /api/v1/social/friend-requests/\(U2)/decline"), 1)
        s.sendRequest(person(U3, "새친구"), next: .friends)
        XCTAssertEqual(k.http.sent.last { $0.path == "/api/v1/social/friend-requests" }?.body, "{\"user_id\":\"\(U3)\"}")
    }

    /// 삭제·차단·해제는 확인창을 두 번 거치고, 거절하면 요청이 0건이다.
    func testRemoveBlockUnblockNeedTwoConfirms() throws {
        let k = kit(["DELETE /api/v1/social/friends/\(U1)": (200, "{\"ok\":true,\"relationship\":\"none\"}"),
                     "POST /api/v1/social/blocks": (200, "{\"ok\":true,\"relationship\":\"blocked\"}"),
                     "DELETE /api/v1/social/blocks/\(U3)": (200, "{\"ok\":true,\"relationship\":\"none\"}")])
        let s = open(k)
        let friend = person(U1, "민지", "friend"), blocked = person(U3, "차단한사람", "blocked")
        k.confirms.accept = false
        s.requestRemoveFriend(friend)
        s.requestBlock(friend)
        s.requestUnblock(blocked)
        XCTAssertEqual(k.confirms.steps.map { $0.count }, [2, 2, 2])
        XCTAssertEqual(k.http.count("DELETE /api/v1/social/friends/\(U1)") + k.http.count("POST /api/v1/social/blocks") + k.http.count("DELETE /api/v1/social/blocks/\(U3)"), 0,
                       "확인하지 않으면 요청이 0건")
        try HubSectionTestKit.captureCard(k.confirms.steps[1][0], name: "friends-block-confirm1", in: self)
        try HubSectionTestKit.captureCard(k.confirms.steps[1][1], name: "friends-block-confirm2", in: self)
        k.confirms.accept = true
        s.requestRemoveFriend(friend)
        s.requestBlock(friend)
        s.requestUnblock(blocked)
        XCTAssertEqual(k.http.count("DELETE /api/v1/social/friends/\(U1)"), 1)
        XCTAssertEqual(k.http.sent.last { $0.path == "/api/v1/social/blocks" }?.body, "{\"user_id\":\"\(U1)\"}")
        XCTAssertEqual(k.http.count("DELETE /api/v1/social/blocks/\(U3)"), 1)
    }

    // MARK: 사용자 ID 검색 검증

    func testLookupValidatesHandleBeforeAnyRequest() throws {
        let k = kit(["GET /api/v1/users/lookup": (200, "{\"hit\":{\"user_id\":\"\(U2)\",\"display_name\":\"철수\",\"handle\":\"chulsu\",\"relationship\":\"none\"}}")])
        let s = open(k)
        s.openAdd()
        for (bad, message) in [("", "찾을 사용자 ID를 입력해 주세요."), ("ab", "사용자 ID는 3자 이상이에요. (영어 소문자, 숫자, 밑줄)"),
                               ("민지민지", "사용자 ID는 영어 소문자, 숫자, 밑줄만 쓸 수 있어요."), ("01012345678", "전화번호로 찾는 것은 휴대폰의 나초 앱에서 해 주세요.")] {
            let f = HubFormField(title: "사용자 ID", validator: { HubFriendsValidation.handle($0) })
            f.field.stringValue = bad
            s.lookup(f)
            XCTAssertTrue(HubSectionTestKit.joined(f).contains(message), "\(bad): \(HubSectionTestKit.joined(f))")
        }
        XCTAssertEqual(k.http.count("GET /api/v1/users/lookup"), 0, "검증을 못 넘으면 요청이 0건")
        let ok = HubFormField(title: "사용자 ID", validator: { HubFriendsValidation.handle($0) })
        ok.field.stringValue = "@Chulsu"
        s.lookup(ok)
        XCTAssertEqual(k.http.sent.last?.path, "/api/v1/users/lookup")
        XCTAssertEqual(s.lookupHit?.displayName, "철수")
        let all = HubSectionTestKit.joined(s.view)
        XCTAssertTrue(all.contains("친구 요청 보내기"), all)
        try HubSectionTestKit.capture(s, name: "friends-add", in: self)
    }

    func testLookupNotFoundShowsKoreanUnderField() {
        let k = kit(["GET /api/v1/users/lookup": (404, "{\"error\":{\"code\":\"not_found\",\"message\":\"english\"}}")])
        let s = open(k)
        s.openAdd()
        let f = HubFormField(title: "사용자 ID", validator: { HubFriendsValidation.handle($0) })
        f.field.stringValue = "nobody"
        s.lookup(f)
        let t = HubSectionTestKit.joined(f)
        XCTAssertTrue(t.contains("찾을 수 없어요."), t)
        XCTAssertFalse(t.contains("english"))
    }

    // MARK: F5 상대 프로필

    func testProfileShowsRelationshipActions() throws {
        let k = kit(["GET /api/v1/users/\(U1)/profile": (200, profileJSON("friend"))])
        let s = open(k)
        s.go(.profile(U1))
        XCTAssertEqual(k.http.lines.last, "GET /api/v1/users/\(U1)/profile")
        let all = HubSectionTestKit.joined(s.view)
        for t in ["민지", "@minji_1", "친구", "대표 나초", "초코", "12일", "함께 아는 친구", "친구 지우기", "차단", "이 친구에게 당부 적기"] { XCTAssertTrue(all.contains(t), "\(t)\n\(all)") }
        try HubSectionTestKit.capture(s, name: "friends-profile", in: self)
        k.routes["GET /api/v1/users/\(U1)/profile"] = (200, profileJSON("none"))
        s.go(.profile(U1))
        XCTAssertTrue(HubSectionTestKit.joined(s.view).contains("친구 요청 보내기"))
        k.routes["GET /api/v1/users/\(U1)/profile"] = (404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")
        s.go(.profile(U1))
        XCTAssertTrue(HubSectionTestKit.joined(s.view).contains("찾을 수 없어요."))
    }

    // MARK: G4 초대 — 복사만

    func testInviteCopiesOnlyAndNeverSends() throws {
        let k = kit(["GET /api/v1/me/invites": (200, inviteJSON), "POST /api/v1/social/invites/aaaaaaaa-0000-0000-0000-000000000009/dismiss": (200, "{\"ok\":true}"),
                     "POST /api/v1/me/onboarding/invite/redeem": (200, "{}")])
        let s = open(k)
        var copied: [String] = []
        s.copyToClipboard = { copied.append($0) }
        s.go(.invite)
        let all = HubSectionTestKit.joined(s.view)
        for t in ["초대장이 3장 남았어요.", "123456", "링크 복사", "코드 복사", "링크는 복사만 해요.", "영희"] { XCTAssertTrue(all.contains(t), "\(t)\n\(all)") }
        try HubSectionTestKit.capture(s, name: "friends-invite", in: self)
        s.copyInviteLink()
        s.copyInviteCode()
        XCTAssertEqual(copied, ["https://nacho.example.com/i/123456", "123456"])
        XCTAssertTrue(k.toasts.contains { $0.0 == "초대 링크를 복사했어요." })
        XCTAssertEqual(k.http.sent.filter { $0.method != "GET" }.count, 0, "복사는 서버로 아무것도 보내지 않는다")
        let badCode = HubFormField(title: "코드", validator: { HubFriendsValidation.inviteCode($0) })
        badCode.field.stringValue = "12ab"
        s.redeem(badCode)
        XCTAssertEqual(k.http.count("POST /api/v1/me/onboarding/invite/redeem"), 0)
        badCode.field.stringValue = "654321"
        s.redeem(badCode)
        XCTAssertEqual(k.http.sent.last?.body, "{\"code\":\"654321\"}")
        s.dismissSignup(person("aaaaaaaa-0000-0000-0000-000000000009", "영희"))
        XCTAssertEqual(k.http.count("POST /api/v1/social/invites/aaaaaaaa-0000-0000-0000-000000000009/dismiss"), 1)
    }

    func testInviteWithNoRemainingBlocksLinks() {
        let none = "{\"invite_only\":true,\"invite_url\":\"https://nacho.example.com/i/123456\",\"invite_code\":\"123456\",\"total\":2,\"used\":2,\"signups\":[],\"rewards\":[]}"
        let k = kit(["GET /api/v1/me/invites": (200, none)])
        let s = open(k)
        s.go(.invite)
        let all = HubSectionTestKit.joined(s.view)
        XCTAssertTrue(all.contains("남은 초대장이 없어서"), all)
        XCTAssertFalse(all.contains("링크 복사"), all)
    }

    // MARK: G5 공유

    func testSharingTogglesAndExclusions() throws {
        let k = kit(["GET /api/v1/sharing": (200, sharingJSON), "PATCH /api/v1/sharing": (200, sharingJSON), "PUT /api/v1/sharing/exclusions": (200, "{\"ok\":true,\"value\":{\"exclusions\":\"a\",\"exclusions_version\":5}}")])
        let s = open(k)
        s.go(.sharing)
        let all = HubSectionTestKit.joined(s.view)
        for t in ["친구의 나초와 일상 대화까지", "일정은 되는지만 말하기", "생일은 월·일만 말하기", "말하지 않을 내용", "건강, 종교", "민지"] { XCTAssertTrue(all.contains(t), "\(t)\n\(all)") }
        try HubSectionTestKit.capture(s, name: "friends-sharing", in: self)
        s.patchSharing(HubSharingPatch(shareFriends: "checkin"))
        XCTAssertEqual(k.http.sent.last { $0.method == "PATCH" }?.body, "{\"share_friends\":\"checkin\"}")
        let ex = HubFormField(title: "x", validator: { HubSharingValidation.text($0, max: 5, name: "내용") })
        ex.field.stringValue = "여섯글자넘어요"
        s.saveExclusions(ex, version: 4)
        XCTAssertEqual(k.http.count("PUT /api/v1/sharing/exclusions"), 0, "길이를 넘으면 요청이 0건")
        ex.field.stringValue = "병원"
        s.saveExclusions(ex, version: 4)
        XCTAssertEqual(k.http.sent.last { $0.method == "PUT" }?.body, "{\"expected_version\":4,\"text\":\"병원\"}")
    }

    func testExclusionsVersionConflictReloads() {
        let k = kit(["GET /api/v1/sharing": (200, sharingJSON), "PUT /api/v1/sharing/exclusions": (409, "{\"error\":{\"code\":\"version_conflict\",\"message\":\"x\"},\"value\":{\"exclusions\":\"서버\",\"exclusions_version\":9}}")])
        let s = open(k)
        s.go(.sharing)
        let ex = HubFormField(title: "x")
        ex.field.stringValue = "내 글"
        s.saveExclusions(ex, version: 4)
        XCTAssertTrue(k.toasts.contains { $0.1 && $0.0 == "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요." }, "\(k.toasts)")
        XCTAssertEqual(k.http.count("GET /api/v1/sharing"), 2, "새로 불러온다")
    }

    func testPersonNoteLoadAndSave() throws {
        let note = "{\"user_id\":\"\(U1)\",\"display_name\":\"민지\",\"person_note\":\"조심\",\"pair_room_id\":null,\"version\":2}"
        let k = kit(["GET /api/v1/sharing": (200, sharingJSON), "GET /api/v1/sharing/people/\(U1)": (200, note), "PUT /api/v1/sharing/people/\(U1)": (200, "{\"ok\":true,\"value\":\(note)}")])
        let s = open(k)
        s.go(.sharing)
        s.go(.person(U1))
        XCTAssertTrue(HubSectionTestKit.joined(s.view).contains("민지님께 당부"))
        let n = HubPersonNote(HubObject(["user_id": U1, "display_name": "민지", "person_note": "조심", "version": 2]))!
        let f = HubFormField(title: "당부", validator: { HubSharingValidation.text($0, max: 500, name: "당부") })
        f.field.stringValue = "새 당부"
        s.savePerson(n, field: f)
        XCTAssertEqual(k.http.sent.last { $0.method == "PUT" }?.body, "{\"expected_version\":2,\"person_note\":\"새 당부\"}")
        let long = HubFormField(title: "당부", validator: { HubSharingValidation.text($0, max: 3, name: "당부") })
        long.field.stringValue = "너무 긴 당부"
        let before = k.http.count("PUT /api/v1/sharing/people/\(U1)")
        s.savePerson(n, field: long)
        XCTAssertEqual(k.http.count("PUT /api/v1/sharing/people/\(U1)"), before, "길이를 넘으면 요청이 0건")
    }
}
