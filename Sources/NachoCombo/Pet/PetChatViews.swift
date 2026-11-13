import AppKit
import NachoComboCore

// The chat bubble's pieces, one view per element of the web mockup (design/web, `scenes.js` helpers and `pet.css`
// classes). Sizes, colours and fonts come from PetTheme (design/tokens.json) only.

private typealias S = PetTokens.Size
private typealias Sp = PetTokens.Space
private typealias Rd = PetTokens.Radius

/// Text with links (nachopet:// actions, https files) and tooltips, sized to its content up to `maxWidth`.
/// `.line span`, `.bubble` text, `.card .q`, `.signin p`.
final class PetLinkText: NSTextView, NSTextViewDelegate {
    var onLink: ((URL) -> Void)?
    private let maxWidth: CGFloat

    init(_ text: NSAttributedString, maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: maxWidth, height: 10), textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        delegate = self
        linkTextAttributes = [.foregroundColor: PetTheme.link, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: PetTheme.link.withAlphaComponent(0.55), .cursor: NSCursor.pointingHand]
        translatesAutoresizingMaskIntoConstraints = false
        let size = fitted
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        maxWidth = frameRect.width
        super.init(frame: frameRect, textContainer: container)
    }

    var fitted: NSSize {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return NSSize(width: min(maxWidth, ceil(used.width)), height: ceil(used.height))
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if url.scheme == "nachopet" { onLink?(url); return true }
        NSWorkspace.shared.open(url)
        return true
    }

    /// Parts → attributed text: plain, secondary (`.sep`), ok/failed marks, links and tooltips.
    static func text(_ parts: [PetTextPart], font: NSFont, color: NSColor, align: NSTextAlignment = .natural) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for part in parts {
            var a: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: PetTheme.paragraph(font, align: align)]
            switch part.style {
            case .plain: a[.foregroundColor] = color
            case .secondary: a[.foregroundColor] = color.withAlphaComponent(CGFloat(PetTokens.Opacity.separatorText))
            case .ok: a[.foregroundColor] = PetTheme.color(\.success)
            case .failed: a[.foregroundColor] = PetTheme.color(\.danger)
            }
            if let l = part.link { a[.link] = l }
            if let t = part.tooltip { a[.toolTip] = t }
            out.append(NSAttributedString(string: part.text, attributes: a))
        }
        return out
    }

    static func plain(_ s: String, font: NSFont, color: NSColor, align: NSTextAlignment = .natural) -> NSAttributedString {
        text([PetTextPart(s)], font: font, color: color, align: align)
    }
}

/// A clickable rounded label: `.opt`, `.ex`, `.older`, `.seg button`, `.file`, `.primary`, `.ibtn`, `.send`.
final class PetPill: PetBox {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let iconSize: Double
    var isEnabled = true

    init(title: String = "", symbol: String? = nil, iconSize: Double = PetTokens.Size.icon, font: NSFont = PetTheme.body,
         color: NSColor = PetTheme.text, fill: NSColor? = nil, stroke: NSColor? = nil, height: Double = PetTokens.Size.control,
         radius: Double = PetTokens.Radius.control, padding: Double = PetTokens.Space.m, width: Double? = nil) {
        self.iconSize = iconSize
        super.init(frame: .zero)
        self.fill = fill
        self.stroke = stroke
        self.radius = CGFloat(radius)
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = CGFloat(Sp.xs)
        row.translatesAutoresizingMaskIntoConstraints = false
        if let s = symbol {
            icon.image = PetTheme.symbol(s, size: iconSize)
            icon.contentTintColor = color
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: CGFloat(iconSize)).isActive = true
            icon.heightAnchor.constraint(equalToConstant: CGFloat(iconSize)).isActive = true
            row.addArrangedSubview(icon)
        }
        if !title.isEmpty {
            label.stringValue = title
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byTruncatingMiddle
            row.addArrangedSubview(label)
        }
        addSubview(row)
        heightAnchor.constraint(equalToConstant: CGFloat(height)).isActive = true
        if let w = width { widthAnchor.constraint(equalToConstant: CGFloat(w)).isActive = true }
        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: CGFloat(width == nil ? padding : 0)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -CGFloat(width == nil ? padding : 0)),
        ])
        if width == nil {
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(padding)).isActive = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? symbol : title)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title: String? = nil, symbol: String? = nil, color: NSColor? = nil, fill: NSColor?? = nil) {
        if let t = title { label.stringValue = t; setAccessibilityLabel(t) }
        if let s = symbol { icon.image = PetTheme.symbol(s, size: iconSize) }
        if let c = color { label.textColor = c; icon.contentTintColor = c }
        if let f = fill { self.fill = f }
    }

    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override func mouseDown(with event: NSEvent) { if isEnabled { alphaValue = 0.7 } }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Lays views out in rows that wrap at `maxWidth` (`flex-wrap: wrap`): option buttons, example chips, file chips.
enum PetFlow {
    static func rows(_ views: [NSView], maxWidth: CGFloat, gap: Double, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = alignment
        column.spacing = CGFloat(gap)
        var row: NSStackView?
        var used: CGFloat = 0
        for v in views {
            let w = v.fittingSize.width
            if row == nil || used + CGFloat(gap) + w > maxWidth {
                let r = NSStackView()
                r.orientation = .horizontal
                r.spacing = CGFloat(gap)
                column.addArrangedSubview(r)
                row = r
                used = 0
            } else {
                used += CGFloat(gap)
            }
            row?.addArrangedSubview(v)
            used += w
        }
        return column
    }
}

/// One row of the log (`.row`): its content on the leading or trailing side, full log width.
final class PetRow: NSView {
    init(_ content: NSView, width: CGFloat, trailing: Bool = false, center: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        var c = [widthAnchor.constraint(equalToConstant: width),
                 content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
                 content.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor)]
        if center { c.append(content.centerXAnchor.constraint(equalTo: centerXAnchor)) }
        else if trailing { c.append(content.trailingAnchor.constraint(equalTo: trailingAnchor)) }
        else { c.append(content.leadingAnchor.constraint(equalTo: leadingAnchor)) }
        NSLayoutConstraint.activate(c)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Builds the view for each transcript item. `width` is the log's inner width.
struct PetItemViews {
    let width: CGFloat
    let onLink: (URL) -> Void
    let onExample: (String) -> Void

    /// `.bubble { max-width }` at the design's width; a wider (resized) chat gives bubbles the same share of the log.
    var bubbleMaxWidth: CGFloat {
        let designLog = CGFloat(S.chatWidth - 2 * Sp.m)
        return max(CGFloat(S.bubbleMaxWidth), (width * CGFloat(S.bubbleMaxWidth) / designLog).rounded(.down))
    }

    func view(_ item: PetChatItem) -> NSView {
        switch item {
        case let .older(loading): return older(loading)
        case let .hello(title, examples): return hello(title, examples)
        case let .mine(text, attachments, past): return bubble(text, mine: true, past: past, streaming: false, attachments: attachments)
        case let .nacho(text, past, streaming): return bubble(text, mine: false, past: past, streaming: streaming, attachments: [])
        case let .line(l): return line(l)
        case let .files(chips, mine): return files(chips, mine: mine)
        case let .card(c): return card(c)
        case let .note(n): return PetRow(label(n, font: PetTheme.caption, color: PetTheme.tertiary, align: .center), width: width, center: true)
        case let .divider(d): return divider(d)
        case let .requestChip(c): return requestChip(c)
        case let .answerActions(id, open): return answerActions(id, showingSent: open)
        case let .sentContext(rows): return sentContext(rows)
        case let .selectionPreview(p): return selectionPreview(p)
        case .selectionIntro: return selectionIntro()
        }
    }

    private func label(_ s: String, font: NSFont, color: NSColor, align: NSTextAlignment = .natural, maxWidth: CGFloat? = nil) -> PetLinkText {
        let t = PetLinkText(PetLinkText.plain(s, font: font, color: color, align: align), maxWidth: maxWidth ?? width)
        t.onLink = onLink
        return t
    }

    /// `.bubble` (`.mine` / `.nacho`, `.past`, streaming caret) with the attachment names under the user's text.
    private func bubble(_ text: String, mine: Bool, past: Bool, streaming: Bool, attachments: [String]) -> NSView {
        let box = PetBox()
        box.fill = PetTheme.color(mine ? \.mineBubble : \.nachoBubble)
        let r = CGFloat(Rd.bubble), tail = CGFloat(Rd.bubbleTail)
        box.corners = mine ? (tl: r, tr: r, br: tail, bl: r) : (tl: r, tr: r, br: r, bl: tail)
        box.alphaValue = past ? CGFloat(PetTokens.Opacity.past) : 1
        let textColor = PetTheme.color(mine ? \.mineText : \.nachoText)
        let inner = bubbleMaxWidth - CGFloat(2 * Sp.m)
        let content = NSMutableAttributedString(attributedString: PetLinkText.plain(text, font: PetTheme.body, color: textColor))
        if streaming {
            content.append(NSAttributedString(string: text.isEmpty ? "…" : " ▍", attributes: [.font: PetTheme.body, .foregroundColor: PetTheme.accent]))
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = mine ? .trailing : .leading
        stack.spacing = CGFloat(Sp.xs)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let t = PetLinkText(content, maxWidth: inner)
        t.onLink = onLink
        stack.addArrangedSubview(t)
        if !attachments.isEmpty {
            let chips = attachments.map { name -> NSView in
                let isImage = PetMedia.mime(forFileName: name)?.hasPrefix("image/") == true
                return PetPill(title: name, symbol: isImage ? "photo" : "doc", iconSize: S.lineIcon, font: PetTheme.caption, color: textColor,
                               fill: PetTheme.color(\.surfaceRaised).withAlphaComponent(0.7), height: S.chipHeight, radius: Rd.chip, padding: Sp.s)
            }
            stack.addArrangedSubview(PetFlow.rows(chips, maxWidth: inner, gap: Sp.xs, alignment: .trailing))
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: CGFloat(Sp.s)),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -CGFloat(Sp.s)),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: CGFloat(Sp.m)),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -CGFloat(Sp.m)),
        ])
        box.translatesAutoresizingMaskIntoConstraints = false
        return PetRow(box, width: width, trailing: mine)
    }

    /// `.line` (tool, progress, memory, notice, danger, usage, notification): small icon + caption with links.
    private func line(_ l: PetChatLine) -> NSView {
        let color: NSColor
        switch l.kind {
        case .memory, .notice: color = PetTheme.secondary
        case .danger: color = PetTheme.color(\.danger)
        default: color = PetTheme.tertiary
        }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = CGFloat(Sp.xs)
        var textWidth = width
        if let s = l.symbol {
            let icon = NSImageView(image: PetTheme.symbol(s, size: S.lineIcon) ?? NSImage())
            icon.contentTintColor = color
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: CGFloat(S.lineIcon)).isActive = true
            icon.heightAnchor.constraint(equalToConstant: CGFloat(PetTokens.Font.caption * PetTokens.Font.lineHeight)).isActive = true
            icon.imageAlignment = .alignCenter
            row.addArrangedSubview(icon)
            textWidth -= CGFloat(S.lineIcon + Sp.xs)
        }
        let t = PetLinkText(PetLinkText.text(l.parts, font: PetTheme.caption, color: color), maxWidth: textWidth)
        t.onLink = onLink
        row.addArrangedSubview(t)
        return PetRow(row, width: width, trailing: l.alignTrailing || l.kind == .usage)
    }

    /// `.file` chips: the name is the link (underlined), "· 나초가 만듦" grey; deleted files dimmed with "· 지워짐".
    private func files(_ chips: [PetFileChip], mine: Bool) -> NSView {
        let views = chips.map { chip -> NSView in
            let box = PetBox()
            box.fill = PetTheme.color(\.surfaceRaised).withAlphaComponent(mine ? 0.7 : 1)
            box.stroke = PetTheme.color(\.separator)
            box.radius = CGFloat(Rd.chip)
            box.translatesAutoresizingMaskIntoConstraints = false
            box.heightAnchor.constraint(equalToConstant: CGFloat(S.chipHeight)).isActive = true
            if chip.deleted { box.alphaValue = CGFloat(PetTokens.Opacity.gone) }
            let nameColor = chip.deleted ? PetTheme.tertiary : (mine ? PetTheme.color(\.mineText) : PetTheme.link)
            let icon = NSImageView(image: PetTheme.symbol(chip.isImage ? "photo" : "doc", size: S.lineIcon) ?? NSImage())
            icon.contentTintColor = nameColor
            var parts = [PetTextPart(chip.name, link: chip.url)]
            if chip.deleted { parts.append(PetTextPart(" · 지워짐")) } else if chip.byNacho { parts.append(PetTextPart(" · 나초가 만듦")) }
            let text = NSMutableAttributedString(attributedString: PetLinkText.text(parts, font: PetTheme.caption, color: PetTheme.tertiary))
            if chip.url == nil { text.addAttribute(.foregroundColor, value: nameColor, range: NSRange(location: 0, length: (chip.name as NSString).length)) }
            let t = PetLinkText(text, maxWidth: width - CGFloat(S.lineIcon + 3 * Sp.s))
            t.onLink = onLink
            let row = NSStackView(views: [icon, t])
            row.spacing = CGFloat(Sp.xs)
            row.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: CGFloat(Sp.s)),
                row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -CGFloat(Sp.s)),
            ])
            return box
        }
        return PetRow(PetFlow.rows(views, maxWidth: width, gap: Sp.xs, alignment: mine ? .trailing : .leading), width: width, trailing: mine)
    }

    /// `.card`: question, detail, option buttons (`.opt`), and a note only where it adds something.
    private func card(_ c: PetCardItem) -> NSView {
        let box = PetBox()
        box.fill = PetTheme.color(\.surfaceRaised)
        box.stroke = PetTheme.color(\.separator)
        box.radius = CGFloat(Rd.card)
        box.translatesAutoresizingMaskIntoConstraints = false
        let inner = width - CGFloat(2 * Sp.m)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CGFloat(Sp.s)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: PetTheme.symbol(c.symbol, size: S.icon) ?? NSImage())
        icon.contentTintColor = PetTheme.accent
        let q = PetLinkText(PetLinkText.plain(c.title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium), color: PetTheme.text),
                            maxWidth: inner - CGFloat(S.icon + Sp.s))
        let head = NSStackView(views: [icon, q])
        head.alignment = .top
        head.spacing = CGFloat(Sp.s)
        stack.addArrangedSubview(head)
        if let d = c.detail { stack.addArrangedSubview(label(d, font: PetTheme.caption, color: PetTheme.secondary, maxWidth: inner)) }
        if !c.options.isEmpty {
            let buttons = c.options.map { o -> NSView in
                let b = PetPill(title: o.label, fill: PetTheme.color(o.chosen ? \.accentSoft : \.surface),
                                stroke: o.chosen ? PetTheme.accent : PetTheme.color(\.separator))
                b.isEnabled = o.link != nil
                if let l = o.link { b.onClick = { onLink(l) } }
                return b
            }
            stack.addArrangedSubview(PetFlow.rows(buttons, maxWidth: inner, gap: Sp.s))
        }
        if let s = c.status {
            stack.addArrangedSubview(label(s, font: PetTheme.caption, color: c.statusWaits ? PetTheme.color(\.warning) : PetTheme.tertiary, maxWidth: inner))
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: CGFloat(Sp.m)),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -CGFloat(Sp.m)),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: CGFloat(Sp.m)),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -CGFloat(Sp.m)),
        ])
        return box
    }

    /// `.older`: "이전 대화 더 보기" as a small link chip.
    private func older(_ loading: Bool) -> NSView {
        let b = PetPill(title: loading ? "이전 대화 불러오는 중…" : "이전 대화 더 보기", symbol: loading ? nil : "chevron.up",
                        iconSize: S.badgeIcon, font: PetTheme.caption, color: loading ? PetTheme.tertiary : PetTheme.link,
                        fill: PetTheme.color(\.surface), height: S.chipHeight, radius: Rd.chip, padding: Sp.s)
        b.isEnabled = !loading
        b.onClick = { onLink(PetLinks.url("older")) }
        return PetRow(b, width: width, center: true)
    }

    /// `.hello`: centred question and example chips (`.ex`); a chip puts its text in the input field.
    private func hello(_ title: String, _ examples: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = CGFloat(Sp.s)
        stack.addArrangedSubview(label(title, font: PetTheme.title, color: PetTheme.text, align: .center))
        let chips = examples.map { e -> NSView in
            let b = PetPill(title: e, font: PetTheme.caption, color: PetTheme.secondary, fill: PetTheme.color(\.surface),
                            stroke: PetTheme.color(\.separator), height: S.chipHeight, radius: Rd.chip)
            b.onClick = { onExample(e) }
            return b
        }
        stack.addArrangedSubview(PetFlow.rows(chips, maxWidth: width, gap: Sp.xs, alignment: .centerX))
        return PetRow(stack, width: width, center: true)
    }

    /// `.divider`: hairline · label · hairline.
    private func divider(_ text: String) -> NSView {
        func hair() -> NSView {
            let v = PetBox()
            v.fill = PetTheme.color(\.separator)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return v
        }
        let a = hair(), b = hair()
        let row = NSStackView(views: [a, label(text, font: PetTheme.caption, color: PetTheme.tertiary), b])
        row.spacing = CGFloat(Sp.s)
        a.widthAnchor.constraint(equalTo: b.widthAnchor).isActive = true
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }
}

/// The window's background: `.chat` (rounded, 1 pt edge) with the tail (`.chat::after`) pointing at the pet.
final class PetChatBackground: NSView {
    /// Tail centre measured from the right edge; on the bottom (pet below) or the top (pet above).
    var tailFromRight: CGFloat = CGFloat(S.pet / 2) { didSet { needsDisplay = true } }
    var tailOnTop = false { didSet { needsDisplay = true } }

    static var tail: CGFloat { CGFloat(S.chatTail) }

    var bodyRect: NSRect {
        tailOnTop ? NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - PetChatBackground.tail)
            : NSRect(x: 0, y: PetChatBackground.tail, width: bounds.width, height: bounds.height - PetChatBackground.tail)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bodyRect.insetBy(dx: 0.5, dy: 0.5)
        let r = CGFloat(Rd.window), t = PetChatBackground.tail
        let path = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
        let cx = bounds.width - tailFromRight
        let tail = NSBezierPath()
        if tailOnTop {
            tail.move(to: NSPoint(x: cx - t, y: body.maxY - 1))
            tail.line(to: NSPoint(x: cx, y: body.maxY + t - 1))
            tail.line(to: NSPoint(x: cx + t, y: body.maxY - 1))
        } else {
            tail.move(to: NSPoint(x: cx - t, y: body.minY + 1))
            tail.line(to: NSPoint(x: cx, y: body.minY - t + 1))
            tail.line(to: NSPoint(x: cx + t, y: body.minY + 1))
        }
        tail.close()
        path.append(tail)
        path.windingRule = .nonZero
        PetTheme.color(\.window).setFill()
        path.fill()
        PetTheme.color(\.edge).setStroke()
        let outline = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
        outline.lineWidth = 1
        outline.stroke()
        // The tail's two outer sides carry the edge; the base is covered by the window colour.
        let edge = NSBezierPath()
        if tailOnTop {
            edge.move(to: NSPoint(x: cx - t, y: body.maxY)); edge.line(to: NSPoint(x: cx, y: body.maxY + t - 1)); edge.line(to: NSPoint(x: cx + t, y: body.maxY))
        } else {
            edge.move(to: NSPoint(x: cx - t, y: body.minY)); edge.line(to: NSPoint(x: cx, y: body.minY - t + 1)); edge.line(to: NSPoint(x: cx + t, y: body.minY))
        }
        PetTheme.color(\.window).setStroke()
        let cover = NSBezierPath()
        cover.move(to: NSPoint(x: cx - t + 1.5, y: tailOnTop ? body.maxY : body.minY))
        cover.line(to: NSPoint(x: cx + t - 1.5, y: tailOnTop ? body.maxY : body.minY))
        cover.lineWidth = 2
        cover.stroke()
        PetTheme.color(\.edge).setStroke()
        edge.lineWidth = 1
        edge.stroke()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The recording mark in the input field while listening (`.wave`).
final class PetWave: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 6 * 3 + 5 * 2, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        PetTheme.color(\.danger).setFill()
        for (i, h) in [6.0, 12, 9, 15, 7, 11].enumerated() {
            let r = NSRect(x: CGFloat(i) * 5, y: (bounds.height - CGFloat(h)) / 2, width: 3, height: CGFloat(h))
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// The input field's capsule (`.field`) with the focus ring (`.field.focus`).
final class PetFieldBox: PetBox {
    var focused = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        if focused {
            PetTheme.color(\.focusRing).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        }
        let inner = bounds.insetBy(dx: focused ? 2 : 0.5, dy: focused ? 2 : 0.5)
        let p = NSBezierPath(roundedRect: inner, xRadius: inner.height / 2, yRadius: inner.height / 2)
        PetTheme.color(\.surfaceRaised).setFill()
        p.fill()
        (focused ? PetTheme.accent : PetTheme.color(\.separator)).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}
