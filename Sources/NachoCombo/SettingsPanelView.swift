import AppKit
import NachoComboCore

/// NACHO-856: the settings, inside the widget window. A panel that slides in from the right edge shows one gadget's
/// page (Settings / Shortcuts / Permissions) or the app's settings (General / Permissions / Combos / MCP). There is no
/// separate settings window any more; `BentoWindowController` places this view and animates it.
final class SettingsPanelView: NSView {
    /// The panel is this wide (pt); a narrower window shows the panel at the window's width and the page scrolls sideways.
    static let width: CGFloat = 480
    /// The page inside it: the panel minus a classic scroller's width.
    static let pageWidth: CGFloat = 460
    /// The strip with the close button above the page.
    static let stripHeight: CGFloat = 40

    private weak var host: SettingsHost?
    let combos: ComboPage
    private let general: GeneralPage
    private let permissions: PermissionsPage
    private let mcp: MCPPage
    let detail: GadgetDetailView

    private let strip = NSView()
    private let stripTitle = NSTextField(labelWithString: "상세 설정")
    private let closeButton = NSButton()
    private let appTabs = NSSegmentedControl(labels: AppPanelTab.allCases.map { $0.title }, trackingMode: .selectOne,
                                             target: nil, action: nil)
    private let scroll = NSScrollView()
    /// Spans the scroll view's width (at least the page's); the page sits centered in it.
    private let container = FlippedView()
    private var pageView: NSView?
    private var detailShown = false
    private var appTab: AppPanelTab = .general
    private(set) var isGadgetPage = true
    private var ticks = 0

    /// The close button, Esc, or the same tile again.
    var onClose: (() -> Void)?
    /// The panel itself asks for another page (Permissions' "Show Steps", the Combos page's gadget links, the app tabs).
    var onNavigate: ((SettingsPanelRoute) -> Void)?

    init(host: SettingsHost) {
        self.host = host
        combos = ComboPage(host: host)
        general = GeneralPage(host: host)
        permissions = PermissionsPage(host: host)
        mcp = MCPPage(host: host)
        detail = GadgetDetailView(host: host)
        super.init(frame: NSRect(x: 0, y: 0, width: SettingsPanelView.width, height: 600))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("상세 설정 패널")
        setAccessibilityIdentifier("settings-panel")
        build()
        permissions.onOpen = { [weak self] route in self?.onNavigate?(route) }
        combos.onOpen = { [weak self] route in self?.onNavigate?(route) }
        detail.onScrollToTop = { [weak self] in self?.scrollToTop() }
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: building

    private func build() {
        stripTitle.font = BentoDraw.font(13, .bold)
        stripTitle.textColor = Brand.ink
        stripTitle.setAccessibilityElement(false)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "닫기")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = Brand.ink2
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.setAccessibilityLabel("닫기")
        closeButton.setAccessibilityIdentifier("settings-panel-close")
        appTabs.target = self
        appTabs.action = #selector(appTabChanged)
        appTabs.setAccessibilityIdentifier("app-tabs")
        appTabs.setAccessibilityLabel("앱 설정 탭")
        strip.addSubview(stripTitle)
        strip.addSubview(closeButton)
        addSubview(strip)
        addSubview(appTabs)

        scroll.documentView = container
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        container.translatesAutoresizingMaskIntoConstraints = false
        // The container follows the clip's width but never gets narrower than the page: a narrow window scrolls sideways.
        let leading = container.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
        let trailing = container.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor)
        // Leading wins over trailing when the page is wider than the clip: the page starts at the left edge and the
        // rest scrolls (equal priorities let Auto Layout pin the right edge and cut the page's left side).
        leading.priority = .defaultHigh
        trailing.priority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            leading, trailing,
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: GadgetDetailView.width),
        ])
        addSubview(scroll)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        strip.frame = NSRect(x: 0, y: 0, width: w, height: SettingsPanelView.stripHeight)
        closeButton.frame = NSRect(x: w - 14 - 24, y: (SettingsPanelView.stripHeight - 24) / 2, width: 24, height: 24)
        stripTitle.frame = NSRect(x: 18, y: (SettingsPanelView.stripHeight - 18) / 2, width: max(0, w - 18 - 50), height: 18)
        var y = SettingsPanelView.stripHeight
        if !isGadgetPage {
            appTabs.frame = NSRect(x: 18, y: y, width: max(120, w - 36), height: 24)
            y += 24 + 6
        }
        scroll.frame = NSRect(x: 0, y: y, width: w, height: max(0, bounds.height - y))
    }

    override func draw(_ dirtyRect: NSRect) {
        Brand.paper.setFill()
        bounds.fill()
        Brand.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: pages

    /// The route the panel shows now (the tab included).
    var route: SettingsPanelRoute {
        isGadgetPage ? .gadget(detail.module, detail.tab) : .app(appTab)
    }

    /// The shown tab's key (`settings`, `shortcuts`, `permissions`, `general`, `combos`, `mcp`), for the diagnostics.
    var tabKey: String {
        switch route {
        case .gadget(_, let tab): return tab.rawValue
        case .app(let tab): return tab.rawValue
        }
    }

    /// Shows a page. The same gadget again only switches its tab; another gadget replaces the content.
    func show(_ route: SettingsPanelRoute) {
        let previous = pageView
        let view: NSView
        switch route {
        case .gadget(let id, let tab):
            isGadgetPage = true
            stripTitle.stringValue = "상세 설정"
            view = detail
            if !detailShown || detail.module != id {
                detail.show(id, tab: tab)
                detailShown = true
            } else {
                detail.select(tab: tab)
            }
        case .app(let tab):
            isGadgetPage = false
            appTab = tab
            stripTitle.stringValue = "앱 설정"
            appTabs.selectedSegment = AppPanelTab.allCases.firstIndex(of: tab) ?? 0
            switch tab {
            case .general: view = general
            case .permissions: view = permissions
            case .combos: view = combos
            case .mcp: view = mcp
            }
        }
        appTabs.isHidden = isGadgetPage
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
        needsLayout = true
        refresh()
        if view !== previous { scrollToTop() }
    }

    @objc private func closeTapped() { onClose?() }

    @objc private func appTabChanged() {
        guard AppPanelTab.allCases.indices.contains(appTabs.selectedSegment) else { return }
        onNavigate?(.app(AppPanelTab.allCases[appTabs.selectedSegment]))
    }

    private func scrollToTop() {
        container.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Esc while the panel is open closes it (the root view's handler calls this first).
    override func cancelOperation(_ sender: Any?) { onClose?() }

    // MARK: live updates

    /// Called by the widget window's 2 s timer while the panel is open: live numbers, the monitor picture every 4 s.
    func tick() {
        ticks += 1
        refresh()
        if isGadgetPage, detail.module == .systemMonitor, ticks % 2 == 0 { detail.refreshPreview() }
    }

    func refresh() {
        guard host != nil else { return }
        switch route {
        case .gadget: detail.refresh()
        case .app(let tab):
            switch tab {
            case .general: general.refresh()
            case .permissions: permissions.refresh()
            case .combos: combos.refresh()
            case .mcp: mcp.refresh()
            }
        }
    }

    func refreshPreview() { detail.refreshPreview() }

    // MARK: debug

    var accessibilityTree: [[String: String]] { UI.accessibilityTree(of: self) }

    /// Debug aid (`ctl settings snapshot <png>`): the panel as drawn, without needing screen recording permission.
    func writeSnapshot(to url: URL) -> Bool { SettingsPanelView.write(self, to: url) }

    /// Debug aid (`ctl gallery detail <png>`): the whole page, including what is scrolled out of view.
    func writeDetailSnapshot(to url: URL) -> Bool {
        guard let page = pageView else { return false }
        page.layoutSubtreeIfNeeded()
        return SettingsPanelView.write(page, to: url)
    }

    /// Debug aid (`ctl gallery content <png>`): only the shown tab of a gadget's page.
    func writeTabSnapshot(to url: URL) -> Bool {
        detail.layoutSubtreeIfNeeded()
        return SettingsPanelView.write(detail.tabContent, to: url)
    }

    private static func write(_ view: NSView, to url: URL) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        // Labels erase to transparent before drawing; put the paper color behind them as on screen.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { Brand.paper.setFill() }
        NSRect(origin: .zero, size: bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
