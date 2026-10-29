import AppKit
import NachoComboCore

/// Level 1: the feature list.
final class ToolListView: NSView {
    private weak var host: PanelHost?
    private var rows: [ModuleID: ToolRowView] = [:]
    private let summary = UI.label("", style: .subheadline, color: UI.secondaryText)
    /// What needs the user, right under the header: "Window Snap needs Accessibility  [Allow…]".
    private let banner = TintedCardView(tone: .attention, content: NSView(), padding: 0)
    private let bannerText = UI.label("", style: .subheadline, weight: .semibold)
    private var bannerTarget: ModuleID?
    private let comboRow = ComboEntryRow()
    var onSelect: ((ModuleID) -> Void)?
    var onCombos: (() -> Void)?
    var firstRow: ToolRowView? { ModuleID.allCases.first.flatMap { rows[$0] } }

    init(host: PanelHost) {
        self.host = host
        super.init(frame: .zero)
        let inner = UI.panelWidth - 2 * UI.margin

        // The title says what this is; the count answers the one question of this screen: what is on right now.
        let logo = NSImageView(image: AppIcon.artwork(height: 18))
        logo.setAccessibilityElement(false)
        let title = Brand.signLabel("Nacho Combo", size: 16)
        title.setAccessibilityIdentifier("panel-list-title")
        summary.alignment = .right
        summary.setAccessibilityIdentifier("panel-list-summary")
        let header = UI.hstack([logo, title, UI.spacer(), summary], spacing: 6)
        header.widthAnchor.constraint(equalToConstant: inner).isActive = true

        let warn = UI.symbolView("exclamationmark.triangle.fill", size: 12, tint: DotPalette.orange)
        bannerText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerText.setAccessibilityIdentifier("panel-banner-text")
        let allow = BrandButton("Allow…", style: .attention, small: true) { [weak self] in
            self?.host?.panelOpenGadget(self?.bannerTarget)
        }
        allow.setAccessibilityIdentifier("panel-banner-allow")
        let bannerRow = UI.hstack([warn, bannerText, UI.spacer(), allow], spacing: 6)
        bannerRow.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 6)
        banner.subviews.forEach { $0.removeFromSuperview() }
        banner.addSubview(bannerRow)
        NSLayoutConstraint.activate([
            bannerRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            bannerRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            bannerRow.topAnchor.constraint(equalTo: banner.topAnchor),
            bannerRow.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
            banner.widthAnchor.constraint(equalToConstant: inner),
        ])
        banner.isHidden = true

        comboRow.onActivate = { [weak self] in self?.onCombos?() }
        comboRow.widthAnchor.constraint(equalToConstant: inner).isActive = true
        var views: [NSView] = [header, UI.separator(width: inner), banner, comboRow]
        for id in ModuleID.allCases {
            let row = ToolRowView(module: id)
            row.setAccessibilityIdentifier("panel-row-\(id.rawValue)")
            row.onActivate = { [weak self] id in self?.onSelect?(id) }
            row.widthAnchor.constraint(equalToConstant: inner).isActive = true
            rows[id] = row
            views.append(row)
        }
        views.append(UI.separator(width: inner))

        let settings = UI.linkButton("Settings…", color: .labelColor, target: self, action: #selector(settingsClicked))
        settings.setAccessibilityIdentifier("panel-settings")
        settings.setAccessibilityHelp("Opens the settings window")
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        let quit = UI.linkButton("Quit", color: .labelColor, target: self, action: #selector(quitClicked))
        quit.setAccessibilityIdentifier("panel-quit")
        quit.setAccessibilityHelp("Quits Nacho Combo and cleans up every tool")
        let footer = UI.hstack([settings, UI.spacer(), quit], spacing: 8)
        footer.widthAnchor.constraint(equalToConstant: inner).isActive = true
        views.append(footer)

        let stack = UI.vstack(views, spacing: 4)
        stack.setCustomSpacing(8, after: header)
        stack.setCustomSpacing(8, after: views[views.count - 2])
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.margin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.margin),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(equalToConstant: UI.panelWidth),
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func update() {
        guard let host = host else { return }
        let manager = host.panelManager
        var statuses: [ToolStatusPresentation] = []
        for id in ModuleID.allCases {
            let status = manager.status(of: id)
            statuses.append(status)
            rows[id]?.configure(status: status, pinned: manager.settings.isPinned(id),
                                shortcut: manager.settings.shortcut(for: id))
        }
        comboRow.configure(current: ComboCatalog.current(manager.settings),
                           anyOn: ModuleID.allCases.contains { manager.settings.isEnabled($0) })
        // Only tools that really run count; what waits for the user gets the banner below instead.
        summary.setLive([ToolStatusPresentation.runningText(of: statuses), ToolStatusPresentation.errorText(of: statuses)]
                            .compactMap { $0 }.joined(separator: " · "))
        let waiting = ModuleID.allCases.filter { manager.status(of: $0).waitingFor != nil }
        if let first = waiting.first {
            bannerTarget = waiting.count == 1 ? first : nil
            bannerText.setLive(waiting.count == 1 ? "\(first.displayName) \(manager.status(of: first).stateText.lowercasedFirst)"
                                                  : "\(waiting.count) gadgets need permissions")
            banner.isHidden = false
        } else {
            banner.isHidden = true
        }
    }

    @objc private func settingsClicked() { host?.panelOpenSettings() }
    @objc private func quitClicked() { host?.panelQuit() }
}

/// Level 2: the controls of one tool. Never starts a tool or asks for a permission by itself:
/// the user presses the switch (or the permission buttons) explicitly.
final class ToolDetailView: NSView {
    private weak var host: PanelHost?
    private let module: ModuleID
    var onBack: (() -> Void)?

    private let dot = StatusDotView()
    private let stateLabel = UI.label("", style: .callout, weight: .medium, color: UI.secondaryText)
    private let enableSwitch = NSSwitch()
    private let messageLabel: NSTextField
    private let permissionRow = NSStackView()
    // The pin row never changes text in place: two labels and two buttons are shown/hidden instead, so the
    // revealed area is always repainted by the row (changed text kept the old glyphs on screen on Monterey).
    private let pinStatusOn = UI.label("Pinned to menu bar", style: .callout, weight: .medium, color: .labelColor)
    private let pinStatusOff = UI.label("Not pinned", style: .callout, weight: .medium, color: UI.secondaryText)
    private let pinButtonOn = LinkButton(title: "", target: nil, action: nil)
    private let pinButtonOff = LinkButton(title: "", target: nil, action: nil)
    private let shortcutLabel = UI.label("", style: .subheadline, color: UI.secondaryText)
    private var controls: [NSControl] = []
    private let inner = UI.panelWidth - 2 * UI.margin

    // tool specific
    private let collapseButton = NSButton(title: "Collapse Hidden Icons", target: nil, action: nil)
    private let cpuValue = UI.label("–", style: .callout, color: .labelColor)
    private let memValue = UI.label("–", style: .callout, color: .labelColor)
    private let rxValue = UI.label("–", style: .callout, color: .labelColor)
    private let txValue = UI.label("–", style: .callout, color: .labelColor)
    private var snapGrid: SnapGridView?
    private let statusLine = UI.label("", style: .subheadline, color: UI.secondaryText)
    private let alwaysHiddenButton = NSButton(title: "Show Always-Hidden", target: nil, action: nil)
    private let pasteButton = NSButton(title: "Add Clipboard", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private var captureButtons: [NSButton] = []
    private let shelfButton = NSButton(title: "Open Shelf", target: nil, action: nil)
    private let shelfCount = UI.label("", style: .subheadline, color: UI.secondaryText)
    private let captureButton = NSButton(title: "Capture Area", target: nil, action: nil)
    private let dimSlider = NSSlider(value: 0.5, minValue: FocusDimLogic.minimumIntensity,
                                     maxValue: FocusDimLogic.maximumIntensity, target: nil, action: nil)
    private let dimValue = UI.label("", style: .callout, color: .labelColor)

    init(module: ModuleID, host: PanelHost) {
        self.module = module
        self.host = host
        self.messageLabel = UI.wrapLabel("", width: UI.panelWidth - 2 * UI.margin, style: .subheadline, color: .labelColor)
        super.init(frame: .zero)

        // Back: standard chevron + title. Esc and Command-[ do the same.
        let back = UI.linkButton("All Tools", symbol: "chevron.left", target: self, action: #selector(backClicked))
        back.setAccessibilityIdentifier("panel-back")
        back.setAccessibilityLabel("Back to all tools")
        back.setAccessibilityHelp("Returns to the tool list. Esc does the same")
        back.keyEquivalent = "["
        back.keyEquivalentModifierMask = .command
        let top = UI.hstack([back, UI.spacer()], spacing: 8)

        let symbol = UI.symbolView(module.symbolName, size: 16)
        let name = UI.label(module.displayName, style: .title3, weight: .semibold)
        name.setAccessibilityIdentifier("panel-title")
        name.setAccessibilityRole(.staticText)
        dot.setAccessibilityElement(false)       // the state label below says the same in words
        stateLabel.setAccessibilityIdentifier("panel-state")
        stateLabel.setAccessibilityLabel("Status")
        let titleRow = UI.hstack([symbol, name, UI.spacer(), dot, stateLabel], spacing: 8)

        let enableLabel = UI.label("Enabled", style: .body)
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)
        enableSwitch.setAccessibilityLabel("Enable \(module.displayName)")
        enableSwitch.setAccessibilityIdentifier("panel-enable")
        let enableRow = UI.hstack([enableLabel, UI.spacer(), enableSwitch], spacing: 8)

        messageLabel.isHidden = true
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        permissionRow.isHidden = true
        permissionRow.translatesAutoresizingMaskIntoConstraints = false
        // The steps live in the settings window's permission card; here: go there, or straight to the list.
        let allow = NSButton(title: "Allow…", target: self, action: #selector(allowClicked))
        allow.setAccessibilityIdentifier("panel-allow")
        allow.bezelStyle = .rounded
        allow.keyEquivalent = "\r"          // the one thing to do on this screen
        let paneName = module.info.requiredPermission?.displayName ?? "Privacy"
        let openPane = NSButton(title: "Open \(paneName) Settings", target: self, action: #selector(openPaneClicked))
        openPane.setAccessibilityIdentifier("panel-open-permission")
        openPane.bezelStyle = .rounded
        permissionRow.addArrangedSubview(allow)
        permissionRow.addArrangedSubview(openPane)

        for (button, title) in [(pinButtonOn, "Unpin"), (pinButtonOff, "Pin to Menu Bar")] {
            button.isBordered = false
            button.target = self
            button.action = #selector(pinClicked)
            button.setAccessibilityIdentifier("panel-pin")
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: UI.linkText, .font: UI.font(.callout)])
            button.setAccessibilityLabel("\(module.displayName) \(title)")
        }
        let pinRow = OutlinedRow(views: [pinStatusOn, pinStatusOff, UI.spacer(), pinButtonOn, pinButtonOff])
        pinRow.orientation = .horizontal
        pinRow.alignment = .centerY
        pinRow.spacing = 8
        pinRow.translatesAutoresizingMaskIntoConstraints = false
        pinRow.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        for label in [pinStatusOn, pinStatusOff] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true
            label.drawsBackground = true
            label.backgroundColor = UI.rowSurface
            label.setAccessibilityLabel("Menu bar pin status")
        }

        let desc = UI.wrapLabel(module.toolSummary, width: inner, style: .callout)

        // Same order on every tool: use -> pin to the menu bar -> the tool's own controls -> permission guidance.
        var views: [NSView] = [top, titleRow, desc, enableRow, pinRow]
        views.append(contentsOf: toolSpecificViews())
        views.append(contentsOf: [messageLabel, permissionRow])
        shortcutLabel.setAccessibilityIdentifier("panel-shortcut")
        views.append(shortcutLabel)
        views.append(UI.separator(width: inner))
        let settingsLink = UI.linkButton("\(module.displayName) Settings…", symbol: "arrow.up.forward.square",
                                         symbolTrailing: true, target: self, action: #selector(settingsClicked))
        settingsLink.setAccessibilityIdentifier("panel-tool-settings")
        settingsLink.setAccessibilityLabel("Open \(module.displayName) settings")
        settingsLink.setAccessibilityHelp("Opens the settings window")
        settingsLink.keyEquivalent = ","
        settingsLink.keyEquivalentModifierMask = .command
        views.append(UI.hstack([settingsLink, UI.spacer()], spacing: 8))

        let stack = UI.vstack(views, spacing: 12)
        stack.setCustomSpacing(4, after: titleRow)          // title and its description read as one block
        for v in views where v is NSStackView { v.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.margin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.margin),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(equalToConstant: UI.panelWidth),
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: tool specific controls

    private func toolSpecificViews() -> [NSView] {
        switch module {
        case .menuBar:
            collapseButton.target = self
            collapseButton.action = #selector(collapseClicked)
            collapseButton.setAccessibilityIdentifier("panel-collapse")
            alwaysHiddenButton.target = self
            alwaysHiddenButton.action = #selector(alwaysHiddenClicked)
            alwaysHiddenButton.setAccessibilityIdentifier("panel-always-hidden")
            controls.append(contentsOf: [collapseButton, alwaysHiddenButton])
            let note = UI.wrapLabel("To hide an icon, ⌘-drag it left of the divider (┊).", width: inner)
            return [UI.hstack([collapseButton, alwaysHiddenButton], spacing: 8), note]
        case .systemMonitor:
            func line(_ title: String, _ value: NSTextField) -> NSView {
                value.font = UI.digitsFont(.callout)
                value.alignment = .right      // fixed-size, right-aligned: the frame never changes while values update
                value.translatesAutoresizingMaskIntoConstraints = false
                value.widthAnchor.constraint(equalToConstant: 170).isActive = true
                value.setAccessibilityLabel(title)
                return UI.hstack([UI.label(title, style: .callout, color: UI.secondaryText), UI.spacer(), value],
                                 spacing: 8)
            }
            cpuValue.setAccessibilityIdentifier("panel-cpu")
            memValue.setAccessibilityIdentifier("panel-mem")
            rxValue.setAccessibilityIdentifier("panel-rx")
            txValue.setAccessibilityIdentifier("panel-tx")
            return [line("CPU", cpuValue), line("Memory", memValue), line("Network down", rxValue),
                    line("Network up", txValue)]
        case .windowSnap:
            let grid = SnapGridView(cell: NSSize(width: 40, height: 27)) { [weak self] action in
                self?.host?.panelApplySnap(action)
            }
            grid.setAccessibilityIdentifier("panel-snap-grid")
            snapGrid = grid
            let note = UI.wrapLabel("Click a layout to apply it to the window of the app you used last.", width: inner)
            return [grid, note]
        case .fileShelf:
            shelfButton.target = self
            shelfButton.action = #selector(shelfClicked)
            shelfButton.setAccessibilityIdentifier("panel-shelf-toggle")
            controls.append(shelfButton)
            shelfCount.setAccessibilityIdentifier("panel-shelf-count")
            shelfCount.setAccessibilityLabel("Shelf item count")
            pasteButton.target = self
            pasteButton.action = #selector(pasteClicked)
            pasteButton.setAccessibilityIdentifier("panel-shelf-paste")
            controls.append(pasteButton)
            return [UI.hstack([shelfButton, pasteButton, shelfCount], spacing: 8)]
        case .captureFloat:
            captureButton.target = self
            captureButton.action = #selector(captureClicked)
            captureButton.title = "Area"
            captureButton.setAccessibilityIdentifier("panel-capture-start")
            func make(_ title: String, _ id: String, _ command: GadgetCommand) -> NSButton {
                let b = ClosureButton(title: title) { [weak self] in self?.capture(command) }
                b.bezelStyle = .rounded
                b.setAccessibilityIdentifier(id)
                return b
            }
            let window = make("Window", "panel-capture-window", .captureWindow)
            let screen = make("Screen", "panel-capture-screen", .captureScreen)
            let previous = make("Previous", "panel-capture-previous", .capturePrevious)
            let lock = make("Lock / Unlock", "panel-floats-lock", .lockFloats)
            let close = make("Close All", "panel-floats-close", .closeFloats)
            captureButtons = [captureButton, window, screen, previous, lock, close]
            controls.append(contentsOf: captureButtons)
            statusLine.setAccessibilityIdentifier("panel-capture-status")
            let note = UI.wrapLabel("Capturing starts after the panel closes.", width: inner)
            return [UI.hstack([captureButton, window, screen, previous], spacing: 6),
                    UI.hstack([lock, close, statusLine], spacing: 6), note]
        case .focusDim:
            dimSlider.target = self
            dimSlider.action = #selector(dimChanged(_:))
            dimSlider.isContinuous = true
            dimSlider.setAccessibilityIdentifier("panel-dim-slider")
            dimSlider.setAccessibilityLabel("Dim strength")
            dimValue.setAccessibilityIdentifier("panel-dim-value")
            dimValue.alignment = .right
            dimValue.translatesAutoresizingMaskIntoConstraints = false
            dimValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
            dimValue.font = UI.digitsFont(.callout)
            controls.append(dimSlider)
            let row = UI.hstack([UI.label("Strength", style: .callout, color: UI.secondaryText), dimSlider, dimValue],
                                spacing: 12)       // slider takes the free width; the value ends at the right edge
            dimSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            dimSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            pauseButton.target = self
            pauseButton.action = #selector(pauseClicked)
            pauseButton.setAccessibilityIdentifier("panel-dim-pause")
            controls.append(pauseButton)
            let session = commandButton("Focus Session", "panel-dim-session", .toggleFocusSession)
            return [row, UI.hstack([pauseButton, session], spacing: 8), statusLine]
        case .keepAwake:
            let toggle = commandButton("Keep Awake On / Off", "panel-keepawake-toggle", .toggleKeepAwake)
            let hour = commandButton("1 Hour", "panel-keepawake-hour", .keepAwakeFor(60))
            return [UI.hstack([toggle, hour], spacing: 8), statusLine]
        case .clipboard:
            let show = commandButton("Show History", "panel-clipboard-show", .showClipboard)
            return [UI.hstack([show], spacing: 8), statusLine]
        case .deviceControl:
            let mute = commandButton("Mute / Unmute", "panel-device-mute", .toggleMic)
            let next = commandButton("Next Output", "panel-device-output", .nextOutput)
            return [UI.hstack([mute, next], spacing: 8), statusLine]
        case .appSwitch:
            let hide = commandButton("Hide Other Apps", "panel-appswitch-hide", .hideOtherApps)
            let note = UI.wrapLabel("Hold ⌥ and press Tab to switch windows.", width: inner)
            return [UI.hstack([hide], spacing: 8), note]
        case .mouseTune:
            let reverse = commandButton("Reverse On / Off", "panel-mouse-reverse", .toggleMouseReverse)
            return [UI.hstack([reverse], spacing: 8), statusLine]
        case .calendarClock:
            let show = commandButton("Show Calendar", "panel-calendar-show", .showCalendar)
            let join = commandButton("Join Next Call", "panel-calendar-join", .joinNextMeeting)
            return [UI.hstack([show, join], spacing: 8), statusLine]
        }
    }

    private func commandButton(_ title: String, _ id: String, _ command: GadgetCommand) -> NSButton {
        let b = ClosureButton(title: title) { [weak self] in self?.host?.panelPerform(command) }
        b.bezelStyle = .rounded
        b.setAccessibilityIdentifier(id)
        controls.append(b)
        return b
    }

    // MARK: state

    func update() {
        guard let host = host else { return }
        let manager = host.panelManager
        let status = manager.status(of: module)
        let enabled = manager.settings.isEnabled(module)
        dot.kind = status.dot
        dot.toolTip = status.accessibilityText
        stateLabel.setLive(status.stateText)
        enableSwitch.state = enabled ? .on : .off

        if let permission = status.waitingFor {
            messageLabel.setLive(attributed: UI.notice("\(module.displayName) is on but can't run until \(permission) is allowed.",
                                                      tint: .systemOrange))
            messageLabel.isHidden = false
        } else if let detail = status.detail {
            messageLabel.setLive(attributed: UI.notice(detail, tint: status.dot == .onError ? .systemRed : .systemOrange))
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
        let showsPermission = status.waitingFor != nil
        permissionRow.isHidden = !showsPermission

        let pinned = manager.settings.isPinned(module)
        pinStatusOn.isHidden = !pinned
        pinButtonOn.isHidden = !pinned
        pinStatusOff.isHidden = pinned
        pinButtonOff.isHidden = pinned

        // Shown only when one is set; it is chosen in Settings ▸ Menu Bar Access.
        shortcutLabel.setLive(manager.settings.shortcut(for: module).map { "Shortcut for this screen: \($0.label)" } ?? "")
        shortcutLabel.isHidden = manager.settings.shortcut(for: module) == nil

        let running = status.dot == .on
        for c in controls { c.isEnabled = running }
        snapGrid?.isEnabled = running
        statusLine.setLive(running ? (host.panelStatusLine(module) ?? "") : "")
        switch module {
        case .menuBar:
            let info = host.panelCollapse
            collapseButton.isEnabled = running && info.running
            collapseButton.title = info.collapsed ? "Expand Hidden Icons" : "Collapse Hidden Icons"
            alwaysHiddenButton.isHidden = !host.panelOptions.alwaysHiddenSection
        case .systemMonitor:
            let r = host.panelReading
            if running {
                cpuValue.setLive(r.cpuBusy.map { String(format: "%.0f%%", $0) } ?? "–")
                memValue.setLive(r.memPercent.map {
                    String(format: "%.0f%%", $0) + " (\(SystemMath.formatBytes(r.memUsed)) / \(SystemMath.formatBytes(r.memTotal)))"
                } ?? "–")
                rxValue.setLive(r.rx.map { SystemMath.formatRateCompact($0) + "/s" } ?? "–")
                txValue.setLive(r.tx.map { SystemMath.formatRateCompact($0) + "/s" } ?? "–")
            } else {
                for v in [cpuValue, memValue, rxValue, txValue] { v.setLive("–") }
            }
            // A missing value is a quiet dash, a real value is full ink.
            for v in [cpuValue, memValue, rxValue, txValue] {
                v.textColor = v.stringValue == "–" ? UI.secondaryText : .labelColor
            }
        case .fileShelf:
            let info = host.panelShelf
            shelfButton.title = info.visible ? "Close Shelf" : "Open Shelf"
            shelfCount.setLive(running ? (info.count == 1 ? "1 item" : "\(info.count) items") : "")
        case .focusDim:
            if NSApp.currentEvent?.type != .leftMouseDragged { dimSlider.doubleValue = manager.settings.dimIntensity }
            let percent = Int((manager.settings.dimIntensity * 100).rounded())
            dimValue.textColor = running ? .labelColor : UI.tertiaryText
            dimValue.setLive("\(percent)%")
            dimSlider.setAccessibilityValueDescription("\(percent)%")
            pauseButton.title = host.panelStatusLine(.focusDim) == "Paused" ? "Resume" : "Pause"
        default: break
        }
        // Off: say why the controls are dimmed - on the dimmed controls only, not on the whole screen. When the tool is
        // on but not running, the notice already says why in words.
        for c in controls { c.toolTip = (!running && !enabled) ? "Available when the tool is on" : nil }
    }

    // MARK: actions

    @objc private func backClicked() { onBack?() }
    @objc private func enableToggled() { host?.panelSetEnabled(module, enableSwitch.state == .on) }
    @objc private func pinClicked() {
        guard let host = host else { return }
        host.panelSetPinned(module, !host.panelManager.settings.isPinned(module))
    }
    @objc private func settingsClicked() { host?.panelOpenSettings() }
    @objc private func openPaneClicked() { host?.panelOpenPermissionPane(module) }
    @objc private func allowClicked() { host?.panelOpenGadget(module) }
    @objc private func collapseClicked() { host?.panelToggleCollapse() }
    @objc private func shelfClicked() { host?.panelToggleShelf() }
    @objc private func captureClicked() { host?.panelStartCapture() }
    @objc private func alwaysHiddenClicked() { host?.panelPerform(.showAlwaysHidden) }
    @objc private func pasteClicked() { host?.panelPerform(.pasteToShelf) }
    @objc private func pauseClicked() { host?.panelPerform(.toggleDimPause) }
    private func capture(_ command: GadgetCommand) { host?.panelPerform(command) }
    @objc private func dimChanged(_ sender: NSSlider) { host?.panelSetDim(sender.doubleValue) }
}

extension String {
    /// "Needs Accessibility" → "needs Accessibility" (keeps the rest, unlike lowercased()).
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// The list's way into combos: the takeout icon, "Combo", which combo the box is now, and `›`.
final class ComboEntryRow: NSControl {
    var onActivate: (() -> Void)?
    private let value = UI.label("", style: .subheadline, weight: .semibold, color: UI.secondaryText)
    private var hover = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Combos")
        setAccessibilityIdentifier("panel-combos")
        let icon = NSImageView(image: SidebarView.symbolIcon("takeoutbag.and.cup.and.straw.fill", tint: Brand.nacho,
                                                             glyph: Brand.onNacho))
        icon.setAccessibilityElement(false)
        let name = UI.label("Combo", style: .body, weight: .medium)
        let chevron = UI.symbolView("chevron.right", size: 10, tint: UI.tertiaryText)
        value.lineBreakMode = .byTruncatingTail
        let row = UI.hstack([icon, name, UI.spacer(), value, chevron], spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(current: Combo?, anyOn: Bool) {
        let text = current.map { "No.\($0.number) \($0.name)" } ?? (anyOn ? "Your own box" : "Pick one")
        value.setLive(text)
        value.textColor = current == nil ? UI.secondaryText : UI.linkText
        setAccessibilityValue(text)
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?() }
    }
    override func keyDown(with event: NSEvent) {
        if focusRingType != .exterior { focusRingType = .exterior; noteFocusRingMaskChanged() }
        switch event.keyCode {
        case 36, 49, 76: onActivate?()
        case 125: window?.selectNextKeyView(nil)
        case 126: window?.selectPreviousKeyView(nil)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool { onActivate?(); return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (hover ? Brand.nacho.withAlphaComponent(0.22) : Brand.nacho.withAlphaComponent(0.1)).cgColor
        }
    }
}

/// One combo in the panel's list: its number, its name and what it means for the box ("Your box", "Asks for 1").
final class ComboListRow: NSControl {
    let combo: Combo
    var onActivate: ((Combo) -> Void)?
    var picked = false { didSet { updateBackground(); setAccessibilitySelected(picked) } }
    private var hover = false { didSet { updateBackground() } }
    private var tracking: NSTrackingArea?

    init(combo: Combo, note: String, noteColor: NSColor) {
        self.combo = combo
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Combo \(combo.number), \(combo.name)")
        setAccessibilityValue(note)
        setAccessibilityIdentifier("panel-combo-\(combo.id)")
        let number = Brand.signLabel("No.\(combo.number)", size: 14, color: Brand.nachoInk)
        number.translatesAutoresizingMaskIntoConstraints = false
        number.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let name = UI.label(combo.name, style: .callout, weight: .semibold)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let small = UI.label(note, style: .footnote, weight: .semibold, color: noteColor)
        let row = UI.hstack([number, name, UI.spacer(), small], spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onActivate?(combo) }
    }
    override func keyDown(with event: NSEvent) {
        if focusRingType != .exterior { focusRingType = .exterior; noteFocusRingMaskChanged() }
        switch event.keyCode {
        case 36, 49, 76: onActivate?(combo)
        case 125: window?.selectNextKeyView(nil)
        case 126: window?.selectPreviousKeyView(nil)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformPress() -> Bool { onActivate?(combo); return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }
    private func updateBackground() {
        let color: NSColor = picked ? Brand.nacho.withAlphaComponent(0.32)
            : (hover ? Brand.ink.withAlphaComponent(0.08) : .clear)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
        layer?.borderWidth = picked ? 1.5 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = Brand.nachoInk.withAlphaComponent(0.6).cgColor }
    }
}

/// Level 2: combos from the menu bar. Pick one to see what it would change, order it, undo it; make your own in Settings.
final class ComboPanelView: NSView {
    private weak var host: PanelHost?
    var onBack: (() -> Void)?
    private var pickedID: String
    private let stack = UI.vstack([], spacing: 6)
    private var lastKey = ""
    private let inner = UI.panelWidth - 2 * UI.margin

    init(host: PanelHost) {
        self.host = host
        let settings = host.panelManager.settings
        pickedID = ComboCatalog.current(settings)?.id ?? settings.combo ?? ComboCatalog.presets[0].id
        super.init(frame: .zero)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: UI.margin),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -UI.margin),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(equalToConstant: UI.panelWidth),
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    var firstRow: NSView? { stack.arrangedSubviews.first { $0 is ComboListRow } }

    private func note(_ combo: Combo, _ settings: AppSettings) -> (String, NSColor) {
        guard let host = host else { return ("", UI.secondaryText) }
        if ComboCatalog.current(settings)?.id == combo.id { return ("Your box", Brand.guac) }
        let missing = combo.permissions.filter { host.panelPermissionGranted($0) != true }.count
        return missing == 0 ? ("\(combo.gadgets.count) gadgets", UI.secondaryText) : ("Asks for \(missing)", Brand.nachoInk)
    }

    func update() {
        guard let host = host else { return }
        let settings = host.panelManager.settings
        let combos = ComboCatalog.combos(settings)
        if !combos.contains(where: { $0.id == pickedID }) { pickedID = combos[0].id }
        let picked = combos.first { $0.id == pickedID } ?? combos[0]
        let plan = ComboPlan.make(picked, settings: settings)
        let key = combos.map { "\($0.id):\($0.name):\(note($0, settings).0)" }.joined(separator: ",")
            + "|\(pickedID)|\(plan.turnsOn)|\(plan.turnsOff)|\(plan.optionChanges)|\(host.panelUndoName ?? "-")"
            + "|" + picked.gadgets.map { "\($0.rawValue)\(settings.isEnabled($0))" }.joined()
        guard key != lastKey else { return }
        lastKey = key
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        let back = UI.linkButton("All Tools", symbol: "chevron.left", target: self, action: #selector(backClicked))
        back.setAccessibilityIdentifier("panel-back")
        back.setAccessibilityLabel("Back to all tools")
        back.keyEquivalent = "["
        back.keyEquivalentModifierMask = .command
        stack.addArrangedSubview(UI.hstack([back, UI.spacer()], spacing: 8))
        let current = ComboCatalog.current(settings)
        let title = Brand.signLabel("Combos", size: 20)
        let currentLabel = UI.label(current.map { "Your box: \($0.name)" } ?? "Your own box", style: .subheadline,
                                    color: UI.secondaryText)
        let titleRow = UI.hstack([title, UI.spacer(), currentLabel], spacing: 8)
        stack.addArrangedSubview(titleRow)

        if let name = host.panelUndoName {
            let text = UI.label("\(name) ordered.", style: .subheadline, weight: .semibold)
            let undo = UI.linkButton("Undo", symbol: "arrow.uturn.backward", target: self, action: #selector(undoClicked))
            undo.setAccessibilityIdentifier("panel-combo-undo")
            stack.addArrangedSubview(UI.hstack([text, UI.spacer(), undo], spacing: 8))
        }

        for combo in combos {
            let (text, color) = note(combo, settings)
            let row = ComboListRow(combo: combo, note: text, noteColor: color)
            row.picked = combo.id == pickedID
            row.onActivate = { [weak self] combo in
                self?.pickedID = combo.id
                self?.update()
                self?.invalidateIntrinsicContentSize()
            }
            stack.addArrangedSubview(row)
        }
        stack.addArrangedSubview(detail(picked, plan: plan, settings: settings))

        let separator = UI.separator(width: inner)
        stack.addArrangedSubview(separator)
        let own = UI.linkButton("Make Your Own…", target: self, action: #selector(makeOwnClicked))
        own.setAccessibilityIdentifier("panel-combo-new")
        let more = UI.linkButton("Combos in Settings…", symbol: "arrow.up.forward.square", symbolTrailing: true,
                                 target: self, action: #selector(settingsClicked))
        stack.addArrangedSubview(UI.hstack([own, UI.spacer(), more], spacing: 8))
        for view in stack.arrangedSubviews where view is NSStackView || view is ComboListRow || view is OutlinedRow {
            view.widthAnchor.constraint(equalToConstant: inner).isActive = true
        }
        stack.setCustomSpacing(10, after: titleRow)
    }

    /// What the picked combo would do to the box, and the button that does it.
    private func detail(_ combo: Combo, plan: ComboPlan, settings: AppSettings) -> NSView {
        guard let host = host else { return NSView() }
        let width = inner - 24
        var views: [NSView] = []
        // The gadgets it holds, as icons.
        var icons: [NSView] = []
        for id in combo.gadgets {
            let icon = NSImageView(image: GadgetIcon.image(for: id, size: 20))
            icon.toolTip = id.displayName
            icon.setAccessibilityLabel(id.displayName)
            icons.append(icon)
        }
        views.append(UI.hstack(icons + [UI.spacer()], spacing: 6))
        func line(_ tag: String, _ text: String, _ color: NSColor) {
            let label = UI.wrapLabel("", width: width, style: .subheadline, color: Brand.ink)
            let attributed = NSMutableAttributedString(string: tag.uppercased() + "  ", attributes: [
                .font: Brand.mono(10), .foregroundColor: color, .kern: 0.8])
            attributed.append(NSAttributedString(string: text, attributes: [.font: UI.font(.subheadline), .foregroundColor: Brand.ink]))
            label.attributedStringValue = attributed
            views.append(label)
        }
        let names: ([ModuleID]) -> String = { $0.map { $0.displayName }.joined(separator: ", ") }
        if plan.isNoChange {
            line("Box", "This is your box as it is.", Brand.guac)
        } else {
            if !plan.turnsOn.isEmpty { line("On", names(plan.turnsOn), Brand.nachoInk) }
            if !plan.turnsOff.isEmpty { line("Off", names(plan.turnsOff), Brand.salsa) }
            for change in plan.optionChanges { line("Set", change, UI.secondaryText) }
        }
        let missing = combo.gadgets.compactMap { id -> (ModuleID, GadgetPermission)? in
            guard let permission = id.info.requiredPermission, host.panelPermissionGranted(permission) != true else { return nil }
            return (id, permission)
        }
        let ordered = settings.combo == combo.id
        if ordered, let first = missing.first {
            let text = UI.wrapLabel("\(first.0.displayName) needs \(first.1.displayName).", width: width - 90,
                                    style: .subheadline, color: UI.attentionText)
            let allow = BrandButton("Allow…", style: .attention, small: true) { [weak self] in
                self?.host?.panelOpenCombos(newCombo: false)
            }
            allow.setAccessibilityIdentifier("panel-combo-allow")
            views.append(UI.hstack([text, UI.spacer(), allow], spacing: 8))
        } else if !plan.isNoChange {
            if !missing.isEmpty {
                line("Asks", missing.map { "\($0.1.displayName) for \($0.0.displayName)" }.joined(separator: ", "), Brand.nachoInk)
            }
            let order = BrandButton("Order \(combo.name)", style: .primary, small: true) { [weak self] in
                self?.host?.panelOrderCombo(combo.id)
            }
            order.setAccessibilityIdentifier("panel-combo-order")
            views.append(UI.hstack([order, UI.spacer()], spacing: 8))
        }
        let column = UI.vstack(views, spacing: 6)
        let surface = OutlinedRow(views: [column])
        surface.orientation = .vertical
        surface.alignment = .leading
        surface.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.setAccessibilityElement(true)
        surface.setAccessibilityRole(.group)
        surface.setAccessibilityLabel("\(combo.name): what it changes")
        return surface
    }

    @objc private func backClicked() { onBack?() }
    @objc private func undoClicked() { host?.panelUndoOrder() }
    @objc private func makeOwnClicked() { host?.panelOpenCombos(newCombo: true) }
    @objc private func settingsClicked() { host?.panelOpenCombos(newCombo: false) }
}
