import AppKit
import NachoComboCore

/// Shared look of the popover and the settings window. Everything follows the system: text styles instead of fixed
/// point sizes, semantic colors (light/dark, accent color), SF Symbols, standard controls on an 8 pt rhythm.
enum UI {
    static let panelWidth: CGFloat = 320
    /// Outer margin of the popover content (8 pt rhythm).
    static let margin: CGFloat = 16

    /// System "Reduce motion". The app has no animations of its own (the popover is shown with `animates = false`
    /// and no view or window animates), so this only has to stay true: nothing may start moving when it is on.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// System font from a Human Interface Guidelines text style (follows the user's system type settings).
    static func font(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        return NSFont.systemFont(ofSize: base.pointSize, weight: weight)
    }

    static func digitsFont(_ style: NSFont.TextStyle) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: .regular)
    }

    static func label(_ text: String, style: NSFont.TextStyle = .callout, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let f = LiveLabel(labelWithString: text)
        f.font = font(style, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    /// Wrapping label with a fixed width so Auto Layout can compute the height before the popover is sized.
    static func wrapLabel(_ text: String, width: CGFloat, style: NSFont.TextStyle = .subheadline,
                          color: NSColor = UI.secondaryText) -> NSTextField {
        let f = LiveLabel(wrappingLabelWithString: text)
        f.isSelectable = false          // read-only text: no I-beam, no selection
        f.attributedStringValue = styled(text, font: font(style), color: color, joinWords: true)
        f.setAccessibilityValue(text)
        f.restyle = { styled(text, font: font(style), color: color, joinWords: true) }
        f.preferredMaxLayoutWidth = width
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return f
    }

    /// U+2060 WORD JOINER: invisible, keeps the glyphs of one Korean word together. NSTextField ignores
    /// `lineBreakStrategy`, so Korean text was broken between syllables ("켜 / 둔"); with the joiners a line can only
    /// break at a space, i.e. between words, and every line is filled up to the last word that fits.
    static let wordJoiner = "\u{2060}"

    static func joinHangulWords(_ text: String) -> String {
        var out = ""
        var previousIsHangul = false
        for ch in text {
            let isHangul = ch.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } ?? false
            if isHangul && previousIsHangul { out += wordJoiner }
            out.append(ch)
            previousIsHangul = isHangul
        }
        return out
    }

    /// Text with the control key glyph (U+2303) replaced by the SF Symbol `control`: in the system fonts U+2303 is a
    /// tiny caret that reads as the ASCII "^". The symbol is tinted with the text color and sized to the cap height;
    /// where the symbol does not exist the glyph stays text (enlarged).
    static func styled(_ text: String, font: NSFont, color: NSColor, joinWords: Bool = false,
                       paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        let plain = joinWords ? joinHangulWords(text) : text
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraph = paragraph { attributes[.paragraphStyle] = paragraph }
        let result = NSMutableAttributedString(string: plain, attributes: attributes)
        replaceControlGlyph(in: result, base: font, color: color)
        return result
    }

    private static var controlAttachments: [String: NSTextAttachment] = [:]

    /// One attachment per size/color, so identical text compares equal and live labels do not repaint needlessly.
    private static func controlAttachment(base: NSFont, color: NSColor) -> NSTextAttachment? {
        var rgba: [CGFloat] = [0, 0, 0, 1]
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = color.usingColorSpace(.sRGB) { rgba = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent] }
        }
        let key = "\(base.pointSize)|" + rgba.map { String(format: "%.3f", $0) }.joined(separator: ",")
        if let cached = controlAttachments[key] { return cached }
        guard let symbol = NSImage(systemSymbolName: "control", accessibilityDescription: nil) else { return nil }
        let tint = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        let config = NSImage.SymbolConfiguration(pointSize: base.pointSize * 1.05, weight: .heavy)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        guard let image = symbol.withSymbolConfiguration(config) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (base.capHeight - image.size.height) / 2 + 0.5,
                                   width: image.size.width, height: image.size.height)
        controlAttachments[key] = attachment
        return attachment
    }

    static func replaceControlGlyph(in text: NSMutableAttributedString, base: NSFont, color: NSColor) {
        var search = NSRange(location: 0, length: text.length)
        while true {
            let r = (text.string as NSString).range(of: "\u{2303}", options: [], range: search)
            if r.location == NSNotFound { break }
            if let attachment = controlAttachment(base: base, color: color) {
                text.replaceCharacters(in: r, with: NSAttributedString(attachment: attachment))
                search = NSRange(location: r.location + 1, length: text.length - r.location - 1)
            } else {
                text.addAttributes([.font: NSFont.systemFont(ofSize: base.pointSize * 1.4, weight: .semibold)], range: r)
                let next = r.location + r.length
                search = NSRange(location: next, length: text.length - next)
            }
        }
    }

    static func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular,
                       description: String? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: description) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return base.withSymbolConfiguration(config) ?? base
    }

    static func symbolView(_ name: String, size: CGFloat = 14, tint: NSColor = .labelColor) -> NSImageView {
        let v = NSImageView(image: symbol(name, size: size) ?? NSImage())
        v.contentTintColor = tint
        v.imageScaling = .scaleProportionallyDown
        v.setAccessibilityElement(false)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: size + 6).isActive = true
        v.heightAnchor.constraint(equalToConstant: size + 6).isActive = true
        return v
    }

    /// "⚠" line with a real SF Symbol in front (orange = needs setup, red = error); the words carry the meaning.
    static func notice(_ text: String, tint: NSColor, style: NSFont.TextStyle = .subheadline) -> NSAttributedString {
        let font = UI.font(style)
        let result = NSMutableAttributedString()
        if let base = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            let image = base.withSymbolConfiguration(config) ?? base
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: " ", attributes: [.font: font]))
        } else {
            result.append(NSAttributedString(string: "⚠︎ ", attributes: [.font: font]))
        }
        // U+2028 keeps the second sentence in the same paragraph, so it hangs under the words like wrapped lines do.
        result.append(styled(joinHangulWords(text).replacingOccurrences(of: "\n", with: "\u{2028}"), font: font,
                             color: .labelColor))
        // Wrapped lines hang under the words, not under the symbol.
        let style = NSMutableParagraphStyle()
        let symbolWidth = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular))?.size.width ?? 12
        style.headIndent = symbolWidth + (" " as NSString).size(withAttributes: [.font: font]).width
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY)
        -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = alignment
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading)
        -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = alignment
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }

    static func separator(width: CGFloat) -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }

    /// Borderless text button, optionally with a leading/trailing SF Symbol. The label is the visible title.
    static func linkButton(_ title: String, color: NSColor = UI.linkText, symbol: String? = nil,
                           symbolTrailing: Bool = false, target: AnyObject?, action: Selector?) -> NSButton {
        let b = LinkButton(title: title, target: target, action: action)
        b.isBordered = false
        b.contentTintColor = color
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color, .font: font(.callout)])
        if let symbol = symbol, let image = UI.symbol(symbol, size: NSFont.preferredFont(forTextStyle: .callout).pointSize,
                                                      weight: .semibold) {
            b.image = image
            b.imagePosition = symbolTrailing ? .imageRight : .imageLeft
            b.imageHugsTitle = true
        }
        b.setAccessibilityLabel(title)
        return b
    }

    static func modifiersToCarbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= ToolShortcut.command }
        if flags.contains(.shift) { m |= ToolShortcut.shift }
        if flags.contains(.option) { m |= ToolShortcut.option }
        if flags.contains(.control) { m |= ToolShortcut.control }
        return m
    }

    /// Debug readout (`ctl a11y`): what an assistive technology would find in a view tree - role, label, value, help,
    /// identifier and key equivalent of every accessibility element. Reads the real AppKit accessibility attributes.
    static func accessibilityTree(of root: NSView) -> [[String: String]] {
        var out: [[String: String]] = []
        func read(_ view: NSView, _ attribute: NSAccessibility.Attribute) -> String? {
            guard let value = view.accessibilityAttributeValue(attribute) else { return nil }
            let text = "\(value)"
            return text.isEmpty ? nil : text
        }
        func walk(_ view: NSView) {
            if view.isHidden { return }
            // Standard controls expose their title / value through their cell, so they are listed even when the view
            // itself does not claim to be an element.
            if view.isAccessibilityElement() || view is NSControl {
                // The legacy attribute reads include what controls derive from their cell (title, value).
                var entry: [String: String] = ["class": String(describing: type(of: view))]
                func nonEmpty(_ text: String?) -> String? { (text?.isEmpty ?? true) ? nil : text }
                func any(_ value: Any?) -> String? { value.flatMap { nonEmpty("\($0)") } }
                if let v = any(view.accessibilityRole()?.rawValue) ?? read(view, .role) { entry["role"] = v }
                if let v = nonEmpty(view.accessibilityTitle()) ?? read(view, .title) ?? nonEmpty((view as? NSButton)?.title) {
                    entry["title"] = v
                }
                if let v = nonEmpty(view.accessibilityLabel()) ?? read(view, .description) { entry["label"] = v }
                if let v = any(view.accessibilityValue()) ?? read(view, .value) ?? nonEmpty((view as? NSTextField)?.stringValue) {
                    entry["value"] = v
                }
                if let slider = view as? NSSlider, let v = nonEmpty(slider.accessibilityValueDescription()) {
                    entry["valueDescription"] = v
                }
                if let v = nonEmpty(view.accessibilityHelp()) ?? read(view, .help) { entry["help"] = v }
                let identifier = view.accessibilityIdentifier()
                if !identifier.isEmpty { entry["id"] = identifier }
                if let button = view as? NSButton, !button.keyEquivalent.isEmpty {
                    entry["key"] = (button.keyEquivalentModifierMask.contains(.command) ? "⌘" : "") + button.keyEquivalent
                }
                if let control = view as? NSControl { entry["enabled"] = control.isEnabled ? "1" : "0" }
                if entry["title"] != nil || entry["label"] != nil || entry["value"] != nil { out.append(entry) }
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return out
    }
}

/// Fixed status colors (sRGB, independent of appearance and vibrancy): the same green / gray / yellow / red looks the
/// same in the popover and in the settings window, light or dark.
enum DotPalette {
    static let green = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)    // #34C759
    static let gray = NSColor(srgbRed: 0.557, green: 0.557, blue: 0.576, alpha: 1)     // #8E8E93
    static let yellow = NSColor(srgbRed: 1.000, green: 0.800, blue: 0.000, alpha: 1)   // #FFCC00
    static let red = NSColor(srgbRed: 1.000, green: 0.231, blue: 0.188, alpha: 1)      // #FF3B30
}

/// Status circle. Green = switched on, gray = off. A yellow (setup/permission) or red (error) circle of the same size
/// sits half behind the green one (offset = half a diameter, no gap cut out, so the back circle reads as a circle,
/// not a crescent). It is only a summary: the state is always repeated as text /
/// accessibility value elsewhere. The width is the same for every state, so names and icons line up in every row.
final class StatusDotView: NSView {
    var kind: StatusDotKind = .off { didSet { needsDisplay = true } }

    static let diameter: CGFloat = 12
    static let overlapOffset: CGFloat = 6
    /// The dot must show its own fixed color, never blend with what is behind it.
    override var allowsVibrancy: Bool { false }
    static var width: CGFloat { diameter + overlapOffset + 1 }
    override var intrinsicContentSize: NSSize { NSSize(width: StatusDotView.width, height: 14) }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let kind = self.kind
        let d = StatusDotView.diameter, offset = StatusDotView.overlapOffset
        // Drawn into an image (resolution independent) so the gap can be cut with .clear without touching the
        // window's own backing store.
        let image = NSImage(size: bounds.size, flipped: false) { rect in
            let y = (rect.height - d) / 2
            let front = NSRect(x: 0, y: y, width: d, height: d)
            switch kind {
            case .off:
                DotPalette.gray.setFill()
                NSBezierPath(ovalIn: front).fill()
            case .on:
                DotPalette.green.setFill()
                NSBezierPath(ovalIn: front).fill()
            case .onNeedsSetup, .onError:
                (kind == .onError ? DotPalette.red : DotPalette.yellow).setFill()
                NSBezierPath(ovalIn: front.offsetBy(dx: offset, dy: 0)).fill()
                DotPalette.green.setFill()
                NSBezierPath(ovalIn: front).fill()
            }
            return true
        }
        image.draw(in: bounds)
    }
}

/// One feature row: status circle, symbol, name, (pin), open-shortcut, arrow. Click or Space/Return opens the tool.
final class ToolRowView: NSControl {
    let module: ModuleID
    var onActivate: ((ModuleID) -> Void)?
    private let dot = StatusDotView()
    private let shortcutLabel = UI.label("", style: .subheadline, color: UI.secondaryText)
    private let pinView = UI.symbolView("pin.fill", size: 10, tint: UI.linkText)
    private var hover = false { didSet { updateBackground() } }
    private var pressed = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    init(module: ModuleID) {
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        // The popover focuses the first row when it opens; a ring around it for a mouse user is noise. It appears once
        // the keyboard is used (keyDown below).
        focusRingType = .none
        // A bare NSControl subclass is not an accessibility element by default: say it is, so VoiceOver finds the row.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        let symbol = UI.symbolView(module.symbolName, size: 14, tint: .labelColor)
        let name = UI.label(module.displayName, style: .body)
        let chevron = UI.symbolView("chevron.right", size: 10, tint: UI.tertiaryText)
        pinView.isHidden = true
        let row = UI.hstack([dot, symbol, name, UI.spacer(), pinView, shortcutLabel, chevron], spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(status: ToolStatusPresentation, pinned: Bool, shortcut: ToolShortcut?) {
        dot.kind = status.dot
        pinView.isHidden = !pinned
        shortcutLabel.textColor = shortcut == nil ? UI.tertiaryText : UI.secondaryText
        shortcutLabel.setLive(shortcut?.label ?? "미설정")
        let shortcutText = shortcut.map { "열기 단축키 \($0.label)" } ?? "열기 단축키 미설정"
        toolTip = "\(module.displayName) — \(status.stateText)" + (status.detail.map { "\n\($0)" } ?? "")
        setAccessibilityLabel(module.displayName)
        setAccessibilityValue("\(status.accessibilityText)\(pinned ? ", 메뉴 막대에 고정됨" : ""), \(shortcutText)")
        setAccessibilityHelp("도구 조작 화면을 엽니다")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?(module) }
    }
    override func keyDown(with event: NSEvent) {
        if focusRingType != .exterior { focusRingType = .exterior; noteFocusRingMaskChanged() }
        switch event.keyCode {
        case 36, 49, 76: onActivate?(module)                 // Return, Space, Enter
        case 125: window?.selectNextKeyView(nil)             // Down
        case 126: window?.selectPreviousKeyView(nil)         // Up
        default: super.keyDown(with: event)
        }
    }
    /// VoiceOver "press" (VO-Space) opens the tool like a click does.
    override func accessibilityPerformPress() -> Bool { onActivate?(module); return true }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    /// The layer color is a resolved CGColor: re-resolve it when light/dark changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let base = NSColor.labelColor
        let color = pressed ? base.withAlphaComponent(0.16) : hover ? base.withAlphaComponent(0.08) : NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

/// Mini screen showing where the chosen window action will put the window.
final class SnapPreviewView: NSView {
    var action: SnapAction = .left {
        didSet { needsDisplay = true; setAccessibilityLabel("배치 미리보기: \(action.displayName)") }
    }

    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 128, height: 80) }

    override func draw(_ dirtyRect: NSRect) {
        let screen = bounds.insetBy(dx: 1, dy: 1)
        NSColor.quaternaryLabelColor.setFill()
        let outline = NSBezierPath(roundedRect: screen, xRadius: 4, yRadius: 4)
        outline.fill()
        let f = WindowLayout.previewFraction(for: action)
        let inner = screen.insetBy(dx: 3, dy: 3)
        let r = NSRect(x: inner.minX + f.minX * inner.width, y: inner.minY + f.minY * inner.height,
                       width: f.width * inner.width, height: f.height * inner.height).insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

extension NSView {
    func invalidateAncestors() {
        var view: NSView? = self
        while let current = view {
            current.needsDisplay = true
            view = current.superview
        }
        if let window = window {
            window.contentView?.superview?.setNeedsDisplay(window.contentView?.superview?.bounds ?? .zero)
            window.display()
        }
    }
}

extension NSTextField {
    /// Changing text can shrink the label's frame; the pixels it no longer covers belong to transparent ancestors (row,
    /// vibrancy popover frame) and were not repainted on Monterey, so old and new glyphs showed through each other
    /// (real-OS captures: CPU digits, "상단바 고정됨" -> "상단바에 고정되지 않음"). Invalidate the whole ancestor chain
    /// and flush the window so the stale pixels are repainted.
    func setLive(_ text: String) {
        if let live = self as? LiveLabel, text.contains("\u{2303}") || live.usesAttributedText {
            // Once a label shows the enlarged control glyph it stays attributed, so a plain string never inherits the
            // glyph's font.
            live.usesAttributedText = true
            let color = textColor ?? .labelColor
            let baseFont = live.baseFont
            live.restyle = { UI.styled(text, font: baseFont, color: color) }
            setLive(attributed: UI.styled(text, font: baseFont, color: color))
            return
        }
        guard stringValue != text else { return }
        stringValue = text
        invalidateAncestors()
    }

    func setLive(attributed text: NSAttributedString) {
        guard !attributedStringValue.isEqual(to: text) else { return }
        attributedStringValue = text
        setAccessibilityValue(text.string.replacingOccurrences(of: UI.wordJoiner, with: "")
                                         .replacingOccurrences(of: "\u{2028}", with: " ")
                                         .replacingOccurrences(of: "\u{FFFC}", with: "Control "))
        invalidateAncestors()
    }
}

/// A horizontal row with a drawn (not layer-backed) rounded surface: opaque fill (a tone step from the popover) and a
/// hairline. A layer-backed row hosting plain text fields kept old glyphs on screen on Monterey when the text changed,
/// so the surface is drawn in draw(_:) instead.
extension UI {
    /// Secondary / tertiary text and link color. The system values are translucent (secondary label 55 % white,
    /// tertiary 25 %) and, in a dark popover, were hard to read; in dark they are raised to opaque-ish fixed
    /// values, in light the system colors are used unchanged.
    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static let secondaryText = NSColor(name: nil) { ap in
        isDark(ap) ? NSColor(white: 1, alpha: 0.74) : NSColor.secondaryLabelColor
    }
    static let tertiaryText = NSColor(name: nil) { ap in
        isDark(ap) ? NSColor(white: 1, alpha: 0.64) : NSColor.tertiaryLabelColor
    }
    /// The accent color, lightened in dark so that it keeps its contrast on the dark popover surface.
    static let linkText = NSColor(name: nil) { ap in
        var result = NSColor.controlAccentColor
        ap.performAsCurrentDrawingAppearance {
            if isDark(ap), let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                result = c.blended(withFraction: 0.35, of: .white) ?? c
            } else if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                result = c
            }
        }
        return result
    }

    /// Surface of the pin row inside the popover: one tone step from the popover itself, in light and in dark.
    static let rowSurface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1)
            : NSColor.white
    }
}

final class OutlinedRow: NSStackView {
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        // Opaque fill: the labels inside draw an identical opaque background, so changed text always repaints cleanly.
        UI.rowSurface.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Grouped surface of the settings window: a tone step from the window background, no outline, no shadow.
final class CardView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Text drawn inside the popover's vibrancy view is composited with a blend mode, so new glyphs were laid over the old
/// ones instead of replacing them (seen on Monterey whenever a secondary-colour label got longer). Opting out of vibrancy
/// makes the label paint normally and erase what was there.
final class LiveLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
    var usesAttributedText = false
    /// Rebuilds the attributed text (the control key symbol is tinted with a resolved color, so it has to follow a
    /// light/dark switch).
    var restyle: (() -> NSAttributedString)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let restyle = restyle { attributedStringValue = restyle() }
    }
    private(set) var baseFont: NSFont = UI.font(.callout)
    override var font: NSFont? {
        get { super.font }
        set { super.font = newValue; if let f = newValue { baseFont = f } }
    }

    /// Erase what an earlier string left behind before drawing the current one (labels without their own opaque
    /// background would otherwise paint new glyphs over old ones).
    override func draw(_ dirtyRect: NSRect) {
        if !drawsBackground {
            NSGraphicsContext.saveGraphicsState()
            NSColor.clear.setFill()
            bounds.fill(using: .copy)
            NSGraphicsContext.restoreGraphicsState()
        }
        super.draw(dirtyRect)
    }
}


/// Borderless text button for links. Like the labels it opts out of the popover's vibrancy blending, which darkened
/// the accent blue by about half in the VM and made links hard to read in dark.
final class LinkButton: NSButton {
    override var allowsVibrancy: Bool { false }
}
