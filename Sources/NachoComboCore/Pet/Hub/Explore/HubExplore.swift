import Foundation

// 탐색 섹션(NACHO-264 U9: I1). 추천 카드·제안 수락/거절/거절 취소.

public struct HubOffer: Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var ctaLabel: String
    public var area: String
    public var steps: [String]
    public var reason: String?
    public var usageText: String?
}

public struct HubExploreSection: Equatable {
    public var id: String
    public var title: String
    public var offers: [HubOffer]
}

public struct HubOfferAccepted: Equatable {
    public var roomID: String
    public var taskID: String?
    public var duplicate: Bool
}

public enum HubExploreAPI {
    public static func sections(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/explore/sections", bearer: bearer)
    }

    /// 맡을 나초(`agent_id`)는 필수. `clientMsgID`는 연속 탭 방지용 멱등 키.
    public static func accept(_ e: ServerEndpoint, offerID: String, agentID: String, clientMsgID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/explore/offers/\(offerID)/accept", bearer: bearer, json: ["agent_id": agentID, "client_msg_id": clientMsgID])
    }

    public static func reject(_ e: ServerEndpoint, offerID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/explore/offers/\(offerID)/reject", bearer: bearer)
    }

    public static func undoReject(_ e: ServerEndpoint, offerID: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/explore/offers/\(offerID)/reject/undo", bearer: bearer)
    }

    public static func areaLabel(_ a: String) -> String {
        switch a {
        case "popular": return "인기"
        case "daily": return "일상"
        case "work": return "일"
        case "travel": return "여행"
        case "shopping": return "쇼핑"
        case "health": return "건강"
        case "fun": return "재미"
        default: return a
        }
    }

    private static func offer(_ o: HubObject) -> HubOffer? {
        guard let id = o.str("offer_id") else { return nil }
        let detail = o.str("detail") ?? ""
        var usage: String?
        if let u = o.obj("usage_estimate"), let lo = u.int("estimate_min"), let hi = u.int("estimate_max") {
            usage = lo == hi ? "예상 \(PetText.number(lo)) 크레딧" : "예상 \(PetText.number(lo))~\(PetText.number(hi)) 크레딧"
        }
        return HubOffer(id: id, title: o.str("title") ?? detail, detail: detail, ctaLabel: o.str("cta_label") ?? "맡기기",
                        area: o.str("area") ?? "", steps: o.strs("steps"), reason: o.str("reason"), usageText: usage)
    }

    /// 섹션 목록 + 「더 둘러보기」(`more_items`)는 마지막 섹션 `more`로 붙인다.
    public static func decodeSections(_ resp: PetHTTPResponse) -> Result<[HubExploreSection], PetAPIError> {
        HubAPI.object(resp).map { o in
            var out: [HubExploreSection] = o.objs("sections").compactMap { s in
                guard let id = s.str("section_id") else { return nil }
                return HubExploreSection(id: id, title: s.str("title") ?? areaLabel(id), offers: s.objs("items").compactMap(offer))
            }.filter { !$0.offers.isEmpty }
            let more = o.objs("more_items").compactMap(offer)
            if !more.isEmpty { out.append(HubExploreSection(id: "more", title: "더 둘러보기", offers: more)) }
            return out
        }
    }

    public static func decodeAccepted(_ resp: PetHTTPResponse) -> Result<HubOfferAccepted, PetAPIError> {
        HubAPI.object(resp).flatMap { o in
            guard let room = o.str("room_id") else { return .failure(.badResponse) }
            return .success(HubOfferAccepted(roomID: room, taskID: o.str("task_id"), duplicate: o.bool("duplicate") ?? false))
        }
    }

    /// 제안 수락 오류 문구(서버 reason을 한국어로). 없는 제안·쉬는 나초는 서버 코드로 가른다.
    public static func acceptErrorText(_ e: PetAPIError) -> String {
        if e.status == 404 { return "이 제안은 이제 없어요. 목록을 새로 불러올게요." }
        return e.text
    }
}
