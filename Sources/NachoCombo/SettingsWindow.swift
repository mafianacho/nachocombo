import AppKit
import NachoComboCore

/// One window for every gadget: a gallery of tiles on the left (icon, live status, on / off switch) and, on the right,
/// everything about the selected gadget: a picture of it at work, its controls, features, shortcuts, the permissions it
/// needs and its options. A switch being on never implies "running": the state always comes from the module.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var host: GadgetHost?
    let window: NSWindow

    private let grid = GadgetGridView()
    private let detail: GadgetDetailView
    private let detailScroll = NSScrollView()
    private let summaryLabel = UI.label("", style: .callout, color: UI.secondaryText)
    private var liveTimer: Timer?
    private var ticks = 0
    private(set) var selected: ModuleID = .menuBar

    static let galleryWidth: CGFloat = GadgetGridView.gridSize.width + 2 * 24
    static var contentWidth: CGFloat { galleryWidth + 1 + GadgetDetailView.width + 14 }
    static let contentHeight: CGFloat = 680

    var quitApp: (() -> Void)?

    init(host: GadgetHost) {
        self.host = host
        detail = GadgetDetailView(host: host)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindowController.contentWidth,
                                              height: SettingsWindowController.contentHeight),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Nacho Combo"
        window.isReleasedWhenClosed = false   // closing the window never stops a running gadget
        window.delegate = self
        build()
        grid.onSelect = { [weak self] id in self?.select(id) }
        grid.onToggle = { [weak self] id, on in self?.host?.gadgetSetEnabled(id, on) }
        select(.menuBar)
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
            // Fit small screens (e.g. 1280×800 with menu bar and Dock): the detail pane scrolls when it does not fit.
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 44
            window.setContentSize(NSSize(width: SettingsWindowController.contentWidth,
                                         height: min(SettingsWindowController.contentHeight, max(500, available))))
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startLiveUpdates()
        detail.refreshPreview()
    }

    func select(_ id: ModuleID) {
        let changed = id != selected || detail.module != id
        selected = id
        grid.select(id)
        if changed || detailScroll.documentView == nil {
            detail.show(id)
            detail.layoutSubtreeIfNeeded()
            detailScroll.contentView.scroll(to: .zero)
            detailScroll.reflectScrolledClipView(detailScroll.contentView)
        }
    }

    // MARK: layout

    private func build() {
        let content = NSView()
        window.contentView = content

        // Gallery side.
        let logo = NSImageView(image: AppIcon.artwork(height: 30))
        logo.setAccessibilityElement(false)
        let title = UI.label("Gadgets", style: .title2, weight: .bold)
        summaryLabel.setAccessibilityIdentifier("settings-summary")
        let header = UI.hstack([logo, title, UI.spacer(), summaryLabel], spacing: 8)
        header.widthAnchor.constraint(equalToConstant: GadgetGridView.gridSize.width).isActive = true
        let intro = UI.wrapLabel("Switch each gadget on or off. Select one to see it at work, what it can do, its shortcuts and the permissions it needs.",
                                 width: GadgetGridView.gridSize.width, style: .callout)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: GadgetGridView.gridSize.width).isActive = true
        grid.heightAnchor.constraint(equalToConstant: GadgetGridView.gridSize.height).isActive = true

        let quit = NSButton(title: "Quit Nacho Combo", target: self, action: #selector(quitClicked))
        quit.setAccessibilityIdentifier("quit-app")
        quit.setAccessibilityHelp("Cleans up every gadget's monitoring, shortcuts and overlays and quits the app")
        let footnote = UI.wrapLabel("Gadgets that are on keep running when this window is closed. Choices are saved automatically. "
                                    + "Reopen it from the nacho box in the menu bar ▸ Settings….",
                                    width: GadgetGridView.gridSize.width - 170, style: .footnote, color: UI.tertiaryText)
        let footer = UI.hstack([footnote, UI.spacer(), quit], spacing: 12)
        footer.widthAnchor.constraint(equalToConstant: GadgetGridView.gridSize.width).isActive = true

        let gallery = UI.vstack([header, intro, grid], spacing: 6)
        gallery.setCustomSpacing(18, after: intro)

        // Detail side.
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        // A drawn line: an NSBox separator has an intrinsic height that would pull the whole window down to it.
        let divider = DividerLineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        let detailBackground = DetailBackgroundView()
        detailBackground.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(gallery)
        content.addSubview(footer)
        content.addSubview(detailBackground)
        content.addSubview(divider)
        content.addSubview(detailScroll)
        NSLayoutConstraint.activate([
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
            gallery.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            gallery.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: SettingsWindowController.galleryWidth),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detailBackground.topAnchor.constraint(equalTo: content.topAnchor),
            detailBackground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailBackground.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailBackground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detailScroll.topAnchor.constraint(equalTo: content.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            detail.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor),
            detail.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor),
        ])
    }

    // MARK: state

    func refresh() {
        guard let host = host else { return }
        let manager = host.gadgetManager
        var dots: [StatusDotKind] = []
        for id in ModuleID.allCases {
            let status = manager.status(of: id)
            dots.append(status.dot)
            grid.tiles[id]?.configure(enabled: manager.settings.isEnabled(id), subtitle: host.gadgetSubtitle(id),
                                      badgeCount: host.gadgetAttention(id).count, stateText: status.accessibilityText)
        }
        summaryLabel.setLive(ToolStatusPresentation.summary(of: dots))
        detail.refresh()
    }

    /// While the window is open: tile subtitles every 2 s (monitor numbers), the monitor picture every 4 s.
    private func startLiveUpdates() {
        guard liveTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.window.isVisible else { return }
            self.ticks += 1
            self.refresh()
            if self.selected == .systemMonitor && self.ticks % 2 == 0 { self.detail.refreshPreview() }
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
        appearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill() }
        rect.fill()
        // NSImageRep.draw(in:) copies (alpha included); blend instead.
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = out.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Debug aid (`ctl settings detail <png>`): the whole detail pane, including what is scrolled out of view.
    func writeDetailSnapshot(to url: URL) -> Bool {
        detail.layoutSubtreeIfNeeded()
        let bounds = detail.bounds
        guard let rep = SettingsWindowController.retinaRep(bounds.size) else { return false }
        detail.cacheDisplay(in: bounds, to: rep)
        return SettingsWindowController.writeOverBackground(rep, size: bounds.size, appearance: window.effectiveAppearance,
                                                            to: url)
    }

    func refreshPreview() { detail.refreshPreview() }

    @objc private func quitClicked() { quitApp?() }
}

/// The detail side sits one tone apart from the gallery.
final class DetailBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 1, alpha: 0.025) : NSColor(white: 0, alpha: 0.025)).setFill()
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
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
