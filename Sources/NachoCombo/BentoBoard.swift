import AppKit
import QuartzCore
import NachoComboCore

/// What the widget board needs from the app. Reading is free of side effects: no tool starts, no permission prompt.
protocol BentoHost: AnyObject {
    var bentoLayout: BentoLayout { get }
    func bentoUpdateLayout(_ change: (inout BentoLayout) -> Void)
    func bentoWidget(_ id: ModuleID) -> BentoWidget
    func bentoPetImage(signedIn: Bool) -> NSImage?
    func bentoSetEnabled(_ id: ModuleID, _ on: Bool)
    func bentoSetPinned(_ id: ModuleID, _ pinned: Bool)
    /// The tool's page in Settings (a widget click, Return on a focused widget).
    func bentoOpen(_ id: ModuleID)
    /// The widget's own button (sign in, open the chat, open a permission).
    func bentoPerform(_ id: ModuleID)
    func bentoOpenSettings()
    /// The main widget board window.
    func bentoOpenBoard()
}

enum BentoEditKey { case earlier, later, hide, select }
enum BentoDragPhase { case began, moved, ended }

/// One widget: header (status circle, name, open shortcut, switch) and its body. Off: the body is faded, the header
/// and switch stay sharp and the switch works. Compact = the menu bar mini board (no switch, smaller paddings).
final class BentoCardView: NSView {
    let module: ModuleID
    let compact: Bool
    private(set) var widget: BentoWidget?
    var size: BentoSize = .small { didSet { bodyView.size = size; needsLayout = true } }
    var editing = false { didSet { needsLayout = true; needsDisplay = true; updateAccessibility() } }
    var selected = false { didSet { needsDisplay = true } }
    var dropTarget = false { didSet { needsDisplay = true } }

    var onOpen: ((ModuleID) -> Void)?
    var onToggle: ((ModuleID, Bool) -> Void)?
    var onAction: ((ModuleID) -> Void)?
    var onEditKey: ((ModuleID, BentoEditKey) -> Void)?
    var onDrag: ((ModuleID, NSEvent, BentoDragPhase) -> Void)?

    private let dot = BentoDotView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let toggle: BentoSwitch
    let bodyView = BentoBodyView()
    private let button = BentoButton(title: "")
    private var pressPoint: NSPoint?
    private var dragging = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }

    init(module: ModuleID, compact: Bool = false) {
        self.module = module
        self.compact = compact
        toggle = BentoSwitch(name: module.displayName)
        super.init(frame: .zero)
        wantsLayer = true
        focusRingType = .exterior
        nameLabel.font = BentoDraw.font(compact ? 12 : 12, .semibold)
        nameLabel.textColor = Brand.Bento.ink
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.stringValue = BentoFormat.name(module)
        nameLabel.toolTip = module.displayName
        shortcutLabel.font = BentoDraw.mono(11)
        shortcutLabel.textColor = Brand.Bento.ink2
        shortcutLabel.alignment = .right
        bodyView.module = module
        bodyView.compact = compact
        for v in [dot, nameLabel, shortcutLabel, toggle, bodyView, button] as [NSView] { addSubview(v) }
        toggle.onToggle = { [weak self] on in
            guard let self = self else { return }
            self.onToggle?(self.module, on)
        }
        button.handler = { [weak self] in
            guard let self = self else { return }
            self.onAction?(self.module)
        }
        toggle.isHidden = compact
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ w: BentoWidget, petImage: NSImage?) {
        widget = w
        dot.dot = BentoDot(w.status.dot)
        shortcutLabel.stringValue = w.shortcut ?? ""
        toggle.isOn = w.enabled
        bodyView.body = w.body
        bodyView.petImage = petImage
        var action: String?
        switch w.body {
        case let .pet(_, a, _): action = a
        case let .checklist(_, a): action = a
        default: action = nil
        }
        button.title = action ?? ""
        button.isHidden = action == nil || compact
        bodyView.alphaValue = w.enabled ? 1 : Brand.Bento.offAlpha
        button.alphaValue = w.enabled ? 1 : Brand.Bento.offAlpha
        updateAccessibility()
        needsLayout = true
        needsDisplay = true
        bodyView.needsDisplay = true
    }

    private func updateAccessibility() {
        guard let w = widget else { return }
        var label = "\(module.displayName), \(BentoDot(w.status.dot).koreanText)"
        if let d = w.status.detail { label += ", \(d)" }
        if w.pinned { label += ", 상단바에 고정됨" }
        setAccessibilityLabel(label)
        setAccessibilityHelp(editing ? "←→로 옮기고 Delete로 숨겨요. Return: 크기 고르기" : "Return: 도구 설정 열기")
        toolTip = nil
    }

    override func layout() {
        super.layout()
        // Edit mode's narrower cells (b3) get the design's tighter padding and a smaller name.
        let padX: CGFloat = compact || editing ? 12 : 16, padY: CGFloat = compact ? 10 : 14
        nameLabel.font = BentoDraw.font(editing ? 11.5 : 12, .semibold)
        let headerH: CGFloat = 17
        var right = bounds.width - padX
        let showSwitch = !compact && !editing
        toggle.isHidden = !showSwitch
        if showSwitch {
            toggle.frame = NSRect(x: right - 28, y: padY, width: 28, height: headerH)
            right -= 28 + 6
        }
        let shortcut = editing ? "" : shortcutLabel.stringValue
        shortcutLabel.isHidden = shortcut.isEmpty
        if !shortcut.isEmpty {
            let w = BentoDraw.textWidth(shortcut, BentoDraw.mono(11)) + 4
            shortcutLabel.frame = NSRect(x: right - w, y: padY + 1, width: w, height: 15)
            right -= w + 6
        }
        dot.frame = NSRect(x: padX, y: padY + 4.5, width: 12, height: 8)
        let nameX = padX + (editing ? 17 : 19)
        nameLabel.frame = NSRect(x: nameX, y: padY, width: max(10, right - nameX), height: headerH)
        let bodyTop = padY + headerH + 8
        let body = NSRect(x: padX, y: bodyTop, width: bounds.width - 2 * padX, height: max(0, bounds.height - bodyTop - padY))
        bodyView.frame = body
        var room: CGFloat = 0
        if !button.isHidden {
            if case .pet = widget?.body {
                if body.height > 120 {
                    button.frame = NSRect(x: body.minX + 12, y: body.maxY - 10 - 32, width: body.width - 24, height: 32)
                    room = 32
                } else { button.frame = .zero }
            } else if body.height > 70 {
                button.frame = NSRect(x: body.minX, y: body.maxY - 32, width: body.width, height: 32)
                room = 38
            } else { button.frame = .zero }
        }
        button.isHidden = button.isHidden || button.frame.height == 0
        bodyView.buttonRoom = room
        bodyView.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = compact ? Brand.Bento.miniRadius : Brand.Bento.radius
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let on = widget?.enabled ?? false
        let fill: NSColor = compact ? Brand.Bento.mini : (on ? Brand.Bento.glassOn : Brand.Bento.glass)
        BentoDraw.rounded(r, radius, fill: fill)
        let edge = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        edge.lineWidth = 1
        Brand.Bento.glassEdge.setStroke()
        edge.stroke()
        if editing {
            if selected {
                let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
                p.lineWidth = 3
                Brand.Bento.selected.setStroke()
                p.stroke()
            } else {
                BentoDraw.dashed(bounds.insetBy(dx: 0.5, dy: 0.5), radius, color: Brand.Bento.editOutline, width: 1.5)
            }
        }
        if dropTarget {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius)
            p.lineWidth = 3
            Brand.Bento.dotOn.setStroke()
            p.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        bodyView.needsDisplay = true
    }

    override func drawFocusRingMask() {
        let radius = compact ? Brand.Bento.miniRadius : Brand.Bento.radius
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: input

    override func hitTest(_ point: NSPoint) -> NSView? {
        // In edit mode the whole card is one handle: no switch or button reacts.
        guard editing else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        if editing { onEditKey?(module, .select) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing, let start = pressPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - start.x, dy = p.y - start.y
        if !dragging, dx * dx + dy * dy > 16 {
            dragging = true
            onDrag?(module, event, .began)
        }
        if dragging { onDrag?(module, event, .moved) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; dragging = false }
        if dragging { onDrag?(module, event, .ended); return }
        guard !editing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?(module)
    }

    override func keyDown(with event: NSEvent) {
        let code = event.keyCode
        if [36, 49, 76].contains(code) {
            if editing { onEditKey?(module, .select) } else { onOpen?(module) }
        } else if editing, code == 123 || code == 126 {
            onEditKey?(module, .earlier)
        } else if editing, code == 124 || code == 125 {
            onEditKey?(module, .later)
        } else if editing, code == 51 || code == 117 {
            onEditKey?(module, .hide)
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        if editing { onEditKey?(module, .select) } else { onOpen?(module) }
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: editing ? .openHand : .pointingHand) }

    // MARK: edit mode wiggle

    func setWiggle(_ on: Bool, delay: Bool) {
        guard let layer = layer else { return }
        layer.removeAnimation(forKey: "wiggle")
        guard on, !UI.reduceMotion else { return }
        let w = bounds.width / 2, h = bounds.height / 2
        func turn(_ degrees: CGFloat) -> NSValue {
            var t = CATransform3DMakeTranslation(w, h, 0)
            t = CATransform3DRotate(t, degrees * .pi / 180, 0, 0, 1)
            t = CATransform3DTranslate(t, -w, -h, 0)
            return NSValue(caTransform3D: t)
        }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = turn(-0.6)
        a.toValue = turn(0.6)
        a.duration = 0.28
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if delay { a.beginTime = CACurrentMediaTime() + 0.14 }
        layer.add(a, forKey: "wiggle")
    }
}

/// "+ 위젯 추가": the board's last cell. Brings a hidden widget back.
final class BentoAddCard: NSView {
    var onPress: ((NSView) -> Void)?
    var title = "위젯 추가"
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("위젯 추가")
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        BentoDraw.dashed(bounds.insetBy(dx: 0.5, dy: 0.5), Brand.Bento.radius, color: NSColor.white.withAlphaComponent(0.6), width: 1.5)
        let plus = BentoDraw.font(24)
        let f = BentoDraw.font(13)
        let total = BentoDraw.lineHeight(plus) + BentoDraw.lineHeight(f)
        let y = (bounds.height - total) / 2
        BentoDraw.text("＋", at: NSPoint(x: 0, y: y), width: bounds.width, font: plus, color: Brand.Bento.ink, align: .center)
        BentoDraw.text(title, at: NSPoint(x: 0, y: y + BentoDraw.lineHeight(plus)), width: bounds.width, font: f, color: Brand.Bento.ink, align: .center)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: Brand.Bento.radius, yRadius: Brand.Bento.radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?(self) }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPress?(self) } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(self); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The "−" on a card's corner in edit mode: hides the widget (the tool keeps running).
final class BentoRemoveBadge: NSView {
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    init(name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(name) 위젯 숨기기")
        toolTip = "위젯 숨기기 (도구는 그대로)"
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        // A light ring keeps it visible on the selected card's dark outline.
        NSColor.white.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        Brand.Bento.selected.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
        Brand.Bento.buttonInk.setFill()
        NSRect(x: 5, y: 8, width: 8, height: 2).fill()
    }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

/// The grid: cards in board order packed by `BentoPacker`, the add cell last. Edit mode adds the wiggle, the "−"
/// badges, drag to move and the keyboard moves.
final class BentoBoardView: NSView {
    weak var host: BentoHost?
    private(set) var editing = false
    private(set) var selectedID: ModuleID?
    var onSelectionChange: ((ModuleID?) -> Void)?
    var onOpenHiddenMenu: ((NSView) -> Void)?
    var padding: CGFloat = Brand.Bento.padding
    /// The window's top bar already leaves room above the board.
    var topPadding: CGFloat = 0
    var rowHeight: CGFloat = Brand.Bento.rowHeight
    var minCell: CGFloat = Brand.Bento.minCell
    private var cards: [ModuleID: BentoCardView] = [:]
    private var badges: [ModuleID: BentoRemoveBadge] = [:]
    private let addCard = BentoAddCard()
    private var order: [ModuleID] = []
    private var dragOffset = NSPoint.zero
    private var dropTarget: ModuleID?
    private(set) var columns = 6

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(addCard)
        addCard.onPress = { [weak self] v in self?.onOpenHiddenMenu?(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("위젯 보드")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var cardViews: [BentoCardView] { order.compactMap { cards[$0] } }

    /// Rebuilds the cards from the saved layout and the tools' current data.
    func reload() {
        guard let host = host else { return }
        let layout = host.bentoLayout
        let visible = layout.visible
        order = visible.compactMap { $0.module }
        for (id, card) in cards where !order.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
            badges[id]?.removeFromSuperview()
            badges[id] = nil
        }
        for item in visible {
            guard let id = item.module else { continue }
            let card = cards[id] ?? makeCard(id)
            card.size = item.size
            let w = host.bentoWidget(id)
            var signedIn = false
            if case let .pet(_, _, s) = w.body { signedIn = s }
            card.apply(w, petImage: id == .nachoPet ? host.bentoPetImage(signedIn: signedIn) : nil)
            card.editing = editing
            card.selected = editing && selectedID == id
        }
        if let s = selectedID, !order.contains(s) { select(nil) }
        addCard.title = layout.hiddenModules.isEmpty ? "위젯 추가" : "위젯 추가 (\(layout.hiddenModules.count))"
        addCard.needsDisplay = true
        relayout(animated: false)
        updateKeyLoop()
    }

    /// Only the data changed (a timer tick or a tool's state): no new cards, no relayout.
    func refreshData() {
        guard let host = host else { return }
        for id in order {
            guard let card = cards[id] else { continue }
            let w = host.bentoWidget(id)
            guard w != card.widget else { continue }
            var signedIn = false
            if case let .pet(_, _, s) = w.body { signedIn = s }
            card.apply(w, petImage: id == .nachoPet ? host.bentoPetImage(signedIn: signedIn) : nil)
        }
    }

    private func makeCard(_ id: ModuleID) -> BentoCardView {
        let card = BentoCardView(module: id)
        card.onOpen = { [weak self] id in self?.host?.bentoOpen(id) }
        card.onToggle = { [weak self] id, on in self?.host?.bentoSetEnabled(id, on) }
        card.onAction = { [weak self] id in self?.host?.bentoPerform(id) }
        card.onEditKey = { [weak self] id, key in self?.editKey(id, key) }
        card.onDrag = { [weak self] id, event, phase in self?.drag(id, event, phase) }
        addSubview(card, positioned: .below, relativeTo: addCard)
        cards[id] = card
        let badge = BentoRemoveBadge(name: id.displayName)
        badge.onPress = { [weak self] in self?.hide(id) }
        badge.isHidden = !editing
        addSubview(badge)
        badges[id] = badge
        return card
    }

    func setEditing(_ on: Bool) {
        editing = on
        if !on { select(nil) }
        for (i, id) in order.enumerated() {
            cards[id]?.editing = on
            cards[id]?.selected = on && selectedID == id
            badges[id]?.isHidden = !on
            cards[id]?.setWiggle(on && selectedID != id, delay: i % 2 == 1)
        }
        window?.invalidateCursorRects(for: self)
        relayout(animated: false)
    }

    func select(_ id: ModuleID?) {
        selectedID = id
        for (i, oid) in order.enumerated() {
            cards[oid]?.selected = editing && oid == id
            cards[oid]?.setWiggle(editing && oid != id, delay: i % 2 == 1)
        }
        onSelectionChange?(id)
    }

    /// The height the board needs at this width (rows of `Brand.Bento.rowHeight`).
    func rows(forWidth width: CGFloat) -> Int {
        let inner = width - 2 * padding
        let cols = BentoPacker.columns(forWidth: Double(inner), minCell: Double(minCell), gap: Double(Brand.Bento.gap))
        return BentoPacker.pack(host?.bentoLayout.visible ?? [], columns: cols, extra: ["add"]).rows
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let rows = rows(forWidth: width)
        return topPadding + padding + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * Brand.Bento.gap
    }

    func relayout(animated: Bool) {
        guard let host = host else { return }
        let inner = bounds.width - 2 * padding
        guard inner > 0 else { return }
        columns = BentoPacker.columns(forWidth: Double(inner), minCell: Double(minCell), gap: Double(Brand.Bento.gap))
        let gap = Brand.Bento.gap
        let cellW = (inner - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let rowH = rowHeight
        let placed = BentoPacker.pack(host.bentoLayout.visible, columns: columns, extra: ["add"]).placements
        let animate = animated && !UI.reduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animate ? 0.2 : 0
            ctx.allowsImplicitAnimation = animate
            for p in placed {
                let f = NSRect(x: padding + CGFloat(p.column) * (cellW + gap), y: topPadding + CGFloat(p.row) * (rowH + gap),
                               width: CGFloat(p.columns) * cellW + CGFloat(p.columns - 1) * gap,
                               height: CGFloat(p.rows) * rowH + CGFloat(p.rows - 1) * gap)
                if p.id == "add" { addCard.frame = f; continue }
                guard let id = ModuleID(rawValue: p.id), let card = cards[id] else { continue }
                if animate { card.animator().frame = f } else { card.frame = f }
                badges[id]?.frame = NSRect(x: f.minX - 7, y: f.minY - 7, width: 18, height: 18)
            }
        }
        for (i, id) in order.enumerated() where editing && selectedID != id { cards[id]?.setWiggle(true, delay: i % 2 == 1) }
    }

    override func layout() {
        super.layout()
        relayout(animated: false)
    }

    /// Tab goes through the widgets in board order, then the add cell.
    private func updateKeyLoop() {
        let views: [NSView] = cardViews + [addCard]
        for (i, v) in views.enumerated() { v.nextKeyView = i + 1 < views.count ? views[i + 1] : nil }
    }

    var firstCard: NSView? { cardViews.first }

    // MARK: editing

    private func editKey(_ id: ModuleID, _ key: BentoEditKey) {
        switch key {
        case .select: select(id)
        case .hide: hide(id)
        case .earlier, .later:
            host?.bentoUpdateLayout { $0.step(id, by: key == .earlier ? -1 : 1) }
            reload()
            relayout(animated: true)
            window?.makeFirstResponder(cards[id])
            select(id)
        }
    }

    func hide(_ id: ModuleID) {
        host?.bentoUpdateLayout { $0.setHidden(id, true) }
        if selectedID == id { select(nil) }
        reload()
    }

    func setSize(_ id: ModuleID, _ size: BentoSize) {
        host?.bentoUpdateLayout { $0.setSize(id, size) }
        reload()
    }

    private func drag(_ id: ModuleID, _ event: NSEvent, _ phase: BentoDragPhase) {
        guard let card = cards[id] else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch phase {
        case .began:
            dragOffset = NSPoint(x: p.x - card.frame.minX, y: p.y - card.frame.minY)
            card.setWiggle(false, delay: false)
            // Above the others while it moves (re-adding the view would end the mouse tracking).
            card.layer?.zPosition = 10
            badges[id]?.isHidden = true
        case .moved:
            card.setFrameOrigin(NSPoint(x: p.x - dragOffset.x, y: p.y - dragOffset.y))
            let target = order.first { $0 != id && (cards[$0]?.frame.contains(p) ?? false) }
            if target != dropTarget {
                if let old = dropTarget { cards[old]?.dropTarget = false }
                dropTarget = target
                if let t = target { cards[t]?.dropTarget = true }
            }
            autoscroll(with: event)
        case .ended:
            if let t = dropTarget {
                cards[t]?.dropTarget = false
                host?.bentoUpdateLayout { $0.drop(id, onto: t) }
            }
            dropTarget = nil
            card.layer?.zPosition = 0
            badges[id]?.isHidden = !editing
            reload()
            relayout(animated: true)
            select(id)
        }
    }
}

/// A choice chip (작게 / 가로 / 크게) or a size preview box of the edit panel.
final class BentoChoiceView: NSView {
    var text: String
    var detail: String?
    var chosen = false { didSet { needsDisplay = true; setAccessibilityValue(chosen ? "선택됨" : "") } }
    var onPress: (() -> Void)?
    private let box: Bool
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }

    init(text: String, detail: String? = nil, box: Bool) {
        self.text = text
        self.detail = detail
        self.box = box
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(detail.map { "\(text): \($0)" } ?? text)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if box {
            BentoDraw.rounded(bounds.insetBy(dx: 1, dy: 1), 16, fill: Brand.Bento.preview)
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: chosen ? 1 : 0.5, dy: chosen ? 1 : 0.5), xRadius: 16, yRadius: 16)
            p.lineWidth = chosen ? 2 : 1
            (chosen ? Brand.Bento.selected : Brand.Bento.line).setStroke()
            p.stroke()
            BentoDraw.text(chosen ? "\(text) (현재)" : text, at: NSPoint(x: 12, y: 10), width: bounds.width - 24, font: BentoDraw.font(12, .bold), color: Brand.Bento.ink)
            if let d = detail {
                BentoDraw.wrapped(d, at: NSPoint(x: 12, y: 30), width: bounds.width - 24, lines: 2, font: BentoDraw.font(12), color: Brand.Bento.ink2)
            }
        } else {
            BentoDraw.rounded(bounds, 8, fill: chosen ? Brand.Bento.selected : Brand.Bento.chip)
            let f = BentoDraw.font(12)
            BentoDraw.text(text, at: NSPoint(x: 0, y: (bounds.height - BentoDraw.lineHeight(f)) / 2 + 1), width: bounds.width, font: f,
                           color: chosen ? Brand.Bento.buttonInk : Brand.Bento.ink, align: .center)
        }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: box ? 16 : 8, yRadius: box ? 16 : 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPress?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A text line of the edit panel that does something when clicked ("· 상단바 고정 켬").
final class BentoLinkLine: NSView {
    var lead: String { didSet { needsDisplay = true; updateLabel() } }
    var value: String { didSet { needsDisplay = true; updateLabel() } }
    var valueColor: NSColor = Brand.Bento.ink { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }

    init(lead: String, value: String = "") {
        self.lead = lead
        self.value = value
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        focusRingType = .exterior
        updateLabel()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateLabel() { setAccessibilityLabel(value.isEmpty ? lead : "\(lead) \(value)") }

    override func draw(_ dirtyRect: NSRect) {
        let f = BentoDraw.font(12)
        let w = BentoDraw.text("· \(lead)", at: NSPoint(x: 0, y: 2), width: bounds.width, font: f, color: Brand.Bento.ink2)
        if !value.isEmpty {
            BentoDraw.text(value, at: NSPoint(x: w + 8, y: 2), width: bounds.width - w - 8, font: BentoDraw.font(12, .bold), color: valueColor)
        }
    }
    override func mouseDown(with event: NSEvent) { onPress?() }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPress?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Edit mode's right panel: the selected widget's size (three previews) and its pin, shortcut and hide.
final class BentoEditDrawer: NSView {
    weak var host: BentoHost?
    var onSize: ((ModuleID, BentoSize) -> Void)?
    var onHide: ((ModuleID) -> Void)?
    private(set) var module: ModuleID?
    private let title = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var chips: [BentoChoiceView] = []
    private var boxes: [BentoChoiceView] = []
    private let pinLine = BentoLinkLine(lead: "상단바 고정")
    private let shortcutLine = BentoLinkLine(lead: "단축키")
    private let hideLine = BentoLinkLine(lead: "위젯 숨기기")
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = BentoDraw.font(15, .bold)
        title.textColor = Brand.Bento.ink
        hint.font = BentoDraw.font(12)
        hint.textColor = Brand.Bento.ink2
        addSubview(title)
        addSubview(hint)
        for size in BentoSize.allCases {
            let chip = BentoChoiceView(text: size.koreanName, box: false)
            chip.onPress = { [weak self] in self?.choose(size) }
            chips.append(chip)
            addSubview(chip)
            let box = BentoChoiceView(text: size.koreanName, detail: "", box: true)
            box.onPress = { [weak self] in self?.choose(size) }
            boxes.append(box)
            addSubview(box)
        }
        for l in [pinLine, shortcutLine, hideLine] { addSubview(l) }
        pinLine.onPress = { [weak self] in
            guard let self = self, let id = self.module, let host = self.host else { return }
            host.bentoSetPinned(id, !host.bentoWidget(id).pinned)
            self.show(id)
        }
        shortcutLine.onPress = { [weak self] in
            guard let id = self?.module else { return }
            self?.host?.bentoOpen(id)
        }
        hideLine.onPress = { [weak self] in
            guard let id = self?.module else { return }
            self?.onHide?(id)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("위젯 설정")
        show(nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func choose(_ size: BentoSize) {
        guard let id = module else { return }
        onSize?(id, size)
        show(id)
    }

    func show(_ id: ModuleID?) {
        module = id
        let has = id != nil
        for v in chips + boxes { v.isHidden = !has }
        for v in [pinLine, shortcutLine, hideLine] { v.isHidden = !has }
        guard let id = id, let host = host else {
            title.stringValue = "위젯 편집"
            hint.stringValue = "위젯을 고르면 크기와 상단바 고정을 바꿀 수 있어요. 끌어서 옮기거나, 고른 뒤 화살표 키로 옮겨요."
            needsLayout = true
            return
        }
        let current = host.bentoLayout.item(id)?.size ?? BentoLayout.defaultSize(id)
        title.stringValue = id.displayName
        hint.stringValue = "위젯 크기를 고르세요"
        for (i, size) in BentoSize.allCases.enumerated() {
            chips[i].chosen = size == current
            boxes[i].chosen = size == current
            boxes[i].detail = BentoSizeText.describe(id, size)
            boxes[i].setAccessibilityLabel("\(size.koreanName): \(BentoSizeText.describe(id, size))")
            boxes[i].needsDisplay = true
        }
        let w = host.bentoWidget(id)
        pinLine.value = w.pinned ? "켬" : "끔"
        pinLine.valueColor = w.pinned ? Brand.Bento.dotOn : Brand.Bento.ink2
        shortcutLine.lead = w.shortcut.map { "단축키 \($0)" } ?? "단축키 없음 · 설정에서 정하기"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 18
        let w = bounds.width - 2 * pad
        var y = pad
        title.frame = NSRect(x: pad, y: y, width: w, height: 20)
        y += 24
        let hintH = BentoDraw.wrappedHeight(hint.stringValue, width: w, lines: 4, font: BentoDraw.font(12)) + 2
        hint.preferredMaxLayoutWidth = w
        hint.frame = NSRect(x: pad, y: y, width: w, height: hintH)
        y += hintH + 10
        guard module != nil else { return }
        let cw = (w - 12) / 3
        for (i, c) in chips.enumerated() { c.frame = NSRect(x: pad + CGFloat(i) * (cw + 6), y: y, width: cw, height: 28) }
        y += 28 + 14
        for b in boxes {
            b.frame = NSRect(x: pad, y: y, width: w, height: 64)
            y += 64 + 10
        }
        y += 4
        for l in [pinLine, shortcutLine, hideLine] {
            l.frame = NSRect(x: pad, y: y, width: w, height: 20)
            y += 22
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        BentoDraw.rounded(bounds, Brand.Bento.radius, fill: Brand.Bento.drawer)
    }
    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        for v in subviews { v.needsDisplay = true }
    }

    var firstControl: NSView? { chips.first }
}

/// A small pill button of the window's top bar ("위젯 편집", "설정", "완료").
final class BentoPill: NSView {
    var title: String { didSet { needsDisplay = true; setAccessibilityLabel(title); invalidateIntrinsicContentSize() } }
    var strong = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: BentoDraw.textWidth(title, BentoDraw.font(13, .semibold)) + 32, height: 28) }

    init(title: String, strong: Bool = false) {
        self.title = title
        self.strong = strong
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        BentoDraw.rounded(bounds, bounds.height / 2, fill: strong ? Brand.Bento.button : Brand.Bento.glassOn)
        let f = BentoDraw.font(13, .semibold)
        BentoDraw.text(title, at: NSPoint(x: 0, y: (bounds.height - BentoDraw.lineHeight(f)) / 2 + 1), width: bounds.width, font: f,
                       color: strong ? Brand.Bento.buttonInk : Brand.Bento.ink, align: .center)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPress?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
