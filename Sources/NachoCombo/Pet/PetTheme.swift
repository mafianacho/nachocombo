import AppKit
import NachoComboCore

/// design/tokens.json for AppKit: colours follow the light/dark palette, sizes and fonts are the generated constants.
/// Nothing in the pet's views uses a number or colour that is not here.
enum PetTheme {
    typealias Size = PetTokens.Size
    typealias Space = PetTokens.Space
    typealias Radius = PetTokens.Radius

    static func color(_ key: KeyPath<PetTokens.Palette, String>) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return rgb((dark ? PetTokens.dark : PetTokens.light)[keyPath: key])
        }
    }

    static func rgb(_ hex: String) -> NSColor {
        guard let c = PetColorHex.parse(hex) else { return .magenta }
        return NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static var text: NSColor { color(\.text) }
    static var secondary: NSColor { color(\.textSecondary) }
    static var tertiary: NSColor { color(\.textTertiary) }
    static var accent: NSColor { color(\.accent) }
    static var link: NSColor { color(\.link) }

    static func font(_ size: Double, _ weight: Double = PetTokens.Font.weightRegular) -> NSFont {
        NSFont.systemFont(ofSize: CGFloat(size), weight: weight >= PetTokens.Font.weightSemibold ? .semibold
                          : weight >= PetTokens.Font.weightMedium ? .medium : .regular)
    }
    static var body: NSFont { font(PetTokens.Font.body) }
    static var caption: NSFont { font(PetTokens.Font.caption) }
    static var title: NSFont { font(PetTokens.Font.title, PetTokens.Font.weightSemibold) }

    /// Korean wraps between words (CSS `word-break: keep-all`): Hangul word priority, line height from the tokens.
    static func paragraph(_ font: NSFont, align: NSTextAlignment = .natural) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakStrategy = [.hangulWordPriority, .pushOut]
        p.lineBreakMode = .byWordWrapping
        p.alignment = align
        let line = font.pointSize * CGFloat(PetTokens.Font.lineHeight)
        p.minimumLineHeight = line
        p.maximumLineHeight = line
        return p
    }

    static func symbol(_ name: String, size: Double, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(size), weight: weight))
    }

    static func ms(_ v: Double) -> TimeInterval { v / 1000 }
    static func pt(_ v: Double) -> CGFloat { CGFloat(v) }
}

/// A plain layer-backed view with a token background, corner radius and optional 1 pt edge.
class PetBox: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    var corners: (tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat)? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = corners.map { PetBox.path(bounds.insetBy(dx: 0.5, dy: 0.5), $0) }
            ?? NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if let f = fill { f.setFill(); path.fill() }
        if let s = stroke { s.setStroke(); path.lineWidth = 1; path.stroke() }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    /// Rounded rectangle with its own radius per corner (bubbles: the corner toward the speaker is small). Flipped coordinates.
    static func path(_ r: NSRect, _ c: (tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat)) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + c.tl, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - c.tr, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - c.tr, y: r.minY + c.tr), radius: c.tr, startAngle: 270, endAngle: 0)
        p.line(to: NSPoint(x: r.maxX, y: r.maxY - c.br))
        p.appendArc(withCenter: NSPoint(x: r.maxX - c.br, y: r.maxY - c.br), radius: c.br, startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: r.minX + c.bl, y: r.maxY))
        p.appendArc(withCenter: NSPoint(x: r.minX + c.bl, y: r.maxY - c.bl), radius: c.bl, startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: r.minX, y: r.minY + c.tl))
        p.appendArc(withCenter: NSPoint(x: r.minX + c.tl, y: r.minY + c.tl), radius: c.tl, startAngle: 180, endAngle: 270)
        p.close()
        return p
    }
}
