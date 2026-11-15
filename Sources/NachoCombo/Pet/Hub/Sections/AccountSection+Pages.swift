import AppKit
import NachoComboCore

fileprivate typealias Sp = PetTokens.Space

/// 계정·설정의 하위 화면: 이름(A5)·사용자 ID(A5)·생일(A5)·문제 신고(A10)·약관·법적 고지(A9).
extension AccountSection {
    // MARK: 저장 (이름·ID·생일 공통)

    /// `PATCH /me`. `expected_version`은 본문에 넣고, 409면 새로 불러온다. 서버 오류 문구는 `onError`로 칸 아래에 보여 준다.
    func savePatch(_ changes: [String: Any], onError: @escaping (String) -> Void) {
        guard let p = profile, let e = endpoint, !saving else { return }
        saving = true
        request({ HubAccountAPI.patchMe(e, bearer: $0, changes: changes, expectedVersion: p.version) }) { r in
            self.saving = false
            switch r.flatMap(HubAccountAPI.parseUser) {
            case var .success(np):
                np.authProvider = p.authProvider
                if np.phoneMasked == nil { np.phoneMasked = p.phoneMasked }
                self.profile = np
                self.toast("저장했어요.")
                self.showMain()
            case let .failure(err):
                if err.isVersionConflict {
                    self.toast(HubAccountAPI.errorText(err), error: true)
                    self.load()
                } else {
                    onError(HubAccountAPI.errorText(err))
                }
            }
        }
    }

    private func editLayout(title: String, note: String?, fields: [NSView], save: PetPill) -> [NSView] {
        var v: [NSView] = [backBar(), HubKit.label(title, font: PetTheme.title)] + fields
        if let n = note { v.append(HubKit.label(n, font: PetTheme.caption, color: PetTheme.secondary)) }
        v.append(buttonRow([save]))
        return v
    }

    // MARK: 이름

    func showName() {
        guard let p = profile else { return }
        page = .name
        let f = HubFormField(title: "이름", placeholder: "이름")
        f.field.stringValue = p.displayName
        f.field.delegate = self
        f.validator = { raw in
            switch AccountRules.name(raw) {
            case .empty: return "이름을 입력해 주세요."
            case .tooLong: return "이름은 \(AccountRules.nameMax)자까지 쓸 수 있어요"
            case .ok: return nil
            }
        }
        var save: PetPill!
        save = primary("저장") { [weak self, weak f] in
            guard let self = self, let f = f, f.validate(), case let .ok(v) = AccountRules.name(f.field.stringValue) else { return }
            self.savePatch(["display_name": v]) { f.showServerError($0) }
        }
        let refresh: () -> Void = { [weak self, weak f] in
            guard let self = self, let f = f else { return }
            if case let .ok(v) = AccountRules.name(f.field.stringValue) {
                f.validate()
                self.setEnabledPill(save, v != p.displayName)
            } else {
                f.validate()
                self.setEnabledPill(save, false)
            }
        }
        fieldChanged = refresh
        setEnabledPill(save, false)
        present(editLayout(title: "이름", note: "내 이름은 친구에게 보여요. 구글 계정 이름은 바뀌지 않아요", fields: [f], save: save), fill: [f])
    }

    func setEnabledPill(_ pill: PetPill, _ on: Bool) {
        pill.isEnabled = on
        pill.alphaValue = on ? 1 : 0.45
    }

    // MARK: 사용자 ID

    static func handleText(_ s: AccountRules.HandleState) -> String? {
        switch s {
        case .same: return nil
        case .short: return "영어 소문자, 숫자, 밑줄로 3~20자를 써 주세요"
        case .uppercase: return "대문자는 쓸 수 없어요. 소문자로 써 주세요"
        case .invalid: return "영어 소문자, 숫자, 밑줄로 3~20자만 쓸 수 있어요"
        case .checking: return "쓸 수 있는지 확인하고 있어요"
        case .available: return "쓸 수 있는 ID예요"
        case .taken: return "이미 누가 쓰는 ID예요"
        case .blocked: return "쓸 수 없는 ID예요"
        case .failed: return "확인하지 못했어요. 눌러서 다시 시도해 주세요"
        }
    }

    func showHandle() {
        guard let p = profile else { return }
        page = .handle
        handleCheck = nil
        handleFailed = false
        handleWork?.cancel()
        let current = p.handle ?? ""
        let f = HubFormField(title: "사용자 ID", placeholder: "영어 소문자, 숫자, 밑줄 3~20자")
        f.field.stringValue = current
        f.field.delegate = self
        let status = HubKit.label("", font: PetTheme.caption, color: PetTheme.secondary)
        var save: PetPill!
        var retry: PetPill!
        let render: () -> Void = { [weak self, weak f] in
            guard let self = self, let f = f else { return }
            let input = f.field.stringValue
            let st = AccountRules.handleState(input: input, current: current, check: self.handleCheck, checkFailed: self.handleFailed)
            status.stringValue = AccountSection.handleText(st) ?? ""
            let bad = st == .invalid || st == .uppercase || st == .taken || st == .blocked
            status.textColor = bad ? PetTheme.color(\.danger) : PetTheme.secondary
            retry.isHidden = st != .failed
            self.setEnabledPill(save, AccountRules.canSaveHandle(st))
        }
        // 글자가 바뀌면 옛 확인 결과를 버리고, 입력이 멈춘 뒤 한 번만 묻는다.
        let ask: () -> Void = { [weak self, weak f] in
            guard let self = self, let f = f, let e = self.endpoint else { return }
            let asked = f.field.stringValue
            guard AccountRules.handleNeedsCheck(input: asked, current: current) else { return }
            self.request({ HubAccountAPI.handleCheck(e, handle: asked, bearer: $0) }) { r in
                guard f.field.stringValue == asked else { return }   // 늦게 온 옛 답은 지금 글자를 바꾸지 못한다
                switch r.flatMap(HubAccountAPI.parseHandleCheck) {
                case let .success(c): self.handleCheck = c
                case .failure: self.handleFailed = true
                }
                render()
            }
        }
        retry = secondary("다시 확인", symbol: "arrow.clockwise") { [weak self] in
            self?.handleFailed = false
            render()
            ask()
        }
        save = primary("저장") { [weak self, weak f] in
            guard let self = self, let f = f else { return }
            let v = f.field.stringValue
            guard AccountRules.canSaveHandle(AccountRules.handleState(input: v, current: current, check: self.handleCheck, checkFailed: self.handleFailed)) else { return }
            self.savePatch(["handle": v]) { f.showServerError($0) }
        }
        fieldChanged = { [weak self] in
            guard let self = self else { return }
            self.handleCheck = nil
            self.handleFailed = false
            self.handleWork?.cancel()
            render()
            let work = DispatchWorkItem { ask() }
            self.handleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.handleCheckDelay, execute: work)
        }
        render()
        present(editLayout(title: "사용자 ID", note: "ID를 바꾸면 이전 ID로는 나를 찾을 수 없어요", fields: [f, status, buttonRow([retry])], save: save), fill: [f, status])
    }

    // MARK: 생일

    func showBirthday() {
        guard let p = profile else { return }
        page = .birthday
        let parts = AccountRules.birthdayParts(p.birthday)
        let y = HubFormField(title: "연도", placeholder: "2000")
        let m = HubFormField(title: "월", placeholder: "1")
        let d = HubFormField(title: "일", placeholder: "1")
        y.field.stringValue = parts.year
        m.field.stringValue = parts.month == "0" ? "" : parts.month
        d.field.stringValue = parts.day == "0" ? "" : parts.day
        for f in [y, m, d] { f.field.delegate = self }
        let message = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
        var save: PetPill!
        let check: () -> AccountRules.BirthdayCheck = { [weak self] in
            AccountRules.birthday(y.field.stringValue, m.field.stringValue, d.field.stringValue, today: self?.today() ?? AccountRules.Day.today())
        }
        let refresh: () -> Void = { [weak self] in
            let c = check()
            switch c {
            case .notADate: message.stringValue = "없는 날짜예요"
            case .future: message.stringValue = "오늘 이후 날짜는 쓸 수 없어요"
            case .tooOld: message.stringValue = "1900년부터 쓸 수 있어요"
            default: message.stringValue = ""
            }
            if case let .ok(v) = c { self?.setEnabledPill(save, v != p.birthday) } else { self?.setEnabledPill(save, false) }
        }
        save = primary("저장") { [weak self] in
            guard let self = self, case let .ok(v) = check() else { return }
            self.savePatch(["birthday": v]) { message.stringValue = $0 }
        }
        fieldChanged = refresh
        refresh()
        let fields = HubKit.hstack([y, m, d], spacing: Sp.m)
        fields.distribution = .fillEqually
        present(editLayout(title: "생일", note: nil, fields: [fields, message], save: save), fill: [fields, message])
    }

    // MARK: 문제 신고 (A10)

    func showIssue() {
        page = .issue
        issueKey = HubAPI.newIdempotencyKey()
        let categories = NSPopUpButton(frame: .zero, pullsDown: false)
        categories.addItem(withTitle: "선택 안 함")
        for c in AccountRules.issueCategories { categories.addItem(withTitle: AccountRules.issueCategoryTitle(c)) }
        categories.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        let text = scroll.documentView as! NSTextView
        text.isRichText = false
        text.font = PetTheme.body
        text.textColor = PetTheme.text
        text.drawsBackground = false
        text.delegate = self
        let box = PetBox()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.fill = PetTheme.color(\.surface)
        box.stroke = PetTheme.color(\.edge)
        box.radius = CGFloat(PetTokens.Radius.control)
        HubKit.pin(scroll, in: box, inset: 4)
        box.heightAnchor.constraint(equalToConstant: 160).isActive = true

        let count = HubKit.label("0/\(AccountRules.issueDescriptionMax)자", font: PetTheme.caption, color: PetTheme.secondary)
        let diag = diagnostics()
        let diagNote = HubKit.label("함께 보내는 정보: 앱 버전 \(diag.appVersion), 운영체제 \(diag.osVersion), 기기 \(diag.deviceModel), 언어 \(diag.language). 대화 내용과 인증 정보는 자동으로 보내지 않아요. 비밀번호나 카드 번호는 적지 말아 주세요.",
                                    font: PetTheme.caption, color: PetTheme.secondary)
        var send: PetPill!
        let refresh: () -> Void = { [weak self] in
            let raw = text.string
            let over = raw.utf16.count > AccountRules.issueDescriptionMax
            count.stringValue = over ? "\(AccountRules.issueDescriptionMax)자까지 쓸 수 있어요 (\(raw.utf16.count)자)" : "\(raw.utf16.count)/\(AccountRules.issueDescriptionMax)자"
            count.textColor = over ? PetTheme.color(\.danger) : PetTheme.secondary
            if case .ok = AccountRules.issueDescription(raw) { self?.setEnabledPill(send, true) } else { self?.setEnabledPill(send, false) }
        }
        send = primary("보내기", symbol: "paperplane") { [weak self] in
            guard let self = self, let e = self.endpoint, case let .ok(body) = AccountRules.issueDescription(text.string), !self.saving else { return }
            let idx = categories.indexOfSelectedItem
            let category: String? = idx > 0 ? AccountRules.issueCategories[idx - 1] : nil
            let d = self.diagnostics()
            let key = self.issueKey
            self.saving = true
            self.request({ HubAccountAPI.issueReport(e, bearer: $0, description: body, category: category, diagnostics: d, idempotencyKey: key) }) { r in
                self.saving = false
                switch r.flatMap(HubAccountAPI.parseCreated) {
                case .success:
                    self.toast("보내 주셔서 고마워요. 보낸 내용이 접수됐어요.")
                    self.showMain()
                case let .failure(err): self.toast("보내지 못했어요. 쓴 내용은 그대로 있어요. " + HubAccountAPI.errorText(err), error: true)
                }
            }
        }
        fieldChanged = refresh
        refresh()
        present([backBar(), HubKit.label("문제 신고", font: PetTheme.title),
                 heading("분류 (선택)"), buttonRow([categories]),
                 heading("어떤 문제가 있었나요?"), box, count, diagNote, buttonRow([send])],
                fill: [box, count, diagNote])
    }

    // MARK: 약관·법적 고지 (A9)

    func showLegal() {
        page = .legal
        drawLegal()
        guard let e = endpoint else { return }
        request({ _ in HubAccountAPI.clientConfig(e) }) { r in
            if case let .success(resp) = r { self.legalDocs = AccountRules.legalDocuments(clientConfig: resp.body) }
            if self.page == .legal { self.drawLegal() }
        }
    }

    func drawLegal() {
        var rows: [NSView] = []
        for doc in legalDocs {
            let r = HubRow(title: doc.title, trailing: doc.url == nil ? "준비 중" : "열기")
            r.onClick = { [weak self] in
                guard let self = self else { return }
                if let u = doc.url { self.openLink(u) } else { self.toast("이 문서의 주소가 아직 정해지지 않았어요.", error: true) }
            }
            rows.append(r)
        }
        let notice = [
            "나초콤보의 소스 코드는 MIT 라이선스예요.",
            "글꼴 Anton, IBM Plex는 SIL Open Font License 1.1이에요.",
            "나초 캐릭터 그림, 앱 아이콘과 로고, \"나초콤보\"·\"나초\"·\"마피아나초\" 이름은 오픈소스가 아니에요. 허락 없이 쓸 수 없어요.",
        ].joined(separator: "\n")
        present([backBar(), HubKit.label("약관·법적 고지", font: PetTheme.title), group("문서", rows),
                 group("오픈소스", [HubKit.label(notice, font: PetTheme.caption, color: PetTheme.secondary)])])
    }
}
