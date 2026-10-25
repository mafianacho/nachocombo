import AppKit
import NachoComboCore

/// Live controls the detail pane offers (they act right away, they are not settings).
enum GadgetCommand: Equatable {
    case toggleCollapse, showAlwaysHidden
    case openMonitorPanel(MonitorItem)
    case snap(SnapAction)
    case toggleShelf, pasteToShelf, clearShelf
    case captureArea, captureWindow, captureScreen, capturePrevious, lockFloats, hideFloats, closeFloats
    case toggleDimPause
}

/// What the gallery needs from the app: live state of every gadget and the actions behind its controls.
protocol GadgetHost: AnyObject {
    var gadgetManager: ModuleManager { get }
    /// One line under the tile: a shortcut, a count or live numbers.
    func gadgetSubtitle(_ id: ModuleID) -> String
    /// Things that need the user's attention (missing permission, error, alert); the tile badge counts them.
    func gadgetAttention(_ id: ModuleID) -> [String]
    /// Live facts for the Controls section ("Collapsed", "3 items", "2 floats").
    func gadgetStatusLine(_ id: ModuleID) -> String?
    func gadgetPreviewInputs() -> GadgetPreviewInputs
    func gadgetMonitorPreview(appearance: NSAppearance.Name) -> (strip: NSImage?, panel: NSImage?, live: Bool)
    /// nil when macOS has not been asked yet (notifications).
    func gadgetPermissionGranted(_ permission: GadgetPermission) -> Bool?
    func gadgetOpenPermissionSettings(_ permission: GadgetPermission)
    func gadgetRequestPermission(_ permission: GadgetPermission)
    func gadgetRecheck(_ id: ModuleID)
    func gadgetSetEnabled(_ id: ModuleID, _ on: Bool)
    func gadgetSetPinned(_ id: ModuleID, _ pinned: Bool)
    /// Returns an error message when refused.
    func gadgetSetToolShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> String?
    func gadgetSetActionShortcut(_ actionID: String, _ shortcut: ToolShortcut?, reset: Bool) -> String?
    /// The action's shortcut is set but macOS refused to register it (another app holds it).
    func gadgetActionShortcutUnavailable(_ actionID: String) -> Bool
    func gadgetRecordingChanged(_ recording: Bool)
    func gadgetSetOptions(_ options: GadgetOptions)
    func gadgetSetMonitorSettings(_ value: MonitorSettings)
    func gadgetSetDimIntensity(_ value: Double)
    func gadgetPerform(_ command: GadgetCommand)
}

/// Right-hand pane of the gallery: everything about the selected gadget.
final class GadgetDetailView: NSView {
    static let width: CGFloat = 448
    static let margin: CGFloat = 22
    static var inner: CGFloat { width - 2 * margin }
    static let cardPadding: CGFloat = 12
    static var cardInner: CGFloat { inner - 2 * cardPadding }

    private weak var host: GadgetHost?
    private(set) var module: ModuleID = .menuBar
    private let stack = NSStackView()

    // Live parts, rebuilt on selection and refreshed in place.
    private let stateDot = StatusDotView()
    private let stateLabel = UI.label("", style: .callout, weight: .medium, color: UI.secondaryText)
    private let pinBox = NSButton(checkboxWithTitle: "Pin to Menu Bar", target: nil, action: nil)
    private var attentionStack = UI.vstack([], spacing: 6)
    private let previewView = PreviewImageView()
    private let previewCaption = UI.label("", style: .subheadline, color: UI.secondaryText)
    private let statusLine = UI.label("", style: .callout, color: UI.secondaryText)
    private var permissionStatus: [GadgetPermission: (label: NSTextField, button: NSButton)] = [:]
    private var shortcutFields: [String: ShortcutField] = [:]
    private var shortcutNotes: [String: NSTextField] = [:]
    private var refreshers: [() -> Void] = []
    private var lastAttention: [String] = []

    init(host: GadgetHost) {
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: GadgetDetailView.width, height: 400))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: GadgetDetailView.margin, bottom: 24, right: GadgetDetailView.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: GadgetDetailView.width),
        ])
        pinBox.target = self
        pinBox.action = #selector(pinToggled)
        pinBox.font = UI.font(.callout)
        previewCaption.lineBreakMode = .byWordWrapping
        previewCaption.maximumNumberOfLines = 2
        previewCaption.preferredMaxLayoutWidth = GadgetDetailView.inner
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: building

    func show(_ id: ModuleID) {
        module = id
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        refreshers.removeAll()
        permissionStatus.removeAll()
        shortcutFields.removeAll()
        shortcutNotes.removeAll()
        lastAttention = []
        let info = id.info
        let inner = GadgetDetailView.inner

        // Header: icon, name, one line, the real state.
        let icon = NSImageView(image: GadgetIcon.image(for: id, size: 56))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        icon.setAccessibilityElement(false)
        let name = UI.label(id.displayName, style: .title2, weight: .bold)
        name.setAccessibilityIdentifier("detail-title")
        let tagline = UI.wrapLabel(info.tagline, width: inner - 56 - 14, style: .callout)
        let state = UI.hstack([stateDot, stateLabel], spacing: 6)
        let titles = UI.vstack([name, tagline, state], spacing: 4)
        titles.setCustomSpacing(8, after: tagline)
        let header = UI.hstack([icon, titles], spacing: 14, alignment: .top)
        stack.addArrangedSubview(header)

        attentionStack = UI.vstack([], spacing: 6)
        stack.addArrangedSubview(attentionStack)

        // The picture.
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.widthAnchor.constraint(equalToConstant: inner).isActive = true
        previewView.setAccessibilityElement(true)
        previewView.setAccessibilityRole(.image)
        previewView.setAccessibilityLabel("\(id.displayName) preview")
        stack.addArrangedSubview(previewView)
        stack.setCustomSpacing(6, after: previewView)
        stack.addArrangedSubview(previewCaption)
        stack.setCustomSpacing(18, after: previewCaption)

        addSection("Controls", rows: controlRows(for: id))
        addSection("Features", rows: info.features.map(featureRow))
        addSection("Shortcuts", rows: shortcutRows(for: id), footer: shortcutFooter(for: id))
        if !info.tips.isEmpty { addSection("Keys and Gestures", rows: info.tips.map(tipRow)) }
        addSection("Permissions", rows: permissionRows(for: info))
        addSection("Options", rows: optionRows(for: id))
        if !info.limits.isEmpty { addSection("Good to Know", rows: info.limits.map(limitRow)) }

        refresh()
        refreshPreview()
    }

    private func addSection(_ title: String, rows: [NSView], footer: NSView? = nil) {
        guard !rows.isEmpty else { return }
        let label = UI.label(title, style: .headline, weight: .semibold)
        label.setAccessibilityRole(.staticText)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(6, after: label)
        let card = GadgetDetailView.card(rows)
        stack.addArrangedSubview(card)
        if let footer = footer {
            stack.setCustomSpacing(6, after: card)
            stack.addArrangedSubview(footer)
        }
        stack.setCustomSpacing(18, after: footer ?? card)
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

    // MARK: permissions

    private func permissionRows(for info: GadgetInfo) -> [NSView] {
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
            let reason = UI.wrapLabel(need.reason, width: GadgetDetailView.cardInner - 29, style: .subheadline)
            let location = UI.wrapLabel(need.permission.location, width: GadgetDetailView.cardInner - 29,
                                        style: .footnote, color: UI.tertiaryText)
            let status = UI.label("", style: .callout, weight: .medium)
            let button = NSButton(title: "Open Settings", target: self, action: #selector(permissionButton(_:)))
            button.controlSize = .small
            button.font = UI.font(.subheadline)
            button.identifier = NSUserInterfaceItemIdentifier(need.permission.rawValue)
            button.setAccessibilityIdentifier("permission-\(need.permission.rawValue)")
            permissionStatus[need.permission] = (status, button)
            let statusRow = UI.hstack([status, UI.spacer(), button], spacing: 8)
            statusRow.widthAnchor.constraint(equalToConstant: GadgetDetailView.cardInner - 29).isActive = true
            let text = UI.vstack([name, reason, location, statusRow], spacing: 3)
            text.setCustomSpacing(8, after: location)
            rows.append(UI.hstack([symbol, text], spacing: 8, alignment: .top))
        }
        return rows
    }

    @objc private func permissionButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let permission = GadgetPermission(rawValue: raw) else { return }
        if permission == .notifications, host?.gadgetPermissionGranted(.notifications) == nil {
            host?.gadgetRequestPermission(.notifications)
        } else {
            host?.gadgetOpenPermissionSettings(permission)
        }
    }

    // MARK: shortcuts

    private func shortcutRows(for id: ModuleID) -> [NSView] {
        var rows: [NSView] = []
        // The quick panel entry point first: it exists for every gadget.
        let open = ShortcutField(placeholder: "None")
        open.setAccessibilityLabel("\(id.displayName) open in quick panel shortcut")
        open.onRecordingChange = { [weak self] on in self?.host?.gadgetRecordingChanged(on) }
        open.onChange = { [weak self] shortcut, _ in
            guard let self = self else { return }
            self.note("open", self.host?.gadgetSetToolShortcut(id, shortcut))
        }
        shortcutFields["open"] = open
        rows.append(shortcutRow(title: "Open in Quick Panel", field: open, key: "open"))
        for action in GadgetActions.of(id) {
            let field = ShortcutField(placeholder: "None")
            field.defaultShortcut = action.defaultShortcut
            field.setAccessibilityLabel("\(action.title) shortcut")
            field.onRecordingChange = { [weak self] on in self?.host?.gadgetRecordingChanged(on) }
            field.onChange = { [weak self] shortcut, reset in
                guard let self = self else { return }
                self.note(action.id, self.host?.gadgetSetActionShortcut(action.id, shortcut, reset: reset))
            }
            shortcutFields[action.id] = field
            rows.append(shortcutRow(title: action.title, field: field, key: action.id))
        }
        return rows
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

    private func shortcutFooter(for id: ModuleID) -> NSView {
        UI.wrapLabel("Click a shortcut and type a new one. ⌫ removes it, ↺ brings back the default, Esc cancels. "
                     + "Shortcuts work everywhere while the gadget is on.", width: GadgetDetailView.inner, style: .footnote,
                     color: UI.tertiaryText)
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

    // MARK: controls

    private func button(_ title: String, symbol: String? = nil, _ command: GadgetCommand,
                        enabled: @escaping () -> Bool = { true }) -> NSButton {
        let b = ClosureButton(title: title) { [weak self] in self?.host?.gadgetPerform(command) }
        b.bezelStyle = .rounded
        b.font = UI.font(.callout)
        if let symbol = symbol, let image = UI.symbol(symbol, size: 12, weight: .medium) {
            b.image = image
            b.imagePosition = .imageLeading
        }
        refreshers.append { [weak b] in b?.isEnabled = enabled() }
        return b
    }

    private func running(_ id: ModuleID) -> Bool { host?.gadgetManager.states[id] == .running }

    private func controlRows(for id: ModuleID) -> [NSView] {
        var rows: [NSView] = []
        statusLine.stringValue = ""
        rows.append(row([statusLine, UI.spacer()]))
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
            popup.font = UI.font(.callout)
            refreshers.append { [weak popup] in popup?.isEnabled = on() }
            rows.append(row([popup, UI.spacer()]))
        case .windowSnap:
            let grid = SnapGridView { [weak self] action in self?.host?.gadgetPerform(.snap(action)) }
            refreshers.append { [weak grid] in grid?.isEnabled = on() }
            rows.append(row([grid, UI.spacer()]))
            rows.append(UI.wrapLabel("Applies to the front window of the app you used last.", width: GadgetDetailView.cardInner,
                                     style: .subheadline))
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
        case .focusDim:
            let slider = NSSlider(value: host?.gadgetManager.settings.dimIntensity ?? FocusDimLogic.defaultIntensity,
                                  minValue: FocusDimLogic.minimumIntensity, maxValue: FocusDimLogic.maximumIntensity,
                                  target: nil, action: nil)
            slider.isContinuous = true
            slider.translatesAutoresizingMaskIntoConstraints = false
            slider.widthAnchor.constraint(equalToConstant: 140).isActive = true
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
        box.font = UI.font(.callout)
        box.onToggle = { [weak self] on in self?.update { set(&$0, on) } }
        refreshers.append { [weak self, weak box] in box?.state = get(self?.options ?? .defaults) ? .on : .off }
        return row([box, UI.spacer()])
    }

    private func popup<T: Equatable>(_ title: String, choices: [(String, T)], get: @escaping (GadgetOptions) -> T,
                                     set: @escaping (inout GadgetOptions, T) -> Void) -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = UI.font(.callout)
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
                check.font = UI.font(.callout)
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
            ip.font = UI.font(.callout)
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
            rows.append(checkbox("Post a notification when an alert starts", get: { $0.alertNotifications },
                                 set: { $0.alertNotifications = $1 }))
        case .windowSnap:
            rows.append(popup("Gap Between Windows", choices: GadgetOptions.gapChoices.map {
                ($0 == 0 ? "None" : "\($0) pt", $0)
            }, get: { $0.snapGap }, set: { $0.snapGap = $1 }))
            rows.append(popup("Repeating Left / Right", choices: SnapRepeat.allCases.map { ($0.displayName, $0) },
                              get: { $0.snapRepeat }, set: { $0.snapRepeat = $1 }))
            rows.append(checkbox("Snap windows dragged to a screen edge or corner", get: { $0.snapDragToEdges },
                                 set: { $0.snapDragToEdges = $1 }))
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
        }
        pinBox.setAccessibilityIdentifier("pin-\(id.rawValue)")
        pinBox.setAccessibilityHelp("A pinned icon opens this gadget's controls directly. Separate from on / off")
        rows.append(row([pinBox, UI.spacer()]))
        return rows
    }

    @objc private func pinToggled() { host?.gadgetSetPinned(module, pinBox.state == .on) }

    // MARK: refresh

    /// Updates the live parts without rebuilding (state, notices, permissions, shortcuts, controls).
    func refresh() {
        guard let host = host else { return }
        let manager = host.gadgetManager
        let status = manager.status(of: module)
        stateDot.kind = status.dot
        stateLabel.setLive(status.stateText)
        stateLabel.textColor = status.dot == .off ? UI.secondaryText : .labelColor
        pinBox.state = manager.settings.isPinned(module) ? .on : .off

        let attention = host.gadgetAttention(module)
        if attention != lastAttention {
            lastAttention = attention
            for view in attentionStack.arrangedSubviews { attentionStack.removeArrangedSubview(view); view.removeFromSuperview() }
            for text in attention {
                let label = UI.wrapLabel("", width: GadgetDetailView.inner, style: .callout, color: .labelColor)
                label.attributedStringValue = UI.notice(text, tint: .systemOrange, style: .callout)
                label.setAccessibilityIdentifier("attention")
                attentionStack.addArrangedSubview(label)
            }
            if case .needsPermission = manager.states[module] ?? .off {
                let recheck = ClosureButton(title: "Check Again") { [weak self] in
                    guard let self = self else { return }
                    self.host?.gadgetRecheck(self.module)
                }
                recheck.bezelStyle = .rounded
                recheck.font = UI.font(.callout)
                var buttons: [NSView] = []
                for need in module.info.permissions where !need.optional {
                    let open = ClosureButton(title: "Open \(need.permission.displayName) Settings") { [weak self] in
                        self?.host?.gadgetOpenPermissionSettings(need.permission)
                    }
                    open.bezelStyle = .rounded
                    open.font = UI.font(.callout)
                    buttons.append(open)
                }
                attentionStack.addArrangedSubview(UI.hstack(buttons + [recheck], spacing: 8))
            }
            attentionStack.isHidden = attention.isEmpty
        }

        for (permission, views) in permissionStatus {
            let granted = host.gadgetPermissionGranted(permission)
            switch granted {
            case true?:
                views.label.stringValue = "✓ Allowed"
                views.label.textColor = DotPalette.green
                views.button.title = "Open Settings"
            case false?:
                views.label.stringValue = "Not allowed"
                views.label.textColor = .systemOrange
                views.button.title = "Open Settings"
            case nil:
                views.label.stringValue = "Not asked yet"
                views.label.textColor = UI.secondaryText
                views.button.title = "Ask"
            }
        }

        if let open = shortcutFields["open"], !open.isRecording { open.shortcut = manager.settings.shortcut(for: module) }
        for action in GadgetActions.of(module) {
            guard let field = shortcutFields[action.id], !field.isRecording else { continue }
            field.shortcut = manager.settings.shortcut(forAction: action.id)
            field.unavailable = host.gadgetActionShortcutUnavailable(action.id)
        }
        let idle = manager.settings.isEnabled(module) ? "Not running yet; see the notice at the top."
                                                      : "Off. Switch the gadget on to use these controls."
        statusLine.setLive(host.gadgetStatusLine(module) ?? idle)
        refreshers.forEach { $0() }
    }

    /// Re-renders the picture (on selection, after an option change, and on a timer for live numbers).
    func refreshPreview() {
        guard let host = host else { return }
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
