import AppKit
import NachoComboCore

/// 작업 섹션(NACHO-271 U5): 목록(C2) → 상세·로그·이어하기·루틴 초안·지시 추가 → 계획 · 전화 모니터(B16) · 라이브 뷰(C4).
/// 시작·취소는 이미 있는 `PetServerAPI` 요청을 그대로 쓴다. 쓰기 결과는 창 토스트로 알리니 다른 섹션으로 옮겨도 사라지지 않는다.
final class TasksSection: HubSectionBase {
    init() { super.init(id: .tasks) }

    private var historyNext: [(String, String)]?
    private let list = HubListView()
    private(set) var screenName = "list"
    /// 상세 화면의 기록 자리(「기록 보기」가 채운다).
    var logsHost: NSStackView?
    /// 라이브 뷰 화면 자리(시험이 가짜 화면을 줄 때만 쓴다. 비면 WKWebView).
    var liveSurface: ((URL, TasksLiveViewPane) -> NSView)?

    override func load() {
        guard let client = ctx.client else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        screenName = "list"
        let e = client.endpoint
        // 두 요청이 모두 끝나면 한 번만 그린다(콜백은 임의의 큐에서 온다).
        let lock = NSLock()
        var pending = 2
        var listResult: Result<HubTaskList, PetAPIError>?
        var histResult: Result<HubPage, PetAPIError>?
        let done: () -> Void = { [weak self] in
            lock.lock()
            pending -= 1
            let finished = pending == 0
            lock.unlock()
            guard finished else { return }
            self?.onMain {
                guard let self = self, let lr = listResult else { return }
                switch lr {
                case let .failure(err): self.state.show(.failed(err.text))
                case let .success(tasks): self.showList(tasks, history: histResult)
                }
            }
        }
        client.send({ HubTasks.list(e, bearer: $0) }) { r in
            lock.lock(); listResult = r.flatMap { HubTasks.decodeList($0) }; lock.unlock()
            done()
        }
        client.send({ HubTasks.history(e, bearer: $0, limit: 20) }) { r in
            lock.lock(); histResult = r.flatMap { HubAPI.page($0) }; lock.unlock()
            done()
        }
    }

    // MARK: list

    /// 화면 그리기만(시험·캡처가 직접 부른다). `history`가 있으면 지난 작업은 이력(최신순)을 쓴다.
    func showList(_ tasks: HubTaskList, history: Result<HubPage, PetAPIError>?) {
        var past = tasks.recent
        var more = false
        if case let .success(page)? = history {
            past = page.items.map(HubTask.init)
            historyNext = page.nextQuery
            more = page.nextQuery != nil
        } else {
            historyNext = nil
        }
        if tasks.active.isEmpty && past.isEmpty {
            state.show(.empty("아직 맡긴 작업이 없어요\n할 일을 말해 주면 제가 맡을게요"))
            return
        }
        var rows: [NSView] = []
        let answers = tasks.active.filter { $0.needsAnswer }.count
        var summary = "\(tasks.active.count)개 진행 중"
        if answers > 0 { summary += ", \(answers)개는 답이 필요해요" }
        rows.append(HubKit.label(summary, font: PetTheme.title))
        if tasks.limit > 0 { rows.append(HubKit.label("동시에 \(tasks.running)개 하는 중 (최대 \(tasks.limit)개)", font: PetTheme.caption, color: PetTheme.secondary)) }
        rows += tasks.active.map(row)
        if !past.isEmpty {
            rows.append(HubKit.label("지난 작업", font: PetTheme.caption, color: PetTheme.secondary))
            rows += past.map(row)
        }
        list.onLoadMore = { [weak self] in self?.loadMoreHistory() }
        list.setRows(rows, hasMore: more)
        host(list)
    }

    private func row(_ t: HubTask) -> HubRow {
        var sub = t.statusText
        if let s = t.stepLine, t.state == "running" { sub += " · " + s }
        let r = HubRow(title: t.title.isEmpty ? "(제목 없음)" : t.title, subtitle: sub, trailing: t.needsAnswer ? "답하기" : HubFormat.date(t.requestedAt),
                       symbol: t.kind == "phone" ? "phone" : "checklist")
        r.onClick = { [weak self] in self?.openTask(t) }
        return r
    }

    private func loadMoreHistory() {
        guard let client = ctx.client, let next = historyNext else { return }
        let e = client.endpoint
        client.send({ HubTasks.history(e, bearer: $0, next: next, limit: 20) }) { [weak self] r in
            guard let self = self else { return }
            self.onMain {
                switch r.flatMap({ HubAPI.page($0) }) {
                case let .failure(err): self.ctx.toast(err.text, true)
                case let .success(page):
                    self.historyNext = page.nextQuery
                    self.list.appendRows(page.items.map(HubTask.init).map(self.row), hasMore: page.nextQuery != nil)
                }
            }
        }
    }

    // MARK: screens

    /// 내용 자리에 한 화면을 붙인다.
    func host(_ v: NSView, name: String = "list") {
        for s in state.contentHost.subviews { s.removeFromSuperview() }
        HubKit.pin(v, in: state.contentHost)
        screenName = name
        state.show(.content)
    }

    func backToList() { load() }

    /// 눌린 작업을 서버에서 다시 읽어 상세를 연다(읽지 못하면 목록의 값으로 연다).
    func openTask(_ t: HubTask) {
        showDetail(t)
        refreshDetail(t.id)
    }

    func refreshDetail(_ id: String) {
        guard let client = ctx.client else { return }
        let e = client.endpoint
        client.send({ HubTasks.get(e, bearer: $0, taskID: id) }) { [weak self] r in
            guard let self = self else { return }
            self.onMain {
                switch r.flatMap({ HubTasks.decodeTask($0) }) {
                case let .success(t): if self.screenName == "detail:\(id)" { self.showDetail(t) }
                case let .failure(err): if err.isNotFound { self.ctx.toast(err.text, true); self.backToList() }
                }
            }
        }
    }

    /// 쓰기 요청을 보내고 결과를 창 토스트로 알린다. 성공하면 `ok`(메인 큐).
    func write(_ build: @escaping (String?) -> PetHTTPRequest, failText: ((PetAPIError) -> String)? = nil, ok: @escaping (PetHTTPResponse) -> Void) {
        guard let client = ctx.client else { ctx.toast("로그인이 필요해요.", true); return }
        // HubClient는 토큰을 기다리는 동안 [weak self]라, 섹션을 옮겨 ctx가 바뀌어도 결과가 버려지지 않게 끝날 때까지 붙든다.
        client.send(build) { [weak self] r in
            withExtendedLifetime(client) {}
            guard let self = self else { return }
            self.onMain {
                switch r {
                case let .failure(err): self.ctx.toast(failText?(err) ?? err.text, true)
                case let .success(resp): ok(resp)
                }
            }
        }
    }
}
