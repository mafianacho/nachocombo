import AppKit
import NachoComboCore

/// Whether Nacho Combo opens at login (Login Items, macOS 13 and later).
enum LoginItemState: Equatable {
    case unsupported, off, on, needsApproval
}

/// The app-level part of the settings panel: General, Permissions, Combos and MCP.
protocol SettingsHost: GadgetHost {
    var loginItemState: LoginItemState { get }
    /// Returns an error message when macOS refused.
    func setOpenAtLogin(_ on: Bool) -> String?
    func openLoginItemsSettings()
    func revealSettingsFile()
    func resetAllSettings()
    func quitApp()
    /// The body of the MCP page (Settings ▸ MCP): the server, keys, tool groups and per-gadget exposure.
    func settingsMCPView() -> NSView?
    /// Things on the Permissions page that need the user (the count on the Permissions tab).
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
    /// In-app updates (General ▸ Updates).
    var updateState: UpdateController.State { get }
    var currentVersion: String { get }
    func checkForUpdatesNow()
    /// Shows the confirmation, then installs (downloading first if needed) and restarts.
    func installUpdate()
    func openReleasePage()
    /// The kept copy of the version before, if any.
    var previousVersion: String? { get }
    /// Revert to Previous Version (asks first).
    func revertUpdate()
}

// MARK: - Icons

enum SettingsIcon {
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
        stack.addArrangedSubview(UI.sectionTitle("Updates"))
        let updates = GadgetDetailView.card([updateRow(), autoUpdateRow(), autoInstallRow(), revertRow()])
        stack.addArrangedSubview(updates)
        stack.setCustomSpacing(18, after: updates)
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
        // Wraps in the room the pop-up leaves (the panel is narrower than the old window).
        let note = UI.wrapLabel("Opening the app again always shows it.", width: cardInner - 215, style: .subheadline)
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

    private func updateRow() -> NSView {
        let note = UI.wrapLabel("", width: cardInner - 200, style: .subheadline, color: UI.secondaryText)
        let check = UI.pushButton("Check Now", small: true) { [weak self] in self?.host?.checkForUpdatesNow() }
        check.setAccessibilityIdentifier("general-update-check")
        let install = UI.pushButton("Update…", primary: true, small: true) { [weak self] in self?.host?.installUpdate() }
        install.setAccessibilityIdentifier("general-update-install")
        let notes = UI.pushButton("Release Notes", small: true) { [weak self] in self?.host?.openReleasePage() }
        notes.setAccessibilityIdentifier("general-update-notes")
        let summary = UI.wrapLabel("", width: cardInner, style: .subheadline, color: UI.secondaryText)
        let warning = UI.wrapLabel(UpdateController.permissionNote, width: cardInner, style: .subheadline,
                                   color: UI.tertiaryText)
        let title = UI.label("Nacho Combo", style: .callout)
        refreshers.append { [weak self, weak note, weak check, weak install, weak notes, weak summary, weak warning, weak title] in
            guard let host = self?.host else { return }
            title?.stringValue = "Nacho Combo \(host.currentVersion)"
            var available = false
            var busy = false
            switch host.updateState {
            case .idle: note?.stringValue = "Looks for a new release on GitHub."
            case .checking: note?.stringValue = "Checking…"; busy = true
            case .upToDate: note?.stringValue = "This is the latest version."
            case .available(let version, let text):
                available = true
                note?.stringValue = "Version \(version) is available."
                summary?.stringValue = text
            case .downloading(let step): note?.stringValue = step; busy = true
            case .ready(let version, let text):
                available = true
                note?.stringValue = "Version \(version) is downloaded and installs when Nacho Combo quits."
                summary?.stringValue = text
            case .installing(let step): note?.stringValue = step; busy = true
            case .failed(let message): note?.stringValue = message
            }
            if case .failed = host.updateState { note?.textColor = UI.attentionText } else { note?.textColor = UI.secondaryText }
            check?.isEnabled = !busy
            if case .ready = host.updateState { install?.title = "Restart to Update" } else { install?.title = "Update…" }
            install?.isHidden = !available
            install?.isEnabled = !busy
            notes?.isHidden = !available
            summary?.isHidden = !available || (summary?.stringValue.isEmpty ?? true)
            warning?.isHidden = !available
        }
        let top = row([UI.vstack([title, note], spacing: 2), UI.spacer(), notes, install, check])
        return UI.vstack([top, summary, warning], spacing: 6)
    }

    private func autoUpdateRow() -> NSView {
        let toggle = NSSwitch()
        toggle.setAccessibilityLabel("Check for updates automatically")
        toggle.setAccessibilityIdentifier("general-update-auto")
        let target = SwitchTarget { [weak self] on in self?.host?.gadgetManager.update { $0.checkForUpdates = on } }
        toggle.target = target
        toggle.action = #selector(SwitchTarget.changed(_:))
        objc_setAssociatedObject(toggle, &SwitchTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self, weak toggle] in
            toggle?.state = (self?.host?.gadgetManager.settings.checkForUpdates ?? true) ? .on : .off
        }
        let note = UI.label("At launch and every 6 hours, on GitHub Releases.", style: .subheadline, color: UI.secondaryText)
        return row([titled("Check Automatically", note), UI.spacer(), toggle])
    }

    private func autoInstallRow() -> NSView {
        let toggle = NSSwitch()
        toggle.setAccessibilityLabel("Download and install updates automatically")
        toggle.setAccessibilityIdentifier("general-update-auto-install")
        let target = SwitchTarget { [weak self] on in self?.host?.gadgetManager.update { $0.autoInstallUpdates = on } }
        toggle.target = target
        toggle.action = #selector(SwitchTarget.changed(_:))
        objc_setAssociatedObject(toggle, &SwitchTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { [weak self, weak toggle] in
            toggle?.state = (self?.host?.gadgetManager.settings.autoInstallUpdates ?? true) ? .on : .off
        }
        let note = UI.wrapLabel("Downloads a new version in the background and installs it when Nacho Combo quits, never while "
                                + "you use it. Off: nothing is installed until you click Update.",
                                width: cardInner - 80, style: .subheadline, color: UI.secondaryText)
        return row([titled("Install Automatically", note), UI.spacer(), toggle])
    }

    private func revertRow() -> NSView {
        let note = UI.wrapLabel("", width: cardInner - 200, style: .subheadline, color: UI.secondaryText)
        let revert = UI.pushButton("Revert…", small: true) { [weak self] in self?.host?.revertUpdate() }
        revert.setAccessibilityIdentifier("general-update-revert")
        refreshers.append { [weak self, weak note, weak revert] in
            let previous = self?.host?.previousVersion
            note?.stringValue = previous.map { "Version \($0) is kept. Going back removes this version and skips it in automatic updates." }
                ?? "No earlier version is kept on this Mac. Older versions stay on the GitHub Releases page."
            revert?.isEnabled = previous != nil
            revert?.title = previous.map { "Revert to \($0)…" } ?? "Revert…"
        }
        return row([titled("Previous Version", note), UI.spacer(), revert])
    }

    private func fileRow() -> NSView {
        let path = (SettingsStore.defaultURL().deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        let note = UI.label(path, style: .subheadline, color: UI.secondaryText)
        note.lineBreakMode = .byTruncatingMiddle
        let reveal = UI.pushButton("Show in Finder", small: true) { [weak self] in self?.host?.revealSettingsFile() }
        return row([titled("Settings File", note), UI.spacer(), reveal])
    }

    private func resetRow() -> NSView {
        let note = UI.wrapLabel("Turns every gadget off and restores the default options and shortcuts.", width: cardInner - 100,
                                style: .subheadline)
        let reset = UI.pushButton("Reset…", small: true) { [weak self] in self?.confirmReset() }
        reset.setAccessibilityIdentifier("general-reset")
        return row([titled("Reset All Settings", note), UI.spacer(), reset])
    }

    private func aboutRow() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let text = UI.wrapLabel("Nacho Combo \(version) · Not signed with an Apple Developer ID, so macOS asks for "
                                + "permissions again after an update. Source code: MIT. The Nacho character, icons, name and logo "
                                + "are not open source (TRADEMARKS.md).", width: inner - 170, style: .footnote,
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
    var onOpen: ((SettingsPanelRoute) -> Void)?

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
                                           { [weak self] in self?.onOpen?(.gadget(id, .permissions)) }),
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
        let diskUser = "Disk Map · lets a scan see every folder at once (optional)."
        if host.gadgetPermissionGranted(.fullDiskAccess) == true {
            lines.append(Line(symbol: GadgetPermission.fullDiskAccess.symbolName, title: "Full Disk Access", user: diskUser,
                              status: "Allowed", tone: .success,
                              action: ("Open Settings", false, { host.gadgetOpenPermissionSettings(.fullDiskAccess) }), note: nil))
        } else {
            lines.append(Line(symbol: GadgetPermission.fullDiskAccess.symbolName, title: "Full Disk Access", user: diskUser,
                              status: "Not allowed", tone: .neutral,
                              action: ("Open Settings", false, { host.gadgetOpenPermissionSettings(.fullDiskAccess) }),
                              note: "Without it, what macOS keeps closed counts as hidden space."))
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


// MARK: - MCP

/// Settings ▸ MCP (NACHO-195): everything about the server that outside MCP clients connect to. The Computer Use gadget
/// itself is only Nacho's switch; its old server settings moved here, with the per-gadget exposure switches.
final class MCPPage: NSView {
    private let width = GadgetDetailView.width

    convenience init(host: SettingsHost) { self.init(body: host.settingsMCPView()) }

    init(body: NSView?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = Brand.eyebrow("Settings")
        let title = UI.label("MCP", style: .title2, weight: .bold)
        let intro = UI.wrapLabel("Let MCP clients such as Claude, Cursor or a script use Nacho Combo's gadgets. Clients connect with an API key you make here. Nothing is open until you turn the server on.",
                                 width: GadgetDetailView.inner, style: .subheadline)
        let stack = UI.vstack([eyebrow, title, intro], spacing: 6)
        stack.setCustomSpacing(2, after: eyebrow)
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(16, after: intro)
        if let body = body { stack.addArrangedSubview(body) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GadgetDetailView.margin),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28),
            widthAnchor.constraint(equalToConstant: width),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func refresh() {}
}
