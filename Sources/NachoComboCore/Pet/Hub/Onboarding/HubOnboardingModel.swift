import Foundation

// 맥에서 가입 마치기(NACHO-277 U11, 표 행 A2). 화면 단계·상태·입력 규칙. 경로·필드는 nacho-server `spec/onboarding.tsp`와 같고,
// 동작·문구는 나초 앱(`features/onboarding`, `onboarding.ko.ts`)을 옮겼다.

/// 서버가 계산한 화면 단계(`ScreenStep`). 전화번호 인증(G3)처럼 이 스펙에 없는 단계는 `phone`/`unknown`으로 남긴다.
public enum HubOnboardingStep: Equatable {
    case login, inviteGate, inviteWaitlist, name, birthday, consent, guide, guidePrivacy, eggMeet
    case characterName, characterVoice, loading, done
    /// 전화번호 인증 단계. 맥에서는 SMS 인증을 하지 않는다.
    case phone(String)
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "login": self = .login
        case "invite_gate": self = .inviteGate
        case "invite_waitlist": self = .inviteWaitlist
        case "name": self = .name
        case "birthday": self = .birthday
        case "consent": self = .consent
        case "guide": self = .guide
        case "guide_privacy": self = .guidePrivacy
        case "egg_meet": self = .eggMeet
        case "character_name": self = .characterName
        case "character_voice": self = .characterVoice
        case "loading": self = .loading
        case "done": self = .done
        default: self = raw.lowercased().contains("phone") ? .phone(raw) : .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .login: return "login"
        case .inviteGate: return "invite_gate"
        case .inviteWaitlist: return "invite_waitlist"
        case .name: return "name"
        case .birthday: return "birthday"
        case .consent: return "consent"
        case .guide: return "guide"
        case .guidePrivacy: return "guide_privacy"
        case .eggMeet: return "egg_meet"
        case .characterName: return "character_name"
        case .characterVoice: return "character_voice"
        case .loading: return "loading"
        case .done: return "done"
        case let .phone(s), let .unknown(s): return s
        }
    }

    /// 이 앱이 그릴 수 없어 휴대폰의 나초 앱에서 마쳐야 하는 단계.
    public var isPhoneAppOnly: Bool {
        switch self {
        case .phone, .unknown: return true
        default: return false
        }
    }
}

public enum HubOnboardingAccountStatus: Equatable { case active, suspended, regionClosed, other(String) }

public struct HubOnboardingVoice: Equatable {
    public var voiceID: String
    public var name: String
    public var label: String
    public var description: String
}

/// `GET /api/v1/me/onboarding`.
public struct HubOnboardingState: Equatable {
    public var step: HubOnboardingStep
    public var canGoBack: Bool
    public var accountStatus: HubOnboardingAccountStatus
    public var displayName: String?
    public var nameSuggestions: [String]
    public var birthday: String?
    public var consentTerms: Bool?
    public var consentPrivacy: Bool?
    public var consentMarketing: Bool?
    public var consentThirdParty: Bool?
    public var consentAiTransfer: Bool?
    public var consentVersion: String?
    public var characterName: String?
    public var voice: String?
    public var voices: [HubOnboardingVoice]
    public var inviteWaitlistJoined: Bool
    public var regionWaitlistJoined: Bool
    public var inviteOnly: Bool
    public var invitedBy: String?
    public var regionName: String?
}

public struct HubOnboardingSubmitResult: Equatable {
    public var step: HubOnboardingStep
    /// 서버가 거절한 이유(`invalid_input`·`blocked_word`·…). 화면은 그대로다. 입력값 메아리(`value`)는 읽지 않는다.
    public var rejection: String?
}

/// 입력 규칙(앱 규칙 그대로)과 한국어 문구.
public enum HubOnboardingRules {
    public static let phoneNotice = "이 단계는 휴대폰의 나초 앱에서 마쳐 주세요. 마친 뒤 아래 「다시 확인」을 눌러 주세요."
    public static let inviteCodeLength = 6
    public static let characterNameMax = 20

    // MARK: 이름·생일(계정 섹션 규칙을 다시 쓴다)

    public static func name(_ raw: String) -> AccountRules.TextCheck { AccountRules.name(raw) }

    public static func nameProblem(_ raw: String) -> String? {
        switch name(raw) {
        case .ok: return nil
        case .empty: return "부를 이름을 입력해 주세요."
        case .tooLong: return rejectionText(step: .name, code: "invalid_input")
        }
    }

    public static func birthday(_ y: String, _ m: String, _ d: String, today: AccountRules.Day) -> AccountRules.BirthdayCheck {
        AccountRules.birthday(y, m, d, today: today)
    }

    public static func birthdayProblem(_ y: String, _ m: String, _ d: String, today: AccountRules.Day) -> String? {
        switch birthday(y, m, d, today: today) {
        case .ok: return nil
        case .incomplete: return "생일을 입력해 주세요."
        case .notADate, .future, .tooOld: return rejectionText(step: .birthday, code: "invalid_input")
        }
    }

    // MARK: 초대 코드(숫자 6자리)

    public static func inviteCodeValid(_ s: String) -> Bool {
        s.unicodeScalars.count == inviteCodeLength && s.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    /// 숫자만 남기고 6자리까지(붙여넣기·공백·하이픈 정리).
    public static func inviteCodeClean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.prefix(inviteCodeLength)))
    }

    // MARK: 캐릭터 이름(1~20자, 줄바꿈·@ 없이)

    public enum CharacterNameCheck: Equatable { case ok(String), empty, tooLong, invalid }

    public static func characterName(_ raw: String) -> CharacterNameCheck {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return .empty }
        if v.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "@" }) { return .invalid }
        return v.unicodeScalars.count > characterNameMax ? .tooLong : .ok(v)
    }

    public static func characterNameProblem(_ raw: String) -> String? {
        switch characterName(raw) {
        case .ok: return nil
        case .empty: return "AI 친구 이름을 입력해 주세요."
        case .tooLong, .invalid: return rejectionText(step: .characterName, code: "invalid_input")
        }
    }

    // MARK: 약관

    /// 필수 넷(이용약관·개인정보 수집·제3자 제공·AI 전송)이 모두 켜져야 한다. 혜택 알림(marketing)은 선택.
    public static func consentsReady(terms: Bool, privacy: Bool, thirdParty: Bool, aiTransfer: Bool) -> Bool {
        terms && privacy && thirdParty && aiTransfer
    }

    /// 스펙 `submit consent`의 값: `{terms, privacy, third_party, ai_transfer, marketing, consent_version}`.
    /// 가입 중에는 필수 넷이 모두 true여야 서버가 받는다(빠지면 `invalid_input`). `marketing_night`은 보내지 않는다(서버가 그대로 둔다).
    public static func consentValue(terms: Bool, privacy: Bool, thirdParty: Bool, aiTransfer: Bool, marketing: Bool, version: String) -> [String: Any] {
        ["terms": terms, "privacy": privacy, "third_party": thirdParty, "ai_transfer": aiTransfer, "marketing": marketing, "consent_version": version]
    }

    // MARK: 서버 거절 이유 → 한국어

    public static func rejectionText(step: HubOnboardingStep, code: String) -> String {
        switch code {
        case "invalid_input":
            switch step {
            case .name: return "이름은 줄바꿈 없이 1~40자로 써 주세요."
            case .characterName: return "AI 친구 이름은 줄바꿈과 @ 없이 1~20자로 써 주세요."
            case .birthday: return "날짜를 다시 확인해 주세요. 없는 날짜나 미래 날짜는 쓸 수 없어요."
            default: return "입력한 내용을 다시 확인해 주세요."
            }
        case "blocked_word": return "쓸 수 없는 표현이 들어 있어요. 다른 이름으로 해 주세요."
        case "impersonation": return "다른 사람이나 서비스로 오해할 수 있는 이름이에요. 다른 이름으로 해 주세요."
        case "underage": return "아직 나초를 쓸 수 있는 나이가 아니에요."
        case "invite_invalid": return "이 코드는 쓸 수 없어요. 코드를 확인해 주세요."
        case "invite_expired": return "기간이 지난 코드예요. 새 초대를 받아 주세요."
        case "invite_exhausted": return "이 코드의 초대 수가 다 찼어요. 새 초대를 받아 주세요."
        case "too_many_requests": return "시도가 너무 많았어요. 잠시 뒤에 다시 해 주세요."
        case "suspended": return "계정을 쓸 수 없는 상태예요."
        case "region_closed": return "이 지역은 아직 열리지 않았어요."
        case "invite_required": return "초대 확인이 먼저 필요해요."
        default: return "문제가 생겨 진행하지 못했어요. 잠시 뒤에 다시 해 주세요."
        }
    }

    /// 받침이 있으면 `withBatchim`, 없으면 `without`(앱 `{name:이}`·`{name:이야}` 문구 처리). 한글이 아니면 받침 없음으로 본다.
    public static func particle(_ name: String, _ withBatchim: String, _ without: String) -> String {
        guard let last = name.unicodeScalars.last, last.value >= 0xAC00, last.value <= 0xD7A3 else { return without }
        return (last.value - 0xAC00) % 28 == 0 ? without : withBatchim
    }

    public static let networkText = "연결을 확인하고 다시 눌러 주세요. 입력한 내용은 그대로 있어요."
    public static let joinFailedText = "등록하지 못했어요. 다시 눌러 주세요."
}
