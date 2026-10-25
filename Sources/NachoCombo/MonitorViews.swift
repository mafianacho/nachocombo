import AppKit
import NachoComboCore

/// Metrics and colours of the monitor panels. Colours are read at draw time so they follow
/// light / dark appearance.
enum MonitorStyle {
    static let panelWidth: CGFloat = 300
    static let outerInset: CGFloat = 8
    static let cardInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
    static let cardSpacing: CGFloat = 8
    static let cardRadius: CGFloat = 9
    static func contentWidth(_ width: CGFloat) -> CGFloat { width - 2 * outerInset - cardInsets.left - cardInsets.right }
    static var contentWidth: CGFloat { contentWidth(panelWidth) }

    /// Hover flyouts sit left of the panel; their main section has no card background.
    static let flyoutWidth: CGFloat = 390
    static let flyoutGap: CGFloat = 6
    static let flyoutInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    static var flyoutContentWidth: CGFloat { flyoutWidth - 2 * outerInset - flyoutInsets.left - flyoutInsets.right }

    static var blue: NSColor { .systemBlue }
    static var pink: NSColor { .systemPink }
    static var yellow: NSColor { .systemYellow }
    static var red: NSColor { .systemRed }
    static var gray: NSColor { .systemGray }
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.13) }
    static var cardFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var primary: NSColor { .labelColor }
    static var secondary: NSColor { .secondaryLabelColor }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }

    static func pressureColor(level: Int) -> NSColor {
        switch level {
        case 4...: return red
        case 2...: return yellow
        default: return blue
        }
    }
}

enum Draw {
    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// One line of text, vertically centred in `rect`, truncated with "…".
    static func text(_ text: String, in rect: NSRect, font: NSFont, color: NSColor, align: NSTextAlignment = .left) {
        guard !text.isEmpty, rect.width > 0 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = ceil(font.ascender - font.descender)
        let line = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    static func dot(_ color: NSColor, center: NSPoint, radius: CGFloat = 4) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }

    /// Ring starting at 12 o'clock and running clockwise (flipped coordinates).
    static func ring(center: NSPoint, radius: CGFloat, lineWidth: CGFloat,
                     segments: [(fraction: Double, color: NSColor)], roundCaps: Bool) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        MonitorStyle.track.setStroke()
        track.stroke()
        var start: CGFloat = -90
        var remaining: CGFloat = 360
        for segment in segments {
            let sweep = min(remaining, CGFloat(max(0, min(1, segment.fraction))) * 360)
            guard sweep > 0.5 else { continue }
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start + sweep, clockwise: false)
            path.lineWidth = lineWidth
            path.lineCapStyle = roundCaps ? .round : .butt
            segment.color.setStroke()
            path.stroke()
            start += sweep
            remaining -= sweep
        }
    }

    static func image(_ image: NSImage, in rect: NSRect, tint: NSColor? = nil) {
        let source: NSImage
        if let tint = tint {
            source = NSImage(size: image.size, flipped: false) { bounds in
                image.draw(in: bounds)
                tint.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
        } else {
            source = image
        }
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Base of every panel element: flipped, manual layout with a fixed preferred height.
class PanelElement: NSView {
    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat { 19 }
    /// Position subviews after the frame was set.
    func layoutContent() {}

    override init(frame: NSRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Panels never activate the app, so the first click must already work.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
    }
}

/// Vertical stack, optionally drawn as a rounded card.
class StackElement: PanelElement {
    private(set) var items: [PanelElement]
    let spacing: CGFloat
    let insets: NSEdgeInsets
    let card: Bool
    /// Blue outline while this card's flyout is open.
    var highlighted = false { didSet { needsDisplay = true } }

    init(_ items: [PanelElement], spacing: CGFloat = 5, insets: NSEdgeInsets = MonitorStyle.cardInsets, card: Bool = true) {
        self.items = items
        self.spacing = spacing
        self.insets = insets
        self.card = card
        super.init(frame: .zero)
        items.forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setItems(_ newItems: [PanelElement]) {
        items.forEach { $0.removeFromSuperview() }
        items = newItems
        items.forEach { addSubview($0) }
    }

    private var visibleItems: [PanelElement] { items.filter { !$0.isHidden } }

    override var preferredHeight: CGFloat {
        let visible = visibleItems
        guard !visible.isEmpty else { return 0 }
        return insets.top + insets.bottom + visible.map { $0.preferredHeight }.reduce(0, +)
            + spacing * CGFloat(visible.count - 1)
    }

    override func layoutContent() {
        var y = insets.top
        for item in visibleItems {
            let height = item.preferredHeight
            item.frame = NSRect(x: insets.left, y: y, width: bounds.width - insets.left - insets.right, height: height)
            item.layoutContent()
            y += height + spacing
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard card else { return }
        let radius = MonitorStyle.cardRadius
        MonitorStyle.cardFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard highlighted else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: radius - 0.75, yRadius: radius - 0.75)
        outline.lineWidth = 1.5
        MonitorStyle.blue.setStroke()
        outline.stroke()
    }
}

/// The whole panel (or flyout): cards stacked with outer insets, fixed width.
final class PanelRootView: StackElement {
    let width: CGFloat

    init(cards: [PanelElement], width: CGFloat = MonitorStyle.panelWidth) {
        let inset = MonitorStyle.outerInset
        self.width = width
        super.init(cards, spacing: MonitorStyle.cardSpacing,
                   insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset), card: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @discardableResult
    func relayout() -> NSSize {
        let size = NSSize(width: width, height: preferredHeight)
        setFrameSize(size)
        layoutContent()
        return size
    }
}

/// Pop-up that also works on the click that makes its (non-key) panel key.
final class FirstMousePopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Section title (accent colour) with optional detail text, right-aligned value or range menu.
/// With options, clicking the title opens a menu of alternatives (GPU: 프로세서 / 메모리 / 온도 / 클럭).
final class HeaderElement: PanelElement {
    var title: String { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }
    var trailing = "" { didSet { needsDisplay = true } }
    var accent = true
    private var popup: NSPopUpButton?
    private var onRange: ((ChartRange) -> Void)?
    private var options: [String] = []
    private var onOption: ((Int) -> Void)?
    private let titleFont = MonitorStyle.font(12, .semibold)

    init(_ title: String, range: ChartRange? = nil, onRange: ((ChartRange) -> Void)? = nil) {
        self.title = title
        super.init(frame: .zero)
        guard let range = range else { return }
        let popup = FirstMousePopUpButton(frame: .zero, pullsDown: false)
        popup.isBordered = false
        popup.controlSize = .small
        popup.font = MonitorStyle.font(11, .semibold)
        for option in ChartRange.allCases {
            popup.addItem(withTitle: option.label)
            popup.lastItem?.tag = option.rawValue
        }
        popup.selectItem(withTag: range.rawValue)
        popup.target = self
        popup.action = #selector(rangeChanged(_:))
        popup.toolTip = "그래프 기간"
        popup.sizeToFit()
        addSubview(popup)
        self.popup = popup
        self.onRange = onRange
        fitPopup()
    }

    /// Width of the selected title plus the arrows, so "1시간 ⌃⌄" stays together.
    private func fitPopup() {
        guard let popup = popup else { return }
        let width = Draw.width(popup.titleOfSelectedItem ?? "", popup.font ?? MonitorStyle.font(11, .semibold)) + 26
        popup.setFrameSize(NSSize(width: width, height: popup.frame.height))
        layoutContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { 18 }

    func select(_ range: ChartRange) {
        popup?.selectItem(withTag: range.rawValue)
        fitPopup()
    }

    /// Makes the title a menu of `options`; `onSelect` gets the chosen index.
    func setOptions(_ options: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        self.options = options
        onOption = onSelect
        if options.indices.contains(selected) { title = options[selected] }
    }

    override func layoutContent() {
        guard let popup = popup else { return }
        let size = popup.frame.size
        popup.frame = NSRect(x: bounds.maxX - size.width + 6, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
    }

    @objc private func rangeChanged(_ sender: NSPopUpButton) {
        fitPopup()
        needsDisplay = true
        if let range = ChartRange(rawValue: sender.selectedTag()) { onRange?(range) }
    }

    private var hasMenu: Bool { options.count > 1 }
    private var titleWidth: CGFloat { Draw.width(title, titleFont) + (hasMenu ? 14 : 0) }

    override func mouseDown(with event: NSEvent) {
        guard hasMenu, convert(event.locationInWindow, from: nil).x <= titleWidth + 4 else { return super.mouseDown(with: event) }
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option, action: #selector(optionChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = option == title ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: -4, y: bounds.height + 3), in: self)
    }

    @objc private func optionChosen(_ sender: NSMenuItem) {
        title = options[sender.tag]
        onOption?(sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        let textWidth = Draw.width(title, titleFont)
        Draw.text(title, in: NSRect(x: 0, y: 0, width: textWidth + 2, height: bounds.height), font: titleFont,
                  color: accent ? MonitorStyle.blue : MonitorStyle.primary)
        if hasMenu, let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil) {
            Draw.image(chevron, in: NSRect(x: textWidth + 4, y: bounds.midY - 5, width: 7, height: 10), tint: MonitorStyle.blue)
        }
        let right = popup.map { $0.frame.minX - 2 } ?? bounds.maxX
        let rest = NSRect(x: titleWidth + 6, y: 0, width: max(0, right - titleWidth - 6), height: bounds.height)
        if !detail.isEmpty { Draw.text(detail, in: rest, font: MonitorStyle.digits(11), color: MonitorStyle.secondary) }
        if !trailing.isEmpty {
            Draw.text(trailing, in: rest, font: MonitorStyle.digits(12, .semibold), color: MonitorStyle.primary, align: .right)
        }
    }
}

/// History bars. Buckets come from TimeSeries.buckets (one value per channel, nil = gap).
final class ChartElement: PanelElement {
    enum Style { case stacked, mirrored }
    static let barWidth: CGFloat = 2
    static let gap: CGFloat = 1

    let style: Style
    let height: CGFloat
    /// Bars that fit the width the chart is laid out at.
    let barCount: Int
    var colors: () -> [NSColor]
    var fixedMax: Double?
    var minimumScale: Double
    var buckets: [[Double]?] = [] { didSet { needsDisplay = true } }

    init(style: Style, height: CGFloat = 62, width: CGFloat = MonitorStyle.contentWidth, fixedMax: Double? = nil,
         minimumScale: Double = 1, colors: @escaping () -> [NSColor]) {
        self.style = style
        self.height = height
        self.barCount = Int((width + ChartElement.gap) / (ChartElement.barWidth + ChartElement.gap))
        self.fixedMax = fixedMax
        self.minimumScale = minimumScale
        self.colors = colors
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { height }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        MonitorStyle.track.setFill()
        let baseline = style == .mirrored ? floor(h / 2) : h - 1
        NSRect(x: 0, y: baseline, width: bounds.width, height: 1).fill()
        guard !buckets.isEmpty else { return }
        let palette = colors()
        let step = ChartElement.barWidth + ChartElement.gap
        let originX = bounds.width - CGFloat(buckets.count) * step + ChartElement.gap
        var scale: Double
        switch style {
        case .stacked: scale = fixedMax ?? max(minimumScale, buckets.compactMap { $0?.reduce(0, +) }.max() ?? 0) * 1.05
        case .mirrored: scale = max(minimumScale, buckets.compactMap { $0?.max() }.max() ?? 0) * 1.05
        }
        scale = max(scale, 1e-9)
        for (i, bucket) in buckets.enumerated() {
            guard let values = bucket else { continue }
            let x = originX + CGFloat(i) * step
            switch style {
            case .stacked:
                var top = baseline
                for (c, value) in values.enumerated() where c < palette.count && value > 0 {
                    let barHeight = max(1, CGFloat(value / scale) * (h - 1))
                    palette[c].setFill()
                    NSRect(x: x, y: top - barHeight, width: ChartElement.barWidth, height: barHeight).fill()
                    top -= barHeight
                }
            case .mirrored:
                let half = h / 2 - 1
                if values.count > 0, values[0] > 0, palette.count > 0 {
                    let barHeight = max(1, CGFloat(values[0] / scale) * half)
                    palette[0].setFill()
                    NSRect(x: x, y: baseline - barHeight, width: ChartElement.barWidth, height: barHeight).fill()
                }
                if values.count > 1, values[1] > 0, palette.count > 1 {
                    let barHeight = max(1, CGFloat(values[1] / scale) * half)
                    palette[1].setFill()
                    NSRect(x: x, y: baseline + 1, width: ChartElement.barWidth, height: barHeight).fill()
                }
            }
        }
    }
}

/// Two "● label value" items, one left-aligned and one right-aligned.
final class PairElement: PanelElement {
    struct Item {
        var color: NSColor?
        var label: String
        var value: String
    }
    var left: Item? { didSet { needsDisplay = true } }
    var right: Item? { didSet { needsDisplay = true } }

    override var preferredHeight: CGFloat { 18 }

    override func draw(_ dirtyRect: NSRect) {
        let labelFont = MonitorStyle.font(11)
        let valueFont = MonitorStyle.digits(12, .semibold)
        func render(_ item: Item, alignRight: Bool) {
            let dotWidth: CGFloat = item.color == nil ? 0 : 12
            let labelWidth = Draw.width(item.label, labelFont)
            let valueWidth = Draw.width(item.value, valueFont)
            var x = alignRight ? bounds.width - (dotWidth + labelWidth + 5 + valueWidth) : 0
            if let color = item.color {
                Draw.dot(color, center: NSPoint(x: x + 4, y: bounds.midY))
                x += dotWidth
            }
            Draw.text(item.label, in: NSRect(x: x, y: 0, width: labelWidth + 1, height: bounds.height),
                      font: labelFont, color: MonitorStyle.secondary)
            x += labelWidth + 5
            Draw.text(item.value, in: NSRect(x: x, y: 0, width: valueWidth + 1, height: bounds.height),
                      font: valueFont, color: MonitorStyle.primary)
        }
        if let left = left { render(left, alignRight: false) }
        if let right = right { render(right, alignRight: true) }
    }
}

/// Two large numbers with a coloured caption (network / disk throughput).
final class BigValuesElement: PanelElement {
    struct Item {
        var value: String
        var label: String
        var color: () -> NSColor
    }
    var left: Item { didSet { needsDisplay = true } }
    var right: Item { didSet { needsDisplay = true } }

    init(left: Item, right: Item) {
        self.left = left
        self.right = right
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { 40 }

    override func draw(_ dirtyRect: NSRect) {
        let half = bounds.width / 2
        for (index, item) in [left, right].enumerated() {
            let x = CGFloat(index) * half
            Draw.text(item.value, in: NSRect(x: x, y: 0, width: half, height: 24), font: MonitorStyle.digits(19, .semibold),
                      color: MonitorStyle.primary, align: .center)
            let labelFont = MonitorStyle.font(11)
            let labelWidth = Draw.width(item.label, labelFont)
            let start = x + (half - labelWidth - 12) / 2
            Draw.dot(item.color(), center: NSPoint(x: start + 4, y: 32))
            Draw.text(item.label, in: NSRect(x: start + 12, y: 24, width: labelWidth + 1, height: 16), font: labelFont,
                      color: MonitorStyle.secondary)
        }
    }
}

/// "● label ............ value ◔" row.
final class RowElement: PanelElement {
    var label: String { didSet { needsDisplay = true } }
    var value = "" { didSet { needsDisplay = true } }
    var dotColor: (() -> NSColor)?
    var icon: NSImage? { didSet { needsDisplay = true } }
    var tintIcon = false
    var gauge: Double? { didSet { needsDisplay = true } }
    var dimmed = false { didSet { needsDisplay = true } }

    init(_ label: String, value: String = "", dot: (() -> NSColor)? = nil) {
        self.label = label
        self.value = value
        self.dotColor = dot
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        if let dot = dotColor {
            Draw.dot(dot(), center: NSPoint(x: 4, y: bounds.midY))
            x = 13
        }
        if let icon = icon {
            Draw.image(icon, in: NSRect(x: x, y: bounds.midY - 7, width: 14, height: 14),
                       tint: tintIcon ? (dimmed ? MonitorStyle.secondary : MonitorStyle.primary) : nil)
            x += 20
        }
        var right = bounds.width
        if let gauge = gauge {
            Draw.ring(center: NSPoint(x: right - 6, y: bounds.midY), radius: 5, lineWidth: 2,
                      segments: [(gauge, MonitorStyle.blue)], roundCaps: true)
            right -= 18
        }
        let valueFont = MonitorStyle.digits(12, .semibold)
        let valueWidth = Draw.width(value, valueFont)
        Draw.text(value, in: NSRect(x: right - valueWidth, y: 0, width: valueWidth + 1, height: bounds.height),
                  font: valueFont, color: dimmed ? MonitorStyle.secondary : MonitorStyle.primary)
        Draw.text(label, in: NSRect(x: x, y: 0, width: max(0, right - valueWidth - 8 - x), height: bounds.height),
                  font: MonitorStyle.font(12), color: dimmed ? MonitorStyle.secondary : MonitorStyle.primary)
    }
}

/// "프로세스" table with up to `maxRows` rows and right-aligned value columns.
final class ProcessListElement: PanelElement {
    struct Row {
        var icon: NSImage?
        var name: String
        var values: [String]
    }
    let columns: [String]
    let maxRows: Int
    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var placeholder = "" { didSet { needsDisplay = true } }
    var footnote = "" { didSet { needsDisplay = true } }
    private let columnWidth: CGFloat = 50
    private let rowHeight: CGFloat = 19

    init(columns: [String], maxRows: Int = 5, footnote: String = "") {
        self.columns = columns
        self.maxRows = maxRows
        self.footnote = footnote
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { 18 + CGFloat(maxRows) * rowHeight + (footnote.isEmpty ? 0 : 14) }

    private func columnRect(_ index: Int, count: Int, y: CGFloat, height: CGFloat) -> NSRect {
        NSRect(x: bounds.width - CGFloat(count - index) * columnWidth, y: y, width: columnWidth, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text("프로세스", in: NSRect(x: 0, y: 0, width: 100, height: 18), font: MonitorStyle.font(12, .semibold),
                  color: MonitorStyle.blue)
        for (i, title) in columns.enumerated() {
            Draw.text(title, in: columnRect(i, count: columns.count, y: 0, height: 18), font: MonitorStyle.font(11, .semibold),
                      color: MonitorStyle.secondary, align: .right)
        }
        if rows.isEmpty && !placeholder.isEmpty {
            Draw.text(placeholder, in: NSRect(x: 0, y: 18, width: bounds.width, height: rowHeight), font: MonitorStyle.font(11),
                      color: MonitorStyle.secondary)
        }
        for (index, row) in rows.prefix(maxRows).enumerated() {
            let y = 18 + CGFloat(index) * rowHeight
            if let icon = row.icon { Draw.image(icon, in: NSRect(x: 0, y: y + 2.5, width: 14, height: 14)) }
            let valueColumns = max(columns.count, row.values.count)
            let nameRight = bounds.width - CGFloat(valueColumns) * columnWidth - 4
            Draw.text(row.name, in: NSRect(x: 20, y: y, width: max(0, nameRight - 20), height: rowHeight),
                      font: MonitorStyle.font(12), color: MonitorStyle.primary)
            for (i, value) in row.values.enumerated() {
                Draw.text(value, in: columnRect(i, count: row.values.count, y: y, height: rowHeight),
                          font: MonitorStyle.digits(12, .semibold), color: MonitorStyle.primary, align: .right)
            }
        }
        if !footnote.isEmpty {
            Draw.text(footnote, in: NSRect(x: 0, y: bounds.height - 14, width: bounds.width, height: 14),
                      font: MonitorStyle.font(10), color: MonitorStyle.secondary)
        }
    }
}

/// Row of large gauges with text inside (value in the middle, caption above / below).
final class RingsElement: PanelElement {
    struct Ring {
        var segments: [(fraction: Double, color: NSColor)]
        var center: String
        var top: String?
        var bottom: String?
        var roundCaps = true
    }
    let diameter: CGFloat
    let lineWidth: CGFloat
    let centerFont: NSFont
    var rings: [Ring] = [] { didSet { needsDisplay = true } }

    init(diameter: CGFloat, lineWidth: CGFloat, centerSize: CGFloat) {
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.centerFont = MonitorStyle.digits(centerSize, .semibold)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { diameter + 4 }

    override func draw(_ dirtyRect: NSRect) {
        guard !rings.isEmpty else { return }
        let slot = bounds.width / CGFloat(rings.count)
        let small = MonitorStyle.font(max(8.5, diameter * 0.12), .semibold)
        for (i, ring) in rings.enumerated() {
            let center = NSPoint(x: slot * (CGFloat(i) + 0.5), y: diameter / 2 + 2)
            Draw.ring(center: center, radius: diameter / 2 - lineWidth / 2, lineWidth: lineWidth,
                      segments: ring.segments, roundCaps: ring.roundCaps)
            let textWidth = diameter - lineWidth * 2 - 4
            let lineOffset = diameter * 0.2
            let centerY = ring.top != nil && ring.bottom != nil ? center.y : (ring.bottom != nil ? center.y - diameter * 0.06 : center.y)
            Draw.text(ring.center, in: NSRect(x: center.x - textWidth / 2, y: centerY - 10, width: textWidth, height: 20),
                      font: centerFont, color: MonitorStyle.primary, align: .center)
            if let top = ring.top {
                Draw.text(top, in: NSRect(x: center.x - textWidth / 2, y: center.y - lineOffset - 6, width: textWidth, height: 12),
                          font: small, color: MonitorStyle.secondary, align: .center)
            }
            if let bottom = ring.bottom {
                Draw.text(bottom, in: NSRect(x: center.x - textWidth / 2, y: center.y + lineOffset - 6, width: textWidth, height: 12),
                          font: small, color: MonitorStyle.secondary, align: .center)
            }
        }
    }
}

/// Small per-core gauges: efficiency cores pink, performance cores blue.
final class CoreGridElement: PanelElement {
    var cores: [CoreLoad] = [] { didSet { needsDisplay = true } }
    private let gap: CGFloat = 7

    private var geometry: (perRow: Int, rows: Int, size: CGFloat) {
        let count = max(1, cores.count)
        let rows = Int(ceil(Double(count) / 8))
        let perRow = Int(ceil(Double(count) / Double(rows)))
        let size = min(26, (MonitorStyle.contentWidth - CGFloat(perRow - 1) * gap) / CGFloat(perRow))
        return (perRow, rows, size)
    }

    override var preferredHeight: CGFloat {
        let g = geometry
        return CGFloat(g.rows) * g.size + CGFloat(g.rows - 1) * gap
    }

    override func draw(_ dirtyRect: NSRect) {
        let g = geometry
        for row in 0..<g.rows {
            let slice = Array(cores.dropFirst(row * g.perRow).prefix(g.perRow))
            let rowWidth = CGFloat(slice.count) * g.size + CGFloat(max(0, slice.count - 1)) * gap
            var x = (bounds.width - rowWidth) / 2
            let y = CGFloat(row) * (g.size + gap)
            for core in slice {
                Draw.ring(center: NSPoint(x: x + g.size / 2, y: y + g.size / 2), radius: g.size / 2 - 2, lineWidth: 3.5,
                          segments: [(core.busy / 100, core.efficiency ? MonitorStyle.pink : MonitorStyle.blue)], roundCaps: true)
                x += g.size + gap
            }
        }
    }
}

final class ProgressElement: PanelElement {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override var preferredHeight: CGFloat { 8 }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: 1, width: bounds.width, height: 6)
        MonitorStyle.track.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()
        let filled = NSRect(x: 0, y: 1, width: bar.width * CGFloat(max(0, min(1, fraction))), height: 6)
        guard filled.width > 0.5 else { return }
        MonitorStyle.blue.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
    }
}

/// Startup volume: usage gauge, name and free space.
final class VolumeElement: PanelElement {
    var percent: Double = 0 { didSet { needsDisplay = true } }
    var name = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    override var preferredHeight: CGFloat { 38 }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: 18, y: bounds.midY)
        Draw.ring(center: center, radius: 16, lineWidth: 3.5, segments: [(percent / 100, MonitorStyle.blue)], roundCaps: true)
        Draw.text(String(format: "%.0f", percent), in: NSRect(x: 2, y: center.y - 8, width: 32, height: 16),
                  font: MonitorStyle.digits(11, .semibold), color: MonitorStyle.primary, align: .center)
        Draw.text(name, in: NSRect(x: 44, y: 1, width: bounds.width - 44, height: 18), font: MonitorStyle.font(13, .semibold),
                  color: MonitorStyle.primary)
        Draw.text(subtitle, in: NSRect(x: 44, y: 19, width: bounds.width - 44, height: 17), font: MonitorStyle.digits(11),
                  color: MonitorStyle.secondary)
    }
}

/// Large usage ring with its legend inside (startup volume flyout).
final class DonutElement: PanelElement {
    struct Part {
        var label: String
        var value: String
        var fraction: Double
        var color: () -> NSColor
        /// false: the remainder, shown by the ring's track.
        var arc = true
    }
    var parts: [Part] = [] { didSet { needsDisplay = true } }
    /// Drawn in the top-left corner.
    var icon: NSImage? { didSet { needsDisplay = true } }
    private let diameter: CGFloat = 170
    private let lineWidth: CGFloat = 13

    override var preferredHeight: CGFloat { diameter + 8 }

    override func draw(_ dirtyRect: NSRect) {
        if let icon = icon { Draw.image(icon, in: NSRect(x: 0, y: 0, width: 18, height: 18)) }
        let center = NSPoint(x: bounds.midX, y: 4 + diameter / 2)
        Draw.ring(center: center, radius: diameter / 2 - lineWidth / 2, lineWidth: lineWidth,
                  segments: parts.filter { $0.arc }.map { ($0.fraction, $0.color()) }, roundCaps: false)
        let line: CGFloat = 16
        let labelFont = MonitorStyle.font(11)
        let valueFont = MonitorStyle.digits(13, .semibold)
        var y = center.y - CGFloat(parts.count) * line
        for part in parts {
            let labelWidth = Draw.width(part.label, labelFont)
            let x = center.x - (labelWidth + 12) / 2
            Draw.dot(part.color(), center: NSPoint(x: x + 4, y: y + line / 2), radius: 3.5)
            Draw.text(part.label, in: NSRect(x: x + 12, y: y, width: labelWidth + 1, height: line), font: labelFont,
                      color: MonitorStyle.secondary)
            Draw.text(part.value, in: NSRect(x: center.x - 60, y: y + line, width: 120, height: line), font: valueFont,
                      color: MonitorStyle.primary, align: .center)
            y += 2 * line
        }
    }
}

final class NoteElement: PanelElement {
    var text: String { didSet { needsDisplay = true } }
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var preferredHeight: CGFloat { 15 }
    override func draw(_ dirtyRect: NSRect) {
        Draw.text(text, in: bounds, font: MonitorStyle.font(10.5), color: MonitorStyle.secondary)
    }
}

/// Text with an optional small button on the right (public IP lookup).
final class ActionRowElement: PanelElement {
    var text = "" { didSet { needsDisplay = true } }
    var bold = true { didSet { needsDisplay = true } }
    var buttonTitle: String? {
        didSet {
            button.isHidden = buttonTitle == nil
            button.title = buttonTitle ?? ""
            button.sizeToFit()
            layoutContent()
            needsDisplay = true
        }
    }
    var onPress: (() -> Void)?
    private let button = NSButton(title: "", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = MonitorStyle.font(11, .medium)
        button.target = self
        button.action = #selector(pressed)
        button.isHidden = true
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { 20 }

    override func layoutContent() {
        let size = button.frame.size
        button.frame = NSRect(x: bounds.width - size.width, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    @objc private func pressed() { onPress?() }

    override func draw(_ dirtyRect: NSRect) {
        let right = button.isHidden ? bounds.width : button.frame.minX - 6
        Draw.text(text, in: NSRect(x: 0, y: 0, width: max(0, right), height: bounds.height),
                  font: bold ? MonitorStyle.digits(12, .semibold) : MonitorStyle.font(11),
                  color: bold ? MonitorStyle.primary : MonitorStyle.secondary)
    }
}

/// Shortcut buttons at the bottom of every panel.
final class ButtonBarElement: PanelElement {
    struct Action {
        let image: NSImage
        let tooltip: String
        let handler: () -> Void
    }
    private let actions: [Action]
    private var buttons: [NSButton] = []

    init(actions: [Action]) {
        self.actions = actions
        super.init(frame: .zero)
        for (index, action) in actions.enumerated() {
            let button = NSButton(image: action.image, target: self, action: #selector(pressed(_:)))
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.tag = index
            button.toolTip = action.tooltip
            button.setAccessibilityLabel(action.tooltip)
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredHeight: CGFloat { 24 }

    override func layoutContent() {
        guard !buttons.isEmpty else { return }
        let slot = bounds.width / CGFloat(buttons.count)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: slot * (CGFloat(i) + 0.5) - 11, y: 1, width: 22, height: 22)
        }
    }

    @objc private func pressed(_ sender: NSButton) { actions[sender.tag].handler() }
}
