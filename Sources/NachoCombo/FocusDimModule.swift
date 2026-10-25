import AppKit
import CoreGraphics
import NachoComboCore

/// HazeOver-style focus dimming. One click-through, borderless overlay window per screen is ordered
/// directly below the active window, so the active window stays bright and every other normal window
/// is darkened. Menu bar, Dock and floating panels stay above the overlay.
/// No permission is needed: window numbers and frames come from CGWindowListCopyWindowInfo.
final class FocusDimModule: NSObject, FeatureModule {
    let id = ModuleID.focusDim
    static let hotKeyLabel = "⌃⌥D"

    private var overlays: [NSWindow] = []
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private let hotKeys = HotKeyCenter(signature: 0x4E43_4446)   // 'NCDF'
    private(set) var intensity = FocusDimLogic.defaultIntensity
    private(set) var activeNumber: Int?
    private(set) var refreshCount = 0
    private(set) var reorderCount = 0
    private var lastFrontApp = "-"
    /// Called (on the main queue) when the user presses the instant-release hotkey.
    var onInstantRelease: (() -> Void)?

    var isRunning: Bool { !overlays.isEmpty }

    func setIntensity(_ value: Double) {
        intensity = FocusDimLogic.clamp(value)
        let color = NSColor.black.withAlphaComponent(CGFloat(intensity))
        for overlay in overlays { overlay.backgroundColor = color }
    }

    func start() -> ModuleState {
        guard overlays.isEmpty else { return .running }
        buildOverlays()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
        defaultObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlays()
        })
        // Window switches inside one app produce no notification: a light poll covers them.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        _ = hotKeys.register(id: 1, keyCode: 2, modifiers: HotKeySpec.controlKey | HotKeySpec.optionKey) { [weak self] in
            DispatchQueue.main.async { self?.onInstantRelease?() }
        }
        refresh()
        return .running
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        workspaceObservers.removeAll()
        defaultObservers.forEach { NotificationCenter.default.removeObserver($0) }
        defaultObservers.removeAll()
        hotKeys.unregisterAll()
        for overlay in overlays {
            overlay.orderOut(nil)
            overlay.close()
        }
        overlays.removeAll()
        activeNumber = nil
    }

    private func buildOverlays() {
        let color = NSColor.black.withAlphaComponent(CGFloat(intensity))
        overlays = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.backgroundColor = color
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true          // clicks always reach the windows underneath
            window.level = .normal
            window.hidesOnDeactivate = false
            window.canHide = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.title = "NachoCombo Focus Dim"
            window.setFrame(screen.frame, display: false)
            return window
        }
    }

    private func rebuildOverlays() {
        guard !overlays.isEmpty else { return }
        for overlay in overlays { overlay.orderOut(nil); overlay.close() }
        overlays.removeAll()
        buildOverlays()
        activeNumber = nil
        refresh()
    }

    private func hideAll() {
        for overlay in overlays where overlay.isVisible { overlay.orderOut(nil) }
    }

    func refresh() {
        refreshCount += 1
        guard !overlays.isEmpty else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { hideAll(); activeNumber = nil; return }
        lastFrontApp = front.localizedName ?? "pid:\(front.processIdentifier)"
        let own = Set(overlays.map { $0.windowNumber })
        let snapshots = FocusDimModule.windowList()
        guard let active = FocusDimLogic.activeWindow(in: snapshots, frontmostPID: front.processIdentifier, excluding: own) else {
            hideAll()
            activeNumber = nil
            return
        }
        if active.number != activeNumber || overlays.contains(where: { !$0.isVisible }) {
            activeNumber = active.number
            reorderCount += 1
            for overlay in overlays { overlay.order(.below, relativeTo: active.number) }
        }
    }

    /// Front-to-back list of on-screen windows (all layers) from the window server.
    static func windowList() -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1
            return WindowSnapshot(number: number, ownerPID: Int32(truncatingIfNeeded: pid), layer: layer, frame: frame, alpha: alpha)
        }
    }

    var diagnostics: [String: String] {
        let overlayNumbers = overlays.map { $0.windowNumber }
        var below = "n/a"
        if let active = activeNumber, !overlays.isEmpty {
            let order = FocusDimModule.windowList().map { $0.number }
            below = overlayNumbers.allSatisfy { FocusDimLogic.isBelow($0, active: active, in: order) } ? "true" : "false"
        }
        return [
            "overlays": "\(overlays.count)",
            "overlaysVisible": "\(overlays.filter { $0.isVisible }.count)",
            "overlaysIgnoreMouse": overlays.isEmpty ? "n/a" : "\(overlays.allSatisfy { $0.ignoresMouseEvents })",
            "overlayAlpha": String(format: "%.2f", intensity),
            "timerActive": "\(timer != nil)",
            "observers": "\(workspaceObservers.count + defaultObservers.count)",
            "hotkeysRegistered": "\(hotKeys.registeredCount)",
            "activeWindow": activeNumber.map(String.init) ?? "none",
            "overlayBelowActive": below,
            "frontApp": lastFrontApp,
            "refreshCount": "\(refreshCount)",
            "reorderCount": "\(reorderCount)",
        ]
    }
}
