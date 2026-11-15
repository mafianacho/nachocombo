import AppKit
import NachoComboCore

/// 창이 모듈에 묻는 것들(시험은 가짜로 채운다).
struct HubEnvironment {
    var isSignedIn: () -> Bool
    /// 로그인이 되어 있고 서버 주소가 있으면 요청 실행기.
    var client: () -> HubClient?
    var signIn: () -> Void
}

/// 사이드바 한 줄.
final class HubSidebarRow: PetBox {
    let sectionID: HubSectionID
    var onClick: (() -> Void)?
    private let title: NSTextField
    private let icon = NSImageView()
    private let badgeLabel = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.onAccent), wrap: false)
    private let badgeBox = PetBox()

    /// 안 읽은 수 배지. 0이면 숨기고 접근성 라벨에 수를 넣는다(섹션이 공통으로 쓴다).
    func setBadge(_ count: Int) {
        badgeBox.isHidden = count <= 0
        badgeLabel.stringValue = count > 99 ? "99+" : String(count)
        setAccessibilityLabel(count > 0 ? "\(sectionID.title), 안 읽음 \(count)개" : sectionID.title)
    }

    var selected = false {
        didSet {
            fill = selected ? PetTheme.color(\.accentSoft) : nil
            title.textColor = selected ? PetTheme.accent : PetTheme.text
            icon.contentTintColor = selected ? PetTheme.accent : PetTheme.secondary
            needsDisplay = true
        }
    }

    init(_ id: HubSectionID) {
        sectionID = id
        title = HubKit.label(id.title, wrap: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        radius = CGFloat(PetTokens.Radius.control)
        icon.image = PetTheme.symbol(id.symbol, size: PetTokens.Size.icon)
        icon.contentTintColor = PetTheme.secondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.fill = PetTheme.accent
        badgeBox.radius = 9
        badgeBox.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.isHidden = true
        badgeBox.addSubview(badgeLabel)
        NSLayoutConstraint.activate([
            badgeLabel.leadingAnchor.constraint(equalTo: badgeBox.leadingAnchor, constant: 6),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeBox.trailingAnchor, constant: -6),
            badgeLabel.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 1),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeBox.bottomAnchor, constant: -1),
        ])
        badgeBox.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = HubKit.hstack([icon, title, badgeBox], spacing: PetTokens.Space.s)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CGFloat(PetTokens.Size.control)),
            icon.widthAnchor.constraint(equalToConstant: CGFloat(PetTokens.Size.icon)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(PetTokens.Space.m)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CGFloat(PetTokens.Space.s)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(id.title)
        setAccessibilityIdentifier("hub-section-\(id.rawValue)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// 나초 앱 창: 대화창과 별개인 일반 창. 크기를 바꿀 수 있고 위치·크기를 기억한다(`setFrameAutosaveName`).
/// 왼쪽 사이드바(섹션 13개), 오른쪽 내용. 로그인 전에는 로그인 안내를 보여 준다.
final class PetHubWindow: NSWindow {
    static let defaultSize = NSSize(width: 960, height: 640)
    static let minimumSize = NSSize(width: 720, height: 480)
    static let sidebarWidth: CGFloat = 208

    private let env: HubEnvironment
    private var sections: [HubSectionID: HubSectionBase] = [:]
    private var rows: [HubSectionID: HubSidebarRow] = [:]
    private let detail = NSView()
    private let toastHost = HubPassthroughView()
    private let signInView = NSView()
    private var wasSignedIn: Bool
    private(set) var selected: HubSectionID
    private var observer: NSObjectProtocol?

    /// `autosaveName`이 nil이면 위치·크기를 기억하지 않는다(시험).
    init(env: HubEnvironment, autosaveName: String? = "NachoHubWindow", initial: HubSectionID = .account) {
        self.env = env
        selected = initial
        wasSignedIn = env.isSignedIn()
        super.init(contentRect: NSRect(origin: .zero, size: PetHubWindow.defaultSize),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        title = "나초 앱"
        isReleasedWhenClosed = false
        minSize = PetHubWindow.minimumSize
        build()
        if let name = autosaveName {
            if !setFrameUsingName(name) { center() }
            setFrameAutosaveName(name)
        }
        select(initial)
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main) { [weak self] _ in
            self?.refreshAuth()
        }
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    // MARK: layout

    private func build() {
        let root = PetBox()
        root.fill = PetTheme.color(\.window)
        contentView = root

        let sidebar = PetBox()
        sidebar.fill = PetTheme.color(\.surface)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let header = HubKit.label("나초 앱", font: PetTheme.title, wrap: false)
        let list = HubKit.vstack([], spacing: Double(PetTokens.Space.xxs))
        for id in HubSectionID.allCases {
            let r = HubSidebarRow(id)
            r.onClick = { [weak self] in self?.select(id) }
            rows[id] = r
            list.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = HubFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        doc.addSubview(list)
        let p = CGFloat(PetTokens.Space.s)
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: p),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -p),
            list.topAnchor.constraint(equalTo: doc.topAnchor, constant: p),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -p),
        ])
        sidebar.addSubview(header)
        sidebar.addSubview(scroll)
        let line = PetBox()
        line.fill = PetTheme.color(\.separator)
        line.translatesAutoresizingMaskIntoConstraints = false

        detail.translatesAutoresizingMaskIntoConstraints = false
        toastHost.translatesAutoresizingMaskIntoConstraints = false

        for v in [sidebar, line, detail, toastHost] as [NSView] { root.addSubview(v) }
        let m = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: PetHubWindow.sidebarWidth),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: m),
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: m),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CGFloat(PetTokens.Space.s)),
            scroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: root.topAnchor),
            line.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: line.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toastHost.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            toastHost.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            toastHost.topAnchor.constraint(equalTo: detail.topAnchor),
            toastHost.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        buildSignIn()
    }

    private func buildSignIn() {
        signInView.translatesAutoresizingMaskIntoConstraints = false
        let art = NSImageView()
        art.image = PetTheme.symbol("person.crop.circle.badge.questionmark", size: 40)
        art.contentTintColor = PetTheme.tertiary
        let title = HubKit.label("나초 계정으로 로그인해 주세요", font: PetTheme.title)
        title.alignment = .center
        let note = HubKit.label("로그인하면 휴대폰의 나초 앱과 같은 대화·작업·기억을 여기서 볼 수 있어요. 비밀번호는 나초 콤보가 보지 않아요.",
                                color: PetTheme.secondary)
        note.alignment = .center
        let button = HubKit.primaryButton("나초 계정으로 로그인") { [weak self] in self?.env.signIn() }
        let s = HubKit.vstack([art, title, note, button], spacing: Double(PetTokens.Space.l))
        s.alignment = .centerX
        signInView.addSubview(s)
        NSLayoutConstraint.activate([
            s.centerXAnchor.constraint(equalTo: signInView.centerXAnchor),
            s.centerYAnchor.constraint(equalTo: signInView.centerYAnchor),
            s.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            note.widthAnchor.constraint(equalToConstant: 340),
        ])
        signInView.setAccessibilityIdentifier("hub-signin")
    }

    // MARK: sections

    func select(_ id: HubSectionID) {
        selected = id
        for (sid, r) in rows { r.selected = sid == id }
        render()
    }

    /// 로그인 상태가 바뀌었으면 다시 그린다(창이 앞으로 올 때 불린다).
    func refreshAuth() {
        let now = env.isSignedIn()
        guard now != wasSignedIn else { return }
        wasSignedIn = now
        render()
    }

    private func render() {
        for v in detail.subviews where v !== toastHost { v.removeFromSuperview() }
        let content: NSView
        if env.isSignedIn() {
            let section = sections[selected] ?? HubSections.make(selected)
            sections[selected] = section
            if let n = section as? NotificationsSection { connect(n) }
            content = section.view
        } else {
            content = signInView
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        detail.addSubview(content, positioned: .below, relativeTo: toastHost)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
            content.topAnchor.constraint(equalTo: detail.topAnchor),
            content.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
        ])
        if env.isSignedIn(), let section = sections[selected] { section.activate(makeContext()) }
    }

    /// 알림 섹션의 이동·배지를 창에 잇는다(섹션을 만들 때마다 같은 콜백으로 덮어쓴다).
    private func connect(_ s: NotificationsSection) {
        s.onNavigate = { [weak self] id in self?.select(id) }
        s.onBadgeChange = { [weak self] count in self?.rows[.notifications]?.setBadge(count) }
    }

    private func makeContext() -> HubContext {
        HubContext(client: env.client(),
                   toast: { [weak self] text, isError in
                       DispatchQueue.main.async { if let host = self?.toastHost { HubToastView.show(in: host, text: text, isError: isError) } }
                   },
                   confirm: { [weak self] steps, done in
                       guard let self = self else { return }
                       HubConfirm.present(from: self, steps: steps, onConfirmed: done)
                   })
    }

    /// 캡처 시험용: 지금 선택된 섹션.
    var currentSection: HubSectionBase? { sections[selected] }
    /// 캡처 시험용: 토스트가 붙는 자리.
    var toastContainer: NSView { toastHost }
}
