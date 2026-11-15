import AppKit
import NachoComboCore

/// E7: 자격 증명 사용 기록(`GET /api/v1/secure/log`). 읽기만 한다. 비밀 값은 Core가 화면 값으로 옮기지 않는다.
extension TrustSection {
    func loadLog(next: [(String, String)]?) {
        let pane = tabs.panes[1]
        pane.onRetry = { [weak self] in self?.loadLog(next: nil) }
        if next == nil { pane.show(.loading) }
        callHub({ HubTrustAPI.accessLog($0, bearer: $1, next: next) }) { [weak self] r in
            guard let self = self else { return }
            switch r.flatMap(HubTrustAPI.decodeAccessLog) {
            case let .failure(e):
                if next == nil { pane.show(.failed(e.text)) } else { self.say(e.text, error: true) }
            case let .success(log):
                if next == nil { self.logRows = [] }
                self.drawLog(log, append: next != nil)
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func drawLog(_ log: HubAccessLog, append: Bool) {
        let pane = tabs.panes[1]
        if !append, log.rows.isEmpty { pane.show(.empty("아직 기록이 없어요. 나초가 연결한 서비스를 쓰면 여기에 남아요.")); return }
        var views: [NSView] = log.rows.map { r in
            var sub = [r.date + " " + r.timeText]
            if let s = r.subtitle { sub.append(s) }
            if r.count > 1 { sub.append("\(r.count)번") }
            if r.flagged { sub.append("확인이 필요해요") }
            return HubRow(title: r.title, subtitle: sub.joined(separator: " · "), trailing: r.outcome, symbol: r.flagged ? "exclamationmark.triangle" : "doc.text.magnifyingglass")
        }
        let more = log.nextQuery
        if append, let list = logList {
            list.appendRows(views, hasMore: log.hasMore)
            logRows += log.rows
        } else {
            for v in pane.contentHost.subviews { v.removeFromSuperview() }
            if let s = log.summary {
                let line = "최근 7일 · 읽기 \(s.reads) · 보내기 \(s.sends) · 바꾸기 \(s.changes)" + (s.browserWork > 0 ? " · 브라우저 작업 \(s.browserWork)" : "")
                views.insert(HubRow(title: "요약", subtitle: line, trailing: nil, symbol: "chart.bar"), at: 0)
            }
            let list = HubListView()
            list.setRows(views, hasMore: log.hasMore)
            HubKit.pin(list, in: pane.contentHost)
            logList = list
            logRows = log.rows
            pane.show(.content)
        }
        logList?.onLoadMore = { [weak self] in self?.loadLog(next: more) }
    }
}
