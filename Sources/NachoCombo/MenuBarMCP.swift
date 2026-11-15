import AppKit
import ApplicationServices
import NachoComboCore

/// App side of the `menubar_*` tools (NACHO-148): answers `MenuBarControlling` from the organizer on the main thread and
/// reads other apps' status items through Accessibility (`AXExtrasMenuBar`, public API, read only).
/// Never blocks the calling thread: every answer comes back through `done`.
final class MenuBarToolController: MenuBarControlling {
    private let organizer: () -> MenuBarOrganizerModule?
    private let options: () -> GadgetOptions
    private let accessibilityGranted: () -> Bool
    private let readQueue = DispatchQueue(label: "nachocombo.menubar.ax", qos: .userInitiated)

    init(organizer: @escaping () -> MenuBarOrganizerModule?, options: @escaping () -> GadgetOptions,
         accessibilityGranted: @escaping () -> Bool) {
        self.organizer = organizer
        self.options = options
        self.accessibilityGranted = accessibilityGranted
    }

    private func snapshot() -> MenuBarState {
        let o = options()
        guard let organizer = organizer() else { return MenuBarState(running: false, collapsed: false) }
        return MenuBarState(running: organizer.isRunning, collapsed: organizer.collapsed,
                            showingAlwaysHidden: organizer.showingAlwaysHidden,
                            hasAlwaysHiddenSection: organizer.hasAlwaysHiddenSection,
                            autoCollapseSeconds: o.autoCollapseSeconds, expandOnHover: o.expandOnHover,
                            dividerFailed: organizer.dividerFailed)
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// The divider is verified 0.3 s after a fold; wait a little longer so `divider_failed` is known when we answer.
    private func answerAfterFold(done: @escaping (MenuBarState) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            done(self.snapshot())
        }
    }

    func state(done: @escaping (MenuBarState) -> Void) {
        onMain { [weak self] in
            guard let self = self else { return }
            done(self.snapshot())
        }
    }

    func setCollapsed(_ collapsed: Bool, done: @escaping (MenuBarState) -> Void) {
        onMain { [weak self] in
            guard let self = self, let organizer = self.organizer(), organizer.isRunning else { return done(self?.snapshot() ?? MenuBarState(running: false, collapsed: false)) }
            organizer.setCollapsed(collapsed)
            if collapsed { self.answerAfterFold(done: done) } else { done(self.snapshot()) }
        }
    }

    func tidy(done: @escaping (MenuBarState) -> Void) {
        onMain { [weak self] in
            guard let self = self, let organizer = self.organizer(), organizer.isRunning else { return done(self?.snapshot() ?? MenuBarState(running: false, collapsed: false)) }
            organizer.tidyNow()
            self.answerAfterFold(done: done)
        }
    }

    func showHidden(done: @escaping (MenuBarState) -> Void) {
        onMain { [weak self] in
            guard let self = self, let organizer = self.organizer(), organizer.isRunning else { return done(self?.snapshot() ?? MenuBarState(running: false, collapsed: false)) }
            organizer.showAlwaysHidden()
            done(self.snapshot())
        }
    }

    func readItems(done: @escaping (MenuBarReading) -> Void) {
        onMain { [weak self] in
            guard let self = self else { return }
            guard self.accessibilityGranted() else { return done(.permissionNeeded) }
            let dividers = self.organizer()?.dividerPositions ?? MenuBarDividers(divider: nil)
            let ownFrames = self.organizer()?.ownItemFrames ?? []
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let apps = NSWorkspace.shared.runningApplications.map { (pid: $0.processIdentifier, name: $0.localizedName ?? $0.bundleIdentifier ?? "?") }
            // Accessibility calls can be slow when an app hangs: read off the main thread, with a short per-app timeout.
            self.readQueue.async {
                let items = MenuBarAXReader.read(apps: apps, ownPID: ownPID, ownFrames: ownFrames)
                done(items.map { .items($0, dividers: dividers) } ?? .permissionNeeded)
            }
        }
    }
}

enum MenuBarAXReader {
    /// nil = Accessibility refused (permission lost); otherwise the status items of every running app.
    static func read(apps: [(pid: pid_t, name: String)], ownPID: pid_t, ownFrames: [CGRect]) -> [MenuBarItem]? {
        guard AXIsProcessTrusted() else { return nil }
        var items: [MenuBarItem] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, 0.4)
            var bar: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &bar)
            if status == .apiDisabled { return nil }
            guard status == .success, let barRef = bar, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { continue }
            let barElement = barRef as! AXUIElement  // type checked above
            AXUIElementSetMessagingTimeout(barElement, 0.4)
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barElement, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { continue }
            for child in list {
                guard let frame = frame(of: child) else { continue }
                let title = text(child, kAXTitleAttribute) ?? text(child, kAXDescriptionAttribute) ?? text(child, kAXHelpAttribute) ?? ""
                items.append(MenuBarItem(app: app.name, title: title, x: Double(frame.minX), y: Double(frame.minY),
                                         width: Double(frame.width), height: Double(frame.height), own: app.pid == ownPID))
            }
        }
        return items
    }

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let p = position, let s = size, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
