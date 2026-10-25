import AppKit
import NachoComboCore

/// Borderless, non-activating panel: it takes key status (so the range menus work) without
/// activating the app, so the frontmost app keeps its menu bar.
final class MonitorPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows one dropdown panel under its status item and closes it on outside clicks, Esc or a Space change.
final class MonitorPanelController: NSObject {
    private var window: MonitorPanelWindow?
    private var scrollView: NSScrollView?
    private(set) var item: MonitorItem?
    private weak var anchor: NSStatusBarButton?
    private var eventMonitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    var onClose: ((MonitorItem) -> Void)?

    var isOpen: Bool { window != nil }
    var isKey: Bool { window?.isKeyWindow ?? false }

    /// "x,y,w,h" of the panel and of its status item in screen coordinates (diagnostics).
    var geometry: (panel: String, anchor: String) {
        func text(_ r: NSRect?) -> String { r.map { String(format: "%.0f,%.0f,%.0f,%.0f", $0.minX, $0.minY, $0.width, $0.height) } ?? "-" }
        var anchorRect: NSRect?
        if let button = anchor, let buttonWindow = button.window {
            anchorRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }
        return (text(window?.frame), text(anchorRect))
    }

    func show(_ root: PanelRootView, item: MonitorItem, anchor: NSStatusBarButton?) {
        close()
        let size = root.relayout()
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
        effect.maskImage = MonitorPanelController.roundedMask(radius: 11)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = root
        effect.addSubview(scroll)
        window.contentView = effect

        self.window = window
        self.scrollView = scroll
        self.item = item
        self.anchor = anchor
        anchor?.highlight(true)
        place(contentSize: size)
        window.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    /// Re-measures the content (rows appeared / disappeared) keeping the top edge in place.
    func relayout(_ root: PanelRootView) {
        guard window != nil else { return }
        place(contentSize: root.relayout())
    }

    func close() {
        guard let window = window else { return }
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors = []
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
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
        let screen = anchor?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var top = visible.maxY - 4
        var x = visible.maxX - contentSize.width - 8
        if let button = anchor, let buttonWindow = button.window {
            let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
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
            if let target = event.window, target !== window, target.styleMask.contains(.titled) { self.close() }
            return event
        }) {
            eventMonitors.append(local)
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.close() }
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
}

private final class SnapshotBackground: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        bounds.fill()
    }
}
