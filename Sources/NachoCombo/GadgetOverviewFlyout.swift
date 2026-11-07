import AppKit
import NachoComboCore

/// A gadget's state in one word on a pill: every row has one, so "off" shows as clearly as "on". The same width in every
/// state keeps the column straight, and the word means the state never rests on color alone.
final class StatusBadge: NSView {
    var status: ToolStatusPresentation? { didSet { if status != oldValue { needsDisplay = true } } }

    static let size = NSSize(width: 44, height: 18)

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { StatusBadge.size }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let status = status else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        let ink: NSColor
        switch status.dot {
        case .on:
            Brand.guac.setFill()
            shape.fill()
            ink = Brand.paper
        case .off:
            Brand.line.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            ink = UI.secondaryText
        case .onNeedsSetup:
            Brand.nachoDeep.setFill()
            shape.fill()
            ink = Brand.onNacho
        case .onError:
            Brand.salsa.setFill()
            shape.fill()
            ink = Brand.paper
        }
        Draw.text(status.badgeText, in: bounds, font: Brand.mono(9.5), color: ink, align: .center)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The card's outline: a rounded box with a small point toward the sidebar row it belongs to.
private final class FlyoutBubbleView: NSView {
    static let point: CGFloat = 8
    var pointY: CGFloat = 30 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0, dy: 0).divided(atDistance: FlyoutBubbleView.point, from: .minXEdge).remainder
        let shape = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: FlyoutBubbleView.point + 1, y: pointY - 8))
        tip.line(to: NSPoint(x: 1, y: pointY))
        tip.line(to: NSPoint(x: FlyoutBubbleView.point + 1, y: pointY + 8))
        tip.close()
        Brand.line.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        tip.lineWidth = 1
        tip.stroke()
        Brand.paper.setFill()
        shape.fill()
        tip.fill()
        // The fill of the point covers the box's edge where the two meet.
        Brand.paper.setStroke()
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: FlyoutBubbleView.point + 0.5, y: pointY - 7))
        seam.line(to: NSPoint(x: FlyoutBubbleView.point + 0.5, y: pointY + 7))
        seam.lineWidth = 2
        seam.stroke()
    }
}

/// A gadget's Overview in a card beside the sidebar, like a large tooltip: what it is, a picture of it at work and what
/// it can do. It opens after the pointer rests on a row, follows it from row to row at once, and never takes a click or
/// the keyboard (everything in it is also on the gadget's page).
final class GadgetOverviewFlyout {
    private weak var host: GadgetHost?
    private weak var parent: NSWindow?
    private let panel: NSPanel
    private let bubble = FlyoutBubbleView()
    private var timer: Timer?
    private var pictures: [String: (image: NSImage, at: Date)] = [:]
    private(set) var shown: ModuleID?

    /// A pause before the first card, so crossing the sidebar on the way elsewhere opens nothing.
    private static let openDelay: TimeInterval = 0.4
    /// Moving between rows passes through a gap between them: the card waits that long before it goes.
    private static let closeDelay: TimeInterval = 0.15
    private static let contentWidth: CGFloat = 300
    private static let padding: CGFloat = 14
    private static let featuresShown = 4
    /// Pictures of live data are drawn again after this long.
    private static let pictureLifetime: TimeInterval = 10

    init(host: GadgetHost, parent: NSWindow) {
        self.host = host
        self.parent = parent
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.contentView = bubble
    }

    /// The pointer came to a row. `force` skips the wait and the question of whether the app is in front (debug).
    func enter(_ id: ModuleID, row: NSView, force: Bool = false) {
        timer?.invalidate()
        guard force || NSApp.isActive else { return }
        if shown != nil || force {
            show(id, row: row)
            return
        }
        schedule(GadgetOverviewFlyout.openDelay) { [weak self, weak row] in
            if let row = row { self?.show(id, row: row) }
        }
    }

    func leave() {
        timer?.invalidate()
        guard shown != nil else { return }
        schedule(GadgetOverviewFlyout.closeDelay) { [weak self] in self?.hide() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        shown = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        let next = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func show(_ id: ModuleID, row: NSView) {
        guard let parent = parent, let content = content(for: id) else { return }
        for view in bubble.subviews { view.removeFromSuperview() }
        bubble.addSubview(content)
        let padding = GadgetOverviewFlyout.padding
        let fitting = content.fittingSize
        let size = NSSize(width: GadgetOverviewFlyout.contentWidth + 2 * padding + FlyoutBubbleView.point, height: fitting.height + 2 * padding)
        content.frame = NSRect(x: FlyoutBubbleView.point + padding, y: padding, width: GadgetOverviewFlyout.contentWidth, height: fitting.height)

        // Beside the sidebar, its top a little above the row, all of it on the screen.
        let rowRect = parent.convertToScreen(row.convert(row.bounds, to: nil))
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        var top = rowRect.maxY + 14
        top = max(min(top, visible.maxY - 6), visible.minY + 6 + size.height)
        let frame = NSRect(x: parent.frame.minX + SidebarView.width + 2, y: top - size.height, width: size.width, height: size.height)
        bubble.pointY = min(max(top - rowRect.midY, 20), size.height - 20)
        panel.setFrame(frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        shown = id
    }

    private func picture(of id: ModuleID, appearance: NSAppearance) -> NSImage? {
        guard let host = host else { return nil }
        let name = appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        let key = "\(id.rawValue)|\(name.rawValue)"
        if let kept = pictures[key], Date().timeIntervalSince(kept.at) < GadgetOverviewFlyout.pictureLifetime { return kept.image }
        var inputs = host.gadgetPreviewInputs()
        if id == .systemMonitor { inputs.monitor = host.gadgetMonitorPreview(appearance: name) }
        let image = GadgetPreview.picture(for: id, inputs: inputs, appearance: appearance).image
        pictures[key] = (image, Date())
        return image
    }

    private func content(for id: ModuleID) -> NSView? {
        guard let host = host, let parent = parent else { return nil }
        let info = id.info
        let width = GadgetOverviewFlyout.contentWidth
        let status = host.gadgetManager.status(of: id)

        let icon = NSImageView(image: GadgetIcon.image(for: id, size: 40))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let role = GadgetDetailView.role(id)
        let names = UI.vstack([Brand.eyebrow(role.text, size: 9, color: role.color), UI.label(id.displayName, style: .headline, weight: .bold)], spacing: 1)
        let badge = StatusBadge()
        badge.status = status
        let top = UI.hstack([icon, names, UI.spacer(), badge], spacing: 10)
        top.widthAnchor.constraint(equalToConstant: width).isActive = true

        var views: [NSView] = [top, UI.wrapLabel(info.tagline, width: width, style: .subheadline)]
        if let image = picture(of: id, appearance: parent.effectiveAppearance), image.size.width > 0 {
            let view = PreviewImageView()
            view.image = image
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            view.heightAnchor.constraint(equalToConstant: (width * image.size.height / image.size.width).rounded()).isActive = true
            views.append(view)
        }
        for feature in info.features.prefix(GadgetOverviewFlyout.featuresShown) {
            let symbol = UI.symbolView(feature.symbol, size: 12, tint: .controlAccentColor)
            let title = UI.label(feature.title, style: .subheadline, weight: .medium)
            views.append(UI.hstack([symbol, title], spacing: 6))
        }
        let more = info.features.count - GadgetOverviewFlyout.featuresShown
        var footer = more > 0 ? "\(more) more on its page" : ""
        if let line = host.gadgetStatusLine(id) {
            footer = line
        } else if let waiting = status.waitingFor {
            footer = "Waiting for \(waiting)"
        } else if status.dot == .off, let permission = info.requiredPermission {
            footer = "Off · asks for \(permission.displayName) when switched on"
        }
        if !footer.isEmpty {
            let line = UI.wrapLabel(footer, width: width, style: .footnote, color: UI.tertiaryText)
            views.append(line)
        }
        let stack = UI.vstack(views, spacing: 8)
        stack.setCustomSpacing(10, after: views[1])
        if views.count > 2 { stack.setCustomSpacing(10, after: views[2]) }
        for view in views.dropFirst(3) { stack.setCustomSpacing(3, after: view) }
        if let last = views.dropLast().last { stack.setCustomSpacing(10, after: last) }
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.layoutSubtreeIfNeeded()
        return stack
    }

    /// Debug only: the card as it is now, on the window's ground.
    func snapshot() -> NSBitmapImageRep? {
        let view = bubble
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
