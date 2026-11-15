import AppKit
import NachoComboCore

/// 사용량 하위 화면 공통 틀: 위에 「돌아가기」와 제목, 아래에 본문.
extension UsageSection {
    func subScreen(title: String, body: NSView) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let back = HubKit.secondaryButton("사용량", symbol: "chevron.left") { [weak self] in self?.load() }
        let bar = HubKit.hstack([back, HubKit.label(title, font: PetTheme.title, wrap: false)])
        host.addSubview(bar)
        host.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        let l = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: host.topAnchor, constant: l),
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: l),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: CGFloat(PetTokens.Space.s)),
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    func place(_ screen: NSView) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        HubKit.pin(screen, in: host)
        state.show(.content)
    }

    /// H2: 사용 내역(`GET /me/usage/ledger`). 다음 쪽은 `HubPage.nextQuery`를 그대로 붙인다.
    func showLedger(next: [(String, String)]?) {
        if next == nil { state.show(.loading) }
        callHub({ HubUsageAPI.ledger($0, bearer: $1, next: next) }) { [weak self] r in
            guard let self = self else { return }
            switch r.flatMap(HubUsageAPI.decodeLedger) {
            case let .failure(e):
                if next == nil { self.state.show(.failed(e.text)) } else { self.say(e.text, error: true) }
            case let .success(result):
                self.drawLedger(rows: result.rows, nextQuery: result.page.nextQuery, append: next != nil)
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func drawLedger(rows: [HubLedgerRow], nextQuery: [(String, String)]?, append: Bool) {
        let views: [NSView] = rows.map { r in
            HubRow(title: r.title, subtitle: [HubFormat.date(r.date), r.subtitle].compactMap { $0 }.joined(separator: " · "), trailing: r.creditsText, symbol: nil)
        }
        if append, let list = ledgerList {
            list.appendRows(views, hasMore: nextQuery != nil)
            list.onLoadMore = { [weak self] in self?.showLedger(next: nextQuery) }
            return
        }
        if rows.isEmpty {
            place(subScreen(title: "사용 내역", body: HubKit.label("  아직 사용 내역이 없어요.", color: PetTheme.secondary)))
            return
        }
        let list = HubListView()
        list.setRows(views, hasMore: nextQuery != nil)
        list.onLoadMore = { [weak self] in self?.showLedger(next: nextQuery) }
        ledgerList = list
        place(subScreen(title: "사용 내역", body: list))
    }
}
