import AppKit
import NachoComboCore

/// Keyboard shortcuts drawn as keys ("⌃⌥←" → [⌃] [⌥] [←]). Modifier and arrow glyphs use SF Symbols, which stay
/// legible where the system font draws ⌃ as a tiny caret.
enum KeyCaps {
    private static let symbols: [Character: String] = [
        "⌃": "control", "⌥": "option", "⇧": "shift", "⌘": "command", "←": "arrow.left", "→": "arrow.right",
        "↑": "arrow.up", "↓": "arrow.down", "↩": "return", "⌫": "delete.left",
    ]
    private static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    /// Modifiers one per key, the rest of the label as the last key.
    static func tokens(_ label: String) -> [String] {
        var result: [String] = []
        var rest = Substring(label)
        while let first = rest.first, modifiers.contains(first) {
            result.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { result.append(String(rest)) }
        return result
    }

    /// Keys spelled out on the cap rather than drawn as a symbol.
    static func text(_ token: String) -> String { token == "⎋" ? "esc" : token }

    static func capWidth(_ token: String, height: CGFloat) -> CGFloat {
        let token = text(token)
        if token.count == 1, symbols[token.first!] != nil { return height }
        let font = NSFont.systemFont(ofSize: height * 0.5, weight: .medium)
        return max(height, ceil((token as NSString).size(withAttributes: [.font: font]).width) + height * 0.6)
    }

    static func width(of label: String, height: CGFloat, spacing: CGFloat = 3) -> CGFloat {
        let caps = tokens(label)
        return caps.map { capWidth($0, height: height) }.reduce(0, +) + CGFloat(max(0, caps.count - 1)) * spacing
    }

    /// Draws the keys left to right from `origin` (in a flipped or unflipped context, `origin` is the top-left corner
    /// when `flipped`). Returns the total width.
    @discardableResult
    static func draw(_ label: String, at origin: NSPoint, height: CGFloat, dark: Bool, flipped: Bool,
                     spacing: CGFloat = 3) -> CGFloat {
        var x = origin.x
        let fill = dark ? NSColor(white: 1, alpha: 0.13) : NSColor.white
        let edge = dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.16)
        let ink = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.12, alpha: 1)
        for token in tokens(label) {
            let w = capWidth(token, height: height)
            let rect = NSRect(x: x, y: origin.y, width: w, height: height)
            // Key bottom (one point lower), then the key top: reads as a physical key.
            let base = rect.offsetBy(dx: 0, dy: flipped ? 1 : -1)
            (dark ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 0, alpha: 0.12)).setFill()
            NSBezierPath(roundedRect: base, xRadius: height * 0.2, yRadius: height * 0.2).fill()
            fill.setFill()
            let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: height * 0.2, yRadius: height * 0.2)
            cap.fill()
            edge.setStroke()
            cap.lineWidth = 1
            cap.stroke()
            if token.count == 1, let name = symbols[token.first!],
               let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: height * 0.46, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                let token = KeyCaps.text(token)
                let font = NSFont.systemFont(ofSize: height * 0.5, weight: .medium)
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: style]
                let textHeight = ceil(font.ascender - font.descender)
                (token as NSString).draw(in: NSRect(x: rect.minX, y: rect.midY - textHeight / 2, width: rect.width,
                                                    height: textHeight), withAttributes: attributes)
            }
            x += w + spacing
        }
        return x - origin.x - spacing
    }
}

/// A shortcut shown as keys, sized to fit.
final class KeyCapView: NSView {
    var label: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; updateAccessibility() } }
    private let capHeight: CGFloat

    init(_ label: String, height: CGFloat = 20) {
        self.label = label
        capHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: KeyCaps.width(of: label, height: capHeight), height: capHeight + 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        KeyCaps.draw(label, at: .zero, height: capHeight, dark: dark, flipped: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateAccessibility() {
        let names: [String: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "←": "Left Arrow",
                                       "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow", "↩": "Return", "⌫": "Delete", "⎋": "Escape"]
        setAccessibilityValue(KeyCaps.tokens(label).map { names[$0] ?? $0 }.joined(separator: " "))
    }
}
