import AppKit
import ApplicationServices
import CoreAudio
import NachoComboCore

/// Runs Nacho's desktop actions (apps, several windows, system controls, File Shelf / Focus Dim, workspaces) after
/// `PetCommands.parse` has checked them. App names are matched against running and installed apps; windows move
/// through the Accessibility API like Window Snap. Nothing here quits an app unless the risky, approval-gated
/// `quitApp` arrives (declared with `"approval": "required"`, so the server shows its approval card first).
final class PetDesktopActions {
    private let manager: ModuleManager
    private let snap: WindowSnapModule
    private let shelf: ShelfModule
    /// Focus Dim strength (0.1...0.9), saved in the settings and applied to a running Focus Dim.
    var applyDimIntensity: (Double) -> Void = { _ in }
    var permissionGranted: (GadgetPermission) -> Bool? = { _ in nil }
    /// Workspaces or gadgets changed (the settings screen and menu bar follow).
    var onChange: (() -> Void)?
    var isTrusted: () -> Bool = { WindowSnapModule.isTrusted(prompt: false) }

    private(set) var store: DesktopWorkspaceStore
    let storeURL: URL
    /// Diagnostics: capability and ok / failed, newest last (never the parameters' text).
    private(set) var log: [String] = []
    private(set) var lastResult: [String: Any] = [:]
    private var installedCache: (at: Date, apps: [PetAppEntry])?

    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NachoCombo", isDirectory: true).appendingPathComponent("workspaces.json")
    }

    init(manager: ModuleManager, snap: WindowSnapModule, shelf: ShelfModule, storeURL: URL = PetDesktopActions.defaultStoreURL) {
        self.manager = manager
        self.snap = snap
        self.shelf = shelf
        self.storeURL = storeURL
        store = DesktopWorkspaceStore.load(from: storeURL)
    }

    /// Runs `command` if it is a desktop action and calls `done` once (some answer later, e.g. after an app opened).
    /// Returns false for the commands the app delegate runs itself (arrange window, gadgets on / off, list gadgets).
    func run(_ command: PetCommand, done: @escaping (PetCommandOutcome) -> Void) -> Bool {
        let finish: (PetCommandOutcome) -> Void = { [weak self] outcome in
            self?.record(command, outcome)
            done(outcome)
        }
        switch command {
        case .arrangeWindow, .setGadget, .listGadgets:
            return false
        case let .listApps(installed): finish(listApps(installed: installed))
        case let .openApp(name): openApp(name, done: finish)
        case let .focusApp(name): focusApp(name, done: finish)
        case let .hideApp(name): finish(hideApp(name))
        case let .quitApp(name): quitApp(name, done: finish)
        case .listWindows: finish(listWindows())
        case let .layoutWindows(items): finish(layoutWindows(items))
        case let .setSystem(change): finish(setSystem(change))
        case let .setDimStrength(percent): finish(setDimStrength(percent))
        case .clearShelf: finish(clearShelf())
        case let .saveWorkspace(name): finish(saveWorkspace(name))
        case let .applyWorkspace(name): applyWorkspace(name, done: finish)
        case .listWorkspaces: finish(listWorkspaces())
        }
        return true
    }

    /// The commands `run` takes (the rest stay with the app delegate).
    func handles(_ command: PetCommand) -> Bool {
        switch command {
        case .arrangeWindow, .setGadget, .listGadgets: return false
        default: return true
        }
    }

    private func record(_ command: PetCommand, _ outcome: PetCommandOutcome) {
        noteOutcome(String(String(describing: command).prefix { $0 != "(" }), outcome)
    }

    /// Debug channel and diagnostics: the latest answer, also for commands run elsewhere or refused by the parser.
    func noteOutcome(_ name: String, _ outcome: PetCommandOutcome) {
        log.append("\(name):\(outcome.ok ? "ok" : "failed")")
        if log.count > 50 { log.removeFirst(log.count - 50) }
        lastResult = outcome.resultJSON
        lastResult["command"] = name
    }

    func noteRefused(_ capability: String, _ message: String) {
        log.append("\(capability.prefix(64)):refused")
        lastResult = ["command": String(capability.prefix(64)), "error": message]
    }

    var diagnostics: [String: Any] {
        ["workspaces": store.workspaces.map { $0.name }, "log": log, "last": lastResult, "axTrusted": isTrusted(),
         "storeFile": storeURL.lastPathComponent]
    }

    // MARK: apps

    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.mafianacho.nachocombo"

    private func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != nil
        }
    }

    private static func names(of url: URL) -> [String] {
        var names: [String] = []
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !names.contains(s) else { return }
            names.append(s)
        }
        var display = FileManager.default.displayName(atPath: url.path)
        if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
        add(display)   // the Finder's name in the Mac's language ("계산기")
        let bundle = Bundle(url: url)
        add(bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
        add(bundle?.localizedInfoDictionary?["CFBundleName"] as? String)
        add(bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
        add(bundle?.infoDictionary?["CFBundleName"] as? String)
        add(url.deletingPathExtension().lastPathComponent)
        return names
    }

    /// Apps in the Applications folders (one level of sub-folders), cached for a minute.
    private func installedApps() -> [PetAppEntry] {
        if let cache = installedCache, Date().timeIntervalSince(cache.at) < 60 { return cache.apps }
        let fm = FileManager.default
        var folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities"]
            .map { URL(fileURLWithPath: $0) }
        folders.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        var result: [PetAppEntry] = []
        func scan(_ folder: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            for url in items {
                if url.pathExtension == "app" {
                    guard let id = Bundle(url: url)?.bundleIdentifier, id != PetDesktopActions.ownBundleID else { continue }
                    result.append(PetAppEntry(bundleID: id, names: PetDesktopActions.names(of: url), running: false))
                } else if depth > 0, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          !folders.contains(url) {
                    scan(url, depth: depth - 1)
                }
            }
        }
        for folder in folders { scan(folder, depth: 1) }
        installedCache = (Date(), result)
        return result
    }

    private func runningEntries() -> [PetAppEntry] {
        runningApps().map { app in
            var names: [String] = []
            if let n = app.localizedName { names.append(n) }
            if let url = app.bundleURL { names += PetDesktopActions.names(of: url).filter { !names.contains($0) } }
            return PetAppEntry(bundleID: app.bundleIdentifier ?? "", names: names, running: true)
        }
    }

    private func running(_ bundleID: String) -> NSRunningApplication? {
        runningApps().first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    private enum Lookup {
        case app(PetAppEntry)
        case problem(PetCommandOutcome)
    }

    private func lookup(_ name: String, runningOnly: Bool) -> Lookup {
        let entries = runningOnly ? runningEntries() : runningEntries() + installedApps()
        switch PetAppMatcher.match(name, in: entries) {
        case let .found(entry): return .app(entry)
        case let .ambiguous(list):
            let names = list.map { "\($0.displayName) (\($0.bundleID))" }.joined(separator: ", ")
            return .problem(PetCommandOutcome(ok: false, message: "More than one app matches \"\(name)\": \(names). Ask the user which one.",
                                              details: ["candidates": list.map { $0.displayName }]))
        case let .none(suggestions):
            if runningOnly, case .found(let installed) = PetAppMatcher.match(name, in: installedApps()) {
                return .problem(PetCommandOutcome(ok: false, message: "\(installed.displayName) is not running. "
                                                  + "Use combo_open_app to open it."))
            }
            var text = "No \(runningOnly ? "running " : "")app on this Mac is named \"\(name)\"."
            if !suggestions.isEmpty { text += " Similar: \(suggestions.joined(separator: ", "))." }
            return .problem(PetCommandOutcome(ok: false, message: text, details: ["suggestions": suggestions]))
        }
    }

    private func listApps(installed: Bool) -> PetCommandOutcome {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = runningApps().map { app -> [String: Any] in
            ["name": app.localizedName ?? app.bundleIdentifier ?? "?", "bundle_id": app.bundleIdentifier ?? "",
             "front": app.processIdentifier == front, "hidden": app.isHidden]
        }
        var details: [String: Any] = ["running": apps]
        var text = "\(apps.count) apps are running: " + apps.compactMap { $0["name"] as? String }.joined(separator: ", ") + "."
        if installed {
            let names = PetAppMatcher.dedupe(installedApps()).map { $0.displayName }.sorted()
            details["installed"] = Array(names.prefix(300))
            text += " \(names.count) apps are installed\(names.count > 300 ? " (first 300 listed)" : "")."
        }
        return PetCommandOutcome(ok: true, message: text, details: details)
    }

    /// Brings a running app to the front through Launch Services (like `open -a`): since macOS 14 an app that is not
    /// active itself (Nacho Combo lives in the menu bar) may have `NSRunningApplication.activate` ignored.
    private func bringForward(_ app: NSRunningApplication, done: @escaping (Bool) -> Void) {
        if app.isHidden { app.unhide() }
        guard let url = app.bundleURL else {
            return done(app.activate(options: [.activateAllWindows]))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { opened, _ in
            DispatchQueue.main.async { done(opened != nil) }
        }
    }

    private func openApp(_ name: String, done: @escaping (PetCommandOutcome) -> Void) {
        let entry: PetAppEntry
        switch lookup(name, runningOnly: false) {
        case let .problem(o): return done(o)
        case let .app(e): entry = e
        }
        if let app = running(entry.bundleID) {
            return bringForward(app) { ok in
                done(ok ? PetCommandOutcome(ok: true, message: "\(entry.displayName) was already open; switched to it.")
                     : PetCommandOutcome(ok: false, message: "\(entry.displayName) is open but could not be brought to the front."))
            }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else {
            return done(PetCommandOutcome(ok: false, message: "\(entry.displayName) is not installed any more."))
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if app != nil {
                    done(PetCommandOutcome(ok: true, message: "Opened \(entry.displayName)."))
                } else {
                    done(PetCommandOutcome(ok: false, message: "\(entry.displayName) did not open: \(error?.localizedDescription ?? "unknown error")."))
                }
            }
        }
    }

    private func focusApp(_ name: String, done: @escaping (PetCommandOutcome) -> Void) {
        switch lookup(name, runningOnly: true) {
        case let .problem(o): done(o)
        case let .app(entry):
            guard let app = running(entry.bundleID) else { return done(PetCommandOutcome(ok: false, message: "\(entry.displayName) is not running.")) }
            bringForward(app) { ok in
                done(ok ? PetCommandOutcome(ok: true, message: "Switched to \(entry.displayName).")
                     : PetCommandOutcome(ok: false, message: "\(entry.displayName) could not be brought to the front."))
            }
        }
    }

    private func hideApp(_ name: String) -> PetCommandOutcome {
        switch lookup(name, runningOnly: true) {
        case let .problem(o): return o
        case let .app(entry):
            guard !PetAppMatcher.isProtected(entry.bundleID) else {
                return PetCommandOutcome(ok: false, message: "\(entry.displayName) is never hidden by Nacho.")
            }
            guard let app = running(entry.bundleID) else { return PetCommandOutcome(ok: false, message: "\(entry.displayName) is not running.") }
            if app.isHidden { return PetCommandOutcome(ok: true, message: "\(entry.displayName) was already hidden.") }
            // macOS may refuse `hide()` from an app that is not active (Nacho Combo lives in the menu bar); the
            // Accessibility attribute does the same as ⌘H.
            if app.hide() || (isTrusted() && AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                                                          kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success) {
                return PetCommandOutcome(ok: true, message: "Hid \(entry.displayName) (it keeps running).")
            }
            return PetCommandOutcome(ok: false, message: "\(entry.displayName) could not be hidden"
                                     + (isTrusted() ? "." : ". \(PetPermissionHelp.accessibility)"))
        }
    }

    private func quitApp(_ name: String, done: @escaping (PetCommandOutcome) -> Void) {
        switch lookup(name, runningOnly: true) {
        case let .problem(o): done(o)
        case let .app(entry):
            guard !PetAppMatcher.isProtected(entry.bundleID) else {
                return done(PetCommandOutcome(ok: false, message: "\(entry.displayName) is never quit by Nacho."))
            }
            guard let app = running(entry.bundleID) else { return done(PetCommandOutcome(ok: false, message: "\(entry.displayName) is not running.")) }
            // A normal quit: the app may ask to save first. Never forced.
            guard app.terminate() else { return done(PetCommandOutcome(ok: false, message: "\(entry.displayName) refused to quit.")) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                done(app.isTerminated ? PetCommandOutcome(ok: true, message: "Quit \(entry.displayName).")
                     : PetCommandOutcome(ok: false, message: "\(entry.displayName) is still open; it may be asking the user to save."))
            }
        }
    }

    // MARK: windows

    private var accessibilityMissing: PetCommandOutcome {
        PetCommandOutcome(ok: false, message: PetPermissionHelp.accessibility, details: ["needs_permission": "accessibility"])
    }

    private func screenFrames() -> (full: [CGRect], visible: [CGRect]) {
        (NSScreen.screens.map { $0.frame }, NSScreen.screens.map { $0.visibleFrame })
    }

    private func listWindows() -> PetCommandOutcome {
        guard isTrusted() else { return accessibilityMissing }
        let (full, visible) = screenFrames()
        let displays: [[String: Any]] = PetDisplays.ordered(full).enumerated().map { n, index in
            ["display": n + 1, "width": Int(full[index].width), "height": Int(full[index].height),
             "main": index == 0, "name": NSScreen.screens[index].localizedName]
        }
        var windows: [[String: Any]] = []
        for app in WindowLayoutKeeper.apps() {
            for (order, window) in WindowLayoutKeeper.windows(of: app).enumerated() {
                guard let frame = window.frame, windows.count < 60 else { continue }
                let index = WindowLayout.screenIndex(for: frame, screens: visible) ?? 0
                let screen = full[index]
                windows.append(["app": app.localizedName ?? app.bundleIdentifier ?? "?", "bundle_id": app.bundleIdentifier ?? "",
                                "window": order + 1, "display": PetDisplays.number(forIndex: index, screens: full) ?? 1,
                                // Points from the display's top-left corner.
                                "x": Int(frame.minX - screen.minX), "y": Int(screen.maxY - frame.maxY),
                                "width": Int(frame.width), "height": Int(frame.height)])
            }
        }
        let text = "\(displays.count) display\(displays.count == 1 ? "" : "s"), \(windows.count) window\(windows.count == 1 ? "" : "s") open."
        return PetCommandOutcome(ok: true, message: text, details: ["displays": displays, "windows": windows])
    }

    private func layoutWindows(_ items: [PetWindowPlacement]) -> PetCommandOutcome {
        guard isTrusted() else { return accessibilityMissing }
        let (full, visible) = screenFrames()
        let gap = CGFloat(snap.optionsProvider().snapGap)
        var parts: [PetPartResult] = []
        for item in items {
            let label = "\(item.app) \(item.position.rawValue)"
            let entry: PetAppEntry
            switch lookup(item.app, runningOnly: true) {
            case let .problem(o): parts.append(PetPartResult(name: label, ok: false, message: o.message)); continue
            case let .app(e): entry = e
            }
            guard let app = running(entry.bundleID) else {
                parts.append(PetPartResult(name: label, ok: false, message: "not running")); continue
            }
            if app.isHidden { app.unhide() }
            let windows = WindowLayoutKeeper.windows(of: app)
            guard windows.indices.contains(item.window - 1), let current = windows[item.window - 1].frame else {
                parts.append(PetPartResult(name: label, ok: false, message: "\(entry.displayName) has \(windows.count) open window\(windows.count == 1 ? "" : "s")"))
                continue
            }
            let screenIndex: Int
            if let number = item.display {
                guard let index = PetDisplays.index(forNumber: number, screens: full) else {
                    parts.append(PetPartResult(name: label, ok: false, message: "there is no display \(number) (this Mac has \(full.count))"))
                    continue
                }
                screenIndex = index
            } else {
                screenIndex = WindowLayout.screenIndex(for: current, screens: visible) ?? 0
            }
            let target = WindowLayout.target(for: item.position, in: visible[screenIndex], current: current, gap: gap, cycle: false)
            let window = windows[item.window - 1]
            let where_ = "\(item.position.displayName) on display \(PetDisplays.number(forIndex: screenIndex, screens: full) ?? 1)"
            snap.memory.remember(window.element, before: current, applied: target)
            switch PetDesktopActions.move(window, to: target) {
            case .placed:
                if let landed = window.frame { snap.memory.updateApplied(window.element, landed) }
                parts.append(PetPartResult(name: label, ok: true, message: "\(entry.displayName) moved to \(where_)"))
            case .movedOnly:
                if let landed = window.frame { snap.memory.updateApplied(window.element, landed) }
                parts.append(PetPartResult(name: label, ok: true, message: "\(entry.displayName) moved to the top-left of \(where_); "
                                           + "the app does not let its window be resized"))
            case let .failed(why):
                snap.memory.forget(window.element)
                parts.append(PetPartResult(name: label, ok: false, message: "\(entry.displayName) did not move (\(why))"))
            }
        }
        return PetPartResult.summary(parts)
    }

    enum MoveResult: Equatable { case placed, movedOnly, failed(String) }

    /// Puts a window at `target`. A window whose size the app fixes (Calculator) still moves: it goes to the target's
    /// top-left corner with its own size.
    static func move(_ window: AXWindow, to target: CGRect) -> MoveResult {
        do {
            try window.setFrame(target)
            return .placed
        } catch {
            guard let size = window.frame?.size else { return .failed("\(error)") }
            let corner = CGRect(x: target.minX, y: target.maxY - size.height, width: size.width, height: size.height)
            window.setPosition(ax: WindowLayout.accessibilityOrigin(forCocoa: corner, primaryScreenHeight: AXWindow.primaryHeight))
            guard let landed = window.frame, abs(landed.minX - corner.minX) <= 4, abs(landed.maxY - corner.maxY) <= 4 else {
                return .failed("\(error)")
            }
            return .movedOnly
        }
    }

    // MARK: system

    private func setSystem(_ change: PetSystemChange) -> PetCommandOutcome {
        var parts: [PetPartResult] = []
        if let volume = change.volume { parts.append(setVolume(volume)) }
        if let brightness = change.brightness { parts.append(BuiltInBrightness.set(brightness)) }
        if let dnd = change.doNotDisturb {
            parts.append(PetPartResult(name: "dnd", ok: false, message: "macOS 12 and later do not let apps switch "
                                       + "Do Not Disturb / Focus \(dnd ? "on" : "off"). The user can do it in Control Center (Focus)."))
        }
        return PetPartResult.summary(parts)
    }

    private func setVolume(_ percent: Int) -> PetPartResult {
        let device = CoreAudioBridge.defaultDevice(input: false)
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            return PetPartResult(name: "volume", ok: false, message: "there is no sound output device")
        }
        let value = Float32(percent) / 100
        CoreAudioBridge.setVolume(device, input: false, value)
        if percent > 0 { _ = CoreAudioBridge.setMute(device, input: false, false) }
        guard let now = CoreAudioBridge.volume(device, input: false), abs(now - value) < 0.02 else {
            return PetPartResult(name: "volume", ok: false, message: "the current sound output has no volume control Nacho Combo can set")
        }
        return PetPartResult(name: "volume", ok: true, message: "set to \(percent)%")
    }

    // MARK: gadgets

    private func setDimStrength(_ percent: Int) -> PetCommandOutcome {
        applyDimIntensity(Double(percent) / 100)
        let on = manager.states[.focusDim] == .running
        onChange?()
        return PetCommandOutcome(ok: true, message: "Focus Dim strength is now \(percent)%"
                                 + (on ? "." : " (Focus Dim is off; the strength is used when it is switched on)."))
    }

    private func clearShelf() -> PetCommandOutcome {
        let count = shelf.store.items.count
        guard shelf.running, count > 0 else {
            return PetCommandOutcome(ok: true, message: shelf.running ? "The File Shelf is already empty." : "The File Shelf is off; nothing to clear.")
        }
        shelf.clear()
        onChange?()
        return PetCommandOutcome(ok: true, message: "Emptied \(count) item\(count == 1 ? "" : "s") from the File Shelf "
                                 + "(original files are untouched; the shelf can undo this).")
    }

    // MARK: workspaces

    private func saveWorkspace(_ name: String) -> PetCommandOutcome {
        guard isTrusted() else { return accessibilityMissing }
        var apps: [DesktopWorkspace.App] = []
        var windows: [SavedWindow] = []
        for app in WindowLayoutKeeper.apps() {
            guard let bundleID = app.bundleIdentifier, !PetAppMatcher.isProtected(bundleID) || bundleID == "com.apple.finder" else { continue }
            apps.append(.init(bundleID: bundleID, name: app.localizedName ?? bundleID))
            for (order, window) in WindowLayoutKeeper.windows(of: app).enumerated() {
                guard let frame = window.frame else { continue }
                windows.append(SavedWindow(bundleID: bundleID, appName: app.localizedName ?? bundleID, frame: frame, order: order))
            }
        }
        var gadgets: [String: Bool] = [:]
        for id in PetCommands.toggleable { gadgets[id.rawValue] = manager.states[id] == .running }
        let workspace = DesktopWorkspace(name: name, savedAt: Date(), displays: WindowLayoutKeeper.currentSignature,
                                         apps: apps, windows: windows, gadgets: gadgets)
        var next = store
        let result = next.save(workspace)
        if result == .full {
            return PetCommandOutcome(ok: false, message: "There are already \(DesktopWorkspaceStore.maxWorkspaces) workspaces. "
                                     + "Ask the user to delete one in Nacho Combo settings (Nacho Pet) or to reuse a name.")
        }
        do { try next.write(to: storeURL) } catch {
            return PetCommandOutcome(ok: false, message: "The workspace could not be saved (\(error.localizedDescription)).")
        }
        store = next
        onChange?()
        return PetCommandOutcome(ok: true, message: "\(result == .replaced ? "Replaced" : "Saved") workspace \"\(name)\": \(workspace.summary).",
                                 details: ["workspace": describe(workspace)])
    }

    private func describe(_ w: DesktopWorkspace) -> [String: Any] {
        let f = ISO8601DateFormatter()
        return ["name": w.name, "apps": w.apps.map { $0.name }, "windows": w.windows.count,
                "gadgets_on": w.gadgets.filter { $0.value }.keys.sorted(), "saved_at": f.string(from: w.savedAt)]
    }

    private func listWorkspaces() -> PetCommandOutcome {
        store = DesktopWorkspaceStore.load(from: storeURL)
        guard !store.workspaces.isEmpty else {
            return PetCommandOutcome(ok: true, message: "No workspace is saved yet.", details: ["workspaces": [Any]()])
        }
        let text = store.workspaces.map { "\($0.name) (\($0.summary))" }.joined(separator: "; ")
        return PetCommandOutcome(ok: true, message: "\(store.workspaces.count) saved: \(text).",
                                 details: ["workspaces": store.workspaces.map(describe)])
    }

    func deleteWorkspace(named name: String) {
        var next = store
        guard next.remove(named: name) else { return }
        do { try next.write(to: storeURL) } catch { return }
        store = next
        onChange?()
    }

    /// Delays (seconds from the start) at which windows of apps that are still opening are placed again.
    static let placementRetries: [TimeInterval] = [0, 1.5, 3, 5, 8]

    private func applyWorkspace(_ name: String, done: @escaping (PetCommandOutcome) -> Void) {
        store = DesktopWorkspaceStore.load(from: storeURL)
        guard let workspace = store.workspace(named: name) else {
            let names = store.workspaces.map { $0.name }
            return done(PetCommandOutcome(ok: false, message: "No workspace is named \"\(name)\"."
                                          + (names.isEmpty ? " None is saved yet." : " Saved: \(names.joined(separator: ", ")).")))
        }
        var report = WorkspaceApplyReport(name: workspace.name)
        report.savedWindows = workspace.windows.count
        // Gadgets first: one that needs a permission it does not have is not switched on from the chat.
        for (id, on) in workspace.gadgetSwitches {
            let isOn = manager.states[id] == .running
            guard on != isOn else { continue }
            if on, let permission = id.info.requiredPermission, permissionGranted(permission) != true {
                report.gadgetsRefused.append("\(id.displayName) needs the \(permission.displayName) permission")
                continue
            }
            let state = manager.setEnabled(id, on)
            if (state == .running) == on { report.gadgetsChanged.append("\(id.displayName) \(on ? "on" : "off")") }
            else { report.gadgetsRefused.append("\(id.displayName): \(state.label.lowercased())") }
        }
        // Apps: open what is missing (in the background), never quit anything.
        let group = DispatchGroup()
        for app in workspace.apps where running(app.bundleID) == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                report.missingApps.append(app.name)
                continue
            }
            group.enter()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { opened, _ in
                DispatchQueue.main.async {
                    if opened != nil { report.openedApps.append(app.name) } else { report.failedApps.append(app.name) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            guard self.isTrusted() else {
                report.windowsNeedPermission = true
                self.onChange?()
                return done(report.outcome)
            }
            var placed = Set<String>()
            let start = Date()
            func attempt(_ step: Int) {
                for key in self.place(workspace) { placed.insert(key) }
                report.placedWindows = placed.count
                let next = step + 1
                if placed.count >= workspace.windows.count || next >= PetDesktopActions.placementRetries.count {
                    self.onChange?()
                    return done(report.outcome)
                }
                let wait = max(0, PetDesktopActions.placementRetries[next] - Date().timeIntervalSince(start))
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { attempt(next) }
            }
            attempt(0)
        }
    }

    /// Moves the open windows to their saved frames; returns "bundle#order" of each window placed.
    private func place(_ workspace: DesktopWorkspace) -> [String] {
        var placed: [String] = []
        for app in WindowLayoutKeeper.apps() {
            guard let bundleID = app.bundleIdentifier else { continue }
            let saved = workspace.windows.filter { $0.bundleID == bundleID }
            guard !saved.isEmpty else { continue }
            let windows = WindowLayoutKeeper.windows(of: app)
            let current = windows.indices.map { (bundleID: bundleID, order: $0) }
            for (index, frame) in LayoutMatching.assign(saved: saved, current: current) {
                if case .failed = PetDesktopActions.move(windows[index], to: WindowLayoutKeeper.fitted(frame)) { continue }
                placed.append("\(bundleID)#\(index)")
            }
        }
        return placed
    }
}

/// Built-in display brightness through DisplayServices (looked up at run time; missing on Macs without a built-in
/// display and on some versions, in which case Nacho says so).
enum BuiltInBrightness {
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let setter: Setter? = symbol("DisplayServicesSetBrightness")
    private static let getter: Getter? = symbol("DisplayServicesGetBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let library = library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func set(_ percent: Int) -> PetPartResult {
        guard let display = builtInDisplay else {
            return PetPartResult(name: "brightness", ok: false, message: "this Mac has no built-in display; external monitors' "
                                 + "brightness is not set by Nacho (the Device Control gadget has a slider for monitors that support DDC)")
        }
        guard let setter = setter else {
            return PetPartResult(name: "brightness", ok: false, message: "this macOS does not let Nacho Combo set the brightness")
        }
        let value = Float(percent) / 100
        guard setter(display, value) == 0 else {
            return PetPartResult(name: "brightness", ok: false, message: "the display refused the brightness change")
        }
        if let getter = getter {
            var now: Float = -1
            if getter(display, &now) == 0, abs(now - value) > 0.05 {
                return PetPartResult(name: "brightness", ok: false, message: "the brightness stayed at \(Int((now * 100).rounded()))%")
            }
        }
        return PetPartResult(name: "brightness", ok: true, message: "set to \(percent)%")
    }
}
