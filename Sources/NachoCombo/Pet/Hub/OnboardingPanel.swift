import AppKit
import NachoComboCore

/// 가입 한 단계의 틀(NACHO-277 U11): 제목·설명·내용·오류 줄·단추. 위에서부터 쌓이고 창이 좁으면 스크롤된다.
/// 색·크기·글꼴은 `PetTheme`/`PetTokens`만 쓴다(라이트·다크 자동).
final class OnboardingPanel: NSView {
    static let width: CGFloat = 480

    private let stack = HubKit.vstack([], spacing: Double(PetTokens.Space.l))
    private let errorLabel = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
    private(set) var primary: PetPill?
    private(set) var extras: [PetPill] = []
    private var pills: [PetPill] = []
    private var enabledRule: (() -> Bool)?
    private(set) var busy = false

    init(symbol: String, title: String, body: String? = nil, content: [NSView] = [], primary: (title: String, action: () -> Void)? = nil,
         extras: [(title: String, action: () -> Void)] = [], enabledRule: (() -> Bool)? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("hub-onboarding-panel")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = HubFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        addSubview(scroll)
        doc.addSubview(stack)

        let icon = NSImageView()
        icon.image = PetTheme.symbol(symbol, size: 34)
        icon.contentTintColor = PetTheme.accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        let heading = HubKit.label(title, font: PetTheme.title)
        heading.setAccessibilityRole(.staticText)
        var views: [NSView] = [icon, heading]
        if let b = body, !b.isEmpty { views.append(HubKit.label(b, color: PetTheme.secondary)) }
        views += content
        errorLabel.isHidden = true
        errorLabel.setAccessibilityIdentifier("hub-onboarding-error")
        views.append(errorLabel)
        var buttons: [NSView] = []
        if let p = primary {
            let pill = HubKit.primaryButton(p.title, onClick: { [weak self] in
                guard let self = self, !self.busy, self.enabledRule?() ?? true else { return }
                p.action()
            })
            self.primary = pill
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pills.append(pill)
            buttons.append(pill)
        }
        for e in extras {
            let pill = HubKit.secondaryButton(e.title, onClick: { [weak self] in
                guard let self = self, !self.busy else { return }
                e.action()
            })
            self.extras.append(pill)
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pills.append(pill)
            buttons.append(pill)
        }
        let buttonRow: NSView? = buttons.isEmpty ? nil : HubKit.hstack(buttons, spacing: Double(PetTokens.Space.s))
        if let r = buttonRow { views.append(r) }
        for v in views { stack.addArrangedSubview(v) }
        // 글·입력 칸은 스택 너비에 맞춘다(여러 줄 글이 줄바꿈되도록). 그림과 단추 줄은 제 크기대로.
        HubKit.fill(stack, views.filter { $0 !== icon && $0 !== buttonRow })

        self.enabledRule = enabledRule
        let wide = stack.widthAnchor.constraint(equalToConstant: OnboardingPanel.width)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: doc.leadingAnchor, constant: CGFloat(PetTokens.Space.xl)),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -CGFloat(PetTokens.Space.xl)),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 44),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -32),
            wide,
        ])
        refreshEnabled()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 오류 줄(서버 이유·검증 문구). nil이면 숨긴다.
    func setError(_ text: String?) {
        errorLabel.stringValue = text ?? ""
        errorLabel.isHidden = (text ?? "").isEmpty
    }

    /// 요청이 나가 있는 동안 단추를 잠근다.
    func setBusy(_ on: Bool) {
        busy = on
        refreshEnabled()
    }

    /// 입력이 바뀔 때 불러서 「계속」 단추를 켜고 끈다.
    func refreshEnabled() {
        let ok = enabledRule?() ?? true
        for p in pills {
            let on = !busy && (p !== primary || ok)
            p.isEnabled = on
            p.alphaValue = on ? 1 : 0.45
        }
    }
}
