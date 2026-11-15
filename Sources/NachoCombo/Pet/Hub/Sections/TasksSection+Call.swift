import AppKit
import NachoComboCore

/// 전화 작업 모니터링(B16): 통화 기록·자막, 메모 보내기, 끊기(이중 확인).
extension TasksSection {
    func openCall(callID: String, from t: HubTask) {
        guard let client = ctx.client else { return }
        state.show(.loading)
        let e = client.endpoint
        client.send({ HubTasks.call(e, bearer: $0, callID: callID) }) { [weak self] r in
            guard let self = self else { return }
            self.onMain {
                switch r.flatMap({ HubTasks.decodeCall($0) }) {
                case let .failure(err):
                    self.ctx.toast(err.text, true)
                    self.showDetail(t)
                case let .success(call): self.showCall(call, task: t)
                }
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func showCall(_ c: HubCallDetail, task t: HubTask) {
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        var views: [NSView] = [HubKit.hstack([HubKit.secondaryButton("작업", symbol: "chevron.left") { [weak self] in self?.showDetail(t) },
                                              HubKit.label("통화 · " + (c.counterpart.isEmpty ? t.title : c.counterpart), font: PetTheme.title)])]
        var fields: [(String, String)] = [("상태", c.stateText)]
        if let o = c.outcomeText { fields.append(("결과", o)) }
        if !c.phoneMasked.isEmpty { fields.append(("번호", c.phoneMasked)) }
        if !c.purpose.isEmpty { fields.append(("용건", c.purpose)) }
        if let a = c.attemptLine { fields.append(("시도", a)) }
        if c.creditsUsed > 0 { fields.append(("쓴 크레딧", HubFormat.number(c.creditsUsed))) }
        for (k, v) in fields {
            views.append(HubKit.vstack([HubKit.label(k, font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(v)], spacing: Double(PetTokens.Space.xxs)))
        }
        if !c.disclosure.isEmpty { views.append(HubKit.label(c.disclosure, font: PetTheme.caption, color: PetTheme.secondary)) }
        if let h = c.headline { views.append(HubKit.label(h, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium))) }
        for i in c.resultItems { views.append(HubKit.label("· " + i)) }
        views.append(HubKit.label("나눈 말", font: PetTheme.caption, color: PetTheme.secondary))
        if c.lines.isEmpty { views.append(HubKit.label("연결되지 않아 나눈 말이 없어요.", color: PetTheme.secondary)) }
        for l in c.lines {
            views.append(HubKit.label("\(l.speakerText): \(l.text)" + (l.relayed ? " (전한 말)" : ""),
                                      color: l.speaker == "user_note" ? PetTheme.accent : PetTheme.text))
        }
        if c.isLive { views.append(liveControls(c, task: t)) }
        views.append(HubKit.hstack([HubKit.secondaryButton("새로고침", symbol: "arrow.clockwise") { [weak self] in self?.openCall(callID: c.id, from: t) }]))
        for v in views { parts.stack.addArrangedSubview(v) }
        HubKit.fill(parts.stack, views)
        host(parts.scroll, name: "call:\(c.id)")
    }

    private func liveControls(_ c: HubCallDetail, task t: HubTask) -> NSView {
        let field = HubFormField(title: "메모 보내기", placeholder: "통화 중인 나초에게 전할 말", validator: HubTasks.validateCallNote)
        let send = HubKit.secondaryButton("보내기", symbol: "paperplane") { [weak self, weak field] in
            guard let self = self, let field = field, field.validate() else { return }
            let text = field.value
            let key = HubAPI.newIdempotencyKey()
            let e = self.ctx.client!.endpoint
            self.write({ HubTasks.callNote(e, bearer: $0, taskID: c.taskID, text: text, idempotencyKey: key) },
                       failText: { $0.status == 409 ? "이미 끝난 통화예요." : "보내지 못했어요. 다시 해 주세요" }) { _ in
                field.field.stringValue = ""
                self.ctx.toast("메모를 보냈어요", false)
            }
        }
        let hang = HubKit.primaryButton("끊기", symbol: "phone.down", danger: true) { [weak self] in self?.hangup(c, task: t) }
        return HubKit.vstack([field, HubKit.hstack([send, hang])], spacing: Double(PetTokens.Space.s))
    }

    /// 되돌릴 수 없는 동작이라 확인창을 두 번 거친다.
    private func hangup(_ c: HubCallDetail, task t: HubTask) {
        let e = ctx.client!.endpoint
        let during = c.state == "in_call"
        ctx.confirm([
            HubConfirmStep(title: "전화를 끊을까요?", message: during ? "지금 끊으면 통화가 여기서 끝나요." : "아직 연결되기 전이라 바로 취소돼요.", confirmTitle: "끊을게요"),
            HubConfirmStep(title: "정말 끊을까요?", message: "끊으면 이 작업도 취소돼요. 되돌릴 수 없어요.", confirmTitle: "끊기"),
        ]) { [weak self] in
            self?.write({ HubTasks.callHangup(e, bearer: $0, taskID: c.taskID) }, failText: { _ in "끊지 못했어요. 다시 해 주세요" }) { _ in
                self?.ctx.toast("전화를 끊었어요", false)
                self?.openCall(callID: c.id, from: t)
            }
        }
    }
}
