import AppKit
import NachoComboCore

/// The Computer Use gadget's own screen (NACHO-195): one switch (the gadget switch in the page header), one short line,
/// the emergency stop, and a line for each OS permission that is still missing. Everything about the MCP server (port,
/// LAN mode, keys, tool groups, call log) lives in Settings ▸ MCP.
///
/// Switching the gadget on asks macOS only for the permissions that are missing (`ComputerUseModule.start`). While one
/// is still missing, its line shows with an Open Settings button; coming back to the app reads the permissions again
/// and a line that is resolved disappears by itself. "Reset Accessibility Permission…" sits in the collapsed
/// Troubleshooting section.
///
/// Not run on a Mac yet - written to compile.
final class ComputerUseGadgetCard: NSObject {
    let view: NSStackView
    private let module: ComputerUseModule
    private let manager: ModuleManager
    private let width: CGFloat

    var openPermissionPane: ((OSPermission) -> Void)?
    var recheckPermissions: (() -> Void)?
    var resetAccessibility: (() -> String?)?
    var emergencyStop: (() -> Void)?

    private var lastState: ModuleState = .off
    private let permissionBox = NSStackView()
    private var permissionRows: [OSPermission: NSStackView] = [:]
    private let emergencyButton = NSButton(title: "Emergency Stop (\(ComputerUseModule.emergencyLabel))", target: nil, action: nil)
    private let troubleToggle = NSButton(title: "Troubleshooting", target: nil, action: nil)
    private let troubleBox = NSStackView()
    private let diagnosticsLabel: NSTextField
    private let locationLabel: NSTextField
    private let resetMessage: NSTextField
    private let resetButton = NSButton(title: "Reset Accessibility Permission…", target: nil, action: nil)

    init(module: ComputerUseModule, manager: ModuleManager, width: CGFloat) {
        self.module = module
        self.manager = manager
        self.width = width
        diagnosticsLabel = UI.wrapLabel("", width: width - 20, style: .caption1, color: UI.secondaryText)
        locationLabel = UI.wrapLabel("", width: width - 20, style: .callout, color: .labelColor)
        resetMessage = UI.wrapLabel("", width: width - 20, style: .callout, color: .labelColor)
        view = NSStackView()
        super.init()
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: layout

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10
        view.translatesAutoresizingMaskIntoConstraints = false

        let line = UI.wrapLabel("Lets Nacho look at the screen and use the mouse and keyboard for you. Nacho still asks you before it acts.",
                                width: width, style: .callout, color: .labelColor)
        line.setAccessibilityIdentifier("computer-use-gadget-description")
        view.addArrangedSubview(line)

        // One line per missing permission; a granted permission has none.
        permissionBox.orientation = .vertical
        permissionBox.alignment = .leading
        permissionBox.spacing = 6
        permissionBox.translatesAutoresizingMaskIntoConstraints = false
        for permission in ComputerUseGadgetPermissions.required {
            let text = UI.label(ComputerUseGadgetPermissions.line(for: permission), style: .callout, weight: .semibold)
            text.setAccessibilityIdentifier("computer-use-need-\(permission.rawValue)")
            let open = NSButton(title: "Open Settings", target: self, action: #selector(openPaneClicked(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(permission.rawValue)
            open.setAccessibilityIdentifier("computer-use-open-\(permission.rawValue)")
            open.setAccessibilityLabel("Open \(permission.displayName) settings")
            let row = UI.hstack([UI.symbolView("exclamationmark.triangle.fill", size: 13, tint: .systemOrange), text, UI.spacer(), open], spacing: 8)
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            permissionRows[permission] = row
            permissionBox.addArrangedSubview(row)
        }
        view.addArrangedSubview(permissionBox)

        emergencyButton.target = self
        emergencyButton.action = #selector(emergencyClicked)
        emergencyButton.setAccessibilityIdentifier("computer-use-emergency")
        emergencyButton.setAccessibilityHelp("Immediately refuses all calls, closes the MCP server and turns Computer Use off")
        view.addArrangedSubview(emergencyButton)

        view.addArrangedSubview(UI.wrapLabel("The server for outside MCP clients, with its keys and settings, is in Settings ▸ MCP.",
                                             width: width, style: .caption1))

        // Troubleshooting (collapsed)
        troubleToggle.setButtonType(.pushOnPushOff)
        troubleToggle.bezelStyle = .disclosure
        troubleToggle.title = ""
        troubleToggle.target = self
        troubleToggle.action = #selector(troubleToggled(_:))
        troubleToggle.setAccessibilityIdentifier("computer-use-troubleshooting")
        troubleToggle.setAccessibilityLabel("Troubleshooting")
        let troubleTitle = UI.label("Troubleshooting", style: .callout, weight: .semibold)
        view.addArrangedSubview(UI.hstack([troubleToggle, troubleTitle], spacing: 4))

        troubleBox.orientation = .vertical
        troubleBox.alignment = .leading
        troubleBox.spacing = 6
        troubleBox.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.setAccessibilityIdentifier("computer-use-permission-diagnostics")
        troubleBox.addArrangedSubview(diagnosticsLabel)
        locationLabel.setAccessibilityIdentifier("computer-use-location-warning")
        troubleBox.addArrangedSubview(locationLabel)
        let recheck = NSButton(title: "Check Permissions Again", target: self, action: #selector(recheckClicked))
        recheck.setAccessibilityIdentifier("computer-use-recheck")
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        resetButton.setAccessibilityIdentifier("computer-use-reset-accessibility")
        troubleBox.addArrangedSubview(UI.hstack([recheck, resetButton], spacing: 8))
        resetMessage.isHidden = true
        troubleBox.addArrangedSubview(resetMessage)
        troubleBox.isHidden = true
        let indent = UI.hstack([{ let gap = NSView(); gap.translatesAutoresizingMaskIntoConstraints = false
                                  gap.widthAnchor.constraint(equalToConstant: 20).isActive = true; return gap }(), troubleBox],
                               spacing: 0, alignment: .top)
        view.addArrangedSubview(indent)
    }

    // MARK: state

    @objc private func appBecameActive() { refresh(state: lastState) }

    func refresh(state: ModuleState) {
        lastState = state
        let on = manager.settings.isEnabled(.computerUse)
        // Read live, never cached: a permission allowed in System Settings drops its line when the app is active again.
        let missing = on ? ComputerUseGadgetPermissions.missing { ComputerUseModule.hasPermission($0) } : []
        for (permission, row) in permissionRows { row.isHidden = !missing.contains(permission) }
        permissionBox.isHidden = missing.isEmpty
        emergencyButton.isEnabled = on && module.isActive
        if !troubleBox.isHidden { refreshDiagnostics() }
    }

    private func refreshDiagnostics() {
        let bundle = Bundle.main
        let location = AppLocationDiagnosis.diagnose(bundlePath: bundle.bundleURL.path, home: NSHomeDirectory())
        let axTrusted = ComputerUseModule.hasPermission(.accessibility)
        let screen = ComputerUseModule.hasPermission(.screenRecording)
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        var lines = [
            "App: \(location.path)",
            "Bundle ID: \(bundle.bundleIdentifier ?? "-") · Version \(version)",
            "Accessibility (AXIsProcessTrusted): \(axTrusted ? "allowed" : "not allowed") · Screen Recording: \(screen ? "allowed" : "not allowed")",
            "Signature requirement: \(CodeSignature.designatedRequirement ?? "unknown")",
        ]
        if CodeSignature.requirementIsPerBuild {
            lines.append("This build's permission is tied to this exact build, so an entry left from another version stays switched on in System Settings but does not apply. Use Reset below.")
        }
        setWrapped(diagnosticsLabel, lines.joined(separator: "\n"), style: .caption1, color: UI.secondaryText)
        if let warning = location.warnings.first {
            locationLabel.attributedStringValue = UI.notice(AppLocationDiagnosis.message(for: warning),
                                                            tint: warning == .outsideApplications ? .systemOrange : .systemRed,
                                                            style: .callout)
            locationLabel.isHidden = false
        } else {
            locationLabel.isHidden = true
        }
        resetButton.isHidden = axTrusted
    }

    private func setWrapped(_ label: NSTextField, _ text: String, style: NSFont.TextStyle = .callout, color: NSColor = .labelColor) {
        let make = { UI.styled(text, font: UI.font(style), color: color, joinWords: true) }
        if let live = label as? LiveLabel { live.restyle = make }
        label.setLive(attributed: make())
    }

    // MARK: actions

    @objc private func troubleToggled(_ sender: NSButton) {
        troubleBox.isHidden = sender.state != .on
        if sender.state == .on { refreshDiagnostics() }
    }

    @objc private func openPaneClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let permission = OSPermission(rawValue: raw) else { return }
        openPermissionPane?(permission)
    }

    @objc private func recheckClicked() { recheckPermissions?(); refresh(state: lastState) }
    @objc private func emergencyClicked() { emergencyStop?() }

    @objc private func resetClicked() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the Accessibility permission of Nacho Combo?"
        alert.informativeText = "This removes Nacho Combo from the Accessibility list (Window Snap, App Switcher and Mouse Tune lose it too) and asks again. Then turn Nacho Combo on in System Settings ▸ Privacy & Security ▸ Accessibility. If macOS asks for your password, that is System Settings, not this app."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if let problem = resetAccessibility?() {
            resetMessage.attributedStringValue = UI.notice(problem, tint: .systemOrange, style: .callout)
        } else {
            resetMessage.attributedStringValue = UI.notice("Reset. Turn Nacho Combo on in the Accessibility list; the line above goes away by itself.",
                                                           tint: .systemGreen, style: .callout)
        }
        resetMessage.isHidden = false
    }
}
