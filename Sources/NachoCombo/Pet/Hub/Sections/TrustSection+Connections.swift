import AppKit
import NachoComboCore

/// E5: 연결별 Nacho 허용(`/connections/{id}/agents`)·공유 대상(`/connections/sharing`).
extension TrustSection {
    func loadConnections() {
        let pane = tabs.panes[0]
        pane.onRetry = { [weak self] in self?.loadConnections() }
        pane.show(.loading)
        var conns: Result<[HubConnection], PetAPIError>?
        var ags: Result<[HubAgentRef], PetAPIError>?
        var shr: Result<[HubSharingRow], PetAPIError>?
        let finish: () -> Void = { [weak self] in
            guard let self = self, let c = conns, let a = ags, let s = shr else { return }
            switch (c, a, s) {
            case let (.success(cs), .success(ag), .success(sh)):
                self.connections = cs
                self.agents = ag
                self.sharing = Dictionary(sh.map { ($0.source, $0) }, uniquingKeysWith: { _, b in b })
                self.drawConnections()
            case let (.failure(e), _, _), let (_, .failure(e), _), let (_, _, .failure(e)):
                pane.show(.failed(e.text))
            }
        }
        callHub({ HubTrustAPI.connections($0, bearer: $1) }) { conns = $0.flatMap(HubTrustAPI.decodeConnections); finish() }
        callHub({ HubTrustAPI.agents($0, bearer: $1) }) { ags = $0.flatMap(HubTrustAPI.decodeAgents); finish() }
        callHub({ HubTrustAPI.sharing($0, bearer: $1) }) { shr = $0.flatMap(HubTrustAPI.decodeSharing); finish() }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func drawConnections() {
        let pane = tabs.panes[0]
        let live = connections.filter { $0.status != "disconnected" }
        guard !live.isEmpty else { pane.show(.empty("연결한 서비스가 아직 없어요. 휴대폰의 나초 앱이나 연결 탭에서 연결해요.")); return }
        for v in pane.contentHost.subviews { v.removeFromSuperview() }
        let list = HubListView()
        let rows: [NSView] = live.map { c in
            var sub = [c.statusText]
            if let a = c.accountLabel, !a.isEmpty { sub.append(a) }
            if let s = c.scopeSummary, !s.isEmpty { sub.append(s) }
            let shared = sharing[c.source].map { $0.audience.label } ?? HubAudience.nobody.label
            let row = HubRow(title: c.label, subtitle: sub.joined(separator: " · "), trailing: shared, symbol: "link")
            row.onClick = { [weak self] in self?.openConnection(c) }
            return row
        }
        list.setRows(rows, hasMore: false)
        HubKit.pin(list, in: pane.contentHost)
        pane.show(.content)
    }

    func openConnection(_ c: HubConnection) {
        let pane = tabs.panes[0]
        pane.show(.loading)
        callHub({ HubTrustAPI.allowances($0, connectionID: c.id, bearer: $1) }) { [weak self] r in
            guard let self = self else { return }
            switch r.flatMap(HubTrustAPI.decodeAllowances) {
            case let .failure(e): self.say(e.text, error: true); self.drawConnections()
            case let .success(allow): self.drawConnectionDetail(c, allowances: allow)
            }
        }
    }

    func drawConnectionDetail(_ c: HubConnection, allowances: [HubAllowance]) {
        let pane = tabs.panes[0]
        for v in pane.contentHost.subviews { v.removeFromSuperview() }
        let parts = HubKit.scrollingStack()
        let stack = parts.stack
        let back = HubKit.secondaryButton("연결 목록", symbol: "chevron.left") { [weak self] in self?.drawConnections() }
        stack.addArrangedSubview(back)
        stack.addArrangedSubview(HubKit.label(c.label, font: PetTheme.title))
        if let a = c.accountLabel, !a.isEmpty { stack.addArrangedSubview(HubKit.label(a, font: PetTheme.caption, color: PetTheme.secondary)) }

        // 나초별 허용
        stack.addArrangedSubview(HubKit.label("이 연결을 쓸 수 있는 나초", font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium)))
        var current = allowances
        if agents.isEmpty { stack.addArrangedSubview(HubKit.label("나초가 아직 없어요.", font: PetTheme.caption, color: PetTheme.secondary)) }
        for ag in agents {
            let existing = current.first { $0.agentID == ag.id }
            let row = HubSwitchRow(title: ag.name, detail: existing?.writeKinds.map { $0.isEmpty ? "읽기만" : "쓰기: " + $0.joined(separator: ", ") }, isOn: existing?.allowed ?? false)
            row.onChange = { [weak self, weak row] on in
                guard let self = self else { return }
                var next = current.filter { $0.agentID != ag.id }
                next.append(HubAllowance(agentID: ag.id, allowed: on, writeKinds: existing?.writeKinds))
                self.callHub({ HubTrustAPI.putAllowances($0, connectionID: c.id, items: next, bearer: $1, idempotencyKey: HubAPI.newIdempotencyKey()) }) { r in
                    switch r.flatMap(HubTrustAPI.decodeAllowances) {
                    case let .success(saved):
                        current = saved
                        self.say(on ? "\(ag.name)이(가) 이 연결을 쓸 수 있어요." : "\(ag.name)은(는) 이제 이 연결을 못 써요.")
                    case let .failure(e):
                        row?.toggle.state = on ? .off : .on
                        self.say(e.text, error: true)
                    }
                }
            }
            stack.addArrangedSubview(row)
            HubKit.fill(stack, [row])
        }

        // 공유 대상
        stack.addArrangedSubview(HubKit.label("이 연결의 정보를 말해도 되는 사람", font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium)))
        let row = sharing[c.source] ?? HubSharingRow(source: c.source, label: c.label, category: "", audience: .nobody, sharePlansFreeOnly: false)
        var options = HubAudience.selectable
        if row.audience == .everyone { options.append(.everyone) }
        let seg = NSSegmentedControl(labels: options.map { $0.label }, trackingMode: .selectOne, target: nil, action: nil)
        seg.translatesAutoresizingMaskIntoConstraints = false
        seg.selectedSegment = options.firstIndex(of: row.audience) ?? 0
        let handler = HubSegmentHandler { [weak self, weak seg] idx in
            guard let self = self, idx < options.count else { return }
            let audience = options[idx]
            self.callHub({ HubTrustAPI.putSharing($0, source: c.source, category: row.category, audience: audience, bearer: $1) }) { r in
                switch r.flatMap(HubTrustAPI.decodeSharingRow) {
                case let .success(saved):
                    self.sharing[c.source] = saved
                    self.say("공유 대상을 바꿨어요.")
                case let .failure(e):
                    seg?.selectedSegment = options.firstIndex(of: self.sharing[c.source]?.audience ?? .nobody) ?? 0
                    self.say(e.text, error: true)
                }
            }
        }
        seg.target = handler
        seg.action = #selector(HubSegmentHandler.fire(_:))
        objc_setAssociatedObject(seg, &HubSegmentHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        stack.addArrangedSubview(seg)
        if row.category == "calendar" {
            stack.addArrangedSubview(HubKit.label("일정은 되는지만 말해요.", font: PetTheme.caption, color: PetTheme.secondary))
        }
        HubKit.pin(parts.scroll, in: pane.contentHost)
        pane.show(.content)
    }
}

/// 분절 단추 선택을 클로저로 받는다.
final class HubSegmentHandler: NSObject {
    static var key: UInt8 = 0
    let onSelect: (Int) -> Void
    init(_ f: @escaping (Int) -> Void) { onSelect = f }
    @objc func fire(_ sender: NSSegmentedControl) { onSelect(sender.selectedSegment) }
}
