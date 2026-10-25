import AppKit
import NachoComboCore

/// Orange count bubble on the corner of a gadget icon: how many things about that gadget need the user's attention
/// (a missing permission, an error, a monitor alert). The detail pane lists them in words.
final class BadgeView: NSView {
    var count = 0 { didSet { isHidden = count <= 0; needsDisplay = true } }
    static let size: CGFloat = 22
    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }
        let ring = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.windowBackgroundColor.setFill()                       // a cut-out ring separates it from the icon
        NSBezierPath(ovalIn: ring).fill()
        NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1).setFill()   // #FF9F0A
        NSBezierPath(ovalIn: ring.insetBy(dx: 2, dy: 2)).fill()
        let text = count > 9 ? "9+" : "\(count)"
        Draw.text(text, in: ring, font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
                  color: NSColor(white: 0.1, alpha: 1), align: .center)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One gadget in the gallery: icon (with attention badge), name, a one-line live status and its on / off switch.
/// Clicking the tile shows the gadget's details; the switch alone turns it on or off.
final class GadgetTileView: NSView {
    let module: ModuleID
    let toggle = NSSwitch()
    var onSelect: ((ModuleID) -> Void)?
    var onToggle: ((ModuleID, Bool) -> Void)?
    /// Arrow keys move the selection between tiles (dx, dy in grid cells).
    var onMove: ((ModuleID, Int, Int) -> Void)?

    static let size = NSSize(width: 164, height: 178)
    private static let iconSize: CGFloat = 64

    private let iconView = NSImageView()
    private let badge = BadgeView()
    private let nameLabel = UI.label("", style: .headline, weight: .semibold)
    private let subtitleLabel = UI.label("", style: .subheadline, color: UI.secondaryText)
    private var tracking: NSTrackingArea?
    private var hover = false { didSet { needsDisplay = true } }
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
            setAccessibilitySelected(selected)
        }
    }

    init(module: ModuleID) {
        self.module = module
        super.init(frame: NSRect(origin: .zero, size: GadgetTileView.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(module.displayName)
        setAccessibilityHelp("Shows what \(module.displayName) does, its shortcuts and the permissions it needs")
        setAccessibilityIdentifier("tile-\(module.rawValue)")
        // No ring for a mouse user; it appears once the keyboard is used (keyDown).
        focusRingType = .none

        let size = GadgetTileView.size
        let icon = GadgetTileView.iconSize
        iconView.image = GadgetIcon.image(for: module, size: icon)
        iconView.imageScaling = .scaleNone
        iconView.setAccessibilityElement(false)
        iconView.frame = NSRect(x: (size.width - icon) / 2, y: 14, width: icon, height: icon)
        badge.frame = NSRect(x: iconView.frame.maxX - BadgeView.size + 8, y: iconView.frame.minY - 8,
                             width: BadgeView.size, height: BadgeView.size)
        badge.count = 0
        badge.setAccessibilityElement(false)

        nameLabel.stringValue = module.displayName
        nameLabel.alignment = .center
        nameLabel.setAccessibilityElement(false)
        nameLabel.frame = NSRect(x: 6, y: 88, width: size.width - 12, height: 20)
        subtitleLabel.alignment = .center
        subtitleLabel.setAccessibilityElement(false)
        subtitleLabel.frame = NSRect(x: 6, y: 109, width: size.width - 12, height: 17)

        toggle.target = self
        toggle.action = #selector(switched)
        toggle.setAccessibilityLabel("Enable \(module.displayName)")
        toggle.setAccessibilityIdentifier("toggle-\(module.rawValue)")
        let switchSize = toggle.intrinsicContentSize
        toggle.frame = NSRect(x: (size.width - switchSize.width) / 2, y: 136, width: switchSize.width, height: switchSize.height)

        for view in [iconView, nameLabel, subtitleLabel, toggle, badge] as [NSView] { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { GadgetTileView.size }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(enabled: Bool, subtitle: String, badgeCount: Int, stateText: String) {
        toggle.state = enabled ? .on : .off
        subtitleLabel.setLive(subtitle)
        subtitleLabel.toolTip = subtitle
        badge.count = badgeCount
        let attention = badgeCount > 0 ? ", \(badgeCount) item\(badgeCount == 1 ? "" : "s") need attention" : ""
        setAccessibilityValue("\(stateText), \(subtitle)\(attention)")
        toolTip = "\(module.displayName) — \(stateText)" + (badgeCount > 0 ? " · \(badgeCount) need attention" : "")
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else if hover {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            shape.fill()
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onSelect?(module)
    }

    override func keyDown(with event: NSEvent) {
        if focusRingType != .exterior { focusRingType = .exterior; noteFocusRingMaskChanged() }
        switch event.keyCode {
        case 36, 76: onSelect?(module)                          // Return, Enter
        case 49:                                                // Space flips the switch, like on a focused switch
            toggle.state = toggle.state == .on ? .off : .on
            switched()
        case 123: onMove?(module, -1, 0)
        case 124: onMove?(module, 1, 0)
        case 125: onMove?(module, 0, 1)
        case 126: onMove?(module, 0, -1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool { onSelect?(module); return true }

    @objc private func switched() {
        onSelect?(module)
        onToggle?(module, toggle.state == .on)
    }
}

/// The gallery: every gadget as a tile, three per row.
final class GadgetGridView: NSView {
    static let columns = 3
    static let spacing: CGFloat = 8
    private(set) var tiles: [ModuleID: GadgetTileView] = [:]
    private let order = ModuleID.allCases

    var onSelect: ((ModuleID) -> Void)? { didSet { tiles.values.forEach { $0.onSelect = onSelect } } }
    var onToggle: ((ModuleID, Bool) -> Void)? { didSet { tiles.values.forEach { $0.onToggle = onToggle } } }

    static var gridSize: NSSize {
        let rows = (ModuleID.allCases.count + columns - 1) / columns
        let tile = GadgetTileView.size
        return NSSize(width: CGFloat(columns) * tile.width + CGFloat(columns - 1) * spacing,
                      height: CGFloat(rows) * tile.height + CGFloat(rows - 1) * spacing)
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: GadgetGridView.gridSize))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Gadgets")
        for (index, id) in order.enumerated() {
            let tile = GadgetTileView(module: id)
            let column = index % GadgetGridView.columns, row = index / GadgetGridView.columns
            tile.setFrameOrigin(NSPoint(x: CGFloat(column) * (GadgetTileView.size.width + GadgetGridView.spacing),
                                        y: CGFloat(row) * (GadgetTileView.size.height + GadgetGridView.spacing)))
            tile.onMove = { [weak self] id, dx, dy in self?.move(from: id, dx: dx, dy: dy) }
            addSubview(tile)
            tiles[id] = tile
        }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { GadgetGridView.gridSize }

    func select(_ id: ModuleID) {
        for (tileID, tile) in tiles { tile.selected = tileID == id }
    }

    private func move(from id: ModuleID, dx: Int, dy: Int) {
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + dx + dy * GadgetGridView.columns
        guard order.indices.contains(target), let tile = tiles[order[target]] else { return }
        window?.makeFirstResponder(tile)
        onSelect?(order[target])
    }
}
