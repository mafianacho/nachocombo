import AppKit
import NachoComboCore

/// 사용량·요금제(H1 읽기): `GET /api/v1/me/usage`를 HubAPI로 불러 보여 준다. 요금제 변경·내역(H2, U9)은 여기 없다.
final class UsageSection: HubSectionBase {
    init() { super.init(id: .usage) }

    override func load() {
        guard let client = ctx.client else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        let endpoint = client.endpoint
        client.send({ HubAPI.get(endpoint, "/api/v1/me/usage", bearer: $0) }) { [weak self] result in
            guard let self = self else { return }
            self.onMain {
                switch result {
                case let .failure(e): self.state.show(.failed(e.text))
                case let .success(resp):
                    if let usage = PetServerAPI.decodeUsage(resp.body) { self.show(usage) } else { self.state.show(.failed(PetAPIError.badResponse.text)) }
                }
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func show(_ u: PetUsage) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        var fields: [(String, String)] = []
        if let a = u.allowance, a > 0 {
            fields.append(("남은 크레딧", "\(HubFormat.number(u.remaining)) / \(HubFormat.number(a))"))
        } else {
            fields.append(("남은 크레딧", HubFormat.number(u.remaining)))
        }
        if let plan = u.planID, !plan.isEmpty { fields.append(("요금제", plan)) }
        if let p = u.period, !p.isEmpty { fields.append(("주기", p)) }
        if let r = HubFormat.date(u.resetAt) { fields.append(("다시 채워지는 때", r)) }
        if let used = u.lightChatUsed, let cap = u.lightChatCap, cap > 0 {
            fields.append(("가벼운 대화", "\(HubFormat.number(used)) / \(HubFormat.number(cap))"))
        }
        if let b = u.blockReason {
            fields.append(("지금은", ErrorText.blockReason(b)))
        } else if u.exhausted {
            fields.append(("지금은", "크레딧을 모두 썼어요."))
        } else if u.lowBalance {
            fields.append(("지금은", "크레딧이 얼마 안 남았어요."))
        }
        let detail = HubDetailView(title: "사용량", fields: fields, actions: [
            HubKit.secondaryButton("새로고침", symbol: "arrow.clockwise") { [weak self] in self?.reload() },
        ])
        HubKit.pin(detail, in: host)
        state.show(.content)
    }
}
