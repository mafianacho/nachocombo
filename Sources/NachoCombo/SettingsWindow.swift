import AppKit
import NachoComboCore

/// One window for every gadget: an independent switch, a description, the *actual* state
/// (꺼짐 / 동작 중 / 권한 필요 / 오류) and, when needed, the permission guidance for that gadget.
/// A switch being on never implies "running": the state label always comes from the module's start result.
final class SettingsWindowController: NSObject {
    private let manager: ModuleManager
    private let organizer: MenuBarOrganizerModule
    let window: NSWindow

    private var switches: [ModuleID: NSSwitch] = [:]
    private var statusLabels: [ModuleID: NSTextField] = [:]
    private var messageLabels: [ModuleID: NSTextField] = [:]
    private var permissionRows: [ModuleID: NSStackView] = [:]
    private var dots: [ModuleID: StatusDotView] = [:]
    private var pinChecks: [ModuleID: NSButton] = [:]
    private var recorders: [ModuleID: ShortcutRecorderButton] = [:]
    private var clearButtons: [ModuleID: NSButton] = [:]
    private var shortcutMessages: [ModuleID: NSTextField] = [:]
    private let summaryLabel = UI.label("", style: .headline, weight: .semibold)

    private let collapseButton = NSButton(title: "숨김 아이콘 접기", target: nil, action: nil)
    private let shelfButton = NSButton(title: "선반 열기", target: nil, action: nil)
    private let captureButton = NSButton(title: "영역 캡처 시작", target: nil, action: nil)
    private let releaseDimButton = NSButton(title: "디밍 즉시 해제", target: nil, action: nil)
    private let dimSlider = NSSlider(value: 0.5, minValue: FocusDimLogic.minimumIntensity,
                                     maxValue: FocusDimLogic.maximumIntensity, target: nil, action: nil)
    private let dimLabel = UI.label("", style: .callout, color: UI.secondaryText)
    private let dimValueLabel = UI.label("", style: .callout, color: .labelColor)

    var openAccessibilitySettings: (() -> Void)?
    var recheckPermission: (() -> Void)?
    var openScreenRecordingSettings: (() -> Void)?
    var recheckScreenRecording: (() -> Void)?
    var toggleShelf: (() -> Void)?
    var startCapture: (() -> Void)?
    var releaseDim: (() -> Void)?
    var dimIntensityChanged: ((Double) -> Void)?
    var shelfVisible: (() -> Bool)?
    var quitApp: (() -> Void)?
    var pinChanged: ((ModuleID, Bool) -> Void)?
    /// Returns an error message when the shortcut was refused (policy or OS), nil when it was saved/cleared.
    var shortcutRecorded: ((ModuleID, ToolShortcut?) -> String?)?
    var recordingChanged: ((Bool) -> Void)?

    private static let cardWidth: CGFloat = 480
    private static let cardInset: CGFloat = 16
    private static var innerWidth: CGFloat { cardWidth - 2 * cardInset }

    private static let hints: [ModuleID: String] = [
        .menuBar: "구분선(┊) 왼쪽의 아이콘을 접습니다. 숨길 아이콘은 ⌘ 키를 누른 채 구분선 왼쪽으로 끌어 놓습니다. 권한 불필요.",
        .systemMonitor: "메뉴 막대에 CPU·메모리·네트워크 속도를 표시합니다(2초 간격). 권한 불필요.",
        .windowSnap: "⌃⌥← 왼쪽 절반 · ⌃⌥→ 오른쪽 절반 · ⌃⌥↩ 최대화. 켜면 손쉬운 사용 권한 동의가 필요합니다.",
        .fileShelf: "파일·이미지·텍스트를 선반에 끌어다 놓고 다른 앱으로 다시 끌어냅니다(복사만, 원본 이동·삭제 없음). \(ShelfModule.hotKeyLabel)로 열기/닫기. 권한 불필요.",
        .captureFloat: "\(CaptureFloatModule.hotKeyLabel)로 영역을 선택해 캡처하고 다른 창 위에 고정합니다. 이동·크기 조절·복사·저장·고정 해제·닫기 지원. 켜면 화면 기록 권한 동의가 필요합니다.",
        .focusDim: "활성 창만 밝게 두고 배경 창을 어둡게 합니다(클릭은 그대로 통과). \(FocusDimModule.hotKeyLabel)로 즉시 해제. 권한 불필요.",
    ]

    init(manager: ModuleManager, organizer: MenuBarOrganizerModule) {
        self.manager = manager
        self.organizer = organizer
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Nacho Combo"
        window.isReleasedWhenClosed = false   // closing the window never stops a running gadget
        build()
        refresh()
    }

    var isVisible: Bool { window.isVisible }

    /// Debug readout of the accessibility elements of the settings window (`ctl a11y settings`).
    var accessibilityTree: [[String: String]] {
        window.contentView.map { UI.accessibilityTree(of: $0) } ?? []
    }

    func show() {
        refresh()
        if !window.isVisible {
            // Fit small screens (e.g. 1280×800 with menu bar and Dock): the card list scrolls when it does not fit.
            let available = (NSScreen.main?.visibleFrame.height ?? 800) - 44
            window.setContentSize(NSSize(width: 540, height: min(660, max(420, available))))
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: layout

    private func build() {
        let content = NSView()
        window.contentView = content

        // No second app title (the window title already says it): the first line answers what is on right now.
        summaryLabel.setAccessibilityIdentifier("settings-summary")
        let subtitle = UI.wrapLabel(
            "각 도구를 따로 켜고 끕니다. 끄면 그 도구의 감시·단축키·오버레이가 모두 중지됩니다. 이 창을 닫아도 켜 둔 도구는 계속 동작합니다.",
            width: 500, style: .callout)
        let header = UI.vstack([summaryLabel, subtitle], spacing: 4)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        for id in ModuleID.allCases { list.addArrangedSubview(makeCard(for: id)) }

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let quit = NSButton(title: "Nacho Combo 종료", target: self, action: #selector(quitClicked))
        quit.setAccessibilityIdentifier("quit-app")
        quit.setAccessibilityHelp("모든 도구의 감시·단축키·오버레이를 정리하고 앱을 종료합니다")
        let footnote = UI.wrapLabel(
            "종료하면 모든 도구가 정리됩니다. 설정은 자동 저장되어 다음 실행 때 복원됩니다. 메뉴 막대의 NC ▸ 설정…에서 이 창을 다시 열 수 있습니다.",
            width: 330, style: .subheadline)
        let footer = NSStackView(views: [footnote, quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
    }

    private func makeCard(for id: ModuleID) -> NSView {
        let width = SettingsWindowController.innerWidth

        // Header row: symbol, name, state (dot + words), the switch.
        let symbol = UI.symbolView(id.symbolName, size: 16, tint: UI.secondaryText)
        let name = UI.label(id.displayName, style: .headline, weight: .semibold)
        name.setAccessibilityElement(false)       // the switch carries the name as its accessibility label

        let toggle = NSSwitch()
        toggle.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        toggle.target = self
        toggle.action = #selector(toggled(_:))
        toggle.setAccessibilityLabel("\(id.displayName) 사용")
        toggle.setAccessibilityIdentifier("toggle-\(id.rawValue)")
        switches[id] = toggle

        let status = UI.label("", style: .callout, weight: .medium, color: UI.secondaryText)
        status.alignment = .left                 // the word sits right next to its dot
        status.translatesAutoresizingMaskIntoConstraints = false
        status.widthAnchor.constraint(equalToConstant: 72).isActive = true       // the dot keeps its place for every state
        status.setAccessibilityIdentifier("status-\(id.rawValue)")
        status.setAccessibilityLabel("\(id.displayName) 상태")
        statusLabels[id] = status

        let dot = StatusDotView()
        dot.setAccessibilityRole(.image)
        dots[id] = dot

        // Dot and state words are one fixed-width group: the dot always sits right next to its words, in every card.
        let state = UI.hstack([dot, status], spacing: 6)
        state.widthAnchor.constraint(equalToConstant: StatusDotView.width + 6 + 72).isActive = true
        let top = UI.hstack([symbol, name, UI.spacer(), state, toggle], spacing: 8)
        top.setCustomSpacing(12, after: state)
        top.widthAnchor.constraint(equalToConstant: width).isActive = true

        let hint = UI.wrapLabel(SettingsWindowController.hints[id] ?? "", width: width, style: .callout)

        let message = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        message.isHidden = true
        messageLabels[id] = message

        let card = UI.vstack([top, hint, message], spacing: 8)
        card.setCustomSpacing(4, after: top)

        // Permission guidance lives with the gadget that needs it.
        switch id {
        case .windowSnap:
            let row = permissionButtons(for: id, open: #selector(openAccessibilityClicked), title: "손쉬운 사용 설정 열기",
                                        recheck: #selector(recheckAccessibilityClicked))
            permissionRows[id] = row
            card.addArrangedSubview(row)
        case .captureFloat:
            let row = permissionButtons(for: id, open: #selector(openScreenClicked), title: "화면 기록 설정 열기",
                                        recheck: #selector(recheckScreenClicked))
            permissionRows[id] = row
            card.addArrangedSubview(row)
        default: break
        }

        // The tool's own actions.
        switch id {
        case .menuBar:
            collapseButton.target = self
            collapseButton.action = #selector(collapseClicked)
            collapseButton.setAccessibilityIdentifier("collapse-button")
            card.addArrangedSubview(actionRow([collapseButton]))
        case .fileShelf:
            shelfButton.target = self
            shelfButton.action = #selector(shelfClicked)
            shelfButton.setAccessibilityIdentifier("shelf-button")
            card.addArrangedSubview(actionRow([shelfButton]))
        case .captureFloat:
            captureButton.target = self
            captureButton.action = #selector(captureClicked)
            captureButton.setAccessibilityIdentifier("capture-button")
            card.addArrangedSubview(actionRow([captureButton]))
        case .focusDim:
            dimSlider.target = self
            dimSlider.action = #selector(dimChanged(_:))
            dimSlider.isContinuous = true
            dimSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            dimSlider.setAccessibilityIdentifier("dim-intensity")
            dimSlider.setAccessibilityLabel("디밍 강도")
            releaseDimButton.target = self
            releaseDimButton.action = #selector(releaseDimClicked)
            releaseDimButton.setAccessibilityIdentifier("dim-release")
            dimValueLabel.alignment = .right
            dimValueLabel.font = UI.digitsFont(.callout)
            dimValueLabel.translatesAutoresizingMaskIntoConstraints = false
            dimValueLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
            dimValueLabel.setAccessibilityIdentifier("dim-value")
            card.addArrangedSubview(actionRow([dimLabel, dimSlider, dimValueLabel, releaseDimButton]))
        default: break
        }

        // Menu bar pin and tool-open shortcut: both are separate from ON/OFF.
        let pin = NSButton(checkboxWithTitle: "메뉴 막대에 고정", target: self, action: #selector(pinToggled(_:)))
        pin.font = UI.font(.callout)
        pin.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        pin.setAccessibilityIdentifier("pin-\(id.rawValue)")
        pin.setAccessibilityLabel("\(id.displayName) 메뉴 막대에 고정")
        pin.setAccessibilityHelp("고정하면 아이콘을 눌러 이 도구 화면으로 바로 이동합니다. 켜기·끄기와는 별개입니다")
        pin.toolTip = "아이콘을 누르면 이 도구 화면으로 바로 이동"
        pinChecks[id] = pin

        let recorder = ShortcutRecorderButton()
        recorder.font = UI.font(.callout)
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.widthAnchor.constraint(equalToConstant: 168).isActive = true      // "해제" keeps its place in every card
        recorder.setAccessibilityIdentifier("shortcut-\(id.rawValue)")
        recorder.setAccessibilityLabel("\(id.displayName) 화면 열기 단축키")
        recorder.setAccessibilityHelp("누른 뒤 새 단축키를 입력합니다. Esc로 취소합니다")
        recorder.onRecordingChange = { [weak self] on in self?.recordingChanged?(on) }
        recorder.onRecord = { [weak self] shortcut in self?.record(id, shortcut) }
        recorders[id] = recorder
        let clear = NSButton(title: "해제", target: self, action: #selector(clearShortcutClicked(_:)))
        clear.font = UI.font(.callout)
        clear.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
        clear.setAccessibilityIdentifier("shortcut-clear-\(id.rawValue)")
        clear.setAccessibilityLabel("\(id.displayName) 화면 열기 단축키 해제")
        clearButtons[id] = clear
        let shortcutTitle = UI.label("화면 열기 단축키", style: .callout, color: UI.secondaryText)
        shortcutTitle.setAccessibilityElement(false)
        let shortcutMessage = UI.wrapLabel("", width: width, style: .callout, color: .labelColor)
        shortcutMessage.isHidden = true
        shortcutMessage.setAccessibilityIdentifier("shortcut-message-\(id.rawValue)")
        shortcutMessages[id] = shortcutMessage

        let lastBefore = card.arrangedSubviews.last ?? hint
        card.addArrangedSubview(pin)
        card.setCustomSpacing(12, after: lastBefore)      // the tool's controls and the shared pin/shortcut settings read as two groups
        card.addArrangedSubview(actionRow([shortcutTitle, recorder, clear]))
        card.addArrangedSubview(shortcutMessage)

        let surface = CardView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: SettingsWindowController.cardInset),
            card.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -SettingsWindowController.cardInset),
            card.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
            card.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -14),
            surface.widthAnchor.constraint(equalToConstant: SettingsWindowController.cardWidth),
        ])
        return surface
    }

    private func permissionButtons(for id: ModuleID, open: Selector, title: String, recheck: Selector) -> NSStackView {
        let openButton = NSButton(title: title, target: self, action: open)
        let recheckButton = NSButton(title: "권한 다시 확인", target: self, action: recheck)
        openButton.setAccessibilityLabel("\(id.displayName) \(title)")
        recheckButton.setAccessibilityLabel("\(id.displayName) 권한 다시 확인")
        openButton.setAccessibilityIdentifier("permission-open-\(id.rawValue)")
        recheckButton.setAccessibilityIdentifier("permission-recheck-\(id.rawValue)")
        let row = NSStackView(views: [openButton, recheckButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.isHidden = true
        return row
    }

    private func actionRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    // MARK: state

    func refresh() {
        var dotKinds: [StatusDotKind] = []
        for id in ModuleID.allCases {
            let enabled = manager.settings.isEnabled(id)
            let state = manager.states[id] ?? .off
            switches[id]?.state = enabled ? .on : .off

            var text = state.label
            var color = UI.secondaryText
            var message: NSAttributedString?
            switch state {
            case .running:
                color = .labelColor
            case .needsPermission(let m):
                color = .labelColor
                message = UI.notice(m + "\n허용하기 전까지 이 도구는 동작하지 않습니다.", tint: .systemOrange, style: .callout)
            case .failed(let m):
                color = .labelColor
                message = UI.notice(m, tint: .systemRed, style: .callout)
            case .off:
                break
            }
            // A switch that is on while the module is not running must never read as "동작 중".
            if enabled, case .off = state { text = "시작 대기" }
            dots[id]?.kind = manager.status(of: id).dot
            dots[id]?.setAccessibilityLabel("\(id.displayName) 상태: \(manager.status(of: id).accessibilityText)")
            pinChecks[id]?.state = manager.settings.isPinned(id) ? .on : .off
            if recorders[id]?.isRecording != true { recorders[id]?.shortcut = manager.settings.shortcut(for: id) }
            clearButtons[id]?.isEnabled = manager.settings.shortcut(for: id) != nil      // nothing to clear when unset
            dotKinds.append(manager.status(of: id).dot)
            statusLabels[id]?.stringValue = text
            statusLabels[id]?.textColor = color
            if let message = message {
                messageLabels[id]?.attributedStringValue = message
                messageLabels[id]?.isHidden = false
            } else {
                messageLabels[id]?.stringValue = ""
                messageLabels[id]?.isHidden = true
            }
            if let row = permissionRows[id] {
                if case .needsPermission = state { row.isHidden = false } else { row.isHidden = true }
            }
        }
        summaryLabel.stringValue = "\(ModuleID.allCases.count)개 도구 중 " + ToolStatusPresentation.summary(of: dotKinds)
        let running: (ModuleID) -> Bool = { self.manager.states[$0] == .running }
        collapseButton.isEnabled = organizer.isRunning
        collapseButton.title = organizer.collapsed ? "숨김 아이콘 펼치기" : "숨김 아이콘 접기"
        shelfButton.isEnabled = running(.fileShelf)
        shelfButton.title = (shelfVisible?() ?? false) ? "선반 닫기" : "선반 열기"
        captureButton.isEnabled = running(.captureFloat)
        releaseDimButton.isEnabled = running(.focusDim)
        dimSlider.doubleValue = manager.settings.dimIntensity
        let percent = Int((manager.settings.dimIntensity * 100).rounded())
        let dimRunning = running(.focusDim)
        dimSlider.isEnabled = dimRunning          // off: the slider is dimmed, not blue and inviting
        dimLabel.stringValue = "강도"
        dimLabel.textColor = dimRunning ? UI.secondaryText : UI.tertiaryText
        dimValueLabel.textColor = dimRunning ? .labelColor : UI.tertiaryText
        dimValueLabel.stringValue = "\(percent)%"
        dimSlider.setAccessibilityValueDescription("\(percent)%")
    }

    // MARK: actions

    @objc private func toggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let id = ModuleID(rawValue: raw) else { return }
        manager.setEnabled(id, sender.state == .on)
    }
    @objc private func pinToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = ModuleID(rawValue: raw) else { return }
        pinChanged?(id, sender.state == .on)
    }
    @objc private func clearShortcutClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = ModuleID(rawValue: raw) else { return }
        _ = shortcutRecorded?(id, nil)
        shortcutMessages[id]?.isHidden = true
    }
    private func record(_ id: ModuleID, _ shortcut: ToolShortcut) {
        let issue = shortcutRecorded?(id, shortcut)
        if let issue = issue {
            shortcutMessages[id]?.attributedStringValue = UI.notice("\(shortcut.label): \(issue)", tint: .systemOrange, style: .callout)
            shortcutMessages[id]?.isHidden = false
        } else {
            shortcutMessages[id]?.stringValue = ""
            shortcutMessages[id]?.isHidden = true
        }
    }
    @objc private func collapseClicked() { organizer.setCollapsed(!organizer.collapsed) }
    @objc private func shelfClicked() { toggleShelf?() }
    @objc private func captureClicked() { startCapture?() }
    @objc private func releaseDimClicked() { releaseDim?() }
    @objc private func dimChanged(_ sender: NSSlider) { dimIntensityChanged?(sender.doubleValue) }
    @objc private func openAccessibilityClicked() { openAccessibilitySettings?() }
    @objc private func recheckAccessibilityClicked() { recheckPermission?() }
    @objc private func openScreenClicked() { openScreenRecordingSettings?() }
    @objc private func recheckScreenClicked() { recheckScreenRecording?() }
    @objc private func quitClicked() { quitApp?() }
}
