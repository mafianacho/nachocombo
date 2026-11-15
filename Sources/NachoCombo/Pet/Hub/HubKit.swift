import AppKit
import NachoComboCore

/// 나초 앱 창(허브)의 공용 화면 부품. 색·크기·글꼴은 모두 `PetTheme`/`PetTokens`에서 가져온다(라이트·다크 둘 다 따른다).
/// 섹션은 이 부품만 조합한다. 이 파일은 공용이라 섹션 이슈가 고치지 않는다(필요하면 자기 파일에 extension).
enum HubKit {
    typealias Sp = PetTokens.Space
    typealias Rad = PetTokens.Radius

    static func label(_ text: String, font: NSFont = PetTheme.body, color: NSColor = PetTheme.text, wrap: Bool = true) -> NSTextField {
        let f = wrap ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.isSelectable = false
        f.translatesAutoresizingMaskIntoConstraints = false
        if wrap { f.maximumNumberOfLines = 0 }
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }

    static func vstack(_ views: [NSView], spacing: Double = Sp.m) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = CGFloat(spacing)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func hstack(_ views: [NSView], spacing: Double = Sp.s) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = CGFloat(spacing)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// 세로 스택의 자식을 스택 너비에 맞춘다(여러 줄 글이 줄바꿈되도록).
    static func fill(_ stack: NSStackView, _ views: [NSView]) {
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    /// 자식을 부모 가장자리에 붙인다.
    static func pin(_ child: NSView, in parent: NSView, inset: Double = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        let i = CGFloat(inset)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: i),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -i),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: i),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -i),
        ])
    }

    static func primaryButton(_ title: String, symbol: String? = nil, danger: Bool = false, onClick: @escaping () -> Void) -> PetPill {
        let p = PetPill(title: title, symbol: symbol, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium),
                        color: danger ? PetTheme.color(\.onDanger) : PetTheme.color(\.onAccent),
                        fill: danger ? PetTheme.color(\.danger) : PetTheme.accent, padding: Sp.l)
        p.onClick = onClick
        return p
    }

    static func secondaryButton(_ title: String, symbol: String? = nil, onClick: @escaping () -> Void) -> PetPill {
        let p = PetPill(title: title, symbol: symbol, color: PetTheme.text, fill: PetTheme.color(\.surfaceRaised),
                        stroke: PetTheme.color(\.edge), padding: Sp.l)
        p.onClick = onClick
        return p
    }

    /// 위에서부터 쌓이는 스크롤 영역(위가 기준인 문서 뷰).
    static func scrollingStack(spacing: Double = Sp.m, inset: Double = Sp.l) -> (scroll: NSScrollView, stack: NSStackView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = HubFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        let stack = vstack([], spacing: spacing)
        doc.addSubview(stack)
        let i = CGFloat(inset)
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: i),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -i),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: i),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -i),
        ])
        return (scroll, stack)
    }
}

final class HubFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 클릭을 아래로 흘려 보내는 겹침 뷰(토스트 자리).
final class HubPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// ISO 8601(`2026-11-20T00:00:00Z`, 소수점 초 있어도 됨)를 "11월 20일 09:00"로. 읽지 못하면 원문 그대로.
enum HubFormat {
    static func date(_ iso: String?) -> String? {
        guard let iso = iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        var d = f.date(from: iso)
        if d == nil {
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            d = f.date(from: iso)
        }
        guard let date = d else { return iso }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ko_KR")
        out.dateFormat = "M월 d일 HH:mm"
        return out.string(from: date)
    }

    static func number(_ n: Int) -> String { PetText.number(n) }
}

// MARK: - 목록·상세·상태

enum HubViewState: Equatable {
    case loading
    case empty(String)
    case failed(String)
    case content
}

/// 불러오는 중 / 빈 상태 / 오류(다시 시도) / 내용을 한 자리에서 바꿔 보여 준다. 섹션의 뿌리 뷰.
final class HubStateView: NSView {
    /// 내용이 들어갈 자리(`.content`일 때만 보인다).
    let contentHost = NSView()
    var onRetry: (() -> Void)?
    private(set) var state: HubViewState = .content
    private let overlay = HubKit.vstack([], spacing: Double(PetTokens.Space.m))
    private let spinner = NSProgressIndicator()
    private let message = HubKit.label("", color: PetTheme.secondary)
    private let icon = NSImageView()
    private var retry: PetPill!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        HubKit.pin(contentHost, in: self)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        message.alignment = .center
        retry = HubKit.secondaryButton("다시 시도", symbol: "arrow.clockwise") { [weak self] in self?.onRetry?() }
        overlay.alignment = .centerX
        for v in [icon, spinner, message, retry] as [NSView] { overlay.addArrangedSubview(v) }
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            overlay.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
        show(.content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ s: HubViewState) {
        state = s
        contentHost.isHidden = s != .content
        overlay.isHidden = s == .content
        spinner.isHidden = s != .loading
        if s == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        retry.isHidden = true
        icon.isHidden = true
        switch s {
        case .loading:
            message.stringValue = "불러오는 중…"
        case let .empty(text):
            message.stringValue = text
            icon.image = PetTheme.symbol("tray", size: 28)
            icon.contentTintColor = PetTheme.tertiary
            icon.isHidden = false
        case let .failed(text):
            message.stringValue = text
            icon.image = PetTheme.symbol("exclamationmark.triangle", size: 28)
            icon.contentTintColor = PetTheme.color(\.warning)
            icon.isHidden = false
            retry.isHidden = false
        case .content:
            break
        }
    }
}

/// 목록 한 줄: 제목·보조 글·오른쪽 글(선택). 눌리면 `onClick`.
final class HubRow: PetBox {
    var onClick: (() -> Void)?

    init(title: String, subtitle: String? = nil, trailing: String? = nil, symbol: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = PetTheme.color(\.surface)
        stroke = PetTheme.color(\.edge)
        radius = CGFloat(Rad.card)
        var left: [NSView] = []
        if let s = symbol {
            let i = NSImageView()
            i.image = PetTheme.symbol(s, size: PetTokens.Size.icon)
            i.contentTintColor = PetTheme.accent
            i.translatesAutoresizingMaskIntoConstraints = false
            left.append(i)
        }
        let texts = HubKit.vstack([HubKit.label(title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium))], spacing: Double(Sp.xxs))
        if let sub = subtitle, !sub.isEmpty { texts.addArrangedSubview(HubKit.label(sub, font: PetTheme.caption, color: PetTheme.secondary)) }
        var views = left + [texts]
        if let t = trailing, !t.isEmpty { views.append(HubKit.label(t, font: PetTheme.caption, color: PetTheme.secondary, wrap: false)) }
        let row = HubKit.hstack(views, spacing: Double(Sp.m))
        addSubview(row)
        let p = CGFloat(Sp.m)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            row.topAnchor.constraint(equalTo: topAnchor, constant: p),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        if let c = onClick { c() } else { super.mouseDown(with: event) }
    }
}

/// 커서 목록: 줄들 + 「더 보기」. 비어 있으면 빈 상태를 보여 준다.
final class HubListView: NSView {
    let scroll: NSScrollView
    private let stack: NSStackView
    private let more: PetPill
    var onLoadMore: (() -> Void)?

    override init(frame: NSRect) {
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.s))
        scroll = parts.scroll
        stack = parts.stack
        more = HubKit.secondaryButton("더 보기") {}
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        more.onClick = { [weak self] in self?.onLoadMore?() }
        HubKit.pin(scroll, in: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 줄을 바꾼다. `hasMore`면 끝에 「더 보기」를 둔다.
    func setRows(_ rows: [NSView], hasMore: Bool) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        for r in rows { stack.addArrangedSubview(r) }
        HubKit.fill(stack, rows)
        if hasMore { stack.addArrangedSubview(more) }
    }

    func appendRows(_ rows: [NSView], hasMore: Bool) {
        stack.removeArrangedSubview(more)
        more.removeFromSuperview()
        for r in rows { stack.addArrangedSubview(r) }
        HubKit.fill(stack, rows)
        if hasMore { stack.addArrangedSubview(more) }
    }
}

/// 상세: 제목 + 이름/값 줄들 + 단추.
final class HubDetailView: NSView {
    let scroll: NSScrollView
    let stack: NSStackView

    init(title: String, fields: [(String, String)], actions: [NSView] = []) {
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        scroll = parts.scroll
        stack = parts.stack
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        HubKit.pin(scroll, in: self)
        stack.addArrangedSubview(HubKit.label(title, font: PetTheme.title))
        for (k, v) in fields {
            let row = HubKit.vstack([HubKit.label(k, font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(v)], spacing: Double(Sp.xxs))
            stack.addArrangedSubview(row)
            HubKit.fill(stack, [row])
        }
        if !actions.isEmpty { stack.addArrangedSubview(HubKit.hstack(actions)) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - 폼·스위치

/// 입력 칸 + 검증 문구. `validator`가 한국어 문구를 돌려주면 그 문구를 빨갛게 보여 준다(nil이면 통과).
final class HubFormField: NSView {
    let field = NSTextField()
    private let title: NSTextField
    private let error = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
    var validator: ((String) -> String?)?

    var value: String { field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(title: String, placeholder: String = "", validator: ((String) -> String?)? = nil) {
        self.title = HubKit.label(title, font: PetTheme.caption, color: PetTheme.secondary)
        self.validator = validator
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.font = PetTheme.body
        field.translatesAutoresizingMaskIntoConstraints = false
        error.isHidden = true
        let s = HubKit.vstack([self.title, field, error], spacing: Double(Sp.xs))
        HubKit.pin(s, in: self)
        HubKit.fill(s, [self.title, field, error])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// 검사해서 문구를 보여 주고, 통과하면 true.
    @discardableResult
    func validate() -> Bool {
        let problem = validator?(value)
        error.stringValue = problem ?? ""
        error.isHidden = problem == nil
        return problem == nil
    }

    /// 서버가 준 오류 문구(한국어)를 이 칸 아래에 보여 준다.
    func showServerError(_ text: String) {
        error.stringValue = text
        error.isHidden = false
    }

    /// 자주 쓰는 규칙: 빈 값 금지 + 최대 길이.
    static func nonEmpty(_ name: String, maxLength: Int) -> (String) -> String? {
        { v in
            if v.isEmpty { return "\(name)을(를) 입력해 주세요." }
            if v.count > maxLength { return "\(name)은(는) \(maxLength)자까지 쓸 수 있어요." }
            return nil
        }
    }
}

/// 제목 + 설명 + 스위치 한 줄.
final class HubSwitchRow: NSView {
    let toggle = NSSwitch()
    var onChange: ((Bool) -> Void)?

    init(title: String, detail: String? = nil, isOn: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let texts = HubKit.vstack([HubKit.label(title)], spacing: Double(Sp.xxs))
        if let d = detail, !d.isEmpty { texts.addArrangedSubview(HubKit.label(d, font: PetTheme.caption, color: PetTheme.secondary)) }
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        let row = HubKit.hstack([texts, toggle], spacing: Double(Sp.m))
        HubKit.pin(row, in: self)
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func changed() { onChange?(toggle.state == .on) }
}

// MARK: - 이중 확인창

struct HubConfirmStep {
    var title: String
    var message: String
    var confirmTitle: String
    var destructive = true
}

/// 확인창 한 장. 시트로 띄우는 것과 캡처 시험이 같은 뷰를 쓴다.
final class HubConfirmCard: PetBox {
    static let width: CGFloat = 380

    init(step: HubConfirmStep, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = PetTheme.color(\.surfaceRaised)
        stroke = PetTheme.color(\.edge)
        radius = CGFloat(Rad.window)
        let cancel = HubKit.secondaryButton("취소", onClick: onCancel)
        let ok = HubKit.primaryButton(step.confirmTitle, danger: step.destructive, onClick: onConfirm)
        let buttons = HubKit.hstack([cancel, ok])
        let body = HubKit.label(step.message, color: PetTheme.secondary)
        let title = HubKit.label(step.title, font: PetTheme.title)
        let s = HubKit.vstack([title, body, buttons], spacing: Double(Sp.l))
        addSubview(s)
        let p = CGFloat(Sp.xl)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: HubConfirmCard.width),
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            s.topAnchor.constraint(equalTo: topAnchor, constant: p),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
        ])
        HubKit.fill(s, [title, body])
        buttons.trailingAnchor.constraint(equalTo: s.trailingAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

enum HubConfirm {
    /// 되돌릴 수 없는 동작은 확인창을 단계마다 한 번씩(보통 두 번) 거친다. 서버 미리보기가 있으면 첫 단계 `message`에 넣는다.
    /// 마지막 단계에서 확인해야만 `onConfirmed`가 불린다.
    static func present(from window: NSWindow, steps: [HubConfirmStep], onConfirmed: @escaping () -> Void) {
        guard let first = steps.first else { onConfirmed(); return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let finish: (Bool) -> Void = { ok in
            window.endSheet(panel)
            panel.orderOut(nil)
            guard ok else { return }
            if steps.count > 1 { present(from: window, steps: Array(steps.dropFirst()), onConfirmed: onConfirmed) } else { onConfirmed() }
        }
        let card = HubConfirmCard(step: first, onCancel: { finish(false) }, onConfirm: { finish(true) })
        let host = NSView()
        HubKit.pin(card, in: host, inset: 8)
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        window.beginSheet(panel, completionHandler: nil)
    }
}

// MARK: - 토스트

final class HubToastView: PetBox {
    init(text: String, isError: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = isError ? PetTheme.color(\.danger) : PetTheme.color(\.tooltip)
        radius = CGFloat(Rad.chip)
        let l = HubKit.label(text, color: isError ? PetTheme.color(\.onDanger) : PetTheme.color(\.onTooltip), wrap: false)
        addSubview(l)
        let h = CGFloat(Sp.l), v = CGFloat(Sp.s)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: h),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -h),
            l.topAnchor.constraint(equalTo: topAnchor, constant: v),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -v),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `host` 아래 가운데에 띄운다. `duration`이 nil이면 그대로 둔다(캡처 시험).
    @discardableResult
    static func show(in host: NSView, text: String, isError: Bool = false, duration: TimeInterval? = 2.5) -> HubToastView {
        let t = HubToastView(text: text, isError: isError)
        host.addSubview(t)
        NSLayoutConstraint.activate([
            t.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            t.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -CGFloat(Sp.xl)),
        ])
        if let d = duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak t] in t?.removeFromSuperview() }
        }
        return t
    }
}
