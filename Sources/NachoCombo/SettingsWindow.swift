import AppKit
import NachoComboCore

/// One window for every gadget, laid out like the system's own settings: a sidebar (All Gadgets, General, Permissions,
/// then each gadget with its state) and the chosen page on the right. The window can be resized; its size and the last
/// page come back next time. A switch being on never implies "running": the state always comes from the module.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var host: SettingsHost?
    let window: NSWindow

    private let sidebar = SidebarView()
    private let home: HomePage
    let combos: ComboPage
    private let general: GeneralPage
    private let permissions: PermissionsPage
    let detail: GadgetDetailView
    private let scroll = NSScrollView()
    /// Spans the scroll view's width; the page sits centered in it.
    private let container = FlippedView()
    private var pageView: NSView?
    private var liveTimer: Timer?
    private var ticks = 0
    private(set) var page: SettingsPage = .home

    static let minimumSize = NSSize(width: SidebarView.width + GadgetDetailView.width + 40, height: 560)
    static let defaultSize = NSSize(width: 1000, height: 700)
    private static let pageKey = "settingsPage"
    private static let frameName = "NachoComboSettings"

    var quitApp: (() -> Void)?

    init(host: SettingsHost) {
        self.host = host
        home = HomePage(host: host)
        combos = ComboPage(host: host)
        general = GeneralPage(host: host)
        permissions = PermissionsPage(host: host)
        detail = GadgetDetailView(host: host)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsWindowController.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Nacho Combo"
        window.isReleasedWhenClosed = false   // closing the window never stops a running gadget
        window.delegate = self
        window.contentMinSize = SettingsWindowController.minimumSize
        build()
        sidebar.onSelect = { [weak self] page in self?.select(page) }
        home.onOpen = { [weak self] page in self?.select(page) }
        permissions.onOpen = { [weak self] page in self?.select(page) }
        combos.onOpen = { [weak self] page in self?.select(page) }
        home.grid.onSelect = { [weak self] id in self?.select(.gadget(id)) }
        home.grid.onAction = { [weak self] id in self?.select(.gadget(id)) }
        home.grid.onToggle = { [weak self] id, on in self?.host?.gadgetSetEnabled(id, on) }
        detail.onScrollToTop = { [weak self] in self?.scrollToTop() }
        // The size and place from last time, else the default size in the middle of the screen.
        if !window.setFrameUsingName(SettingsWindowController.frameName) {
            window.setContentSize(SettingsWindowController.defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(SettingsWindowController.frameName)
        let saved = UserDefaults.standard.string(forKey: SettingsWindowController.pageKey).flatMap(SettingsPage.init(key:))
        select(saved ?? .home)
        refresh()
    }

    var isVisible: Bool { window.isVisible }

    /// Debug readout of the accessibility elements of the settings window (`ctl a11y settings`).
    var accessibilityTree: [[String: String]] {
        window.contentView.map { UI.accessibilityTree(of: $0) } ?? []
    }

    func show() {
        refresh()
        if !window.isVisible {
            // Fit small screens (e.g. 1280×800 with menu bar and Dock): the page scrolls when it does not fit.
            if let visible = NSScreen.main?.visibleFrame {
                var frame = window.frame
                frame.size.height = min(frame.height, visible.height - 20)
                frame.size.width = min(frame.width, visible.width - 20)
                if !visible.contains(frame) { frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2) }
                window.setFrame(frame, display: false)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startLiveUpdates()
        detail.refreshPreview()
    }

    func select(_ id: ModuleID, tab: DetailTab? = nil) {
        select(.gadget(id), tab: tab)
    }

    func select(_ newPage: SettingsPage, tab: DetailTab? = nil) {
        let changed = newPage != page || pageView == nil
        page = newPage
        sidebar.select(newPage)
        UserDefaults.standard.set(newPage.key, forKey: SettingsWindowController.pageKey)
        let view: NSView
        switch newPage {
        case .home:
            view = home
            if changed { home.grid.select(nil) }
        case .combos: view = combos
        case .general: view = general
        case .permissions: view = permissions
        case .gadget(let id):
            view = detail
            if changed || detail.module != id { detail.show(id, tab: tab) } else if let tab = tab { detail.select(tab: tab) }
        }
        if view !== pageView {
            pageView?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            pageView = view
        }
        refresh()
        if changed { scrollToTop() }
    }

    private func scrollToTop() {
        container.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: layout

    private func build() {
        let content = NSView()
        window.contentView = content
        scroll.documentView = container
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        // A drawn line: an NSBox separator has an intrinsic height that would pull the whole window down to it.
        let divider = DividerLineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        let background = DetailBackgroundView()
        background.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebar)
        content.addSubview(background)
        content.addSubview(divider)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
    }

    // MARK: state

    func refresh() {
        guard let host = host else { return }
        let manager = host.gadgetManager
        for id in ModuleID.allCases {
            let status = manager.status(of: id)
            sidebar.row(for: .gadget(id))?.configure(dot: status.dot, count: 0, value: status.accessibilityText)
        }
        let count = host.permissionsAttentionCount()
        sidebar.row(for: .permissions)?.configure(dot: nil, count: count,
                                                  value: count == 0 ? "Nothing to do" : "\(count) need attention")
        switch page {
        case .home: home.refresh()
        case .combos: combos.refresh()
        case .general: general.refresh()
        case .permissions: permissions.refresh()
        case .gadget: detail.refresh()
        }
    }

    /// While the window is open: live numbers every 2 s, the monitor picture every 4 s.
    private func startLiveUpdates() {
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.window.isVisible else { return }
            self.ticks += 1
            self.refresh()
            if self.page == .gadget(.systemMonitor) && self.ticks % 2 == 0 { self.detail.refreshPreview() }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// Debug aid (`ctl settings snapshot <png>`); draws the window without needing screen recording permission.
    func writeSnapshot(to url: URL) -> Bool {
        guard let frameView = window.contentView?.superview,
              let rep = SettingsWindowController.retinaRep(frameView.bounds.size) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        // Labels erase to transparent before drawing; put the window color behind them as on screen.
        return SettingsWindowController.writeOverBackground(rep, size: frameView.bounds.size, appearance: window.effectiveAppearance,
                                                            to: url)
    }

    /// A 2x bitmap whatever the display, so documentation screenshots stay sharp.
    private static func retinaRep(_ size: NSSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size
        return rep
    }

    private static func writeOverBackground(_ rep: NSBitmapImageRep, size: NSSize, appearance: NSAppearance, to url: URL) -> Bool {
        guard let out = retinaRep(size) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let rect = NSRect(origin: .zero, size: size)
        appearance.performAsCurrentDrawingAppearance { Brand.paper.setFill() }
        rect.fill()
        // NSImageRep.draw(in:) copies (alpha included); blend instead.
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Debug aid (`ctl gallery detail <png>`): the whole page, including what is scrolled out of view.
    func writeDetailSnapshot(to url: URL) -> Bool {
        guard let page = pageView else { return false }
        page.layoutSubtreeIfNeeded()
        let bounds = page.bounds
        guard let rep = SettingsWindowController.retinaRep(bounds.size) else { return false }
        page.cacheDisplay(in: bounds, to: rep)
        return SettingsWindowController.writeOverBackground(rep, size: bounds.size, appearance: window.effectiveAppearance,
                                                            to: url)
    }

    /// Debug aid (`ctl gallery content <png>`): only the shown tab of a gadget's page.
    func writeTabSnapshot(to url: URL) -> Bool {
        let view = detail.tabContent
        detail.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = SettingsWindowController.retinaRep(bounds.size) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        return SettingsWindowController.writeOverBackground(rep, size: bounds.size, appearance: window.effectiveAppearance,
                                                            to: url)
    }

    func refreshPreview() { detail.refreshPreview() }
}


/// The page side: the design system's paper ground.
final class DetailBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Brand.paper.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One-point vertical line in the separator color.
final class DividerLineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Brand.line.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
