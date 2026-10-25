import AppKit
import NachoComboCore

/// Borderless, non-activating panel: it takes key status (so the range menus work) without
/// activating the app, so the frontmost app keeps its menu bar.
final class MonitorPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows one dropdown panel under its status item and closes it on outside clicks, Esc or a Space change.
/// While the pointer rests on a hover card, a flyout with the card's details opens beside the panel.
final class MonitorPanelController: NSObject {
    private var window: MonitorPanelWindow?
    private var scrollView: NSScrollView?
    private(set) var item: MonitorItem?
    private weak var anchor: NSStatusBarButton?
    private var eventMonitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    var onClose: ((MonitorItem) -> Void)?

    /// Builds the flyout content for a factory and returns its root (the owner keeps it refreshed).
    var makeFlyout: ((FlyoutFactory) -> MonitorRootView?)?
    var onFlyoutClose: (() -> Void)?
    private var flyoutWindow: MonitorPanelWindow?
    private weak var flyoutRoot: MonitorRootView?
    private weak var flyoutCard: StackElement?
    /// Opened by a debug command: stays until another card is hovered.
    private var flyoutPinned = false
    private var hoverTargets: [HoverTarget] = []
    private var pointerTimer: Timer?
    /// Card under the pointer that has no flyout yet, and since when.
    private var candidate: (card: StackElement, since: TimeInterval)?
    /// Since when the pointer is off the flyout, its card and the gap between them.
    private var awaySince: TimeInterval?
    private var menuTracking = false

    var isOpen: Bool { window != nil }
    var isKey: Bool { window?.isKeyWindow ?? false }

    /// "x,y,w,h" of the panel, its status item and the flyout in screen coordinates (diagnostics).
    var geometry: (panel: String, anchor: String, flyout: String) {
        func text(_ r: NSRect?) -> String { r.map { String(format: "%.0f,%.0f,%.0f,%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-" }
        return (text(window?.frame), text(anchor.flatMap(MonitorPanelController.screenRect)), text(flyoutWindow?.frame))
    }

    func show(_ root: MonitorRootView, item: MonitorItem, anchor: NSStatusBarButton?, hoverTargets: [HoverTarget]) {
        close()
        let size = root.relayout()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = root
        let window = MonitorPanelController.makeWindow(size: size, content: scroll)

        self.window = window
        self.scrollView = scroll
        self.item = item
        self.anchor = anchor
        anchor?.highlight(true)
        place(contentSize: size)
        window.makeKeyAndOrderFront(nil)
        installMonitors()
        self.hoverTargets = hoverTargets
        if !hoverTargets.isEmpty {
            // Tracking areas of this never-active panel stop reporting after the pointer visits another
            // window, so the pointer is polled while the panel is open instead.
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.trackPointer() }
            timer.tolerance = 0.02
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
    }

    /// Re-measures the content (rows appeared / disappeared) keeping the top edge in place.
    func relayout(_ root: MonitorRootView) {
        guard window != nil else { return }
        place(contentSize: root.relayout())
        if let card = flyoutCard, card.isHidden || card.window == nil { closeFlyout() } else { placeFlyout() }
    }

    func close() {
        guard let window = window else { return }
        closeFlyout()
        pointerTimer?.invalidate()
        pointerTimer = nil
        hoverTargets = []
        candidate = nil
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors = []
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        menuTracking = false
        window.orderOut(nil)
        self.window = nil
        scrollView = nil
        anchor?.highlight(false)
        anchor = nil
        let closed = item
        item = nil
        if let closed = closed { onClose?(closed) }
    }

    private func place(contentSize: NSSize) {
        guard let window = window else { return }
        // A status item the menu bar had no room for sits off-screen: open top right of the main screen instead.
        let anchorRect = anchor.flatMap(MonitorPanelController.screenRect)
        let anchorScreen = anchorRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
        let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var top = visible.maxY - 4
        var x = visible.maxX - contentSize.width - 8
        if let rect = anchorRect, anchorScreen != nil {
            top = rect.minY - 5
            x = rect.minX
        }
        x = min(max(x, visible.minX + 6), visible.maxX - contentSize.width - 6)
        // Taller than the screen: the panel scrolls.
        let height = min(contentSize.height, top - visible.minY - 6)
        window.setFrame(NSRect(x: x, y: top - height, width: contentSize.width, height: height), display: true)
        scrollView?.frame = NSRect(x: 0, y: 0, width: contentSize.width, height: height)
        window.invalidateShadow()
    }

    private func installMonitors() {
        // Clicks in other apps (no permission needed for mouse events).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                          handler: { [weak self] _ in self?.close() }) {
            eventMonitors.append(global)
        }
        // Esc, and clicks into our own titled windows (settings). Status item clicks are handled by their
        // buttons; menu windows of the range pop-ups must not close the panel.
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown],
                                                        handler: { [weak self] event in
            guard let self = self, let window = self.window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if let target = event.window, target !== window, target !== self.flyoutWindow, target.styleMask.contains(.titled) {
                self.close()
            }
            return event
        }) {
            eventMonitors.append(local)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.close() }
        // A range or title menu opened from the flyout leaves its bounds; keep the flyout until the menu is done.
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuTracking = true
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                self?.menuTracking = false
                self?.awaySince = nil
            },
        ]
    }

    // MARK: Flyout

    /// Resting on a card opens its flyout; moving to another card switches quickly. The flyout closes once
    /// the pointer has been off it, its card and the gap between them for a moment (not while a menu is open).
    private func trackPointer() {
        guard window != nil, !menuTracking else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let target = hoverTargets.first { !$0.card.isHidden && MonitorPanelController.screenRect($0.card)?.contains(mouse) == true }

        if let target = target, target.card !== flyoutCard {
            if let pending = candidate, pending.card === target.card {
                if now - pending.since >= (flyoutWindow == nil ? 0.25 : 0.1) { openFlyout(for: target.card, make: target.make) }
            } else {
                candidate = (target.card, now)
            }
        } else {
            candidate = nil
        }

        guard flyoutWindow != nil, !flyoutPinned else { return }
        if pointerKeepsFlyout(mouse) {
            awaySince = nil
        } else if let since = awaySince {
            if now - since >= 0.3 { closeFlyout() }
        } else {
            awaySince = now
        }
    }

    private func pointerKeepsFlyout(_ mouse: NSPoint) -> Bool {
        guard let flyout = flyoutWindow?.frame, let card = flyoutCard.flatMap(MonitorPanelController.screenRect) else { return false }
        if flyout.contains(mouse) || card.contains(mouse) { return true }
        let left = flyout.maxX <= card.minX
        let gap = NSRect(x: left ? flyout.maxX : card.maxX, y: max(flyout.minY, card.minY),
                         width: max(0, left ? card.minX - flyout.maxX : flyout.minX - card.maxX),
                         height: max(0, min(flyout.maxY, card.maxY) - max(flyout.minY, card.minY)))
        return gap.contains(mouse)
    }

    /// `pinned`: keep it open without the pointer (debug command).
    func openFlyout(for card: StackElement, make: @escaping FlyoutFactory, pinned: Bool = false) {
        closeFlyout()
        guard window != nil, let root = makeFlyout?(make) else { return }
        let window = MonitorPanelController.makeWindow(size: root.relayout(), content: root)
        flyoutWindow = window
        flyoutRoot = root
        flyoutCard = card
        flyoutPinned = pinned
        card.highlighted = true
        placeFlyout()
        window.orderFront(nil)
    }

    func relayoutFlyout() {
        guard flyoutWindow != nil, let root = flyoutRoot else { return }
        root.relayout()
        placeFlyout()
    }

    func closeFlyout() {
        candidate = nil
        awaySince = nil
        guard let flyout = flyoutWindow else { return }
        let wasKey = flyout.isKeyWindow
        flyout.orderOut(nil)
        flyoutWindow = nil
        flyoutRoot = nil
        flyoutPinned = false
        flyoutCard?.highlighted = false
        flyoutCard = nil
        onFlyoutClose?()
        if wasKey { window?.makeKey() }
    }

    /// Left of the panel with the top at the card's top; right of it when the screen has no room.
    private func placeFlyout() {
        guard let flyout = flyoutWindow, let root = flyoutRoot, let panel = window?.frame,
              let card = flyoutCard.flatMap(MonitorPanelController.screenRect) else { return }
        let size = root.frame.size
        let visible = (window?.screen ?? NSScreen.main)?.visibleFrame ?? panel
        let gap = MonitorStyle.flyoutGap
        var x = panel.minX - gap - size.width
        if x < visible.minX + 4 { x = panel.maxX + gap }
        var y = min(card.maxY, panel.maxY) - size.height
        y = min(max(y, visible.minY + 6), visible.maxY - size.height)
        flyout.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        flyout.invalidateShadow()
    }

    // MARK: Helpers

    private static func screenRect(_ view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.visibleRect, to: nil))
    }

    private static func makeWindow(size: NSSize, content: NSView) -> MonitorPanelWindow {
        let window = MonitorPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .popUpMenu
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: 11)
        content.frame = NSRect(origin: .zero, size: size)
        effect.addSubview(content)
        window.contentView = effect
        return window
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Debug aid (`ctl monitor snapshot`): renders a view onto an opaque panel-like background as PNG.
    static func renderPNG(_ view: NSView, size: NSSize, appearance: NSAppearance.Name, to url: URL) -> Bool {
        let container = SnapshotBackground(frame: NSRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = container
        container.addSubview(view)
        view.setFrameOrigin(.zero)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size  // 2x, like a Retina display
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Debug aid (`ctl monitor flyout`): flyout and panel side by side, laid out like on screen.
    static func renderFlyoutPNG(panel: MonitorRootView, flyout: MonitorRootView, card: StackElement,
                                appearance: NSAppearance.Name, to url: URL) -> Bool {
        let gap = MonitorStyle.flyoutGap
        let top = max(0, card.convert(NSPoint.zero, to: panel).y)
        let size = NSSize(width: flyout.frame.width + gap + panel.frame.width,
                          height: max(panel.frame.height, top + flyout.frame.height))
        let canvas = SnapshotCanvas(frame: NSRect(origin: .zero, size: size))
        canvas.addSubview(flyout)
        canvas.addSubview(panel)
        flyout.setFrameOrigin(NSPoint(x: 0, y: top))
        panel.setFrameOrigin(NSPoint(x: flyout.frame.width + gap, y: 0))
        return renderPNG(canvas, size: size, appearance: appearance, to: url)
    }
}

private final class SnapshotBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        bounds.fill()
    }
}

/// Windows as rounded panel-coloured shapes on a darker backdrop.
private final class SnapshotCanvas: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.07, alpha: 1) : NSColor(white: 0.75, alpha: 1)).setFill()
        bounds.fill()
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        for view in subviews { NSBezierPath(roundedRect: view.frame, xRadius: 11, yRadius: 11).fill() }
    }
}
