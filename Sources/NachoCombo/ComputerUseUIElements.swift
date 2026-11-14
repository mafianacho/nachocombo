import AppKit
import ApplicationServices
import CoreGraphics
import NachoComboCore

// Computer Use (NACHO-147): the macOS side of the accessibility tree tools and of the guard that keeps Nacho's input
// away from Nacho Combo's own windows. The Core (`UITreeReader`, `ComputerGadgetRunner`) decides what is read, cut and
// sent; this file only reads AXUIElement attributes and children, presses, and looks at our own windows.
//
// NOT verified on a Mac (compiled in CI only), like the rest of Computer Use.

/// An AXUIElement as the Core's `AnyObject` handle.
final class AXHandle {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

final class MacUIElementAccess: UIElementAccess {
    /// One round trip per element (CopyMultipleAttributeValues); missing attributes come back as error values.
    private static let attributes: [CFString] = [
        kAXRoleAttribute as CFString, kAXSubroleAttribute as CFString, kAXTitleAttribute as CFString,
        kAXValueAttribute as CFString, kAXDescriptionAttribute as CFString, kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString, kAXEnabledAttribute as CFString, kAXFocusedAttribute as CFString,
    ]
    /// A hung app must not hold the runner for long (seconds per element).
    private static let messagingTimeout: Float = 1.0

    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    // MARK: UIElementAccess

    func root(of target: UITreeTarget) throws -> (element: AnyObject, app: UITreeApp) {
        guard AXIsProcessTrusted() else {
            throw PolicyError("Accessibility permission is missing. Allow it for Nacho Combo in System Settings on the Mac.")
        }
        let found = try onMain { () -> Result<NSRunningApplication, PolicyError> in self.runningApp(target) }.get()
        let pid = found.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            throw PolicyError("Nacho Combo does not read or click its own windows; name the app to look at.")
        }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, MacUIElementAccess.messagingTimeout)
        let app = UITreeApp(name: found.localizedName ?? "App", pid: Int(pid), bundleID: found.bundleIdentifier)
        switch target.scope {
        case .app:
            return (AXHandle(appElement), app)
        case .window:
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let w = element(appElement, attribute as CFString) { return (AXHandle(w), app) }
            }
            if let first = elements(appElement, kAXWindowsAttribute as CFString).first { return (AXHandle(first), app) }
            throw PolicyError("\(app.name.prefix(60)) has no open window; read it with scope app.")
        }
    }

    func info(of handle: AnyObject) -> UIElementInfo? {
        guard let e = (handle as? AXHandle)?.element else { return nil }
        var raw: CFArray?
        let names = MacUIElementAccess.attributes as CFArray
        guard AXUIElementCopyMultipleAttributeValues(e, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == MacUIElementAccess.attributes.count else { return nil }
        func text(_ v: AnyObject) -> String? {
            if let s = v as? String { return s }
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return (v as? Bool) == true ? "true" : "false" }
            if let n = v as? NSNumber { return n.stringValue }
            if let u = v as? URL { return u.absoluteString }
            return nil
        }
        func flag(_ v: AnyObject) -> Bool? { CFGetTypeID(v) == CFBooleanGetTypeID() ? (v as? Bool) : nil }
        guard let role = values[0] as? String else { return nil }
        var frame: UIRect?
        if let origin = point(values[5]), let size = size(values[6]) {
            frame = UIRect(x: Double(origin.x), y: Double(origin.y), width: Double(size.width), height: Double(size.height))
        }
        return UIElementInfo(role: role, subrole: values[1] as? String, title: values[2] as? String,
                             value: text(values[3]), label: values[4] as? String, frame: frame,
                             enabled: flag(values[7]), focused: flag(values[8]))
    }

    func children(of handle: AnyObject) -> [AnyObject] {
        guard let e = (handle as? AXHandle)?.element else { return [] }
        return elements(e, kAXChildrenAttribute as CFString).map { AXHandle($0) }
    }

    func press(_ handle: AnyObject) -> Bool {
        guard let e = (handle as? AXHandle)?.element else { return false }
        return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
    }

    // MARK: helpers

    /// By pid, by name or bundle id (regular apps), or the app of the frontmost window that is not Nacho Combo's
    /// (the chat is usually in front while the user talks to Nacho).
    private func runningApp(_ target: UITreeTarget) -> Result<NSRunningApplication, PolicyError> {
        if let pid = target.pid {
            guard let app = NSRunningApplication(processIdentifier: pid_t(clamping: pid)) else { return .failure(PolicyError("Running app not found")) }
            return .success(app)
        }
        if let name = target.app?.lowercased() {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            let match = apps.first { $0.bundleIdentifier?.lowercased() == name }
                ?? apps.first { ($0.localizedName ?? "").lowercased() == name }
                ?? apps.first { ($0.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased() == name }
            return match.map { .success($0) } ?? .failure(PolicyError("Running app not found"))
        }
        if let pid = MacComputerSelfGuard.frontmostOtherPID(), let app = NSRunningApplication(processIdentifier: pid) {
            return .success(app)
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return .success(app)
        }
        return .failure(PolicyError("No app window is in front; name the app to look at."))
    }

    private func element(_ e: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute, &ref) == .success, let v = ref,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func elements(_ e: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute, &ref) == .success, let list = ref as? [AXUIElement] else { return [] }
        return list
    }

    private func point(_ v: AnyObject) -> CGPoint? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let value = v as! AXValue
        var p = CGPoint.zero
        guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &p) else { return nil }
        return p
    }

    private func size(_ v: AnyObject) -> CGSize? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let value = v as! AXValue
        var s = CGSize.zero
        guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &s) else { return nil }
        return s
    }
}

/// Keeps Nacho's clicks and keys out of Nacho Combo's own windows (chat, approval cards, pet, panels).
final class MacComputerSelfGuard: ComputerSelfGuard {
    private func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// Screen points (top-left origin of the main display) → AppKit (bottom-left), then our windows that take clicks.
    func ownsPoint(x: Double, y: Double) -> Bool {
        onMain {
            let height = NSScreen.screens.first?.frame.height ?? 0
            let p = NSPoint(x: x, y: Double(height) - y)
            return NSApp.windows.contains { w in
                w.isVisible && !w.ignoresMouseEvents && w.alphaValue > 0.01 && w.frame.contains(p)
            }
        }
    }

    /// Our chat is a non-activating panel that can be key: keys would land there. Hand the keyboard to the app of the
    /// frontmost other window and wait a moment for it to take it.
    func releaseKeyboard() -> Bool {
        let ours = { self.onMain { NSApp.keyWindow != nil } }
        guard ours() else { return true }
        guard let pid = MacComputerSelfGuard.frontmostOtherPID(), let app = NSRunningApplication(processIdentifier: pid) else { return false }
        onMain { _ = app.activate(options: [.activateIgnoringOtherApps]) }
        for _ in 0..<10 {
            usleep(50_000)
            if !ours() { return true }
        }
        return false
    }

    /// The owner of the frontmost normal window that is not ours (window list order is front to back).
    static func frontmostOtherPID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? Int, pid != me else { continue }
            return pid_t(pid)
        }
        return nil
    }
}
