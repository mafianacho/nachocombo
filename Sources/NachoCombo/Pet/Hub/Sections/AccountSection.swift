import AppKit
import NachoComboCore

fileprivate typealias Sp = PetTokens.Space

/// 계정·설정(NACHO-267 U1, 표 행 A4·A5·A6·A9·A10). 한 섹션 안에서 첫 화면과 하위 화면(이름·ID·생일·문제 신고·법적 고지)을 바꿔 보여 준다.
/// 요청은 모두 `HubAccountAPI`(Core)로 만든다. 입력 검증은 `AccountRules`(나초 앱 규칙 그대로).
/// 쓰기 요청 중에 다른 섹션으로 옮겨도 결과가 사라지지 않게, 완료 콜백이 요청 실행기(`HubClient`)를 붙들고 이 섹션 객체에 되돌아온다.
/// 하위 화면은 `AccountSection+Pages.swift`.
final class AccountSection: HubSectionBase, NSTextFieldDelegate, NSTextViewDelegate {
    enum Page { case main, name, handle, birthday, issue, legal }

    // MARK: 시험·캡처가 바꾸는 값

    /// 계정 삭제 실행 단추(`HubFeatureFlags.accountDelete`, 기본 꺼짐). 꺼져 있으면 휴대폰 앱 안내만 보인다.
    var accountDeleteEnabled = HubFeatureFlags.accountDelete
    var signOut: () -> Void = { PetHandoff.module?.signOut() }
    /// 내려받은 내 데이터를 파일로 저장한다. 저장한 위치를 돌려주고, 취소하면 nil.
    var saveExport: (AccountExportFile) -> URL? = AccountSection.saveWithPanel
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var diagnostics: () -> HubAccountAPI.Diagnostics = AccountSection.currentDiagnostics
    var today: () -> AccountRules.Day = { AccountRules.Day.today() }
    /// 핸들 입력이 멈춘 뒤 서버에 묻기까지 기다리는 시간(나초 앱 300ms).
    var handleCheckDelay: TimeInterval = 0.3

    // MARK: 상태

    var page: Page = .main
    var profile: AccountProfile?
    var privacy: AccountPrivacy?
    var privacyFailed = false
    var deletion: AccountDeletionStatus?
    var legalDocs = AccountRules.legalDocuments(clientConfig: nil)
    var saving = false
    /// 입력 칸이 바뀔 때 불리는 쪽(하위 화면이 채운다).
    var fieldChanged: (() -> Void)?
    var handleCheck: HandleCheckResult?
    var handleFailed = false
    var handleWork: DispatchWorkItem?
    var issueKey = HubAPI.newIdempotencyKey()

    init() { super.init(id: .account) }

    // MARK: 요청 도우미

    var endpoint: ServerEndpoint? { ctx?.client?.endpoint }

    /// 토큰을 붙여 보내고 결과를 메인 큐에서 돌려준다. `HubClient` 안쪽이 `[weak self]`라 여기서 붙들고 있어야 결과가 버려지지 않는다.
    func request(_ build: @escaping (String?) -> PetHTTPRequest, _ done: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        guard let client = ctx?.client else {
            done(.failure(HubAPI.error(PetHTTPResponse(status: 401))))
            return
        }
        client.send(build) { r in
            withExtendedLifetime(client) { self.onMain { done(r) } }
        }
    }

    func toast(_ text: String, error: Bool = false) { ctx?.toast(text, error) }

    // MARK: 불러오기

    override func load() {
        guard let e = endpoint else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        page = .main
        var me: Result<AccountProfile, PetAPIError>?
        var pv: Result<AccountPrivacy, PetAPIError>?
        var ds: Result<AccountDeletionStatus, PetAPIError>?
        var left = 3
        let finish: () -> Void = { [weak self] in
            left -= 1
            guard left == 0, let self = self, let me = me else { return }
            switch me {
            case let .failure(err): self.state.show(.failed(HubAccountAPI.errorText(err)))
            case let .success(p):
                self.profile = p
                if case let .success(v)? = pv { self.privacy = v; self.privacyFailed = false } else { self.privacy = nil; self.privacyFailed = true }
                if case let .success(d)? = ds { self.deletion = d } else { self.deletion = nil }
                self.showMain()
            }
        }
        request({ HubAccountAPI.me(e, bearer: $0) }) { r in me = r.flatMap(HubAccountAPI.parseMe); finish() }
        request({ HubAccountAPI.privacy(e, bearer: $0) }) { r in pv = r.flatMap(HubAccountAPI.parsePrivacy); finish() }
        request({ HubAccountAPI.deletionStatus(e, bearer: $0) }) { r in ds = r.flatMap(HubAccountAPI.parseDeletionStatus); finish() }
    }

    // MARK: 화면 도우미

    /// 한 화면의 내용을 갈아 끼운다.
    func present(_ views: [NSView], fill fills: [NSView]? = nil) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        let parts = HubKit.scrollingStack(spacing: Sp.l)
        for v in views { parts.stack.addArrangedSubview(v) }
        HubKit.fill(parts.stack, fills ?? views)
        HubKit.pin(parts.scroll, in: host)
        state.show(.content)
    }

    func heading(_ text: String) -> NSTextField { HubKit.label(text, font: PetTheme.caption, color: PetTheme.secondary) }

    /// 테두리 있는 묶음.
    func card(_ views: [NSView]) -> PetBox {
        let box = PetBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.fill = PetTheme.color(\.surface)
        box.stroke = PetTheme.color(\.edge)
        box.radius = CGFloat(PetTokens.Radius.card)
        let stack = HubKit.vstack(views, spacing: Sp.m)
        box.addSubview(stack)
        let p = CGFloat(Sp.m)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: p),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -p),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -p),
        ])
        HubKit.fill(stack, views.filter { $0 is NSTextField || $0 is HubSwitchRow })
        return box
    }

    func group(_ title: String, _ views: [NSView]) -> NSStackView {
        let g = HubKit.vstack([heading(title)] + views, spacing: Sp.s)
        HubKit.fill(g, g.arrangedSubviews.filter { !($0 is PetPill) })
        return g
    }

    /// 단추는 글자 크기에 맞춰 폭을 정한다(정하지 않으면 칸 너비만큼 늘어난다).
    func primary(_ title: String, symbol: String? = nil, danger: Bool = false, _ action: @escaping () -> Void) -> PetPill {
        sized(HubKit.primaryButton(title, symbol: symbol, danger: danger, onClick: action), title: title, symbol: symbol,
              font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium))
    }

    func secondary(_ title: String, symbol: String? = nil, _ action: @escaping () -> Void) -> PetPill {
        sized(HubKit.secondaryButton(title, symbol: symbol, onClick: action), title: title, symbol: symbol, font: PetTheme.body)
    }

    private func sized(_ p: PetPill, title: String, symbol: String?, font: NSFont) -> PetPill {
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        let icon = symbol == nil ? 0 : PetTokens.Size.icon + Sp.xs
        p.widthAnchor.constraint(equalToConstant: ceil(text + CGFloat(Sp.l * 2 + icon)) + 6).isActive = true
        return p
    }

    func buttonRow(_ buttons: [NSView]) -> NSStackView { HubKit.hstack(buttons, spacing: Sp.s) }

    func backBar() -> NSView {
        buttonRow([secondary("계정·설정", symbol: "chevron.left") { [weak self] in self?.showMain() }])
    }

    // MARK: 첫 화면

    func showMain() {
        page = .main
        guard let p = profile else { return }
        var views: [NSView] = [HubKit.label("계정·설정", font: PetTheme.title)]

        func row(_ title: String, _ value: String, _ go: Page?) -> HubRow {
            let r = HubRow(title: title, trailing: value)
            if let g = go { r.onClick = { [weak self] in self?.open(g) } }
            return r
        }
        views.append(group("프로필", [
            row("이름", p.displayName.isEmpty ? "정하지 않았어요" : p.displayName, .name),
            row("사용자 ID", p.handle.map { "@\($0)" } ?? "아직 정하지 않았어요", .handle),
            row("생일", p.birthday ?? "정하지 않았어요", .birthday),
            row("전화번호", p.phoneMasked ?? "인증 안 함", nil),
        ]))

        views.append(group("개인정보·안전", privacyViews()))
        views.append(group("내 데이터", dataViews()))
        views.append(group("도움말", [
            row("문제 신고", "", .issue),
            row("약관·법적 고지", "", .legal),
        ]))
        views.append(buttonRow([secondary("로그아웃", symbol: "rectangle.portrait.and.arrow.right") { [weak self] in self?.confirmSignOut() }]))
        present(views)
    }

    func open(_ p: Page) {
        switch p {
        case .main: showMain()
        case .name: showName()
        case .handle: showHandle()
        case .birthday: showBirthday()
        case .issue: showIssue()
        case .legal: showLegal()
        }
    }

    // MARK: 개인정보·안전 (A6)

    enum PrivacyKey { case discoverable, memoryPaused, memoryIndicator }

    func privacyViews() -> [NSView] {
        guard let pv = privacy else {
            let note = HubKit.label(privacyFailed ? "설정을 불러오지 못했어요. 눌러서 다시 시도해 주세요." : "", color: PetTheme.secondary)
            let retry = secondary("다시 시도", symbol: "arrow.clockwise") { [weak self] in self?.reload() }
            return [card([note, buttonRow([retry])])]
        }
        func sw(_ title: String, _ detail: String, _ on: Bool, _ key: PrivacyKey) -> HubSwitchRow {
            let r = HubSwitchRow(title: title, detail: detail, isOn: on)
            r.onChange = { [weak self, weak r] v in self?.setPrivacy(key, v, row: r) }
            return r
        }
        let del = secondary("연락처 매칭 자료 삭제", symbol: "trash") { [weak self] in self?.confirmDeleteContacts() }
        return [card([
            sw("전화번호로 나를 찾을 수 있게", "켜면 내 전화번호를 아는 사람이 나를 찾을 수 있어요.", pv.phoneDiscoverable, .discoverable),
            sw("기억 일시 중지", "켜면 모든 나초와 단톡방에서 새로 기억하지 않아요.", pv.memoryPaused, .memoryPaused),
            sw("대화에 기억 표시", "끄면 표시만 사라지고 기억은 계속돼요.", pv.memoryIndicatorEnabled, .memoryIndicator),
            buttonRow([del]),
        ])]
    }

    func setPrivacy(_ key: PrivacyKey, _ on: Bool, row: HubSwitchRow?) {
        guard let e = endpoint else { return }
        let build: (String?) -> PetHTTPRequest = { b in
            switch key {
            case .discoverable: return HubAccountAPI.patchPrivacy(e, bearer: b, phoneDiscoverable: on)
            case .memoryPaused: return HubAccountAPI.patchPrivacy(e, bearer: b, memoryPaused: on)
            case .memoryIndicator: return HubAccountAPI.patchPrivacy(e, bearer: b, memoryIndicatorEnabled: on)
            }
        }
        request(build) { [weak row] r in
            switch r.flatMap(HubAccountAPI.parsePrivacy) {
            case let .success(p): self.privacy = p
            case let .failure(err):
                row?.toggle.state = on ? .off : .on   // 저장하지 못했으니 이전 값으로
                self.toast("저장하지 못해서 이전 값으로 돌렸어요. " + HubAccountAPI.errorText(err), error: true)
            }
        }
    }

    func confirmDeleteContacts() {
        ctx.confirm([
            HubConfirmStep(title: "연락처 매칭 자료를 지울까요?", message: "서버의 매칭 자료를 지우고 자동 매칭을 꺼요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "되돌릴 수 없어요.", confirmTitle: "지우기"),
        ]) { [weak self] in self?.deleteContacts() }
    }

    func deleteContacts() {
        guard let e = endpoint else { return }
        request({ HubAccountAPI.deleteContactMatches(e, bearer: $0) }) { r in
            switch r.flatMap(HubAccountAPI.parseDeletedCount) {
            case .success: self.toast("자료를 지웠어요. 다시 쓰려면 친구 찾기에서 동의해 주세요.")
            case let .failure(err): self.toast("지우지 못했어요. " + HubAccountAPI.errorText(err), error: true)
            }
        }
    }

    // MARK: 내 데이터·계정 삭제 (A4)

    func dataViews() -> [NSView] {
        var inner: [NSView] = [
            HubKit.label("대화, 기억, 일, 사용 내역이 들어 있는 파일을 받아요.", color: PetTheme.secondary),
            buttonRow([secondary("내 데이터 내려받기", symbol: "square.and.arrow.down") { [weak self] in self?.exportData() }]),
        ]
        if let d = deletion, d.status == .scheduled {
            let when = HubFormat.date(d.purgeAt).map { "\($0)에 모두 지워져요." } ?? "곧 모두 지워져요."
            inner.append(HubKit.label("계정 삭제가 예약돼 있어요. " + when + " 그전에 취소하면 계정이 돌아와요.", color: PetTheme.color(\.danger)))
            inner.append(buttonRow([primary("삭제 취소") { [weak self] in self?.cancelDeletion() }]))
        } else if accountDeleteEnabled {
            inner.append(buttonRow([primary("계정 삭제", symbol: "trash", danger: true) { [weak self] in self?.startDelete() }]))
        } else {
            inner.append(HubKit.label("계정 삭제는 휴대폰의 나초 앱에서 할 수 있어요.", color: PetTheme.secondary))
        }
        return [card(inner)]
    }

    func exportData() {
        guard let e = endpoint else { return }
        toast("파일을 만들고 있어요. 잠시만 기다려 주세요.")
        request({ HubAccountAPI.export(e, bearer: $0) }) { r in
            switch r.flatMap(HubAccountAPI.parseExport) {
            case let .success(file):
                if self.saveExport(file) != nil { self.toast("파일을 저장했어요.") }
            case let .failure(err): self.toast("받지 못했어요. " + HubAccountAPI.errorText(err), error: true)
            }
        }
    }

    func cancelDeletion() {
        guard let e = endpoint else { return }
        let key = HubAPI.newIdempotencyKey()
        request({ HubAccountAPI.cancelDeletion(e, bearer: $0, idempotencyKey: key) }) { r in
            switch r.flatMap(HubAccountAPI.parseDeletionStatus) {
            case .success:
                self.toast("삭제를 취소했어요.")
                self.load()
            case let .failure(err): self.toast("삭제를 취소하지 못했어요. " + HubAccountAPI.errorText(err), error: true)
            }
        }
    }

    /// 서버 미리보기를 확인창 첫 단계에 보여 준다. 미리보기를 못 받으면 삭제를 시작하지 않는다.
    func startDelete() {
        guard accountDeleteEnabled, let e = endpoint else { return }
        request({ HubAccountAPI.deletionPreview(e, bearer: $0) }) { r in
            switch r.flatMap(HubAccountAPI.parseDeletionPreview) {
            case let .failure(err): self.toast("지금 상태를 불러오지 못했어요. 다시 시도해 주세요. " + HubAccountAPI.errorText(err), error: true)
            case let .success(preview):
                self.ctx.confirm([
                    HubConfirmStep(title: "계정을 삭제할까요?", message: AccountSection.deletionMessage(preview), confirmTitle: "계속"),
                    HubConfirmStep(title: "마지막으로 확인할게요", message: "삭제를 시작하면 진행 중인 일이 바로 멈추고 연결이 끊겨요. 정해진 기간 안에 다시 로그인하면 취소할 수 있어요.", confirmTitle: "계정 삭제하기"),
                ]) { [weak self] in self?.deleteAccount() }
            }
        }
    }

    static func deletionMessage(_ p: AccountDeletionPreview) -> String {
        var s = "프로필, 나초와 기억, 대화, 커넥터가 지워져요. 다른 사람에게 보낸 메시지와 일부 기록은 남을 수 있어요.\n"
        s += "지금 나초 \(p.agentCount)명, 진행 중인 일 \(p.runningTasks)개, 단톡 일 \(p.runningGroupRuns)개, 예약 \(p.scheduledActions)개가 있어요."
        if p.subscriptionActive { s += "\n구독이 있어요. 삭제만으로 결제가 멈추지 않을 수 있으니 먼저 해지해 주세요. 남은 기간과 크레딧은 사라져요." }
        return s
    }

    func deleteAccount() {
        guard accountDeleteEnabled, let e = endpoint else { return }
        request({ HubAccountAPI.deleteAccount(e, bearer: $0) }) { r in
            switch r.flatMap(HubAccountAPI.parseCreated) {
            case .success:
                self.toast("삭제를 시작했어요. 정해진 기간 안에 다시 로그인하면 취소할 수 있어요.")
                self.load()
            case let .failure(err): self.toast("삭제하지 못했어요. " + HubAccountAPI.errorText(err), error: true)
            }
        }
    }

    // MARK: 로그아웃 (A3 기존 동작을 부른다)

    func confirmSignOut() {
        ctx.confirm([HubConfirmStep(title: "로그아웃할까요?", message: "맡긴 일은 계속되지만 이 기기로 알림이 오지 않아요.", confirmTitle: "로그아웃하기", destructive: false)]) { [weak self] in
            self?.signOut()
        }
    }

    // MARK: 도우미

    static func saveWithPanel(_ file: AccountExportFile) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do { try file.data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    static func currentDiagnostics() -> HubAccountAPI.Diagnostics {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return HubAccountAPI.Diagnostics(appVersion: app, osVersion: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                                         deviceModel: model.isEmpty ? "Mac" : model, language: "ko")
    }

    // MARK: 입력 칸 알림

    func controlTextDidChange(_ obj: Notification) { fieldChanged?() }
    func textDidChange(_ notification: Notification) { fieldChanged?() }
}
