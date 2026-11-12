import AppKit
import NachoComboCore
import UniformTypeIdentifiers

// Nacho Pet ▸ Settings ▸ Selection Bar (mockup scene sel-settings): on/off, buttons (drag to reorder, untick to hide;
// Ask Nacho always shown), when the bar shows, the search engine, and the apps it never shows in.

protocol PetSelectionSettingsHost: AnyObject {
    var selectionSettings: PetSelectionBarSettings { get }
    func updateSelection(_ change: (inout PetSelectionBarSettings) -> Void)
    var selectionAccessibilityGranted: Bool { get }
    /// Switching the bar on: asks for Accessibility when it is not allowed yet (never at launch).
    func selectionSwitchedOn()
}

/// A bordered list (`.olist`).
final class PetSettingsList: NSView {
    let stack = NSStackView()
    init(width: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateLayer()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.borderColor = NSColor.separatorColor.cgColor }

    func row(_ views: [NSView], width: CGFloat) -> NSStackView {
        let r = UI.hstack(views, spacing: 6)
        r.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        r.widthAnchor.constraint(equalToConstant: width).isActive = true
        return r
    }
}

/// The ⋮⋮ handle of a button row: drag up or down to move the row; the menu has Move Up / Move Down too.
final class PetGripView: NSTextField {
    var onDrag: ((CGFloat) -> Void)?
    var onDrop: ((CGFloat) -> Void)?
    var onMove: ((Int) -> Void)?
    private var start: NSPoint?

    static func make() -> PetGripView {
        let g = PetGripView(labelWithString: "⋮⋮")
        g.setUp()
        return g
    }

    private func setUp() {
        textColor = .tertiaryLabelColor
        toolTip = "Drag to reorder"
        setAccessibilityLabel("Reorder")
        let m = NSMenu()
        m.addItem(withTitle: "Move Up", action: #selector(up), keyEquivalent: "").target = self
        m.addItem(withTitle: "Move Down", action: #selector(down), keyEquivalent: "").target = self
        menu = m
    }

    @objc private func up() { onMove?(-1) }
    @objc private func down() { onMove?(1) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) { if let s = start { onDrag?(event.locationInWindow.y - s.y) } }
    override func mouseUp(with event: NSEvent) {
        if let s = start { onDrop?(event.locationInWindow.y - s.y) }
        start = nil
    }
}

final class PetSelectionSettingsSection: NSObject {
    let view = NSStackView()
    private weak var host: PetSelectionSettingsHost?
    private let width: CGFloat
    private let toggle = NSSwitch()
    private let permission = NSStackView()
    private let columns = NSStackView()
    private let buttons: PetSettingsList
    private let apps: PetSettingsList
    private let delayPopup = NSPopUpButton()
    private let enginePopup = NSPopUpButton()
    private let columnWidth: CGFloat
    private var rowHeight: CGFloat = 26

    init(host: PetSelectionSettingsHost, width: CGFloat) {
        self.host = host
        self.width = width
        // Two columns as in the design when there is room, else one under the other.
        columnWidth = width >= 600 ? (width - 24) / 2 : width
        buttons = PetSettingsList(width: columnWidth)
        apps = PetSettingsList(width: columnWidth)
        super.init()
        build()
        refresh()
    }

    private func h3(_ s: String) -> NSTextField { UI.label(s, style: .subheadline, weight: .semibold) }

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("pet-selection-bar")

        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityLabel("Selection Bar")
        toggle.setAccessibilityIdentifier("pet-selection-toggle")
        view.addArrangedSubview(UI.hstack([UI.sectionTitle("Selection Bar"), UI.spacer(), toggle], spacing: 8))
        view.arrangedSubviews.last?.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.addArrangedSubview(UI.wrapLabel("Select text in any app and a small bar appears next to it: copy, search, translate, summarize, explain, ask Nacho. "
                                             + "Nothing is sent until you press a button, and you see what will be sent first. Reading the selection needs "
                                             + "Accessibility; it is asked only when you switch this on.", width: width, style: .caption1, color: UI.secondaryText))
        permission.orientation = .horizontal
        permission.spacing = 8
        let open = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibility))
        permission.setViews([UI.attentionNote("Accessibility is not allowed yet, so the bar cannot read selections.", width: width - 200,
                                              style: .caption1), open], in: .leading)
        view.addArrangedSubview(permission)

        let left = UI.vstack([], spacing: 6)
        left.addArrangedSubview(h3("Buttons (drag to reorder)"))
        left.addArrangedSubview(buttons)
        left.addArrangedSubview(h3("Show the bar"))
        for d in PetSelectionDelay.allCases { delayPopup.addItem(withTitle: d.displayName) }
        delayPopup.target = self
        delayPopup.action = #selector(delayChanged)
        left.addArrangedSubview(delayPopup)
        left.addArrangedSubview(UI.wrapLabel("Or only while holding ⌘ when you let go of the mouse.", width: columnWidth, style: .caption1, color: UI.secondaryText))
        left.addArrangedSubview(h3("Search with"))
        for e in PetSearchEngine.allCases { enginePopup.addItem(withTitle: e.displayName) }
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        left.addArrangedSubview(enginePopup)
        left.addArrangedSubview(UI.wrapLabel("Opens in your default browser. Also Naver or DuckDuckGo.", width: columnWidth, style: .caption1, color: UI.secondaryText))

        let right = UI.vstack([], spacing: 6)
        right.addArrangedSubview(h3("Never in these apps"))
        right.addArrangedSubview(apps)
        let add = NSButton(title: "Add App…", target: self, action: #selector(addApp))
        add.setAccessibilityIdentifier("pet-selection-add-app")
        right.addArrangedSubview(add)
        right.addArrangedSubview(UI.wrapLabel("Password fields and secure input are always skipped. Terminals are skipped because they often show keys; "
                                              + "untick one to allow it. Banking sites cannot be told apart by app: add the browser if you need to. "
                                              + "Selected text is never written to logs.", width: columnWidth, style: .caption1, color: UI.secondaryText))

        columns.orientation = width >= 600 ? .horizontal : .vertical
        columns.alignment = .top
        columns.spacing = width >= 600 ? 24 : 14
        columns.setViews([left, right], in: .leading)
        view.addArrangedSubview(columns)
    }

    func refresh() {
        guard let host = host else { return }
        let s = host.selectionSettings
        toggle.state = s.enabled ? .on : .off
        permission.isHidden = !s.enabled || host.selectionAccessibilityGranted
        columns.alphaValue = s.enabled ? 1 : 0.55
        if let i = PetSelectionDelay.allCases.firstIndex(of: s.delay) { delayPopup.selectItem(at: i) }
        if let i = PetSearchEngine.allCases.firstIndex(of: s.searchEngine) { enginePopup.selectItem(at: i) }
        renderButtons(s)
        renderApps(s)
    }

    private func renderButtons(_ s: PetSelectionBarSettings) {
        buttons.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, a) in s.order.enumerated() {
            let grip = PetGripView.make()
            let check = NSButton(checkboxWithTitle: a.settingsTitle, target: self, action: #selector(buttonTicked(_:)))
            check.tag = i
            check.state = s.hidden.contains(a) ? .off : .on
            let row = buttons.row([grip, check, UI.spacer()], width: columnWidth)
            grip.onDrag = { [weak row] dy in row?.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: dy)) }
            grip.onDrop = { [weak self, weak row] dy in
                row?.layer?.setAffineTransform(.identity)
                guard let self = self else { return }
                self.move(i, by: Int((-dy / self.rowHeight).rounded()))
            }
            grip.onMove = { [weak self] d in self?.move(i, by: d) }
            row.wantsLayer = true
            buttons.stack.addArrangedSubview(row)
        }
        let ask = NSButton(checkboxWithTitle: PetSelectionAction.ask.settingsTitle, target: nil, action: nil)
        ask.state = .on
        ask.isEnabled = false
        let spacer = NSTextField(labelWithString: "⋮⋮")
        spacer.textColor = .clear
        buttons.stack.addArrangedSubview(buttons.row([spacer, ask, UI.spacer(), UI.label("always shown", style: .caption1, color: UI.tertiaryText)],
                                                     width: columnWidth))
        buttons.stack.layoutSubtreeIfNeeded()
        if let first = buttons.stack.arrangedSubviews.first { rowHeight = max(20, first.fittingSize.height) }
    }

    private func renderApps(_ s: PetSelectionBarSettings) {
        apps.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let builtIn: (String) -> NSTextField = { UI.label($0, style: .caption1, color: UI.tertiaryText) }
        for b in PetSelectionExclusions.builtIns {
            if b.canAllow {
                let check = NSButton(checkboxWithTitle: b.name, target: self, action: #selector(builtInTicked(_:)))
                check.identifier = NSUserInterfaceItemIdentifier(b.id)
                check.state = s.allowedBuiltIns.contains(b.id) ? .off : .on
                check.toolTip = "Ticked: the bar never shows in \(b.name)"
                apps.stack.addArrangedSubview(apps.row([check, UI.spacer(), builtIn("built in · can be allowed")], width: columnWidth))
            } else {
                apps.stack.addArrangedSubview(apps.row([UI.label(b.name, style: .callout), UI.spacer(), builtIn("built in")], width: columnWidth))
            }
        }
        for (i, a) in s.excludedApps.enumerated() {
            let remove = NSButton(title: "Remove", target: self, action: #selector(removeApp(_:)))
            remove.isBordered = false
            remove.contentTintColor = .linkColor
            remove.attributedTitle = NSAttributedString(string: "Remove", attributes: [.foregroundColor: NSColor.linkColor,
                                                                                         .font: NSFont.preferredFont(forTextStyle: .caption1)])
            remove.tag = i
            remove.setAccessibilityLabel("Remove \(a.name)")
            apps.stack.addArrangedSubview(apps.row([UI.label(a.name, style: .callout), UI.spacer(), remove], width: columnWidth))
        }
    }

    private func move(_ index: Int, by delta: Int) {
        guard delta != 0 else { return }
        host?.updateSelection { s in
            guard s.order.indices.contains(index) else { return }
            let a = s.order.remove(at: index)
            s.order.insert(a, at: min(max(0, index + delta), s.order.count))
        }
        refresh()
    }

    @objc private func toggled() {
        let on = toggle.state == .on
        host?.updateSelection { $0.enabled = on; $0.introAnswered = true; if on { $0.snoozedUntil = nil } }
        if on { host?.selectionSwitchedOn() }
        refresh()
    }

    @objc private func openAccessibility() { PetSelectionAX.openAccessibilitySettings() }

    @objc private func delayChanged() {
        let d = PetSelectionDelay.allCases[max(0, delayPopup.indexOfSelectedItem)]
        host?.updateSelection { $0.delay = d }
    }

    @objc private func engineChanged() {
        let e = PetSearchEngine.allCases[max(0, enginePopup.indexOfSelectedItem)]
        host?.updateSelection { $0.searchEngine = e }
    }

    @objc private func buttonTicked(_ sender: NSButton) {
        guard let s = host?.selectionSettings, s.order.indices.contains(sender.tag) else { return }
        let a = s.order[sender.tag]
        let show = sender.state == .on
        host?.updateSelection { x in
            x.hidden.removeAll { $0 == a }
            if !show { x.hidden.append(a) }
        }
        refresh()
    }

    @objc private func builtInTicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let excluded = sender.state == .on
        host?.updateSelection { x in
            x.allowedBuiltIns.removeAll { $0 == id }
            if !excluded { x.allowedBuiltIns.append(id) }
        }
        refresh()
    }

    @objc private func removeApp(_ sender: NSButton) {
        let i = sender.tag
        host?.updateSelection { x in if x.excludedApps.indices.contains(i) { x.excludedApps.remove(at: i) } }
        refresh()
    }

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps the selection bar should never show in"
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.compactMap { url -> PetExcludedApp? in
            guard let b = Bundle(url: url), let id = b.bundleIdentifier else { return nil }
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return PetExcludedApp(bundleID: id, name: name)
        }
        host?.updateSelection { x in x.excludedApps += picked }
        refresh()
    }
}
