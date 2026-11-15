import Foundation

// 친구·공유 섹션(NACHO-274 U8: G1·G4·G5)의 요청 만들기·응답 모델. 경로·필드는 nacho-server `spec/social.tsp`·`sharing.tsp`·`onboarding.tsp`와 같다.
// G2 연락처·G3 전화 인증은 모바일 전용이라 없다. 초대 링크는 클립보드 복사만 한다(문자·메일 발송 없음).

public enum HubFriendsAPI {
    // MARK: G1 친구

    public static func summary(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/social/summary", bearer: bearer)
    }

    public static func lookup(_ e: ServerEndpoint, bearer: String?, handle: String) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/users/lookup", query: [("query", handle)], bearer: bearer)
    }

    public static func sendRequest(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/social/friend-requests", bearer: bearer, json: ["user_id": userID])
    }

    /// `action`: accept | decline | cancel
    public static func answerRequest(_ e: ServerEndpoint, bearer: String?, userID: String, action: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/social/friend-requests/\(userID)/\(action)", bearer: bearer)
    }

    public static func removeFriend(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/social/friends/\(userID)", bearer: bearer)
    }

    public static func block(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/social/blocks", bearer: bearer, json: ["user_id": userID])
    }

    public static func unblock(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/social/blocks/\(userID)", bearer: bearer)
    }

    // MARK: G4 초대

    public static func invites(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/me/invites", bearer: bearer)
    }

    public static func dismissInvite(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/social/invites/\(userID)/dismiss", bearer: bearer)
    }

    public static func redeem(_ e: ServerEndpoint, bearer: String?, code: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/me/onboarding/invite/redeem", bearer: bearer, json: ["code": code])
    }

    /// 초대 링크 랜딩(`GET /i/{code}`, 인증 없음). 링크 문자열을 만드는 데만 쓴다(앱이 직접 부르지 않는다).
    public static func landingPath(code: String) -> String { "/i/\(code)" }

    // MARK: G5 공유

    public static func sharing(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/sharing", bearer: bearer)
    }

    public static func patchSharing(_ e: ServerEndpoint, bearer: String?, patch: HubSharingPatch) -> PetHTTPRequest {
        HubAPI.patch(e, "/api/v1/sharing", bearer: bearer, json: patch.json)
    }

    public static func putExclusions(_ e: ServerEndpoint, bearer: String?, text: String, version: Int) -> PetHTTPRequest {
        HubAPI.put(e, "/api/v1/sharing/exclusions", bearer: bearer, json: ["text": text], expectedVersion: version)
    }

    public static func person(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/sharing/people/\(userID)", bearer: bearer)
    }

    public static func putPerson(_ e: ServerEndpoint, bearer: String?, userID: String, note: String, version: Int) -> PetHTTPRequest {
        HubAPI.put(e, "/api/v1/sharing/people/\(userID)", bearer: bearer, json: ["person_note": note], expectedVersion: version)
    }
}

/// `PATCH /sharing`: 토글 4개 중 바꾸는 것만.
public struct HubSharingPatch: Equatable {
    public var shareFriends: String?        // everyday | checkin
    public var shareStrangers: String?      // public_profile | intro
    public var plansFreeOnly: Bool?
    public var birthdayMonthDay: Bool?

    public init(shareFriends: String? = nil, shareStrangers: String? = nil, plansFreeOnly: Bool? = nil, birthdayMonthDay: Bool? = nil) {
        self.shareFriends = shareFriends
        self.shareStrangers = shareStrangers
        self.plansFreeOnly = plansFreeOnly
        self.birthdayMonthDay = birthdayMonthDay
    }

    public var json: [String: Any] {
        var o: [String: Any] = [:]
        if let v = shareFriends { o["share_friends"] = v }
        if let v = shareStrangers { o["share_strangers"] = v }
        if let v = plansFreeOnly { o["share_plans_free_only"] = v }
        if let v = birthdayMonthDay { o["share_birthday_month_day"] = v }
        return o
    }
}

// MARK: - 입력 검증

public enum HubFriendsValidation {
    /// 사용자 ID 규칙(나초 앱 `handle-rules`): 영어 소문자·숫자·밑줄 3~20자. `@`·대문자는 고쳐 준다.
    public static let handleMin = 3
    public static let handleMax = 20

    /// 입력을 검색용 핸들로 바꾼다(앞뒤 공백·`@` 제거, 소문자).
    public static func normalizeHandle(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while v.hasPrefix("@") { v.removeFirst() }
        return v.lowercased()
    }

    /// 문제가 있으면 한국어 문구. 전화번호 모양(숫자 8자 이상)은 모바일에서만 찾을 수 있다.
    public static func handle(_ raw: String) -> String? {
        let v = normalizeHandle(raw)
        if v.isEmpty { return "찾을 사용자 ID를 입력해 주세요." }
        let digits = v.filter { $0.isNumber }
        if digits.count >= 8, v.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "+" || $0 == " " }) {
            return "전화번호로 찾는 것은 휴대폰의 나초 앱에서 해 주세요."
        }
        if v.count < handleMin { return "사용자 ID는 \(handleMin)자 이상이에요. (영어 소문자, 숫자, 밑줄)" }
        if v.count > handleMax { return "사용자 ID는 \(handleMax)자까지예요." }
        if !v.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "_" }) {
            return "사용자 ID는 영어 소문자, 숫자, 밑줄만 쓸 수 있어요."
        }
        return nil
    }

    /// 6자리 숫자 초대 코드.
    public static func inviteCode(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.count != 6 || !v.allSatisfy({ $0.isASCII && $0.isNumber }) { return "초대 코드는 숫자 6자리예요." }
        return nil
    }
}

public enum HubFriendsText {
    public static func message(_ e: PetAPIError) -> String {
        switch e.code ?? "" {
        case "not_found": return "찾을 수 없어요."
        case "invalid_params", "invalid_input": return "입력을 다시 확인해 주세요."
        case "limit_exceeded": return "친구 요청을 너무 많이 보냈어요. 내일 다시 해 주세요."
        case "invite_required", "invalid_code": return "초대 코드를 확인해 주세요."
        case "conflict": return "지금은 바꿀 수 없어요."
        default: return e.text
        }
    }
}

// MARK: - 응답 모델

public struct HubPerson: Equatable {
    public var userID: String
    public var displayName: String
    public var handle: String?
    public var avatarURL: String?
    public var flavor: String
    public var relationship: String
    public var unseen: Bool
    public var note: String?

    public init?(_ o: HubObject) {
        guard let id = o.str("user_id") else { return nil }
        userID = id
        displayName = o.str("display_name") ?? o.str("handle") ?? "친구"
        handle = o.str("handle")
        avatarURL = o.str("character_avatar_url")
        flavor = o.obj("character_look")?.str("flavor") ?? "original"
        relationship = o.str("relationship") ?? "none"
        unseen = o.bool("unseen") ?? false
        note = o.str("person_note_preview")
    }

    public var handleText: String? { handle.map { "@\($0)" } }
}

public struct HubSocialSummary: Equatable {
    public var friends: [HubPerson]
    public var requestsIn: [HubPerson]
    public var blocked: [HubPerson]

    public init?(_ o: HubObject) {
        guard o.raw["friends"] is [Any] else { return nil }
        friends = o.objs("friends").compactMap(HubPerson.init)
        requestsIn = o.objs("requests_in").compactMap(HubPerson.init)
        blocked = o.objs("blocked").compactMap(HubPerson.init)
    }
}

public struct HubInviteSignup: Equatable {
    public var person: HubPerson
    public var dismissed: Bool
}

public struct HubInviteInfo: Equatable {
    public var inviteOnly: Bool
    public var url: String
    public var code: String
    public var total: Int
    public var used: Int
    public var signups: [HubInviteSignup]

    public init?(_ o: HubObject) {
        guard o.str("invite_code") != nil || o.str("invite_url") != nil else { return nil }
        inviteOnly = o.bool("invite_only") ?? false
        url = o.str("invite_url") ?? ""
        code = o.str("invite_code") ?? ""
        total = o.int("total") ?? 0
        used = o.int("used") ?? 0
        signups = o.objs("signups").compactMap { s in HubPerson(s).map { HubInviteSignup(person: $0, dismissed: s.bool("dismissed") ?? false) } }
    }

    public var remaining: Int { max(0, total - used) }

    /// 복사할 수 있는 링크(https만). 그 밖의 값은 복사 대상이 아니다.
    public var copyableURL: String? {
        guard let u = URL(string: url), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return nil }
        return url
    }
}

public struct HubSharing: Equatable {
    public var shareFriends: String
    public var shareStrangers: String
    public var plansFreeOnly: Bool
    public var birthdayMonthDay: Bool
    public var strangerChatEnabled: Bool
    public var exclusions: String
    public var exclusionsVersion: Int
    public var exclusionsMax: Int
    public var personNoteMax: Int
    public var sensitive: [String]
    public var people: [HubPerson]

    public init?(_ o: HubObject) {
        guard o.str("share_friends") != nil else { return nil }
        shareFriends = o.str("share_friends") ?? "everyday"
        shareStrangers = o.str("share_strangers") ?? "public_profile"
        plansFreeOnly = o.bool("share_plans_free_only") ?? true
        birthdayMonthDay = o.bool("share_birthday_month_day") ?? false
        strangerChatEnabled = o.bool("stranger_chat_enabled") ?? false
        exclusions = o.str("exclusions") ?? ""
        exclusionsVersion = o.int("exclusions_version") ?? 0
        exclusionsMax = o.int("exclusions_max") ?? 2000
        personNoteMax = o.int("person_note_max") ?? 500
        sensitive = o.strs("sensitive_categories")
        people = o.objs("people").compactMap(HubPerson.init)
    }
}

public struct HubPersonNote: Equatable {
    public var userID: String
    public var displayName: String
    public var note: String
    public var version: Int

    public init?(_ o: HubObject) {
        guard let id = o.str("user_id") else { return nil }
        userID = id
        displayName = o.str("display_name") ?? "친구"
        note = o.str("person_note") ?? ""
        version = o.int("version") ?? 0
    }
}

/// 글자 수 검사(말하지 않을 내용·당부).
public enum HubSharingValidation {
    public static func text(_ raw: String, max: Int, name: String) -> String? {
        raw.count > max ? "\(name)은(는) \(max)자까지 쓸 수 있어요." : nil
    }
}
