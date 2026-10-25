import AppKit
import NachoComboCore

/// Menu bar tidying within what macOS allows.
///
/// OS constraint (verified design, see docs/MENUBAR-CONSTRAINTS.md): macOS has no public API to enumerate, hide or
/// reorder status items owned by other apps. The supported technique is a divider status item whose length is
/// stretched to push every item on its left out of view. The user chooses what is hidden by ⌘-dragging icons across
/// the divider. A second, optional divider further left marks an "always hidden" section that stays folded even when
/// the rest is expanded (⌥-click the toggle to see it). No permission is required.
final class MenuBarOrganizerModule: NSObject, FeatureModule {
    let id = ModuleID.menuBar
    var optionsProvider: () -> GadgetOptions = { .defaults }

    private var toggleItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var alwaysItem: NSStatusItem?
    private var hoverView: HoverView?
    private(set) var collapsed: Bool
    /// The always-hidden section is shown too (⌥-click or the shortcut), until the next collapse.
    private(set) var showingAlwaysHidden = false
    private(set) var toggleCount = 0
    /// macOS did not let the divider grow, so collapsing cannot hide anything (seen on macOS 27 betas).
    private(set) var dividerFailed = false
    private var expandedAt = Date()
    private var lastPointerInBar = Date.distantPast
    private var expandedByHover = false
    private var rehideTimer: Timer?
    private var hoverWork: DispatchWorkItem?
    var onCollapsedChange: ((Bool) -> Void)?
    var onStateChange: (() -> Void)?

    init(initiallyCollapsed: Bool) { collapsed = initiallyCollapsed }

    var isRunning: Bool { toggleItem != nil }
    var hasAlwaysHiddenSection: Bool { alwaysItem != nil }

    /// Wide enough to push everything off the widest screen, within the 10,000 pt cap macOS puts on a status item.
    private var hideLength: CGFloat {
        let widest = NSScreen.screens.map { $0.frame.width }.max() ?? 2000
        return max(500, min(widest * 2, 10_000))
    }

    func start() -> ModuleState {
        guard toggleItem == nil else { return .running }
        // Created right to left: the toggle stays right-most and visible, then the divider, then the always-hidden one.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleClicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        toggle.button?.setAccessibilityLabel("Show or hide menu bar icons")
        let divider = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        divider.button?.toolTip = "Nacho Combo divider: icons left of it fold away (⌘-drag icons across it)"
        divider.button?.setAccessibilityLabel("Menu bar divider")
        toggleItem = toggle
        dividerItem = divider
        if optionsProvider().alwaysHiddenSection {
            let always = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            always.button?.toolTip = "Nacho Combo always-hidden divider: icons left of it stay hidden (⌥-click ‹ to see them)"
            always.button?.setAccessibilityLabel("Always-hidden divider")
            alwaysItem = always
        }
        if let button = toggle.button {
            let hover = HoverView(frame: button.bounds)
            hover.autoresizingMask = [.width, .height]
            hover.onEnter = { [weak self] in self?.pointerEnteredToggle() }
            hover.onExit = { [weak self] in self?.hoverWork?.cancel() }
            button.addSubview(hover)
            hoverView = hover
        }
        render()
        if !collapsed { scheduleRehide() }
        return .running
    }

    func stop() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        hoverWork?.cancel()
        hoverView?.removeFromSuperview()
        hoverView = nil
        for item in [toggleItem, dividerItem, alwaysItem].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        toggleItem = nil
        dividerItem = nil
        alwaysItem = nil
        showingAlwaysHidden = false
    }

    /// Re-create the items so the dividers are again the left-most of our own items.
    func rebuild() {
        guard isRunning else { return }
        stop()
        _ = start()
    }

    /// Options changed: add or remove the always-hidden divider, restart the rehide countdown.
    func applyOptions() {
        guard isRunning else { return }
        if optionsProvider().alwaysHiddenSection != hasAlwaysHiddenSection { rebuild() } else if !collapsed { scheduleRehide() }
    }

    func setCollapsed(_ value: Bool) {
        if value { showingAlwaysHidden = false }
        guard collapsed != value else { render(); return }
        collapsed = value
        toggleCount += 1
        if !value { expandedAt = Date(); lastPointerInBar = Date() }
        if value { expandedByHover = false }
        render()
        if value { rehideTimer?.invalidate(); rehideTimer = nil } else { scheduleRehide() }
        onCollapsedChange?(value)
        onStateChange?()
    }

    /// Expands everything, the always-hidden section included (until the next collapse).
    func showAlwaysHidden() {
        guard isRunning else { return }
        showingAlwaysHidden = hasAlwaysHiddenSection
        expandedByHover = false
        if collapsed { setCollapsed(false) } else { expandedAt = Date(); render(); scheduleRehide(); onStateChange?() }
    }

    @objc private func toggleClicked() {
        let event = NSApp.currentEvent
        if event?.modifierFlags.contains(.option) == true || event?.type == .rightMouseUp {
            if showingAlwaysHidden { setCollapsed(true) } else { showAlwaysHidden() }
            return
        }
        expandedByHover = false
        setCollapsed(!collapsed)
    }

    // MARK: hover and auto-collapse

    private func pointerEnteredToggle() {
        guard optionsProvider().expandOnHover, collapsed else { return }
        hoverWork?.cancel()
        // A short dwell, so passing over the item on the way elsewhere does not expand it.
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.collapsed, self.isRunning else { return }
            self.expandedByHover = true
            self.setCollapsed(false)
            self.expandedByHover = true
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// While expanded, a light poll decides when to fold the icons away again: after the chosen delay, but never while
    /// the pointer is in the menu bar (and right away once a hover-expanded bar is left).
    private func scheduleRehide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        let delay = optionsProvider().autoCollapseSeconds
        guard isRunning, !collapsed, delay > 0 || expandedByHover else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkRehide() }
        RunLoop.main.add(timer, forMode: .common)
        rehideTimer = timer
    }

    private func checkRehide() {
        guard isRunning, !collapsed else { rehideTimer?.invalidate(); rehideTimer = nil; return }
        let now = Date()
        if MenuBarOrganizerModule.pointerInMenuBar() { lastPointerInBar = now; return }
        let away = now.timeIntervalSince(lastPointerInBar)
        if expandedByHover && away > 1 { setCollapsed(true); return }
        let delay = Double(optionsProvider().autoCollapseSeconds)
        if delay > 0 && now.timeIntervalSince(expandedAt) >= delay && away > 1 { setCollapsed(true) }
    }

    static func pointerInMenuBar() -> Bool {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        return point.y >= screen.frame.maxY - NSStatusBar.system.thickness - 2
    }

    // MARK: drawing

    private func render() {
        let dividerColor = NSColor.secondaryLabelColor
        toggleItem?.button?.title = collapsed ? "›" : "‹"
        toggleItem?.button?.toolTip = collapsed
            ? "Nacho Combo: show hidden icons (⌥-click: also the always-hidden ones)"
            : "Nacho Combo: hide icons left of ┊"
        if collapsed {
            dividerItem?.length = hideLength
            dividerItem?.button?.title = ""
            alwaysItem?.length = NSStatusItem.variableLength
            alwaysItem?.button?.title = ""
        } else {
            dividerItem?.length = NSStatusItem.variableLength
            dividerItem?.button?.attributedTitle = NSAttributedString(string: "┊", attributes: [.foregroundColor: dividerColor])
            if showingAlwaysHidden {
                alwaysItem?.length = NSStatusItem.variableLength
                alwaysItem?.button?.attributedTitle = NSAttributedString(
                    string: "┊", attributes: [.foregroundColor: dividerColor.withAlphaComponent(0.45)])
            } else {
                alwaysItem?.length = hideLength
                alwaysItem?.button?.title = ""
            }
        }
        if collapsed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.verifyDivider() } }
    }

    /// The divider's window must have grown; if macOS kept it small, collapsing hides nothing, so say so and expand.
    private func verifyDivider() {
        guard isRunning, collapsed, let window = dividerItem?.button?.window else { return }
        let failed = window.frame.width < 100
        if failed != dividerFailed {
            dividerFailed = failed
            onStateChange?()
        }
        if failed { setCollapsed(false) }
    }

    var diagnostics: [String: String] {
        [
            "statusItems": "\([toggleItem, dividerItem, alwaysItem].compactMap { $0 }.count)",
            "collapsed": "\(collapsed)",
            "dividerLength": dividerItem.map { "\(Int($0.length))" } ?? "-",
            "dividerWindowWidth": dividerItem?.button?.window.map { "\(Int($0.frame.width))" } ?? "-",
            "alwaysHiddenSection": "\(hasAlwaysHiddenSection)",
            "alwaysHiddenLength": alwaysItem.map { "\(Int($0.length))" } ?? "-",
            "showingAlwaysHidden": "\(showingAlwaysHidden)",
            "rehideTimer": "\(rehideTimer != nil)",
            "dividerFailed": "\(dividerFailed)",
            "toggleCount": "\(toggleCount)",
        ]
    }
}

/// Transparent overlay that reports the pointer entering / leaving a status item button (clicks pass through).
final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var area: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
