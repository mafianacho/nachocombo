import AppKit
import NachoComboCore

/// E8: 승인 규칙 목록·계정 합계 한도·삭제(`/me/approval-rules`). 규칙은 사용자가 카드에서 허용해야만 생기므로 만들기는 없다.
extension TrustSection {
    func loadRules() {
        let pane = tabs.panes[2]
        pane.onRetry = { [weak self] in self?.loadRules() }
        pane.show(.loading)
        callHub({ HubTrustAPI.approvalRules($0, bearer: $1) }) { [weak self] r in
            guard let self = self else { return }
            switch r.flatMap(HubTrustAPI.decodeApprovalRules) {
            case let .failure(e): pane.show(.failed(e.text))
            case let .success(rules): self.drawRules(rules)
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func drawRules(_ rules: HubApprovalRules) {
        let pane = tabs.panes[2]
        for v in pane.contentHost.subviews { v.removeFromSuperview() }
        let parts = HubKit.scrollingStack()
        let stack = parts.stack
        stack.addArrangedSubview(HubKit.label("계정 합계 한도", font: PetTheme.title))
        let limitText = rules.limitValue.map { "\(PetText.number($0))원 (\(PetText.number(rules.limitUsed))원 썼어요)" } ?? "한도 없음"
        stack.addArrangedSubview(HubKit.label("모든 나초가 자동으로 허락받아 쓸 수 있는 금액의 합이에요. 지금: \(limitText)", font: PetTheme.caption, color: PetTheme.secondary))
        let field = HubFormField(title: "한도(원)", placeholder: "비우면 한도가 없어요", validator: { text in
            if case let .failure(e) = HubTrustAPI.parseLimit(text) { return e.text }
            return nil
        })
        field.field.stringValue = rules.limitValue.map(String.init) ?? ""
        limitField = field
        stack.addArrangedSubview(field)
        let save = HubKit.primaryButton("한도 저장") { [weak self] in self?.saveLimit(currency: rules.limitCurrency) }
        stack.addArrangedSubview(save)
        HubKit.fill(stack, [field])

        stack.addArrangedSubview(HubKit.label("허용 규칙", font: PetTheme.title))
        if rules.rules.isEmpty {
            stack.addArrangedSubview(HubKit.label("저장된 규칙이 없어요. 승인 카드에서 「앞으로도 허용」을 고르면 여기에 생겨요.", font: PetTheme.caption, color: PetTheme.secondary))
        } else {
            stack.addArrangedSubview(HubKit.label("규칙을 누르면 지울 수 있어요.", font: PetTheme.caption, color: PetTheme.secondary))
        }
        for rule in rules.rules {
            var sub: [String] = []
            if rule.expired { sub.append("만료됨") } else if let d = HubFormat.date(rule.expiresAt) { sub.append("\(d)까지") }
            if rule.used > 0 { sub.append("\(PetText.number(rule.used))원 썼어요") }
            if !rule.appliesToAgentIDs.isEmpty { sub.append("나초 \(rule.appliesToAgentIDs.count)개") }
            let row = HubRow(title: rule.summary, subtitle: sub.joined(separator: " · "), trailing: rule.expired ? "만료" : nil, symbol: "checkmark.shield")
            row.onClick = { [weak self] in self?.confirmDelete(rule) }
            stack.addArrangedSubview(row)
            HubKit.fill(stack, [row])
        }
        HubKit.pin(parts.scroll, in: pane.contentHost)
        pane.show(.content)
    }

    func saveLimit(currency: String) {
        guard let field = limitField, field.validate() else { return }
        guard case let .success(value) = HubTrustAPI.parseLimit(field.value) else { return }
        callHub({ HubTrustAPI.patchAccountLimit($0, value: value, currency: currency, bearer: $1) }) { [weak self] r in
            guard let self = self else { return }
            switch r.flatMap(HubTrustAPI.decodePatchedRules) {
            case let .success(rules):
                self.say(value == nil ? "한도를 없앴어요." : "한도를 저장했어요.")
                self.drawRules(rules)
            case let .failure(e):
                self.limitField?.showServerError(e.text)
                self.say(e.text, error: true)
            }
        }
    }

    /// 되돌릴 수 없는 삭제: 확인창을 두 번 거친다.
    func confirmDelete(_ rule: HubApprovalRule) {
        ctx.confirm([
            HubConfirmStep(title: "이 규칙을 지울까요?", message: "「\(rule.summary)」\n지우면 다음부터는 이 일을 할 때마다 다시 물어봐요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "한 번 더 확인해요. 지운 규칙은 되살릴 수 없어요.", confirmTitle: "지우기"),
        ]) { [weak self] in
            guard let self = self else { return }
            self.callHub({ HubTrustAPI.deleteRule($0, id: rule.id, bearer: $1) }) { r in
                switch r.flatMap(HubAPI.empty) {
                case .success: self.say("규칙을 지웠어요."); self.loadRules()
                case let .failure(e):
                    self.say(e.isNotFound ? "이미 없는 규칙이에요." : e.text, error: e.isNotFound == false)
                    if e.isNotFound { self.loadRules() }
                }
            }
        }
    }
}
