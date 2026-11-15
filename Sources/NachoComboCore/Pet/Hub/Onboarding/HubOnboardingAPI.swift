import Foundation

// 가입 요청 만들기(순수 함수라 시험이 바이트를 확인한다)와 응답 읽기. 공용 `HubAPI`를 그대로 쓴다.
//   GET  /api/v1/me/onboarding · POST …/submit {step, value?} · …/back {from} · …/invite-waitlist · …/region-waitlist · …/invite/redeem {code}

public enum HubOnboardingAPI {
    static let base = "/api/v1/me/onboarding"

    // MARK: requests

    public static func state(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.get(e, base, bearer: bearer) }

    public static func submit(_ e: ServerEndpoint, bearer: String?, step: HubOnboardingStep, value: Any?) -> PetHTTPRequest {
        var json: [String: Any] = ["step": step.raw]
        if let v = value { json["value"] = v }
        return HubAPI.post(e, base + "/submit", bearer: bearer, json: json)
    }

    public static func back(_ e: ServerEndpoint, bearer: String?, from: HubOnboardingStep) -> PetHTTPRequest {
        HubAPI.post(e, base + "/back", bearer: bearer, json: ["from": from.raw])
    }

    public static func inviteWaitlist(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.post(e, base + "/invite-waitlist", bearer: bearer) }
    public static func regionWaitlist(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.post(e, base + "/region-waitlist", bearer: bearer) }

    /// 링크로 받은 초대 코드. 화면의 코드 입력은 `submit invite_gate`로 거절 이유를 받는다.
    public static func redeem(_ e: ServerEndpoint, bearer: String?, code: String) -> PetHTTPRequest {
        HubAPI.post(e, base + "/invite/redeem", bearer: bearer, json: ["code": code])
    }

    // MARK: responses

    public static func parseState(_ resp: PetHTTPResponse) -> Result<HubOnboardingState, PetAPIError> {
        HubAPI.object(resp).flatMap { o in
            guard let step = o.str("step") else { return .failure(.badResponse) }
            let flags = o.obj("consent_flags")
            let status: HubOnboardingAccountStatus
            switch o.str("account_status") ?? "active" {
            case "active": status = .active
            case "suspended": status = .suspended
            case "region_closed": status = .regionClosed
            case let other: status = .other(other)
            }
            let voices = o.objs("voices").compactMap { v -> HubOnboardingVoice? in
                guard let id = v.str("voice_id"), !id.isEmpty else { return nil }
                return HubOnboardingVoice(voiceID: id, name: v.str("name") ?? id, label: v.str("label") ?? v.str("name") ?? id, description: v.str("description") ?? "")
            }
            return .success(HubOnboardingState(
                step: HubOnboardingStep(raw: step), canGoBack: o.bool("can_go_back") ?? false, accountStatus: status,
                displayName: o.str("display_name"), nameSuggestions: o.strs("name_suggestions"), birthday: o.str("birthday"),
                consentTerms: flags?.bool("terms"), consentPrivacy: flags?.bool("privacy"), consentMarketing: flags?.bool("marketing"),
                consentVersion: o.str("consent_version"), characterName: o.str("character_name"), voice: o.str("voice"), voices: voices,
                inviteWaitlistJoined: o.bool("invite_waitlist_joined") ?? false, regionWaitlistJoined: o.bool("region_waitlist_joined") ?? false,
                inviteOnly: o.bool("invite_only") ?? false, invitedBy: o.str("invited_by"), regionName: o.str("region_name")))
        }
    }

    public static func parseSubmit(_ resp: PetHTTPResponse) -> Result<HubOnboardingSubmitResult, PetAPIError> {
        HubAPI.object(resp).flatMap { o in
            guard let step = o.str("step") else { return .failure(.badResponse) }
            return .success(HubOnboardingSubmitResult(step: HubOnboardingStep(raw: step), rejection: o.obj("rejection")?.str("code")))
        }
    }

    public static func parseBack(_ resp: PetHTTPResponse) -> Result<HubOnboardingStep, PetAPIError> {
        HubAPI.object(resp).flatMap { o in
            guard let step = o.str("step") else { return .failure(.badResponse) }
            return .success(HubOnboardingStep(raw: step))
        }
    }
}

/// 대화 소켓을 열기 전의 확인: 가입이 덜 끝났거나 약관 갱신 동의가 남았으면 소켓을 열지 않는다(PetSession).
public enum HubOnboardingGate {
    public enum Decision: Equatable { case proceed, needsOnboarding }

    /// 서버가 가입 상태를 못 알려 주면(오류·네트워크·읽기 실패) 막지 않는다: 서버가 자기 오류로 거절한다.
    public static func check(endpoint: ServerEndpoint, http: PetHTTPClient, token: String, completion: @escaping (Decision) -> Void) {
        http.send(HubOnboardingAPI.state(endpoint, bearer: token)) { r in
            guard case let .success(resp) = r, case let .success(state) = HubOnboardingAPI.parseState(resp) else { completion(.proceed); return }
            completion(decision(state))
        }
    }

    public static func decision(_ s: HubOnboardingState) -> Decision {
        s.step == .done && !needsReconsent(s) ? .proceed : .needsOnboarding
    }

    /// 서버는 현재 문서 버전으로 동의한 것만 true로 준다: 새 버전이면 false로 읽힌다. 말이 없으면(nil) 묻지 않는다.
    public static func needsReconsent(_ s: HubOnboardingState) -> Bool {
        s.consentTerms == false || s.consentPrivacy == false
    }
}
