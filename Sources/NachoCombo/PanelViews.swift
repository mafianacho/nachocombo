import AppKit
import NachoComboCore

/// Level 1: the feature list.
final class ToolListView: NSView {
    private weak var host: PanelHost?
    private var rows: [ModuleID: ToolRowView] = [:]
    private let summary = UI.label("", style: .subheadline, color: UI.secondaryText)
    var onSelect: ((ModuleID) -> Void)?
    var firstRow: ToolRowView? { ModuleID.allCases.first.flatMap { rows[$0] } }

    init(host: PanelHost) {
        self.host = host
        super.init(frame: .zero)
        let inner = UI.panelWidth - 2 * UI.margin

        // The title says what this is; the count answers the one question of this screen: what is on right now.
        let title = UI.label("Nacho Combo", style: .headline, weight: .semibold)
        title.setAccessibilityIdentifier("panel-list-title")
        summary.alignment = .right
        summary.setAccessibilityIdentifier("panel-list-summary")
        let header = UI.hstack([title, UI.spacer(), summary], spacing: 8)
        header.widthAnchor.constraint(equalToConstant: inner).isActive = true

        var views: [NSView] = [header, UI.separator(width: inner)]
        for id in ModuleID.allCases {
            let row = ToolRowView(module: id)
            row.setAccessibilityIdentifier("panel-row-\(id.rawValue)")
            row.onActivate = { [weak self] id in self?.onSelect?(id) }
            row.widthAnchor.constraint(equalToConstant: inner).isActive = true
            rows[id] = row
            views.append(row)
        }
        views.append(UI.separator(width: inner))

        let settings = UI.linkButton("설정…", color: .labelColor, target: self, action: #selector(settingsClicked))
        settings.setAccessibilityIdentifier("panel-settings")
        settings.setAccessibilityHelp("설정 창을 엽니다")
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        let quit = UI.linkButton("종료", color: .labelColor, target: self, action: #selector(quitClicked))
        quit.setAccessibilityIdentifier("panel-quit")
        quit.setAccessibilityHelp("Nacho Combo를 종료하고 모든 도구를 정리합니다")
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
        var dots: [StatusDotKind] = []
        for id in ModuleID.allCases {
            let status = manager.status(of: id)
            dots.append(status.dot)
            rows[id]?.configure(status: status, pinned: manager.settings.isPinned(id),
                                shortcut: manager.settings.shortcut(for: id))
        }
        // Only tools that really run count as on; a tool still waiting for a permission is named separately.
        summary.setLive(ToolStatusPresentation.summary(of: dots))
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
    private let pinStatusOn = UI.label("상단바 고정됨", style: .callout, weight: .medium, color: .labelColor)
    private let pinStatusOff = UI.label("상단바에 고정되지 않음", style: .callout, weight: .medium, color: UI.secondaryText)
    private let pinButtonOn = LinkButton(title: "", target: nil, action: nil)
    private let pinButtonOff = LinkButton(title: "", target: nil, action: nil)
    private let shortcutLabel = UI.label("", style: .subheadline, color: UI.secondaryText)
    private var controls: [NSControl] = []
    private let inner = UI.panelWidth - 2 * UI.margin

    // tool specific
    private let collapseButton = NSButton(title: "숨김 아이콘 접기", target: nil, action: nil)
    private let cpuValue = UI.label("–", style: .callout, color: .labelColor)
    private let memValue = UI.label("–", style: .callout, color: .labelColor)
    private let rxValue = UI.label("–", style: .callout, color: .labelColor)
    private let txValue = UI.label("–", style: .callout, color: .labelColor)
    private let snapSegments = NSSegmentedControl(labels: SnapAction.allCases.map { $0.displayName },
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let snapPreview = SnapPreviewView()
    private let snapApply = NSButton(title: "적용", target: nil, action: nil)
    private let shelfButton = NSButton(title: "선반 열기", target: nil, action: nil)
    private let shelfCount = UI.label("", style: .subheadline, color: UI.secondaryText)
    private let captureButton = NSButton(title: "영역 캡처 시작", target: nil, action: nil)
    private let dimSlider = NSSlider(value: 0.5, minValue: FocusDimLogic.minimumIntensity,
                                     maxValue: FocusDimLogic.maximumIntensity, target: nil, action: nil)
    private let dimValue = UI.label("", style: .callout, color: .labelColor)
    private var snapSelection: SnapAction = .left

    init(module: ModuleID, host: PanelHost) {
        self.module = module
        self.host = host
        self.messageLabel = UI.wrapLabel("", width: UI.panelWidth - 2 * UI.margin, style: .subheadline, color: .labelColor)
        super.init(frame: .zero)

        // Back: standard chevron + title. Esc and Command-[ do the same.
        let back = UI.linkButton("모든 도구", symbol: "chevron.left", target: self, action: #selector(backClicked))
        back.setAccessibilityIdentifier("panel-back")
        back.setAccessibilityLabel("모든 도구로 돌아가기")
        back.setAccessibilityHelp("도구 목록으로 돌아갑니다. Esc 키로도 돌아갈 수 있습니다")
        back.keyEquivalent = "["
        back.keyEquivalentModifierMask = .command
        let top = UI.hstack([back, UI.spacer()], spacing: 8)

        let symbol = UI.symbolView(module.symbolName, size: 16)
        let name = UI.label(module.displayName, style: .title3, weight: .semibold)
        name.setAccessibilityIdentifier("panel-title")
        name.setAccessibilityRole(.staticText)
        dot.setAccessibilityElement(false)       // the state label below says the same in words
        stateLabel.setAccessibilityIdentifier("panel-state")
        stateLabel.setAccessibilityLabel("상태")
        let titleRow = UI.hstack([symbol, name, UI.spacer(), dot, stateLabel], spacing: 8)

        let enableLabel = UI.label("사용", style: .body)
        enableSwitch.target = self
        enableSwitch.action = #selector(enableToggled)
        enableSwitch.setAccessibilityLabel("\(module.displayName) 사용")
        enableSwitch.setAccessibilityIdentifier("panel-enable")
        let enableRow = UI.hstack([enableLabel, UI.spacer(), enableSwitch], spacing: 8)

        messageLabel.isHidden = true
        permissionRow.orientation = .horizontal
        permissionRow.spacing = 8
        permissionRow.isHidden = true
        permissionRow.translatesAutoresizingMaskIntoConstraints = false
        let openPane = NSButton(title: module == .captureFloat ? "화면 기록 설정 열기" : "손쉬운 사용 설정 열기",
                                target: self, action: #selector(openPaneClicked))
        openPane.setAccessibilityIdentifier("panel-open-permission")
        openPane.bezelStyle = .rounded
        openPane.keyEquivalent = "\r"          // the one thing to do on this screen
        let recheck = NSButton(title: "권한 다시 확인", target: self, action: #selector(recheckClicked))
        recheck.setAccessibilityIdentifier("panel-recheck")
        permissionRow.addArrangedSubview(openPane)
        permissionRow.addArrangedSubview(recheck)

        for (button, title) in [(pinButtonOn, "고정 해제"), (pinButtonOff, "상단바에 고정")] {
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
            label.setAccessibilityLabel("메뉴 막대 고정 상태")
        }

        let desc = UI.wrapLabel(module.toolSummary, width: inner, style: .callout)

        // Same order on every tool: use -> pin to the menu bar -> the tool's own controls -> permission guidance.
        var views: [NSView] = [top, titleRow, desc, enableRow, pinRow]
        views.append(contentsOf: toolSpecificViews())
        views.append(contentsOf: [messageLabel, permissionRow])
        shortcutLabel.setAccessibilityIdentifier("panel-shortcut")
        views.append(shortcutLabel)
        views.append(UI.separator(width: inner))
        let settingsLink = UI.linkButton("\(module.displayName) 설정…", symbol: "arrow.up.forward.square",
                                         symbolTrailing: true, target: self, action: #selector(settingsClicked))
        settingsLink.setAccessibilityIdentifier("panel-tool-settings")
        settingsLink.setAccessibilityLabel("\(module.displayName) 설정 열기")
        settingsLink.setAccessibilityHelp("설정 창을 엽니다")
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
            controls.append(collapseButton)
            let note = UI.wrapLabel("숨길 아이콘은 ⌘ 키를 누른 채 구분선(┊) 왼쪽으로 끌어 놓습니다.", width: inner)
            return [collapseButton, note]
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
            return [line("CPU", cpuValue), line("메모리", memValue), line("네트워크 내려받기", rxValue),
                    line("네트워크 올리기", txValue)]
        case .windowSnap:
            snapSegments.target = self
            snapSegments.action = #selector(snapSelected)
            snapSegments.selectedSegment = 0
            snapSegments.setAccessibilityIdentifier("panel-snap-choice")
            snapSegments.setAccessibilityLabel("배치 방식")
            snapApply.target = self
            snapApply.action = #selector(snapApplyClicked)
            snapApply.bezelStyle = .rounded
            snapApply.keyEquivalent = ""
            snapApply.setAccessibilityIdentifier("panel-snap-apply")
            snapApply.setAccessibilityLabel("선택한 배치 적용")
            snapPreview.action = .left
            snapPreview.setAccessibilityElement(true)
            snapPreview.setAccessibilityRole(.image)
            snapPreview.setAccessibilityLabel("배치 미리보기: 왼쪽 절반")
            controls.append(contentsOf: [snapSegments, snapApply])
            snapSegments.translatesAutoresizingMaskIntoConstraints = false
            snapSegments.segmentDistribution = .fillEqually
            snapSegments.widthAnchor.constraint(equalToConstant: inner).isActive = true
            let bottom = UI.hstack([snapPreview, UI.spacer(), snapApply], spacing: 12, alignment: .bottom)
            let note = UI.wrapLabel("직전에 쓰던 앱의 창이 대상입니다.", width: inner)
            return [snapSegments, bottom, note]
        case .fileShelf:
            shelfButton.target = self
            shelfButton.action = #selector(shelfClicked)
            shelfButton.setAccessibilityIdentifier("panel-shelf-toggle")
            controls.append(shelfButton)
            shelfCount.setAccessibilityIdentifier("panel-shelf-count")
            shelfCount.setAccessibilityLabel("선반 항목 수")
            return [UI.hstack([shelfButton, shelfCount], spacing: 12)]
        case .captureFloat:
            captureButton.target = self
            captureButton.action = #selector(captureClicked)
            captureButton.setAccessibilityIdentifier("panel-capture-start")
            controls.append(captureButton)
            let note = UI.wrapLabel("패널이 닫힌 뒤 영역을 고릅니다. 켤 때 화면 기록 권한 동의가 필요합니다.", width: inner)
            return [captureButton, note]
        case .focusDim:
            dimSlider.target = self
            dimSlider.action = #selector(dimChanged(_:))
            dimSlider.isContinuous = true
            dimSlider.setAccessibilityIdentifier("panel-dim-slider")
            dimSlider.setAccessibilityLabel("디밍 강도")
            dimValue.setAccessibilityIdentifier("panel-dim-value")
            dimValue.alignment = .right
            dimValue.translatesAutoresizingMaskIntoConstraints = false
            dimValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
            dimValue.font = UI.digitsFont(.callout)
            controls.append(dimSlider)
            let row = UI.hstack([UI.label("강도", style: .callout, color: UI.secondaryText), dimSlider, dimValue],
                                spacing: 12)       // slider takes the free width; the value ends at the right edge
            dimSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
            dimSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            return [row]
        }
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

        if let detail = status.detail {
            let extra = status.dot == .onNeedsSetup ? "\n허용하기 전까지 이 도구는 동작하지 않습니다." : ""
            messageLabel.setLive(attributed: UI.notice(detail + extra,
                                                      tint: status.dot == .onError ? .systemRed : .systemOrange))
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
        let showsPermission = status.dot == .onNeedsSetup && (module == .windowSnap || module == .captureFloat)
        permissionRow.isHidden = !showsPermission

        let pinned = manager.settings.isPinned(module)
        pinStatusOn.isHidden = !pinned
        pinButtonOn.isHidden = !pinned
        pinStatusOff.isHidden = pinned
        pinButtonOff.isHidden = pinned

        if let shortcut = manager.settings.shortcut(for: module) {
            shortcutLabel.setLive("이 화면 열기 단축키: \(shortcut.label)")
        } else {
            shortcutLabel.setLive("이 화면 열기 단축키: 미설정 (설정 창에서 지정)")
        }

        let running = status.dot == .on
        for c in controls { c.isEnabled = running }
        switch module {
        case .menuBar:
            let info = host.panelCollapse
            collapseButton.isEnabled = running && info.running
            collapseButton.title = info.collapsed ? "숨김 아이콘 펼치기" : "숨김 아이콘 접기"
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
            shelfButton.title = info.visible ? "선반 닫기" : "선반 열기"
            shelfCount.setLive(running ? "\(info.count)개 항목" : "")
        case .focusDim:
            if NSApp.currentEvent?.type != .leftMouseDragged { dimSlider.doubleValue = manager.settings.dimIntensity }
            let percent = Int((manager.settings.dimIntensity * 100).rounded())
            dimValue.textColor = running ? .labelColor : UI.tertiaryText
            dimValue.setLive("\(percent)%")
            dimSlider.setAccessibilityValueDescription("\(percent)%")
        case .windowSnap:
            snapPreview.alphaValue = running ? 1.0 : 0.35      // a preview of something that cannot run stays quiet
        default: break
        }
        // Off: say why the controls are dimmed - on the dimmed controls only, not on the whole screen. When the tool is
        // on but not running, the notice already says why in words.
        for c in controls { c.toolTip = (!running && !enabled) ? "켜면 사용할 수 있습니다" : nil }
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
    @objc private func recheckClicked() { host?.panelRecheck(module) }
    @objc private func collapseClicked() { host?.panelToggleCollapse() }
    @objc private func shelfClicked() { host?.panelToggleShelf() }
    @objc private func captureClicked() { host?.panelStartCapture() }
    @objc private func dimChanged(_ sender: NSSlider) { host?.panelSetDim(sender.doubleValue) }
    @objc private func snapSelected() {
        let i = max(0, snapSegments.selectedSegment)
        snapSelection = SnapAction.allCases[i]
        snapPreview.action = snapSelection
    }
    @objc private func snapApplyClicked() { host?.panelApplySnap(snapSelection) }
}
