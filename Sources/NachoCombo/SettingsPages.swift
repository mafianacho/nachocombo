import AppKit
import NachoComboCore

/// What the settings window can show on its right-hand side.
enum SettingsPage: Equatable {
    case home, combos, general, permissions
    case gadget(ModuleID)

    var key: String {
        switch self {
        case .home: return "home"
        case .combos: return "combos"
        case .general: return "general"
        case .permissions: return "permissions"
        case .gadget(let id): return id.rawValue
        }
    }

    init?(key: String) {
        switch key {
        case "home": self = .home
        case "combos": self = .combos
        case "general": self = .general
        case "permissions": self = .permissions
        default:
            guard let id = ModuleID(rawValue: key) else { return nil }
            self = .gadget(id)
        }
    }

    static var sidebarOrder: [SettingsPage] { [.home, .combos, .general, .permissions] + ModuleID.allCases.map { .gadget($0) } }
}

/// Whether Nacho Combo opens at login (Login Items, macOS 13 and later).
enum LoginItemState: Equatable {
    case unsupported, off, on, needsApproval
}

/// The app-level part of the settings window: General and Permissions.
protocol SettingsHost: GadgetHost {
    var loginItemState: LoginItemState { get }
    /// Returns an error message when macOS refused.
    func setOpenAtLogin(_ on: Bool) -> String?
    func openLoginItemsSettings()
    func revealSettingsFile()
    func resetAllSettings()
    func quitApp()
    /// Things on the Permissions page that need the user (the sidebar count).
    func permissionsAttentionCount() -> Int
    /// Orders a combo: its options, its switches; gadgets whose permission is missing wait for Allow.
    func orderCombo(_ id: String)
    /// Allow… on a combo's waiting gadget: the explanation sheet, then macOS's dialog, staying on the Combos page.
    func allowFromCombo(_ id: ModuleID)
    /// Saves a combo of one's own; false when refused (no gadget, or the most one may have).
    func saveCombo(_ combo: SavedCombo) -> Bool
    func deleteCombo(_ id: String)
    /// The combo just ordered, while its order can still be undone.
    var orderUndoName: String? { get }
    func undoOrder()
}

// MARK: - Sidebar

/// One entry of the sidebar: an icon, a name and, on the right, a status dot (gadgets) or a count (Permissions).
final class SidebarRow: NSView {
    let page: SettingsPage
    var onSelect: ((SettingsPage) -> Void)?
    var onMove: ((SettingsPage, Int) -> Void)?
    var selected = false { didSet { if selected != oldValue { needsDisplay = true; setAccessibilitySelected(selected) } } }
    private let dot = StatusDotView()
    private let count = Chip("", tone: .attention)
    private var hover = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    static let height: CGFloat = 30

    init(page: SettingsPage, title: String, icon: NSImage) {
        self.page = page
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: SidebarRow.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("sidebar-\(page.key)")
        focusRingType = .none
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 20).isActive = true
        image.heightAnchor.constraint(equalToConstant: 20).isActive = true
        image.setAccessibilityElement(false)
        // Plain labels: the gallery's LiveLabel erases its rectangle inside vibrancy, which shows on the sidebar material.
        let name = NSTextField(labelWithString: title)
        name.font = UI.font(.body, weight: .medium)
        name.textColor = Brand.ink
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityElement(false)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.isHidden = true
        count.isHidden = true
        let row = UI.hstack([image, name, UI.spacer(), count, dot], spacing: 7)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(dot kind: StatusDotKind?, count value: Int, value text: String) {
        dot.isHidden = kind == nil || kind == .off
        if let kind = kind { dot.kind = kind }
        count.isHidden = value == 0
        count.title = "\(value)"
        setAccessibilityValue(text)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        if selected {
            Brand.nacho.withAlphaComponent(0.42).setFill()
            shape.fill()
            Brand.nachoInk.withAlphaComponent(0.55).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else if hover {
            Brand.ink.withAlphaComponent(0.05).setFill()
            shape.fill()
        }
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
        onSelect?(page)
    }
    override func keyDown(with event: NSEvent) {
        if focusRingType != .exterior { focusRingType = .exterior; noteFocusRingMaskChanged() }
        switch event.keyCode {
        case 36, 49, 76: onSelect?(page)
        case 125: onMove?(page, 1)
        case 126: onMove?(page, -1)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(page); return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Left column of the settings window: All Gadgets, Combos, General, Permissions, then every gadget with its state.
/// It sits on the design system's paper-2, a tint step from the page.
final class SidebarView: NSView {
    static let width: CGFloat = 220
    private(set) var rows: [SidebarRow] = []
    var onSelect: ((SettingsPage) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        Brand.paper2.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Sidebar")

        var views: [NSView] = []
        func add(_ page: SettingsPage, _ title: String, _ icon: NSImage) {
            let row = SidebarRow(page: page, title: title, icon: icon)
            row.onSelect = { [weak self] page in self?.onSelect?(page) }
            row.onMove = { [weak self] page, step in self?.move(from: page, step: step) }
            rows.append(row)
            views.append(row)
        }
        add(.home, "All Gadgets", SidebarView.symbolIcon("square.grid.2x2.fill", tint: Brand.ink, glyph: Brand.paper))
        add(.combos, "Combos", SidebarView.symbolIcon("takeoutbag.and.cup.and.straw.fill", tint: Brand.nacho,
                                                       glyph: Brand.onNacho))
        add(.general, "General", SidebarView.symbolIcon("gearshape.fill", tint: Brand.ink2, glyph: Brand.paper))
        add(.permissions, "Permissions", SidebarView.symbolIcon("lock.shield.fill", tint: Brand.nachoDeep, glyph: Brand.onNacho))
        let heading = Brand.eyebrow("Gadgets", size: 10.5)
        views.append(heading)
        for id in ModuleID.allCases { add(.gadget(id), id.displayName, GadgetIcon.image(for: id, size: 20)) }

        let stack = UI.vstack(views, spacing: 2)
        stack.setCustomSpacing(16, after: rows[3])
        stack.setCustomSpacing(4, after: heading)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            widthAnchor.constraint(equalToConstant: SidebarView.width),
        ])
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 0).isActive = true }
        heading.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// A small rounded square in one color with an SF Symbol on it, like the system's own settings panes.
    static func symbolIcon(_ name: String, tint: NSColor, glyph: NSColor = .white) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            tint.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
            if let symbol = UI.symbol(name, size: 11, weight: .semibold) ?? UI.symbol("bag.fill", size: 11, weight: .semibold) {
                let white = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [glyph])) ?? symbol
                let s = white.size
                white.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width,
                                      height: s.height))
            }
            return true
        }
    }

    func select(_ page: SettingsPage) {
        for row in rows { row.selected = row.page == page }
    }

    func row(for page: SettingsPage) -> SidebarRow? { rows.first { $0.page == page } }

    private func move(from page: SettingsPage, step: Int) {
        guard let index = rows.firstIndex(where: { $0.page == page }), rows.indices.contains(index + step) else { return }
        let target = rows[index + step]
        window?.makeFirstResponder(target)
        onSelect?(target.page)
    }
}

// MARK: - All Gadgets

/// The box lid: the brand's yellow band (nacho with an on-nacho rule) that opens the gallery.
final class LidView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
        Brand.nacho.setFill()
        shape.fill()
        Brand.onNacho.setStroke()
        shape.lineWidth = 2
        shape.stroke()
    }
}

/// The gallery: the lid with the box's state and its combo, then every gadget as a tile with its switch.
final class HomePage: NSView {
    private weak var host: SettingsHost?
    let grid = GadgetGridView()
    private let runningLabel = NSTextField(labelWithString: "")
    private let waitingChip = Chip("", tone: .lid)
    private let errorChip = Chip("", tone: .lid)
    private let comboChip = Chip("", tone: .lid)
    var onOpen: ((SettingsPage) -> Void)?
    static var width: CGFloat { GadgetGridView.gridSize.width + 2 * 28 }

    init(host: SettingsHost) {
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let gridWidth = GadgetGridView.gridSize.width

        // The lid: icon, the name as a sign, one line, and what the box holds now.
        let logo = NSImageView(image: AppIcon.artwork(height: 64))
        logo.setAccessibilityElement(false)
        let eyebrow = Brand.eyebrow("All Gadgets", color: Brand.onNacho.withAlphaComponent(0.75))
        let name = Brand.signLabel("Nacho Combo", size: 44, color: Brand.onNacho)
        name.setAccessibilityIdentifier("home-sign")
        let line = NSTextField(labelWithString: "One box. Only what you order.")
        line.font = Brand.body(14, weight: .semibold)
        line.textColor = Brand.onNacho
        runningLabel.font = Brand.body(13, weight: .medium)
        runningLabel.textColor = Brand.onNacho
        runningLabel.setAccessibilityIdentifier("settings-summary")
        waitingChip.setAccessibilityIdentifier("settings-summary-waiting")
        waitingChip.onPress = { [weak self] in self?.openWaiting() }
        errorChip.onPress = { [weak self] in self?.openWaiting() }
        comboChip.setAccessibilityIdentifier("home-combo")
        comboChip.onPress = { [weak self] in self?.onOpen?(.combos) }
        let summary = UI.hstack([runningLabel, waitingChip, errorChip, UI.spacer(), comboChip], spacing: 6)
        let titles = UI.vstack([eyebrow, name, line], spacing: 2)
        titles.setCustomSpacing(4, after: name)
        let top = UI.hstack([logo, titles, UI.spacer()], spacing: 14)
        let column = UI.vstack([top, summary], spacing: 12)
        let lid = LidView()
        lid.translatesAutoresizingMaskIntoConstraints = false
        lid.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: lid.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: lid.trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: lid.topAnchor, constant: 16),
            column.bottomAnchor.constraint(equalTo: lid.bottomAnchor, constant: -14),
            lid.widthAnchor.constraint(equalToConstant: gridWidth),
            summary.widthAnchor.constraint(equalToConstant: gridWidth - 36),
        ])

        let intro = UI.wrapLabel("Switch each gadget on or off, or start from a combo. Open one to see it at work, change "
                                 + "its settings and shortcuts, and allow what it needs.", width: gridWidth, style: .callout)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: gridWidth).isActive = true
        grid.heightAnchor.constraint(equalToConstant: GadgetGridView.gridSize.height).isActive = true
        let footnote = UI.wrapLabel("Gadgets that are on keep running when this window is closed. Choices are saved "
                                    + "automatically. Reopen it from the nacho box in the menu bar ▸ Settings…",
                                    width: gridWidth, style: .footnote, color: UI.tertiaryText)
        let stack = UI.vstack([lid, intro, grid, footnote], spacing: 6)
        stack.setCustomSpacing(16, after: lid)
        stack.setCustomSpacing(16, after: intro)
        stack.setCustomSpacing(18, after: grid)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            widthAnchor.constraint(equalToConstant: HomePage.width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func refresh() {
        guard let host = host else { return }
        let manager = host.gadgetManager
        var statuses: [ToolStatusPresentation] = []
        for id in ModuleID.allCases {
            let status = manager.status(of: id)
            statuses.append(status)
            grid.tiles[id]?.configure(enabled: manager.settings.isEnabled(id), status: tileStatus(id, status),
                                      badgeCount: host.gadgetBadgeCount(id), stateText: status.accessibilityText)
        }
        runningLabel.stringValue = ToolStatusPresentation.runningText(of: statuses)
        if let waiting = ToolStatusPresentation.waitingText(of: statuses) {
            waitingChip.title = waiting + " ›"
            waitingChip.isHidden = false
        } else {
            waitingChip.isHidden = true
        }
        if let errors = ToolStatusPresentation.errorText(of: statuses) {
            errorChip.title = errors + " ›"
            errorChip.isHidden = false
        } else {
            errorChip.isHidden = true
        }
        if let combo = ComboCatalog.current(manager.settings) {
            comboChip.title = "Your box: \(combo.name) ›"
        } else {
            comboChip.title = "Start from a combo ›"
        }
    }

    private func tileStatus(_ id: ModuleID, _ status: ToolStatusPresentation) -> TileStatus {
        guard let host = host else { return .text("") }
        let permission = id.info.requiredPermission
        if status.dot == .onNeedsSetup, let permission = permission, status.waitingFor != nil {
            return .action("Allow \(permission.displayName)…")
        }
        if status.dot == .off, let permission = permission, host.gadgetPermissionGranted(permission) != true {
            return .locked(permission.displayName)
        }
        return .text(host.gadgetSubtitle(id))
    }

    /// One gadget waits: open it. More: the Permissions page lists them.
    private func openWaiting() {
        guard let manager = host?.gadgetManager else { return }
        let waiting = ModuleID.allCases.filter { manager.status(of: $0).dot == .onNeedsSetup }
        onOpen?(waiting.count == 1 ? .gadget(waiting[0]) : .permissions)
    }
}

// MARK: - General

final class GeneralPage: NSView {
    private weak var host: SettingsHost?
    private var refreshers: [() -> Void] = []
    private let width = GadgetDetailView.width
    private var inner: CGFloat { GadgetDetailView.inner }
    private var cardInner: CGFloat { GadgetDetailView.cardInner }

    init(host: SettingsHost) {
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = Brand.eyebrow("Settings")
        let title = UI.label("General", style: .title2, weight: .bold)
        let stack = UI.vstack([eyebrow, title], spacing: 6)
        stack.setCustomSpacing(2, after: eyebrow)
        stack.setCustomSpacing(16, after: title)
        stack.addArrangedSubview(UI.sectionTitle("Startup"))
        let startup = GadgetDetailView.card([loginRow(), launchWindowRow(), dotRow()])
        stack.addArrangedSubview(startup)
        stack.setCustomSpacing(18, after: startup)
        stack.addArrangedSubview(UI.sectionTitle("Settings"))
        let data = GadgetDetailView.card([fileRow(), resetRow()])
        stack.addArrangedSubview(data)
        stack.setCustomSpacing(18, after: data)
        stack.addArrangedSubview(aboutRow())
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GadgetDetailView.margin),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            widthAnchor.constraint(equalToConstant: width),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func refresh() { refreshers.forEach { $0() } }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = UI.hstack(views, spacing: 8)
        r.widthAnchor.constraint(equalToConstant: cardInner).isActive = true
        return r
    }

    private func titled(_ title: String, _ note: NSTextField) -> NSView {
        UI.vstack([UI.label(title, style: .callout), note], spacing: 2)
    }

    private func loginRow() -> NSView {
        let toggle = NSSwitch()
        toggle.setAccessibilityLabel("Open at Login")
        toggle.setAccessibilityIdentifier("general-login")
        let note = UI.label("", style: .subheadline, color: UI.secondaryText)
        let problem = UI.wrapLabel("", width: cardInner, style: .subheadline, color: UI.attentionText)
        problem.isHidden = true
        let approve = UI.pushButton("Open Login Items", small: true) { [weak self] in self?.host?.openLoginItemsSettings() }
        approve.isHidden = true
        let target = SwitchTarget { [weak self] on in
            guard let self = self, let host = self.host else { return }
            if let message = host.setOpenAtLogin(on) {
                problem.attributedStringValue = UI.notice(message, tint: DotPalette.orange)
                problem.isHidden = false
            } else {
                problem.isHidden = true
            }
            self.refresh()
        }
        toggle.target = target
        toggle.action = #selector(SwitchTarget.changed(_:))
        objc_setAssociatedObject(toggle, &SwitchTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self, weak toggle, weak note, weak approve] in
            guard let state = self?.host?.loginItemState else { return }
            toggle?.isEnabled = state != .unsupported
            toggle?.state = (state == .on || state == .needsApproval) ? .on : .off
            approve?.isHidden = state != .needsApproval
            switch state {
            case .unsupported: note?.stringValue = "Requires macOS 13 or later."
            case .needsApproval: note?.stringValue = "Waiting for your OK in System Settings ▸ General ▸ Login Items."
            default: note?.stringValue = "Uses Login Items in System Settings."
            }
            note?.textColor = state == .needsApproval ? UI.attentionText : UI.secondaryText
        }
        return UI.vstack([row([titled("Open at Login", note), UI.spacer(), approve, toggle]), problem], spacing: 4)
    }

    private func launchWindowRow() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = UI.controlFont(.callout)
        popup.setAccessibilityLabel("Show this window at launch")
        popup.setAccessibilityIdentifier("general-launch-window")
        for choice in LaunchWindow.allCases {
            let item = ClosureMenuItem(title: choice.displayName) { [weak self] in
                self?.host?.gadgetManager.update { $0.launchWindow = choice }
            }
            popup.menu?.addItem(item)
        }
        refreshers.append { [weak self, weak popup] in
            guard let current = self?.host?.gadgetManager.settings.launchWindow,
                  let index = LaunchWindow.allCases.firstIndex(of: current) else { return }
            popup?.selectItem(at: index)
        }
        let note = UI.label("Opening the app again always shows it.", style: .subheadline, color: UI.secondaryText)
        return row([titled("Show This Window at Launch", note), UI.spacer(), popup])
    }

    private func dotRow() -> NSView {
        let toggle = NSSwitch()
        toggle.setAccessibilityLabel("Dot on the menu bar icon")
        toggle.setAccessibilityIdentifier("general-dot")
        let target = SwitchTarget { [weak self] on in self?.host?.gadgetManager.update { $0.menuBarAttentionDot = on } }
        toggle.target = target
        toggle.action = #selector(SwitchTarget.changed(_:))
        objc_setAssociatedObject(toggle, &SwitchTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self, weak toggle] in
            toggle?.state = (self?.host?.gadgetManager.settings.menuBarAttentionDot ?? true) ? .on : .off
        }
        let note = UI.label("When a gadget needs a permission or has an error.", style: .subheadline, color: UI.secondaryText)
        return row([titled("Dot on the Menu Bar Icon", note), UI.spacer(), toggle])
    }

    private func fileRow() -> NSView {
        let path = (SettingsStore.defaultURL().deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let note = UI.label(path, style: .subheadline, color: UI.secondaryText)
        note.lineBreakMode = .byTruncatingMiddle
        let reveal = UI.pushButton("Show in Finder", small: true) { [weak self] in self?.host?.revealSettingsFile() }
        return row([titled("Settings File", note), UI.spacer(), reveal])
    }

    private func resetRow() -> NSView {
        let note = UI.label("Turns every gadget off and restores the default options and shortcuts.", style: .subheadline,
                            color: UI.secondaryText)
        let reset = UI.pushButton("Reset…", small: true) { [weak self] in self?.confirmReset() }
        reset.setAccessibilityIdentifier("general-reset")
        return row([titled("Reset All Settings", note), UI.spacer(), reset])
    }

    private func aboutRow() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let text = UI.wrapLabel("Nacho Combo \(version) · Not signed with an Apple Developer ID, so macOS asks for "
                                + "permissions again after an update.", width: inner - 170, style: .footnote,
                                color: UI.tertiaryText)
        let quit = UI.pushButton("Quit Nacho Combo") { [weak self] in self?.host?.quitApp() }
        quit.setAccessibilityIdentifier("quit-app")
        quit.setAccessibilityHelp("Cleans up every gadget's monitoring, shortcuts and overlays and quits the app")
        let r = UI.hstack([text, UI.spacer(), quit], spacing: 12)
        r.widthAnchor.constraint(equalToConstant: inner).isActive = true
        return r
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Every gadget turns off, and options, shortcuts, pins and General choices go back to their "
            + "defaults. Permissions you allowed in System Settings stay as they are."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.host?.resetAllSettings() }
        }
        if let window = window { alert.beginSheetModal(for: window, completionHandler: apply) } else { apply(alert.runModal()) }
    }
}

// MARK: - Permissions

/// Everything macOS asks the user to allow for Nacho Combo, and the system settings a gadget depends on, in one place.
final class PermissionsPage: NSView {
    private weak var host: SettingsHost?
    private let content = UI.vstack([], spacing: 6)
    private var lastKey = ""
    var onOpen: ((SettingsPage) -> Void)?

    private struct Line {
        let symbol: String
        let title: String
        let user: String
        let status: String
        let tone: Chip.Tone
        let action: (title: String, primary: Bool, run: () -> Void)?
        let note: String?
        var key: String { "\(title)|\(status)|\(tone)|\(action?.title ?? "")|\(note ?? "")" }
    }

    init(host: SettingsHost) {
        self.host = host
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GadgetDetailView.margin),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            widthAnchor.constraint(equalToConstant: GadgetDetailView.width),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func refresh() {
        guard let host = host else { return }
        let privacy = privacyLines(host)
        let system = systemLines(host)
        let key = (privacy + system).map { $0.key }.joined(separator: "#")
        guard key != lastKey else { return }
        lastKey = key
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        let eyebrow = Brand.eyebrow("Privacy")
        let title = UI.label("Permissions", style: .title2, weight: .bold)
        let intro = UI.wrapLabel("What macOS asks you to allow for Nacho Combo. Nothing is requested until you switch on a "
                                 + "gadget that needs it.", width: GadgetDetailView.inner, style: .callout)
        content.addArrangedSubview(eyebrow)
        content.setCustomSpacing(2, after: eyebrow)
        content.addArrangedSubview(title)
        content.addArrangedSubview(intro)
        content.setCustomSpacing(16, after: intro)
        content.addArrangedSubview(UI.sectionTitle("Privacy & Security"))
        let card = GadgetDetailView.card(privacy.map(row))
        content.addArrangedSubview(card)
        content.setCustomSpacing(18, after: card)
        if !system.isEmpty {
            content.addArrangedSubview(UI.sectionTitle("Other System Settings"))
            content.addArrangedSubview(GadgetDetailView.card(system.map(row)))
        }
    }

    private func privacyLines(_ host: SettingsHost) -> [Line] {
        var lines: [Line] = []
        let manager = host.gadgetManager
        for permission in [GadgetPermission.accessibility, .screenRecording] {
            // Every gadget that uses the permission; the ones that cannot run without it decide what the line asks.
            let users = ModuleID.allCases.filter { id in id.info.permissions.contains { $0.permission == permission } }
            let required = users.filter { $0.info.requiredPermission == permission }
            guard let first = required.first ?? users.first else { continue }
            let names = users.map { id -> String in
                let optional = id.info.permissions.first { $0.permission == permission }?.optional ?? false
                return id.displayName + (optional ? " (optional)" : "")
            }
            var user = names.joined(separator: ", ")
            if users.count == 1 { user += " · " + (first.info.permissions.first { $0.permission == permission }?.purpose ?? "") }
            let monthly = permission == .screenRecording ? " macOS 15 and later ask again about once a month." : ""
            let waiting = required.first { manager.settings.isEnabled($0) }
            if host.gadgetPermissionGranted(permission) == true {
                lines.append(Line(symbol: permission.symbolName, title: permission.paneName(), user: user + "." + monthly,
                                  status: "Allowed", tone: .success,
                                  action: ("Open Settings", false, { host.gadgetOpenPermissionSettings(permission) }),
                                  note: nil))
            } else if let id = waiting {
                let updated = host.gadgetPermissionStage(permission) == .updated
                lines.append(Line(symbol: permission.symbolName, title: permission.paneName(), user: user + "." + monthly,
                                  status: "Not allowed", tone: .attention,
                                  action: (updated ? "Allow Again…" : "Allow…", true,
                                           { [weak self] in self?.onOpen?(.gadget(id)) }),
                                  note: updated ? "Nacho Combo was updated, so macOS needs to allow it again." : nil))
            } else {
                let asked = required.map { $0.displayName }
                let when = asked.count > 1 ? asked.dropLast().joined(separator: ", ") + " or " + asked.last! : (asked.first ?? "")
                lines.append(Line(symbol: permission.symbolName, title: permission.paneName(), user: user + "." + monthly,
                                  status: "Not allowed", tone: .neutral, action: nil,
                                  note: "Asked when you switch on \(when)."))
            }
        }
        let alerts = manager.settings.options.alertNotifications
        let user = "System Monitor · alert notifications (optional)."
        switch host.gadgetPermissionGranted(.notifications) {
        case true?:
            lines.append(Line(symbol: GadgetPermission.notifications.symbolName, title: "Notifications", user: user,
                              status: "Allowed", tone: .success,
                              action: ("Open Settings", false, { host.gadgetOpenPermissionSettings(.notifications) }), note: nil))
        case false?:
            lines.append(Line(symbol: GadgetPermission.notifications.symbolName, title: "Notifications", user: user,
                              status: "Not allowed", tone: alerts ? .attention : .neutral,
                              action: ("Open Settings", alerts, { host.gadgetOpenPermissionSettings(.notifications) }),
                              note: alerts ? "Alerts only show as a badge until you allow it." : nil))
        case nil:
            lines.append(Line(symbol: GadgetPermission.notifications.symbolName, title: "Notifications", user: user,
                              status: "Not asked yet", tone: .neutral,
                              action: alerts ? ("Ask", false, { host.gadgetRequestPermission(.notifications) }) : nil,
                              note: alerts ? nil : "Asked when you turn on alert notifications in System Monitor."))
        }
        let events = manager.settings.isEnabled(.calendarClock) && manager.settings.options.clockNextEvent
        let calendarUser = "Calendar Clock · shows your events and meeting links (optional)."
        switch host.gadgetPermissionGranted(.calendars) {
        case true?:
            lines.append(Line(symbol: GadgetPermission.calendars.symbolName, title: "Calendars", user: calendarUser,
                              status: "Allowed", tone: .success,
                              action: ("Open Settings", false, { host.gadgetOpenPermissionSettings(.calendars) }), note: nil))
        case false?:
            lines.append(Line(symbol: GadgetPermission.calendars.symbolName, title: "Calendars", user: calendarUser,
                              status: "Not allowed", tone: .neutral,
                              action: ("Open Settings", false, { host.gadgetOpenPermissionSettings(.calendars) }),
                              note: events ? "The clock works; events do not show until you allow it." : nil))
        case nil:
            lines.append(Line(symbol: GadgetPermission.calendars.symbolName, title: "Calendars", user: calendarUser,
                              status: "Not asked yet", tone: .neutral,
                              action: events ? ("Ask", false, { host.gadgetRequestPermission(.calendars) }) : nil,
                              note: events ? nil : "Asked when Calendar Clock shows your next event."))
        }
        return lines
    }

    private func systemLines(_ host: SettingsHost) -> [Line] {
        guard GadgetPermission.currentMajor >= 15 else { return [] }
        let options = host.gadgetManager.settings.options
        let snapUses = host.gadgetManager.settings.isEnabled(.windowSnap) && options.snapDragToEdges
        let user = "Desktop & Dock · while it is on, macOS handles edge drags instead of Window Snap."
        if WindowSnapModule.systemEdgeTilingEnabled {
            return [Line(symbol: "rectangle.split.2x1", title: "Drag windows to screen edges to tile", user: user,
                         status: "On", tone: snapUses ? .attention : .neutral,
                         action: ("Open Desktop & Dock", snapUses, { host.gadgetOpenDesktopSettings() }),
                         note: snapUses ? "Turn it off to use Window Snap's drag zones." : nil)]
        }
        return [Line(symbol: "rectangle.split.2x1", title: "Drag windows to screen edges to tile", user: user,
                     status: "Off", tone: .success, action: nil, note: nil)]
    }

    private func row(_ line: Line) -> NSView {
        let width = GadgetDetailView.cardInner
        let symbol = UI.symbolView(line.symbol, size: 15, tint: .controlAccentColor)
        let chip = Chip(line.status, tone: line.tone)
        chip.setAccessibilityIdentifier("permissions-status-\(line.title)")
        var right: [NSView] = [chip]
        var buttonWidth: CGFloat = 0
        if let action = line.action {
            let button = UI.pushButton(action.title, primary: action.primary, small: true, handler: action.run)
            buttonWidth = button.fittingSize.width + 8
            right.append(button)
        }
        let textWidth = width - 29 - chip.intrinsicContentSize.width - buttonWidth - 16
        var text: [NSView] = [UI.label(line.title, style: .callout, weight: .semibold),
                              UI.wrapLabel(line.user, width: textWidth, style: .subheadline)]
        if let note = line.note { text.append(UI.attentionNote(note, width: textWidth, style: .footnote)) }
        if line.tone != .attention, let note = text.last as? NSTextField, line.note != nil {
            note.attributedStringValue = UI.styled(line.note!, font: UI.font(.footnote), color: UI.tertiaryText)
        }
        let r = UI.hstack([symbol, UI.vstack(text, spacing: 2), UI.spacer()] + right, spacing: 8, alignment: .top)
        r.widthAnchor.constraint(equalToConstant: width).isActive = true
        return r
    }
}
