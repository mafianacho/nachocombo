import AppKit
import NachoComboCore

/// Bartender-style menu bar tidying within what macOS allows.
///
/// OS constraint (verified design, see docs/MENUBAR-CONSTRAINTS.md): macOS has no public API to
/// enumerate, hide or reorder status items owned by other apps. The supported technique is a
/// divider status item whose length is stretched to push every item on its left out of view.
/// The user chooses what is hidden by Cmd-dragging icons to the left of the divider.
/// No permission is required.
final class MenuBarOrganizerModule: NSObject, FeatureModule {
    let id = ModuleID.menuBar
    private let expandedDividerLength: CGFloat = NSStatusItem.variableLength
    private let collapsedDividerLength: CGFloat = 10_000

    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private(set) var collapsed: Bool
    private(set) var toggleCount = 0
    var onCollapsedChange: ((Bool) -> Void)?

    init(initiallyCollapsed: Bool) { collapsed = initiallyCollapsed }

    var isRunning: Bool { toggleItem != nil }

    func start() -> ModuleState {
        guard toggleItem == nil else { return .running }
        // First created = right-most: the toggle stays visible, the divider sits to its left.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.toolTip = "Nacho Combo: 숨김 아이콘 접기/펼치기"
        let divider = NSStatusBar.system.statusItem(withLength: expandedDividerLength)
        divider.button?.toolTip = "Nacho Combo 구분선: 이 선 왼쪽 아이콘이 접힘 대상 (⌘ 드래그로 이동)"
        toggleItem = toggle
        dividerItem = divider
        render()
        return .running
    }

    func stop() {
        if let item = toggleItem { NSStatusBar.system.removeStatusItem(item) }
        if let item = dividerItem { NSStatusBar.system.removeStatusItem(item) }
        toggleItem = nil
        dividerItem = nil
    }

    /// Re-create the pair so the divider is again the left-most of our own items.
    func rebuild() {
        guard isRunning else { return }
        stop()
        _ = start()
    }

    func setCollapsed(_ value: Bool) {
        guard collapsed != value else { return }
        collapsed = value
        toggleCount += 1
        render()
        onCollapsedChange?(value)
    }

    @objc private func toggleClicked() { setCollapsed(!collapsed) }

    private func render() {
        toggleItem?.button?.title = collapsed ? "›" : "‹"
        if collapsed {
            dividerItem?.length = collapsedDividerLength
            dividerItem?.button?.title = ""
        } else {
            dividerItem?.length = expandedDividerLength
            dividerItem?.button?.title = "┊"
        }
    }

    var diagnostics: [String: String] {
        [
            "statusItems": "\((toggleItem != nil ? 1 : 0) + (dividerItem != nil ? 1 : 0))",
            "collapsed": "\(collapsed)",
            "dividerLength": dividerItem.map { "\(Int($0.length))" } ?? "-",
            "toggleCount": "\(toggleCount)",
        ]
    }
}
