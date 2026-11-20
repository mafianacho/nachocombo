import AppKit
import NachoComboCore

/// The window's root: Esc closes the settings panel or ends edit mode.
final class BentoRootView: BentoWallView {
    var onEscape: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// The top-left logo of the main window: the mascot and the wordmark. The text and sizes live here so the boss can
/// swap them after seeing the real capture (no separate logo file exists in the ledger).
enum BentoLogo {
    static let wordmark = "나초콤보"
    static let wordmarkSize: CGFloat = 17
    static let mascotHeight: CGFloat = 26
    static let gap: CGFloat = 8
    /// Left edge: right of the traffic lights.
    static let originX: CGFloat = 84
    /// The wordmark is dropped (the mascot stays) when fewer points than this are left for it.
    static let minWordmarkWidth: CGFloat = 40
}

/// The main window (b1/b2): every tool as a widget on a wall. "위젯 편집" turns on edit mode (b3): drag to move, "−"
/// to hide, the right panel for size, pin, shortcut. Light and dark follow the system.
final class BentoWindowController: NSObject, NSWindowDelegate {
    private weak var host: BentoHost?
    let window: NSWindow
    let board = BentoBoardView()
    private let scroll = NSScrollView()
    private let root = BentoRootView()
    private let drawer = BentoEditDrawer()
    /// NACHO-856: the right-hand settings panel (nil in tests that build the window without a settings host).
    let settingsPanel: SettingsPanelView?
    private var panelState = SettingsPanelState()
    /// Below this width left for the board the panel covers the board instead of squeezing it.
    static let minBoardWidth: CGFloat = 360
    private let editBar = NSTextField(labelWithString: "위젯 편집 중 · 끌어서 옮기고, 오른쪽에서 크기를 골라요")
    private let titleLabel = NSTextField(labelWithString: BentoLogo.wordmark)
    private let mascotView = NSImageView()
    let updateButton = BentoPill(title: "업데이트")
    private var lastUpdateModel = BentoUpdateButtonModel(visible: false, title: "", enabled: false)
    private let editButton = BentoPill(title: "위젯 편집")
    private let settingsButton = BentoPill(title: "설정")
    private let doneButton = BentoPill(title: "완료", strong: true)
    private var liveTimer: Timer?
    private static let frameName = "NachoComboBento"
    static let defaultSize = NSSize(width: 1210, height: 770)
    static let topBar: CGFloat = 56
    /// The narrowest window: as wide as the settings panel, so every control of the panel shows without sideways scrolling.
    static let minContentWidth: CGFloat = SettingsPanelView.width

    init(host: BentoHost, settingsHost: SettingsHost? = nil) {
        self.host = host
        settingsPanel = settingsHost.map { SettingsPanelView(host: $0) }
        window = NSWindow(contentRect: NSRect(origin: .zero, size: BentoWindowController.defaultSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "나초콤보"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false   // closing the board never stops a tool
        window.isMovableByWindowBackground = false
        window.contentMinSize = NSSize(width: BentoWindowController.minContentWidth, height: 420)
        window.delegate = self
        window.tabbingMode = .disallowed
        window.contentView = root
        build()
        if !window.setFrameUsingName(BentoWindowController.frameName) {
            window.setContentSize(BentoWindowController.defaultSize)
            window.center()
        }
        window.setFrameAutosaveName(BentoWindowController.frameName)
        // A frame saved by an older version may be narrower than the minimum: bring it up to it.
        if window.contentLayoutRect.width < BentoWindowController.minContentWidth {
            window.setContentSize(NSSize(width: BentoWindowController.minContentWidth, height: window.contentLayoutRect.height))
        }
    }

    private func build() {
        root.onEscape = { [weak self] in
            guard let self = self else { return }
            if self.panelState.isOpen { self.closePanel() } else { self.endEditing() }
        }
        board.host = host
        board.onSelectionChange = { [weak self] id in self?.drawer.show(id) }
        board.onOpenHiddenMenu = { [weak self] view in self?.showHiddenMenu(from: view) }
        drawer.host = host
        drawer.onSize = { [weak self] id, size in self?.board.setSize(id, size); self?.fitBoard() }
        drawer.onHide = { [weak self] id in self?.board.hide(id); self?.fitBoard() }
        drawer.onShortcuts = { [weak self] id in self?.openPanel(.gadget(id, .shortcuts)) }
        drawer.isHidden = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.contentView.drawsBackground = false
        scroll.documentView = board
        root.addSubview(scroll)
        root.addSubview(drawer)
        if let panel = settingsPanel {
            panel.isHidden = true
            panel.onClose = { [weak self] in self?.closePanel() }
            panel.onNavigate = { [weak self] route in self?.navigatePanel(route) }
            root.addSubview(panel)
            board.onTileClick = { [weak self] id in self?.tileClick(id) }
        }
        titleLabel.font = BentoDraw.font(BentoLogo.wordmarkSize, .heavy)
        titleLabel.textColor = Brand.Bento.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        mascotView.imageScaling = .scaleProportionallyUpOrDown
        mascotView.setAccessibilityElement(false)   // decoration: the wordmark carries the name
        updateButton.update = true
        updateButton.isHidden = true
        editBar.font = BentoDraw.font(13, .semibold)
        editBar.textColor = Brand.Bento.ink
        editBar.lineBreakMode = .byTruncatingTail
        editBar.isHidden = true
        doneButton.isHidden = true
        for v in [mascotView, titleLabel, editBar, updateButton, editButton, settingsButton, doneButton] as [NSView] { root.addSubview(v) }
        editButton.onPress = { [weak self] in self?.beginEditing() }
        settingsButton.onPress = { [weak self] in self?.settingsPillClick() }
        doneButton.onPress = { [weak self] in self?.endEditing() }
        updateButton.onPress = { [weak self] in
            guard let self = self else { return }
            self.host?.bentoInstallUpdate(from: self.window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: root)
        root.postsFrameChangedNotifications = true
        layoutChrome()
    }

    @objc private func resized() { layoutChrome() }

    private var editing: Bool { board.editing }

    private func layoutChrome(animatePanel: Bool = false) {
        let b = root.bounds
        let top = BentoWindowController.topBar
        let drawerW = Brand.Bento.drawerWidth
        let model = BentoUpdateLogic.button(for: host?.bentoUpdateState ?? .idle, editing: editing)
        lastUpdateModel = model
        mascotView.image = host?.bentoPetImage(signedIn: true)
        let hasMascot = mascotView.image != nil
        let mascotW = hasMascot ? BentoLogo.mascotHeight + BentoLogo.gap : 0
        let pillY: CGFloat = 14
        // Right pills, right to left: 설정, 위젯 편집, then the yellow update pill at the far left of them. Edit mode: 완료 only.
        func placePills(compact: Bool) -> CGFloat {
            updateButton.isHidden = !model.visible
            updateButton.active = model.enabled
            updateButton.title = compact && model.enabled ? "업데이트" : model.title
            var x = b.width - 24
            var pills: [BentoPill] = editing ? [doneButton] : [settingsButton, editButton]
            if model.visible { pills.append(updateButton) }
            for pill in pills {
                let w = pill.intrinsicContentSize.width
                x -= w
                pill.frame = NSRect(x: x, y: pillY, width: w, height: 28)
                x -= 8
            }
            return x
        }
        var x = placePills(compact: false)
        // Narrow window: the update pill gives up the version before the logo gives up anything.
        if model.visible, x - 12 - BentoLogo.originX < mascotW + BentoLogo.minWordmarkWidth { x = placePills(compact: true) }
        // The traffic lights take the top-left corner; the mascot and the wordmark sit after them, centered in the bar.
        let room = x - 12 - BentoLogo.originX
        let showMascot = hasMascot && room >= BentoLogo.mascotHeight
        let textRoom = room - (showMascot ? mascotW : 0)
        let natural = BentoDraw.textWidth(BentoLogo.wordmark, titleLabel.font ?? BentoDraw.font(BentoLogo.wordmarkSize, .heavy))
        let showText = textRoom >= BentoLogo.minWordmarkWidth || (!hasMascot && textRoom >= 20)
        mascotView.frame = NSRect(x: BentoLogo.originX, y: (top - BentoLogo.mascotHeight) / 2, width: BentoLogo.mascotHeight, height: BentoLogo.mascotHeight)
        mascotView.isHidden = editing || !showMascot
        let textX = BentoLogo.originX + (showMascot ? mascotW : 0)
        let lineH = BentoDraw.lineHeight(titleLabel.font ?? BentoDraw.font(BentoLogo.wordmarkSize, .heavy))
        titleLabel.frame = NSRect(x: textX, y: (top - lineH) / 2, width: max(0, min(natural + 4, textRoom)), height: lineH)
        titleLabel.isHidden = editing || !showText
        editBar.frame = NSRect(x: 84, y: 18, width: max(40, x - 84 - 12), height: 20)
        // The panel (normal mode only) takes the right edge; the board keeps the rest while that is at least
        // `minBoardWidth`, else the panel covers the board and closing it brings the board back.
        let panelW = panelState.isOpen ? min(SettingsPanelView.width, b.width) : 0
        let squeezed = panelW > 0 && b.width - panelW >= BentoWindowController.minBoardWidth
        let boardW = editing ? b.width - drawerW - 24 - 12 : (squeezed ? b.width - panelW : b.width)
        scroll.frame = NSRect(x: 0, y: top, width: max(200, boardW), height: max(100, b.height - top))
        drawer.frame = NSRect(x: b.width - drawerW - 24, y: top, width: drawerW, height: max(100, b.height - top - 24))
        placePanel(in: b, top: top, animated: animatePanel)
        fitBoard()
    }

    // MARK: settings panel (NACHO-856)

    /// Slides the panel in from the right edge (about 0.2 s) or out again; Reduce Motion: no animation.
    private func placePanel(in b: NSRect, top: CGFloat, animated: Bool) {
        guard let panel = settingsPanel else { return }
        let w = min(SettingsPanelView.width, b.width)
        let height = max(100, b.height - top)
        let shown = NSRect(x: b.width - w, y: top, width: w, height: height)
        let hidden = NSRect(x: b.width, y: top, width: w, height: height)
        let animate = animated && !UI.reduceMotion
        if panelState.isOpen {
            if panel.isHidden {
                panel.frame = hidden
                panel.isHidden = false
            }
            if animate {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    panel.animator().frame = shown
                })
            } else {
                panel.frame = shown
            }
        } else if !panel.isHidden {
            if animate {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    panel.animator().frame = hidden
                }, completionHandler: { [weak self, weak panel] in
                    if self?.panelState.isOpen == false { panel?.isHidden = true }
                })
            } else {
                panel.frame = hidden
                panel.isHidden = true
            }
        }
    }

    /// Re-reads the state: shows the route in the panel, slides it, and takes the board's width into account.
    private func applyPanel(animated: Bool = true) {
        if let route = panelState.route { settingsPanel?.show(route) }
        layoutChrome(animatePanel: animated)
        // The panel went away: keyboard focus goes back to the board.
        if !panelState.isOpen, !editing, let first = board.firstCard { window.makeFirstResponder(first) }
    }

    var isPanelOpen: Bool { panelState.isOpen }
    /// Where the board and the panel sit in the window (tests: no overlap, nothing outside the window).
    var panelLayout: (board: NSRect, panel: NSRect?) {
        (scroll.frame, settingsPanel.flatMap { $0.isHidden ? nil : $0.frame })
    }
    var panelRoute: SettingsPanelRoute? { settingsPanel.flatMap { panelState.isOpen ? $0.route : nil } }

    /// A tile of the wall was clicked (or Return on it): open its panel, swap the content, or close on the same tile.
    func tileClick(_ id: ModuleID, animated: Bool = true) {
        guard settingsPanel != nil else { host?.bentoOpen(id); return }
        guard panelState.tileClick(id) else { return }   // editing: the drawer owns the click
        applyPanel(animated: animated)
    }

    private func settingsPillClick() {
        guard settingsPanel != nil else { host?.bentoOpenSettings(); return }
        guard panelState.settingsPillClick() else { return }
        applyPanel()
    }

    /// Any other entry point (menu bar "Settings…", a gadget's own request, a deep link): the window comes to the front
    /// and the panel shows the route (nil closes it). Edit mode ends first: the panel and the edit drawer never meet.
    /// `bringToFront: false` / `animated: false` are for tests that draw the window off screen.
    func openPanel(_ route: SettingsPanelRoute?, bringToFront: Bool = true, animated: Bool = true) {
        guard settingsPanel != nil else { if bringToFront { show() }; return }
        if editing { endEditing() }
        if bringToFront { show() }
        guard let route = route else { closePanel(animated: animated); return }
        panelState.open(route)
        applyPanel(animated: animated)
    }

    func closePanel(animated: Bool = true) {
        guard panelState.isOpen else { return }
        panelState.close()
        applyPanel(animated: animated)
    }

    /// The panel's own navigation: its tabs, "Show Steps", a combo's gadget link. No re-slide.
    private func navigatePanel(_ route: SettingsPanelRoute) {
        guard panelState.open(route) else { return }
        applyPanel(animated: false)
    }

    private func fitBoard() {
        let w = scroll.contentSize.width
        board.padding = editing ? 24 : Brand.Bento.padding
        board.topPadding = 4
        // Edit mode keeps six columns next to the panel with narrower cells (b3).
        board.minCell = editing ? 118 : Brand.Bento.minCell
        // Rows fill the window when they fit (the design's 4 rows in 770 pt), else they keep a readable height and scroll.
        let rows = CGFloat(max(1, board.rows(forWidth: w)))
        let room = scroll.contentSize.height - board.topPadding - board.padding - (rows - 1) * Brand.Bento.gap
        board.rowHeight = min(200, max(editing ? 120 : 140, floor(room / rows)))
        let h = max(board.height(forWidth: w), scroll.contentSize.height)
        board.frame = NSRect(x: 0, y: 0, width: w, height: h)
        board.relayout(animated: false)
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let first = board.firstCard { window.makeFirstResponder(first) }
        startTimer()
    }

    func reload() {
        board.reload()
        layoutChrome()
        fitBoard()
        if editing { drawer.show(board.selectedID) }
    }

    /// The tools' state changed: new numbers and switches, same cards.
    func refresh() {
        guard window.isVisible else { return }
        // The updater changed: the yellow pill appears, changes or goes away and the pills are placed again.
        let now = BentoUpdateLogic.button(for: host?.bentoUpdateState ?? .idle, editing: editing)
        if now != lastUpdateModel { layoutChrome() }
        board.refreshData()
        if editing { drawer.show(board.selectedID) }
        if panelState.isOpen { settingsPanel?.refresh() }
    }

    func beginEditing() {
        guard !editing else { return }
        panelState.beginEditing()   // closes the panel: it and the edit drawer never show together
        board.setEditing(true)
        editBar.isHidden = false
        doneButton.isHidden = false
        editButton.isHidden = true
        settingsButton.isHidden = true
        drawer.isHidden = false
        drawer.show(nil)
        layoutChrome()
        window.makeFirstResponder(board.firstCard)
    }

    func endEditing() {
        guard editing else { return }
        panelState.endEditing()
        board.setEditing(false)
        editBar.isHidden = true
        doneButton.isHidden = true
        editButton.isHidden = false
        settingsButton.isHidden = false
        drawer.isHidden = true
        layoutChrome()
    }

    private func showHiddenMenu(from view: NSView) {
        guard let host = host else { return }
        let menu = NSMenu()
        let hidden = host.bentoLayout.hiddenModules
        if hidden.isEmpty {
            let none = NSMenuItem(title: "숨긴 위젯이 없어요", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let head = NSMenuItem(title: "숨긴 위젯 다시 보이기", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for id in hidden {
                // Each hidden widget: bring it back, or open its settings panel without showing it.
                let item = NSMenuItem(title: id.displayName, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: id.displayName)
                let show = NSMenuItem(title: "다시 보이기", action: #selector(unhide(_:)), keyEquivalent: "")
                show.target = self
                show.representedObject = id.rawValue
                sub.addItem(show)
                if settingsPanel != nil {
                    let settings = NSMenuItem(title: "설정 열기", action: #selector(openHiddenSettings(_:)), keyEquivalent: "")
                    settings.target = self
                    settings.representedObject = id.rawValue
                    sub.addItem(settings)
                }
                item.submenu = sub
                menu.addItem(item)
            }
        }
        if !editing {
            menu.addItem(.separator())
            let edit = NSMenuItem(title: "위젯 편집", action: #selector(menuEdit), keyEquivalent: "")
            edit.target = self
            menu.addItem(edit)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func unhide(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw) else { return }
        host?.bentoUpdateLayout { $0.setHidden(id, false) }
        reload()
    }

    @objc private func openHiddenSettings(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw) else { return }
        openPanel(SettingsEntry.hiddenWidgetSettings(id).route)
    }

    @objc private func menuEdit() { beginEditing() }

    // MARK: live numbers

    /// Every 2 s while the board is on screen (monitor, keep awake countdown); nothing while hidden or minimized.
    private func startTimer() {
        liveTimer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.window.isVisible, !self.window.isMiniaturized, self.window.occlusionState.contains(.visible) else { return }
            self.board.refreshData()
            // The panel's live numbers (the old settings window's 2 s timer) run here while it is open.
            if self.panelState.isOpen { self.settingsPanel?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
    }

    func windowWillClose(_ notification: Notification) {
        endEditing()
        liveTimer?.invalidate()
        liveTimer = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) { board.refreshData() }
    }

    var diagnostics: [String: Any] {
        ["shown": window.isVisible, "editing": editing, "columns": board.columns, "cards": board.cardViews.count,
         "selected": board.selectedID?.rawValue ?? "-", "timer": liveTimer?.isValid ?? false,
         "panelOpen": panelState.isOpen, "panelRoute": panelRoute.map { "\($0)" } ?? "-"]
    }

    /// Frames of the top bar's parts (tests: nothing overlaps, even at the minimum width).
    var chromeFrames: (mascot: NSRect?, wordmark: NSRect?, update: NSRect?, edit: NSRect?, settings: NSRect?) {
        (mascotView.isHidden ? nil : mascotView.frame, titleLabel.isHidden ? nil : titleLabel.frame,
         updateButton.isHidden ? nil : updateButton.frame, editButton.isHidden ? nil : editButton.frame,
         settingsButton.isHidden ? nil : settingsButton.frame)
    }

    var accessibilityTree: [[String: String]] { UI.accessibilityTree(of: root) }
}

/// The menu bar mini board (b4): the pinned widgets, small. A click opens the tool's controls (or, on Nacho Pet,
/// signs in / opens the chat); "+ 위젯 고정" pins one more; "전체 도구 열기 ›" opens the main board.
final class BentoMiniView: NSView {
    weak var host: BentoHost?
    var onTool: ((ModuleID) -> Void)?
    var onOpenAll: (() -> Void)?
    var onAfterAction: (() -> Void)?
    private var cards: [BentoCardView] = []
    private let face = NSImageView()
    private let title = NSTextField(labelWithString: "나초콤보")
    private let count = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "고정한 위젯이 없어요. 고정하면 상단바에서 바로 볼 수 있어요.")
    private let pinMore = BentoLinkButton(title: "＋ 위젯 고정")
    private let openAll = BentoLinkButton(title: "전체 도구 열기 ›")
    private var widthC: NSLayoutConstraint?
    private var heightC: NSLayoutConstraint?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        face.imageScaling = .scaleProportionallyUpOrDown
        title.font = BentoDraw.font(13, .bold)
        title.textColor = Brand.Bento.ink
        count.font = BentoDraw.font(12)
        count.textColor = Brand.Bento.ink2
        count.alignment = .right
        empty.font = BentoDraw.font(12)
        empty.textColor = Brand.Bento.ink2
        for v in [face, title, count, empty, pinMore, openAll] as [NSView] { addSubview(v) }
        pinMore.onPress = { [weak self] in self?.showPinMenu() }
        openAll.onPress = { [weak self] in self?.onOpenAll?() }
        widthC = widthAnchor.constraint(equalToConstant: Brand.Bento.miniWidth)
        heightC = heightAnchor.constraint(equalToConstant: 200)
        widthC?.isActive = true
        heightC?.isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("고정한 위젯")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var firstControl: NSView? { cards.first ?? pinMore }

    private var pinnedItems: [BentoItem] {
        guard let host = host else { return [] }
        return host.bentoLayout.items.filter { item in item.module.map { host.bentoWidget($0).pinned } ?? false }
    }

    func update() {
        guard let host = host else { return }
        face.image = host.bentoPetImage(signedIn: true)
        let items = pinnedItems
        let ids = items.compactMap { $0.module }
        if cards.map({ $0.module }) != ids {
            cards.forEach { $0.removeFromSuperview() }
            cards = ids.map { id in
                let c = BentoCardView(module: id, compact: true)
                c.onOpen = { [weak self] id in self?.open(id) }
                addSubview(c)
                return c
            }
        }
        for (i, c) in cards.enumerated() {
            let w = host.bentoWidget(c.module)
            c.size = items[i].size
            c.apply(w, petImage: nil)
        }
        count.stringValue = "고정한 위젯 \(cards.count)개"
        empty.isHidden = !cards.isEmpty
        let views: [NSView] = cards + [pinMore, openAll]
        for (i, v) in views.enumerated() { v.nextKeyView = i + 1 < views.count ? views[i + 1] : nil }
        layoutNow()
    }

    private func open(_ id: ModuleID) {
        if id == .nachoPet, let host = host, host.bentoWidget(id).enabled {
            host.bentoPerform(id)
            onAfterAction?()
        } else {
            onTool?(id)
        }
    }

    private func layoutNow() {
        let pad: CGFloat = 12
        let width = Brand.Bento.miniWidth
        let inner = width - 2 * pad
        face.frame = NSRect(x: pad + 4, y: pad + 2, width: 26, height: 26)
        title.frame = NSRect(x: pad + 38, y: pad + 6, width: 150, height: 18)
        count.frame = NSRect(x: width - pad - 4 - 160, y: pad + 7, width: 160, height: 16)
        var y = pad + 38
        if cards.isEmpty {
            empty.preferredMaxLayoutWidth = inner - 8
            let h = BentoDraw.wrappedHeight(empty.stringValue, width: inner - 8, lines: 3, font: BentoDraw.font(12)) + 4
            empty.frame = NSRect(x: pad + 4, y: y, width: inner - 8, height: h)
            y += h + 8
        } else {
            let gap: CGFloat = 8
            let cellW = (inner - gap) / 2
            let placed = BentoPacker.pack(cards.map { BentoItem(id: $0.module.rawValue, size: $0.size == .wide ? .wide : .small) },
                                          columns: 2)
            for p in placed.placements {
                guard let c = cards.first(where: { $0.module.rawValue == p.id }) else { continue }
                c.frame = NSRect(x: pad + CGFloat(p.column) * (cellW + gap), y: y + CGFloat(p.row) * (Brand.Bento.miniRow + gap),
                                 width: CGFloat(p.columns) * cellW + CGFloat(p.columns - 1) * gap, height: Brand.Bento.miniRow)
            }
            y += CGFloat(placed.rows) * (Brand.Bento.miniRow + gap) - gap
        }
        y += 10
        let pw = pinMore.intrinsicContentSize.width, ow = openAll.intrinsicContentSize.width
        pinMore.frame = NSRect(x: pad + 4, y: y, width: pw, height: 22)
        openAll.frame = NSRect(x: width - pad - 4 - ow, y: y, width: ow, height: 22)
        y += 22 + pad - 2
        heightC?.constant = y
        frame.size = NSSize(width: width, height: y)
    }

    private func showPinMenu() {
        guard let host = host else { return }
        let menu = NSMenu()
        let order = host.bentoLayout.items.compactMap { $0.module }
        let unpinned = order.filter { !host.bentoWidget($0).pinned }
        if unpinned.isEmpty {
            let none = NSMenuItem(title: "모든 위젯을 고정했어요", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let head = NSMenuItem(title: "상단바에 고정 (켜지지 않아요)", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for id in unpinned {
                let item = NSMenuItem(title: id.displayName, action: #selector(pin(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id.rawValue
                menu.addItem(item)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: pinMore.bounds.height + 2), in: pinMore)
    }

    @objc private func pin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ModuleID(rawValue: raw) else { return }
        host?.bentoSetPinned(id, true)
        update()
    }
}

/// A text button of the mini board's footer.
final class BentoLinkButton: NSView {
    let title: String
    var onPress: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: BentoDraw.textWidth(title, BentoDraw.font(12)) + 4, height: 22) }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let f = BentoDraw.font(12)
        BentoDraw.text(title, at: NSPoint(x: 2, y: (bounds.height - BentoDraw.lineHeight(f)) / 2 + 1), width: bounds.width - 4, font: f, color: Brand.Bento.ink2)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPress?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
