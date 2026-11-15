import AppKit
import NachoComboCore

/// 탐색(NACHO-264 U9: I1). 추천 카드를 보고 나초에게 맡기거나(수락), 숨기고(거절), 되돌린다(거절 취소).
/// 시작은 항상 사용자가 누를 때만이고, Mac의 내용(화면·파일·클립보드)은 서버로 보내지 않는다.
final class ExploreSection: HubSectionBase {
    var agents: [HubAgentRef] = []
    var sections: [HubExploreSection] = []
    var picker: NSPopUpButton?
    /// 방금 숨긴 제안(되돌리기용).
    var lastRejected: HubOffer?
    var busy = Set<String>()

    init() { super.init(id: .explore) }

    override func load() {
        guard ctx.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        var secs: Result<[HubExploreSection], PetAPIError>?
        var ags: Result<[HubAgentRef], PetAPIError>?
        let finish: () -> Void = { [weak self] in
            guard let self = self, let s = secs, let a = ags else { return }
            switch (s, a) {
            case let (.success(ss), .success(aa)):
                self.sections = ss
                self.agents = aa
                self.draw()
            case let (.failure(e), _), let (_, .failure(e)): self.state.show(.failed(e.text))
            }
        }
        call({ HubExploreAPI.sections($0, bearer: $1) }) { secs = $0.flatMap(HubExploreAPI.decodeSections); finish() }
        call({ HubTrustAPI.agents($0, bearer: $1) }) { ags = $0.flatMap(HubTrustAPI.decodeAgents); finish() }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func draw() {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        guard !sections.isEmpty else { state.show(.empty("지금 둘러볼 제안이 없어요.")); return }
        let parts = HubKit.scrollingStack()
        let stack = parts.stack
        // 맡을 나초
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.translatesAutoresizingMaskIntoConstraints = false
        pop.addItems(withTitles: agents.map { $0.name })
        picker = pop
        let who = HubKit.hstack([HubKit.label("맡을 나초", font: PetTheme.caption, color: PetTheme.secondary, wrap: false), pop])
        stack.addArrangedSubview(who)
        if agents.isEmpty { stack.addArrangedSubview(HubKit.label("맡을 나초가 아직 없어요. 나초를 먼저 만들어 주세요.", font: PetTheme.caption, color: PetTheme.secondary)) }
        if let r = lastRejected {
            stack.addArrangedSubview(HubKit.secondaryButton("「\(r.title)」 숨김 되돌리기", symbol: "arrow.uturn.backward") { [weak self] in self?.undoReject(r) })
        }
        for sec in sections {
            stack.addArrangedSubview(HubKit.label(sec.title, font: PetTheme.title))
            for offer in sec.offers {
                let card = HubOfferCard(offer: offer, busy: busy.contains(offer.id), onAccept: { [weak self] in self?.accept(offer) }, onReject: { [weak self] in self?.reject(offer) })
                stack.addArrangedSubview(card)
                HubKit.fill(stack, [card])
            }
        }
        HubKit.pin(parts.scroll, in: host)
        state.show(.content)
    }

    private func selectedAgent() -> HubAgentRef? {
        let i = picker?.indexOfSelectedItem ?? 0
        return agents.indices.contains(i) ? agents[i] : nil
    }

    func accept(_ offer: HubOffer) {
        guard let agent = selectedAgent() else { say("맡을 나초를 먼저 골라 주세요.", error: true); return }
        guard !busy.contains(offer.id) else { return }
        busy.insert(offer.id)
        draw()
        let msgID = HubAPI.newIdempotencyKey()
        call({ HubExploreAPI.accept($0, offerID: offer.id, agentID: agent.id, clientMsgID: msgID, bearer: $1) }) { [self] r in
            busy.remove(offer.id)
            switch r.flatMap(HubExploreAPI.decodeAccepted) {
            case let .success(done):
                say(done.duplicate ? "이미 \(agent.name)에게 맡겼어요." : "\(agent.name)에게 맡겼어요.")
                draw()
            case let .failure(e):
                say(HubExploreAPI.acceptErrorText(e), error: true)
                if e.status == 404 { load() } else { draw() }
            }
        }
    }

    func reject(_ offer: HubOffer) {
        call({ HubExploreAPI.reject($0, offerID: offer.id, bearer: $1) }) { [self] r in
            switch r.flatMap(HubAPI.empty) {
            case .success:
                lastRejected = offer
                say("제안을 숨겼어요.")
                load()
            case let .failure(e):
                say(HubExploreAPI.acceptErrorText(e), error: true)
                if e.status == 404 { load() }
            }
        }
    }

    func undoReject(_ offer: HubOffer) {
        call({ HubExploreAPI.undoReject($0, offerID: offer.id, bearer: $1) }) { [self] r in
            switch r.flatMap(HubAPI.empty) {
            case .success: lastRejected = nil; say("숨김을 되돌렸어요."); load()
            case let .failure(e): say(e.text, error: true)
            }
        }
    }
}

/// 추천 카드 하나: 제목·설명·단계·이유·예상 사용량 + 「맡기기」「관심 없어요」.
final class HubOfferCard: PetBox {
    init(offer: HubOffer, busy: Bool, onAccept: @escaping () -> Void, onReject: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = PetTheme.color(\.surface)
        stroke = PetTheme.color(\.edge)
        radius = CGFloat(PetTokens.Radius.card)
        let title = HubKit.label(offer.title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium))
        var views: [NSView] = [title]
        if offer.detail != offer.title, !offer.detail.isEmpty { views.append(HubKit.label(offer.detail, color: PetTheme.secondary)) }
        if !offer.steps.isEmpty {
            views.append(HubKit.label(offer.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"), font: PetTheme.caption, color: PetTheme.secondary))
        }
        if let r = offer.reason, !r.isEmpty { views.append(HubKit.label(r, font: PetTheme.caption, color: PetTheme.tertiary)) }
        if let u = offer.usageText { views.append(HubKit.label(u, font: PetTheme.caption, color: PetTheme.secondary)) }
        let accept = HubKit.primaryButton(busy ? "맡기는 중…" : offer.ctaLabel, onClick: { if !busy { onAccept() } })
        let reject = HubKit.secondaryButton("관심 없어요", onClick: onReject)
        let buttons = HubKit.hstack([accept, reject])
        views.append(buttons)
        let s = HubKit.vstack(views, spacing: Double(PetTokens.Space.s))
        addSubview(s)
        let p = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            s.topAnchor.constraint(equalTo: topAnchor, constant: p),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
        ])
        HubKit.fill(s, views.filter { $0 !== buttons })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
