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

// MARK: bento board tokens (0.7.0 widget board: main window, edit mode, menu bar mini board)

extension Brand {
    private static func rgba(_ value: UInt32, _ alpha: CGFloat) -> NSColor { rgb(value).withAlphaComponent(alpha) }

    private static func dynamicA(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    /// Colors of the widget board. Light and dark follow the system appearance (never forced).
    enum Bento {
        /// The wall behind the cards: a warm gradient (light) or a deep violet ground with two glows (dark).
        static let wallLight: [NSColor] = [Brand.rgb(0xFFD27A), Brand.rgb(0xFF9A6B), Brand.rgb(0xC86BFF)]
        static let wallDark = Brand.rgb(0x100D1A)
        static let wallGlowA = Brand.rgb(0x3B2A7A)
        static let wallGlowB = Brand.rgb(0x7A2A55)
        /// The glass of a card that is off, and of one that is on (a little more solid).
        static let glass = Brand.dynamicA(Brand.rgba(0xFFFFFF, 0.62), Brand.rgba(0x282438, 0.55))
        static let glassOn = Brand.dynamicA(Brand.rgba(0xFFFFFF, 0.86), Brand.rgba(0x342E48, 0.80))
        static let glassEdge = Brand.rgba(0xFFFFFF, 0.18)
        static let ink = Brand.dynamic(0x1D1D1F, 0xF2F0F7)
        static let ink2 = Brand.dynamic(0x6B6B70, 0xA19CB3)
        static let line = Brand.dynamicA(Brand.rgba(0x000000, 0.08), Brand.rgba(0xFFFFFF, 0.08))
        static let track = Brand.dynamicA(Brand.rgba(0x000000, 0.10), Brand.rgba(0xFFFFFF, 0.12))
        /// Buttons: ink on light, the nacho yellow on dark.
        static let button = Brand.dynamic(0x1D1D1F, 0xFFB21E)
        static let buttonInk = Brand.dynamic(0xFFFFFF, 0x1D1D1F)
        /// Nacho's speech bubble on the pet widget.
        static let say = Brand.dynamicA(Brand.rgb(0xFFFFFF), Brand.rgba(0xFFFFFF, 0.08))
        /// Status circle: on green, off gray, the yellow half behind green when more setup is needed, error red.
        static let dotOn = Brand.rgb(0x30C159)
        static let dotOff = Brand.rgb(0xB8B8BF)
        static let dotSetup = Brand.rgb(0xFFBF1A)
        static let dotError = Brand.rgb(0xFF453A)
        static let switchOn = Brand.rgb(0x30C159)
        static let warn = Brand.rgb(0xD98A00)
        static let blue = Brand.rgb(0x0A84FF)
        static let orange = Brand.rgb(0xFF9F0A)
        static let purple = Brand.rgb(0xBF5AF2)
        static let red = Brand.rgb(0xE5484D)
        static let coffee = Brand.rgb(0xFFB21E)
        /// Edit mode: the dashed outline of every card, the selected card's outline, the edit panel.
        static let editOutline = Brand.rgba(0xFFFFFF, 0.9)
        static let selected = Brand.dynamic(0x1D1D1F, 0xFFB21E)
        static let drawer = Brand.dynamicA(Brand.rgba(0xFFFFFF, 0.88), Brand.rgba(0x241F33, 0.92))
        static let preview = Brand.dynamicA(Brand.rgb(0xFFFFFF), Brand.rgba(0xFFFFFF, 0.06))
        static let chip = Brand.dynamicA(Brand.rgba(0x000000, 0.06), Brand.rgba(0xFFFFFF, 0.10))
        /// The menu bar mini board's cards.
        static let mini = Brand.dynamicA(Brand.rgba(0xFFFFFF, 0.75), Brand.rgba(0xFFFFFF, 0.08))

        static let radius: CGFloat = 22
        static let miniRadius: CGFloat = 16
        static let gap: CGFloat = 12
        static let padding: CGFloat = 36
        static let rowHeight: CGFloat = 160
        static let minCell: CGFloat = 150
        static let drawerWidth: CGFloat = 300
        static let miniWidth: CGFloat = 380
        static let miniRow: CGFloat = 108
        /// Off widgets: the body only is faded; header and switch stay sharp.
        static let offAlpha: CGFloat = 0.45
    }
}
