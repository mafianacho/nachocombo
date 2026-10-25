import AppKit
import CoreGraphics
import NachoComboCore

/// Focus dimming. Click-through, borderless overlay windows (two per screen, for cross-fades) are ordered directly
/// below the active window, so it stays bright and every other normal window is darkened. Menu bar, Dock and floating
/// panels stay above the overlay. Options keep all windows of the active app bright, leave other displays undimmed,
/// and fade between windows. No permission is needed: window numbers and frames come from CGWindowListCopyWindowInfo.
final class FocusDimModule: NSObject, FeatureModule {
    let id = ModuleID.focusDim
    var optionsProvider: () -> GadgetOptions = { .defaults }

    /// Per screen: the overlay in use and a spare for the next cross-fade.
    private var overlays: [(screen: CGRect, current: NSWindow, spare: NSWindow)] = []
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private(set) var intensity = FocusDimLogic.defaultIntensity
    private(set) var paused = false
    private(set) var activeNumber: Int?
    private var activeScreen: Int?
    private var fadeGeneration = 0
    private(set) var refreshCount = 0
    private(set) var reorderCount = 0
    private var lastFrontApp = "-"
    var onPauseChange: (() -> Void)?

    var isRunning: Bool { !overlays.isEmpty }
    private var allWindows: [NSWindow] { overlays.flatMap { [$0.current, $0.spare] } }

    func setIntensity(_ value: Double) {
        intensity = FocusDimLogic.clamp(value)
        let color = NSColor.black.withAlphaComponent(CGFloat(intensity))
        for window in allWindows { window.backgroundColor = color }
    }

    func start() -> ModuleState {
        guard overlays.isEmpty else { return .running }
        paused = false
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
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        for window in allWindows {
            window.orderOut(nil)
            window.close()
        }
        overlays.removeAll()
        activeNumber = nil
        activeScreen = nil
        paused = false
    }

    /// Hides the shade (or brings it back) without switching the gadget off.
    func togglePause() {
        guard isRunning else { return }
        paused.toggle()
        if paused { hideAll(); activeNumber = nil; activeScreen = nil } else { refresh() }
        onPauseChange?()
    }

    private func makeOverlay(_ screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(intensity))
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks always reach the windows underneath
        window.level = .normal
        window.hidesOnDeactivate = false
        window.canHide = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.title = "NachoCombo Focus Dim"
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func buildOverlays() {
        overlays = NSScreen.screens.map { ($0.frame, makeOverlay($0), makeOverlay($0)) }
    }

    private func rebuildOverlays() {
        guard !overlays.isEmpty else { return }
        for window in allWindows { window.orderOut(nil); window.close() }
        overlays.removeAll()
        buildOverlays()
        activeNumber = nil
        refresh()
    }

    private func hideAll() {
        for window in allWindows where window.isVisible { window.orderOut(nil) }
        activeScreen = nil
    }

    func refresh() {
        refreshCount += 1
        guard !overlays.isEmpty, !paused else { return }
        guard let front = NSWorkspace.shared.frontmostApplication else { hideAll(); activeNumber = nil; return }
        lastFrontApp = front.localizedName ?? "pid:\(front.processIdentifier)"
        let own = Set(allWindows.map { $0.windowNumber })
        let snapshots = FocusDimModule.windowList()
        let options = optionsProvider()
        guard let active = FocusDimLogic.activeWindow(in: snapshots, frontmostPID: front.processIdentifier, excluding: own) else {
            hideAll()
            activeNumber = nil
            return
        }
        // With "all windows of the app", the shade goes below the app's backmost window instead of the front one.
        let anchor = options.dimScope == .frontApp
            ? FocusDimLogic.backmostWindow(in: snapshots, ownerPID: front.processIdentifier, excluding: own) ?? active
            : active
        // The active window's display, from the window server's top-left coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let activeCocoa = CGRect(x: active.frame.minX, y: primaryHeight - active.frame.maxY,
                                 width: active.frame.width, height: active.frame.height)
        let screen = WindowLayout.screenIndex(for: activeCocoa, screens: overlays.map { $0.screen })
        func wanted(_ index: Int) -> Bool { options.dimOtherDisplays || index == screen }
        let stale = overlays.indices.contains { wanted($0) && !overlays[$0].current.isVisible }
        guard anchor.number != activeNumber || stale || screen != activeScreen else { return }
        let changed = anchor.number != activeNumber
        activeNumber = anchor.number
        activeScreen = screen
        reorderCount += 1
        let fade = (options.dimFadeSeconds > 0 && !UI.reduceMotion && changed && !stale) ? options.dimFadeSeconds : 0
        fadeGeneration += 1
        let generation = fadeGeneration
        for index in overlays.indices {
            let entry = overlays[index]
            guard wanted(index) else {
                entry.current.orderOut(nil)
                entry.spare.orderOut(nil)
                continue
            }
            if fade > 0 && entry.current.isVisible {
                // Cross-fade: the spare appears below the new window while the old shade fades out.
                let incoming = entry.spare, outgoing = entry.current
                incoming.alphaValue = 0
                incoming.order(.below, relativeTo: anchor.number)
                overlays[index] = (entry.screen, incoming, outgoing)
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = fade
                    incoming.animator().alphaValue = 1
                    outgoing.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    // A newer switch may already have reused this window as its incoming shade.
                    guard self?.fadeGeneration == generation else { return }
                    outgoing.orderOut(nil)
                    outgoing.alphaValue = 1
                })
            } else {
                entry.current.alphaValue = 1
                entry.current.order(.below, relativeTo: anchor.number)
                entry.spare.orderOut(nil)
            }
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
        let shades = overlays.map { $0.current }
        var below = "n/a"
        if let active = activeNumber, !overlays.isEmpty {
            let order = FocusDimModule.windowList().map { $0.number }
            below = shades.filter { $0.isVisible }.allSatisfy { FocusDimLogic.isBelow($0.windowNumber, active: active, in: order) }
                ? "true" : "false"
        }
        return [
            "overlays": "\(shades.count)",
            "overlaysVisible": "\(shades.filter { $0.isVisible }.count)",
            "overlaysIgnoreMouse": shades.isEmpty ? "n/a" : "\(allWindows.allSatisfy { $0.ignoresMouseEvents })",
            "overlayAlpha": String(format: "%.2f", intensity),
            "paused": "\(paused)",
            "scope": optionsProvider().dimScope.rawValue,
            "timerActive": "\(timer != nil)",
            "observers": "\(workspaceObservers.count + defaultObservers.count)",
            "activeWindow": activeNumber.map(String.init) ?? "none",
            "overlayBelowActive": below,
            "frontApp": lastFrontApp,
            "refreshCount": "\(refreshCount)",
            "reorderCount": "\(reorderCount)",
        ]
    }
}
