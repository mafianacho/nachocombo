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

/// Keyboard and mouse window management through the Accessibility API: snap positions with gaps and repeat cycling,
/// restore, display moves, drag-to-snap with a preview, and ⌃⌘-drag to move or resize any window.
final class WindowSnapModule: NSObject, FeatureModule, PermissionPrompting {
    var allowPermissionPrompt = false
    let id = ModuleID.windowSnap
    static let permissionMessage =
        "To move windows, allow Nacho Combo in System Settings ▸ Privacy & Security ▸ Accessibility (Monterey: System Preferences ▸ Security & Privacy ▸ Privacy ▸ Accessibility)."

    var optionsProvider: () -> GadgetOptions = { .defaults }
    /// The quick panel can be the frontmost app while the user clicks "apply": this tells which app's window to move.
    var targetAppProvider: (() -> NSRunningApplication?)?
    var onPermissionLost: (() -> Void)?

    private(set) var running = false
    private(set) var snapCount = 0
    private(set) var lastResult = "-"
    /// The OS permission dialog is shown once per ON switch; re-checks never re-prompt.
    private var promptedSinceEnabled = false
    let memory = WindowFrameMemory()
    private lazy var dragSnap = DragSnapController(module: self)
    private lazy var motion = WindowMotionController()

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// macOS 15+ tiles windows dragged to a screen edge by itself unless the user turned that off.
    static var systemEdgeTilingEnabled: Bool {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0,
                                                                                     patchVersion: 0)) else { return false }
        return (UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool) ?? true
    }

    func start() -> ModuleState {
        // The OS permission dialog is shown once per explicit opt-in; later re-checks stay silent.
        let shouldPrompt = allowPermissionPrompt && !promptedSinceEnabled
        if allowPermissionPrompt { promptedSinceEnabled = true }
        guard WindowSnapModule.isTrusted(prompt: shouldPrompt) else {
            return .needsPermission(WindowSnapModule.permissionMessage)
        }
        running = true
        applyOptions()
        return .running
    }

    func stop() {
        running = false
        promptedSinceEnabled = false
        dragSnap.stop()
        motion.stop()
    }

    /// Starts or stops the mouse features to match the options.
    func applyOptions() {
        guard running else { return }
        let options = optionsProvider()
        if options.snapDragToEdges || options.snapRestoreOnDrag { dragSnap.start() } else { dragSnap.stop() }
        if options.windowMotion { motion.start() } else { motion.stop() }
    }

    var motionFailed: Bool { running && optionsProvider().windowMotion && !motion.isActive }

    // MARK: keyboard actions

    func perform(_ action: SnapAction) {
        do {
            guard WindowSnapModule.isTrusted(prompt: false) else { throw WindowSnapError.notTrusted }
            guard let app = targetAppProvider?() ?? NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { throw WindowSnapError.noTargetApp }
            guard let window = AXWindow.focused(of: app.processIdentifier) else { throw WindowSnapError.noFocusedWindow }
            try apply(action, to: window)
            snapCount += 1
            lastResult = "ok:\(action.rawValue)"
        } catch {
            lastResult = "error:\(error)"
            if case WindowSnapError.notTrusted = error {
                stop()   // permission was revoked while running: stop reacting
                onPermissionLost?()
            }
        }
    }

    /// Computes and applies the frame for `action` (also used by drag-to-snap).
    func apply(_ action: SnapAction, to window: AXWindow) throws {
        guard let current = window.frame else { throw WindowSnapError.attribute("read") }
        let options = optionsProvider()
        let visibles = NSScreen.screens.map { $0.visibleFrame }
        guard let index = WindowLayout.screenIndex(for: current, screens: visibles) else {
            throw WindowSnapError.attribute("screen")
        }
        let visible = visibles[index]
        let gap = CGFloat(options.snapGap)
        var target: CGRect
        switch action {
        case .restore:
            guard let saved = memory.before(window.element) else { return }
            target = saved
        case .nextDisplay, .previousDisplay:
            guard let next = WindowLayout.adjacentScreen(of: index, screens: visibles, forward: action == .nextDisplay) else { return }
            target = WindowLayout.move(current, from: visible, to: visibles[next])
        default:
            let plain = WindowLayout.target(for: action, in: visible, current: current, gap: gap, cycle: false)
            if options.snapRepeat == .nextDisplay, action == .left || action == .right, WindowLayout.matches(current, plain),
               let next = WindowLayout.adjacentScreen(of: index, screens: visibles, forward: action == .right) {
                // Repeating a half moves on: left again lands on the right half of the display to the left.
                target = WindowLayout.target(for: action == .left ? .right : .left, in: visibles[next], current: nil,
                                             gap: gap, cycle: false)
            } else {
                target = WindowLayout.target(for: action, in: visible, current: current, gap: gap,
                                             cycle: options.snapRepeat == .cycleSizes)
            }
        }
        if action == .restore {
            memory.forget(window.element)
        } else {
            memory.remember(window.element, before: current, applied: target)
        }
        try window.setFrame(target)
        if action != .restore, let landed = window.frame { memory.updateApplied(window.element, landed) }
    }

    var diagnostics: [String: String] {
        [
            "running": "\(running)",
            "snapCount": "\(snapCount)",
            "lastResult": lastResult,
            "axTrusted": "\(WindowSnapModule.isTrusted(prompt: false))",
            "dragSnapActive": "\(dragSnap.isActive)",
            "dragSnapDeferredToSystem": "\(WindowSnapModule.systemEdgeTilingEnabled)",
            "motionTapActive": "\(motion.isActive)",
            "rememberedWindows": "\(memory.count)",
        ]
    }
}

// MARK: - Accessibility window

/// One window of another app, addressed through the Accessibility API. Frames are in Cocoa coordinates.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t

    static func focused(of pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXWindow(element: value as! AXUIElement, pid: pid)
    }

    /// The window under a point given in Accessibility (top-left) coordinates; nil for our own windows and the Dock.
    static func at(axPoint: CGPoint) -> AXWindow? {
        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(axPoint.x), Float(axPoint.y), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != getpid(), NSRunningApplication(processIdentifier: pid)?.bundleIdentifier != "com.apple.dock" else { return nil }
        for _ in 0..<12 {
            if role(of: element) == kAXWindowRole as String { return AXWindow(element: element, pid: pid) }
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
               let value = windowRef, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return AXWindow(element: value as! AXUIElement, pid: pid)
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { return nil }
            element = next as! AXUIElement
        }
        return nil
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    var isStandard: Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success else { return true }
        return (value as? String) == (kAXStandardWindowSubrole as String)
    }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Top-left origin and size as the Accessibility API reports them.
    var axFrame: CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    var frame: CGRect? {
        axFrame.map { WindowLayout.cocoaRect(fromAccessibilityOrigin: $0.origin, size: $0.size, primaryScreenHeight: AXWindow.primaryHeight) }
    }

    func setFrame(_ cocoa: CGRect) throws {
        let origin = WindowLayout.accessibilityOrigin(forCocoa: cocoa, primaryScreenHeight: AXWindow.primaryHeight)
        try withPlainUserInterface {
            // position -> size -> position: some apps clamp the first move to the old size.
            try set(kAXPositionAttribute, .cgPoint, origin)
            try set(kAXSizeAttribute, .cgSize, cocoa.size)
            try set(kAXPositionAttribute, .cgPoint, origin)
        }
    }

    func setPosition(ax origin: CGPoint) { try? set(kAXPositionAttribute, .cgPoint, origin) }
    func setSize(_ size: CGSize) { try? set(kAXSizeAttribute, .cgSize, size) }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    private func set<T>(_ attribute: String, _ type: AXValueType, _ value: T) throws {
        var copy = value
        guard let axValue = AXValueCreate(type, &copy),
              AXUIElementSetAttributeValue(element, attribute as CFString, axValue) == .success
        else { throw WindowSnapError.attribute(attribute) }
    }

    /// Apps with "enhanced user interface" on (set by assistive tools) animate frame changes and end up in the wrong
    /// place; it is switched off for the move and restored afterwards.
    private func withPlainUserInterface(_ body: () throws -> Void) rethrows {
        let app = AXUIElementCreateApplication(pid)
        let attribute = "AXEnhancedUserInterface" as CFString
        var value: CFTypeRef?
        let enhanced = AXUIElementCopyAttributeValue(app, attribute, &value) == .success && (value as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue) } }
        try body()
    }
}

/// Frames of windows before they were snapped (for Restore and for "restore size when dragged away").
final class WindowFrameMemory {
    private struct Entry { let element: AXUIElement; var before: CGRect; var applied: CGRect }
    private var entries: [Entry] = []
    private let capacity = 64

    var count: Int { entries.count }

    private func index(_ element: AXUIElement) -> Int? { entries.firstIndex { CFEqual($0.element, element) } }

    /// Keeps the frame from before the first snap while the window keeps being snapped.
    func remember(_ element: AXUIElement, before: CGRect, applied: CGRect) {
        if let i = index(element) {
            if !WindowLayout.matches(entries[i].applied, before) { entries[i].before = before }
            entries[i].applied = applied
            let entry = entries.remove(at: i)
            entries.append(entry)
        } else {
            entries.append(Entry(element: element, before: before, applied: applied))
            if entries.count > capacity { entries.removeFirst() }
        }
    }

    func updateApplied(_ element: AXUIElement, _ frame: CGRect) {
        if let i = index(element) { entries[i].applied = frame }
    }

    func before(_ element: AXUIElement) -> CGRect? { index(element).map { entries[$0].before } }

    /// The frame we gave the window if it is still exactly there (it was snapped and not changed since).
    func isSnapped(_ element: AXUIElement, at frame: CGRect) -> Bool {
        guard let i = index(element) else { return false }
        return WindowLayout.matches(entries[i].applied, frame)
    }

    func forget(_ element: AXUIElement) {
        if let i = index(element) { entries.remove(at: i) }
    }
}

// MARK: - Drag to snap

/// Watches window drags with passive global mouse monitors (they see events, never change them). When a window
/// being dragged reaches a screen edge, a preview shows where it will land; releasing there snaps it. A window that
/// was snapped gets its earlier size back as soon as it is dragged away.
final class DragSnapController {
    private weak var module: WindowSnapModule?
    private var monitors: [Any] = []
    private var window: AXWindow?
    private var startFrame: CGRect?
    private var moving = false
    private var zone: SnapAction?
    private var lastCheck = Date.distantPast
    private let footprint = FootprintWindow()

    init(module: WindowSnapModule) { self.module = module }

    var isActive: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.mouseDown() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in self?.dragged() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.mouseUp() }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        reset()
    }

    private func reset() {
        window = nil
        startFrame = nil
        moving = false
        zone = nil
        footprint.orderOut(nil)
    }

    private func mouseDown() {
        reset()
        let point = NSEvent.mouseLocation
        let axPoint = CGPoint(x: point.x, y: AXWindow.primaryHeight - point.y)
        guard let found = AXWindow.at(axPoint: axPoint), found.isStandard, let frame = found.frame else { return }
        window = found
        startFrame = frame
    }

    private func dragged() {
        guard let module = module, let window = window, let start = startFrame else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCheck) > 0.04 else { return }
        lastCheck = now
        let options = module.optionsProvider()
        if !moving {
            // Only a window that actually follows the pointer is being dragged (not text selection, not a resize).
            guard let frame = window.frame, frame.size == start.size,
                  abs(frame.minX - start.minX) + abs(frame.minY - start.minY) > 3 else { return }
            moving = true
            if options.snapRestoreOnDrag, module.memory.isSnapped(window.element, at: start),
               let before = module.memory.before(window.element) {
                // Give back the old size, keeping the grab point at the same relative spot under the pointer.
                let pointer = NSEvent.mouseLocation
                let ratio = start.width > 0 ? (pointer.x - start.minX) / start.width : 0.5
                let newX = pointer.x - before.width * ratio
                let topY = frame.maxY
                window.setSize(before.size)
                window.setPosition(ax: CGPoint(x: newX, y: AXWindow.primaryHeight - topY))
                module.memory.forget(window.element)
            }
        }
        guard options.snapDragToEdges, !WindowSnapModule.systemEdgeTilingEnabled else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) else { return }
        let action = SnapZones.action(at: pointer, screen: screen.frame)
        if action != zone {
            zone = action
            if let action = action {
                let target = WindowLayout.target(for: action, in: screen.visibleFrame, current: nil,
                                                 gap: CGFloat(options.snapGap), cycle: false)
                footprint.show(target)
            } else {
                footprint.orderOut(nil)
            }
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard moving, let action = zone, let window = window, let module = module else { return }
        // Let the app finish its own drag before the frame is set.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            try? module.apply(action, to: window)
        }
    }
}

/// Translucent accent rectangle showing where a dragged window will land.
final class FootprintWindow: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.borderWidth = 2
        contentView = view
    }

    func show(_ frame: CGRect) {
        let accent = NSColor.controlAccentColor
        contentView?.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        contentView?.layer?.borderColor = accent.withAlphaComponent(0.85).cgColor
        setFrame(frame.insetBy(dx: 4, dy: 4), display: true)
        orderFrontRegardless()
    }
}

// MARK: - Window motion (⌃⌘-drag)

/// ⌃⌘-drag anywhere inside a window moves it, ⌃⌘-right-drag resizes it from the nearest corner. An event tap (allowed
/// by the Accessibility permission) takes those clicks so the app underneath does not also react to them; every
/// other click passes through untouched.
final class WindowMotionController {
    private enum Mode { case move, resize(left: Bool, top: Bool) }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mode: Mode?
    private var window: AXWindow?
    private var startMouse = CGPoint.zero
    private var startFrame = CGRect.zero        // Accessibility coordinates (top-left origin)
    private var lastApply = Date.distantPast
    static let modifiers: CGEventFlags = [.maskControl, .maskCommand]

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil else { return }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                    .rightMouseDown, .rightMouseDragged, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<WindowMotionController>.fromOpaque(info).takeUnretainedValue()
            return controller.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        mode = nil
        window = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            let flags = event.flags.intersection([.maskControl, .maskCommand, .maskAlternate, .maskShift])
            guard flags == WindowMotionController.modifiers else { return Unmanaged.passUnretained(event) }
            let location = event.location
            guard let found = AXWindow.at(axPoint: location), let frame = found.axFrame else {
                return Unmanaged.passUnretained(event)
            }
            window = found
            startMouse = location
            startFrame = frame
            if type == .leftMouseDown {
                mode = .move
            } else {
                mode = .resize(left: location.x < frame.midX, top: location.y < frame.midY)
            }
            found.raise()
            return nil
        case .leftMouseDragged, .rightMouseDragged:
            guard let mode = mode, let window = window else { return Unmanaged.passUnretained(event) }
            let now = Date()
            guard now.timeIntervalSince(lastApply) > 1.0 / 60 else { return nil }
            lastApply = now
            let dx = event.location.x - startMouse.x, dy = event.location.y - startMouse.y
            switch mode {
            case .move:
                window.setPosition(ax: CGPoint(x: startFrame.minX + dx, y: startFrame.minY + dy))
            case .resize(let left, let top):
                var frame = startFrame
                let minimum: CGFloat = 120
                if left {
                    let width = max(minimum, startFrame.width - dx)
                    frame.origin.x = startFrame.maxX - width
                    frame.size.width = width
                } else {
                    frame.size.width = max(minimum, startFrame.width + dx)
                }
                if top {
                    let height = max(minimum, startFrame.height - dy)
                    frame.origin.y = startFrame.maxY - height
                    frame.size.height = height
                } else {
                    frame.size.height = max(minimum, startFrame.height + dy)
                }
                if left || top { window.setPosition(ax: frame.origin) }
                window.setSize(frame.size)
            }
            return nil
        case .leftMouseUp, .rightMouseUp:
            guard mode != nil else { return Unmanaged.passUnretained(event) }
            mode = nil
            window = nil
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
