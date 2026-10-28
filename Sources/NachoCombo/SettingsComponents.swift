import AppKit
import NachoComboCore

/// A capsule with a word or two: a status ("Allowed", "Not allowed") or, with `onPress`, a small button
/// ("Allow Accessibility…", "1 needs Accessibility ›"). Its height is fixed by the font, so swapping a status line for a
/// chip never moves what is around it.
final class Chip: NSView {
    enum Tone { case attention, success, neutral, lid }

    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) } }
    var tone: Tone { didSet { needsDisplay = true } }
    var symbol: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var onPress: (() -> Void)? {
        didSet {
            setAccessibilityRole(onPress == nil ? .staticText : .button)
            window?.invalidateCursorRects(for: self)
        }
    }
    private let font: NSFont
    private var pressed = false { didSet { needsDisplay = true } }

    static let height: CGFloat = 20

    init(_ title: String, tone: Tone, symbol: String? = nil, font: NSFont = Brand.mono(10.5),
         onPress: (() -> Void)? = nil) {
        self.title = title
        self.tone = tone
        self.symbol = symbol
        self.font = font
        self.onPress = onPress
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(onPress == nil ? .staticText : .button)
        setAccessibilityLabel(title)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    private var symbolImage: NSImage? {
        symbol.flatMap { UI.symbol($0, size: font.pointSize - 1, weight: .semibold) }
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        let image = symbolImage.map { $0.size.width + 3 } ?? 0
        return NSSize(width: ceil(text + image + 16), height: Chip.height)
    }

    private var colors: (fill: NSColor, stroke: NSColor?, text: NSColor) {
        switch tone {
        case .attention: return (Brand.nachoDeep.withAlphaComponent(pressed ? 0.30 : 0.16), Brand.nachoInk, Brand.nachoInk)
        case .success: return (Brand.guac.withAlphaComponent(0.14), Brand.guac, Brand.guac)
        case .neutral: return (Brand.ink.withAlphaComponent(pressed ? 0.12 : 0.05), Brand.ink2.withAlphaComponent(0.6), Brand.ink2)
        case .lid: return (pressed ? Brand.board2 : Brand.onNacho, nil, Brand.nacho)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = colors
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: bounds.height / 2 - 0.75,
                                 yRadius: bounds.height / 2 - 0.75)
        c.fill.setFill()
        shape.fill()
        if let stroke = c.stroke {
            stroke.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: c.text]
        let textSize = (title as NSString).size(withAttributes: attributes)
        var x = (bounds.width - intrinsicContentSize.width) / 2 + 8
        if let image = symbolImage {
            let tinted = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [c.text])) ?? image
            tinted.draw(in: NSRect(x: x, y: (bounds.height - image.size.height) / 2, width: image.size.width,
                                   height: image.size.height), from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            x += image.size.width + 3
        }
        let available = bounds.width - x - 6
        (title as NSString).draw(with: NSRect(x: x, y: (bounds.height - textSize.height) / 2, width: available,
                                              height: textSize.height),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: input

    override var acceptsFirstResponder: Bool { onPress != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { onPress != nil }
    override func resetCursorRects() { if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func hitTest(_ point: NSPoint) -> NSView? {
        onPress == nil ? nil : super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) { if onPress != nil { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: onPress?()
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return onPress != nil }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A grouped surface tinted by what it asks for: orange = you have to do something, green = done, accent = a tip.
final class TintedCardView: NSView {
    enum Tone { case attention, success, accent }
    var tone: Tone { didSet { needsDisplay = true } }

    init(tone: Tone, content: NSView, padding: CGFloat = 12) {
        self.tone = tone
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding - 1),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor, stroke: NSColor
        switch tone {
        case .attention: fill = Brand.nachoDeep.withAlphaComponent(0.12); stroke = Brand.nachoDeep.withAlphaComponent(0.7)
        case .success: fill = Brand.guac.withAlphaComponent(0.12); stroke = Brand.guac.withAlphaComponent(0.6)
        case .accent: fill = Brand.nacho.withAlphaComponent(0.18); stroke = Brand.nachoInk.withAlphaComponent(0.6)
        }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 14, yRadius: 14)
        fill.setFill()
        shape.fill()
        stroke.setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The number in front of a step: plain while it is to do, orange while it is the step to do now, a green check once done.
final class StepNumberView: NSView {
    enum State { case todo, current, done }
    let number: Int
    var state: State = .todo { didSet { needsDisplay = true } }
    static let size: CGFloat = 20

    init(_ number: Int) {
        self.number = number
        super.init(frame: NSRect(x: 0, y: 0, width: StepNumberView.size, height: StepNumberView.size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: StepNumberView.size).isActive = true
        heightAnchor.constraint(equalToConstant: StepNumberView.size).isActive = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        switch state {
        case .todo:
            Brand.paper.setFill()
            circle.fill()
            Brand.line.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            Draw.text("\(number)", in: bounds, font: Brand.sign(11.5), color: Brand.ink, align: .center)
        case .current:
            Brand.nachoDeep.setFill()
            circle.fill()
            Draw.text("\(number)", in: bounds, font: Brand.sign(11.5), color: Brand.onNacho, align: .center)
        case .done:
            DotPalette.green.setFill()
            circle.fill()
            if let check = UI.symbol("checkmark", size: 10, weight: .bold) {
                let tinted = check.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? check
                let s = tinted.size
                tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width,
                                       height: s.height), from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension UI {
    /// A push button that runs a closure. `primary` tints it with the accent color without making it the window's
    /// default button (Return keeps working on tiles and fields).
    static func pushButton(_ title: String, symbol: String? = nil, primary: Bool = false, small: Bool = false,
                           handler: @escaping () -> Void) -> NSButton {
        // The one main action of a card is drawn in the brand; the rest stay native push buttons.
        if primary && symbol == nil { return BrandButton(title, style: .primary, small: small, handler: handler) }
        let b = ClosureButton(title: title, handler: handler)
        b.bezelStyle = .rounded
        b.font = UI.controlFont(small ? .subheadline : .callout)
        if small { b.controlSize = .small }
        if let symbol = symbol, let image = UI.symbol(symbol, size: 12, weight: .medium) {
            b.image = image
            b.imagePosition = .imageLeading
        }
        return b
    }

    /// A section title above a grouped card.
    static func sectionTitle(_ text: String) -> NSTextField {
        let label = UI.label(text, style: .headline, weight: .bold)
        label.setAccessibilityRole(.staticText)
        return label
    }

    /// "⚠ text" in the attention color, wrapped to `width`.
    static func attentionNote(_ text: String, width: CGFloat, style: NSFont.TextStyle = .subheadline) -> NSTextField {
        let label = UI.wrapLabel("", width: width, style: style, color: UI.attentionText)
        label.attributedStringValue = UI.notice(text, tint: DotPalette.orange, style: style)
        let tinted = NSMutableAttributedString(attributedString: label.attributedStringValue)
        tinted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: tinted.length)) { value, range, _ in
            if value != nil { tinted.addAttribute(.foregroundColor, value: UI.attentionText, range: range) }
        }
        label.attributedStringValue = tinted
        label.setAccessibilityValue(text)
        return label
    }
}
