import AppKit
import NachoComboCore

// 나초 섹션: 만들기·상세·프로필 편집·삭제·복구·대표·휴식.
extension NachosSection {
    // MARK: 만들기 (F4)

    func openCreate() {
        createKey = HubAPI.newIdempotencyKey()
        go(.create)
        guard templates.isEmpty, let e = ctx.client?.endpoint else { return }
        hubSend({ HubNachosAPI.templates(e, bearer: $0) }) { [weak self] result in
            guard let self = self, case let .success(resp) = result, case let .success(page) = HubAPI.page(resp) else { return }
            self.templates = page.items.compactMap(HubAgentTemplate.init)
            if self.screen == .create { self.render() }
        }
    }

    func showCreate() {
        let page = HubScreen(title: "새 나초 만들기", back: { [weak self] in self?.go(.list) })
        let name = HubFormField(title: "이름", placeholder: "예: 초코", validator: { HubNachosValidation.name($0) })
        let role = HubFormField(title: "역할 한 줄 (선택)", placeholder: "예: 일정을 챙겨 주는 나초", validator: { HubNachosValidation.roleNote($0) })
        let tpl = HubChoiceField(title: "역할 템플릿", options: [("", "고르지 않음")] + templates.map { ($0.id, $0.label) }, selected: nil)
        let honorific = HubChoiceField(title: "말투", options: HubSpeech.honorifics.map { ($0.id, $0.label) }, selected: "polite")
        let tone = HubChoiceField(title: "분위기", options: HubSpeech.tones.map { ($0.id, $0.label) }, selected: "warm")
        let error = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
        error.isHidden = true
        let submit = HubKit.primaryButton("만들기") { [weak self] in
            self?.submitCreate(name: name, role: role, template: tpl, honorific: honorific, tone: tone, error: error)
        }
        for v in [name, role] as [NSView] { page.add(v) }
        if !templates.isEmpty { page.add(tpl) }
        page.add(honorific)
        page.add(tone)
        page.add(error)
        page.add(HubKit.hstack([submit]), full: false)
        hubShow(page.view)
    }

    func submitCreate(name: HubFormField, role: HubFormField, template: HubChoiceField, honorific: HubChoiceField, tone: HubChoiceField, error: NSTextField) {
        let okName = name.validate()
        let okRole = role.validate()
        guard okName, okRole, let e = ctx.client?.endpoint else { return }
        // 템플릿을 골랐으면 그 말투·역할이 기본값이고, 고른 값이 우선이다.
        let tplID = template.selectedID.flatMap { $0.isEmpty ? nil : $0 }
        let speech = HubSpeech(honorific: honorific.selectedID ?? "polite", tone: tone.selectedID ?? "warm")
        let key = createKey
        let (n, r) = (name.value, role.value)
        write({ HubNachosAPI.create(e, bearer: $0, name: n, speech: speech, roleNote: r, templateID: tplID, idempotencyKey: key) },
              success: "나초를 만들었어요.", then: { [weak self] o in
                  guard let self = self else { return }
                  self.createKey = HubAPI.newIdempotencyKey()
                  if let id = (o?.obj("agent") ?? o)?.str("id") { self.go(.detail(id)) } else { self.refreshAfterConflict() }
              }, failure: { [weak self] err in
                  let text = HubNachosText.message(err)
                  error.stringValue = text
                  error.isHidden = false
                  if ["duplicate_name", "blocked_word", "impersonation"].contains(err.code ?? "") { name.showServerError(text) }
                  if err.code == "agent_limit" { self?.refreshAfterConflict() }
              })
    }

    // MARK: 상세 (F2·F4)

    func showDetail(_ id: String) {
        guard let a = agent(id) else { screen = .list; showList(); return }
        let page = HubScreen(title: "나초", back: { [weak self] in self?.go(.list) })
        let head = HubKit.hstack([HubArt.character(size: 72), HubKit.vstack([
            HubKit.label(a.name + (a.isDefault ? "  · 대표" : ""), font: PetTheme.title),
            HubKit.label(a.statusLabel, color: PetTheme.secondary),
        ], spacing: Double(PetTokens.Space.xs))], spacing: Double(PetTokens.Space.l))
        page.add(head, full: false)
        var fields: [(String, String)] = [("말투", a.speech.label)]
        if !a.roleNote.isEmpty { fields.append(("역할", a.roleNote)) }
        fields.append(("전화 상대에게 밝히는 이름", a.phoneName.isEmpty ? "AI 비서" : a.phoneName))
        fields.append(("목소리", a.voiceID.isEmpty ? "기본" : a.voiceID))
        fields.append(("모습", a.avatarURL == nil ? "기본 모습" : "내가 만든 사진"))
        for (k, v) in fields {
            let row = HubKit.vstack([HubKit.label(k, font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(v)], spacing: Double(PetTokens.Space.xxs))
            page.add(row)
        }
        if a.status == "deleting" {
            page.note("이 나초는 지워지는 중이에요. 기간 안에는 되살릴 수 있어요.", color: PetTheme.color(\.warning))
            page.add(HubKit.hstack([HubKit.primaryButton("되살리기", symbol: "arrow.uturn.backward") { [weak self] in self?.restore(a) }]), full: false)
            hubShow(page.view)
            return
        }
        let edit = HubKit.secondaryButton("프로필 고치기", symbol: "pencil") { [weak self] in self?.go(.edit(id)) }
        let voices = HubKit.secondaryButton("목소리", symbol: "waveform") { [weak self] in self?.go(.voices(id)) }
        let traits = HubKit.secondaryButton("닮은 점", symbol: "sparkles") { [weak self] in self?.go(.traits(id)) }
        let photos = HubKit.secondaryButton("사진", symbol: "photo") { [weak self] in self?.go(.photos(id)) }
        let limits = HubKit.secondaryButton("한도", symbol: "slider.horizontal.3") { [weak self] in self?.go(.limits(id)) }
        page.add(PetFlow.rows([edit, voices, traits, photos, limits], maxWidth: 560, gap: Double(PetTokens.Space.s)), full: false)
        var stateButtons: [NSView] = []
        if !a.isDefault && a.status == "active" {
            stateButtons.append(HubKit.secondaryButton("대표로 정하기", symbol: "star") { [weak self] in self?.setDefault(a) })
        }
        if !a.isDefault {
            if a.status == "active" { stateButtons.append(HubKit.secondaryButton("쉬게 하기", symbol: "moon") { [weak self] in self?.rest(a) }) }
            if a.status == "resting" { stateButtons.append(HubKit.secondaryButton("깨우기", symbol: "sun.max") { [weak self] in self?.wake(a) }) }
        }
        stateButtons.append(HubKit.primaryButton("지우기", symbol: "trash", danger: true) { [weak self] in self?.requestDelete(a) })
        page.add(PetFlow.rows(stateButtons, maxWidth: 560, gap: Double(PetTokens.Space.s)), full: false)
        if a.isDefault { page.note("대표 나초는 쉬게 하거나 지울 수 없어요. 다른 나초를 대표로 정한 뒤 해 주세요.") }
        hubShow(page.view)
    }

    // MARK: 상태 바꾸기

    func setDefault(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.setDefault(e, bearer: $0, id: a.id) }, success: "\(a.name)을(를) 대표로 정했어요.", then: { [weak self] _ in self?.render() })
    }

    func rest(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.rest(e, bearer: $0, id: a.id, version: a.version) }, success: "\(a.name)이(가) 쉬어요.", then: { [weak self] _ in self?.render() })
    }

    func wake(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.wake(e, bearer: $0, id: a.id, version: a.version) }, success: "\(a.name)을(를) 깨웠어요.", then: { [weak self] _ in self?.render() })
    }

    func restore(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.restore(e, bearer: $0, id: a.id) }, success: "\(a.name)을(를) 되살렸어요.", then: { [weak self] _ in self?.render() })
    }

    // MARK: 삭제 (되돌릴 수 없음 → 서버 미리보기 + 확인창 두 번)

    func requestDelete(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        let toast = ctx.toast
        let confirm = ctx.confirm
        hubSend({ HubNachosAPI.removalPreview(e, bearer: $0, id: a.id) }) { [weak self] result in
            switch result {
            case let .failure(err): toast(HubNachosText.message(err), true)
            case let .success(resp):
                guard case let .success(o) = HubAPI.object(resp), let preview = HubRemovalPreview(o) else { toast(PetAPIError.badResponse.text, true); return }
                guard preview.canDelete else { toast(HubNachosText.message(.hubDefaultAgent), true); return }
                let steps = [
                    HubConfirmStep(title: "\(a.name)을(를) 지울까요?", message: preview.lines.joined(separator: "\n"), confirmTitle: "계속"),
                    HubConfirmStep(title: "정말 지울까요?", message: "\(a.name)이(가) 지워져요." + (preview.restoreDays > 0 ? " \(preview.restoreDays)일 안에만 되살릴 수 있어요." : ""), confirmTitle: "지우기"),
                ]
                confirm(steps) { self?.deleteConfirmed(a) }
            }
        }
    }

    func deleteConfirmed(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        let key = HubAPI.newIdempotencyKey()
        write({ HubNachosAPI.remove(e, bearer: $0, id: a.id, version: a.version, idempotencyKey: key) }, success: "\(a.name)을(를) 지웠어요.", then: { [weak self] _ in
            self?.screen = .list
            self?.refreshAfterConflict()
        })
    }

    // MARK: 프로필 고치기 (F2)

    func showEdit(_ id: String) {
        guard let a = agent(id) else { go(.list); return }
        let page = HubScreen(title: "프로필 고치기", back: { [weak self] in self?.go(.detail(id)) })
        let name = HubFormField(title: "이름", validator: { HubNachosValidation.name($0) })
        name.field.stringValue = a.name
        let phone = HubFormField(title: "전화 상대에게 밝히는 이름 (비우면 AI 비서)", validator: { HubNachosValidation.phoneName($0) })
        phone.field.stringValue = a.phoneName
        let role = HubFormField(title: "역할 한 줄", validator: { HubNachosValidation.roleNote($0) })
        role.field.stringValue = a.roleNote
        let honorific = HubChoiceField(title: "말투", options: HubSpeech.honorifics.map { ($0.id, $0.label) }, selected: a.speech.honorific)
        let tone = HubChoiceField(title: "분위기", options: HubSpeech.tones.map { ($0.id, $0.label) }, selected: a.speech.tone)
        let error = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
        error.isHidden = true
        let save = HubKit.primaryButton("저장") { [weak self] in
            self?.submitEdit(a, name: name, phone: phone, role: role, honorific: honorific, tone: tone, error: error)
        }
        for v in [name, phone, role, honorific, tone, error] as [NSView] { page.add(v) }
        page.add(HubKit.hstack([save]), full: false)
        hubShow(page.view)
    }

    /// 바뀐 칸만 보낸다. 한 칸이라도 거부되면 서버는 아무것도 저장하지 않는다.
    func submitEdit(_ a: HubAgent, name: HubFormField, phone: HubFormField, role: HubFormField, honorific: HubChoiceField, tone: HubChoiceField, error: NSTextField) {
        let checks = [name.validate(), phone.validate(), role.validate()]
        guard !checks.contains(false), let e = ctx.client?.endpoint else { return }
        var patch = HubAgentPatch()
        if name.value != a.name { patch.name = name.value }
        if phone.value != a.phoneName { patch.phoneName = phone.value }
        if role.value != a.roleNote { patch.roleNote = role.value }
        let h = honorific.selectedID ?? a.speech.honorific, t = tone.selectedID ?? a.speech.tone
        if h != a.speech.honorific || t != a.speech.tone {
            patch.speech = HubSpeech(honorific: h, tone: t, mimic: a.speech.mimic, addressAs: a.speech.addressAs)
        }
        guard !patch.json.isEmpty else { ctx.toast("바꾼 것이 없어요.", false); return }
        let p = patch
        write({ HubNachosAPI.patch(e, bearer: $0, id: a.id, patch: p, version: a.version) }, success: "프로필을 저장했어요.", then: { [weak self] _ in self?.go(.detail(a.id)) },
              failure: { err in
                  let text = HubNachosText.message(err)
                  error.stringValue = text
                  error.isHidden = false
                  if ["duplicate_name", "blocked_word", "impersonation"].contains(err.code ?? ""), p.name != nil { name.showServerError(text) }
              })
    }
}
