import Foundation

// 사용량 섹션 확장(NACHO-264 U9: H2 사용 내역, 요금제 보기). U0의 사용량 읽기 화면 위에 붙는다.
// 요금제 구매·크레딧 팩 결제(H3)는 보스 결정 대기라 여기에 결제 호출이 없다(시험이 소스 문자열을 확인한다).

public struct HubLedgerRow: Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var credits: Int
    public var creditsText: String
    public var date: String
}

public struct HubPlanRow: Equatable {
    public var id: String
    public var label: String
    public var allowanceText: String
    public var priceText: String?
    public var isCurrent: Bool
}

public struct HubPlans: Equatable {
    public var plans: [HubPlanRow]
    public var currentPlanID: String
    public var subscriptionText: String?
}

public enum HubUsageAPI {
    /// 사용 내역 한 쪽. `next`는 `HubPage.nextQuery`를 그대로 넘긴다(쿼리 이름을 직접 정하지 않는다).
    public static func ledger(_ e: ServerEndpoint, bearer: String?, limit: Int = 30, next: [(String, String)]? = nil) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/me/usage/ledger", query: [("limit", String(limit))] + (next ?? []), bearer: bearer)
    }

    public static func plans(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/plans", bearer: bearer)
    }

    public static func entryLabel(_ t: String) -> String {
        switch t {
        case "usage": return "사용"
        case "refund": return "환불"
        case "refund_pending": return "환불 대기"
        case "grant": return "지급"
        case "purchase": return "충전"
        case "revoke": return "회수"
        default: return "내역"
        }
    }

    /// 앞에 부호를 붙인다(+30 / -12).
    public static func creditsText(_ n: Int) -> String {
        let s = PetText.number(abs(n))
        return n > 0 ? "+\(s)" : (n < 0 ? "-\(s)" : s)
    }

    public static func decodeLedger(_ resp: PetHTTPResponse) -> Result<(rows: [HubLedgerRow], page: HubPage), PetAPIError> {
        HubAPI.page(resp, key: "ledger").map { page in
            let rows = page.items.map { o -> HubLedgerRow in
                var title = o.str("task_label") ?? entryLabel(o.str("entry_type") ?? "")
                if title.isEmpty { title = entryLabel(o.str("entry_type") ?? "") }
                var sub: [String] = [entryLabel(o.str("entry_type") ?? "")]
                if let a = o.str("agent_name"), !a.isEmpty { sub.append(a) }
                let c = o.int("credits") ?? 0
                return HubLedgerRow(id: o.str("id") ?? UUID().uuidString, title: title, subtitle: sub.joined(separator: " · "),
                                    credits: c, creditsText: creditsText(c), date: o.str("occurred_at") ?? "")
            }
            return (rows, page)
        }
    }

    private static func subscriptionStatus(_ s: String) -> String {
        switch s {
        case "active": return "이용 중"
        case "canceled": return "해지됨(기간이 끝날 때까지 이용 가능)"
        case "grace": return "결제 유예 중"
        case "on_hold": return "결제 문제로 멈춤"
        case "expired": return "만료됨"
        case "pending": return "확인 중"
        default: return s
        }
    }

    public static func decodePlans(_ resp: PetHTTPResponse) -> Result<HubPlans, PetAPIError> {
        HubAPI.object(resp).map { o in
            let current = o.str("current_plan_id") ?? ""
            var plans: [HubPlanRow] = []
            for p in o.objs("plans") {
                guard let id = p.str("id") else { continue }
                if p.bool("offered") == false, id != current { continue }
                let weekly = p.int("weekly_allowance") ?? 0
                let daily = p.int("daily_allowance") ?? 0
                let allowance = p.str("period") == "week" && weekly > 0 ? "매주 \(PetText.number(weekly)) 크레딧" : (daily > 0 ? "매일 \(PetText.number(daily)) 크레딧" : "")
                let price = p.objs("prices").first.flatMap { $0.str("display") }
                plans.append(HubPlanRow(id: id, label: p.str("label") ?? id, allowanceText: allowance, priceText: price, isCurrent: id == current))
            }
            var sub: String?
            if let s = o.obj("subscription"), let st = s.str("status") {
                sub = subscriptionStatus(st)
                if let r = s.str("renews_at") ?? s.str("ends_at") { sub = (sub ?? "") + " · " + r }
            }
            return HubPlans(plans: plans, currentPlanID: current, subscriptionText: sub)
        }
    }

    /// 구매 안내 문구(결제 단추는 없다).
    public static let purchaseNotice = "구매는 휴대폰의 나초 앱에서 할 수 있어요"
}
