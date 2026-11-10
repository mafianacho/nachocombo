import AppKit
import NachoComboCore

/// Nacho Pet's Settings tab: account, server, what Nacho may do on this Mac, and the pet's place.
final class PetSettingsCard: NSObject {
    let view = NSStackView()
    private let module: NachoPetModule
    private let width: CGFloat
    private let account: NSTextField
    private let accountButton = NSButton(title: "Sign In", target: nil, action: nil)
    private let serverPopup = NSPopUpButton()
    private let customServer = NSTextField()
    private let customIssuer = NSTextField()
    private let customRow = NSStackView()
    private let serverNote: NSTextField
    private let controlCheck = NSButton(checkboxWithTitle: "Let Nacho snap windows and switch gadgets on this Mac",
                                        target: nil, action: nil)

    init(module: NachoPetModule, width: CGFloat) {
        self.module = module
        self.width = width
        account = UI.wrapLabel("", width: width - 120, style: .callout, color: .labelColor)
        serverNote = UI.wrapLabel("", width: width, style: .caption1, color: UI.secondaryText)
        super.init()
        build()
        refresh()
    }

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.translatesAutoresizingMaskIntoConstraints = false

        account.setAccessibilityIdentifier("pet-account")
        accountButton.target = self
        accountButton.action = #selector(accountClicked)
        accountButton.setAccessibilityIdentifier("pet-account-button")
        view.addArrangedSubview(UI.sectionTitle("Nacho Account"))
        view.addArrangedSubview(UI.hstack([account, UI.spacer(), accountButton], spacing: 8))

        view.addArrangedSubview(UI.sectionTitle("Server"))
        for mode in PetServerMode.allCases { serverPopup.addItem(withTitle: mode.displayName) }
        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)
        serverPopup.setAccessibilityIdentifier("pet-server")
        view.addArrangedSubview(serverPopup)
        customServer.placeholderString = "https://nacho.example.com"
        customIssuer.placeholderString = "https://auth.example.com/realms/nachotown"
        for f in [customServer, customIssuer] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: width - 80).isActive = true
        }
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyCustom))
        customRow.orientation = .vertical
        customRow.alignment = .leading
        customRow.spacing = 6
        customRow.setViews([customServer, UI.hstack([customIssuer, apply], spacing: 8)], in: .top)
        view.addArrangedSubview(customRow)
        view.addArrangedSubview(serverNote)

        view.addArrangedSubview(UI.sectionTitle("On This Mac"))
        controlCheck.target = self
        controlCheck.action = #selector(controlChanged)
        controlCheck.setAccessibilityIdentifier("pet-allow-control")
        view.addArrangedSubview(controlCheck)
        view.addArrangedSubview(UI.wrapLabel("Nacho can snap the front window (Window Snap's Accessibility permission) and switch other gadgets "
                                             + "on or off. Never Computer Use, never Nacho Pet itself, and never a gadget that still needs a permission.",
                                             width: width, style: .caption1, color: UI.secondaryText))
        let reset = NSButton(title: "Put Nacho Back in the Corner", target: self, action: #selector(resetClicked))
        reset.setAccessibilityIdentifier("pet-reset-position")
        view.addArrangedSubview(reset)
        view.addArrangedSubview(UI.wrapLabel("The Nacho character is © Mafianacho, all rights reserved: it is not part of the MIT-licensed source code "
                                             + "(see TRADEMARKS.md).",
                                             width: width, style: .caption1, color: UI.tertiaryText))
    }

    func refresh() {
        let st = module.state
        switch st.auth {
        case .signedIn:
            account.stringValue = "Signed in as \(st.chat.agentName == "나초" ? "your Nacho account" : st.chat.agentName) · \(module.statusText)"
            accountButton.title = "Sign Out"
        case .signingIn:
            account.stringValue = "Signing in in the browser sheet…"
            accountButton.title = "Sign In"
        case let .failed(m):
            account.stringValue = m
            accountButton.title = "Sign In"
        case .signedOut:
            account.stringValue = "Not signed in. Signing in opens auth.nachotown.com in a browser sheet; Nacho Combo never sees the password."
            accountButton.title = "Sign In"
        }
        let s = module.settings
        if let index = PetServerMode.allCases.firstIndex(of: s.serverMode) { serverPopup.selectItem(at: index) }
        customRow.isHidden = s.serverMode != .custom
        if customServer.currentEditor() == nil { customServer.stringValue = s.customServerURL }
        if customIssuer.currentEditor() == nil { customIssuer.stringValue = s.customIssuerURL }
        if let problem = s.validationProblem() {
            serverNote.stringValue = "⚠︎ " + problem
        } else {
            serverNote.stringValue = "\(s.endpoint?.base.absoluteString ?? "-") · login \(s.oidc?.issuer.absoluteString ?? "-")"
        }
        controlCheck.state = s.allowComboControl ? .on : .off
    }

    @objc private func accountClicked() {
        if module.state.auth == .signedIn { module.signOut() } else { module.openChat(); module.signIn() }
    }

    @objc private func serverChanged() {
        let mode = PetServerMode.allCases[max(0, serverPopup.indexOfSelectedItem)]
        module.update { $0.serverMode = mode }
        refresh()
    }

    @objc private func applyCustom() {
        let server = customServer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let issuer = customIssuer.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        module.update { $0.customServerURL = server; $0.customIssuerURL = issuer }
        refresh()
    }

    @objc private func controlChanged() {
        module.update { $0.allowComboControl = self.controlCheck.state == .on }
        refresh()
    }

    @objc private func resetClicked() { module.resetPosition() }
}
