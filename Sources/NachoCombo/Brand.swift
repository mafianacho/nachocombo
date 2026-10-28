import AppKit
import CoreText

/// The Nacho Combo design system in AppKit: its color tokens resolved for light and dark appearance, and its type
/// roles. Brand surfaces (the gallery's lid, the Combos page, cards, chips, badges, status dots) use these; native
/// controls keep the system font so they follow the user's settings.
enum Brand {
    // MARK: color tokens

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    /// The ground: window and page background.
    static let paper = dynamic(0xFFFFFF, 0x15100B)
    /// Tinted surfaces on paper: cards, the sidebar, table heads.
    static let paper2 = dynamic(0xFFF7E1, 0x211810)
    /// Hairlines, card borders, dashed compartment rules.
    static let line = dynamic(0xEBDDBF, 0x3A2C1F)
    /// Primary text, strong borders.
    static let ink = dynamic(0x24180D, 0xF8EFDF)
    /// Secondary text and metadata.
    static let ink2 = dynamic(0x66553F, 0xC7B59C)
    /// The box yellow: brand fills only, never text on paper.
    static let nacho = rgb(0xFFC43D)
    /// "You have to do something" as a fill: attention badges, waiting dots.
    static let nachoDeep = dynamic(0xE48A0C, 0xF5A53A)
    /// "You have to do something" as text or an outline; also the focus ring.
    static let nachoInk = dynamic(0x9A5A00, 0xF5A53A)
    /// Text and icons on nacho and nachoDeep fills.
    static let onNacho = rgb(0x2A1A0B)
    /// Success and running.
    static let guac = dynamic(0x377F33, 0x7FCB72)
    /// Danger, errors and "not doing".
    static let salsa = dynamic(0xBE3B24, 0xF38069)
    /// The combo menu board, the same in both appearances.
    static let board = rgb(0x1E1610)
    static let board2 = rgb(0x2B2017)
    static let boardLine = rgb(0x45352A)
    static let boardInk = rgb(0xFFF1D2)
    static let boardMute = rgb(0xBFA889)
    static let boardPick = rgb(0x3A2A14)
    /// salsa and guac as they read on the board (their dark-theme values).
    static let boardSalsa = rgb(0xF38069)
    static let boardGuac = rgb(0x7FCB72)
    /// Status dot of a gadget that is off.
    static let statusOff = rgb(0x8E8E93)

    // MARK: type roles

    /// Registers the bundled fonts (Resources/Fonts) for this process. Missing files fall back to the system font.
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// Anton, always set in capitals: the name, combo names and numbers. One loud thing per view.
    static func sign(_ size: CGFloat) -> NSFont {
        NSFont(name: "Anton-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: .black)
    }

    /// IBM Plex Sans: labels and running text on the app's own surfaces.
    static func body(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "IBMPlexSans-Bold"
        case .semibold: name = "IBMPlexSans-SmBld"
        case .medium: name = "IBMPlexSans-Medm"
        default: name = "IBMPlexSans"
        }
        return NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// IBM Plex Mono in capitals with tracking: eyebrows, tags, role labels.
    static func mono(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        NSFont(name: weight == .medium ? "IBMPlexMono-Medium" : "IBMPlexMono-SemiBold", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// An eyebrow / tag label: mono capitals with a little tracking.
    static func eyebrow(_ text: String, size: CGFloat = 11, color: NSColor = Brand.ink2) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: mono(size), .foregroundColor: color, .kern: size * 0.09])
        label.setAccessibilityLabel(text)
        return label
    }

    /// A sign line in Anton capitals.
    static func signLabel(_ text: String, size: CGFloat, color: NSColor = Brand.ink) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: sign(size), .foregroundColor: color, .kern: size * 0.02])
        label.setAccessibilityLabel(text)
        return label
    }
}

/// A push button drawn in the brand: `primary` is a nacho fill with on-nacho text (the one main action of a view),
/// `attention` a nacho-deep fill (an action that resolves something waiting), `secondary` a paper button with a hairline.
final class BrandButton: NSButton {
    enum Style { case primary, attention, secondary, board }
    var style: Style { didSet { needsDisplay = true } }
    private var handler: (() -> Void)?
    private var pressed = false { didSet { needsDisplay = true } }
    private let small: Bool

    init(_ title: String, style: Style, small: Bool = false, handler: @escaping () -> Void) {
        self.style = style
        self.small = small
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(run)
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        setAccessibilityLabel(title)
        // Its label must never be cut: the text beside it gives way instead.
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler?() }

    private var font_: NSFont { Brand.body(small ? 12 : 13.5, weight: .semibold) }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font_]).width
        return NSSize(width: ceil(width) + (small ? 20 : 28), height: small ? 24 : 30)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        super.mouseDown(with: event)    // runs the tracking loop and the action
        pressed = false
    }

    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(title) } }
    override var isEnabled: Bool { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    override func draw(_ dirtyRect: NSRect) {
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        let fill: NSColor, stroke: NSColor, text: NSColor
        switch style {
        case .primary: fill = Brand.nacho; stroke = Brand.onNacho; text = Brand.onNacho
        case .attention: fill = Brand.nachoDeep; stroke = Brand.nachoDeep; text = Brand.onNacho
        case .secondary: fill = Brand.paper; stroke = Brand.line; text = Brand.ink
        case .board: fill = Brand.board2; stroke = Brand.boardLine; text = Brand.boardInk
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            (pressed ? fill.blended(withFraction: 0.15, of: .black) ?? fill : fill).setFill()
            shape.fill()
            stroke.setStroke()
            shape.lineWidth = style == .primary ? 1.5 : 1
            shape.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.font: font_, .foregroundColor: text]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                     withAttributes: attributes)
        }
    }

    override var isFlipped: Bool { true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
}
