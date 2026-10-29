import AppKit
import UniformTypeIdentifiers
import NachoComboCore

/// Live controls the detail pane offers (they act right away, they are not settings).
enum GadgetCommand: Equatable {
    case toggleCollapse, showAlwaysHidden
    case openMonitorPanel(MonitorItem)
    case snap(SnapAction)
    case toggleShelf, pasteToShelf, clearShelf
    case captureArea, captureWindow, captureScreen, capturePrevious, lockFloats, hideFloats, closeFloats
    case toggleDimPause, toggleFocusSession
    case saveLayout, restoreLayout
    case toggleRecording, pickColor, liveWindow
    case toggleKeepAwake, keepAwakeFor(Int)
    case showClipboard, clearClipboard
    case toggleMic, nextOutput, selectOutput(String), selectInput(String), setVolume(Double), setBrightness(Int, Int)
    case hideOtherApps
    case toggleMouseReverse
    case showCalendar, joinNextMeeting
}

/// What the gallery needs from the app: live state of every gadget and the actions behind its controls.
protocol GadgetHost: AnyObject {
    var gadgetManager: ModuleManager { get }
    /// One line under the tile: a shortcut, a count or live numbers.
    func gadgetSubtitle(_ id: ModuleID) -> String
    /// What needs the user's attention besides a missing permission (an error, a shortcut clash, an alert), in words.
    func gadgetAttention(_ id: ModuleID) -> [String]
    /// The tile badge: the attention items plus a missing permission.
    func gadgetBadgeCount(_ id: ModuleID) -> Int
    /// Live facts for the Controls section ("Collapsed", "3 items", "2 floats").
    func gadgetStatusLine(_ id: ModuleID) -> String?
    func gadgetPreviewInputs() -> GadgetPreviewInputs
    func gadgetMonitorPreview(appearance: NSAppearance.Name) -> (strip: NSImage?, panel: NSImage?, live: Bool)
    /// nil when macOS has not been asked yet (notifications).
    func gadgetPermissionGranted(_ permission: GadgetPermission) -> Bool?
    /// Which step of allowing the permission the card shows.
    func gadgetPermissionStage(_ permission: GadgetPermission) -> PermissionStage
    /// The gadget just started because its permission was allowed: the card says so for a few seconds.
    func gadgetRecentlyAllowed(_ id: ModuleID) -> Bool
    func gadgetOpenPermissionSettings(_ permission: GadgetPermission)
    func gadgetRequestPermission(_ permission: GadgetPermission)
    /// Removes this app's old entry from the permission's list and asks macOS again.
    func gadgetAskAgain(_ permission: GadgetPermission)
    /// "Not Yet" on the restart step: back to the plain steps.
    func gadgetForgetSettingsVisit(_ permission: GadgetPermission)
    func gadgetRelaunch()
    func gadgetRecheck(_ id: ModuleID)
    func gadgetSetEnabled(_ id: ModuleID, _ on: Bool)
    func gadgetSetPinned(_ id: ModuleID, _ pinned: Bool)
    /// Returns an error message when refused.
    func gadgetSetToolShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> String?
    func gadgetSetActionShortcut(_ actionID: String, _ shortcut: ToolShortcut?, reset: Bool) -> String?
    func gadgetResetActionShortcuts(_ id: ModuleID)
    /// The action's shortcut is set but macOS refused to register it (another app holds it).
    func gadgetActionShortcutUnavailable(_ actionID: String) -> Bool
    func gadgetRecordingChanged(_ recording: Bool)
    func gadgetSetOptions(_ options: GadgetOptions)
    func gadgetSetMonitorSettings(_ value: MonitorSettings)
    func gadgetSetDimIntensity(_ value: Double)
    func gadgetPerform(_ command: GadgetCommand)
    func gadgetDismissHint(_ key: String)
    func gadgetOpenDesktopSettings()
    /// The settings window, for confirmation sheets.
    var gadgetWindow: NSWindow? { get }
    /// Device Control's devices and displays, for its controls (empty while it is off).
    func gadgetDevices() -> DeviceSnapshot
    /// Whether a toggle is on now (awake, muted, recording, in a session) and whether the command can run now.
    func gadgetCommandState(_ command: GadgetCommand) -> (on: Bool, enabled: Bool)
    /// Gives an app (App Switch) a shortcut, or removes it; returns an error message when refused.
    func gadgetSetAppShortcut(_ bundleID: String, _ shortcut: ToolShortcut?) -> String?
}

/// The three parts of a gadget's page. Overview is for getting to know it, Settings for changing it, Shortcuts for keys.
enum DetailTab: Int, CaseIterable {
    case overview, settings, shortcuts

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .settings: return "Settings"
        case .shortcuts: return "Shortcuts"
        }
    }

    var key: String { title.lowercased() }
}

/// Right-hand page of a gadget: header with its switch, what has to be done (a permission, a setup step, notices),
/// then the Overview / Settings / Shortcuts tabs.
final class GadgetDetailView: NSView {
    static let width: CGFloat = 560
    static let margin: CGFloat = 24
    static var inner: CGFloat { width - 2 * margin }
    static let cardPadding: CGFloat = 12
    static var cardInner: CGFloat { inner - 2 * cardPadding }

    private weak var host: GadgetHost?
    private(set) var module: ModuleID = .menuBar
    private(set) var tab: DetailTab = .overview
    private let stack = NSStackView()
    /// The page changed a lot (another gadget, another tab): the window scrolls back to the top.
    var onScrollToTop: (() -> Void)?

    // Header.
    private let stateDot = StatusDotView()
    private let stateLabel = UI.label("", style: .callout, weight: .medium, color: UI.secondaryText)
    private let enableSwitch = NSSwitch()
    // What has to be done; rebuilt only when it changes.
    private let topStack = UI.vstack([], spacing: 8)
    private var lastTopKey = ""
    private let tabControl = NSSegmentedControl(labels: DetailTab.allCases.map { $0.title }, trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let tabStack = UI.vstack([], spacing: 10)
    /// The shown tab's content (debug snapshots of one tab).
    var tabContent: NSView { tabStack }

    // Live parts of the shown tab.
    private let previewView = PreviewImageView()
    private let previewCaption = UI.label("", style: .subheadline, color: UI.secondaryText)
    private let statusLine = UI.label("", style: .callout, color: UI.secondaryText)
    private var shortcutFields: [String: ShortcutField] = [:]
    private var shortcutNotes: [String: NSTextField] = [:]
    private var refreshers: [() -> Void] = []
    private var expandedGroups: Set<String> = []
    private var previewSized = false

    init(host: GadgetHost) {
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: GadgetDetailView.width, height: 400))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: GadgetDetailView.margin, bottom: 28, right: GadgetDetailView.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: GadgetDetailView.width),
        ])
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)
        enableSwitch.setAccessibilityIdentifier("detail-enable")
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.setAccessibilityIdentifier("detail-tabs")
        tabControl.setAccessibilityLabel("Page")
        previewCaption.lineBreakMode = .byWordWrapping
        previewCaption.maximumNumberOfLines = 2
        previewCaption.preferredMaxLayoutWidth = GadgetDetailView.inner
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private var info: GadgetInfo { module.info }
    private var enabled: Bool { host?.gadgetManager.settings.isEnabled(module) ?? false }
    private func running(_ id: ModuleID) -> Bool { host?.gadgetManager.states[id] == .running }

    // MARK: building

    /// Shows a gadget. Without a tab, a gadget that is on opens on Settings, one that is off on Overview.
    func show(_ id: ModuleID, tab requested: DetailTab? = nil) {
        module = id
        tab = requested ?? (enabled ? .settings : .overview)
        expandedGroups = [GadgetActions.groups(of: id).first?.title ?? ""]
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        lastTopKey = ""

        let icon = NSImageView(image: GadgetIcon.image(for: id, size: 56))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        icon.setAccessibilityElement(false)
        let name = UI.label(id.displayName, style: .title2, weight: .bold)
        name.setAccessibilityIdentifier("detail-title")
        let role = GadgetDetailView.role(id)
        let roleLabel = Brand.eyebrow(role.text, size: 10.5, color: role.color)
        let switchWidth = enableSwitch.intrinsicContentSize.width
        // icon, titles, spacer and switch with 14 pt between each: the tagline gets what is left.
        let tagline = UI.wrapLabel(info.tagline, width: GadgetDetailView.inner - 56 - switchWidth - 3 * 14 - 4, style: .callout)
        let state = UI.hstack([stateDot, stateLabel], spacing: 5)
        let titles = UI.vstack([roleLabel, name, tagline, state], spacing: 4)
        titles.setCustomSpacing(2, after: roleLabel)
        titles.setCustomSpacing(8, after: tagline)
        enableSwitch.setAccessibilityLabel("Enable \(id.displayName)")
        let header = UI.hstack([icon, titles, UI.spacer(), enableSwitch], spacing: 14, alignment: .top)
        header.widthAnchor.constraint(equalToConstant: GadgetDetailView.inner).isActive = true
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(14, after: header)

        for view in topStack.arrangedSubviews { topStack.removeArrangedSubview(view); view.removeFromSuperview() }
        stack.addArrangedSubview(topStack)
        stack.setCustomSpacing(14, after: topStack)
        stack.addArrangedSubview(tabControl)
        stack.setCustomSpacing(16, after: tabControl)
        stack.addArrangedSubview(tabStack)
        renderTab()
        onScrollToTop?()
    }

    func select(tab newTab: DetailTab) {
        guard newTab != tab else { return }
        tab = newTab
        renderTab()
        onScrollToTop?()
    }

    /// The gadget's place in the box (the design system's box anatomy), shown above its name.
    static func role(_ id: ModuleID) -> (text: String, color: NSColor) {
        switch id {
        case .menuBar: return ("Lid · keeps the box tidy", Brand.ink2)
        case .windowSnap: return ("Main · every day", Brand.guac)
        case .systemMonitor: return ("Main · always in sight", Brand.guac)
        case .fileShelf: return ("Side · when you drag", Brand.nachoInk)
        case .captureFloat: return ("Side · for reference", Brand.nachoInk)
        case .focusDim: return ("Sauce · set and forget", Brand.salsa)
        case .clipboard: return ("Main · every day", Brand.guac)
        case .appSwitch: return ("Main · every day", Brand.guac)
        case .calendarClock: return ("Main · always in sight", Brand.guac)
        case .keepAwake: return ("Side · for long tasks", Brand.nachoInk)
        case .deviceControl: return ("Side · for calls", Brand.nachoInk)
        case .mouseTune: return ("Sauce · set and forget", Brand.salsa)
        }
    }

    @objc private func tabChanged() {
        guard let newTab = DetailTab(rawValue: tabControl.selectedSegment) else { return }
        select(tab: newTab)
    }

    @objc private func enableToggled() { host?.gadgetSetEnabled(module, enableSwitch.state == .on) }

    private func renderTab() {
        tabControl.selectedSegment = tab.rawValue
        for view in tabStack.arrangedSubviews { tabStack.removeArrangedSubview(view); view.removeFromSuperview() }
        refreshers.removeAll()
        shortcutFields.removeAll()
        shortcutNotes.removeAll()
        switch tab {
        case .overview:
            if !previewSized {
                previewView.translatesAutoresizingMaskIntoConstraints = false
                previewView.widthAnchor.constraint(equalToConstant: GadgetDetailView.inner).isActive = true
                previewSized = true
            }
            previewView.setAccessibilityElement(true)
            previewView.setAccessibilityRole(.image)
            previewView.setAccessibilityLabel("\(module.displayName) preview")
            tabStack.addArrangedSubview(previewView)
            tabStack.setCustomSpacing(6, after: previewView)
            tabStack.addArrangedSubview(previewCaption)
            tabStack.setCustomSpacing(18, after: previewCaption)
            addSection("Controls", rows: controlRows(for: module))
            addSection("Features", rows: info.features.map(featureRow))
            if !info.tips.isEmpty { addSection("Keys and Gestures", rows: info.tips.map(tipRow)) }
            if !info.limits.isEmpty { addSection("Good to Know", rows: info.limits.map(limitRow)) }
        case .settings:
            addSection("Options", rows: optionRows(for: module))
            addSection("Menu Bar Access", rows: menuBarAccessRows())
            addSection(info.permissions.count > 1 ? "Permissions" : "Permission", rows: permissionRows())
        case .shortcuts:
            addShortcutSections()
        }
        refresh()
        if tab == .overview { refreshPreview() }
    }

    private func addSection(_ title: String, rows: [NSView], footer: NSView? = nil, header: NSView? = nil) {
        guard !rows.isEmpty else { return }
        let label = header ?? UI.sectionTitle(title)
        tabStack.addArrangedSubview(label)
        tabStack.setCustomSpacing(6, after: label)
        let card = GadgetDetailView.card(rows)
        tabStack.addArrangedSubview(card)
        if let footer = footer {
            tabStack.setCustomSpacing(6, after: card)
            tabStack.addArrangedSubview(footer)
        }
        tabStack.setCustomSpacing(18, after: footer ?? card)
    }

    /// Rows on a grouped surface with hairlines between them.
    static func card(_ rows: [NSView]) -> NSView {
        var views: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 { views.append(UI.separator(width: cardInner)) }
            views.append(row)
        }
        let column = UI.vstack(views, spacing: 9)
        let surface = CardView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: cardPadding),
            column.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -cardPadding),
            column.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10),
            surface.widthAnchor.constraint(equalToConstant: inner),
        ])
        return surface
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = UI.hstack(views, spacing: 8)
        r.widthAnchor.constraint(equalToConstant: GadgetDetailView.cardInner).isActive = true
        return r
    }

    private func featureRow(_ feature: GadgetFeature) -> NSView {
        let symbol = UI.symbolView(feature.symbol, size: 15, tint: .controlAccentColor)
        let title = UI.label(feature.title, style: .callout, weight: .semibold)
        let detail = UI.wrapLabel(feature.detail, width: GadgetDetailView.cardInner - 29, style: .subheadline)
        let text = UI.vstack([title, detail], spacing: 2)
        return UI.hstack([symbol, text], spacing: 8, alignment: .top)
    }

    private func tipRow(_ tip: GadgetTip) -> NSView {
        var left: [NSView] = []
        if !tip.keys.isEmpty { left.append(KeyCapView(tip.keys, height: 19)) }
        if !tip.gesture.isEmpty { left.append(UI.label(tip.gesture, style: .callout, weight: .medium)) }
        let title = UI.label(tip.title, style: .callout, color: UI.secondaryText)
        title.alignment = .right
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = tip.title
        return row(left + [UI.spacer(), title])
    }

    private func limitRow(_ text: String) -> NSView {
        let bullet = UI.symbolView("info.circle", size: 12, tint: UI.secondaryText)
        let label = UI.wrapLabel(text, width: GadgetDetailView.cardInner - 26, style: .subheadline)
        return UI.hstack([bullet, label], spacing: 8, alignment: .top)
    }

    // MARK: what has to be done

    /// The permission card, the one-time setup card and the notices, rebuilt only when what they say changes.
    private func refreshTop() {
        guard let host = host else { return }
        let manager = host.gadgetManager
        var key = ""
        var permissionStage: PermissionStage?
        let permission = info.requiredPermission
        if let permission = permission, enabled, case .needsPermission = manager.states[module] ?? .off {
            permissionStage = host.gadgetPermissionStage(permission)
            key += "perm:\(permissionStage!.rawValue)|"
        }
        let allowed = permission != nil && host.gadgetRecentlyAllowed(module)
        if allowed { key += "allowed|" }
        let setupHint = module == .menuBar && running(.menuBar) && !manager.settings.hintDismissed("menuBarSetup")
        if setupHint { key += "hint|" }
        let attention = host.gadgetAttention(module)
        key += attention.joined(separator: "|")
        guard key != lastTopKey else { return }
        lastTopKey = key

        for view in topStack.arrangedSubviews { topStack.removeArrangedSubview(view); view.removeFromSuperview() }
        let width = GadgetDetailView.inner
        if let permission = permission, let stage = permissionStage {
            topStack.addArrangedSubview(PermissionCard.make(module: module, permission: permission, stage: stage, host: host,
                                                            width: width))
        } else if let permission = permission, allowed {
            topStack.addArrangedSubview(PermissionCard.allowed(module: module, permission: permission, width: width))
        }
        if setupHint { topStack.addArrangedSubview(menuBarSetupCard(width: width)) }
        for text in attention {
            let label = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
            label.attributedStringValue = UI.notice(text, tint: .systemOrange, style: .callout)
            label.setAccessibilityIdentifier("attention")
            topStack.addArrangedSubview(label)
        }
        topStack.isHidden = topStack.arrangedSubviews.isEmpty
    }

    /// Menu Bar Organizer cannot pick other apps' icons: until the user moved some left of the divider, nothing folds away.
    private func menuBarSetupCard(width: CGFloat) -> NSView {
        let inner = width - 24
        let symbol = UI.symbolView("menubar.rectangle", size: 16, tint: .controlAccentColor)
        let title = UI.label("One more step: choose what to hide", style: .callout, weight: .semibold)
        let text = UI.wrapLabel("Hold ⌘ and drag the icons you rarely need to the left of ┊ in the menu bar. "
                                + "Nacho Combo cannot move other apps' icons for you.", width: inner - 30, style: .subheadline)
        let expand = UI.pushButton("Expand Now", small: true) { [weak self] in
            if self?.host?.gadgetManager.settings.menuBarCollapsed == true { self?.host?.gadgetPerform(.toggleCollapse) }
        }
        let done = UI.pushButton("Got It", primary: true, small: true) { [weak self] in
            self?.host?.gadgetDismissHint("menuBarSetup")
        }
        done.setAccessibilityIdentifier("hint-dismiss")
        let buttons = UI.hstack([UI.spacer(), expand, done], spacing: 8)
        buttons.widthAnchor.constraint(equalToConstant: inner - 30).isActive = true
        let column = UI.vstack([title, text, buttons], spacing: 4)
        column.setCustomSpacing(8, after: text)
        let card = TintedCardView(tone: .accent, content: UI.hstack([symbol, column], spacing: 8, alignment: .top))
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        card.setAccessibilityIdentifier("menubar-setup-card")
        return card
    }

    // MARK: controls

    private func button(_ title: String, symbol: String? = nil, _ command: GadgetCommand,
                        enabled: @escaping () -> Bool = { true }) -> NSButton {
        let b = UI.pushButton(title, symbol: symbol) { [weak self] in self?.host?.gadgetPerform(command) }
        refreshers.append { [weak b] in b?.isEnabled = enabled() }
        return b
    }

    /// A button for a command that is on or off (Keep Awake, mute, record…): its title follows the state.
    private func toggleButton(_ off: String, _ on: String, symbol: String? = nil, _ command: GadgetCommand) -> NSButton {
        let b = UI.pushButton(off, symbol: symbol) { [weak self] in self?.host?.gadgetPerform(command) }
        refreshers.append { [weak self, weak b] in
            guard let self = self, let host = self.host, let b = b else { return }
            let state = host.gadgetCommandState(command)
            b.title = state.on ? on : off
            b.isEnabled = self.running(self.module) && state.enabled
        }
        return b
    }

    private func commandButton(_ title: String, symbol: String? = nil, _ command: GadgetCommand) -> NSButton {
        button(title, symbol: symbol, command) { [weak self] in
            guard let self = self, let host = self.host else { return false }
            return self.running(self.module) && host.gadgetCommandState(command).enabled
        }
    }

    private func controlRows(for id: ModuleID) -> [NSView] {
        var rows: [NSView] = []
        statusLine.stringValue = ""
        let turnOn = UI.pushButton("Turn On", primary: true, small: true) { [weak self] in
            guard let self = self else { return }
            self.host?.gadgetSetEnabled(self.module, true)
        }
        turnOn.setAccessibilityIdentifier("controls-turn-on")
        refreshers.append { [weak self, weak turnOn] in turnOn?.isHidden = self?.enabled ?? true }
        rows.append(row([statusLine, UI.spacer(), turnOn]))
        let on = { [weak self] in self?.running(id) ?? false }
        switch id {
        case .menuBar:
            let collapse = button("Expand / Collapse", symbol: "chevron.left.2", .toggleCollapse, enabled: on)
            let all = button("Show Always-Hidden", symbol: "eye", .showAlwaysHidden) { [weak self] in
                on() && (self?.host?.gadgetManager.settings.options.alwaysHiddenSection ?? false)
            }
            rows.append(row([collapse, all, UI.spacer()]))
        case .systemMonitor:
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.addItem(withTitle: "Open a Panel")
            for item in MonitorItem.allCases {
                let menuItem = ClosureMenuItem(title: item.displayName) { [weak self] in
                    self?.host?.gadgetPerform(.openMonitorPanel(item))
                }
                popup.menu?.addItem(menuItem)
            }
            popup.font = UI.controlFont(.callout)
            refreshers.append { [weak popup] in popup?.isEnabled = on() }
            rows.append(row([popup, UI.spacer()]))
        case .windowSnap:
            let grid = SnapGridView { [weak self] action in self?.host?.gadgetPerform(.snap(action)) }
            refreshers.append { [weak grid] in grid?.isEnabled = on() }
            rows.append(row([grid, UI.spacer()]))
            rows.append(UI.wrapLabel("Applies to the front window of the app you used last.", width: GadgetDetailView.cardInner,
                                     style: .subheadline))
            rows.append(row([commandButton("Save Layout", symbol: "square.and.arrow.down", .saveLayout),
                             commandButton("Restore Layout", symbol: "arrow.uturn.backward", .restoreLayout), UI.spacer()]))
        case .fileShelf:
            rows.append(row([button("Show / Hide Shelf", symbol: "tray", .toggleShelf, enabled: on),
                             button("Add Clipboard", symbol: "doc.on.clipboard", .pasteToShelf, enabled: on),
                             button("Clear", .clearShelf, enabled: on), UI.spacer()]))
        case .captureFloat:
            rows.append(row([button("Area", symbol: "viewfinder", .captureArea, enabled: on),
                             button("Window", symbol: "macwindow", .captureWindow, enabled: on),
                             button("Screen", symbol: "display", .captureScreen, enabled: on),
                             button("Previous", symbol: "arrow.counterclockwise", .capturePrevious, enabled: on), UI.spacer()]))
            rows.append(row([button("Lock / Unlock", symbol: "lock", .lockFloats, enabled: on),
                             button("Hide / Show", symbol: "eye.slash", .hideFloats, enabled: on),
                             button("Close All", symbol: "xmark", .closeFloats, enabled: on), UI.spacer()]))
            rows.append(row([toggleButton("Record", "Stop Recording", symbol: "record.circle", .toggleRecording),
                             button("Pick a Color", symbol: "eyedropper", .pickColor, enabled: on),
                             button("Live Window", symbol: "play.rectangle", .liveWindow, enabled: on), UI.spacer()]))
        case .focusDim:
            let slider = NSSlider(value: host?.gadgetManager.settings.dimIntensity ?? FocusDimLogic.defaultIntensity,
                                  minValue: FocusDimLogic.minimumIntensity, maxValue: FocusDimLogic.maximumIntensity,
                                  target: nil, action: nil)
            slider.isContinuous = true
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            slider.setAccessibilityLabel("Dim strength")
            slider.setAccessibilityIdentifier("dim-intensity")
            let value = UI.label("", style: .callout)
            value.font = UI.digitsFont(.callout)
            let target = SliderTarget { [weak self] v in self?.host?.gadgetSetDimIntensity(v) }
            slider.target = target
            slider.action = #selector(SliderTarget.changed(_:))
            objc_setAssociatedObject(slider, &SliderTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            refreshers.append { [weak self, weak slider, weak value] in
                let v = self?.host?.gadgetManager.settings.dimIntensity ?? FocusDimLogic.defaultIntensity
                if let slider = slider, abs(slider.doubleValue - v) > 0.001 { slider.doubleValue = v }
                value?.stringValue = "\(Int((v * 100).rounded()))%"
                slider?.setAccessibilityValueDescription("\(Int((v * 100).rounded()))%")
            }
            let strength = UI.label("Strength", style: .callout)
            strength.setContentCompressionResistancePriority(.required, for: .horizontal)
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            rows.append(row([strength, slider, value, UI.spacer(),
                             button("Pause", symbol: "pause.circle", .toggleDimPause, enabled: on)]))
            rows.append(row([toggleButton("Start Focus Session", "Stop Focus Session", symbol: "timer", .toggleFocusSession),
                             UI.spacer()]))
        case .keepAwake:
            let duration = NSPopUpButton(frame: .zero, pullsDown: true)
            duration.addItem(withTitle: "Keep Awake For…")
            for minutes in GadgetOptions.keepAwakeChoices {
                duration.menu?.addItem(ClosureMenuItem(title: KeepAwakePolicy.durationName(minutes)) { [weak self] in
                    self?.host?.gadgetPerform(.keepAwakeFor(minutes))
                })
            }
            duration.font = UI.controlFont(.callout)
            refreshers.append { [weak duration] in duration?.isEnabled = on() }
            rows.append(row([toggleButton("Keep Awake", "Let It Sleep", symbol: "cup.and.saucer", .toggleKeepAwake), duration,
                             UI.spacer()]))
        case .clipboard:
            rows.append(row([button("Show History", symbol: "list.bullet.rectangle", .showClipboard, enabled: on),
                             button("Clear History", symbol: "trash", .clearClipboard, enabled: on), UI.spacer()]))
            rows.append(UI.wrapLabel("Pinned items stay when you clear the history or quit.", width: GadgetDetailView.cardInner,
                                     style: .subheadline))
        case .deviceControl:
            rows.append(contentsOf: deviceRows())
        case .appSwitch:
            rows.append(row([button("Hide Other Apps", symbol: "eye.slash", .hideOtherApps, enabled: on), UI.spacer()]))
            let keys = host?.gadgetManager.settings.shortcut(forAction: "appSwitch.next")?.label ?? "the switcher shortcut"
            rows.append(UI.wrapLabel("Hold \(keys.replacingOccurrences(of: "Tab", with: "")) and press Tab to go through your windows; "
                                     + "let go to switch. Give apps their own shortcuts on the Shortcuts tab.",
                                     width: GadgetDetailView.cardInner, style: .subheadline))
        case .mouseTune:
            rows.append(row([toggleButton("Reverse the Wheel", "Natural Wheel", symbol: "arrow.up.arrow.down", .toggleMouseReverse),
                             UI.spacer()]))
            rows.append(UI.wrapLabel("Only wheel mice change; trackpads and Magic Mouse keep the system settings.",
                                     width: GadgetDetailView.cardInner, style: .subheadline))
        case .calendarClock:
            rows.append(row([button("Show Calendar", symbol: "calendar", .showCalendar, enabled: on),
                             commandButton("Join Next Call", symbol: "video", .joinNextMeeting), UI.spacer()]))
        }
        return rows
    }

    /// Output and input devices, the microphone switch and one brightness slider per external display.
    private func deviceRows() -> [NSView] {
        var rows: [NSView] = []
        let devices = host?.gadgetDevices() ?? DeviceSnapshot()
        let output = NSPopUpButton(frame: .zero, pullsDown: false)
        let input = NSPopUpButton(frame: .zero, pullsDown: false)
        for popup in [output, input] {
            popup.font = UI.controlFont(.callout)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        output.setAccessibilityLabel("Sound output")
        input.setAccessibilityLabel("Microphone")
        var shownOutputs: [String] = [], shownInputs: [String] = []
        let volume = NSSlider(value: devices.volume ?? 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        volume.isContinuous = true
        volume.translatesAutoresizingMaskIntoConstraints = false
        volume.widthAnchor.constraint(equalToConstant: 120).isActive = true
        volume.setAccessibilityLabel("Volume")
        let volumeTarget = SliderTarget { [weak self] v in self?.host?.gadgetPerform(.setVolume(v)) }
        volume.target = volumeTarget
        volume.action = #selector(SliderTarget.changed(_:))
        objc_setAssociatedObject(volume, &SliderTarget.key, volumeTarget, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self, weak output, weak input, weak volume] in
            guard let self = self, let host = self.host, let output = output, let input = input else { return }
            let now = host.gadgetDevices()
            func fill(_ popup: NSPopUpButton, _ list: [(uid: String, name: String)], _ shown: inout [String],
                      _ make: @escaping (String) -> GadgetCommand) {
                if shown != list.map({ $0.uid }) {
                    shown = list.map { $0.uid }
                    popup.removeAllItems()
                    for device in list {
                        popup.menu?.addItem(ClosureMenuItem(title: device.name) { [weak self] in
                            self?.host?.gadgetPerform(make(device.uid))
                        })
                    }
                    if list.isEmpty { popup.addItem(withTitle: "None") }
                }
            }
            fill(output, now.outputs, &shownOutputs) { .selectOutput($0) }
            fill(input, now.inputs, &shownInputs) { .selectInput($0) }
            if let index = now.outputs.firstIndex(where: { $0.uid == now.output }) { output.selectItem(at: index) }
            if let index = now.inputs.firstIndex(where: { $0.uid == now.input }) { input.selectItem(at: index) }
            let on = self.running(.deviceControl)
            output.isEnabled = on && !now.outputs.isEmpty
            input.isEnabled = on && !now.inputs.isEmpty
            volume?.isEnabled = on && now.volume != nil
            if let v = now.volume, NSApp.currentEvent?.type != .leftMouseDragged { volume?.doubleValue = v }
        }
        let outputLabel = UI.label("Sound Output", style: .callout)
        rows.append(row([outputLabel, UI.spacer(), output]))
        rows.append(row([UI.label("Volume", style: .callout), UI.spacer(), volume]))
        rows.append(row([UI.label("Microphone", style: .callout), UI.spacer(), input]))
        rows.append(row([toggleButton("Mute Microphone", "Unmute Microphone", symbol: "mic.slash", .toggleMic),
                         commandButton("Next Output", symbol: "hifispeaker", .nextOutput), UI.spacer()]))
        if devices.displays.isEmpty {
            rows.append(UI.wrapLabel(running(.deviceControl)
                                     ? "No external display answers brightness commands. Monitors that accept DDC/CI show here."
                                     : "External display brightness shows here while Device Control is on.",
                                     width: GadgetDetailView.cardInner, style: .subheadline))
        }
        for display in devices.displays {
            let slider = NSSlider(value: Double(display.brightness), minValue: 0, maxValue: 100, target: nil, action: nil)
            slider.isContinuous = false
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
            slider.setAccessibilityLabel("\(display.name) brightness")
            let target = SliderTarget { [weak self] v in self?.host?.gadgetPerform(.setBrightness(display.index, Int(v.rounded()))) }
            slider.target = target
            slider.action = #selector(SliderTarget.changed(_:))
            objc_setAssociatedObject(slider, &SliderTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            refreshers.append { [weak self, weak slider] in
                guard let now = self?.host?.gadgetDevices().displays.first(where: { $0.index == display.index }) else { return }
                if NSApp.currentEvent?.type != .leftMouseDragged { slider?.doubleValue = Double(now.brightness) }
            }
            let name = UI.label(display.name, style: .callout)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(row([UI.symbolView("sun.max", size: 13, tint: UI.secondaryText), name, UI.spacer(), slider]))
        }
        return rows
    }

    // MARK: options

    private var options: GadgetOptions { host?.gadgetManager.settings.options ?? .defaults }

    private func update(_ change: (inout GadgetOptions) -> Void) {
        var value = options
        change(&value)
        host?.gadgetSetOptions(value)
        refreshPreview()
    }

    private func checkbox(_ title: String, get: @escaping (GadgetOptions) -> Bool,
                          set: @escaping (inout GadgetOptions, Bool) -> Void) -> NSView {
        let box = ClosureButton(checkbox: title) { _ in }
        box.font = UI.controlFont(.callout)
        box.onToggle = { [weak self] on in self?.update { set(&$0, on) } }
        refreshers.append { [weak self, weak box] in box?.state = get(self?.options ?? .defaults) ? .on : .off }
        return row([box, UI.spacer()])
    }

    /// A row with a note under it that appears only while `visible` is true: the note says what the user has to change
    /// elsewhere for the option to work, with the button that goes there.
    private func withNote(_ line: NSView, text: @escaping () -> String?, button: NSButton?) -> NSView {
        let width = GadgetDetailView.cardInner - 22
        let holder = UI.vstack([], spacing: 6)
        let noteBox = UI.vstack([], spacing: 6)
        noteBox.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        noteBox.isHidden = true
        var lastText: String?
        refreshers.append { [weak noteBox] in
            guard let noteBox = noteBox else { return }
            let now = text()
            guard now != lastText else { return }
            lastText = now
            for view in noteBox.arrangedSubviews { noteBox.removeArrangedSubview(view); view.removeFromSuperview() }
            if let now = now {
                noteBox.addArrangedSubview(UI.attentionNote(now, width: width))
                if let button = button { noteBox.addArrangedSubview(button) }
            }
            noteBox.isHidden = now == nil
        }
        holder.addArrangedSubview(line)
        holder.addArrangedSubview(noteBox)
        return holder
    }

    private func popup<T: Equatable>(_ title: String, choices: [(String, T)], get: @escaping (GadgetOptions) -> T,
                                     set: @escaping (inout GadgetOptions, T) -> Void) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = UI.controlFont(.callout)
        for (index, choice) in choices.enumerated() {
            let item = ClosureMenuItem(title: choice.0) { [weak self] in self?.update { set(&$0, choices[index].1) } }
            popup.menu?.addItem(item)
        }
        refreshers.append { [weak self, weak popup] in
            let current = get(self?.options ?? .defaults)
            if let index = choices.firstIndex(where: { $0.1 == current }) { popup?.selectItem(at: index) }
        }
        popup.setAccessibilityLabel(title)
        let label = UI.label(title, style: .callout)
        return row([label, UI.spacer(), popup])
    }

    private func optionRows(for id: ModuleID) -> [NSView] {
        var rows: [NSView] = []
        switch id {
        case .menuBar:
            rows.append(popup("Collapse Again After", choices: GadgetOptions.autoCollapseChoices.map {
                ($0 == 0 ? "Never" : "\($0) Seconds", $0)
            }, get: { $0.autoCollapseSeconds }, set: { $0.autoCollapseSeconds = $1 }))
            rows.append(checkbox("Expand when the pointer rests on ‹", get: { $0.expandOnHover },
                                 set: { $0.expandOnHover = $1 }))
            rows.append(checkbox("Always-hidden section (a second divider)", get: { $0.alwaysHiddenSection },
                                 set: { $0.alwaysHiddenSection = $1 }))
        case .systemMonitor:
            let label = UI.label("Menu Bar Items", style: .callout)
            var checks: [NSView] = []
            for item in MonitorItem.allCases {
                let check = ClosureButton(checkbox: item.displayName) { _ in }
                check.font = UI.controlFont(.callout)
                check.setAccessibilityIdentifier("monitor-item-\(item.rawValue)")
                check.onToggle = { [weak self] on in
                    guard let self = self, let host = self.host else { return }
                    var value = host.gadgetManager.settings.monitorSettings
                    value.setShown(item, on)
                    host.gadgetSetMonitorSettings(value)
                    self.refreshPreview()
                }
                refreshers.append { [weak self, weak check] in
                    check?.state = (self?.host?.gadgetManager.settings.monitorSettings.isShown(item) ?? true) ? .on : .off
                }
                checks.append(check)
            }
            let firstLine = UI.hstack(Array(checks.prefix(3)), spacing: 12)
            let secondLine = UI.hstack(Array(checks.dropFirst(3)), spacing: 12)
            rows.append(UI.vstack([label, firstLine, secondLine], spacing: 6))
            let ip = ClosureButton(checkbox: "Look up the public IP when the network panel opens") { _ in }
            ip.font = UI.controlFont(.callout)
            ip.setAccessibilityIdentifier("monitor-public-ip")
            ip.onToggle = { [weak self] on in
                guard let host = self?.host else { return }
                var value = host.gadgetManager.settings.monitorSettings
                value.publicIPLookup = on
                host.gadgetSetMonitorSettings(value)
            }
            refreshers.append { [weak self, weak ip] in
                ip?.state = (self?.host?.gadgetManager.settings.monitorSettings.publicIPLookup ?? false) ? .on : .off
            }
            rows.append(UI.vstack([row([ip, UI.spacer()]),
                                   UI.wrapLabel("Sends one request to cloudflare.com, which sees your IP address.",
                                                width: GadgetDetailView.cardInner, style: .footnote, color: UI.tertiaryText)],
                                  spacing: 2))
            rows.append(popup("CPU Alert", choices: GadgetOptions.cpuAlertChoices.map {
                ($0 == 0 ? "Off" : "Above \($0)% for 30 s", $0)
            }, get: { $0.cpuAlertPercent }, set: { $0.cpuAlertPercent = $1 }))
            let notify = checkbox("Post a notification when an alert starts", get: { $0.alertNotifications },
                                  set: { $0.alertNotifications = $1 })
            let openNotifications = UI.pushButton("Open Notification Settings", small: true) { [weak self] in
                self?.host?.gadgetOpenPermissionSettings(.notifications)
            }
            rows.append(withNote(notify, text: { [weak self] in
                guard let host = self?.host, host.gadgetManager.settings.options.alertNotifications else { return nil }
                switch host.gadgetPermissionGranted(.notifications) {
                case false?: return "Notifications are off for Nacho Combo, so alerts only show as a badge."
                default: return nil
                }
            }, button: openNotifications))
        case .windowSnap:
            rows.append(popup("Gap Between Windows", choices: GadgetOptions.gapChoices.map {
                ($0 == 0 ? "None" : "\($0) pt", $0)
            }, get: { $0.snapGap }, set: { $0.snapGap = $1 }))
            rows.append(popup("Repeating Left / Right", choices: SnapRepeat.allCases.map { ($0.displayName, $0) },
                              get: { $0.snapRepeat }, set: { $0.snapRepeat = $1 }))
            let drag = checkbox("Snap windows dragged to a screen edge or corner", get: { $0.snapDragToEdges },
                                set: { $0.snapDragToEdges = $1 })
            let openDock = UI.pushButton("Open Desktop & Dock", small: true) { [weak self] in
                self?.host?.gadgetOpenDesktopSettings()
            }
            openDock.setAccessibilityIdentifier("open-desktop-settings")
            rows.append(withNote(drag, text: { [weak self] in
                guard let options = self?.host?.gadgetManager.settings.options, options.snapDragToEdges,
                      WindowSnapModule.systemEdgeTilingEnabled else { return nil }
                return "macOS tiling is handling edge drags now. Turn off “Drag windows to screen edges to tile” to use these zones."
            }, button: openDock))
            rows.append(checkbox("Restore the size when a snapped window is dragged away", get: { $0.snapRestoreOnDrag },
                                 set: { $0.snapRestoreOnDrag = $1 }))
            rows.append(checkbox("⌃⌘-drag to move, ⌃⌘-right-drag to resize", get: { $0.windowMotion },
                                 set: { $0.windowMotion = $1 }))
        case .fileShelf:
            rows.append(popup("Show the Shelf", choices: ShelfTrigger.allCases.map { ($0.displayName, $0) },
                              get: { $0.shelfTrigger }, set: { $0.shelfTrigger = $1 }))
        case .captureFloat:
            rows.append(checkbox("Rounded corners and shadow on floats", get: { $0.captureRoundedCorners },
                                 set: { $0.captureRoundedCorners = $1 }))
        case .focusDim:
            rows.append(popup("Keep Bright", choices: DimScope.allCases.map { ($0.displayName, $0) },
                              get: { $0.dimScope }, set: { $0.dimScope = $1 }))
            rows.append(checkbox("Dim the other displays too", get: { $0.dimOtherDisplays },
                                 set: { $0.dimOtherDisplays = $1 }))
            rows.append(popup("Fade", choices: GadgetOptions.fadeChoices.map {
                ($0 == 0 ? "Off" : String(format: "%g s", $0), $0)
            }, get: { $0.dimFadeSeconds }, set: { $0.dimFadeSeconds = $1 }))
            rows.append(popup("Focus Session", choices: GadgetOptions.focusChoices.map { ("\($0) Minutes", $0) },
                              get: { $0.focusMinutes }, set: { $0.focusMinutes = $1 }))
            rows.append(popup("Break After It", choices: GadgetOptions.breakChoices.map { ($0 == 0 ? "None" : "\($0) Minutes", $0) },
                              get: { $0.breakMinutes }, set: { $0.breakMinutes = $1 }))
            rows.append(checkbox("Dim only during a focus session", get: { $0.dimOnlyInSession },
                                 set: { $0.dimOnlyInSession = $1 }))
            rows.append(shortcutPicker("Run a Shortcut When It Starts", get: { $0.sessionStartShortcut },
                                       set: { $0.sessionStartShortcut = $1 }))
            rows.append(shortcutPicker("Run a Shortcut When It Ends", get: { $0.sessionEndShortcut },
                                       set: { $0.sessionEndShortcut = $1 }))
        case .keepAwake:
            rows.append(popup("A Click Keeps It Awake", choices: GadgetOptions.keepAwakeChoices.map {
                (KeepAwakePolicy.durationName($0), $0)
            }, get: { $0.keepAwakeMinutes }, set: { $0.keepAwakeMinutes = $1 }))
            rows.append(checkbox("Keep the display on too", get: { $0.keepAwakeDisplay }, set: { $0.keepAwakeDisplay = $1 }))
            rows.append(checkbox("Only while on the power adapter", get: { $0.keepAwakePowerOnly },
                                 set: { $0.keepAwakePowerOnly = $1 }))
            rows.append(popup("Battery Guard", choices: GadgetOptions.batteryFloorChoices.map {
                ($0 == 0 ? "Off" : "Sleep Below \($0)%", $0)
            }, get: { $0.keepAwakeBatteryFloor }, set: { $0.keepAwakeBatteryFloor = $1 }))
            rows.append(appList("Stay Awake While These Apps Run", ids: options.keepAwakeApps) { list, options in
                options.keepAwakeApps = list
            })
        case .clipboard:
            rows.append(popup("Remember", choices: GadgetOptions.clipboardLimitChoices.map { ("\($0) Items", $0) },
                              get: { $0.clipboardLimit }, set: { $0.clipboardLimit = $1 }))
            rows.append(checkbox("Keep images too", get: { $0.clipboardImages }, set: { $0.clipboardImages = $1 }))
            let paste = checkbox("Paste into the app you were in", get: { $0.clipboardPasteDirectly },
                                 set: { $0.clipboardPasteDirectly = $1 })
            let allow = UI.pushButton("Allow Accessibility…", small: true) { [weak self] in
                self?.host?.gadgetRequestPermission(.accessibility)
            }
            rows.append(withNote(paste, text: { [weak self] in
                guard let host = self?.host, host.gadgetManager.settings.options.clipboardPasteDirectly,
                      host.gadgetPermissionGranted(.accessibility) != true else { return nil }
                return "Without Accessibility the item is only copied, and you press ⌘V yourself."
            }, button: allow))
        case .deviceControl:
            let devices = host?.gadgetDevices() ?? DeviceSnapshot()
            func choices(_ list: [(uid: String, name: String)], current: String) -> [(String, String)] {
                var result = [("None", "")] + list.map { ($0.name, $0.uid) }
                if !current.isEmpty, !list.contains(where: { $0.uid == current }) { result.append(("Saved Device (not connected)", current)) }
                return result
            }
            rows.append(popup("When It Connects, Use This Output", choices: choices(devices.outputs, current: options.preferredOutput),
                              get: { $0.preferredOutput }, set: { $0.preferredOutput = $1 }))
            rows.append(popup("When It Connects, Use This Microphone", choices: choices(devices.inputs, current: options.preferredInput),
                              get: { $0.preferredInput }, set: { $0.preferredInput = $1 }))
            rows.append(checkbox("A red microphone in the menu bar while muted", get: { $0.micIndicator },
                                 set: { $0.micIndicator = $1 }))
        case .appSwitch:
            rows.append(checkbox("Pressing an app's shortcut while it is in front hides it", get: { $0.appHideOnRepeat },
                                 set: { $0.appHideOnRepeat = $1 }))
        case .mouseTune:
            rows.append(checkbox("Reverse the wheel (the trackpad stays as it is)", get: { $0.mouseReverse },
                                 set: { $0.mouseReverse = $1 }))
            rows.append(checkbox("Smooth scrolling", get: { $0.mouseSmooth }, set: { $0.mouseSmooth = $1 }))
            rows.append(popup("Scroll Speed", choices: GadgetOptions.mouseSpeedChoices.map { (String(format: "%g×", $0), $0) },
                              get: { $0.mouseSpeed }, set: { $0.mouseSpeed = $1 }))
            rows.append(checkbox("Side buttons go back and forward", get: { $0.mouseSideButtons },
                                 set: { $0.mouseSideButtons = $1 }))
            rows.append(popup("Middle Button", choices: MiddleButton.allCases.map { ($0.displayName, $0) },
                              get: { $0.mouseMiddle }, set: { $0.mouseMiddle = $1 }))
        case .calendarClock:
            rows.append(checkbox("Show the date", get: { $0.clockDate }, set: { $0.clockDate = $1 }))
            rows.append(checkbox("Show the weekday", get: { $0.clockWeekday }, set: { $0.clockWeekday = $1 }))
            rows.append(checkbox("Show seconds", get: { $0.clockSeconds }, set: { $0.clockSeconds = $1 }))
            rows.append(popup("Hours", choices: ClockHours.allCases.map { ($0.displayName, $0) },
                              get: { $0.clockHours }, set: { $0.clockHours = $1 }))
            let next = checkbox("Show the next event and a Join button", get: { $0.clockNextEvent },
                                set: { $0.clockNextEvent = $1 })
            let allow = UI.pushButton("Allow Calendars…", small: true) { [weak self] in
                self?.host?.gadgetRequestPermission(.calendars)
            }
            allow.setAccessibilityIdentifier("allow-calendars")
            rows.append(withNote(next, text: { [weak self] in
                guard let host = self?.host, host.gadgetManager.settings.options.clockNextEvent else { return nil }
                switch host.gadgetPermissionGranted(.calendars) {
                case nil: return "Allow Calendars to see your events and join calls from the menu bar."
                case false?: return "Calendars is not allowed for Nacho Combo, so events do not show."
                default: return nil
                }
            }, button: allow))
            rows.append(worldClockRows())
        }
        switch id {
        case .windowSnap:
            rows.append(checkbox("Put a saved layout back when the same displays connect", get: { $0.autoApplyLayouts },
                                 set: { $0.autoApplyLayouts = $1 }))
        case .captureFloat:
            rows.append(checkbox("Also make a GIF of each recording (the first 15 seconds)", get: { $0.recordGIF },
                                 set: { $0.recordGIF = $1 }))
        default: break
        }
        return rows
    }

    /// A list of apps with Remove buttons and Add App….
    private func appList(_ title: String, ids: [String], set: @escaping ([String], inout GadgetOptions) -> Void) -> NSView {
        var lines: [NSView] = [UI.label(title, style: .callout)]
        for id in ids {
            let app = AppInfo(bundleID: id)
            let icon = NSImageView(image: app.icon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let remove = UI.pushButton("Remove", small: true) { [weak self] in
                self?.update { set(ids.filter { $0 != id }, &$0) }
                self?.renderTab()
            }
            lines.append(row([icon, UI.label(app.name, style: .callout), UI.spacer(), remove]))
        }
        let add = UI.pushButton("Add App…", small: true) { [weak self] in
            guard let picked = AppInfo.choose(), !ids.contains(picked) else { return }
            self?.update { set(ids + [picked], &$0) }
            self?.renderTab()
        }
        lines.append(row([add, UI.spacer()]))
        return UI.vstack(lines, spacing: 6)
    }

    /// The user's Shortcuts by name (loaded once in the background).
    private func shortcutPicker(_ title: String, get: @escaping (GadgetOptions) -> String,
                                set: @escaping (inout GadgetOptions, String) -> Void) -> NSView {
        let names = FocusSessionController.shortcutNames
        if names.isEmpty {
            FocusSessionController.loadShortcutNames { [weak self] in
                guard let self = self, self.module == .focusDim, self.tab == .settings,
                      !FocusSessionController.shortcutNames.isEmpty else { return }
                self.renderTab()
            }
        }
        var choices = [("None", "")] + names.map { ($0, $0) }
        let current = get(options)
        if !current.isEmpty, !names.contains(current) { choices.append((current, current)) }
        return popup(title, choices: choices, get: get, set: set)
    }

    private func worldClockRows() -> NSView {
        let zones = options.worldClocks
        var lines: [NSView] = [UI.label("World Clocks", style: .callout)]
        for identifier in zones {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            let offset = UI.label(WorldClock.offset(zone, from: .current, at: Date()), style: .subheadline, color: UI.secondaryText)
            let remove = UI.pushButton("Remove", small: true) { [weak self] in
                self?.update { $0.worldClocks.removeAll { $0 == identifier } }
                self?.renderTab()
            }
            lines.append(row([UI.label(WorldClock.city(identifier), style: .callout), offset, UI.spacer(), remove]))
        }
        let add = NSPopUpButton(frame: .zero, pullsDown: true)
        add.addItem(withTitle: "Add a City")
        add.font = UI.controlFont(.callout)
        for identifier in WorldClock.suggestions where !zones.contains(identifier) {
            guard let zone = TimeZone(identifier: identifier) else { continue }
            add.menu?.addItem(ClosureMenuItem(title: "\(WorldClock.city(identifier))  (\(WorldClock.offset(zone, from: .current, at: Date())))") {
                [weak self] in
                self?.update { $0.worldClocks.append(identifier) }
                self?.renderTab()
            })
        }
        lines.append(row([add, UI.spacer()]))
        return UI.vstack(lines, spacing: 6)
    }

    // MARK: menu bar access

    /// The two ways into the gadget from the menu bar, side by side: its own icon and a shortcut for its controls.
    private func menuBarAccessRows() -> [NSView] {
        let id = module
        let pinTitle = UI.label("Pin to Menu Bar", style: .callout)
        let pinNote = UI.label("A pinned icon opens \(id.displayName)'s controls directly.", style: .subheadline,
                               color: UI.secondaryText)
        let pin = NSSwitch()
        pin.setAccessibilityLabel("Pin \(id.displayName) to the menu bar")
        pin.setAccessibilityIdentifier("pin-\(id.rawValue)")
        pin.setAccessibilityHelp("A pinned icon opens this gadget's controls directly. Separate from on / off")
        let target = SwitchTarget { [weak self] on in self?.host?.gadgetSetPinned(id, on) }
        pin.target = target
        pin.action = #selector(SwitchTarget.changed(_:))
        objc_setAssociatedObject(pin, &SwitchTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self, weak pin] in
            pin?.state = (self?.host?.gadgetManager.settings.isPinned(id) ?? false) ? .on : .off
        }
        let pinRow = row([UI.vstack([pinTitle, pinNote], spacing: 2), UI.spacer(), pin])

        let open = ShortcutField(placeholder: "None")
        open.setAccessibilityLabel("\(id.displayName) open its controls shortcut")
        open.onRecordingChange = { [weak self] on in self?.host?.gadgetRecordingChanged(on) }
        open.onChange = { [weak self] shortcut, _ in
            guard let self = self else { return }
            self.note("open", self.host?.gadgetSetToolShortcut(id, shortcut))
        }
        shortcutFields["open"] = open
        return [pinRow, shortcutRow(title: "Shortcut to Open Its Controls", field: open, key: "open")]
    }

    // MARK: permissions

    private func permissionRows() -> [NSView] {
        var rows: [NSView] = []
        if info.permissions.isEmpty || info.permissions.allSatisfy({ $0.optional }) {
            let check = UI.symbolView("checkmark.shield", size: 15, tint: DotPalette.green)
            let title = UI.label(info.permissions.isEmpty ? "No Permission Needed" : "No Permission Needed to Run",
                                 style: .callout, weight: .semibold)
            let note = UI.wrapLabel(info.permissionNote, width: GadgetDetailView.cardInner - 29, style: .subheadline)
            rows.append(UI.hstack([check, UI.vstack([title, note], spacing: 2)], spacing: 8, alignment: .top))
        }
        for need in info.permissions {
            let symbol = UI.symbolView(need.permission.symbolName, size: 15, tint: .controlAccentColor)
            let name = UI.label(need.permission.displayName + (need.optional ? " (optional)" : ""), style: .callout,
                                weight: .semibold)
            let textWidth = GadgetDetailView.cardInner - 29
            let reason = UI.wrapLabel(need.reason, width: textWidth, style: .subheadline)
            let location = UI.wrapLabel(need.permission.location, width: textWidth, style: .footnote, color: UI.tertiaryText)
            let chip = Chip("", tone: .neutral)
            chip.setAccessibilityIdentifier("permission-status-\(need.permission.rawValue)")
            let button = UI.pushButton("Open Settings", small: true) { [weak self] in
                guard let host = self?.host else { return }
                if need.permission == .notifications || need.permission == .calendars,
                   host.gadgetPermissionGranted(need.permission) == nil {
                    host.gadgetRequestPermission(need.permission)
                } else {
                    host.gadgetOpenPermissionSettings(need.permission)
                }
            }
            button.setAccessibilityIdentifier("permission-\(need.permission.rawValue)")
            refreshers.append { [weak self, weak chip, weak button] in
                guard let self = self, let host = self.host, let chip = chip, let button = button else { return }
                switch host.gadgetPermissionGranted(need.permission) {
                case true?:
                    chip.title = "Allowed"; chip.tone = .success; button.title = "Open Settings"
                case false?:
                    chip.title = "Not allowed"
                    chip.tone = (self.enabled && !need.optional) ? .attention : .neutral
                    button.title = "Open Settings"
                case nil:
                    chip.title = "Not asked yet"; chip.tone = .neutral; button.title = "Ask"
                }
            }
            let statusRow = UI.hstack([chip, UI.spacer(), button], spacing: 8)
            statusRow.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            let text = UI.vstack([name, reason, location, statusRow], spacing: 3)
            text.setCustomSpacing(8, after: location)
            rows.append(UI.hstack([symbol, text], spacing: 8, alignment: .top))
        }
        return rows
    }

    // MARK: shortcuts

    private func addShortcutSections() {
        let id = module
        let actions = GadgetActions.of(id)
        guard !actions.isEmpty else {
            addSection("Shortcuts", rows: [UI.wrapLabel("This gadget has no global shortcuts. Its controls open from the "
                                                        + "menu bar; see Settings ▸ Menu Bar Access.",
                                                        width: GadgetDetailView.cardInner, style: .subheadline)])
            return
        }
        // Summary: how many are set, how many another app holds, and the way back to the defaults.
        let count = UI.label("", style: .callout, color: UI.secondaryText)
        let taken = Chip("", tone: .attention)
        taken.setAccessibilityIdentifier("shortcuts-taken")
        let restore = UI.pushButton("Restore Defaults…", small: true) { [weak self] in self?.confirmRestoreDefaults() }
        restore.setAccessibilityIdentifier("shortcuts-restore")
        refreshers.append { [weak self, weak count, weak taken, weak restore] in
            guard let self = self, let host = self.host else { return }
            let settings = host.gadgetManager.settings
            let set = actions.filter { settings.shortcut(forAction: $0.id) != nil }.count
            count?.setLive("\(set) of \(actions.count) set")
            let clashes = actions.filter { host.gadgetActionShortcutUnavailable($0.id) }.count
            taken?.title = "\(clashes) taken by another app"
            taken?.isHidden = clashes == 0
            restore?.isEnabled = actions.contains { settings.actionShortcuts[$0.id] != nil }
        }
        let summary = UI.hstack([count, taken, UI.spacer(), restore], spacing: 8)
        summary.widthAnchor.constraint(equalToConstant: GadgetDetailView.inner).isActive = true
        tabStack.addArrangedSubview(summary)
        tabStack.setCustomSpacing(12, after: summary)

        let groups = GadgetActions.groups(of: id)
        for group in groups {
            var rows: [NSView] = []
            let clashes = group.actions.filter { host?.gadgetActionShortcutUnavailable($0.id) ?? false }.count
            if let title = group.title {
                let open = expandedGroups.contains(title) || clashes > 0
                rows.append(groupHeader(title, count: group.actions.count, clashes: clashes, open: open))
                if open { rows.append(contentsOf: group.actions.map(actionRow)) }
            } else {
                rows.append(contentsOf: group.actions.map(actionRow))
            }
            let card = GadgetDetailView.card(rows)
            tabStack.addArrangedSubview(card)
            tabStack.setCustomSpacing(8, after: card)
        }
        if id == .appSwitch { addAppShortcutSection() }
        let footer = UI.wrapLabel("Click a shortcut and type a new one. ⌫ removes it, ↺ brings back the default, Esc cancels. "
                                  + "Shortcuts work everywhere while the gadget is on.", width: GadgetDetailView.inner,
                                  style: .footnote, color: UI.tertiaryText)
        tabStack.addArrangedSubview(footer)
    }

    /// App Switch: one row per app with its own shortcut, and Add App….
    private func addAppShortcutSection() {
        let label = UI.sectionTitle("App Shortcuts")
        tabStack.addArrangedSubview(label)
        tabStack.setCustomSpacing(6, after: label)
        var rows: [NSView] = []
        let list = options.appShortcuts
        for hotKey in list {
            let app = AppInfo(bundleID: hotKey.bundleID)
            let icon = NSImageView(image: app.icon)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let field = ShortcutField(placeholder: "None")
            field.setAccessibilityLabel("\(hotKey.name) shortcut")
            field.onRecordingChange = { [weak self] on in self?.host?.gadgetRecordingChanged(on) }
            let key = "app:\(hotKey.bundleID)"
            field.onChange = { [weak self] shortcut, _ in
                guard let self = self else { return }
                self.note(key, self.host?.gadgetSetAppShortcut(hotKey.bundleID, shortcut))
            }
            refreshers.append { [weak self, weak field] in
                guard let field = field, !field.isRecording else { return }
                field.shortcut = self?.options.appShortcuts.first { $0.bundleID == hotKey.bundleID }?.shortcut
            }
            let remove = UI.pushButton("Remove", small: true) { [weak self] in
                self?.update { $0.appShortcuts.removeAll { $0.bundleID == hotKey.bundleID } }
                self?.renderTab()
            }
            let name = UI.label(hotKey.name, style: .callout)
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = row([icon, name, UI.spacer(), field, remove])
            let note = UI.wrapLabel("", width: GadgetDetailView.cardInner, style: .subheadline, color: .labelColor)
            note.isHidden = true
            shortcutNotes[key] = note
            rows.append(UI.vstack([line, note], spacing: 4))
        }
        let add = UI.pushButton("Add App…", small: true) { [weak self] in
            guard let self = self, let picked = AppInfo.choose(),
                  !self.options.appShortcuts.contains(where: { $0.bundleID == picked }) else { return }
            self.update { $0.appShortcuts.append(AppHotKey(bundleID: picked, name: AppInfo(bundleID: picked).name, shortcut: nil)) }
            self.renderTab()
        }
        add.setAccessibilityIdentifier("app-shortcut-add")
        let explain = UI.wrapLabel(list.isEmpty ? "Add an app, then give it a shortcut: it opens the app, brings it to the front, "
                                   + "or hides it when it is already in front." : "Shortcuts need two modifier keys, like ⌃⌥.",
                                   width: GadgetDetailView.cardInner - 100, style: .subheadline)
        rows.append(row([explain, UI.spacer(), add]))
        let card = GadgetDetailView.card(rows)
        tabStack.addArrangedSubview(card)
        tabStack.setCustomSpacing(8, after: card)
    }

    private func groupHeader(_ title: String, count: Int, clashes: Int, open: Bool) -> NSView {
        let button = ClosureButton(title: "") { [weak self] in
            guard let self = self else { return }
            if self.expandedGroups.contains(title) { self.expandedGroups.remove(title) } else { self.expandedGroups.insert(title) }
            self.renderTab()
        }
        button.isBordered = false
        // A fixed box: the two chevrons differ in width, the title must not move when a group opens.
        if let chevron = UI.symbol(open ? "chevron.down" : "chevron.right", size: 11, weight: .semibold) {
            button.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                let s = chevron.size
                chevron.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width,
                                        height: s.height))
                return true
            }
            button.image?.isTemplate = true
        }
        button.imagePosition = .imageLeading
        button.attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: UI.font(.callout, weight: .semibold), .foregroundColor: NSColor.labelColor])
        button.contentTintColor = UI.secondaryText
        button.setAccessibilityLabel("\(title), \(count) shortcuts, \(open ? "expanded" : "collapsed")")
        button.setAccessibilityIdentifier("shortcut-group-\(title)")
        var views: [NSView] = [button, UI.spacer()]
        if clashes > 0 { views.append(Chip("\(clashes) taken", tone: .attention)) }
        views.append(UI.label("\(count)", style: .callout, color: UI.tertiaryText))
        return row(views)
    }

    private func actionRow(_ action: GadgetAction) -> NSView {
        let field = ShortcutField(placeholder: "None")
        field.defaultShortcut = action.defaultShortcut
        field.setAccessibilityLabel("\(action.title) shortcut")
        field.onRecordingChange = { [weak self] on in self?.host?.gadgetRecordingChanged(on) }
        field.onChange = { [weak self] shortcut, reset in
            guard let self = self else { return }
            self.note(action.id, self.host?.gadgetSetActionShortcut(action.id, shortcut, reset: reset))
        }
        shortcutFields[action.id] = field
        return shortcutRow(title: action.title, field: field, key: action.id)
    }

    private func shortcutRow(title: String, field: ShortcutField, key: String) -> NSView {
        let label = UI.label(title, style: .callout)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = row([label, UI.spacer(), field])
        let note = UI.wrapLabel("", width: GadgetDetailView.cardInner, style: .subheadline, color: .labelColor)
        note.isHidden = true
        shortcutNotes[key] = note
        return UI.vstack([line, note], spacing: 4)
    }

    private func note(_ key: String, _ message: String?) {
        guard let label = shortcutNotes[key] else { return }
        if let message = message {
            label.attributedStringValue = UI.notice(message, tint: .systemOrange, style: .subheadline)
            label.isHidden = false
        } else {
            label.isHidden = true
        }
        refresh()
    }

    private func confirmRestoreDefaults() {
        let id = module
        let alert = NSAlert()
        alert.messageText = "Restore \(id.displayName)'s default shortcuts?"
        alert.informativeText = "Shortcuts you changed or removed for \(id.displayName) go back to their defaults. "
            + "A default another gadget uses now stays empty."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.host?.gadgetResetActionShortcuts(id)
            self?.renderTab()
        }
        if let window = host?.gadgetWindow { alert.beginSheetModal(for: window, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    // MARK: refresh

    /// Updates the live parts without rebuilding (state, what has to be done, permissions, shortcuts, controls).
    func refresh() {
        guard let host = host else { return }
        let manager = host.gadgetManager
        let status = manager.status(of: module)
        stateDot.kind = status.dot
        stateLabel.setLive(status.stateText)
        stateLabel.textColor = status.dot == .off ? UI.secondaryText
            : (status.dot == .onNeedsSetup ? UI.attentionText : .labelColor)
        enableSwitch.state = manager.settings.isEnabled(module) ? .on : .off
        refreshTop()

        if let open = shortcutFields["open"], !open.isRecording { open.shortcut = manager.settings.shortcut(for: module) }
        for action in GadgetActions.of(module) {
            guard let field = shortcutFields[action.id], !field.isRecording else { continue }
            field.shortcut = manager.settings.shortcut(forAction: action.id)
            field.unavailable = host.gadgetActionShortcutUnavailable(action.id)
        }
        let idle: String
        if !manager.settings.isEnabled(module) {
            idle = "Off."
        } else if case .needsPermission = manager.states[module] ?? .off, let permission = info.requiredPermission {
            idle = "Allow \(permission.displayName) above to use these controls."
        } else {
            idle = "Not running; see the notice above."
        }
        statusLine.setLive(host.gadgetStatusLine(module) ?? idle)
        refreshers.forEach { $0() }
    }

    /// Re-renders the picture (on selection, after an option change, and on a timer for live numbers).
    func refreshPreview() {
        guard let host = host, tab == .overview else { return }
        var inputs = host.gadgetPreviewInputs()
        if module == .systemMonitor { inputs.monitor = host.gadgetMonitorPreview(appearance: appearanceName) }
        let picture = GadgetPreview.picture(for: module, inputs: inputs, appearance: effectiveAppearance)
        previewView.image = picture.image
        previewCaption.stringValue = picture.caption
    }

    private var appearanceName: NSAppearance.Name {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if window != nil { refreshPreview() }
    }
}

final class SwitchTarget: NSObject {
    static var key = 0
    private let handler: (Bool) -> Void
    init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    @objc func changed(_ sender: NSSwitch) { handler(sender.state == .on) }
}

// MARK: - Small controls

/// The preview picture with rounded corners and a hairline, height following the image's aspect ratio.
final class PreviewImageView: NSView {
    var image: NSImage? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        guard let image = image, image.size.width > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 200) }
        return NSSize(width: NSView.noIntrinsicMetric, height: (GadgetDetailView.inner * image.size.height / image.size.width).rounded())
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A button (or checkbox) that runs a closure.
final class ClosureButton: NSButton {
    private var handler: (() -> Void)?
    var onToggle: ((Bool) -> Void)?

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        target = self
        action = #selector(run)
    }

    convenience init(checkbox title: String, onToggle: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        self.onToggle = onToggle
        target = self
        action = #selector(run)
    }

    @objc private func run() {
        handler?()
        onToggle?(state == .on)
    }
}

final class SliderTarget: NSObject {
    static var key = 0
    private let handler: (Double) -> Void
    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }
    @objc func changed(_ sender: NSSlider) { handler(sender.doubleValue) }
}

/// Mini screens for the snap positions; clicking one applies it.
final class SnapGridView: NSView {
    private var buttons: [SnapChoiceButton] = []
    var isEnabled = true { didSet { buttons.forEach { $0.isEnabled = isEnabled } } }
    private static let choices: [SnapAction] = [.left, .right, .topHalf, .bottomHalf, .maximize, .center,
                                                .topLeft, .topRight, .bottomLeft, .bottomRight, .almostMaximize, .restore,
                                                .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds,
                                                .nextDisplay]
    private static let columns = 6

    init(cell: NSSize = NSSize(width: 54, height: 36), apply: @escaping (SnapAction) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for (index, action) in SnapGridView.choices.enumerated() {
            let b = SnapChoiceButton(action: action) { apply(action) }
            let column = index % SnapGridView.columns, rowIndex = index / SnapGridView.columns
            b.frame = NSRect(x: CGFloat(column) * (cell.width + 8), y: CGFloat(rowIndex) * (cell.height + 8),
                             width: cell.width, height: cell.height)
            addSubview(b)
            buttons.append(b)
        }
        let rows = (SnapGridView.choices.count + SnapGridView.columns - 1) / SnapGridView.columns
        widthAnchor.constraint(equalToConstant: CGFloat(SnapGridView.columns) * (cell.width + 8) - 8).isActive = true
        heightAnchor.constraint(equalToConstant: CGFloat(rows) * (cell.height + 8) - 8).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Snap positions")
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }
}

final class SnapChoiceButton: NSButton {
    let snapAction: SnapAction
    private let handler: () -> Void
    private var hover = false { didSet { needsDisplay = true } }

    init(action: SnapAction, handler: @escaping () -> Void) {
        snapAction = action
        self.handler = handler
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        self.action = #selector(run)
        toolTip = action.displayName + (HotKeySpec.spec(for: action).map { "  \($0.label)" } ?? "")
        setAccessibilityLabel(action.displayName)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func draw(_ dirtyRect: NSRect) {
        let screen = bounds.insetBy(dx: 1, dy: 1)
        let outline = NSBezierPath(roundedRect: screen, xRadius: 5, yRadius: 5)
        (hover && isEnabled ? NSColor.labelColor.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor).setFill()
        outline.fill()
        let f = WindowLayout.previewFraction(for: snapAction)
        let inner = screen.insetBy(dx: 3, dy: 3)
        // Drawn unflipped math (fractions have a bottom-left origin).
        let r = NSRect(x: inner.minX + f.minX * inner.width, y: inner.minY + (1 - f.maxY) * inner.height,
                       width: f.width * inner.width, height: f.height * inner.height).insetBy(dx: 1, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.9 : 0.35).setFill()
        NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5).fill()
        if snapAction == .restore || snapAction == .nextDisplay {
            let name = snapAction == .restore ? "arrow.uturn.backward" : "arrow.right"
            if let symbol = UI.symbol(name, size: 11, weight: .bold) {
                let tinted = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? symbol
                let s = tinted.size
                tinted.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
    override var isFlipped: Bool { true }
}

/// A shortcut shown as key caps; click to record a new one. ⌫ removes it, ↺ restores the default, Esc cancels.
final class ShortcutField: NSView {
    var shortcut: ToolShortcut? { didSet { needsDisplay = true; updateButtons(); updateAccessibility() } }
    var defaultShortcut: ToolShortcut? { didSet { updateButtons() } }
    /// macOS refused to register it (another app uses it).
    var unavailable = false { didSet { needsDisplay = true } }
    var onChange: ((ToolShortcut?, Bool) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?
    private let placeholder: String
    private let resetButton = NSButton()
    private static let fieldSize = NSSize(width: 132, height: 24)

    init(placeholder: String) {
        self.placeholder = placeholder
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: ShortcutField.fieldSize.width + 24, height: 24)))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: ShortcutField.fieldSize.width + 24).isActive = true
        heightAnchor.constraint(equalToConstant: ShortcutField.fieldSize.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Click, then type the new shortcut. Delete removes it, Escape cancels")
        resetButton.image = UI.symbol("arrow.counterclockwise", size: 11, weight: .semibold)
        resetButton.isBordered = false
        resetButton.contentTintColor = UI.secondaryText
        resetButton.toolTip = "Use the default shortcut"
        resetButton.setAccessibilityLabel("Use the default shortcut")
        resetButton.target = self
        resetButton.action = #selector(resetTapped)
        resetButton.frame = NSRect(x: ShortcutField.fieldSize.width + 4, y: 2, width: 20, height: 20)
        addSubview(resetButton)
        updateButtons()
        updateAccessibility()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var fieldRect: NSRect { NSRect(origin: .zero, size: ShortcutField.fieldSize) }

    private func updateButtons() {
        resetButton.isHidden = defaultShortcut == nil ? shortcut == nil : shortcut == defaultShortcut
        if defaultShortcut == nil { resetButton.toolTip = "Remove the shortcut" } else { resetButton.toolTip = "Use the default shortcut" }
    }

    private func updateAccessibility() {
        setAccessibilityValue(isRecording ? "Recording" : (shortcut?.label ?? placeholder))
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: fieldRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.03)).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : (unavailable ? NSColor.systemOrange : NSColor.separatorColor)).setStroke()
        path.lineWidth = isRecording || unavailable ? 1.5 : 1
        path.stroke()
        if isRecording {
            Draw.text("Type shortcut…", in: fieldRect.insetBy(dx: 8, dy: 0), font: UI.font(.callout),
                      color: .controlAccentColor, align: .center)
        } else if let shortcut = shortcut {
            let label = shortcut.label
            let width = KeyCaps.width(of: label, height: 18)
            KeyCaps.draw(label, at: NSPoint(x: fieldRect.midX - width / 2, y: 2.5), height: 18, dark: dark, flipped: true)
        } else {
            Draw.text(placeholder, in: fieldRect.insetBy(dx: 8, dy: 0), font: UI.font(.callout), color: UI.tertiaryText,
                      align: .center)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard fieldRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        isRecording ? stop() : start()
    }

    override func accessibilityPerformPress() -> Bool { isRecording ? stop() : start(); return true }

    private func start() {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
        updateAccessibility()
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            if event.type == .leftMouseDown {
                // A click elsewhere ends recording without a change.
                if event.window !== self.window || !self.fieldRect.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.stop()
                }
                return event
            }
            let mods = UI.modifiersToCarbon(event.modifierFlags)
            switch (event.keyCode, mods) {
            case (53, _): self.stop()                                   // Esc cancels
            case (51, 0), (117, 0):                                      // Delete alone removes the shortcut
                self.stop()
                self.onChange?(nil, false)
            default:
                self.stop()
                self.onChange?(ToolShortcut(keyCode: UInt32(event.keyCode), modifiers: mods), false)
            }
            return nil
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        needsDisplay = true
        updateAccessibility()
        onRecordingChange?(false)
    }

    @objc private func resetTapped() {
        if defaultShortcut == nil { onChange?(nil, false) } else { onChange?(nil, true) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stop() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// An installed app by bundle identifier: its name and icon, and a picker for /Applications.
struct AppInfo {
    let bundleID: String
    let name: String
    let icon: NSImage

    init(bundleID: String) {
        self.bundleID = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            name = bundleID
            icon = NSWorkspace.shared.icon(for: .application)
        }
    }

    /// Asks for an app in /Applications; returns its bundle identifier.
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
