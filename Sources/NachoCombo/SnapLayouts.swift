import AppKit
import ApplicationServices
import NachoComboCore

/// Window Snap's layouts: where every app's windows are, saved per arrangement of displays and put back later, or by
/// itself when the same displays are connected again. Windows are matched by app and front-to-back order, never by
/// title, and moved through the Accessibility API like a snap.
final class WindowLayoutKeeper {
    var optionsProvider: () -> GadgetOptions = { .defaults }
    var onChange: (() -> Void)?

    private(set) var store = WindowLayoutStore()
    private var observer: NSObjectProtocol?
    private var lastSignature = ""
    private var pendingApply: DispatchWorkItem?
    private(set) var lastResult = "-"

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NachoCombo", isDirectory: true).appendingPathComponent("window-layouts.json")
    }

    static var currentSignature: String { DisplaySignature.make(NSScreen.screens.map { $0.frame }) }

    func start() {
        store = WindowLayoutStore.load(from: WindowLayoutKeeper.fileURL)
        lastSignature = WindowLayoutKeeper.currentSignature
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
    }

    func stop() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pendingApply?.cancel()
        pendingApply = nil
    }

    /// The layout for the displays connected now.
    var current: SavedWindowLayout? { store.layout(for: WindowLayoutKeeper.currentSignature) }

    private func screensChanged() {
        let signature = WindowLayoutKeeper.currentSignature
        guard signature != lastSignature else { return }
        lastSignature = signature
        pendingApply?.cancel()
        guard optionsProvider().autoApplyLayouts, store.layout(for: signature) != nil else { return }
        // Displays settle for a moment after they connect, and apps move their windows themselves first.
        let work = DispatchWorkItem { [weak self] in self?.restore(quiet: true) }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func save() {
        var windows: [SavedWindow] = []
        for app in WindowLayoutKeeper.apps() {
            guard let bundleID = app.bundleIdentifier else { continue }
            for (order, window) in WindowLayoutKeeper.windows(of: app).enumerated() {
                guard let frame = window.frame else { continue }
                windows.append(SavedWindow(bundleID: bundleID, appName: app.localizedName ?? bundleID, frame: frame, order: order))
            }
        }
        guard !windows.isEmpty else {
            lastResult = "save:empty"
            Toast.show("No windows to save", near: NSEvent.mouseLocation)
            return
        }
        let layout = SavedWindowLayout(displays: WindowLayoutKeeper.currentSignature, displayCount: NSScreen.screens.count,
                                       savedAt: Date(), windows: windows)
        store.save(layout)
        do {
            try store.write(to: WindowLayoutKeeper.fileURL)
            lastResult = "saved:\(windows.count)"
            Toast.show("Saved \(windows.count) window\(windows.count == 1 ? "" : "s") of \(layout.appCount) app\(layout.appCount == 1 ? "" : "s")",
                       near: NSEvent.mouseLocation)
        } catch {
            lastResult = "error:write"
            Toast.show("The layout could not be saved", near: NSEvent.mouseLocation)
        }
        onChange?()
    }

    /// Puts the windows back as saved for these displays (or, by hand, as saved last on any displays).
    func restore(quiet: Bool = false) {
        guard let layout = current ?? (quiet ? nil : store.latest) else {
            lastResult = "restore:none"
            if !quiet { Toast.show("No layout saved yet", near: NSEvent.mouseLocation) }
            return
        }
        var moved = 0
        for app in WindowLayoutKeeper.apps() {
            guard let bundleID = app.bundleIdentifier else { continue }
            let windows = WindowLayoutKeeper.windows(of: app)
            let current = windows.indices.map { (bundleID: bundleID, order: $0) }
            let saved = layout.windows.filter { $0.bundleID == bundleID }
            for (index, frame) in LayoutMatching.assign(saved: saved, current: current) {
                // A frame saved on a display that is gone now is pulled onto the nearest one.
                let target = WindowLayoutKeeper.fitted(frame)
                if (try? windows[index].setFrame(target)) != nil { moved += 1 }
            }
        }
        lastResult = "restored:\(moved)"
        if !quiet || moved > 0 {
            Toast.show(moved == 0 ? "No saved windows are open" : "Put back \(moved) window\(moved == 1 ? "" : "s")",
                       near: NSEvent.mouseLocation)
        }
        onChange?()
    }

    private static func apps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
        }
    }

    /// The app's standard, not minimized windows, front to back.
    private static func windows(of app: NSRunningApplication) -> [AXWindow] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list.map { AXWindow(element: $0, pid: app.processIdentifier) }.filter { window in
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window.element, kAXMinimizedAttribute as CFString, &minimized)
            return window.isStandard && (minimized as? Bool) != true
        }
    }

    private static func fitted(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.map { $0.visibleFrame }
        guard !screens.contains(where: { $0.intersects(frame) }), let main = screens.first else { return frame }
        let width = min(frame.width, main.width), height = min(frame.height, main.height)
        return CGRect(x: main.midX - width / 2, y: main.midY - height / 2, width: width, height: height)
    }

    var summary: String {
        guard let layout = current else {
            return store.layouts.isEmpty ? "No layout saved" : "No layout saved for these displays"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Layout of \(layout.windows.count) window\(layout.windows.count == 1 ? "" : "s"), saved "
            + formatter.localizedString(for: layout.savedAt, relativeTo: Date())
    }

    var diagnostics: [String: String] {
        ["layouts": "\(store.layouts.count)", "layoutForDisplays": "\(current != nil)", "layoutResult": lastResult,
         "displaySignature": WindowLayoutKeeper.currentSignature]
    }
}
