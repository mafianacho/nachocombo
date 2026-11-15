import AppKit
import NachoComboCore

/// 나초 앱 창에서 가입을 마치는 화면(NACHO-277 U11, 표 행 A2). 로그인 직후 서버가 「가입이 덜 끝났다」고 하면 창 내용 자리에 뜬다.
/// 상태는 Core `HubOnboardingFlow`가 쥔다(서버의 `step`이 그리는 화면을 정한다). 여기는 그리기와 입력 모으기만 한다.
/// 전화번호 인증 단계는 맥에서 하지 않고 「휴대폰의 나초 앱에서 마쳐 주세요」 안내와 다시 확인 단추만 둔다.
final class OnboardingHost: NSObject, NSTextFieldDelegate {
    /// 칸에 적던 값. 화면을 다시 그려도(오류·진행 표시) 지워지지 않는다.
    struct Draft {
        var name = "", year = "", month = "", day = "", inviteCode = "", characterName = "", voice = ""
        var terms = false, privacy = false, thirdParty = false, aiTransfer = false, marketing = false
        var seeded: Set<String> = []
    }

    let state = HubStateView()
    var view: NSView { state }
    /// 가입이 끝나 나초 앱 창이 평소 모습으로 돌아간다.
    var onCleared: (() -> Void)?
    var onSignOut: (() -> Void)?
    var today: () -> AccountRules.Day = { AccountRules.Day.today() }

    private(set) var flow: HubOnboardingFlow?
    private(set) var panel: OnboardingPanel?
    var draft = Draft()
    private var key = ""
    private var cleared = false
    private var sawHatch = false
    private var hatchStarted = false
    private var greeting = false
    var docViews: [String: NSView] = [:]

    override init() {
        super.init()
        state.onRetry = { [weak self] in self?.flow?.load() }
    }

    /// 창이 이 화면을 보일 때마다 불린다. 처음에만 서버에서 읽고, 그 뒤에는 지금 상태를 다시 그린다.
    func activate(client: HubClient?) {
        guard let client = client else { state.show(.failed("로그인이 필요해요.")); return }
        if let f = flow { render(f.snapshot); return }
        let f = HubOnboardingFlow(client: client)
        f.onChange = { [weak self] s in self?.onMain { self?.render(s) } }
        flow = f
        f.load()
    }

    func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    // MARK: render

    func render(_ s: HubOnboardingFlow.Snapshot) {
        switch s.phase {
        case .loading:
            key = ""; panel = nil
            state.show(.loading)
        case .failed:
            key = ""; panel = nil
            state.show(.failed(s.errorText ?? "가입 정보를 불러오지 못했어요."))
        case .finished:
            if sawHatch, !cleared { showGreeting(s) } else { finish() }
        default:
            let k = "\(s.phase)-\(s.state?.step.raw ?? "")"
            if k != key || panel == nil { build(s, key: k) }
            panel?.setBusy(s.busy)
            panel?.setError(s.errorText)
            panel?.refreshEnabled()
            if s.state?.step == .loading, s.phase == .step { sawHatch = true; startHatch(s) }
        }
    }

    private func finish() {
        guard !cleared else { return }
        cleared = true
        onCleared?()
    }

    /// 새 단계 화면을 만든다(`OnboardingSteps.swift`).
    private func build(_ s: HubOnboardingFlow.Snapshot, key k: String) {
        key = k
        docViews = [:]
        guard let p = makePanel(s) else { state.show(.failed("이 단계를 그리지 못했어요.")); return }
        place(p)
    }

    func place(_ p: OnboardingPanel) {
        for v in state.contentHost.subviews { v.removeFromSuperview() }
        panel = p
        HubKit.pin(p, in: state.contentHost)
        state.show(.content)
    }

    /// 끝 인사: 「같이 시작하기」를 누르면 평소 화면으로 돌아간다.
    private func showGreeting(_ s: HubOnboardingFlow.Snapshot) {
        guard !greeting else { return }
        greeting = true
        key = "greeting"
        let user = s.state?.displayName ?? ""
        let name = s.state?.characterName ?? "나초"
        let p = OnboardingPanel(symbol: "hand.wave", title: "안녕, \(user). 나 \(name)\(HubOnboardingRules.particle(name, "이야", "야")).",
                                body: "이제 네 일, 같이 하자.", primary: ("같이 시작하기", { [weak self] in self?.finish() }))
        place(p)
    }

    /// 마지막 단계(`loading`)는 입력이 없다: 들어오면 한 번 알아서 완료를 보낸다. 실패하면 「다시 시도」로 다시 보낸다.
    private func startHatch(_ s: HubOnboardingFlow.Snapshot) {
        guard !hatchStarted, !s.busy else { return }
        hatchStarted = true
        DispatchQueue.main.async { [weak self] in self?.flow?.submit(.loading, value: nil) }
    }

    func retryHatch() {
        hatchStarted = true
        flow?.submit(.loading, value: nil)
    }

    // MARK: 입력 칸

    func controlTextDidChange(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, let id = f.identifier?.rawValue else { return }
        switch id {
        case "name": draft.name = f.stringValue
        case "characterName": draft.characterName = f.stringValue
        case "year": f.stringValue = Self.digits(f.stringValue, 4); draft.year = f.stringValue
        case "month": f.stringValue = Self.digits(f.stringValue, 2); draft.month = f.stringValue
        case "day": f.stringValue = Self.digits(f.stringValue, 2); draft.day = f.stringValue
        case "inviteCode": f.stringValue = HubOnboardingRules.inviteCodeClean(f.stringValue); draft.inviteCode = f.stringValue
        default: break
        }
        panel?.setError(nil)
        panel?.refreshEnabled()
    }

    static func digits(_ s: String, _ max: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.prefix(max)))
    }

    func field(_ id: String, title: String, placeholder: String = "", value: String) -> HubFormField {
        let f = HubFormField(title: title, placeholder: placeholder)
        f.field.stringValue = value
        f.field.identifier = NSUserInterfaceItemIdentifier(id)
        f.field.delegate = self
        f.field.setAccessibilityLabel(title)
        return f
    }
}

/// 켜고 끄는 점검 단추(약관 동의·목소리 고르기).
final class OnboardingCheck: NSButton {
    var onToggle: ((Bool) -> Void)?

    init(title: String, checked: Bool, radio: Bool = false) {
        super.init(frame: .zero)
        setButtonType(radio ? .radio : .switch)
        self.title = title
        state = checked ? .on : .off
        target = self
        action = #selector(fire)
        font = PetTheme.body
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { onToggle?(state == .on) }
}
