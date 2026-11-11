import AppKit
import NachoComboCore

/// The pieces of the widget board (0.7.0): status circle, switch, button, the wall, a card and its body drawing.
/// Every color comes from `Brand.Bento`; light and dark follow the system appearance.
enum BentoDraw {
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }

    static func attrs(_ font: NSFont, _ color: NSColor, align: NSTextAlignment = .left, wrap: Bool = false) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        if #available(macOS 13.0, *), wrap { p.lineBreakStrategy = .hangulWordPriority }
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    /// One line, cut with "…" when too long. Returns the width used.
    @discardableResult
    static func text(_ s: String, at p: NSPoint, width: CGFloat, font: NSFont, color: NSColor, align: NSTextAlignment = .left) -> CGFloat {
        let a = attrs(font, color, align: align)
        let h = ceil(font.ascender - font.descender + font.leading) + 1
        (s as NSString).draw(with: NSRect(x: p.x, y: p.y, width: max(0, width), height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
        return min(width, ceil((s as NSString).size(withAttributes: a).width))
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) + 1 }

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }

    /// Wrapped text (Korean keeps words whole), at most `lines` lines, top-left at `p`. Returns the height used.
    @discardableResult
    static func wrapped(_ s: String, at p: NSPoint, width: CGFloat, lines: Int, font: NSFont, color: NSColor,
                        align: NSTextAlignment = .left) -> CGFloat {
        let a = attrs(font, color, align: align, wrap: true)
        let maxH = lineHeight(font) * CGFloat(lines)
        let str = UI.joinHangulWords(s)
        let need = (str as NSString).boundingRect(with: NSSize(width: width, height: maxH), options: [.usesLineFragmentOrigin], attributes: a).height
        let h = min(maxH, ceil(need))
        (str as NSString).draw(with: NSRect(x: p.x, y: p.y, width: width, height: h),
                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
        return h
    }

    static func wrappedHeight(_ s: String, width: CGFloat, lines: Int, font: NSFont) -> CGFloat {
        let a = attrs(font, .labelColor, wrap: true)
        let need = (UI.joinHangulWords(s) as NSString).boundingRect(with: NSSize(width: width, height: lineHeight(font) * CGFloat(lines)),
                                                                     options: [.usesLineFragmentOrigin], attributes: a).height
        return min(lineHeight(font) * CGFloat(lines), ceil(need))
    }

    /// An SF Symbol drawn in one color.
    static func symbol(_ name: String, in r: NSRect, color: NSColor, weight: NSFont.Weight = .regular) {
        guard let base = UI.symbol(name, size: min(r.width, r.height), weight: weight) else { return }
        let tinted = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let s = base.size
        let scale = min(r.width / max(1, s.width), r.height / max(1, s.height), 1)
        let w = s.width * scale, h = s.height * scale
        tinted.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: true, hints: nil)
    }

    static func rounded(_ r: NSRect, _ radius: CGFloat, fill: NSColor) {
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    static func dashed(_ r: NSRect, _ radius: CGFloat, color: NSColor, width: CGFloat = 1) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = width
        path.setLineDash([4, 3], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
    }

    /// A progress bar: track and a filled part (0…1).
    static func bar(_ r: NSRect, fraction: Double, color: NSColor) {
        rounded(r, r.height / 2, fill: Brand.Bento.track)
        let w = r.width * CGFloat(max(0, min(1, fraction)))
        if w > 0 { rounded(NSRect(x: r.minX, y: r.minY, width: max(r.height, w), height: r.height), r.height / 2, fill: color) }
    }

    /// A ring from 12 o'clock clockwise (flipped view coordinates).
    static func ring(center c: NSPoint, radius: CGFloat, width: CGFloat, fraction: Double?, color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        Brand.Bento.track.setStroke()
        track.stroke()
        guard let f = fraction, f > 0 else { return }
        let arc = NSBezierPath()
        // In a flipped view the angle runs clockwise on screen; -90° is 12 o'clock.
        arc.appendArc(withCenter: c, radius: radius, startAngle: -90, endAngle: -90 + 360 * CGFloat(min(1, f)), clockwise: false)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }
}

/// The three-state status circle of the board: gray off, green on, green with a yellow half behind it when the tool
/// is on but needs more setup; red for an error. The words go with it (tooltip and accessibility value).
final class BentoDotView: NSView {
    var dot: BentoDot = .off { didSet { needsDisplay = true; toolTip = dot.koreanText; setAccessibilityValue(dot.koreanText) } }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 8) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("상태")
        toolTip = dot.koreanText
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 8
        let x = bounds.width - d, y = (bounds.height - d) / 2
        switch dot {
        case .setup:
            Brand.Bento.dotSetup.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 4, y: y, width: d, height: d)).fill()
            Brand.Bento.dotOn.setFill()
        case .on: Brand.Bento.dotOn.setFill()
        case .off: Brand.Bento.dotOff.setFill()
        case .error: Brand.Bento.dotError.setFill()
        }
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
    }
}

/// The ON/OFF switch of a card's header (28 × 17). Pressable while the card is off; Space toggles it.
final class BentoSwitch: NSView {
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } }
    var onToggle: ((Bool) -> Void)?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 17) }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }

    init(name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 17))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("\(name) 켜기")
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0, y: (bounds.height - 17) / 2, width: 28, height: 17)
        BentoDraw.rounded(r, 8.5, fill: isOn ? Brand.Bento.switchOn : Brand.Bento.track)
        let knob = NSRect(x: isOn ? r.maxX - 15 : r.minX + 2, y: r.minY + 2, width: 13, height: 13)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8.5, yRadius: 8.5).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    override func mouseDown(with event: NSEvent) { flip() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { flip() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
    private func flip() {
        isOn.toggle()
        onToggle?(isOn)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The full-width button of a widget (ink on light, nacho yellow on dark).
final class BentoButton: NSView {
    var title: String { didSet { needsDisplay = true; setAccessibilityLabel(title) } }
    var handler: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        BentoDraw.rounded(bounds, 10, fill: Brand.Bento.button)
        let f = BentoDraw.font(12, .semibold)
        BentoDraw.text(title, at: NSPoint(x: 8, y: (bounds.height - BentoDraw.lineHeight(f)) / 2 + 1), width: bounds.width - 16,
                       font: f, color: Brand.Bento.buttonInk, align: .center)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { handler?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { handler?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { handler?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The wall behind the cards: warm gradient in light, violet ground with two glows in dark.
class BentoWallView: NSView {
    var cornerRadius: CGFloat = 0
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    static func isDark(_ view: NSView) -> Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        let clip = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if BentoWallView.isDark(self) {
            Brand.Bento.wallDark.setFill()
            bounds.fill()
            let a = NSGradient(colors: [Brand.Bento.wallGlowA, Brand.Bento.wallGlowA.withAlphaComponent(0)])
            a?.draw(fromCenter: NSPoint(x: bounds.width * 0.15, y: 0), radius: 0,
                    toCenter: NSPoint(x: bounds.width * 0.15, y: 0), radius: max(500, bounds.width * 0.6), options: [])
            let b = NSGradient(colors: [Brand.Bento.wallGlowB, Brand.Bento.wallGlowB.withAlphaComponent(0)])
            b?.draw(fromCenter: NSPoint(x: bounds.width, y: bounds.height), radius: 0,
                    toCenter: NSPoint(x: bounds.width, y: bounds.height), radius: max(500, bounds.width * 0.55), options: [])
        } else {
            let g = NSGradient(colors: Brand.Bento.wallLight, atLocations: [0, 0.45, 1], colorSpace: .sRGB)
            // 135°: top-left to bottom-right (flipped: positive y goes down, so the angle is -45° in drawing terms).
            g?.draw(in: bounds, angle: 45)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// What the card body draws (no controls: those are subviews of the card).
final class BentoBodyView: NSView {
    var module: ModuleID = .nachoPet
    var body: BentoBody = .basic(line: "") { didSet { needsDisplay = true } }
    var size: BentoSize = .small { didSet { needsDisplay = true } }
    var compact = false
    var petImage: NSImage?
    /// Room the card keeps free at the bottom for its button.
    var buttonRoom: CGFloat = 0
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private var ink: NSColor { Brand.Bento.ink }
    private var sub: NSColor { Brand.Bento.ink2 }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - buttonRoom)
        guard r.width > 20, r.height > 10 else { return }
        switch body {
        case .basic(let line): basic(line, r)
        case let .pet(line, _, signedIn): pet(line, signedIn: signedIn, r)
        case let .gauges(rings, side): gauges(rings, side, r)
        case let .checklist(rows, _): checklist(rows, r)
        case let .layouts(shapes, caption): layouts(shapes, caption, r)
        case let .timer(fraction, big, caption): timer(fraction, big, caption, r)
        case let .list(rows, empty): list(rows, empty, r)
        case let .stack(count, caption): stack(count, caption, r)
        case let .level(fraction, low, high, caption): level(fraction, low, high, caption, r)
        case let .sliders(sliders, rows): slidersBody(sliders, rows, r)
        case let .calendar(weekday, day, event, note): calendar(weekday, day, event, note, r)
        case let .usage(big, caption, segments): usage(big, caption, segments, r)
        case let .slots(rows, drop): slots(rows, drop, r)
        case let .strip(_, caption): strip(caption, r)
        }
    }

    // MARK: bodies

    private func basic(_ line: String, _ r: NSRect) {
        let f = BentoDraw.font(11)
        let lines = r.height > 70 ? 3 : 2
        let h = BentoDraw.wrappedHeight(line, width: r.width, lines: lines, font: f)
        if r.height - h > 34 { BentoDraw.symbol(module.symbolName, in: NSRect(x: r.minX, y: r.minY + 4, width: 24, height: 24), color: sub) }
        BentoDraw.wrapped(line, at: NSPoint(x: r.minX, y: r.maxY - h), width: r.width, lines: lines, font: f, color: sub)
    }

    private func pet(_ line: String, signedIn: Bool, _ r: NSRect) {
        if compact {
            // The mini board says the pet's state in words (b4) instead of showing the character.
            var hasAction = false
            if case let .pet(_, a, _) = body { hasAction = a != nil }
            let short = BentoBuilder.petShort(auth: signedIn ? .signedIn : .signedOut)
            if signedIn || hasAction {
                BentoDraw.text(short.big, at: NSPoint(x: r.minX, y: r.maxY - 38), width: r.width, font: BentoDraw.font(12, .semibold),
                               color: signedIn ? ink : Brand.Bento.warn)
                BentoDraw.text(short.caption, at: NSPoint(x: r.minX, y: r.maxY - 18), width: r.width, font: BentoDraw.font(11), color: sub)
            } else {
                BentoDraw.wrapped(line, at: NSPoint(x: r.minX, y: r.maxY - 30), width: r.width, lines: 2, font: BentoDraw.font(11), color: sub)
            }
            return
        }
        let f = BentoDraw.font(compact ? 12 : 13)
        let bubbleTextH = BentoDraw.wrappedHeight(line, width: r.width - 24, lines: 2, font: f)
        let bubbleH = bubbleTextH + 20 + (buttonRoom > 0 ? 0 : 0)
        // The bubble ends where the card's button begins; the button sits inside it.
        let bubble = NSRect(x: r.minX, y: bounds.height - bubbleH - buttonRoom - (buttonRoom > 0 ? 10 : 0), width: r.width,
                            height: bubbleH + buttonRoom + (buttonRoom > 0 ? 10 : 0))
        let showBubble = size != .small || r.height > 120
        if showBubble {
            BentoDraw.rounded(bubble, 14, fill: Brand.Bento.say)
            BentoDraw.wrapped(line, at: NSPoint(x: bubble.minX + 12, y: bubble.minY + 10), width: bubble.width - 24, lines: 2, font: f, color: ink)
        }
        let top = r.minY + 4
        let bottom = (showBubble ? bubble.minY : r.maxY) - 6
        if let img = petImage, bottom - top > 30 {
            let side = min(bottom - top, size == .large ? 190 : 120, r.width)
            let ir = NSRect(x: r.midX - side / 2, y: top + (bottom - top - side) / 2, width: side, height: side)
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if !showBubble {
            BentoDraw.wrapped(line, at: NSPoint(x: r.minX, y: r.maxY - 30), width: r.width, lines: 2, font: BentoDraw.font(11), color: sub)
        }
    }

    private func gauges(_ rings: [BentoRing], _ side: [BentoLine], _ r: NSRect) {
        if compact {
            // Mini board: CPU big, memory and disk as bars.
            let big = BentoDraw.font(24, .bold)
            let lf = BentoDraw.font(11)
            let cpu = rings.first
            let y0 = r.maxY - 46
            BentoDraw.text(cpu?.text ?? "—", at: NSPoint(x: r.minX, y: y0), width: 80, font: big, color: ink)
            BentoDraw.text(cpu?.label ?? "CPU", at: NSPoint(x: r.minX, y: y0 + 31), width: 80, font: lf, color: sub)
            let x = r.minX + 86
            for (i, ring) in rings.dropFirst().prefix(2).enumerated() {
                let y = y0 + 4 + CGFloat(i) * 20
                BentoDraw.text(ring.label, at: NSPoint(x: x, y: y), width: 44, font: lf, color: sub)
                BentoDraw.bar(NSRect(x: x + 46, y: y + 5, width: max(10, r.maxX - x - 46 - 40), height: 6), fraction: ring.fraction ?? 0,
                              color: color(ring.tone))
                BentoDraw.text(ring.text, at: NSPoint(x: r.maxX - 34, y: y), width: 34, font: lf, color: sub, align: .right)
            }
            return
        }
        let shown = size == .small ? Array(rings.prefix(2)) : rings
        let ringD: CGFloat = size == .small ? 50 : 58
        let labelH: CGFloat = 16
        let sideW: CGFloat = size == .small ? 0 : 92
        let y = r.maxY - ringD - labelH
        let slotW = (r.width - sideW) / CGFloat(max(1, shown.count))
        for (i, ring) in shown.enumerated() {
            let cx = r.minX + slotW * (CGFloat(i) + 0.5)
            let c = NSPoint(x: cx, y: y + ringD / 2)
            BentoDraw.ring(center: c, radius: ringD / 2 - 5, width: ringD * 4 / 36, fraction: ring.fraction, color: color(ring.tone))
            let tf = BentoDraw.font(ringD * 9 / 36 + 1, .bold)
            BentoDraw.text(ring.text, at: NSPoint(x: cx - 30, y: c.y - BentoDraw.lineHeight(tf) / 2), width: 60, font: tf, color: ink, align: .center)
            BentoDraw.text(ring.label, at: NSPoint(x: cx - 40, y: y + ringD + 1), width: 80, font: BentoDraw.font(11), color: sub, align: .center)
        }
        if sideW > 0 {
            let x = r.maxX - sideW + 6
            var yy = y + 6
            for (i, l) in side.enumerated() {
                if i == 0 {
                    BentoDraw.text(l.label, at: NSPoint(x: x, y: yy), width: sideW, font: BentoDraw.font(11), color: sub)
                    yy += 16
                } else {
                    BentoDraw.text("\(l.label) \(l.value)", at: NSPoint(x: x, y: yy), width: sideW, font: BentoDraw.font(13, .semibold), color: ink)
                    yy += 18
                }
            }
        }
    }

    private func checklist(_ rows: [BentoCheck], _ r: NSRect) {
        let f = BentoDraw.font(12)
        var y = r.minY + 6
        if compact || size == .small {
            let missing = rows.filter { $0.granted == false }.count
            let big = BentoDraw.font(20, .bold)
            let text = missing == 0 ? "준비됨" : "권한 \(missing)개 필요"
            BentoDraw.text(text, at: NSPoint(x: r.minX, y: r.maxY - 26), width: r.width, font: big, color: missing == 0 ? ink : Brand.Bento.warn)
            return
        }
        for row in rows {
            let mark: String, color: NSColor
            switch row.granted {
            case true?: mark = "✓"; color = Brand.Bento.dotOn
            case false?: mark = "!"; color = Brand.Bento.warn
            case nil: mark = "?"; color = sub
            }
            BentoDraw.text(mark, at: NSPoint(x: r.minX, y: y), width: 14, font: BentoDraw.font(12, .bold), color: color, align: .center)
            BentoDraw.text(row.name, at: NSPoint(x: r.minX + 22, y: y), width: r.width - 90, font: f, color: ink)
            let stateFont = row.granted == false ? BentoDraw.font(11, .semibold) : BentoDraw.font(11)
            BentoDraw.text(row.stateText, at: NSPoint(x: r.maxX - 70, y: y + 1), width: 70, font: stateFont,
                           color: row.granted == false ? Brand.Bento.warn : sub, align: .right)
            y += 23
        }
    }

    private func layouts(_ shapes: [BentoSnapShape], _ caption: String?, _ r: NSRect) {
        let capH: CGFloat = caption == nil ? 0 : 20
        let cellH: CGFloat = 26
        let gap: CGFloat = 6
        let cols = 2
        let rows = min(2, (shapes.count + 1) / 2)
        let gridH = CGFloat(rows) * cellH + CGFloat(rows - 1) * gap
        let top = r.maxY - capH - gridH
        let w = (r.width - gap) / 2
        for (i, s) in shapes.prefix(4).enumerated() {
            let cell = NSRect(x: r.minX + CGFloat(i % cols) * (w + gap), y: top + CGFloat(i / cols) * (cellH + gap), width: w, height: cellH)
            let p = NSBezierPath(roundedRect: cell.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            p.lineWidth = 1.5
            sub.setStroke()
            p.stroke()
            let inner = cell.insetBy(dx: 2, dy: 2)
            let fill = NSRect(x: inner.minX + inner.width * CGFloat(s.x), y: inner.minY + inner.height * CGFloat(s.y),
                              width: inner.width * CGFloat(s.w), height: inner.height * CGFloat(s.h))
            BentoDraw.rounded(fill, 3, fill: Brand.Bento.dotOn)
        }
        if let c = caption { BentoDraw.text(c, at: NSPoint(x: r.minX, y: r.maxY - 16), width: r.width, font: BentoDraw.font(11), color: sub) }
    }

    private func timer(_ fraction: Double?, _ big: String, _ caption: String, _ r: NSRect) {
        if compact {
            BentoDraw.text(big, at: NSPoint(x: r.minX, y: r.maxY - 42), width: r.width, font: BentoDraw.font(20, .bold), color: ink)
            BentoDraw.text(caption, at: NSPoint(x: r.minX, y: r.maxY - 16), width: r.width, font: BentoDraw.font(11), color: sub)
            return
        }
        let d: CGFloat = 56
        let c = NSPoint(x: r.minX + d / 2, y: r.maxY - d / 2)
        BentoDraw.ring(center: c, radius: d * 15 / 36, width: d * 3 / 36, fraction: fraction, color: Brand.Bento.coffee)
        BentoDraw.symbol("cup.and.saucer.fill", in: NSRect(x: c.x - 9, y: c.y - 8, width: 18, height: 16), color: ink)
        let x = r.minX + d + 10
        let bf = BentoDraw.font(20, .bold)
        BentoDraw.text(big, at: NSPoint(x: x, y: c.y - 22), width: r.maxX - x, font: bf, color: ink)
        BentoDraw.wrapped(caption, at: NSPoint(x: x, y: c.y + 4), width: r.maxX - x, lines: 2, font: BentoDraw.font(11), color: sub)
    }

    private func kindSymbol(_ k: BentoRow.Kind) -> String {
        switch k {
        case .text: return "textformat"
        case .link: return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private func list(_ rows: [BentoRow], _ empty: String, _ r: NSRect) {
        let f = BentoDraw.font(12)
        let rowH: CGFloat = compact ? 20 : 26
        if rows.isEmpty {
            BentoDraw.text(empty, at: NSPoint(x: r.minX, y: r.maxY - 18), width: r.width, font: BentoDraw.font(11), color: sub)
            return
        }
        let fit = max(1, Int(r.height / rowH))
        let want: Int
        if compact { want = 2 } else {
            switch size { case .small: want = 1; case .wide: want = 3; case .large: want = 8 }
        }
        let shown = Array(rows.prefix(min(fit, want)))
        var y = r.maxY - CGFloat(shown.count) * rowH
        for row in shown {
            if !compact {
                Brand.Bento.line.setFill()
                NSRect(x: r.minX, y: y, width: r.width, height: 1).fill()
            }
            let ty = y + (rowH - BentoDraw.lineHeight(f)) / 2 + 1
            BentoDraw.symbol(kindSymbol(row.kind), in: NSRect(x: r.minX, y: ty + 1, width: 15, height: 13), color: ink)
            let detailW: CGFloat = row.detail == nil || compact ? 0 : BentoDraw.textWidth(row.detail ?? "", BentoDraw.font(11)) + 8
            BentoDraw.text(row.text, at: NSPoint(x: r.minX + 22, y: ty), width: r.width - 22 - detailW, font: f, color: ink)
            if let d = row.detail, !compact {
                BentoDraw.text(d, at: NSPoint(x: r.maxX - detailW + 8, y: ty + 1), width: detailW - 8, font: BentoDraw.font(11), color: sub, align: .right)
            }
            y += rowH
        }
    }

    private func stack(_ count: Int, _ caption: String, _ r: NSRect) {
        let capH: CGFloat = 20
        let area = NSRect(x: r.minX, y: r.maxY - capH - 70, width: r.width, height: 66)
        let w = min(96, area.width - 34), h: CGFloat = 60
        if count == 0 {
            BentoDraw.dashed(NSRect(x: area.minX + 18, y: area.minY + 4, width: w, height: h), 8, color: sub)
        } else {
            let colors: [[NSColor]] = [[Brand.Bento.blue.withAlphaComponent(0.55), Brand.Bento.blue],
                                       [Brand.Bento.coffee, Brand.Bento.orange]]
            let n = min(count, 2)
            for i in 0..<n {
                let back = i == 0 && n == 2
                let rect = NSRect(x: area.minX + (back ? 18 : 30), y: area.minY + (back ? 4 : 8), width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                if back {
                    let t = NSAffineTransform()
                    t.translateX(by: rect.midX, yBy: rect.midY)
                    t.rotate(byDegrees: -7)
                    t.translateX(by: -rect.midX, yBy: -rect.midY)
                    t.concat()
                }
                let g = NSGradient(colors: colors[back ? 0 : 1])
                g?.draw(in: NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8), angle: -45)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        BentoDraw.text(caption, at: NSPoint(x: r.minX, y: r.maxY - 16), width: r.width, font: BentoDraw.font(11), color: sub)
    }

    private func level(_ fraction: Double, _ low: String, _ high: String, _ caption: String, _ r: NSRect) {
        let f = BentoDraw.font(11)
        let capH = BentoDraw.wrappedHeight(caption, width: r.width, lines: 2, font: f)
        let barY = r.maxY - capH - 6 - 14
        let iconY = barY - 6 - 30
        if iconY > r.minY {
            let c = NSRect(x: r.minX + 1, y: iconY, width: 28, height: 28)
            let ring = NSBezierPath(ovalIn: c)
            ring.lineWidth = 2
            ink.setStroke()
            ring.stroke()
            let half = NSBezierPath()
            half.move(to: NSPoint(x: c.midX, y: c.minY))
            half.appendArc(withCenter: NSPoint(x: c.midX, y: c.midY), radius: c.width / 2, startAngle: -90, endAngle: 90, clockwise: false)
            half.close()
            ink.setFill()
            half.fill()
        }
        let lw = BentoDraw.textWidth(low, f), hw = BentoDraw.textWidth(high, f)
        BentoDraw.text(low, at: NSPoint(x: r.minX, y: barY), width: lw, font: f, color: sub)
        BentoDraw.bar(NSRect(x: r.minX + lw + 8, y: barY + 4, width: r.width - lw - hw - 16, height: 6), fraction: fraction, color: sub)
        BentoDraw.text(high, at: NSPoint(x: r.maxX - hw, y: barY), width: hw, font: f, color: sub)
        BentoDraw.wrapped(caption, at: NSPoint(x: r.minX, y: r.maxY - capH), width: r.width, lines: 2, font: f, color: sub)
    }

    private func slidersBody(_ sliders: [BentoSlider], _ rows: [BentoLine], _ r: NSRect) {
        let f = BentoDraw.font(11)
        let rowH: CGFloat = 21
        let shownSliders = compact || size == .small ? Array(sliders.prefix(rows.isEmpty ? 2 : 1)) : sliders
        let total = CGFloat(shownSliders.count + rows.count) * rowH
        var y = r.maxY - total + 2
        for s in shownSliders {
            var x = r.minX
            if s.symbol.isEmpty {
                let w = BentoDraw.textWidth(s.label, f)
                BentoDraw.text(s.label, at: NSPoint(x: x, y: y), width: w, font: f, color: sub)
                x += w + 8
            } else {
                BentoDraw.symbol(s.symbol, in: NSRect(x: x, y: y, width: 15, height: 14), color: sub)
                x += 22
            }
            let vw = max(22, BentoDraw.textWidth(s.value, f))
            BentoDraw.bar(NSRect(x: x, y: y + 4, width: max(10, r.maxX - x - vw - 8), height: 6), fraction: s.fraction ?? 0,
                          color: s.symbol.isEmpty ? sub : ink)
            BentoDraw.text(s.value, at: NSPoint(x: r.maxX - vw, y: y), width: vw, font: f, color: sub, align: .right)
            y += rowH
        }
        for row in rows {
            if module == .deviceControl {
                var x = r.minX
                BentoDraw.symbol("headphones", in: NSRect(x: x, y: y, width: 15, height: 14), color: sub)
                x += 22
                let vw = BentoDraw.textWidth(row.value, f)
                BentoDraw.text(row.label, at: NSPoint(x: x, y: y - 1), width: r.maxX - x - vw - 8, font: BentoDraw.font(12, .semibold), color: ink)
                BentoDraw.text(row.value, at: NSPoint(x: r.maxX - vw, y: y), width: vw, font: f, color: sub)
            } else {
                let vw = BentoDraw.textWidth(row.value, f)
                BentoDraw.text(row.label, at: NSPoint(x: r.minX, y: y), width: r.width - vw - 8, font: f, color: sub)
                BentoDraw.text(row.value, at: NSPoint(x: r.maxX - vw, y: y), width: vw, font: f, color: sub)
            }
            y += rowH
        }
    }

    private func calendar(_ weekday: String, _ day: String, _ event: BentoLine?, _ note: String?, _ r: NSRect) {
        let f = BentoDraw.font(11)
        let lower = event.map { "\($0.label) \($0.value)" } ?? note
        let lowerH: CGFloat = lower == nil ? 0 : BentoDraw.wrappedHeight(lower ?? "", width: r.width - 9, lines: 2, font: f) + 6
        let dayF = BentoDraw.font(compact ? 26 : 34, .bold)
        let dayH = dayF.pointSize + 2
        let top = r.maxY - lowerH - dayH - 16
        BentoDraw.text(weekday, at: NSPoint(x: r.minX, y: top), width: r.width, font: f, color: sub)
        BentoDraw.text(day, at: NSPoint(x: r.minX, y: top + 14), width: r.width, font: dayF, color: Brand.Bento.red)
        if let e = event {
            Brand.Bento.blue.setFill()
            NSRect(x: r.minX, y: r.maxY - lowerH + 6, width: 3, height: lowerH - 6).fill()
            BentoDraw.wrapped("\(e.label) \(e.value)", at: NSPoint(x: r.minX + 9, y: r.maxY - lowerH + 6), width: r.width - 9, lines: 2, font: f, color: ink)
        } else if let n = note {
            BentoDraw.wrapped(n, at: NSPoint(x: r.minX, y: r.maxY - lowerH + 6), width: r.width, lines: 2, font: f, color: sub)
        }
    }

    private func usage(_ big: String, _ caption: String, _ segments: [BentoSegment], _ r: NSRect) {
        let bf = BentoDraw.font(22, .bold)
        let barY = r.maxY - 8
        let capY = barY - 8 - 15
        let bigY = capY - bf.pointSize - 4
        BentoDraw.text(big, at: NSPoint(x: r.minX, y: bigY), width: r.width, font: bf, color: ink)
        BentoDraw.text(caption, at: NSPoint(x: r.minX, y: capY), width: r.width, font: BentoDraw.font(11), color: sub)
        let bar = NSRect(x: r.minX, y: barY, width: r.width, height: 8)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).addClip()
        NSColor(white: 0.5, alpha: 0.25).setFill()
        bar.fill()
        let tones = [Brand.Bento.blue, Brand.Bento.orange, Brand.Bento.purple, NSColor(white: 0.55, alpha: 0.6)]
        var x = bar.minX
        for (i, s) in segments.enumerated() {
            let w = bar.width * CGFloat(max(0, min(1, s.fraction)))
            (s.label == "기타" ? tones[3] : tones[min(i, 2)]).setFill()
            NSRect(x: x, y: bar.minY, width: w, height: bar.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func slots(_ rows: [BentoRow], _ drop: String, _ r: NSRect) {
        let gap: CGFloat = 8
        let h = min(64, r.height - 4)
        let y = r.maxY - h
        let maxChips = size == .small || compact ? 1 : (size == .large ? 5 : 3)
        let chips = Array(rows.prefix(maxChips))
        let n = CGFloat(chips.count + 1)
        let w = (r.width - gap * (n - 1)) / n
        let f = BentoDraw.font(11)
        for (i, row) in chips.enumerated() {
            let cell = NSRect(x: r.minX + CGFloat(i) * (w + gap), y: y, width: w, height: h)
            BentoDraw.dashed(cell, 10, color: sub)
            BentoDraw.symbol(kindSymbol(row.kind), in: NSRect(x: cell.midX - 10, y: cell.minY + 9, width: 20, height: 20), color: ink)
            BentoDraw.text(row.text, at: NSPoint(x: cell.minX + 6, y: cell.maxY - 22), width: cell.width - 12, font: f, color: ink, align: .center)
        }
        let cell = NSRect(x: r.minX + CGFloat(chips.count) * (w + gap), y: y, width: w, height: h)
        BentoDraw.dashed(cell, 10, color: sub)
        let th = BentoDraw.wrappedHeight(drop, width: cell.width - 12, lines: 2, font: f)
        BentoDraw.wrapped(drop, at: NSPoint(x: cell.minX + 6, y: cell.midY - th / 2), width: cell.width - 12, lines: 2, font: f, color: sub, align: .center)
    }

    private func strip(_ caption: String, _ r: NSRect) {
        let barH: CGFloat = 26
        let capH = BentoDraw.wrappedHeight(caption, width: r.width, lines: 2, font: BentoDraw.font(11))
        let bar = NSRect(x: r.minX, y: r.maxY - capH - 6 - barH, width: r.width, height: barH)
        BentoDraw.rounded(bar, 8, fill: Brand.Bento.track)
        // A picture of a menu bar's right end (not other apps' real icons: macOS gives no list of them).
        var x = bar.maxX - 8
        for name in ["wifi", "battery.75", "ellipsis"] {
            x -= 16
            BentoDraw.symbol(name, in: NSRect(x: x, y: bar.minY + 6, width: 15, height: 14), color: ink)
            x -= 6
        }
        BentoDraw.wrapped(caption, at: NSPoint(x: r.minX, y: r.maxY - capH), width: r.width, lines: 2, font: BentoDraw.font(11), color: sub)
    }

    private func color(_ tone: BentoRing.Tone) -> NSColor {
        switch tone {
        case .green: return Brand.Bento.dotOn
        case .blue: return Brand.Bento.blue
        case .orange: return Brand.Bento.orange
        }
    }
}
