import AppKit
import NachoComboCore

final class SettingsWindowController: NSObject {
    private let manager: ModuleManager
    private let organizer: MenuBarOrganizerModule
    private let window: NSWindow
    private var checkboxes: [ModuleID: NSButton] = [:]
    private var statusLabels: [ModuleID: NSTextField] = [:]
    private let permissionBox = NSStackView()
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let collapseButton = NSButton(title: "숨김 아이콘 접기", target: nil, action: nil)
    private var monitorItemBoxes: [MonitorItem: NSButton] = [:]
    private let publicIPBox = NSButton(checkboxWithTitle: "네트워크 패널을 열 때 공용 IP 자동 조회 (cloudflare.com에 요청)", target: nil, action: nil)
    var openAccessibilitySettings: (() -> Void)?
    var recheckPermission: (() -> Void)?
    var onMonitorSettingsChanged: ((MonitorSettings) -> Void)?

    init(manager: ModuleManager, organizer: MenuBarOrganizerModule) {
        self.manager = manager
        self.organizer = organizer
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Nacho Combo"
        window.isReleasedWhenClosed = false
        build()
        refresh()
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Nacho Combo")
        title.font = NSFont.boldSystemFont(ofSize: 18)
        root.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString: "기능을 각각 켜고 끌 수 있습니다. 끄면 해당 기능의 감시·이벤트·단축키가 모두 중지됩니다.")
        subtitle.textColor = .secondaryLabelColor
        root.addArrangedSubview(subtitle)

        let hints: [ModuleID: String] = [
            .menuBar: "구분선(┊) 왼쪽의 아이콘을 접습니다. 숨길 아이콘은 ⌘ 키를 누른 채 구분선 왼쪽으로 끌어 놓습니다. 권한 불필요.",
            .systemMonitor: "메뉴 막대에 CPU·메모리·디스크·네트워크·센서를 표시하고, 클릭하면 그래프·프로세스·온도·팬·전력 패널을 엽니다(2초 간격). 권한 불필요.",
            .windowSnap: "⌃⌥← 왼쪽 절반 · ⌃⌥→ 오른쪽 절반 · ⌃⌥↩ 최대화. 손쉬운 사용 권한 필요.",
        ]
        for id in ModuleID.allCases {
            let box = NSStackView()
            box.orientation = .vertical
            box.alignment = .leading
            box.spacing = 3
            let check = NSButton(checkboxWithTitle: id.displayName, target: self, action: #selector(toggled(_:)))
            check.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            check.identifier = NSUserInterfaceItemIdentifier(id.rawValue)
            checkboxes[id] = check
            let hint = NSTextField(wrappingLabelWithString: hints[id] ?? "")
            hint.textColor = .secondaryLabelColor
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.preferredMaxLayoutWidth = 470
            let status = NSTextField(wrappingLabelWithString: "")
            status.font = NSFont.systemFont(ofSize: 11)
            status.preferredMaxLayoutWidth = 470
            statusLabels[id] = status
            box.addArrangedSubview(check)
            box.addArrangedSubview(hint)
            box.addArrangedSubview(status)
            if id == .menuBar {
                collapseButton.target = self
                collapseButton.action = #selector(collapseClicked)
                box.addArrangedSubview(collapseButton)
            }
            if id == .systemMonitor {
                let itemsRow = NSStackView()
                itemsRow.orientation = .horizontal
                itemsRow.spacing = 10
                let label = NSTextField(labelWithString: "메뉴 막대 항목:")
                label.font = NSFont.systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                itemsRow.addArrangedSubview(label)
                for item in MonitorItem.allCases {
                    let check = NSButton(checkboxWithTitle: item.displayName, target: self, action: #selector(monitorItemToggled(_:)))
                    check.font = NSFont.systemFont(ofSize: 11)
                    check.identifier = NSUserInterfaceItemIdentifier(item.rawValue)
                    monitorItemBoxes[item] = check
                    itemsRow.addArrangedSubview(check)
                }
                box.addArrangedSubview(itemsRow)
                publicIPBox.font = NSFont.systemFont(ofSize: 11)
                publicIPBox.target = self
                publicIPBox.action = #selector(publicIPToggled(_:))
                box.addArrangedSubview(publicIPBox)
            }
            root.addArrangedSubview(box)
        }

        permissionBox.orientation = .vertical
        permissionBox.alignment = .leading
        permissionBox.spacing = 6
        permissionLabel.textColor = .systemRed
        permissionLabel.preferredMaxLayoutWidth = 470
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.addArrangedSubview(NSButton(title: "손쉬운 사용 설정 열기", target: self, action: #selector(openSettings)))
        buttons.addArrangedSubview(NSButton(title: "권한 다시 확인", target: self, action: #selector(recheck)))
        permissionBox.addArrangedSubview(permissionLabel)
        permissionBox.addArrangedSubview(buttons)
        root.addArrangedSubview(permissionBox)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 520, height: max(420, root.fittingSize.height)))
    }

    func refresh() {
        for id in ModuleID.allCases {
            let state = manager.states[id] ?? .off
            checkboxes[id]?.state = manager.settings.isEnabled(id) ? .on : .off
            var text = "상태: \(state.label)"
            var color = NSColor.secondaryLabelColor
            switch state {
            case .running: color = .systemGreen
            case .needsPermission, .failed: color = .systemRed
            case .off: break
            }
            if case .failed(let m) = state { text += " — \(m)" }
            statusLabels[id]?.stringValue = text
            statusLabels[id]?.textColor = color
        }
        let monitorSettings = manager.settings.monitorSettings
        for (item, check) in monitorItemBoxes { check.state = monitorSettings.isShown(item) ? .on : .off }
        publicIPBox.state = monitorSettings.publicIPLookup ? .on : .off
        collapseButton.isEnabled = organizer.isRunning
        collapseButton.title = organizer.collapsed ? "숨김 아이콘 펼치기" : "숨김 아이콘 접기"
        if case .needsPermission(let message) = manager.states[.windowSnap] ?? .off {
            permissionLabel.stringValue = "⚠︎ " + message + "\n허용하기 전까지 창 배치 단축키는 동작하지 않습니다."
            permissionBox.isHidden = false
        } else {
            permissionBox.isHidden = true
        }
    }

    /// Debug aid (`ctl settings snapshot <png>`).
    func writeSnapshot(to url: URL) -> Bool {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = ModuleID(rawValue: raw) else { return }
        manager.setEnabled(id, sender.state == .on)
    }
    @objc private func monitorItemToggled(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let item = MonitorItem(rawValue: raw) else { return }
        var value = manager.settings.monitorSettings
        value.setShown(item, sender.state == .on)
        onMonitorSettingsChanged?(value)
    }
    @objc private func publicIPToggled(_ sender: NSButton) {
        var value = manager.settings.monitorSettings
        value.publicIPLookup = sender.state == .on
        onMonitorSettingsChanged?(value)
    }
    @objc private func collapseClicked() { organizer.setCollapsed(!organizer.collapsed) }
    @objc private func openSettings() { openAccessibilitySettings?() }
    @objc private func recheck() { recheckPermission?() }
}
