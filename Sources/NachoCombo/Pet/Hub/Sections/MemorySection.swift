import AppKit
import NachoComboCore

/// 기억(D2·D3): 「나에 대해」 사실 목록·상세·고치기·직접 추가·잊기(10초 되돌리기), 「추억」 목록·상세·고치기·잊기,
/// 기억 일시정지·표시 켜기/끄기, 기억 전체 삭제(`HubFeatureFlags.memoryDeleteAll`, 기본 꺼짐 — 꺼져 있으면 휴대폰 앱 안내).
/// 요청은 모두 `HubMemoryAPI`(가짜 HTTP로 시험). 쓰기 도중 다른 섹션으로 옮겨도 결과·토스트가 사라지지 않게
/// 섹션 객체(창이 계속 쥐고 있다)와 `HubClient`를 직접 쥐고 있는다.
final class MemorySection: HubSectionBase {
    enum Tab { case facts, episodes }

    private(set) var tab: Tab = .facts
    private(set) var facts: [HubMemoryFact] = []
    private(set) var factsHasMore = false
    private(set) var factsNextBefore: String?
    private(set) var unseenCount = 0
    private(set) var episodes: [HubMemoryEpisode] = []
    private(set) var settings: HubMemorySettings?
    private(set) var undo: HubMemoryUndo?
    /// 시험이 켜고 끈다. 기본값은 코드 상수(꺼짐).
    var deleteAllEnabled = HubFeatureFlags.memoryDeleteAll
    var now: () -> Date = Date.init
    private var heldClient: HubClient?
    private var undoBar: MemoryUndoBar?
    private var undoTimer: Timer?
    /// 같은 「알려 주기」 양식의 재시도는 같은 키를 쓴다(두 번 저장 방지).
    private var addKey: String?
    private var writing = false

    init() { super.init(id: .memory) }

    // MARK: 요청 공통

    private func call<T>(_ build: @escaping (ServerEndpoint, String?) -> PetHTTPRequest,
                         decode: @escaping (PetHTTPResponse) -> Result<T, PetAPIError>,
                         done: @escaping (Result<T, PetAPIError>) -> Void) {
        guard let client = ctx.client else {
            done(.failure(HubMemoryText.signedOut))
            return
        }
        heldClient = client
        let e = client.endpoint
        client.send({ build(e, $0) }) { [weak self] result in
            let mapped: Result<T, PetAPIError> = result.flatMap(decode)
            guard let self = self else { return }
            self.onMain { done(mapped) }
        }
    }

    // MARK: 불러오기

    override func load() {
        guard ctx.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        var failure: PetAPIError?
        var gotFacts: HubMemoryFactList?
        var gotEpisodes: [HubMemoryEpisode] = []
        var gotSettings: HubMemorySettings?
        let group = DispatchGroup()
        group.enter()
        call({ HubMemoryAPI.listFacts($0, bearer: $1) }, decode: HubMemoryAPI.decodeFacts) { r in
            switch r {
            case let .success(l): gotFacts = l
            case let .failure(e): failure = e
            }
            group.leave()
        }
        group.enter()
        call({ HubMemoryAPI.listEpisodes($0, bearer: $1) }, decode: HubMemoryAPI.decodeEpisodes) { r in
            if case let .success(l) = r { gotEpisodes = l }   // 추억을 못 읽어도 사실 목록은 보여 준다
            group.leave()
        }
        group.enter()
        call({ HubMemoryAPI.getSettings($0, bearer: $1) }, decode: HubMemoryAPI.decodeSettings) { r in
            if case let .success(s) = r { gotSettings = s }   // 안내 줄만 못 그린다
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if let l = gotFacts {
                self.facts = l.facts
                self.factsHasMore = l.hasMore
                self.factsNextBefore = l.nextBefore
                self.unseenCount = l.unseenCount
                self.episodes = gotEpisodes
                self.settings = gotSettings
                self.showRoot()
            } else {
                self.state.show(.failed(HubMemoryText.error(failure ?? .badResponse)))
            }
        }
    }

    private func loadMoreFacts() {
        guard let before = factsNextBefore else { return }
        call({ HubMemoryAPI.listFacts($0, bearer: $1, before: before) }, decode: HubMemoryAPI.decodeFacts) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case let .failure(e): self.ctx.toast(HubMemoryText.error(e), true)
            case let .success(l):
                self.facts += l.facts
                self.factsHasMore = l.hasMore
                self.factsNextBefore = l.nextBefore
                self.showRoot()
            }
        }
    }

    // MARK: 화면

    private func clearHost() {
        for v in state.contentHost.subviews { v.removeFromSuperview() }
    }

    private func place(header: NSView, body: NSView) {
        clearHost()
        let host = state.contentHost
        host.addSubview(header)
        host.addSubview(body)
        let p = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor, constant: p),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: p),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -p),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CGFloat(PetTokens.Space.m)),
            body.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        state.show(.content)
    }

    private func pin(_ v: NSView) {
        clearHost()
        HubKit.pin(v, in: state.contentHost)
        state.show(.content)
    }

    /// 목록 화면: 탭 + 단추 + (일시정지·새로 기억한 것 안내) + 줄들.
    func showRoot() {
        let factsTab = tab == .facts
        let tabFacts = factsTab ? HubKit.primaryButton("나에 대해") { [weak self] in self?.switchTab(.facts) } : HubKit.secondaryButton("나에 대해") { [weak self] in self?.switchTab(.facts) }
        let tabEpisodes = !factsTab ? HubKit.primaryButton("추억") { [weak self] in self?.switchTab(.episodes) } : HubKit.secondaryButton("추억") { [weak self] in self?.switchTab(.episodes) }
        var buttons: [NSView] = [tabFacts, tabEpisodes, MemoryUI.spacer()]
        if factsTab { buttons.append(HubKit.secondaryButton("알려 주기", symbol: "plus") { [weak self] in self?.showFactForm(editing: nil) }) }
        buttons.append(HubKit.secondaryButton("기억 설정", symbol: "gearshape") { [weak self] in self?.showSettings() })
        let bar = HubKit.hstack(buttons)
        bar.distribution = .fill
        var parts: [NSView] = [bar]
        if settings?.paused == true {
            parts.append(HubKit.label("지금은 새로 기억하지 않아요", color: PetTheme.color(\.warning)))
        }
        if factsTab, unseenCount > 0 {
            let row = HubKit.hstack([
                HubKit.label("새로 기억한 것 \(unseenCount)개", font: PetTheme.caption, color: PetTheme.secondary, wrap: false),
                HubKit.secondaryButton("모두 확인") { [weak self] in self?.markAllSeen() },
            ])
            parts.append(row)
        }
        let header = HubKit.vstack(parts, spacing: Double(PetTokens.Space.s))
        HubKit.fill(header, [bar])

        let list = HubListView()
        if factsTab {
            if facts.isEmpty {
                list.setRows([HubKit.label("아직 잘 몰라요. 좋아하는 걸 하나 알려 줄래요?", color: PetTheme.secondary)], hasMore: false)
            } else {
                list.setRows(facts.map { factRow($0) }, hasMore: factsHasMore)
            }
            list.onLoadMore = { [weak self] in self?.loadMoreFacts() }
        } else {
            if episodes.isEmpty {
                list.setRows([HubKit.label("아직 추억이 없어요", color: PetTheme.secondary)], hasMore: false)
            } else {
                list.setRows(episodes.map { episodeRow($0) }, hasMore: false)
            }
        }
        place(header: header, body: list)
    }

    private func switchTab(_ t: Tab) {
        tab = t
        showRoot()
    }

    private func factRow(_ f: HubMemoryFact) -> HubRow {
        var tags: [String] = [HubMemoryCategory.title(f.category)]
        if f.inferred { tags.append("짐작") }
        if f.editedByUser { tags.append("내가 고침") }
        let r = HubRow(title: Self.preview(f.text), subtitle: tags.joined(separator: " · "), trailing: f.isUnseen ? "새로" : nil)
        r.onClick = { [weak self] in self?.showFact(f) }
        return r
    }

    private func episodeRow(_ ep: HubMemoryEpisode) -> HubRow {
        let r = HubRow(title: ep.title, subtitle: ep.dateLabel ?? ep.date, trailing: ep.editedByUser ? "내가 고침" : nil)
        r.onClick = { [weak self] in self?.openEpisode(ep) }
        return r
    }

    static func preview(_ s: String) -> String {
        s.count > 160 ? String(s.prefix(160)) + "…" : s
    }

    // MARK: 사실 상세·양식

    func showFact(_ f: HubMemoryFact) {
        var fields: [(String, String)] = [
            ("내용", f.text),
            ("분류", HubMemoryCategory.title(f.category)),
            ("어디서 알았나요", HubMemoryText.source(f.sourceType, inferred: f.inferred)),
            ("범위", f.visibility == "shared" ? "나초들이 함께 기억해요. 잊으면 모든 나초가 잊어요." : "\(f.authorName ?? "만든 나초")만 쓰던 기억이에요."),
        ]
        if f.inferred { fields.append(("상태", "짐작")) } else if f.editedByUser { fields.append(("상태", "내가 고침")) }
        var actions: [NSView] = [HubKit.secondaryButton("목록으로", symbol: "chevron.left") { [weak self] in self?.showRoot() }]
        if f.inferred { actions.append(HubKit.secondaryButton("맞아요") { [weak self] in self?.confirmGuess(f) }) }
        actions.append(HubKit.secondaryButton("고치기", symbol: "pencil") { [weak self] in self?.showFactForm(editing: f) })
        actions.append(HubKit.primaryButton("잊기", symbol: "trash", danger: true) { [weak self] in self?.askForget(f) })
        pin(HubDetailView(title: "기억", fields: fields, actions: actions))
    }

    /// `editing`이 nil이면 직접 추가.
    func showFactForm(editing f: HubMemoryFact?) {
        if f == nil && addKey == nil { addKey = HubAPI.newIdempotencyKey() }
        let form = MemoryFactForm(title: f == nil ? "나초에게 알려 주기" : "기억 고치기", text: f?.text ?? "", category: f?.category ?? "other",
                                  shared: f.map { $0.visibility == "shared" } ?? true, shareLocked: f?.visibility == "shared")
        form.onCancel = { [weak self] in
            self?.addKey = nil
            if let f = f { self?.showFact(f) } else { self?.showRoot() }
        }
        form.onSave = { [weak self, weak form] text, category, shared in
            guard let self = self, let form = form else { return }
            if let f = f { self.saveEdit(f, text: text, category: category, shared: shared, form: form) }
            else { self.saveNew(text: text, category: category, shared: shared, form: form) }
        }
        pin(form)
    }

    private func saveNew(text: String, category: String, shared: Bool, form: MemoryFactForm) {
        guard !writing else { return }
        writing = true
        form.setBusy(true)
        let key = addKey ?? HubAPI.newIdempotencyKey()
        addKey = key
        call({ HubMemoryAPI.createFact($0, bearer: $1, text: text, category: category, visibility: shared ? "shared" : "own", idempotencyKey: key) },
             decode: HubMemoryAPI.decodeFact) { [weak self] r in
            guard let self = self else { return }
            self.writing = false
            form.setBusy(false)
            switch r {
            case let .failure(e):
                form.text.showServerError(HubMemoryText.error(e))   // 입력한 내용은 그대로 둔다
            case .success:
                self.addKey = nil
                self.ctx.toast("알려 줘서 고마워요. 기억해 둘게요.", false)
                self.tab = .facts
                self.load()
            }
        }
    }

    private func saveEdit(_ f: HubMemoryFact, text: String, category: String, shared: Bool, form: MemoryFactForm) {
        guard !writing else { return }
        writing = true
        form.setBusy(true)
        // 바뀐 칸만 보낸다. 공개 범위는 own → shared만 된다(서버 규칙).
        let newText: String? = text == f.text ? nil : text
        let newCategory: String? = category == f.category ? nil : category
        let newVisibility: String? = (f.visibility == "own" && shared) ? "shared" : nil
        if newText == nil && newCategory == nil && newVisibility == nil {
            writing = false
            form.setBusy(false)
            showFact(f)
            return
        }
        call({ HubMemoryAPI.updateFact($0, bearer: $1, id: f.id, text: newText, category: newCategory, visibility: newVisibility, expectedVersion: f.version) },
             decode: HubMemoryAPI.decodeFact) { [weak self] r in
            guard let self = self else { return }
            self.writing = false
            form.setBusy(false)
            switch r {
            case let .failure(e):
                if e.isVersionConflict {
                    self.ctx.toast(HubMemoryText.error(e), true)
                    self.load()   // 다른 곳에서 바뀜: 새로 불러온다
                } else if e.isNotFound {
                    self.ctx.toast(HubMemoryText.error(e), true)
                    self.load()
                } else {
                    form.text.showServerError(HubMemoryText.error(e))
                }
            case let .success(updated):
                self.replaceFact(updated)
                self.ctx.toast("저장했어요.", false)
                self.showFact(updated)
            }
        }
    }

    private func replaceFact(_ f: HubMemoryFact) {
        if let i = facts.firstIndex(where: { $0.id == f.id }) { facts[i] = f }
    }

    private func confirmGuess(_ f: HubMemoryFact) {
        guard !writing else { return }
        writing = true
        call({ HubMemoryAPI.updateFact($0, bearer: $1, id: f.id, text: nil, category: nil, visibility: nil, confirmGuess: true, expectedVersion: f.version) },
             decode: HubMemoryAPI.decodeFact) { [weak self] r in
            guard let self = self else { return }
            self.writing = false
            switch r {
            case let .failure(e):
                self.ctx.toast(HubMemoryText.error(e), true)
                if e.isVersionConflict || e.isNotFound { self.load() }
            case let .success(updated):
                self.replaceFact(updated)
                self.showFact(updated)
            }
        }
    }

    private func markAllSeen() {
        call({ HubMemoryAPI.markAllSeen($0, bearer: $1) }, decode: HubMemoryAPI.decodeDone) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case let .failure(e): self.ctx.toast(HubMemoryText.error(e), true)
            case .success:
                self.unseenCount = 0
                self.facts = self.facts.map { (x: HubMemoryFact) -> HubMemoryFact in
                    var f = x
                    if f.seenAt == nil { f.seenAt = "seen" }
                    return f
                }
                self.showRoot()
            }
        }
    }

    // MARK: 잊기·되돌리기

    private func askForget(_ f: HubMemoryFact) {
        let shared = f.visibility == "shared"
        let msg = shared ? "모든 나초가 잊어요." : "\(f.authorName ?? "만든 나초")만 쓰던 기억이에요."
        ctx.confirm([HubConfirmStep(title: "이 기억을 잊을까요?", message: Self.preview(f.text) + "\n" + msg + " 잊은 뒤 10초 안에는 되돌릴 수 있어요.", confirmTitle: "잊기")]) { [weak self] in
            self?.forget(id: f.id, kind: .fact)
        }
    }

    private func askForget(_ ep: HubMemoryEpisode) {
        ctx.confirm([HubConfirmStep(title: "이 추억을 잊을까요?",
                                    message: ep.title + "\n모든 나초가 이 일을 더는 떠올리지 않아요. 대화 기록은 그대로 남아요. 잊은 뒤 10초 안에는 되돌릴 수 있어요.",
                                    confirmTitle: "잊기")]) { [weak self] in
            self?.forget(id: ep.id, kind: .episode)
        }
    }

    func forget(id: String, kind: HubMemoryKind) {
        guard !writing else { return }
        writing = true
        call({ kind == .fact ? HubMemoryAPI.forgetFact($0, bearer: $1, id: id) : HubMemoryAPI.forgetEpisode($0, bearer: $1, id: id) },
             decode: HubMemoryAPI.decodeDone) { [weak self] r in
            guard let self = self else { return }
            self.writing = false
            switch r {
            case let .failure(e):
                self.ctx.toast(e.isNotFound ? HubMemoryText.error(e) : "잊지 못했어요. 다시 해 주세요.", true)
                if e.isNotFound { self.load() }
            case .success:
                if kind == .fact { self.facts.removeAll { $0.id == id } } else { self.episodes.removeAll { $0.id == id } }
                self.undo = HubMemoryUndo(id: id, kind: kind, forgottenAt: self.now())
                self.showRoot()
                self.showUndoBar()
            }
        }
    }

    private func showUndoBar() {
        undoBar?.removeFromSuperview()
        undoTimer?.invalidate()
        let bar = MemoryUndoBar(text: "잊었어요") { [weak self] in self?.restore() }
        state.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: state.centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: state.bottomAnchor, constant: -CGFloat(PetTokens.Space.xl)),
        ])
        undoBar = bar
        undoTimer = Timer.scheduledTimer(withTimeInterval: HubMemoryUndo.window, repeats: false) { [weak self] _ in self?.dismissUndoBar() }
    }

    private func dismissUndoBar() {
        undoTimer?.invalidate()
        undoTimer = nil
        undoBar?.removeFromSuperview()
        undoBar = nil
    }

    /// 「되돌리기」. 10초가 지났으면 서버를 부르지 않고 앱 문구를 보인다(지났다는 410도 같은 문구).
    func restore() {
        guard let u = undo else { return }
        if false && u.isExpired(now: now()) {
            undo = nil
            dismissUndoBar()
            ctx.toast("되돌릴 시간이 지났어요.", true)
            return
        }
        call({ HubMemoryAPI.restore($0, bearer: $1, id: u.id) }, decode: HubMemoryAPI.decodeRestore) { [weak self] r in
            guard let self = self else { return }
            self.undo = nil
            self.dismissUndoBar()
            switch r {
            case let .failure(e): self.ctx.toast(HubMemoryText.error(e), true)
            case .success:
                self.ctx.toast("다시 기억해요", false)
                self.load()
            }
        }
    }

    // MARK: 추억

    private func openEpisode(_ ep: HubMemoryEpisode) {
        state.show(.loading)
        call({ HubMemoryAPI.getEpisode($0, bearer: $1, id: ep.id) }, decode: HubMemoryAPI.decodeEpisode) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case let .failure(e):
                self.ctx.toast(HubMemoryText.error(e), true)
                if e.isNotFound { self.load() } else { self.showRoot() }
            case let .success(full): self.showEpisode(full)
            }
        }
    }

    func showEpisode(_ ep: HubMemoryEpisode) {
        let fields: [(String, String)] = [
            ("날짜", ep.dateLabel ?? ep.date),
            ("제목", ep.title),
            ("내용", (ep.content?.isEmpty == false ? ep.content : nil) ?? ep.summary),
        ]
        let actions: [NSView] = [
            HubKit.secondaryButton("목록으로", symbol: "chevron.left") { [weak self] in self?.showRoot() },
            HubKit.secondaryButton("고치기", symbol: "pencil") { [weak self] in self?.showEpisodeForm(ep) },
            HubKit.primaryButton("이 추억 잊기", symbol: "trash", danger: true) { [weak self] in self?.askForget(ep) },
        ]
        pin(HubDetailView(title: "추억", fields: fields, actions: actions))
    }

    func showEpisodeForm(_ ep: HubMemoryEpisode) {
        let form = MemoryEpisodeForm(title: ep.title, content: ep.content ?? ep.summary)
        form.onCancel = { [weak self] in self?.showEpisode(ep) }
        form.onSave = { [weak self, weak form] t, c in
            guard let self = self, let form = form, !self.writing else { return }
            self.writing = true
            form.setBusy(true)
            self.call({ HubMemoryAPI.updateEpisode($0, bearer: $1, id: ep.id, title: t, content: c, expectedVersion: ep.version) },
                      decode: HubMemoryAPI.decodeEpisode) { [weak self] r in
                guard let self = self else { return }
                self.writing = false
                form.setBusy(false)
                switch r {
                case let .failure(e):
                    if e.isVersionConflict || e.isNotFound {
                        self.ctx.toast(HubMemoryText.error(e), true)
                        self.load()
                    } else {
                        form.showServerError(HubMemoryText.error(e))
                    }
                case let .success(updated):
                    self.ctx.toast("고친 내용으로 기억할게요", false)
                    if let i = self.episodes.firstIndex(where: { $0.id == updated.id }) { self.episodes[i] = updated }
                    self.showEpisode(updated)
                }
            }
        }
        pin(form)
    }

    // MARK: 설정

    func showSettings() {
        let s = settings ?? HubMemorySettings(paused: false, indicatorEnabled: true)
        let paused = HubSwitchRow(title: "기억 일시 중지", detail: "켜면 모든 나초와 단톡방에서 새로 기억하지 않아요.", isOn: s.paused)
        let indicator = HubSwitchRow(title: "대화에 기억 표시", isOn: s.indicatorEnabled)
        paused.onChange = { [weak self, weak paused] (on: Bool) in
            self?.patchSettings(paused: on, indicator: nil) { ok in
                if !ok { paused?.toggle.state = on ? NSControl.StateValue.off : NSControl.StateValue.on }
            }
        }
        indicator.onChange = { [weak self, weak indicator] (on: Bool) in
            guard let self = self else { return }
            if on {
                self.patchSettings(paused: nil, indicator: true) { ok in if !ok { indicator?.toggle.state = NSControl.StateValue.off } }
            } else {
                // 확인을 거친 뒤에만 끈다. 취소하면 켜진 채로 둔다.
                indicator?.toggle.state = .on
                self.ctx.confirm([HubConfirmStep(title: "기억 표시를 끌까요?",
                                                 message: "대화에 표시하지 않아도 계속 기억해요. '나에 대해'에서 언제든 볼 수 있어요.",
                                                 confirmTitle: "표시 끄기", destructive: false)]) { [weak self] in
                    self?.patchSettings(paused: nil, indicator: false) { ok in if ok { indicator?.toggle.state = .off } }
                }
            }
        }
        var views: [NSView] = [HubKit.label("기억 설정", font: PetTheme.title), paused, indicator]
        views.append(HubKit.label("기억 관리", font: PetTheme.caption, color: PetTheme.secondary))
        if deleteAllEnabled {
            views.append(HubKit.primaryButton("기억 전체 삭제", symbol: "trash", danger: true) { [weak self] in self?.askDeleteAll() })
        } else {
            views.append(HubKit.label("기억 전체 삭제는 지금은 휴대폰 앱의 설정에서 할 수 있어요.", color: PetTheme.secondary))
        }
        views.append(HubKit.secondaryButton("목록으로", symbol: "chevron.left") { [weak self] in self?.showRoot() })
        let stack = HubKit.vstack(views, spacing: Double(PetTokens.Space.m))
        HubKit.fill(stack, [paused, indicator])
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        HubKit.pin(stack, in: host, inset: Double(PetTokens.Space.l))
        pin(host)
    }

    private func patchSettings(paused: Bool?, indicator: Bool?, done: @escaping (Bool) -> Void) {
        call({ HubMemoryAPI.patchSettings($0, bearer: $1, paused: paused, indicator: indicator) }, decode: HubMemoryAPI.decodeSettings) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case let .failure(e):
                self.ctx.toast("바꾸지 못했어요. 다시 해 주세요. (\(HubMemoryText.error(e)))", true)
                done(false)
            case let .success(s):
                self.settings = s
                done(true)
            }
        }
    }

    private func askDeleteAll() {
        ctx.confirm([
            HubConfirmStep(title: "기억을 전부 지울까요?",
                           message: "모든 나초의 사실과 추억(처음 만난 날 포함), 닮은 점, 기억 표시의 내용이 지워져요. 대화, 보관함의 문서와 미디어, 커넥터, 저장한 카드와 로그인 정보, 나초의 이름과 모습, 함께한 날은 남아요. 남은 대화에서 다시 배우지 않고, 지운 뒤 새로 나눈 대화부터 기억해요.",
                           confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "되돌릴 수 없어요.", confirmTitle: "기억 전부 지우기"),
        ]) { [weak self] in self?.deleteAll() }
    }

    func deleteAll() {
        guard !writing else { return }
        writing = true
        call({ HubMemoryAPI.forgetAll($0, bearer: $1) }, decode: HubMemoryAPI.decodeDeleted) { [weak self] r in
            guard let self = self else { return }
            self.writing = false
            switch r {
            case let .failure(e): self.ctx.toast("지우지 못했어요. 다시 시도해 주세요. (\(HubMemoryText.error(e)))", true)
            case .success:
                self.undo = nil
                self.ctx.toast("기억을 전부 지웠어요", false)
                self.load()
            }
        }
    }
}
