import AppKit
import NachoComboCore

/// 예약(C3): 목록 → 상세(일시정지·지금 실행·시험 실행·담당 바꾸기·삭제) → 실행 기록. NACHO-272.
/// 지금 실행·시험 실행은 크레딧을 쓴다 → 누르기 전에 확인창(「크레딧을 씁니다」+ 남은 크레딧). 삭제는 확인창 두 번.
/// 쓰기 요청은 섹션을 옮겨도 결과(토스트·갱신)가 사라지지 않게 섹션과 클라이언트를 요청이 끝날 때까지 붙든다.
final class SchedulesSection: HubSectionBase {
    enum Screen: Equatable {
        case list
        case detail(String)
        case runLog(String, String)
        case transfer(String)
    }

    private(set) var screen: Screen = .list
    private(set) var list: HubScheduleList?
    private(set) var current: HubSchedule?
    /// 상세를 열 때 함께 읽은 남은 크레딧(확인창에 쓴다). 못 읽었으면 nil.
    private(set) var remainingCredits: Int?
    private(set) var runLog: HubScheduleRunLog?
    private(set) var transferChoices: [HubAgentChoice] = []
    /// 쓰기가 가는 중이면 다른 쓰기는 막는다(같은 요청이 두 번 가지 않게).
    private(set) var busy = false

    init() { super.init(id: .schedules) }

    // MARK: load

    override func load() {
        switch screen {
        case .list: loadList()
        case let .detail(id): loadDetail(id)
        case let .runLog(id, run): loadRunLog(id, run)
        case let .transfer(id): loadTransfer(id)
        }
    }

    override func activate(_ ctx: HubContext) {
        screen = .list   // 섹션에 들어올 때마다 목록에서 시작
        super.activate(ctx)
    }

    /// 읽기·쓰기 공통 실행기. `client`와 `self`를 끝날 때까지 붙들고, 결과는 메인에서 `done`으로 준다.
    private func call<T>(_ build: @escaping (ServerEndpoint, String?) -> PetHTTPRequest,
                         decode: @escaping (PetHTTPResponse) -> Result<T, PetAPIError>,
                         done: @escaping (Result<T, PetAPIError>) -> Void) {
        guard let client = ctx.client else { done(.failure(.signedOut)); return }
        let endpoint = client.endpoint
        client.send({ build(endpoint, $0) }) { result in
            // 일부러 client·self를 강하게 잡는다: 사용자가 다른 섹션으로 옮겨도 결과가 버려지지 않게.
            _ = client
            self.onMain {
                switch result {
                case let .failure(e): done(.failure(e))
                case let .success(resp): done(decode(resp))
                }
            }
        }
    }

    private func loadList() {
        guard ctx.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        call({ HubSchedulesAPI.list($0, bearer: $1) }, decode: HubSchedulesAPI.decodeList) { [weak self] result in
            guard let self = self, self.screen == .list else { return }
            switch result {
            case let .failure(e): self.state.show(.failed(e.text))
            case let .success(l): self.show(list: l)
            }
        }
    }

    private func loadDetail(_ id: String) {
        guard ctx.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        // 남은 크레딧도 같이 읽어 둔다(지금 실행 확인창이 바로 뜨도록).
        call({ HubAPI.get($0, "/api/v1/me/usage", bearer: $1) }, decode: { (r: PetHTTPResponse) -> Result<Int?, PetAPIError> in
            HubAPI.empty(r).map { PetServerAPI.decodeUsage(r.body)?.remaining }
        }) { [weak self] result in
            if case let .success(n) = result { self?.remainingCredits = n }
        }
        call({ HubSchedulesAPI.get($0, id: id, bearer: $1) }, decode: HubSchedulesAPI.decodeSchedule) { [weak self] result in
            guard let self = self, self.screen == .detail(id) else { return }
            switch result {
            case let .failure(e):
                if e.isNotFound { self.gone() } else { self.state.show(.failed(HubScheduleText.failure(e, reason: nil, action: .read))) }
            case let .success(s): self.showDetail(s)
            }
        }
    }

    private func loadRunLog(_ id: String, _ run: String) {
        state.show(.loading)
        call({ HubSchedulesAPI.runLog($0, id: id, runID: run, bearer: $1) }, decode: HubSchedulesAPI.decodeRunLog) { [weak self] result in
            guard let self = self, self.screen == .runLog(id, run) else { return }
            switch result {
            case let .failure(e):
                if e.isNotFound { self.go(.detail(id)) } else { self.state.show(.failed(e.text)) }
            case let .success(l): self.showRunLog(l)
            }
        }
    }

    private func loadTransfer(_ id: String) {
        guard let s = current, s.id == id else { go(.detail(id)); return }
        state.show(.loading)
        call({ HubSchedulesAPI.agents($0, bearer: $1) }, decode: { HubSchedulesAPI.decodeAgentChoices($0, excluding: s.agentID) }) { [weak self] result in
            guard let self = self, self.screen == .transfer(id) else { return }
            switch result {
            case let .failure(e): self.state.show(.failed(e.text))
            case let .success(c): self.showTransfer(s, choices: c)
            }
        }
    }

    func go(_ next: Screen) {
        screen = next
        load()
    }

    /// 예약이 이미 없다: 목록으로 돌아가 알린다.
    private func gone() {
        ctx.toast("이미 삭제된 예약이에요.", true)
        go(.list)
    }

    // MARK: 그리기(시험·캡처가 직접 부른다)

    private func draw(_ views: [NSView]) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        HubKit.pin(parts.scroll, in: host)
        for v in views { parts.stack.addArrangedSubview(v) }
        HubKit.fill(parts.stack, views)
        state.show(.content)
    }

    private func field(_ name: String, _ value: String) -> NSView {
        HubKit.vstack([HubKit.label(name, font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(value)], spacing: Double(PetTokens.Space.xxs))
    }

    private func back(_ title: String, to s: Screen) -> NSView {
        HubKit.hstack([HubKit.secondaryButton(title, symbol: "chevron.left") { [weak self] in self?.go(s) }])
    }

    func show(list l: HubScheduleList) {
        screen = .list
        list = l
        if l.isEmpty {
            state.show(.empty("아직 예약이 없어요. 나초에게 「매일 아침 새 메일을 확인해 줘」처럼 맡겨 보세요."))
            return
        }
        var views: [NSView] = [HubKit.hstack([HubKit.label("예약", font: PetTheme.title),
                                              HubKit.secondaryButton("새로고침", symbol: "arrow.clockwise") { [weak self] in self?.reload() }])]
        func group(_ title: String, _ items: [HubSchedule]) {
            guard !items.isEmpty else { return }
            views.append(HubKit.label(title, font: PetTheme.caption, color: PetTheme.secondary))
            for s in items { views.append(row(s)) }
        }
        group("한 번 (\(l.active.filter { $0.recurrence == "once" }.count))", l.active.filter { $0.recurrence == "once" })
        group("반복 (\(l.active.filter { $0.recurrence != "once" }.count))", l.active.filter { $0.recurrence != "once" })
        group("일시 정지", l.paused)
        draw(views)
    }

    private func row(_ s: HubSchedule) -> NSView {
        var sub = s.scheduleText
        if s.paused { sub += s.pausedReason == "agent_resting" ? " · 쉬는 중이라 멈춤" : " · 일시 정지" }
        else if let n = HubFormat.date(s.nextRunAt) { sub += " · 다음 실행 \(n)" }
        if let last = s.lastRunStatus, last == "failed" || last == "skipped" { sub += " · 최근 실행을 확인해 주세요" }
        let r = HubRow(title: s.title, subtitle: sub, trailing: s.agentName, symbol: "clock")
        r.onClick = { [weak self] in self?.go(.detail(s.id)) }
        return r
    }

    func showDetail(_ s: HubSchedule) {
        screen = .detail(s.id)
        current = s
        var views: [NSView] = [back("예약 목록", to: .list), HubKit.label(s.headerTitle, font: PetTheme.title)]
        if s.title != s.headerTitle { views.append(field("제목", s.title)) }
        views.append(field("맡은 나초", s.agentName))
        views.append(field("할 일", s.actionLines.isEmpty ? s.actionText : s.actionLines.joined(separator: "\n")))
        views.append(field("주기", s.scheduleText))
        if s.paused {
            views.append(field("지금은", s.pausedReason == "agent_resting" ? "쉬는 중이라 멈춤" : "일시 정지"))
        } else if let n = HubFormat.date(s.nextRunAt) {
            views.append(field("다음 실행", n))
        }
        if s.estimateMax > 0 {
            views.append(field("크레딧", "1회 약 \(PetText.number(s.estimateMin))~\(PetText.number(s.estimateMax)) · \(s.monthlyEstimateText)"
                                + (s.overPlanWarning ? "\n요금제 한 달 크레딧을 넘을 수 있어요." : "")))
        }
        if let c = HubScheduleText.credentialNotice(s.credentialMode) { views.append(field("승인", c)) }
        if let w = s.approvalWaitText, !w.isEmpty { views.append(field("승인 대기", "승인 없으면 멈춰요. \(w). 만료되면 실행하지 않아요.")) }
        if let n = noteForTest(s) { views.append(HubKit.label(n, font: PetTheme.caption, color: PetTheme.secondary)) }

        var actions: [NSView] = []
        if !s.registered {
            actions.append(HubKit.primaryButton("등록", symbol: "checkmark") { [weak self] in self?.confirmTapped() })
        }
        if HubScheduleRules.runNowAvailable(flag: HubFeatureFlags.scheduleRunNow) && s.registered {
            actions.append(HubKit.primaryButton("지금 한 번 실행", symbol: "play.fill") { [weak self] in self?.runNowTapped() })
            if s.testUnavailableReason == nil {
                actions.append(HubKit.secondaryButton("시험 실행", symbol: "testtube.2") { [weak self] in self?.testTapped() })
            }
        }
        if s.registered, HubScheduleRules.canPause(s) {
            actions.append(HubKit.secondaryButton(HubScheduleRules.pauseTitle(s), symbol: s.paused ? "play" : "pause") { [weak self] in self?.pauseTapped() })
        }
        actions.append(HubKit.secondaryButton("담당 바꾸기", symbol: "arrow.left.arrow.right") { [weak self] in self?.go(.transfer(s.id)) })
        if s.deletable {
            actions.append(HubKit.primaryButton("삭제", symbol: "trash", danger: true) { [weak self] in self?.deleteTapped() })
        }
        views.append(HubKit.hstack(actions))
        if s.registered, !s.paused, HubScheduleRules.canPause(s) {
            views.append(HubKit.label("일시 정지해도 진행 중인 실행은 멈추지 않고 다음 실행부터 적용돼요.", font: PetTheme.caption, color: PetTheme.secondary))
        }

        views.append(HubKit.label("실행 기록", font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium)))
        if s.runs.isEmpty {
            views.append(HubKit.label("아직 실행한 적이 없어요.", font: PetTheme.caption, color: PetTheme.secondary))
        }
        for r in s.runs {
            var sub = HubScheduleText.runStatus(r.status)
            if let k = r.skippedReason { sub += " · " + HubScheduleText.skipped(k) }
            let rr = HubRow(title: HubFormat.date(r.startedAt) ?? r.startedAt, subtitle: sub)
            rr.onClick = { [weak self] in self?.go(.runLog(s.id, r.runID)) }
            views.append(rr)
        }
        draw(views)
    }

    private func noteForTest(_ s: HubSchedule) -> String? {
        if let why = s.testUnavailableReason, !why.isEmpty { return "시험 실행을 할 수 없어요: \(why)" }
        return s.registered ? "시험 실행은 밖으로 나가는 행동 없이 승인이 필요한 단계 앞에서 멈춰요. 이것도 크레딧을 써요." : nil
    }

    func showRunLog(_ l: HubScheduleRunLog) {
        runLog = l
        var views: [NSView] = [back("예약 상세", to: .detail(l.scheduleID)), HubKit.label(l.dateText, font: PetTheme.title),
                               field("상태", HubScheduleText.runStatus(l.status))]
        if let k = l.skippedReason { views.append(field("건너뛴 이유", HubScheduleText.skipped(k))) }
        if l.status == "stopped_at_cap" { views.append(field("멈춤", "상한에서 멈추고 여기까지의 결과를 저장했어요. 다음 실행도 같은 상한을 써요.")) }
        if let f = l.failureMessage, !f.isEmpty { views.append(field("실패", f)) }
        if !l.resultLines.isEmpty { views.append(field("결과", l.resultLines.joined(separator: "\n"))) }
        if l.creditUsed > 0 { views.append(field("쓴 크레딧", PetText.number(l.creditUsed))) }
        if let n = HubFormat.date(l.nextRunAt) { views.append(field("다음 실행", n)) }
        if !l.logLines.isEmpty { views.append(field("진행 기록", l.logLines.joined(separator: "\n"))) }
        draw(views)
    }

    func showTransfer(_ s: HubSchedule, choices: [HubAgentChoice]) {
        transferChoices = choices
        var views: [NSView] = [back("예약 상세", to: .detail(s.id)), HubKit.label("담당 바꾸기", font: PetTheme.title),
                               HubKit.label("승인 규칙은 따라가지 않아요. 바꾼 뒤 등록 내용을 다시 확인해 주세요.", color: PetTheme.secondary)]
        if choices.isEmpty { views.append(HubKit.label("바꿀 수 있는 다른 나초가 없어요.", font: PetTheme.caption, color: PetTheme.secondary)) }
        for c in choices {
            let r = HubRow(title: c.name, symbol: "pawprint")
            r.onClick = { [weak self] in self?.transfer(to: c) }
            views.append(r)
        }
        draw(views)
    }

    // MARK: 동작

    private func confirmSteps(_ steps: [HubScheduleStep]) -> [HubConfirmStep] {
        steps.map { HubConfirmStep(title: $0.title, message: $0.message, confirmTitle: $0.confirmTitle, destructive: $0.destructive) }
    }

    /// 쓰기 한 건: 가는 중이면 막고, 끝나면 `after`로 결과를 처리한다.
    private func write<T>(_ action: HubScheduleAction, build: @escaping (ServerEndpoint, String?) -> PetHTTPRequest,
                          decode: @escaping (PetHTTPResponse) -> Result<T, PetAPIError>, success: @escaping (T) -> Void) {
        guard !busy else { return }
        busy = true
        call(build, decode: decode) { result in
            self.busy = false
            switch result {
            case let .success(v): success(v)
            case let .failure(e): self.fail(e, action)
            }
        }
    }

    private func fail(_ e: PetAPIError, _ action: HubScheduleAction) {
        ctx.toast(HubScheduleText.failure(e, reason: nil, action: action), true)
        if e.isNotFound && action != .transfer { go(.list); return }
        // 답이 없거나 낡은 값이면 지금 상태를 다시 읽는다(다시 누르면 두 번 갈 수 있다).
        if e.code == "outcome_unknown" || e.code == "estimate_changed" || e.isVersionConflict || e.status == 0 { load() }
    }

    func runNowTapped() {
        guard let s = current, HubFeatureFlags.scheduleRunNow else { return }
        ctx.confirm(confirmSteps([HubScheduleRules.runNowStep(s, remaining: remainingCredits)])) { [self] in
            write(.runNow, build: { HubSchedulesAPI.runNow($0, id: s.id, expectedEstimateID: s.estimateID, bearer: $1) },
                  decode: HubSchedulesAPI.decodeStartedTask) { _ in
                self.ctx.toast("실행을 시작했어요. 작업에서 진행을 볼 수 있어요.", false)
                self.refreshDetail(s.id)
            }
        }
    }

    func testTapped() {
        guard let s = current, HubFeatureFlags.scheduleRunNow, s.testUnavailableReason == nil else { return }
        var step = HubScheduleRules.runNowStep(s, remaining: remainingCredits)
        step.title = "시험 실행"
        step.message = "시험 실행은 밖으로 나가는 행동 없이 승인 직전까지만 해요. " + step.message
        ctx.confirm(confirmSteps([step])) { [self] in
            write(.test, build: { HubSchedulesAPI.test($0, id: s.id, bearer: $1) }, decode: HubSchedulesAPI.decodeStartedTask) { _ in
                self.ctx.toast("시험 실행을 시작했어요.", false)
                self.refreshDetail(s.id)
            }
        }
    }

    func pauseTapped() {
        guard let s = current, HubScheduleRules.canPause(s) else { return }
        write(.pause, build: { HubSchedulesAPI.pause($0, id: s.id, paused: !s.paused, bearer: $1) }, decode: HubSchedulesAPI.decodeOk) { updated in
            self.ctx.toast(updated.paused ? "일시 정지했어요." : "다시 시작했어요.", false)
            if self.screen == .detail(s.id) { self.showDetail(updated) } else { self.current = updated }
        }
    }

    func confirmTapped() {
        guard let s = current, !s.registered else { return }
        write(.confirm, build: { HubSchedulesAPI.confirm($0, id: s.id, bearer: $1) }, decode: HubSchedulesAPI.decodeOk) { updated in
            self.ctx.toast("등록했어요.", false)
            if self.screen == .detail(s.id) { self.showDetail(updated) } else { self.current = updated }
        }
    }

    func deleteTapped() {
        guard let s = current, s.deletable else { return }
        ctx.confirm(confirmSteps(HubScheduleRules.deleteSteps(s))) { [self] in
            write(.delete, build: { HubSchedulesAPI.remove($0, id: s.id, bearer: $1) }, decode: HubSchedulesAPI.decodeDeleted) { _ in
                self.current = nil
                self.ctx.toast("예약을 지웠어요.", false)
                self.go(.list)
            }
        }
    }

    func transfer(to c: HubAgentChoice) {
        guard let s = current else { return }
        write(.transfer, build: { HubSchedulesAPI.transfer($0, id: s.id, agentID: c.id, bearer: $1) }, decode: HubSchedulesAPI.decodeOk) { updated in
            self.ctx.toast("담당을 \(c.name)(으)로 바꿨어요. 승인 규칙은 따라가지 않으니 내용을 다시 확인해 주세요.", false)
            self.current = updated
            self.go(.detail(s.id))
        }
    }

    private func refreshDetail(_ id: String) {
        if screen == .detail(id) { loadDetail(id) }
    }
}

