import AppKit
import NachoComboCore

/// 작업 상세·계획·로그·이어하기·루틴 초안·지시 추가.
extension TasksSection {
    private func sub(_ title: String, _ lines: [String]) -> [NSView] {
        guard !lines.isEmpty else { return [] }
        return [HubKit.label(title, font: PetTheme.caption, color: PetTheme.secondary)] + lines.map { HubKit.label("· " + $0) }
    }

    private func backBar(_ title: String, back: @escaping () -> Void) -> NSView {
        HubKit.hstack([HubKit.secondaryButton("목록", symbol: "chevron.left", onClick: back), HubKit.label(title, font: PetTheme.title)])
    }

    func showDetail(_ t: HubTask) {
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        let stack = parts.stack
        var views: [NSView] = [backBar(t.title.isEmpty ? "작업" : t.title) { [weak self] in self?.backToList() }]
        var fields: [(String, String)] = [("상태", t.statusText)]
        if let s = t.stepLine { fields.append(("지금", s)) }
        if !t.requestText.isEmpty { fields.append(("맡긴 일", t.requestText)) }
        if let d = HubFormat.date(t.requestedAt) { fields.append(("요청한 때", d)) }
        if t.creditUsed > 0 { fields.append(("쓴 크레딧", HubFormat.number(t.creditUsed) + (t.creditCap.map { " / " + HubFormat.number($0) } ?? ""))) }
        if let s = t.awaySummary, !s.isEmpty { fields.append(("그동안", s)) }
        for (k, v) in fields {
            let r = HubKit.vstack([HubKit.label(k, font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(v)], spacing: Double(PetTokens.Space.xxs))
            views.append(r)
        }
        views += sub("결과", t.resultLines)
        if let title = t.failureTitle {
            views.append(HubKit.label(title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium), color: PetTheme.color(\.danger)))
            if let why = t.failureWhy { views.append(HubKit.label(why, color: PetTheme.secondary)) }
            views += sub("끝낸 일", t.completedActions) + sub("못 한 일", t.pendingActions) + sub("확실하지 않은 일", t.uncertainActions)
            if !t.nextActionTexts.isEmpty { views += sub("다음에 할 수 있는 일", t.nextActionTexts) }
        }
        views.append(actions(t))
        if t.canInstruct { views.append(instructionForm(t)) }
        let logs = HubKit.vstack([], spacing: Double(PetTokens.Space.xs))
        views.append(logs)
        for v in views { stack.addArrangedSubview(v) }
        HubKit.fill(stack, views)
        logsHost = logs
        host(parts.scroll, name: "detail:\(t.id)")
    }

    private func actions(_ t: HubTask) -> NSView {
        var b: [NSView] = []
        if t.canStart {
            b.append(HubKit.primaryButton("시작하기", symbol: "play.fill") { [weak self] in self?.start(t) })
        }
        for c in t.choices {
            b.append(HubKit.primaryButton(c.title) { [weak self] in self?.continueTask(t, c) })
        }
        if t.canOpenLiveView {
            b.append(HubKit.primaryButton("원격 화면 열기", symbol: "display") { [weak self] in self?.openLiveView(t) })
        }
        if let cid = t.callID {
            b.append(HubKit.secondaryButton(t.isLiveCall ? "통화 보기" : "통화 기록 보기", symbol: "phone") { [weak self] in self?.openCall(callID: cid, from: t) })
        }
        if !t.planLines.isEmpty || !t.steps.isEmpty {
            b.append(HubKit.secondaryButton("계획 보기", symbol: "list.bullet") { [weak self] in self?.showPlan(t) })
        }
        b.append(HubKit.secondaryButton("기록 보기", symbol: "clock") { [weak self] in self?.toggleLogs(t) })
        if t.canRoutine {
            b.append(HubKit.secondaryButton("예약으로 저장", symbol: "calendar.badge.plus") { [weak self] in self?.routineDraft(t) })
        }
        if t.canCancel {
            b.append(HubKit.secondaryButton("취소", symbol: "xmark") { [weak self] in self?.cancel(t) })
        }
        b.append(HubKit.secondaryButton("새로고침", symbol: "arrow.clockwise") { [weak self] in self?.refreshDetail(t.id) })
        let rows = HubKit.vstack([], spacing: Double(PetTokens.Space.s))
        var i = 0
        while i < b.count {
            let line = HubKit.hstack(Array(b[i..<min(i + 3, b.count)]))
            rows.addArrangedSubview(line)
            i += 3
        }
        return rows
    }

    // MARK: plan

    func showPlan(_ t: HubTask) {
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        var views: [NSView] = [backBar("계획") { [weak self] in self?.showDetail(t) }]
        views.append(HubKit.label(t.title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium)))
        views += sub("할 일 순서", t.planLines)
        views += sub("단계", t.steps)
        if t.creditUsed > 0 || t.creditCap != nil {
            views.append(HubKit.label("크레딧: " + HubFormat.number(t.creditUsed) + (t.creditCap.map { " / " + HubFormat.number($0) } ?? ""), color: PetTheme.secondary))
        }
        if t.canStart { views.append(HubKit.hstack([HubKit.primaryButton("시작하기", symbol: "play.fill") { [weak self] in self?.start(t) }])) }
        for v in views { parts.stack.addArrangedSubview(v) }
        HubKit.fill(parts.stack, views)
        host(parts.scroll, name: "plan:\(t.id)")
    }

    // MARK: writes

    private func start(_ t: HubTask) {
        let e = ctx.client!.endpoint
        write({ PetServerAPI.startTaskRequest(e, bearer: $0, taskID: t.id, expectedEstimateID: t.estimateID) },
              failText: { [weak self] err in
            if err.code == "estimate_changed" { self?.refreshDetail(t.id) }  // 새 계획을 다시 읽어 확인하게 한다
            return HubTasks.continueFailureText(err)
        }) { [weak self] resp in
            self?.ctx.toast("작업을 시작했어요", false)
            if case let .success(nt) = HubTasks.decodeTask(resp) { self?.showDetail(nt) } else { self?.refreshDetail(t.id) }
        }
    }

    private func continueTask(_ t: HubTask, _ choice: HubContinueChoice) {
        let e = ctx.client!.endpoint
        write({ HubTasks.continueTask(e, bearer: $0, taskID: t.id, choice: choice, expectedEstimateID: t.estimateID) },
              failText: { [weak self] err in
            if err.code == "estimate_changed" { self?.refreshDetail(t.id) }
            return HubTasks.continueFailureText(err)
        }) { [weak self] resp in
            self?.ctx.toast("알려 드렸어요", false)
            if case let .success(nt) = HubTasks.decodeTask(resp) { self?.showDetail(nt) } else { self?.refreshDetail(t.id) }
        }
    }

    private func cancel(_ t: HubTask) {
        let e = ctx.client!.endpoint
        ctx.confirm([HubConfirmStep(title: "\(t.title) 취소할까요?", message: "이미 끝난 일은 되돌릴 수 없어요", confirmTitle: "취소하기")]) { [weak self] in
            self?.write({ PetServerAPI.cancelTaskRequest(e, bearer: $0, taskID: t.id) }) { resp in
                self?.ctx.toast("취소했어요", false)
                if case let .success(nt) = HubTasks.decodeTask(resp) { self?.showDetail(nt) } else { self?.refreshDetail(t.id) }
            }
        }
    }

    private func routineDraft(_ t: HubTask) {
        let e = ctx.client!.endpoint
        write({ HubTasks.routineDraft(e, bearer: $0, taskID: t.id) }, failText: { err in
            err.status == 0 ? "초안이 만들어졌는지 확인하지 못했어요. 예약 목록을 확인해 주세요" : "초안을 만들지 못했어요. 다시 눌러 주세요"
        }) { [weak self] _ in
            self?.ctx.toast("예약 초안을 만들었어요. 예약 섹션에서 확인해 주세요", false)
        }
    }

    private func instructionForm(_ t: HubTask) -> NSView {
        let field = HubFormField(title: "지시 추가", placeholder: "예: 더 싼 곳으로 찾아 줘", validator: HubTasks.validateText)
        let send = HubKit.secondaryButton("보내기", symbol: "paperplane") { [weak self, weak field] in
            guard let self = self, let field = field, field.validate() else { return }
            let text = field.value
            let key = HubAPI.newIdempotencyKey()
            let e = self.ctx.client!.endpoint
            self.write({ HubTasks.instruction(e, bearer: $0, taskID: t.id, text: text, idempotencyKey: key) },
                       failText: { $0.status == 409 ? "이미 끝난 작업이라 지시를 더할 수 없어요." : $0.text }) { resp in
                field.field.stringValue = ""
                self.ctx.toast("지시를 보냈어요", false)
                if case let .success(nt) = HubTasks.decodeTask(resp) { self.showDetail(nt) }
            }
        }
        return HubKit.vstack([field, send], spacing: Double(PetTokens.Space.s))
    }

    // MARK: logs

    private func toggleLogs(_ t: HubTask) {
        guard let host = logsHost else { return }
        if !host.arrangedSubviews.isEmpty { for v in host.arrangedSubviews { host.removeArrangedSubview(v); v.removeFromSuperview() }; return }
        host.addArrangedSubview(HubKit.label("불러오는 중…", color: PetTheme.secondary))
        let e = ctx.client!.endpoint
        ctx.client!.send({ HubTasks.logs(e, bearer: $0, taskID: t.id) }) { [weak self, weak host] r in
            self?.onMain {
                guard let host = host else { return }
                for v in host.arrangedSubviews { host.removeArrangedSubview(v); v.removeFromSuperview() }
                switch r.flatMap({ HubTasks.decodeLogs($0) }) {
                case let .failure: host.addArrangedSubview(HubKit.label("기록을 읽지 못했어요", color: PetTheme.color(\.danger)))
                case let .success(nodes):
                    if nodes.isEmpty { host.addArrangedSubview(HubKit.label("아직 기록이 없어요", color: PetTheme.secondary)) }
                    for n in nodes {
                        let time = HubFormat.date(n.createdAt).map { $0 + "  " } ?? ""
                        host.addArrangedSubview(HubKit.label(time + n.text, font: PetTheme.caption))
                    }
                }
            }
        }
    }
}
