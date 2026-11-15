import AppKit
import NachoComboCore

/// 가입 단계별 화면(NACHO-277 U11). 단계·문구·입력 규칙은 나초 앱 `features/onboarding`과 같다.
/// 입력은 보내기 전에 앱 규칙으로 먼저 검사하고(길이·형식·빈 값), 서버가 거절하면 그 이유를 한국어로 보여 준다.
extension OnboardingHost {
    func makePanel(_ s: HubOnboardingFlow.Snapshot) -> OnboardingPanel? {
        guard let st = s.state else { return nil }
        switch s.phase {
        case .phoneOnPhone: return phonePanel(st)
        case .reconsent: return reconsentPanel(st)
        case .suspended: return stoppedPanel(st, region: false)
        case .regionClosed: return stoppedPanel(st, region: true)
        default: break
        }
        switch st.step {
        case .inviteGate: return invitePanel(st, waitlist: false)
        case .inviteWaitlist: return invitePanel(st, waitlist: true)
        case .name: return namePanel(st)
        case .birthday: return birthdayPanel(st)
        case .consent: return consentPanel(st)
        case .guide: return guidePanel(st)
        case .eggMeet: return eggPanel(st)
        case .characterName: return characterNamePanel(st)
        case .characterVoice: return voicePanel(st)
        case .loading, .done: return hatchPanel(st)
        case .guidePrivacy: return hatchPanel(st)  // 클라이언트가 지나가는 단계: 잠깐 보이는 동안 기다리는 화면
        case .login, .phone, .unknown: return phonePanel(st)
        }
    }

    // MARK: 공통

    /// 먼저 앱 규칙으로 검사하고, 문제가 있으면 오류 줄에 보여 주고 보내지 않는다.
    private func send(_ step: HubOnboardingStep, value: Any?, problem: String?) {
        if let p = problem { panel?.setError(p); return }
        flow?.submit(step, value: value)
    }

    private func back(_ st: HubOnboardingState) -> [(title: String, action: () -> Void)] {
        st.canGoBack ? [("뒤로", { [weak self] in self?.flow?.back() })] : []
    }

    private func logout() -> (title: String, action: () -> Void) { ("로그아웃", { [weak self] in self?.onSignOut?() }) }

    private func seed(_ id: String, _ body: () -> Void) {
        if !draft.seeded.contains(id) { draft.seeded.insert(id); body() }
    }

    // MARK: 초대 코드

    private func invitePanel(_ st: HubOnboardingState, waitlist: Bool) -> OnboardingPanel {
        let f = field("inviteCode", title: "초대 코드", placeholder: "숫자 6자리", value: draft.inviteCode)
        let confirm = { [weak self] in
            guard let self = self else { return }
            let code = HubOnboardingRules.inviteCodeClean(self.draft.inviteCode)
            self.send(waitlist ? .inviteWaitlist : .inviteGate, value: ["invite_code": code],
                      problem: HubOnboardingRules.inviteCodeValid(code) ? nil : "초대 코드는 숫자 6자리예요.")
        }
        var extras = back(st)
        if waitlist {
            if !st.inviteWaitlistJoined {
                extras.append(("대기 등록", { [weak self] in self?.flow?.joinInviteWaitlist() }))
            }
            extras.append(logout())
        } else {
            // 코드가 없으면 빈 코드를 보내 서버가 대기 단계로 넘긴다(앱 `초대 코드가 없어요`).
            extras.append(("초대 코드가 없어요", { [weak self] in self?.flow?.submit(.inviteGate, value: ["invite_code": ""]) }))
        }
        let body = waitlist ? "앱을 열 때마다 입장할 수 있는지 확인해요." : "지금은 초대받은 분만 시작할 수 있어요."
        var content: [NSView] = [f]
        if waitlist, st.inviteWaitlistJoined { content.append(HubKit.label("대기 등록을 마쳤어요.", color: PetTheme.secondary)) }
        return OnboardingPanel(symbol: "envelope.open", title: waitlist ? "아직 시작할 수 없어요" : "초대 코드가 있나요?", body: body, content: content,
                               primary: ("코드 확인", confirm), extras: extras,
                               enabledRule: { [weak self] in HubOnboardingRules.inviteCodeValid(self?.draft.inviteCode ?? "") })
    }

    // MARK: 이름·생일

    private func namePanel(_ st: HubOnboardingState) -> OnboardingPanel {
        seed("name") { draft.name = st.displayName ?? st.nameSuggestions.first ?? "" }
        let f = field("name", title: "부를 이름", value: draft.name)
        var content: [NSView] = []
        if let by = st.invitedBy, !by.isEmpty { content.append(HubKit.label("\(by)님이 초대했어요.", color: PetTheme.secondary)) }
        content.append(f)
        content.append(HubKit.label("전체 이름 말고 부르기 좋은 이름이면 충분해요.", font: PetTheme.caption, color: PetTheme.secondary))
        if !st.nameSuggestions.isEmpty {
            let chips = st.nameSuggestions.prefix(4).map { name -> PetPill in
                let chip = HubKit.secondaryButton(name) { [weak self, weak f] in
                    self?.draft.name = name
                    f?.field.stringValue = name
                    self?.panel?.refreshEnabled()
                }
                chip.setContentHuggingPriority(.required, for: .horizontal)
                return chip
            }
            content.append(OnboardingPanel.row(chips, spacing: Double(PetTokens.Space.s)))
        }
        return OnboardingPanel(symbol: "person.crop.circle", title: "나초가 뭐라고 부르면 좋을까요?", content: content,
                               primary: ("계속", { [weak self] in
                                   guard let self = self else { return }
                                   if case let .ok(v) = HubOnboardingRules.name(self.draft.name) { self.send(.name, value: v, problem: nil) }
                                   else { self.send(.name, value: nil, problem: HubOnboardingRules.nameProblem(self.draft.name)) }
                               }), extras: back(st),
                               enabledRule: { [weak self] in !(self?.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) })
    }

    private func birthdayPanel(_ st: HubOnboardingState) -> OnboardingPanel {
        seed("birthday") {
            let p = AccountRules.birthdayParts(st.birthday)
            draft.year = p.year == "" ? "" : p.year; draft.month = p.month == "0" ? "" : p.month; draft.day = p.day == "0" ? "" : p.day
        }
        let y = field("year", title: "연도", placeholder: "1999", value: draft.year)
        let m = field("month", title: "월", placeholder: "2", value: draft.month)
        let d = field("day", title: "일", placeholder: "3", value: draft.day)
        let row = HubKit.hstack([y, m, d], spacing: Double(PetTokens.Space.m))
        for f in [y, m, d] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true }
        var extras = back(st)
        extras.append(logout())  // 나이 제한에 걸리면 나갈 길이 이것뿐이라 늘 둔다
        return OnboardingPanel(symbol: "gift", title: "생일을 알려 주세요", body: "쓸 수 있는 나이인지 확인하고, 생일을 기억해 두려고 물어요.",
                               content: [row],
                               primary: ("계속", { [weak self] in
                                   guard let self = self else { return }
                                   let t = self.today()
                                   if case let .ok(v) = HubOnboardingRules.birthday(self.draft.year, self.draft.month, self.draft.day, today: t) {
                                       self.send(.birthday, value: v, problem: nil)
                                   } else {
                                       self.send(.birthday, value: nil, problem: HubOnboardingRules.birthdayProblem(self.draft.year, self.draft.month, self.draft.day, today: t))
                                   }
                               }), extras: extras,
                               enabledRule: { [weak self] in
                                   guard let d = self?.draft else { return false }
                                   return !d.year.isEmpty && !d.month.isEmpty && !d.day.isEmpty
                               })
    }

    // MARK: 약관

    static let docs: [(kind: String, title: String, body: String)] = [
        ("terms", "이용약관", "나초 시험판 이용약관의 임시 내용이에요. 시험판에서는 실제 비밀번호나 카드 번호를 넣지 말아 주세요. 시험판 기능과 데이터는 예고 없이 바뀌거나 지워질 수 있어요."),
        ("privacy", "개인정보 수집과 이용", "광고를 넣지 않고, 커넥터는 언제든 끌 수 있으며, 계정을 지울 수 있어요. 나초 시험판 개인정보 처리방침의 임시 내용이에요. 이름, 생일, 대화를 서비스 제공에 써요. 계정을 지우면 함께 지우는 것을 목표로 하며, 자세한 기간은 정식 문서에 적어요."),
        ("third_party", "개인정보 제3자 제공", "개인정보 제3자 제공 동의의 임시 내용이에요. 나초가 대신 주문하면, 연결한 서비스(쇼핑몰 등)가 주문과 배송에 필요한 정보를 받아요. 받는 곳, 항목, 보관 기간은 정식 문서에 적어요."),
        ("ai_transfer", "AI 서비스 개인정보 전송", "AI 서비스 개인정보 전송 동의의 임시 내용이에요. 나초가 답을 만들려고 대화 내용을 외부 AI 모델 제공자에게 보내요. 제공자가 해외에 있을 수 있어요. 받는 곳, 나라, 항목, 보관 기간은 정식 문서에 적어요."),
        ("marketing", "혜택 알림", "새 기능과 혜택 소식을 받는다는 선택 동의의 임시 내용이에요. 동의하지 않아도 나초를 쓸 수 있어요."),
    ]

    /// 문서 한 줄 + 「보기」(누르면 아래에 임시 문서 글이 펼쳐진다).
    private func docRow(_ d: (kind: String, title: String, body: String), required: Bool, checked: Bool, onToggle: ((Bool) -> Void)?) -> (row: NSView, check: OnboardingCheck?) {
        let doc = HubKit.label("임시 문서예요. 출시 전에 정식 문서로 바뀌어요.\n" + d.body, font: PetTheme.caption, color: PetTheme.secondary)
        doc.isHidden = true
        docViews[d.kind] = doc
        let toggle = HubKit.secondaryButton("보기") { [weak doc] in doc?.isHidden.toggle() }
        toggle.setAccessibilityLabel("\(d.title) 보기")
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        var views: [NSView] = []
        var check: OnboardingCheck?
        if let on = onToggle {
            let c = OnboardingCheck(title: "\(d.title) (\(required ? "필수" : "선택"))", checked: checked)
            c.onToggle = on
            check = c
            views.append(c)
        } else {
            views.append(HubKit.label(d.title))
        }
        views.append(toggle)
        let row = OnboardingPanel.row(views, spacing: Double(PetTokens.Space.m))
        let box = HubKit.vstack([row, doc], spacing: Double(PetTokens.Space.xs))
        HubKit.fill(box, [row, doc])
        return (box, check)
    }

    private func consentPanel(_ st: HubOnboardingState) -> OnboardingPanel {
        seed("consent") {
            draft.terms = st.consentTerms ?? false; draft.privacy = st.consentPrivacy ?? false
            draft.marketing = st.consentMarketing ?? false
        }
        var checks: [String: OnboardingCheck] = [:]
        let all = OnboardingCheck(title: "모두 동의", checked: draft.terms && draft.privacy && draft.thirdParty && draft.aiTransfer && draft.marketing)
        var rows: [NSView] = [all]
        for d in Self.docs {
            let on: Bool
            switch d.kind {
            case "terms": on = draft.terms
            case "privacy": on = draft.privacy
            case "third_party": on = draft.thirdParty
            case "ai_transfer": on = draft.aiTransfer
            default: on = draft.marketing
            }
            let r = docRow(d, required: d.kind != "marketing", checked: on) { [weak self] v in
                guard let self = self else { return }
                switch d.kind {
                case "terms": self.draft.terms = v
                case "privacy": self.draft.privacy = v
                case "third_party": self.draft.thirdParty = v
                case "ai_transfer": self.draft.aiTransfer = v
                default: self.draft.marketing = v
                }
                all.state = (self.draft.terms && self.draft.privacy && self.draft.thirdParty && self.draft.aiTransfer && self.draft.marketing) ? .on : .off
                self.panel?.setError(nil)
                self.panel?.refreshEnabled()
            }
            if let c = r.check { checks[d.kind] = c }
            rows.append(r.row)
        }
        all.onToggle = { [weak self] v in
            guard let self = self else { return }
            self.draft.terms = v; self.draft.privacy = v; self.draft.thirdParty = v; self.draft.aiTransfer = v; self.draft.marketing = v
            for c in checks.values { c.state = v ? .on : .off }
            self.panel?.setError(nil)
            self.panel?.refreshEnabled()
        }
        let list = HubKit.vstack(rows, spacing: Double(PetTokens.Space.m))
        HubKit.fill(list, rows)
        return OnboardingPanel(symbol: "doc.text", title: "약관을 확인해 주세요", content: [list],
                               primary: ("계속", { [weak self] in
                                   guard let self = self, let version = st.consentVersion, !version.isEmpty else { return }
                                   // 서버 스펙의 값은 terms·privacy·marketing·consent_version. 제3자 제공·AI 전송은 화면에서 필수로 받는다.
                                   self.flow?.submit(.consent, value: HubOnboardingRules.consentValue(
                                       terms: self.draft.terms, privacy: self.draft.privacy, marketing: self.draft.marketing, version: version))
                               }), extras: back(st),
                               enabledRule: { [weak self] in
                                   guard let d = self?.draft else { return false }
                                   return HubOnboardingRules.consentsReady(terms: d.terms, privacy: d.privacy, thirdParty: d.thirdParty, aiTransfer: d.aiTransfer)
                               })
    }

    private func reconsentPanel(_ st: HubOnboardingState) -> OnboardingPanel {
        var rows: [NSView] = []
        for d in Self.docs where d.kind != "marketing" { rows.append(docRow(d, required: true, checked: false, onToggle: nil).row) }
        let list = HubKit.vstack(rows, spacing: Double(PetTokens.Space.m))
        HubKit.fill(list, rows)
        return OnboardingPanel(symbol: "doc.badge.gearshape", title: "약관이 바뀌었어요", body: "읽고 동의하면 계속 쓸 수 있어요. 혜택 알림 선택은 그대로 둬요.",
                               content: [list], primary: ("동의하고 계속", { [weak self] in self?.flow?.agreeAgain() }),
                               extras: [("동의하지 않아요 (로그아웃)", { [weak self] in self?.onSignOut?() })])
    }

    // MARK: 안내·캐릭터

    private func guidePanel(_ st: HubOnboardingState) -> OnboardingPanel {
        let lines = ["돈 드는 일이나 큰일은 먼저 물어봐요", "실수도 해요. 결과를 확인해 주세요", "앱을 닫아도 일해요. 범위는 직접 정해요", "대화를 외부 AI 제공사에 보낼 수 있어요"]
        let l = lines.map { HubKit.label("•  " + $0) }
        let box = HubKit.vstack(l, spacing: Double(PetTokens.Space.s))
        HubKit.fill(box, l)
        return OnboardingPanel(symbol: "checkmark.shield", title: "나초는 실제로 일을 해요", content: [box],
                               primary: ("계속", { [weak self] in self?.flow?.submit(.guide, value: nil) }), extras: back(st))
    }

    private func eggPanel(_ st: HubOnboardingState) -> OnboardingPanel {
        let user = st.displayName ?? ""
        return OnboardingPanel(symbol: "shippingbox", title: "\(user), 나초가 기다리고 있어요", body: "버튼을 눌러 봉지를 뜯어요.",
                               primary: ("봉지 뜯기", { [weak self] in self?.flow?.submit(.eggMeet, value: nil) }), extras: back(st))
    }

    private func characterNamePanel(_ st: HubOnboardingState) -> OnboardingPanel {
        seed("characterName") { draft.characterName = st.characterName ?? "" }
        let f = field("characterName", title: "내 AI 친구 이름", value: draft.characterName)
        return OnboardingPanel(symbol: "sparkles", title: "내 AI 친구 이름을 정해 주세요", body: "대화에서 이 이름으로 불러요.",
                               content: [f, HubKit.label("전화할 때는 기본으로 AI 비서라고 밝혀요.", font: PetTheme.caption, color: PetTheme.secondary)],
                               primary: ("계속", { [weak self] in
                                   guard let self = self else { return }
                                   if case let .ok(v) = HubOnboardingRules.characterName(self.draft.characterName) { self.send(.characterName, value: v, problem: nil) }
                                   else { self.send(.characterName, value: nil, problem: HubOnboardingRules.characterNameProblem(self.draft.characterName)) }
                               }), extras: back(st),
                               enabledRule: { [weak self] in !(self?.draft.characterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) })
    }

    private func voicePanel(_ st: HubOnboardingState) -> OnboardingPanel {
        seed("voice") { draft.voice = st.voices.contains { $0.voiceID == st.voice } ? (st.voice ?? "") : "" }
        let name = st.characterName ?? "나초"
        var radios: [OnboardingCheck] = []
        for v in st.voices {
            let text = v.description.isEmpty ? v.label : "\(v.label) — \(v.description)"
            let c = OnboardingCheck(title: text, checked: draft.voice == v.voiceID, radio: true)
            c.onToggle = { [weak self] _ in
                self?.draft.voice = v.voiceID
                for o in radios where o !== c { o.state = .off }
                c.state = .on
                self?.panel?.setError(nil)
                self?.panel?.refreshEnabled()
            }
            radios.append(c)
        }
        let list = HubKit.vstack(radios, spacing: Double(PetTokens.Space.m))
        return OnboardingPanel(symbol: "waveform", title: "\(name)\(HubOnboardingRules.particle(name, "이", "가")) 어떤 목소리로 말할까요?",
                               body: "전화를 걸 때도 이 목소리예요. 나중에 바꿀 수 있어요.", content: [list],
                               primary: ("계속", { [weak self] in
                                   guard let self = self else { return }
                                   // 고를 수 있는 목소리 안에 있어야 한다(서버 규칙).
                                   let known = st.voices.contains { $0.voiceID == self.draft.voice }
                                   self.send(.characterVoice, value: self.draft.voice, problem: known ? nil : "목소리를 골라 주세요.")
                               }), extras: back(st),
                               enabledRule: { [weak self] in !(self?.draft.voice.isEmpty ?? true) })
    }

    private func hatchPanel(_ st: HubOnboardingState) -> OnboardingPanel {
        let name = st.characterName ?? "나초"
        return OnboardingPanel(symbol: "hourglass", title: "\(name)\(HubOnboardingRules.particle(name, "이", "가")) 나오려고 해요",
                               body: "준비하는 데 시간이 조금 걸릴 수 있어요.",
                               primary: ("다시 시도", { [weak self] in self?.retryHatch() }),
                               enabledRule: { [weak self] in self?.flow?.snapshot.error != nil })
    }

    // MARK: 휴대폰 안내·멈춘 계정

    private func phonePanel(_ st: HubOnboardingState) -> OnboardingPanel {
        OnboardingPanel(symbol: "iphone", title: "휴대폰의 나초 앱에서 마쳐 주세요", body: HubOnboardingRules.phoneNotice,
                        primary: ("다시 확인", { [weak self] in self?.flow?.recheck() }), extras: [logout()])
    }

    private func stoppedPanel(_ st: HubOnboardingState, region: Bool) -> OnboardingPanel {
        if region {
            let where_ = (st.regionName ?? "").isEmpty ? "" : " (\(st.regionName!))"
            var extras: [(title: String, action: () -> Void)] = []
            if !st.regionWaitlistJoined { extras.append(("대기 등록", { [weak self] in self?.flow?.joinRegionWaitlist() })) }
            extras.append(logout())
            return OnboardingPanel(symbol: "globe.asia.australia", title: "이 지역은 아직 열리지 않았어요", body: st.regionWaitlistJoined ? "대기 등록을 마쳤어요\(where_)." : "대기 등록을 하면 열릴 때 알려 줘요\(where_).",
                                   extras: extras)
        }
        return OnboardingPanel(symbol: "exclamationmark.triangle", title: "계정을 쓸 수 없는 상태예요", body: "문의가 필요하면 휴대폰의 나초 앱에서 문의해 주세요.", extras: [logout()])
    }
}
