import AppKit
import NachoComboCore

/// The dark menu board the combos sit on (the same in light and dark appearance).
final class BoardView: NSView {
    let radius: CGFloat
    let fill: NSColor
    let stroke: NSColor
    let lineWidth: CGFloat

    init(radius: CGFloat = 22, fill: NSColor = Brand.board, stroke: NSColor = Brand.onNacho, lineWidth: CGFloat = 3) {
        self.radius = radius
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The board is dark in both appearances: native controls on it (pop-ups, the name field) draw dark too.
        appearance = NSAppearance(named: .darkAqua)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()
        stroke.setStroke()
        shape.lineWidth = lineWidth
        shape.stroke()
    }

    /// Puts `content` inside with `padding` on every side.
    func wrap(_ content: NSView, padding: CGFloat) -> BoardView {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
        return self
    }
}

/// A tile on the board: a numbered combo ("No.2 / DESK / Asks for 1"), or, dashed, the tile that makes a new one.
final class BoardTileButton: NSView {
    var onPress: (() -> Void)?
    var selected = false { didSet { needsDisplay = true; setAccessibilitySelected(selected) } }
    private let dashed: Bool
    private var hover = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(top: String, name: String, note: String, identifier: String, accessibility: String, dashed: Bool = false) {
        self.dashed = dashed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibility)
        setAccessibilityValue(note)
        setAccessibilityIdentifier(identifier)
        focusRingType = .exterior
        let number = Brand.signLabel(top, size: 19, color: Brand.nacho)
        let title = Brand.signLabel(name, size: 14, color: Brand.boardInk)
        title.lineBreakMode = .byTruncatingTail
        let small = NSTextField(labelWithString: note)
        small.font = Brand.body(10.5, weight: .medium)
        small.textColor = Brand.boardMute
        small.lineBreakMode = .byTruncatingTail
        let column = UI.vstack([number, title, small], spacing: 1)
        column.setCustomSpacing(3, after: title)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            title.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
            small.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        let base = dashed ? Brand.board : Brand.board2
        (selected ? Brand.boardPick : (hover ? base.blended(withFraction: 0.12, of: .white) ?? base : base)).setFill()
        shape.fill()
        (selected ? Brand.nacho : Brand.boardLine).setStroke()
        shape.lineWidth = 2
        if dashed && !selected { shape.setLineDash([5, 4], count: 2, phase: 0) }
        shape.stroke()
    }

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
        onPress?()
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76: onPress?()
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One gadget in the order's tray: lit when the combo includes it, the permission it asks for under it. While a combo
/// is being made, clicking a slot puts the gadget in or takes it out.
final class TraySlotView: NSView {
    private let lit: Bool
    private let module: ModuleID
    var onToggle: ((ModuleID) -> Void)? {
        didSet {
            setAccessibilityRole(onToggle == nil ? .staticText : .checkBox)
            if onToggle != nil { setAccessibilityValue(lit ? "1" : "0") }
            alphaValue = lit ? 1 : (onToggle == nil ? 0.38 : 0.6)
            window?.invalidateCursorRects(for: self)
        }
    }

    init(module: ModuleID, lit: Bool, lock: String?) {
        self.lit = lit
        self.module = module
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("slot-\(module.rawValue)")
        setAccessibilityLabel(module.displayName + (lit ? ", included" : ", not included") + (lock.map { ", asks for \($0)" } ?? ""))
        let icon = NSImageView(image: GadgetIcon.image(for: module, size: 26))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let name = NSTextField(labelWithString: module.displayName)
        name.font = Brand.body(11.5, weight: .semibold)
        name.textColor = Brand.boardInk
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        let lockLabel = NSTextField(labelWithString: lock ?? " ")
        lockLabel.font = Brand.mono(9.5)
        lockLabel.textColor = Brand.nacho
        lockLabel.alignment = .center
        let column = UI.vstack([icon, name, lockLabel], spacing: 4, alignment: .centerX)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            name.widthAnchor.constraint(lessThanOrEqualTo: column.widthAnchor),
        ])
        alphaValue = lit ? 1 : 0.38
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        shape.lineWidth = 2
        if lit {
            Brand.nacho.setStroke()
        } else {
            Brand.boardLine.setStroke()
            shape.setLineDash([5, 4], count: 2, phase: 0)
        }
        shape.stroke()
        if onToggle != nil {
            // A check in the corner while editing: what is in, what is out.
            let box = NSRect(x: bounds.maxX - 22, y: 8, width: 14, height: 14)
            let mark = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            (lit ? Brand.nacho : Brand.board).setFill()
            mark.fill()
            (lit ? Brand.nacho : Brand.boardMute).setStroke()
            mark.lineWidth = 1.5
            mark.stroke()
            if lit, let check = UI.symbol("checkmark", size: 9, weight: .bold) {
                let tinted = check.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Brand.onNacho])) ?? check
                let s = tinted.size
                tinted.draw(in: NSRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func mouseDown(with event: NSEvent) { onToggle?(module) }
    override func accessibilityPerformPress() -> Bool { onToggle?(module); return onToggle != nil }
    override func resetCursorRects() { if onToggle != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// A key or a gesture on the board ("⌃⌥←", "Shake while dragging").
final class BoardKeyView: NSView {
    private let text: String
    private let font = Brand.mono(11)

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16, height: 22)
    }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        Brand.board.setFill()
        shape.fill()
        Brand.boardLine.setStroke()
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Brand.boardInk]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                                withAttributes: attributes)
    }
}

/// Combos: pick one and see, before ordering, what gets easier (with your own shortcuts), what changes in your box and
/// what it asks for. Make your own from the box as it is or from a preset: tap the gadgets in the tray, choose the
/// settings it brings, name it. Ordering switches the gadgets and options in one go and can be undone; a gadget whose
/// permission is missing waits for its own Allow, so ordering never raises a system dialog.
final class ComboPage: NSView, NSTextFieldDelegate {
    private weak var host: SettingsHost?
    private(set) var selectedID: String
    /// The combo being made or edited (nil: the board shows the chosen combo's order).
    private(set) var draft: SavedCombo?
    private var draftIsNew = false
    private let content = UI.vstack([], spacing: 0)
    private var lastKey = ""
    var onOpen: ((SettingsPage) -> Void)?
    /// First launch: the page greets instead of explaining.
    var welcome = false { didSet { lastKey = ""; refresh() } }

    private static let width = GadgetDetailView.width
    private static let inner = GadgetDetailView.inner
    private static let boardPadding: CGFloat = 16
    private static var boardInner: CGFloat { inner - 2 * boardPadding }
    private static let orderPadding: CGFloat = 16
    private static var orderInner: CGFloat { boardInner - 2 * orderPadding }

    init(host: SettingsHost) {
        self.host = host
        let settings = host.gadgetManager.settings
        selectedID = ComboCatalog.current(settings)?.id ?? settings.combo ?? ComboCatalog.presets[0].id
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GadgetDetailView.margin),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            widthAnchor.constraint(equalToConstant: ComboPage.width),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var settings: AppSettings { host?.gadgetManager.settings ?? .defaults }

    var selected: Combo {
        ComboCatalog.combo(selectedID, in: settings) ?? ComboCatalog.presets[0]
    }

    func select(_ id: String) {
        guard ComboCatalog.combo(id, in: settings) != nil else { return }
        selectedID = id
        draft = nil
        rebuildNow()
    }

    /// Starts a combo of one's own: from what is on now, or from `combo` to change.
    func startNewCombo(copying combo: Combo? = nil) {
        guard settings.customCombos.count < ComboCatalog.maxCustom else { return }
        draft = ComboCatalog.draft(from: settings, copying: combo)
        draftIsNew = true
        rebuildNow()
    }

    func edit(_ id: String) {
        guard let saved = settings.customCombos.first(where: { $0.id == id }) else { return }
        selectedID = id
        draft = saved
        draftIsNew = false
        rebuildNow()
    }

    // MARK: what the board says

    private func keys(for moment: ComboMoment) -> String {
        let labels = moment.actions.compactMap { settings.shortcut(forAction: $0)?.label }
        if !labels.isEmpty { return labels.joined(separator: "  ") }
        return moment.actions.isEmpty ? moment.gesture : "No shortcut set"
    }

    private func permissionText(_ combo: Combo) -> String {
        guard let host = host else { return "" }
        let missing = combo.permissions.filter { host.gadgetPermissionGranted($0) != true }
        if combo.permissions.isEmpty { return "No permission" }
        if missing.isEmpty { return "Already allowed" }
        return "Asks for \(missing.count)"
    }

    /// The gadgets of an ordered combo that still wait for the user.
    private func pending(_ combo: Combo) -> [ModuleID] {
        guard let manager = host?.gadgetManager, manager.settings.combo == combo.id else { return [] }
        return combo.gadgets.filter { id in
            guard id.info.requiredPermission != nil else { return false }
            if !manager.settings.isEnabled(id) { return true }
            if case .needsPermission = manager.states[id] ?? .off { return true }
            return false
        }
    }

    /// While a combo is being made the page rebuilds only on the user's own changes (a live rebuild would take the
    /// name field away from under the typing).
    func refresh() {
        guard let host = host, draft == nil else { return }
        let manager = host.gadgetManager
        let combo = selected
        let plan = ComboPlan.make(combo, settings: settings)
        var key = "\(combo.id)|\(welcome)|\(plan.turnsOn)|\(plan.turnsOff)|\(plan.optionChanges)|"
        key += ComboCatalog.combos(settings).map { "\($0.id):\($0.name):\(permissionText($0))" }.joined(separator: ",") + "|"
        key += pending(combo).map { "\($0.rawValue):\(manager.settings.isEnabled($0))" }.joined(separator: ",") + "|"
        key += combo.moments.map { keys(for: $0) }.joined(separator: ",")
        key += "|\(ComboCatalog.current(settings)?.id ?? "-")|\(host.orderUndoName ?? "-")"
        guard key != lastKey else { return }
        lastKey = key
        rebuild()
    }

    private func rebuildNow() {
        lastKey = ""
        if draft == nil { refresh() } else { rebuild() }
    }

    private func rebuild() {
        guard let host = host else { return }
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }

        let eyebrow = Brand.eyebrow(welcome ? "Welcome to Nacho Combo" : "Combos")
        let title = Brand.signLabel("What's your order?", size: 40)
        title.setAccessibilityIdentifier("combos-title")
        let lede = UI.wrapLabel(welcome
            ? "Everything starts off. Pick a combo to switch on a few gadgets together, make your own, or choose them one by "
                + "one in All Gadgets. Each combo shows what gets easier before you order."
            : "Pick a combo to switch on a few gadgets together, or make your own. Before you order, it shows what gets "
                + "easier, what changes in your box and what it asks for. Every gadget stays its own switch afterwards.",
            width: ComboPage.inner, style: .callout)
        content.addArrangedSubview(eyebrow)
        content.setCustomSpacing(4, after: eyebrow)
        content.addArrangedSubview(title)
        content.setCustomSpacing(8, after: title)
        content.addArrangedSubview(lede)
        content.setCustomSpacing(16, after: lede)

        if let name = host.orderUndoName, draft == nil {
            let text = UI.label("\(name) ordered. Undo puts your box back as it was.", style: .callout, weight: .semibold)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let undo = BrandButton("Undo", style: .secondary, small: true) { [weak self] in
                self?.host?.undoOrder()
                self?.rebuildNow()
            }
            undo.setAccessibilityIdentifier("combo-undo")
            let line = UI.hstack([UI.symbolView("arrow.uturn.backward.circle", size: 14, tint: Brand.guac), text, UI.spacer(), undo],
                                 spacing: 8)
            let card = TintedCardView(tone: .success, content: line, padding: 10)
            card.widthAnchor.constraint(equalToConstant: ComboPage.inner).isActive = true
            content.addArrangedSubview(card)
            content.setCustomSpacing(12, after: card)
        }

        // The board: the numbered presets, the user's own, then the order or the editor.
        let tileWidth = floor((ComboPage.boardInner - 4 * 8) / 5)
        let editingID = draft?.id
        func tile(_ combo: Combo) -> NSView {
            let button = BoardTileButton(top: "No.\(combo.number)", name: combo.name, note: permissionText(combo),
                                         identifier: "combo-\(combo.id)", accessibility: "Combo \(combo.number), \(combo.name)")
            button.selected = editingID.map { $0 == combo.id } ?? (combo.id == selectedID)
            button.onPress = { [weak self] in self?.select(combo.id) }
            button.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true
            return button
        }
        var rows: [NSView] = [UI.hstack(ComboCatalog.presets.map(tile), spacing: 8, alignment: .top)]
        let customs = ComboCatalog.combos(settings).filter { $0.isCustom }
        var ownTiles = customs.map(tile)
        if customs.count < ComboCatalog.maxCustom {
            let new = BoardTileButton(top: "+", name: "New Combo", note: "From your box", identifier: "combo-new",
                                      accessibility: "Make a new combo", dashed: true)
            new.selected = draft != nil && draftIsNew
            new.onPress = { [weak self] in self?.startNewCombo() }
            new.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true
            ownTiles.append(new)
        }
        rows.append(Brand.eyebrow("Your combos", size: 10.5, color: Brand.boardMute))
        rows.append(UI.hstack(ownTiles, spacing: 8, alignment: .top))
        rows.append(draft.map { editorPanel($0) } ?? orderPanel())
        let boardColumn = UI.vstack(rows, spacing: 10)
        boardColumn.setCustomSpacing(14, after: rows[0])
        boardColumn.setCustomSpacing(6, after: rows[1])
        boardColumn.setCustomSpacing(14, after: rows[2])
        let board = BoardView().wrap(boardColumn, padding: ComboPage.boardPadding)
        board.widthAnchor.constraint(equalToConstant: ComboPage.inner).isActive = true
        board.setAccessibilityElement(true)
        board.setAccessibilityRole(.group)
        board.setAccessibilityLabel("Combo menu")
        content.addArrangedSubview(board)
        content.setCustomSpacing(12, after: board)
        content.addArrangedSubview(UI.wrapLabel("A combo switches gadgets and a few settings; it never changes your "
                                                + "shortcuts. You can switch any gadget on or off afterwards, and undo an order.",
                                                width: ComboPage.inner, style: .footnote, color: UI.tertiaryText))
    }

    private func boardText(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                           color: NSColor = Brand.boardInk, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Brand.body(size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func panel(_ views: [NSView], spacingAfter: [(NSView, CGFloat)]) -> NSView {
        let column = UI.vstack(views, spacing: 8)
        for (view, gap) in spacingAfter { column.setCustomSpacing(gap, after: view) }
        let panel = BoardView(radius: 16, fill: Brand.board2, stroke: Brand.boardLine, lineWidth: 2)
            .wrap(column, padding: ComboPage.orderPadding)
        panel.widthAnchor.constraint(equalToConstant: ComboPage.boardInner).isActive = true
        return panel
    }

    private func tray(_ gadgets: [ModuleID], editing: Bool) -> NSView {
        guard let host = host else { return NSView() }
        let width = ComboPage.orderInner
        let slotWidth = floor((width - 2 * 8) / 3)
        var slots: [NSView] = []
        for id in ModuleID.allCases {
            let lit = gadgets.contains(id)
            let lock = id.info.requiredPermission.flatMap { host.gadgetPermissionGranted($0) == true ? nil : $0.displayName }
            let slot = TraySlotView(module: id, lit: lit, lock: lit ? lock : nil)
            if editing {
                slot.onToggle = { [weak self] id in
                    guard var draft = self?.draft else { return }
                    if draft.gadgets.contains(id) { draft.gadgets.removeAll { $0 == id } } else { draft.gadgets.append(id) }
                    self?.draft = draft
                    self?.rebuildNow()
                }
            }
            slot.widthAnchor.constraint(equalToConstant: slotWidth).isActive = true
            slots.append(slot)
        }
        return UI.vstack([UI.hstack(Array(slots.prefix(3)), spacing: 8, alignment: .top),
                          UI.hstack(Array(slots.dropFirst(3)), spacing: 8, alignment: .top)], spacing: 8)
    }

    private func momentViews(_ moments: [ComboMoment]) -> [NSView] {
        let width = ComboPage.orderInner
        return moments.map { moment in
            let keyView = BoardKeyView(keys(for: moment))
            let icon = NSImageView(image: GadgetIcon.image(for: moment.module, size: 18))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let text = boardText(moment.result, size: 13, width: max(120, width - keyView.intrinsicContentSize.width - 18 - 20))
            let line = UI.hstack([icon, keyView, text], spacing: 10)
            line.setAccessibilityElement(true)
            line.setAccessibilityLabel("\(keys(for: moment)): \(moment.result)")
            return line
        }
    }

    private func asksText(_ gadgets: [ModuleID]) -> String {
        guard let host = host else { return "" }
        let needs = gadgets.compactMap { $0.info.requiredPermission }
        let missing = gadgets.compactMap { id -> String? in
            guard let permission = id.info.requiredPermission, host.gadgetPermissionGranted(permission) != true else { return nil }
            return "\(permission.displayName) for \(id.displayName)"
        }
        if needs.isEmpty { return "Nothing. These gadgets need no permission." }
        if missing.isEmpty { return "Nothing new: " + needs.map { $0.displayName }.joined(separator: " and ") + " already allowed." }
        return missing.joined(separator: ", ") + ". Asked one at a time, only when you press Allow."
    }

    private func linkButton(_ title: String, color: NSColor = Brand.nacho, id: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, handler: action)
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color,
                                                                                .font: Brand.body(12.5, weight: .semibold)])
        button.setAccessibilityIdentifier(id)
        return button
    }

    // MARK: the order

    private func orderPanel() -> NSView {
        guard let host = host else { return NSView() }
        let combo = selected
        let plan = ComboPlan.make(combo, settings: settings)
        let waiting = pending(combo)
        let width = ComboPage.orderInner
        let isCurrent = ComboCatalog.current(settings)?.id == combo.id
        var views: [NSView] = []
        var gaps: [(NSView, CGFloat)] = []

        let name = Brand.signLabel(combo.name, size: 30, color: Brand.nacho)
        name.setAccessibilityIdentifier("combo-name")
        var headViews: [NSView] = [name, UI.spacer()]
        if isCurrent { headViews.append(Brand.eyebrow("Your box", color: Brand.nacho)) }
        let head = UI.hstack(headViews, spacing: 8)
        head.widthAnchor.constraint(equalToConstant: width).isActive = true
        views.append(head)
        gaps.append((head, 2))
        views.append(boardText(combo.line, size: 14, weight: .semibold, width: width))
        let who = boardText(combo.who, size: 12, color: Brand.boardMute, width: width)
        views.append(who)
        gaps.append((who, 12))
        let trayView = tray(combo.gadgets, editing: false)
        views.append(trayView)
        gaps.append((trayView, 14))

        views.append(Brand.eyebrow("What gets easier", color: Brand.boardMute))
        views.append(contentsOf: momentViews(combo.moments))

        views.append(Brand.eyebrow("What changes in your box", color: Brand.boardMute))
        func change(_ tag: String, _ text: String, _ color: NSColor) {
            let tagLabel = Brand.eyebrow(tag, size: 10, color: color)
            tagLabel.translatesAutoresizingMaskIntoConstraints = false
            tagLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
            views.append(UI.hstack([tagLabel, boardText(text, size: 13, width: width - 82)], spacing: 10, alignment: .firstBaseline))
        }
        let names: ([ModuleID]) -> String = { $0.map { $0.displayName }.joined(separator: ", ") }
        if plan.isNoChange {
            views.append(boardText("Nothing: this is your box as it is.", size: 13, color: Brand.boardMute, width: width))
        } else {
            if !plan.turnsOn.isEmpty { change("Turns on", names(plan.turnsOn), Brand.nacho) }
            if !plan.staysOn.isEmpty { change("Stays on", names(plan.staysOn), Brand.boardMute) }
            if !plan.turnsOff.isEmpty { change("Turns off", names(plan.turnsOff), Brand.boardSalsa) }
            for line in plan.optionChanges { change("Setting", line, Brand.boardMute) }
        }

        views.append(Brand.eyebrow("Asks for", color: Brand.boardMute))
        views.append(boardText(asksText(combo.gadgets), size: 13, width: width))

        if !waiting.isEmpty {
            views.append(Brand.eyebrow("To finish \(combo.name)", color: Brand.nacho))
            for id in waiting {
                guard let permission = id.info.requiredPermission else { continue }
                let icon = NSImageView(image: GadgetIcon.image(for: id, size: 22))
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
                let enabled = settings.isEnabled(id)
                let button: NSButton = enabled
                    ? BrandButton("Show Steps", style: .board, small: true) { [weak self] in self?.onOpen?(.gadget(id)) }
                    : BrandButton("Allow \(permission.displayName)…", style: .attention, small: true) { [weak self] in
                        self?.host?.allowFromCombo(id)
                    }
                button.setAccessibilityIdentifier("combo-allow-\(id.rawValue)")
                let text = boardText(enabled ? "\(id.displayName) is waiting for \(permission.displayName)."
                                             : "\(id.displayName) needs \(permission.displayName).",
                                     size: 13, weight: .semibold,
                                     width: width - 22 - button.intrinsicContentSize.width - 3 * 10)
                let line = UI.hstack([icon, text, UI.spacer(), button], spacing: 10)
                line.widthAnchor.constraint(equalToConstant: width).isActive = true
                views.append(line)
            }
        } else if isCurrent && plan.isNoChange {
            views.append(boardText("\(combo.name) is your box. Every gadget in it is ready.", size: 13.5, weight: .semibold,
                                   color: Brand.boardGuac, width: width))
        } else {
            let order = BrandButton("Order \(combo.name)", style: .primary) { [weak self] in
                guard let self = self else { return }
                self.host?.orderCombo(combo.id)
                self.rebuildNow()
            }
            order.setAccessibilityIdentifier("combo-order")
            let missing = combo.gadgets.contains { id in
                id.info.requiredPermission.map { host.gadgetPermissionGranted($0) != true } ?? false
            }
            let note = boardText(missing ? "Gadgets that need a permission wait for your Allow; the rest start at once."
                                         : "Takes effect at once. You can undo it.", size: 12, color: Brand.boardMute,
                                 width: width - order.intrinsicContentSize.width - 14)
            views.append(UI.hstack([order, note], spacing: 14))
        }

        // Make it your own: edit or delete one's own; start a copy of a preset.
        var links: [NSView] = []
        if combo.isCustom {
            links.append(linkButton("Edit", id: "combo-edit") { [weak self] in self?.edit(combo.id) })
            links.append(linkButton("Delete…", color: Brand.boardSalsa, id: "combo-delete") { [weak self] in
                self?.confirmDelete(combo)
            })
        } else if settings.customCombos.count < ComboCatalog.maxCustom {
            links.append(linkButton("Make Your Own from \(combo.name)", id: "combo-copy") { [weak self] in
                self?.startNewCombo(copying: combo)
            })
        }
        if !links.isEmpty {
            let separator = UI.separator(width: width)
            views.append(separator)
            views.append(UI.hstack(links + [UI.spacer()], spacing: 16))
        }
        return panel(views, spacingAfter: gaps)
    }

    private func confirmDelete(_ combo: Combo) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(combo.name)”?"
        alert.informativeText = "Your gadgets and settings stay as they are; only the combo goes."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.host?.deleteCombo(combo.id)
            self.selectedID = ComboCatalog.current(self.settings)?.id ?? ComboCatalog.presets[0].id
            self.draft = nil
            self.rebuildNow()
        }
        if let window = window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }

    // MARK: making one's own

    private func editorPanel(_ draft: SavedCombo) -> NSView {
        let width = ComboPage.orderInner
        var views: [NSView] = []
        var gaps: [(NSView, CGFloat)] = []

        let eyebrow = Brand.eyebrow(draftIsNew ? "New combo" : "Edit combo", color: Brand.nacho)
        views.append(eyebrow)
        gaps.append((eyebrow, 4))
        // The name on its own framed strip, in the text face (Anton's tall metrics push a field's text off-center).
        let field = NSTextField(string: draft.name)
        field.font = Brand.body(18, weight: .bold)
        field.textColor = Brand.boardInk
        field.drawsBackground = false
        field.isBordered = false
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "My Combo"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel("Combo name")
        field.setAccessibilityIdentifier("combo-name-field")
        let frame = BoardView(radius: 8, fill: Brand.board, stroke: Brand.boardLine, lineWidth: 1.5).wrap(field, padding: 7)
        frame.widthAnchor.constraint(equalToConstant: width).isActive = true
        views.append(frame)
        let hint = boardText("Up to \(ComboCatalog.maxNameLength) letters. Tap the gadgets below to put them in or take them out.",
                             size: 12, color: Brand.boardMute, width: width)
        views.append(hint)
        gaps.append((hint, 12))
        let trayView = tray(draft.gadgets, editing: true)
        views.append(trayView)
        gaps.append((trayView, 14))

        let tunable = optionRows(draft)
        if !tunable.isEmpty {
            views.append(Brand.eyebrow("Settings it brings", color: Brand.boardMute))
            views.append(contentsOf: tunable)
        }

        let preview = ComboCatalog.moments(for: draft.gadgets)
        views.append(Brand.eyebrow("What gets easier", color: Brand.boardMute))
        if preview.isEmpty {
            views.append(boardText("Pick at least one gadget.", size: 13, color: Brand.boardMute, width: width))
        } else {
            views.append(contentsOf: momentViews(preview))
        }
        views.append(Brand.eyebrow("Asks for", color: Brand.boardMute))
        views.append(boardText(draft.gadgets.isEmpty ? "—" : asksText(draft.gadgets), size: 13, width: width))

        let save = BrandButton(draftIsNew ? "Save Combo" : "Save Changes", style: .primary) { [weak self] in self?.saveDraft() }
        save.isEnabled = draft.isValid
        save.setAccessibilityIdentifier("combo-save")
        let cancel = BrandButton("Cancel", style: .board) { [weak self] in
            self?.draft = nil
            self?.rebuildNow()
        }
        cancel.setAccessibilityIdentifier("combo-cancel")
        var buttons: [NSView] = [save, cancel, UI.spacer()]
        if !draftIsNew {
            let delete = linkButton("Delete…", color: Brand.boardSalsa, id: "combo-delete") { [weak self] in
                guard let self = self, let combo = ComboCatalog.combo(draft.id, in: self.settings) else { return }
                self.confirmDelete(combo)
            }
            buttons.append(delete)
        }
        let row = UI.hstack(buttons, spacing: 10)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        views.append(UI.separator(width: width))
        views.append(row)
        return panel(views, spacingAfter: gaps)
    }

    /// The settings a combo can bring, for the gadgets in it. "Keep as it is" leaves the user's own value alone.
    private func optionRows(_ draft: SavedCombo) -> [NSView] {
        var rows: [NSView] = []
        func row<T: Equatable>(_ title: String, _ choices: [(String, T?)], _ current: T?,
                               _ set: @escaping (inout ComboTuning, T?) -> Void, id: String) {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.font = UI.controlFont(.callout)
            popup.setAccessibilityLabel(title)
            popup.setAccessibilityIdentifier("combo-option-\(id)")
            for (index, choice) in choices.enumerated() {
                let item = ClosureMenuItem(title: choice.0) { [weak self] in
                    guard var draft = self?.draft else { return }
                    set(&draft.tuning, choices[index].1)
                    self?.draft = draft
                }
                popup.menu?.addItem(item)
            }
            if let index = choices.firstIndex(where: { $0.1 == current }) { popup.selectItem(at: index) }
            let label = boardText(title, size: 13, width: ComboPage.orderInner - 200)
            let line = UI.hstack([label, UI.spacer(), popup], spacing: 8)
            line.widthAnchor.constraint(equalToConstant: ComboPage.orderInner).isActive = true
            rows.append(line)
        }
        let keep = "Keep as it is"
        if draft.gadgets.contains(.windowSnap) {
            row("Gap Between Windows", [(keep, nil)] + GadgetOptions.gapChoices.map { ($0 == 0 ? "None" : "\($0) pt", Optional($0)) },
                draft.tuning.snapGap, { $0.snapGap = $1 }, id: "gap")
        }
        if draft.gadgets.contains(.focusDim) {
            row("Dim Strength", [(keep, nil)] + [0.3, 0.4, 0.5, 0.6, 0.7, 0.8].map { ("\(Int($0 * 100))%", Optional($0)) },
                draft.tuning.dimIntensity, { $0.dimIntensity = $1 }, id: "dim")
            row("Other Displays", [(keep, nil), ("Dim Them Too", Optional(true)), ("Leave Them Bright", Optional(false))],
                draft.tuning.dimOtherDisplays, { $0.dimOtherDisplays = $1 }, id: "displays")
        }
        if draft.gadgets.contains(.menuBar) {
            row("Collapse Again After", [(keep, nil)] + GadgetOptions.autoCollapseChoices.map {
                ($0 == 0 ? "Never" : "\($0) Seconds", Optional($0))
            }, draft.tuning.autoCollapseSeconds, { $0.autoCollapseSeconds = $1 }, id: "collapse")
        }
        if draft.gadgets.contains(.systemMonitor) {
            let sets: [(String, [MonitorItem]?)] = [(keep, nil), ("CPU, Memory, Network", [.cpu, .memory, .network]),
                                                    ("CPU and Memory", [.cpu, .memory]),
                                                    ("All but Battery", [.cpu, .memory, .disk, .network, .sensors]),
                                                    ("All Six", MonitorItem.allCases)]
            row("Menu Bar Items", sets, draft.tuning.monitorItems, { $0.monitorItems = $1 }, id: "items")
        }
        return rows
    }

    func saveDraft() {
        guard let draft = draft, draft.isValid, let host = host else { return }
        if host.saveCombo(draft) {
            selectedID = draft.id
            self.draft = nil
        }
        rebuildNow()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field.stringValue.count > ComboCatalog.maxNameLength {
            field.stringValue = String(field.stringValue.prefix(ComboCatalog.maxNameLength))
        }
        draft?.name = field.stringValue
    }
}
