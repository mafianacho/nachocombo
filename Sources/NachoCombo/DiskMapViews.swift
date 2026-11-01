import AppKit
import NachoComboCore

/// The picture: the map drawn once into a bitmap, with hover and selection on top so moving the pointer costs nothing.
/// Before a map exists it shows the start screen or the scan's progress.
final class DiskCanvasView: NSView {
    enum Content: Equatable {
        case empty
        case scanning
        case map
    }

    var content: Content = .empty { didSet { if content != oldValue { invalidateMap() } } }
    var focus: DiskNode? { didSet { invalidateMap() } }
    var slices: [DiskNode] = [] { didSet { invalidateMap() } }
    var style: DiskMapStyle = .sunburst { didSet { if style != oldValue { invalidateMap() } } }
    var coloring: DiskColoring = .folder { didSet { if coloring != oldValue { invalidateMap() } } }
    var selected: DiskNode? { didSet { needsDisplay = true } }
    var picked: [DiskNode] = [] { didSet { needsDisplay = true } }
    /// Fraction done (nil: not known) and the lines under it.
    var scan: (fraction: Double?, big: String, line: String, path: String) = (nil, "", "", "") { didSet { needsDisplay = true } }

    var onSelect: ((DiskNode?) -> Void)?
    var onOpen: ((DiskNode) -> Void)?
    var onUp: (() -> Void)?
    var onMenu: ((DiskNode, NSEvent) -> NSMenu?)?

    private(set) var renderer: DiskMapRenderer?
    private var image: NSImage?
    private var hovered: DiskMapRenderer.Hit = .nothing { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pointer = NSPoint.zero
    private var area: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Disk map. The list beside it holds the same items.")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func invalidateMap() {
        image = nil
        renderer = nil
        hovered = .nothing
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        // While the window is being resized the old bitmap stretches; the map is laid out again at the end.
        if inLiveResize { needsDisplay = true } else { invalidateMap() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        invalidateMap()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = area { removeTrackingArea(area) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        area = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        hovered = renderer?.hit(pointer) ?? .nothing
        if style == .blocks { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hovered = .nothing }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = renderer?.hit(point) else { return }
        window?.makeFirstResponder(self)
        switch hit {
        case .hub: onUp?()
        case .node(let node):
            onSelect?(node)
            if event.clickCount == 2 { onOpen?(node) }
        case .sum, .nothing:
            onSelect?(nil)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard case .node(let node)? = renderer?.hit(convert(event.locationInWindow, from: nil)) else { return nil }
        onSelect?(node)
        return onMenu?(node, event)
    }

    override var acceptsFirstResponder: Bool { true }

    private func ensureMap() {
        guard content == .map, let focus = focus, bounds.width > 10, bounds.height > 10 else { return }
        guard renderer == nil || image == nil else { return }
        let picture = DiskMapRenderer(focus: focus, slices: slices, style: style, coloring: coloring, size: bounds.size)
        renderer = picture
        image = GadgetPreview.canvas(bounds.size) { _ in picture.draw() }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .empty: break
        case .scanning: drawScan()
        case .map:
            ensureMap()
            image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawOverlay()
        }
    }

    private func drawOverlay() {
        guard let context = NSGraphicsContext.current?.cgContext, let renderer = renderer else { return }
        context.saveGState()
        for node in picked {
            guard let shape = renderer.outline(of: node) else { continue }
            context.addPath(shape)
            context.setStrokeColor(Brand.boardSalsa.cgColor)
            context.setLineWidth(1.8)
            context.setLineDash(phase: 0, lengths: [4, 3])
            context.strokePath()
        }
        context.setLineDash(phase: 0, lengths: [])
        if case .node(let node) = hovered, let shape = renderer.outline(of: node) {
            context.addPath(shape)
            context.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            context.fillPath()
            context.addPath(shape)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1.2)
            context.strokePath()
        }
        if let node = selected, let shape = renderer.outline(of: node) {
            context.addPath(shape)
            context.setStrokeColor(Brand.nacho.cgColor)
            context.setLineWidth(2.4)
            context.strokePath()
        }
        context.restoreGState()
        if style == .sunburst { drawHub(renderer) } else { drawBubble() }
    }

    private var shownNode: DiskNode? {
        if case .node(let node) = hovered { return node }
        return nil
    }

    private func drawHub(_ renderer: DiskMapRenderer) {
        guard let focus = focus else { return }
        let node = shownNode ?? focus
        let radius = renderer.hubRadius - 12
        let center = renderer.center
        let number = DiskFormat.size(node.size)
        var font = Brand.sign(min(32, radius * 0.62))
        while Draw.width(number, font) > radius * 1.76, font.pointSize > 12 { font = Brand.sign(font.pointSize - 1) }
        let numberHeight = ceil(font.ascender - font.descender)
        Draw.text(node.name.uppercased(), in: NSRect(x: center.x - radius * 0.92, y: center.y - numberHeight / 2 - 13, width: radius * 1.84, height: 13),
                  font: Brand.mono(9.5), color: Brand.boardMute, align: .center)
        Draw.text(number, in: NSRect(x: center.x - radius, y: center.y - numberHeight / 2 + 1, width: 2 * radius, height: numberHeight),
                  font: font, color: Brand.boardInk, align: .center)
        if focus.parent != nil, shownNode == nil, hovered == .hub {
            Draw.text("BACK", in: NSRect(x: center.x - radius, y: center.y + numberHeight / 2 + 1, width: 2 * radius, height: 12),
                      font: Brand.mono(9), color: Brand.nacho, align: .center)
        }
    }

    /// The hovered block's name and size next to the pointer.
    private func drawBubble() {
        guard let node = shownNode else { return }
        let title = node.name
        let detail = DiskFormat.size(node.size)
        let titleFont = Brand.body(12, weight: .semibold)
        let detailFont = Brand.sign(15)
        let width = min(320, max(Draw.width(title, titleFont), Draw.width(detail, detailFont)) + 20)
        var box = NSRect(x: pointer.x + 14, y: pointer.y + 14, width: width, height: 46)
        if box.maxX > bounds.maxX - 4 { box.origin.x = pointer.x - width - 12 }
        if box.maxY > bounds.maxY - 4 { box.origin.y = pointer.y - 58 }
        let shape = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
        Brand.board.setFill()
        shape.fill()
        Brand.boardLine.setStroke()
        shape.stroke()
        Draw.text(title, in: NSRect(x: box.minX + 10, y: box.minY + 5, width: box.width - 20, height: 17), font: titleFont, color: Brand.boardInk)
        Draw.text(detail, in: NSRect(x: box.minX + 10, y: box.minY + 21, width: box.width - 20, height: 22), font: detailFont, color: Brand.nacho)
    }

    private func drawScan() {
        let center = NSPoint(x: bounds.midX, y: bounds.midY - 34)
        let radius = min(96, min(bounds.width, bounds.height) * 0.24)
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 12
        Brand.board2.setStroke()
        track.stroke()
        if let fraction = scan.fraction {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90 + CGFloat(max(0.005, fraction)) * 360, clockwise: false)
            arc.lineWidth = 12
            arc.lineCapStyle = .round
            Brand.nacho.setStroke()
            arc.stroke()
        }
        Draw.text(scan.big, in: NSRect(x: center.x - radius, y: center.y - 26, width: 2 * radius, height: 52), font: Brand.sign(38),
                  color: Brand.boardInk, align: .center)
        let text = NSRect(x: 24, y: center.y + radius + 22, width: bounds.width - 48, height: 20)
        Draw.text(scan.line, in: text, font: Brand.body(13, weight: .medium), color: Brand.boardInk, align: .center)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        (scan.path as NSString).draw(in: NSRect(x: 24, y: text.maxY + 4, width: bounds.width - 48, height: 16), withAttributes: [
            .font: Brand.mono(10, weight: .medium), .foregroundColor: Brand.boardMute, .paragraphStyle: style])
    }
}

/// How the disk is doing: what is left as the one loud number, then the whole disk as a bar in the map's own colors.
final class DiskCapacityView: NSView {
    struct Part {
        let bytes: Int64
        let color: NSColor
        var hatched = false
    }

    var space: DiskSpace? { didSet { needsDisplay = true; updateAccessibility() } }
    /// What the scan found, largest first, in the map's colors. Empty before a scan.
    var parts: [Part] = [] { didSet { needsDisplay = true } }
    var hiddenBytes: Int64 = 0 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("disk-capacity")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateAccessibility() {
        setAccessibilityLabel(space.map { "\(DiskFormat.size($0.free)) free of \(DiskFormat.size($0.total))" } ?? "Disk space not known")
    }

    private var freeTint: NSColor {
        guard let space = space else { return Brand.boardInk }
        if space.freeFraction < 0.05 { return Brand.boardSalsa }
        return space.freeFraction < 0.15 ? Brand.nacho : Brand.boardGuac
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let space = space, let context = NSGraphicsContext.current?.cgContext else { return }
        let number = DiskFormat.size(space.free).uppercased()
        let font = Brand.sign(36)
        let numberWidth = Draw.width(number, font) + 2
        Draw.text(number, in: NSRect(x: 0, y: 0, width: numberWidth, height: 54), font: font, color: freeTint)
        Draw.text("FREE", in: NSRect(x: numberWidth + 7, y: 9, width: 50, height: 14), font: Brand.mono(11), color: freeTint)
        Draw.text("OF \(DiskFormat.size(space.total))", in: NSRect(x: numberWidth + 7, y: 25, width: 92, height: 14), font: Brand.mono(10, weight: .medium),
                  color: Brand.boardMute)
        let left = numberWidth + 104
        let bar = NSRect(x: left, y: 10, width: max(10, bounds.width - left), height: 16)
        let shape = CGPath(roundedRect: bar, cornerWidth: 5, cornerHeight: 5, transform: nil)
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setFillColor(Brand.board2.cgColor)
        context.fill(bar)
        var x = bar.minX
        func paint(_ bytes: Int64, _ color: NSColor, alpha: CGFloat = 1, gap: Bool = true) {
            let width = bar.width * CGFloat(Double(max(0, bytes)) / Double(max(1, space.total)))
            guard width > 0 else { return }
            context.setFillColor(color.withAlphaComponent(alpha).cgColor)
            context.fill(NSRect(x: x, y: bar.minY, width: max(0, width - (gap && width > 3 ? 1 : 0)), height: bar.height))
            x += width
        }
        if parts.isEmpty {
            paint(space.used - space.purgeable, Brand.boardMute, alpha: 0.7)
        } else {
            for part in parts { paint(part.bytes, part.color) }
            if hiddenBytes > 0 {
                let start = x
                paint(hiddenBytes, DiskPalette.hidden, alpha: 0.28)
                DiskMapRenderer.hatch(CGPath(rect: NSRect(x: start, y: bar.minY, width: x - start, height: bar.height), transform: nil),
                                      color: DiskPalette.hidden, in: context)
            }
        }
        context.restoreGState()
        var notes = ["\(DiskFormat.size(space.used)) USED"]
        if hiddenBytes > 0 { notes.append("\(DiskFormat.size(hiddenBytes)) HIDDEN") }
        if space.purgeable > 0 { notes.append("\(DiskFormat.size(space.purgeable)) MACOS CAN CLEAR") }
        Draw.text(notes.joined(separator: "   ·   "), in: NSRect(x: left, y: 31, width: bar.width, height: 14), font: Brand.mono(10, weight: .medium),
                  color: Brand.boardMute)
    }
}

/// One row of the list beside the map.
final class DiskRowView: NSView {
    struct Row {
        let node: DiskNode
        let color: NSColor
        /// Share of the largest row, for the bar behind the text.
        let share: Double
    }

    var row: Row? { didSet { needsDisplay = true; updateAccessibility() } }
    var isPicked = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private func updateAccessibility() {
        guard let row = row else { return }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(row.node.name), \(DiskFormat.size(row.node.size))")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row = row else { return }
        let node = row.node
        let bar = NSRect(x: 0, y: bounds.height - 3, width: (bounds.width - 8) * CGFloat(row.share), height: 2)
        row.color.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        Draw.dot(row.color, center: NSPoint(x: 8, y: bounds.midY - 1), radius: 4.5)
        let size = DiskFormat.size(node.size)
        let sizeFont = Brand.mono(11, weight: .medium)
        let sizeWidth = Draw.width(size, sizeFont) + 2
        let dim = !node.isItem
        Draw.text(size, in: NSRect(x: bounds.width - sizeWidth - 8, y: 0, width: sizeWidth, height: bounds.height - 2), font: sizeFont,
                  color: dim ? Brand.boardMute : Brand.boardInk, align: .right)
        var name = node.name
        if isPicked { name = "× " + name }
        let nameRect = NSRect(x: 20, y: 0, width: bounds.width - sizeWidth - 36, height: bounds.height - 2)
        Draw.text(name, in: nameRect, font: Brand.body(12.5, weight: node.isFolder ? .medium : .regular),
                  color: dim ? Brand.boardMute : (isPicked ? Brand.boardSalsa : Brand.boardInk))
    }
}

final class DiskRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Brand.boardPick.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

final class DiskTableView: NSTableView {
    var onMenu: ((Int, NSEvent) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return onMenu?(row, event)
    }

    // Return opens the row; the arrow keys and typing stay with the table.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0 {
            sendAction(doubleAction, to: target)
        } else if event.keyCode == 49 || event.modifierFlags.contains(.command) {
            window?.keyDown(with: event)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The items of the shown folder, the same ones the map draws, as a list the keyboard and VoiceOver can use.
final class DiskListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = DiskTableView()
    private let scroll = NSScrollView()
    private var rows: [DiskRowView.Row] = []
    private var picked: [DiskNode] = []
    private var updating = false

    var onSelect: ((DiskNode?) -> Void)?
    var onOpen: ((DiskNode) -> Void)?
    var onMenu: ((DiskNode, NSEvent) -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 27
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Items in this folder, largest first")
        table.setAccessibilityIdentifier("disk-list")
        table.onMenu = { [weak self] row, event in
            guard let self = self, self.rows.indices.contains(row) else { return nil }
            return self.onMenu?(self.rows[row].node, event)
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ rows: [DiskRowView.Row], selected: DiskNode?, picked: [DiskNode]) {
        updating = true
        self.rows = rows
        self.picked = picked
        table.reloadData()
        select(selected)
        updating = false
    }

    func select(_ node: DiskNode?) {
        updating = true
        defer { updating = false }
        if let node = node, let index = rows.firstIndex(where: { $0.node === node }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        } else {
            table.deselectAll(nil)
        }
    }

    func focusList() { window?.makeFirstResponder(table) }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("row"), owner: nil) as? DiskRowView) ?? {
            let created = DiskRowView()
            created.identifier = NSUserInterfaceItemIdentifier("row")
            return created
        }()
        let item = rows[row]
        view.row = item
        view.isPicked = picked.contains { $0 === item.node }
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { DiskRowBackground() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        onSelect?(rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].node : nil)
    }

    @objc private func doubleClicked() {
        guard rows.indices.contains(table.clickedRow >= 0 ? table.clickedRow : table.selectedRow) else { return }
        onOpen?(rows[table.clickedRow >= 0 ? table.clickedRow : table.selectedRow].node)
    }
}
