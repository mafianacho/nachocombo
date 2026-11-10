import AppKit
import NachoComboCore

/// The Computer Use part of the settings window: address and port, the LAN mode (switch, connection URLs, TLS
/// fingerprint, warnings, firewall hint, sleep guard, Bonjour), permission guidance, tool group switches
/// (high-risk ones separate, with a confirmation), API keys (shown once, revocable) and the call log.
/// It only edits settings and keys; starting/stopping stays with the module manager.
///
/// Not run on a Mac yet - written to compile.
final class ComputerUseCard: NSObject {
    let view: NSStackView
    private let module: ComputerUseModule
    private let manager: ModuleManager
    private let width: CGFloat

    /// Opens the System Settings pane of one permission.
    var openPermissionPane: ((OSPermission) -> Void)?
    var recheckPermissions: (() -> Void)?
    /// A group switch or the port changed: the owner re-applies the running module.
    var settingsChanged: (() -> Void)?
    var emergencyStop: (() -> Void)?

    private var lastState: ModuleState = .off
    private var groupChecks: [ToolGroup: NSButton] = [:]
    private let endpointLabel: NSTextField
    private let portField = NSTextField()
    private let portMessage: NSTextField
    private let permissionRow = NSStackView()
    private var permissionButtons: [OSPermission: NSButton] = [:]
    private let keyList = NSStackView()
    private var keyListSignature = ""
    private let newKeyField = NSTextField()
    private let keyMessage: NSTextField
    private let logLabel: NSTextField
    private let emergencyButton = NSButton(title: "Emergency Stop (\(ComputerUseModule.emergencyLabel))", target: nil, action: nil)

    // LAN mode
    private let lanCheck = NSButton(checkboxWithTitle: "Allow connections from other computers on the same network (LAN mode)", target: nil, action: nil)
    private let lanBox = NSStackView()
    private let lanUrlList = NSStackView()
    private var lanUrlSignature = ""
    private let lanStatusLabel: NSTextField
    private let sanListLabel: NSTextField
    private let sanNoticeLabel: NSTextField
    private let fingerprintChangedLabel: NSTextField
    /// Fingerprint of the certificate that was thrown away by the last "regenerate", to show old -> new.
    private var previousFingerprint: String?
    private let fingerprintLabel = NSTextField(wrappingLabelWithString: "")
    private let clientExampleLabel = NSTextField(wrappingLabelWithString: "")
    private let copyFingerprintButton = NSButton(title: "Copy Fingerprint", target: nil, action: nil)
    private let copyPEMButton = NSButton(title: "Copy Certificate (PEM)", target: nil, action: nil)
    private let regenerateButton = NSButton(title: "Regenerate Certificate", target: nil, action: nil)
    private let sleepCheck = NSButton(checkboxWithTitle: "Keep the Mac awake while the server is on", target: nil, action: nil)
    private let bonjourCheck = NSButton(checkboxWithTitle: "Announce the service name on the same network (Bonjour)", target: nil, action: nil)

    init(module: ComputerUseModule, manager: ModuleManager, width: CGFloat) {
        self.module = module
        self.manager = manager
        self.width = width
        endpointLabel = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        portMessage = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        keyMessage = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        lanStatusLabel = UI.wrapLabel("", width: width - 20, style: .caption1, color: UI.secondaryText)
        sanListLabel = UI.wrapLabel("", width: width, style: .caption1, color: UI.secondaryText)
        sanNoticeLabel = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        fingerprintChangedLabel = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        logLabel = UI.wrapLabel("", width: width, style: .caption1, color: UI.secondaryText)
        view = NSStackView()
        super.init()
        build()
    }

    // MARK: layout

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.translatesAutoresizingMaskIntoConstraints = false

        endpointLabel.setAccessibilityIdentifier("computer-use-endpoint")

        // port
        portField.alignment = .right
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        portField.setAccessibilityIdentifier("computer-use-port")
        portField.setAccessibilityLabel("Computer Use port")
        let portApply = NSButton(title: "Apply", target: self, action: #selector(portApplyClicked))
        portApply.setAccessibilityIdentifier("computer-use-port-apply")
        let portTitle = UI.label("Port", style: .callout, color: UI.secondaryText)
        let portRow = UI.hstack([portTitle, portField, portApply], spacing: 8)
        portMessage.isHidden = true

        // permissions: one button per permission that is actually missing, plus a re-check
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        for permission in OSPermission.allCases {
            let button = NSButton(title: "Open \(permission.displayName) Settings", target: self, action: #selector(openPaneClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(permission.rawValue)
            button.setAccessibilityIdentifier("computer-use-open-\(permission.rawValue)")
            permissionButtons[permission] = button
            permissionRow.addArrangedSubview(button)
        }
        let recheck = NSButton(title: "Check Permissions Again", target: self, action: #selector(recheckClicked))
        recheck.setAccessibilityIdentifier("computer-use-recheck")
        permissionRow.addArrangedSubview(recheck)
        permissionRow.isHidden = true

        view.addArrangedSubview(endpointLabel)
        view.addArrangedSubview(portRow)
        view.addArrangedSubview(portMessage)
        buildLANSection()
        view.addArrangedSubview(permissionRow)

        // normal tool groups
        view.addArrangedSubview(sectionTitle("Tool Groups (tools in groups that are off are not listed and calls to them are refused)"))
        for group in ToolGroup.allCases where !group.isHighRisk { view.addArrangedSubview(groupRow(group)) }

        // high risk
        let danger = UI.label("High-Risk Tool Groups (off by default)", style: .callout, weight: .semibold, color: .systemRed)
        danger.setAccessibilityIdentifier("computer-use-high-risk-title")
        view.addArrangedSubview(danger)
        view.setCustomSpacing(12, after: view.arrangedSubviews[view.arrangedSubviews.count - 2])
        for group in ToolGroup.allCases where group.isHighRisk { view.addArrangedSubview(groupRow(group)) }

        // keys
        view.addArrangedSubview(sectionTitle("API Keys (Authorization: Bearer …)"))
        view.addArrangedSubview(keyList)
        keyList.orientation = .vertical
        keyList.alignment = .leading
        keyList.spacing = 6
        keyList.translatesAutoresizingMaskIntoConstraints = false
        newKeyField.placeholderString = "New key name (e.g. Laptop)"
        newKeyField.translatesAutoresizingMaskIntoConstraints = false
        newKeyField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        newKeyField.setAccessibilityIdentifier("computer-use-new-key-label")
        newKeyField.setAccessibilityLabel("New key name")
        let create = NSButton(title: "Create Key", target: self, action: #selector(createKeyClicked))
        create.setAccessibilityIdentifier("computer-use-create-key")
        view.addArrangedSubview(UI.hstack([newKeyField, create], spacing: 8))
        keyMessage.isHidden = true
        view.addArrangedSubview(keyMessage)
        view.addArrangedSubview(UI.wrapLabel("A key is shown only once, when it is created. This app stores only its hash. Whoever holds a key can control this Mac with the enabled tools, so revoke it right away if it leaks.",
                                            width: width, style: .callout))

        // emergency stop and log
        emergencyButton.target = self
        emergencyButton.action = #selector(emergencyClicked)
        emergencyButton.setAccessibilityIdentifier("computer-use-emergency")
        emergencyButton.setAccessibilityHelp("Immediately refuses all calls and turns Computer Use off")
        view.addArrangedSubview(emergencyButton)
        view.addArrangedSubview(sectionTitle("Recent Calls (only the tool name, time and key name are logged, never typed content or screens)"))
        logLabel.setAccessibilityIdentifier("computer-use-log")
        view.addArrangedSubview(logLabel)
    }

    // MARK: LAN mode

    private func buildLANSection() {
        view.addArrangedSubview(sectionTitle("Access Scope"))

        lanCheck.target = self
        lanCheck.action = #selector(lanToggled(_:))
        lanCheck.font = UI.font(.callout, weight: .medium)
        lanCheck.setAccessibilityIdentifier("computer-use-lan-mode")
        lanCheck.setAccessibilityLabel("Computer Use LAN mode")
        view.addArrangedSubview(lanCheck)
        view.addArrangedSubview(indented(UI.wrapLabel(
            "Off (default): opens only inside this Mac (127.0.0.1). When on, computers on the same router or private network can connect over TLS (encrypted). Connections from non-private addresses are dropped immediately.",
            width: width - 20, style: .caption1)))

        // Everything below is only visible while the LAN mode is selected.
        lanBox.orientation = .vertical
        lanBox.alignment = .leading
        lanBox.spacing = 6
        lanBox.translatesAutoresizingMaskIntoConstraints = false

        let warning = UI.wrapLabel(
            "In LAN mode, anyone on the same network can try to connect to this port. Tools need an API key, but if a key leaks, this Mac can be controlled from inside the network. Do not turn it on on public Wi-Fi, in cafés or in hotels, and turn it on only when you need it.",
            width: width, style: .callout, color: .systemRed)
        warning.setAccessibilityIdentifier("computer-use-lan-warning")
        lanBox.addArrangedSubview(warning)

        lanUrlList.orientation = .vertical
        lanUrlList.alignment = .leading
        lanUrlList.spacing = 4
        lanUrlList.translatesAutoresizingMaskIntoConstraints = false
        lanBox.addArrangedSubview(sectionTitle("Connection Addresses (enter an address and an API key in your client)"))
        lanBox.addArrangedSubview(lanUrlList)
        lanStatusLabel.setAccessibilityIdentifier("computer-use-lan-status")
        lanBox.addArrangedSubview(lanStatusLabel)

        lanBox.addArrangedSubview(sectionTitle("TLS Certificate Fingerprint (SHA-256) — check that it matches on the first connection from a client"))
        configureSelectable(fingerprintLabel, style: .callout)
        fingerprintLabel.setAccessibilityIdentifier("computer-use-lan-fingerprint")
        fingerprintLabel.setAccessibilityLabel("TLS certificate fingerprint")
        lanBox.addArrangedSubview(fingerprintLabel)
        copyFingerprintButton.target = self
        copyFingerprintButton.action = #selector(copyFingerprintClicked)
        copyFingerprintButton.setAccessibilityIdentifier("computer-use-lan-copy-fingerprint")
        copyPEMButton.target = self
        copyPEMButton.action = #selector(copyPEMClicked)
        copyPEMButton.setAccessibilityIdentifier("computer-use-lan-copy-pem")
        regenerateButton.target = self
        regenerateButton.action = #selector(regenerateClicked)
        regenerateButton.setAccessibilityIdentifier("computer-use-lan-regenerate")
        fingerprintChangedLabel.setAccessibilityIdentifier("computer-use-lan-fingerprint-changed")
        fingerprintChangedLabel.isHidden = true
        lanBox.addArrangedSubview(fingerprintChangedLabel)
        lanBox.addArrangedSubview(UI.hstack([copyFingerprintButton, copyPEMButton], spacing: 8))
        lanBox.addArrangedSubview(regenerateButton)
        sanListLabel.setAccessibilityIdentifier("computer-use-lan-cert-names")
        lanBox.addArrangedSubview(sanListLabel)
        sanNoticeLabel.setAccessibilityIdentifier("computer-use-lan-cert-address-changed")
        sanNoticeLabel.isHidden = true
        lanBox.addArrangedSubview(sanNoticeLabel)
        lanBox.addArrangedSubview(UI.wrapLabel(
            "The certificate is self-signed, created only on this Mac, and its private key is in the keychain. It contains this Mac’s private addresses and its “name.local” name, so if an address changes (for example when the router hands out a different one), regenerate it with “Regenerate Certificate”. Regenerating changes the fingerprint, so clients must check the new fingerprint again. Clients that pin the fingerprint keep connecting after an address change as long as the fingerprint stays the same.",
            width: width, style: .caption1))

        lanBox.addArrangedSubview(sectionTitle("Client Connection Examples"))
        configureSelectable(clientExampleLabel, style: .caption1)
        clientExampleLabel.setAccessibilityIdentifier("computer-use-lan-client-example")
        lanBox.addArrangedSubview(clientExampleLabel)

        sleepCheck.target = self
        sleepCheck.action = #selector(sleepToggled(_:))
        sleepCheck.font = UI.font(.callout, weight: .medium)
        sleepCheck.setAccessibilityIdentifier("computer-use-lan-prevent-sleep")
        lanBox.addArrangedSubview(sleepCheck)
        lanBox.addArrangedSubview(indented(UI.wrapLabel(
            "Other computers cannot connect while the Mac sleeps. When this is on, system sleep is prevented while Computer Use is on (the display may still turn off, and a turned-off display cannot be captured). Keeping the power adapter connected is recommended.",
            width: width - 20, style: .caption1)))

        bonjourCheck.target = self
        bonjourCheck.action = #selector(bonjourToggled(_:))
        bonjourCheck.font = UI.font(.callout, weight: .medium)
        bonjourCheck.setAccessibilityIdentifier("computer-use-lan-bonjour")
        lanBox.addArrangedSubview(bonjourCheck)
        lanBox.addArrangedSubview(indented(UI.wrapLabel(
            "Announces this Mac’s name and port as a “\(ComputerUseLAN.bonjourType)” service (keys and fingerprints are not included). Off by default.",
            width: width - 20, style: .caption1)))

        let firewall = NSButton(title: "Open Firewall Settings", target: self, action: #selector(openFirewallClicked))
        firewall.setAccessibilityIdentifier("computer-use-lan-firewall")
        lanBox.addArrangedSubview(UI.wrapLabel(
            "If the macOS firewall is on, it asks “Do you want the application “Nacho Combo” to accept incoming network connections?” the first time the port opens. Click “Allow” so that other computers can connect. If connections fail, check System Settings ▸ Network ▸ Firewall to make sure Nacho Combo is not blocked.",
            width: width, style: .caption1))
        lanBox.addArrangedSubview(firewall)

        view.addArrangedSubview(lanBox)
    }

    /// A selectable, monospaced, wrapping text (fingerprint, command line) that breaks at any character.
    private func configureSelectable(_ field: NSTextField, style: NSFont.TextStyle) {
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: style).pointSize, weight: .regular)
        field.textColor = .labelColor
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = width
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func refreshLAN(config: ComputerUseSettings, state: ModuleState) {
        let urls = ComputerUseLAN.urls(mode: .lan, bindAddress: config.bindAddress, port: config.port)
        let signature = urls.joined(separator: ";")
        if signature != lanUrlSignature {
            lanUrlSignature = signature
            for row in lanUrlList.arrangedSubviews { lanUrlList.removeArrangedSubview(row); row.removeFromSuperview() }
            for url in urls {
                let field = NSTextField(labelWithString: url)
                field.isSelectable = true
                field.font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
                field.setAccessibilityLabel("Connection address \(url)")
                let copy = NSButton(title: "Copy", target: self, action: #selector(copyURLClicked(_:)))
                copy.identifier = NSUserInterfaceItemIdentifier(url)
                copy.setAccessibilityLabel("Copy connection address \(url)")
                lanUrlList.addArrangedSubview(UI.hstack([field, copy], spacing: 8))
            }
        }

        let hasPrivateAddress = !ComputerUseLAN.privateIPv4Addresses().isEmpty
        let status: String
        switch state {
        case .running where module.activeMode == .lan:
            status = hasPrivateAddress
                ? "Open (TLS). Only computers on the same network can connect."
                : "Open, but this Mac’s private IP address was not found. Check the Wi-Fi or Ethernet connection."
        case .running:
            status = "Applying settings…"
        case .needsPermission:
            status = "Not open yet (permission required)."
        case .failed(let message):
            status = "Did not open: \(message)"
        case .off:
            status = manager.settings.isEnabled(.computerUse)
                ? "Waiting for the server to start."
                : "Computer Use is off, so the port is closed. When it is on, it opens at this address."
        }
        setWrapped(lanStatusLabel, status, style: .caption1, color: UI.secondaryText)

        let identity = module.activeMode == .lan ? module.tlsIdentity : nil
        let shown = identity?.fingerprintDisplay ?? "Shown once the server is open (the certificate is created the first time it is turned on)."
        if fingerprintLabel.stringValue != shown { fingerprintLabel.stringValue = shown }
        fingerprintLabel.setAccessibilityValue(identity?.fingerprintDisplay ?? "None yet")
        copyFingerprintButton.isEnabled = identity != nil
        copyPEMButton.isEnabled = identity != nil
        refreshCertificateNames(identity)

        sleepCheck.state = ComputerUseLANPrefs.preventSleep ? .on : .off
        bonjourCheck.state = ComputerUseLANPrefs.advertiseBonjour ? .on : .off

        let example = clientExample(url: urls.first ?? "")
        if clientExampleLabel.stringValue != example { clientExampleLabel.stringValue = example }
    }

    /// Names inside the stored certificate, an orange hint when this Mac's addresses no longer match them, and the
    /// old -> new fingerprint line after a regeneration.
    private func refreshCertificateNames(_ identity: ComputerUseTLSIdentity?) {
        guard let identity = identity else {
            sanListLabel.isHidden = true
            sanNoticeLabel.isHidden = true
            fingerprintChangedLabel.isHidden = previousFingerprint == nil
            if previousFingerprint != nil {
                setWrapped(fingerprintChangedLabel, "The certificate was deleted. A new fingerprint will be shown once the server opens again.", style: .callout)
            }
            return
        }
        let have = identity.subjectAltNames
        let listed = ((have?.dnsNames ?? []) + (have?.ipAddresses ?? []).map { ComputerUseLAN.text(ofPackedAddress: $0) })
            .filter { $0 != "localhost" && $0 != "127.0.0.1" && $0 != "::1" }
        sanListLabel.isHidden = false
        setWrapped(sanListLabel, listed.isEmpty ? "Addresses and names in the certificate: localhost only" : "Addresses and names in the certificate: " + listed.joined(separator: ", "),
                   style: .caption1, color: UI.secondaryText)

        let missing = ComputerUseLAN.missingCertificateNames(in: identity.certificateDER, wanted: ComputerUseLAN.certificateNames())
        if missing.isEmpty {
            sanNoticeLabel.isHidden = true
        } else {
            sanNoticeLabel.isHidden = false
            sanNoticeLabel.attributedStringValue = UI.notice(
                "This Mac’s address has changed (not in the certificate: \(missing.joined(separator: ", "))). The certificate must be regenerated after an address change. Clicking “Regenerate Certificate” changes the fingerprint. Clients that pin the fingerprint keep connecting as long as it stays the same; clients that also verify the host name fail until it is updated.",
                tint: .systemOrange, style: .callout)
        }

        if let old = previousFingerprint {
            if old == identity.fingerprint {
                fingerprintChangedLabel.isHidden = true
            } else {
                fingerprintChangedLabel.isHidden = false
                let oldShown = ComputerUseCertificate.colonSeparated(hex: String(old.prefix(16)))
                let newShown = ComputerUseCertificate.colonSeparated(hex: String(identity.fingerprint.prefix(16)))
                setWrapped(fingerprintChangedLabel, "The fingerprint was updated: before \(oldShown)… → now \(newShown)… Check the new fingerprint above again in your clients.",
                           style: .callout)
            }
        } else {
            fingerprintChangedLabel.isHidden = true
        }
    }

    private func clientExample(url: String) -> String {
        guard let parts = URLComponents(string: url), let host = parts.host, let port = parts.port else { return "" }
        let header = "-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream'"
        let body = "-d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}'"
        return [
            "1) Check the fingerprint (it must match the one above)",
            "openssl s_client -connect \(host):\(port) </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256",
            "2) Call (only if the fingerprint matches; pass the key via an environment variable)",
            "curl -k \(url) -H \"Authorization: Bearer $NACHO_KEY\" \(header) \(body)",
            "3) Or save “Copy Certificate (PEM)” as nacho.pem to verify the address and name as well",
            "curl --cacert nacho.pem \(url) -H \"Authorization: Bearer $NACHO_KEY\" \(header) \(body)",
        ].joined(separator: "\n")
    }

    private func copyPlain(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    private func sectionTitle(_ text: String) -> NSView {
        let label = UI.wrapLabel(text, width: width, style: .callout, color: .labelColor)
        label.font = UI.font(.callout, weight: .semibold)
        return label
    }

    private func groupRow(_ group: ToolGroup) -> NSView {
        let check = NSButton(checkboxWithTitle: group.displayName, target: self, action: #selector(groupToggled(_:)))
        check.font = UI.font(.callout, weight: .medium)
        check.identifier = NSUserInterfaceItemIdentifier(group.rawValue)
        check.setAccessibilityIdentifier("computer-use-group-\(group.rawValue)")
        check.setAccessibilityLabel("Computer Use tool group: \(group.displayName)")
        groupChecks[group] = check
        let column = UI.vstack([check], spacing: 1)
        column.addArrangedSubview(indented(UI.wrapLabel(group.detail, width: width - 20, style: .caption1)))
        if let note = group.riskNote {
            column.addArrangedSubview(indented(UI.wrapLabel(note, width: width - 20, style: .caption1, color: .systemRed)))
        }
        return column
    }

    /// Description lines hang under the checkbox title, not under the box.
    private func indented(_ content: NSView) -> NSView {
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return UI.hstack([gap, content], spacing: 0, alignment: .top)
    }

    /// Replaces the text of a wrapping label and keeps its style when the appearance changes.
    private func setWrapped(_ label: NSTextField, _ text: String, style: NSFont.TextStyle = .callout, color: NSColor = .labelColor) {
        let make = { UI.styled(text, font: UI.font(style), color: color, joinWords: true) }
        if let live = label as? LiveLabel { live.restyle = make }
        label.setLive(attributed: make())
    }

    // MARK: state

    func refresh(state: ModuleState) {
        lastState = state
        let config = manager.settings.computerUse
        let enabled = manager.settings.isEnabled(.computerUse)

        for (group, check) in groupChecks { check.state = config.isEnabled(group) ? .on : .off }
        if portField.currentEditor() == nil { portField.stringValue = "\(config.port)" }

        let plannedURL = ComputerUseLAN.urls(mode: config.listenMode, bindAddress: config.bindAddress, port: config.port).first ?? "-"
        lanCheck.state = config.listenMode == .lan ? .on : .off
        lanBox.isHidden = config.listenMode != .lan
        if config.listenMode == .lan { refreshLAN(config: config, state: state) }
        switch state {
        case .running:
            if module.activeMode == .lan {
                setWrapped(endpointLabel, "Address: \(module.endpoint) · Only computers on the same private network can connect (TLS). Do not expose the port to the internet.")
            } else {
                setWrapped(endpointLabel, "Address: \(module.endpoint) · Opens only inside this Mac (expose it externally only through a tunnel).")
            }
        case .needsPermission:
            setWrapped(endpointLabel, "The server is not open (permission required). Address: \(plannedURL)")
        case .failed:
            setWrapped(endpointLabel, "The server is not open (error). Address: \(plannedURL)")
        case .off:
            setWrapped(endpointLabel, enabled ? "Waiting for the server to start. Address: \(plannedURL)" : "Off, so the port is closed. When on, it opens at \(plannedURL).")
        }

        // Permission guidance: only the missing ones.
        var missing: [OSPermission] = []
        if case .needsPermission = state { missing = module.missingPermissions }
        permissionRow.isHidden = missing.isEmpty && !isNeedsPermission(state)
        for (permission, button) in permissionButtons { button.isHidden = !missing.contains(permission) }

        emergencyButton.isEnabled = module.isRunning

        // Rebuild the key rows only when something visible changed.
        let records = module.keys.records
        let signature = records.map { "\($0.id)|\($0.label)|\($0.lastUsedAt.map { "\($0.timeIntervalSince1970)" } ?? "-")" }.joined(separator: ";")
        if signature != keyListSignature {
            keyListSignature = signature
            rebuildKeyList(records)
        }
        renderLog()
    }

    private func isNeedsPermission(_ state: ModuleState) -> Bool {
        if case .needsPermission = state { return true }
        return false
    }

    private func rebuildKeyList(_ records: [APIKeyRecord]) {
        for row in keyList.arrangedSubviews { keyList.removeArrangedSubview(row); row.removeFromSuperview() }
        if records.isEmpty {
            keyList.addArrangedSubview(UI.wrapLabel("No keys have been issued. Without a key, all requests are refused (401).", width: width, style: .callout))
            return
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        for record in records {
            let name = UI.label(record.label, style: .callout, weight: .semibold)
            let used = record.lastUsedAt.map { formatter.string(from: $0) } ?? "never used"
            let info = UI.label("Created \(formatter.string(from: record.createdAt)) · Last used \(used)", style: .caption1, color: UI.secondaryText)
            let reissue = NSButton(title: "Reissue", target: self, action: #selector(reissueClicked(_:)))
            reissue.identifier = NSUserInterfaceItemIdentifier(record.id)
            reissue.setAccessibilityLabel("Reissue key \(record.label)")
            let revoke = NSButton(title: "Revoke", target: self, action: #selector(revokeClicked(_:)))
            revoke.identifier = NSUserInterfaceItemIdentifier(record.id)
            revoke.setAccessibilityLabel("Revoke key \(record.label)")
            let text = UI.vstack([name, info], spacing: 1)
            let row = UI.hstack([text, UI.spacer(), reissue, revoke], spacing: 8)
            row.widthAnchor.constraint(equalToConstant: width).isActive = true
            keyList.addArrangedSubview(row)
        }
    }

    private func renderLog() {
        let entries = module.callLog.entries.suffix(10).reversed()
        if entries.isEmpty { setWrapped(logLabel, "No calls yet.", style: .caption1, color: UI.secondaryText); return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = entries.map { entry -> String in
            var line = "\(formatter.string(from: entry.time))  \(entry.tool)  [\(entry.keyLabel)]"
            if entry.highRisk { line += "  high-risk" }
            if entry.outcome == .denied { line += "  denied" } else if entry.outcome == .error { line += "  error" }
            return line
        }
        setWrapped(logLabel, lines.joined(separator: "\n"), style: .caption1, color: UI.secondaryText)
    }

    // MARK: actions

    @objc private func groupToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let group = ToolGroup(rawValue: raw) else { return }
        let on = sender.state == .on
        if on && group.isHighRisk && !confirmHighRisk(group) {
            sender.state = .off
            return
        }
        manager.setComputerUse { $0.setEnabled(group, on) }
        settingsChanged?()
    }

    private func confirmHighRisk(_ group: ToolGroup) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Turn on the “\(group.displayName)” tool group?"
        alert.informativeText = (group.riskNote ?? "") + "\nIf an API key leaks, this Mac can be controlled right away. Turn it on only when you need it and turn it off when you are done."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Turn On")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func portApplyClicked() {
        let text = portField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = Int(text), ComputerUseSettings.isValidPort(port) else {
            portMessage.attributedStringValue = UI.notice("The port must be a number between 1024 and 65535.", tint: .systemOrange, style: .callout)
            portMessage.isHidden = false
            return
        }
        portMessage.isHidden = true
        manager.setComputerUse { $0.port = port }
        settingsChanged?()
    }

    @objc private func lanToggled(_ sender: NSButton) {
        let turnOn = sender.state == .on
        if turnOn {
            let risky = manager.settings.computerUse.enabledToolGroups.filter { $0.isHighRisk }.map { $0.displayName }
            var detail = "Computers on the same network (private addresses behind the router) will be able to connect to this Mac’s port over TLS. Tools cannot be used without an API key, but if a key leaks, this Mac can be controlled from inside that network. Do not turn it on on public Wi-Fi. The macOS firewall may ask whether to allow incoming connections."
            if !risky.isEmpty { detail += "\nHigh-risk groups currently on: " + risky.joined(separator: ", ") }
            guard confirm("Turn on LAN mode?", detail, "Turn On") else { sender.state = .off; return }
        }
        if !turnOn { previousFingerprint = nil }
        manager.setComputerUse { $0.listenMode = turnOn ? .lan : .localOnly }
        settingsChanged?()
    }

    @objc private func copyURLClicked(_ sender: NSButton) {
        if let url = sender.identifier?.rawValue { copyPlain(url) }
    }

    @objc private func copyFingerprintClicked() {
        guard let identity = module.tlsIdentity else { return }
        copyPlain(identity.fingerprintDisplay)
    }

    @objc private func copyPEMClicked() {
        guard let identity = module.tlsIdentity else { return }
        copyPlain(identity.pem)
    }

    @objc private func regenerateClicked() {
        guard confirm("Regenerate the TLS certificate?", "The fingerprint will change, so clients that are connected now should not connect again until they check the new fingerprint. If the server is on, it restarts.", "Regenerate") else { return }
        previousFingerprint = module.tlsIdentity?.fingerprint ?? ComputerUseTLS.load()?.fingerprint
        ComputerUseTLS.removeAll()
        settingsChanged?()
        refresh(state: lastState)
    }

    @objc private func sleepToggled(_ sender: NSButton) {
        ComputerUseLANPrefs.preventSleep = sender.state == .on
        settingsChanged?()
    }

    @objc private func bonjourToggled(_ sender: NSButton) {
        ComputerUseLANPrefs.advertiseBonjour = sender.state == .on
        settingsChanged?()
    }

    @objc private func openFirewallClicked() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Firewall") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPaneClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let permission = OSPermission(rawValue: raw) else { return }
        openPermissionPane?(permission)
    }

    @objc private func recheckClicked() { recheckPermissions?() }
    @objc private func emergencyClicked() { emergencyStop?() }

    @objc private func createKeyClicked() {
        do {
            let issued = try module.keys.create(label: newKeyField.stringValue)
            newKeyField.stringValue = ""
            keyMessage.isHidden = true
            refresh(state: lastState)
            reveal(issued, title: "New key “\(issued.record.label)”")
        } catch {
            showKeyProblem(error)
        }
    }

    @objc private func reissueClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let record = module.keys.records.first(where: { $0.id == id }) else { return }
        guard confirm("Reissue key “\(record.label)”?", "The existing key stops working immediately. The new key is shown only once.", "Reissue") else { return }
        do {
            let issued = try module.keys.reissue(id: id)
            refresh(state: lastState)
            reveal(issued, title: "Reissued key “\(issued.record.label)”")
        } catch {
            showKeyProblem(error)
        }
    }

    @objc private func revokeClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let record = module.keys.records.first(where: { $0.id == id }) else { return }
        guard confirm("Revoke key “\(record.label)”?", "Clients using this key are refused immediately (401).", "Revoke") else { return }
        if !module.keys.revoke(id: id) {
            keyMessage.attributedStringValue = UI.notice("Could not revoke the key. Check that the key file can be written.", tint: .systemRed, style: .callout)
            keyMessage.isHidden = false
        }
        refresh(state: lastState)
    }

    private func showKeyProblem(_ error: Error) {
        var text = "Could not create the key."
        switch error as? APIKeyError {
        case .some(.invalidLabel): text = "The key name must be 1 to \(APIKeyStore.maxLabelLength) characters."
        case .some(.tooManyKeys): text = "At most \(APIKeyStore.maxActiveKeys) keys are allowed. Revoke keys you no longer use."
        case .some(.persistFailed): text = "The key file could not be saved, so no key was created."
        default: break
        }
        keyMessage.attributedStringValue = UI.notice(text, tint: .systemOrange, style: .callout)
        keyMessage.isHidden = false
    }

    private func confirm(_ title: String, _ detail: String, _ action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The only place the plaintext key is ever visible. It is not stored; closing the dialog drops it.
    private func reveal(_ issued: IssuedKey, title: String) {
        let alert = NSAlert()
        alert.messageText = "\(title) was created"
        alert.informativeText = "This key is shown only once, now. You cannot see it again after closing, so copy it somewhere safe. Pass it to the MCP client in an Authorization: Bearer <key> header."
        let field = NSTextField(string: issued.token)
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = true
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: 0, y: 0, width: 420, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Copy and Close")
        alert.addButton(withTitle: "Close Without Copying")
        if alert.runModal() == .alertFirstButtonReturn {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(issued.token, forType: .string)
            let count = board.changeCount
            // Do not leave the key on the clipboard: clear it after a minute if nothing else was copied meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            }
        }
    }
}
