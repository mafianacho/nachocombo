import AppKit
import NachoComboCore

/// The one card that says what to do for a missing permission, right under a gadget's header. Its steps follow what
/// the user really does (open the list, turn on Nacho Combo, come back), and the card follows them: waiting while
/// System Settings is in front, a restart for Screen Recording, a fresh start after an update.
enum PermissionCard {
    static func make(module: ModuleID, permission: GadgetPermission, stage: PermissionStage, host: GadgetHost,
                     width: CGFloat) -> NSView {
        let inner = width - 24
        let textWidth = inner - 30
        let app = GadgetPermission.settingsAppName()
        let pane = permission.paneName()
        let purpose = module.info.permissions.first { $0.permission == permission }?.purpose ?? ""

        let title: String
        let explainer: String
        let symbol: String
        switch stage {
        case .updated:
            title = "Allow \(permission.displayName) again after the update"
            explainer = "This copy of Nacho Combo is new, so macOS no longer trusts the old entry, even if its switch in "
                + "\(app) still looks on."
            symbol = permission.symbolName
        case .restartNeeded:
            title = "Turned on Nacho Combo in \(pane)?"
            explainer = "macOS applies it after Nacho Combo restarts. \(module.displayName) turns on again by itself"
                + (module == .captureFloat ? "; floats on screen close." : ".")
            symbol = "arrow.clockwise"
        default:
            title = "Allow \(permission.displayName) to start \(module.displayName)"
            explainer = "\(module.displayName) \(purpose). macOS allows that only after you turn it on yourself."
            symbol = permission.symbolName
        }

        let icon = UI.symbolView(symbol, size: 18, tint: DotPalette.orange)
        let titleLabel = UI.label(title, style: .callout, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("permission-card-title")
        let explainerLabel = UI.wrapLabel(explainer, width: textWidth, style: .subheadline)
        var column: [NSView] = [titleLabel, explainerLabel]

        let open = UI.pushButton("Open \(app)", primary: stage == .notAllowed, small: true) {
            host.gadgetOpenPermissionSettings(permission)
        }
        open.setAccessibilityIdentifier("permission-card-open")
        let askAgain = UI.pushButton("Ask Again", primary: stage == .updated || stage == .stillNotAllowed, small: true) {
            host.gadgetAskAgain(permission)
        }
        askAgain.setAccessibilityIdentifier("permission-card-ask")

        switch stage {
        case .notAllowed, .waiting, .stillNotAllowed:
            let first: StepNumberView.State = stage == .notAllowed ? .current : .done
            let second: StepNumberView.State = stage == .notAllowed ? .todo : .current
            column.append(steps([
                step(1, first, "Open \(permission.path())", nil, open, width: textWidth),
                step(2, second, "Turn on Nacho Combo in the list",
                     "Not in the list? Click + and choose Nacho Combo in Applications.", nil, width: textWidth,
                     highlighted: stage != .notAllowed),
                step(3, .todo, "Come back here", "Nacho Combo notices the change by itself.", nil, width: textWidth),
            ]))
            column.append(footer(stage: stage, host: host, module: module, askAgain: askAgain, width: textWidth))
        case .updated:
            column.append(steps([
                step(1, .current, "Ask macOS again", "Removes the old entry and adds this copy to the list.", askAgain,
                     width: textWidth),
                step(2, .todo, "Turn on Nacho Combo in \(pane)", nil, open, width: textWidth),
                step(3, .todo, "Come back here", "Nacho Combo notices the change by itself.", nil, width: textWidth),
            ]))
            column.append(UI.wrapLabel("Why: Nacho Combo is not signed with an Apple Developer ID, so macOS treats every "
                                       + "update as a new app.", width: textWidth, style: .footnote, color: UI.tertiaryText))
        case .restartNeeded:
            let restart = UI.pushButton("Restart Nacho Combo", primary: true, small: true) { host.gadgetRelaunch() }
            restart.setAccessibilityIdentifier("permission-card-restart")
            let later = UI.pushButton("Not Yet", small: true) { host.gadgetForgetSettingsVisit(permission) }
            let again = ClosureButton(title: "Open \(app) Again") { host.gadgetOpenPermissionSettings(permission) }
            again.isBordered = false
            again.attributedTitle = NSAttributedString(string: "Open \(app) Again", attributes: [
                .foregroundColor: UI.linkText, .font: UI.font(.subheadline)])
            let buttons = UI.hstack([restart, later, UI.spacer(), again], spacing: 8)
            buttons.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
            column.append(buttons)
        case .allowed:
            break
        }

        let content = UI.vstack(column, spacing: 4)
        content.setCustomSpacing(10, after: explainerLabel)
        let card = TintedCardView(tone: .attention, content: UI.hstack([icon, content], spacing: 8, alignment: .top))
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel(title)
        card.setAccessibilityIdentifier("permission-card-\(stage.rawValue)")
        return card
    }

    /// A few seconds of "done" after the permission arrived, then the card goes away.
    static func allowed(module: ModuleID, permission: GadgetPermission, width: CGFloat) -> NSView {
        let icon = UI.symbolView("checkmark.circle.fill", size: 16, tint: DotPalette.green)
        let text = UI.label("\(permission.displayName) allowed. \(module.displayName) is running.", style: .callout,
                            weight: .semibold)
        let card = TintedCardView(tone: .success, content: UI.hstack([icon, text, UI.spacer()], spacing: 8), padding: 10)
        card.widthAnchor.constraint(equalToConstant: width).isActive = true
        card.setAccessibilityIdentifier("permission-card-allowed")
        return card
    }

    private static func steps(_ rows: [NSView]) -> NSView { UI.vstack(rows, spacing: 2) }

    private static func step(_ number: Int, _ state: StepNumberView.State, _ title: String, _ detail: String?,
                             _ button: NSButton?, width: CGFloat, highlighted: Bool = false) -> NSView {
        let badge = StepNumberView(number)
        badge.state = state
        // insets 6 + 6, number, 8 to the text, 8 to the spacer, 8 + the button when there is one.
        let buttonWidth = button.map { $0.fittingSize.width + 8 } ?? 0
        let textWidth = width - 12 - StepNumberView.size - 16 - buttonWidth - 2
        let titleLabel = UI.label(title, style: .callout, weight: state == .current ? .semibold : .regular)
        titleLabel.textColor = state == .done ? UI.secondaryText : .labelColor
        var text: [NSView] = [titleLabel]
        if let detail = detail { text.append(UI.wrapLabel(detail, width: textWidth, style: .subheadline)) }
        var views: [NSView] = [badge, UI.vstack(text, spacing: 1), UI.spacer()]
        if let button = button { views.append(button) }
        let line = UI.hstack(views, spacing: 8)
        line.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        guard highlighted else { return line }
        // The step to do now sits on its own surface.
        let surface = CardView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            line.topAnchor.constraint(equalTo: surface.topAnchor),
            line.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        return surface
    }

    private static func footer(stage: PermissionStage, host: GadgetHost, module: ModuleID, askAgain: NSButton,
                               width: CGFloat) -> NSView {
        let separator = UI.separator(width: width)
        switch stage {
        case .waiting:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
            spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
            // Reduce Motion: the words say it, the circle stays still.
            if !UI.reduceMotion { spinner.startAnimation(nil) }
            let text = UI.label("Waiting for Nacho Combo to be turned on…", style: .subheadline, weight: .semibold,
                                color: UI.attentionText)
            let check = UI.pushButton("Check Now", small: true) { host.gadgetRecheck(module) }
            let line = UI.hstack([spinner, text, UI.spacer(), check], spacing: 7)
            line.widthAnchor.constraint(equalToConstant: width).isActive = true
            return UI.vstack([separator, line], spacing: 8)
        case .stillNotAllowed:
            let note = UI.attentionNote("Still not allowed. If Nacho Combo already looks on in the list, macOS is holding "
                                        + "an old entry: Ask Again removes it and asks macOS once more.",
                                        width: width - askAgain.fittingSize.width - 16)
            let line = UI.hstack([note, UI.spacer(), askAgain], spacing: 8, alignment: .top)
            line.widthAnchor.constraint(equalToConstant: width).isActive = true
            return UI.vstack([separator, line], spacing: 8)
        default:
            let dot = StatusDotView()
            dot.kind = .onNeedsSetup
            let text = UI.label("Not allowed", style: .subheadline, weight: .semibold, color: UI.attentionText)
            text.setAccessibilityIdentifier("permission-card-status")
            let line = UI.hstack([dot, text, UI.spacer()], spacing: 5)
            line.widthAnchor.constraint(equalToConstant: width).isActive = true
            return UI.vstack([separator, line], spacing: 8)
        }
    }
}
