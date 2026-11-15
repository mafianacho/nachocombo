import AppKit
import NachoComboCore

private typealias Sp = PetTokens.Space

/// Small drawing parts of the Connections tab (NACHO-239): text labels that wrap Korean between words, a row with
/// name / one status line / a switch, and the closure-driven switch and button. They hold no state of their own.
enum PetConnectionsParts {
    static func label(_ text: String, font: NSFont = PetTheme.body, color: NSColor = PetTheme.text, width: CGFloat,
                      lines: Int = 0) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: "")
        let para = PetTheme.paragraph(font)
        if lines == 1 { (para as? NSMutableParagraphStyle)?.lineBreakMode = .byTruncatingTail }
        f.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        f.isSelectable = false
        f.maximumNumberOfLines = lines
        f.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        f.preferredMaxLayoutWidth = width
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return f
    }

    static func toneColor(_ tone: ConnectionsTone) -> NSColor {
        switch tone {
        case .normal: return PetTheme.secondary
        case .attention: return PetTheme.color(\.warning)
        case .off: return PetTheme.tertiary
        }
    }

    static func vstack(_ views: [NSView], spacing: Double = Sp.s, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = alignment
        s.spacing = CGFloat(spacing)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func hstack(_ views: [NSView], spacing: Double = Sp.s, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = alignment
        s.spacing = CGFloat(spacing)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    /// A box with token fill and padding around one child.
    static func card(_ child: NSView, fill: NSColor, width: CGFloat, padding: Double = Sp.m, stroke: NSColor? = nil) -> PetBox {
        let box = PetBox()
        box.fill = fill
        box.stroke = stroke
        box.radius = CGFloat(PetTokens.Radius.card)
        box.translatesAutoresizingMaskIntoConstraints = false
        child.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(child)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            child.topAnchor.constraint(equalTo: box.topAnchor, constant: CGFloat(padding)),
            child.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -CGFloat(padding)),
            child.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: CGFloat(padding)),
            child.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -CGFloat(padding)),
        ])
        return box
    }

    static func pill(_ title: String, symbol: String? = nil, color: NSColor = PetTheme.text, fill: NSColor? = PetTheme.color(\.surface),
                     stroke: NSColor? = nil, onClick: @escaping () -> Void) -> PetPill {
        let p = PetPill(title: title, symbol: symbol, iconSize: PetTokens.Size.lineIcon, font: PetTheme.caption, color: color, fill: fill,
                        stroke: stroke, height: PetTokens.Size.control, radius: PetTokens.Radius.control, padding: Sp.m)
        p.onClick = onClick
        return p
    }
}

/// An NSSwitch that tells a closure instead of needing a target.
final class PetToggle: NSSwitch {
    var onToggle: ((Bool) -> Void)?

    convenience init(on: Bool, label: String, onToggle: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        controlSize = .small
        state = on ? .on : .off
        self.onToggle = onToggle
        target = self
        action = #selector(changed)
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func changed() { onToggle?(state == .on) }
}

/// One row of the list: name, one status line, then the control (a switch, a lock, or a short reason) and a chevron.
/// Pressing the row (not the switch) opens the detail.
final class PetConnectionsRowView: PetBox {
    var onOpen: (() -> Void)?
    private(set) var toggle: PetToggle?
    let row: ConnectionsRow

    init(row: ConnectionsRow, width: CGFloat, onToggle: @escaping (Bool) -> Void, onOpen: @escaping () -> Void) {
        self.row = row
        self.onOpen = onOpen
        super.init(frame: .zero)
        fill = PetTheme.color(\.surface)
        radius = CGFloat(PetTokens.Radius.card)
        translatesAutoresizingMaskIntoConstraints = false

        let control: NSView
        var controlWidth: CGFloat = 44
        switch row.control {
        case .on, .off:
            let t = PetToggle(on: row.control.isOn, label: row.title + " 켜기/끄기", onToggle: onToggle)
            toggle = t
            control = t
        case .locked:
            let img = NSImageView(image: PetTheme.symbol("lock.fill", size: PetTokens.Size.lineIcon) ?? NSImage())
            img.contentTintColor = PetTheme.tertiary
            img.toolTip = "나초가 대화하는 데 꼭 필요한 기본 도구예요. 끌 수 없어요."
            img.setAccessibilityLabel("잠김: 끌 수 없는 기본 도구")
            img.translatesAutoresizingMaskIntoConstraints = false
            control = img
            controlWidth = 24
        case let .fixed(reason):
            let l = PetConnectionsParts.label(reason, font: PetTheme.caption, color: PetTheme.tertiary, width: 96, lines: 2)
            control = l
            controlWidth = 96
        }
        let chevron = NSImageView(image: PetTheme.symbol("chevron.right", size: 10, weight: .semibold) ?? NSImage())
        chevron.contentTintColor = PetTheme.tertiary
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let textWidth = width - CGFloat(2 * Sp.m) - controlWidth - 10 - CGFloat(2 * Sp.s)
        let title = PetConnectionsParts.label(row.title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium), width: textWidth, lines: 1)
        let status = PetConnectionsParts.label(row.status, font: PetTheme.caption, color: PetConnectionsParts.toneColor(row.tone), width: textWidth, lines: 1)
        let text = PetConnectionsParts.vstack([title, status], spacing: 1)
        let line = PetConnectionsParts.hstack([text, control, chevron], spacing: Sp.s)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        addSubview(line)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            line.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Sp.s + 2)),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Sp.s + 2)),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Sp.m)),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Sp.m)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(row.title), \(row.status)")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.7 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }
}
