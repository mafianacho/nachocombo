import AppKit
import ApplicationServices
import NachoComboCore

enum WindowSnapError: Error, CustomStringConvertible {
    case notTrusted, noTargetApp, noFocusedWindow, attribute(String)
    var description: String {
        switch self {
        case .notTrusted: return "Accessibility permission is missing"
        case .noTargetApp: return "No target app"
        case .noFocusedWindow: return "No target window"
        case .attribute(let name): return "Could not change the window attribute: \(name)"
        }
    }
}

/// Left/right/maximize window placement through the Accessibility API.
final class WindowSnapModule: NSObject, FeatureModule {
    let id = ModuleID.windowSnap
    static let permissionMessage =
        "To move windows, allow Nacho Combo in System Settings ▸ Privacy & Security ▸ Accessibility (Monterey: System Preferences ▸ Security & Privacy ▸ Privacy ▸ Accessibility)."

    private let hotKeys = HotKeyCenter()
    private(set) var snapCount = 0
    private(set) var lastResult = "-"
    /// The OS permission dialog is shown once per ON switch; re-checks never re-prompt.
    private var promptedSinceEnabled = false
    var onPermissionLost: (() -> Void)?

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func start() -> ModuleState {
        // The OS permission dialog is shown once per explicit opt-in; later re-checks stay silent.
        let shouldPrompt = !promptedSinceEnabled
        promptedSinceEnabled = true
        guard WindowSnapModule.isTrusted(prompt: shouldPrompt) else {
            return .needsPermission(WindowSnapModule.permissionMessage)
        }
        guard hotKeys.registeredCount == 0 else { return .running }
        var failures: [String] = []
        for (index, spec) in HotKeySpec.defaults.enumerated() {
            let ok = hotKeys.register(id: UInt32(index + 1), keyCode: spec.keyCode,
                                      modifiers: spec.carbonModifiers) { [weak self] in
                self?.perform(spec.action)
            }
            if !ok { failures.append(spec.label) }
        }
        if !failures.isEmpty {
            hotKeys.unregisterAll()
            return .failed("Could not register hotkeys (another app may use them): " + failures.joined(separator: ", "))
        }
        return .running
    }

    func stop() {
        hotKeys.unregisterAll()
        promptedSinceEnabled = false
    }

    func perform(_ action: SnapAction) {
        do {
            try snapFrontmostWindow(action)
            snapCount += 1
            lastResult = "ok:\(action.rawValue)"
        } catch {
            lastResult = "error:\(error)"
            if case WindowSnapError.notTrusted = error {
                hotKeys.unregisterAll()   // permission was revoked while running: stop reacting to keys
                onPermissionLost?()
            }
        }
    }

    private func snapFrontmostWindow(_ action: SnapAction) throws {
        guard WindowSnapModule.isTrusted(prompt: false) else { throw WindowSnapError.notTrusted }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw WindowSnapError.noTargetApp }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let windowRef = focused else { throw WindowSnapError.noFocusedWindow }
        let window = windowRef as! AXUIElement

        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { throw WindowSnapError.attribute("read") }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        guard let primary = NSScreen.screens.first else { throw WindowSnapError.attribute("screen") }
        let primaryHeight = primary.frame.height
        let current = WindowLayout.cocoaRect(fromAccessibilityOrigin: origin, size: size,
                                             primaryScreenHeight: primaryHeight)
        let visibles = NSScreen.screens.map { $0.visibleFrame }
        guard let index = WindowLayout.screenIndex(for: current, screens: visibles) else {
            throw WindowSnapError.attribute("screen")
        }
        let target = WindowLayout.target(for: action, in: visibles[index])
        var newOrigin = WindowLayout.accessibilityOrigin(forCocoa: target, primaryScreenHeight: primaryHeight)
        var newSize = target.size

        // position -> size -> position: some apps clamp the first move to the old size.
        try set(window, kAXPositionAttribute, .cgPoint, &newOrigin)
        try set(window, kAXSizeAttribute, .cgSize, &newSize)
        try set(window, kAXPositionAttribute, .cgPoint, &newOrigin)
    }

    private func set<T>(_ window: AXUIElement, _ attribute: String, _ type: AXValueType, _ value: inout T) throws {
        guard let axValue = AXValueCreate(type, &value),
              AXUIElementSetAttributeValue(window, attribute as CFString, axValue) == .success
        else { throw WindowSnapError.attribute(attribute) }
    }

    var diagnostics: [String: String] {
        [
            "hotkeysRegistered": "\(hotKeys.registeredCount)",
            "hotkeyEvents": "\(hotKeys.firedCount)",
            "snapCount": "\(snapCount)",
            "lastResult": lastResult,
            "axTrusted": "\(WindowSnapModule.isTrusted(prompt: false))",
        ]
    }
}
