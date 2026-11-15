import AppKit
import NachoComboCore

/// 요금제 보기(읽기만): `GET /api/v1/plans`. 구매·변경은 보스 결정 대기라 단추도 요청도 없다. 안내 문구만 둔다.
extension UsageSection {
    func showPlans() {
        state.show(.loading)
        callHub({ HubUsageAPI.plans($0, bearer: $1) }) { [weak self] r in
            guard let self = self else { return }
            switch r.flatMap(HubUsageAPI.decodePlans) {
            case let .failure(e): self.state.show(.failed(e.text))
            case let .success(p): self.drawPlans(p)
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func drawPlans(_ p: HubPlans) {
        let parts = HubKit.scrollingStack()
        let stack = parts.stack
        if let s = p.subscriptionText { stack.addArrangedSubview(HubKit.label("내 구독: \(s)", color: PetTheme.secondary)) }
        if p.plans.isEmpty { stack.addArrangedSubview(HubKit.label("보여 줄 요금제가 없어요.", color: PetTheme.secondary)) }
        for plan in p.plans {
            let row = HubRow(title: plan.label + (plan.isCurrent ? " · 내 요금제" : ""), subtitle: plan.allowanceText, trailing: plan.priceText, symbol: plan.isCurrent ? "checkmark.circle" : "square.stack")
            stack.addArrangedSubview(row)
            HubKit.fill(stack, [row])
        }
        let notice = HubKit.label(HubUsageAPI.purchaseNotice, font: PetTheme.caption, color: PetTheme.secondary)
        stack.addArrangedSubview(notice)
        place(subScreen(title: "요금제", body: parts.scroll))
    }
}
