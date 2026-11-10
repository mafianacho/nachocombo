import AppKit
import ApplicationServices
import CoreGraphics
import NachoComboCore

/// Runs the MCP tools on macOS. The Core service has already checked key, emergency stop and the group switch;
/// every tool still validates its own arguments (Core policies) and the OS permission it needs, and never logs
/// arguments or results.
///
/// NOT yet verified on a Mac (the boss forbade running it for now): this file is written to compile, nothing more.
final class MacComputerUseBackend: ComputerUseBackend {
    let filePolicy: FilePolicy
    let shell = ProcessRunner()

    init() {
        let appSupport = SettingsStore.defaultURL().deletingLastPathComponent().path
        filePolicy = FilePolicy(home: NSHomeDirectory(), protectedPaths: [appSupport])
    }

    /// Called when the module is switched off: stops a shell command that may still be running.
    func shutdown() { shell.terminateRunning() }

    func execute(tool: String, arguments: [String: JSONValue]) -> ToolResult {
        let args = ToolArguments(arguments)
        do {
            switch tool {
            // screen
            case "screen_list_displays": return try listDisplays()
            case "screen_capture": return try capture(args)
            // apps and windows
            case "app_list": return listApps()
            case "app_open": return try openApp(args)
            case "app_activate": return try withApp(args) { app in
                app.activate(options: [.activateIgnoringOtherApps]) ? "Activated" : "Could not activate" }
            case "app_quit": return try withApp(args) { app in
                guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return "Nacho Combo cannot quit itself" }
                return app.terminate() ? "Quit requested" : "Quit request was refused" }
            case "window_list": return try listWindows()
            case "window_set_frame": return try setWindowFrame(args)
            case "window_minimize": return try minimizeWindow(args)
            // input
            case "mouse_move": return try mouseMove(args)
            case "mouse_click": return try mouseClick(args)
            case "mouse_drag": return try mouseDrag(args)
            case "mouse_scroll": return try mouseScroll(args)
            case "key_press": return try keyPress(args)
            case "type_text": return try typeText(args)
            // clipboard
            case "clipboard_read": return clipboardRead()
            case "clipboard_write": return try clipboardWrite(args)
            // open
            case "open_url": return try openURL(args)
            case "open_file": return try openFile(args)
            // system
            case "system_info": return systemInfo()
            case "process_list": return processList()
            // high risk
            case "applescript_run": return try runAppleScript(args)
            case "shell_run": return try runShell(args)
            case "file_read": return try readFile(args)
            case "file_write": return try writeFile(args)
            case "process_kill": return try killProcess(args)
            default: return .error("Unsupported tool")
            }
        } catch let error as ToolArgumentError {
            return .error(error.message)
        } catch let error as PolicyError {
            return .error(error.message)
        } catch {
            return .error("Could not run: \(error.localizedDescription)")
        }
    }

    // MARK: shared helpers

    func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    func json(_ value: JSONValue) -> ToolResult {
        .text(String(data: JSONRPCCodec.encode(value), encoding: .utf8) ?? "{}")
    }

    func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw PolicyError("Accessibility permission is missing. Allow it for Nacho Combo in System Settings on the Mac.")
        }
    }

    func requireScreenRecording() throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw PolicyError("Screen Recording permission is missing. Allow it for Nacho Combo in System Settings on the Mac.")
        }
    }

    func rectJSON(_ rect: CGRect) -> JSONValue {
        .object(["x": .double(Double(rect.origin.x)), "y": .double(Double(rect.origin.y)),
                 "width": .double(Double(rect.size.width)), "height": .double(Double(rect.size.height))])
    }

    // MARK: apps

    private func listApps() -> ToolResult {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let items: [JSONValue] = apps.map { app in
            .object(["name": .string(app.localizedName ?? ""), "bundleId": .string(app.bundleIdentifier ?? ""),
                     "pid": .int(Int(app.processIdentifier)), "active": .bool(app.isActive), "hidden": .bool(app.isHidden)])
        }
        return json(.object(["apps": .array(items)]))
    }

    private func openApp(_ args: ToolArguments) throws -> ToolResult {
        var url: URL?
        if let bundleId = try args.optionalString("bundleId") {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        } else if let name = try args.optionalString("name") {
            let clean = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            guard !clean.isEmpty, !clean.contains("/") else { throw PolicyError("Invalid app name") }
            for folder in ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities"] {
                let candidate = URL(fileURLWithPath: folder).appendingPathComponent(clean + ".app")
                if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; break }
            }
        } else {
            throw ToolArgumentError("bundleId or name is required")
        }
        guard let appURL = url else { throw PolicyError("App not found") }
        let done = DispatchSemaphore(value: 0)
        var failure: String?
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error { failure = error.localizedDescription }
            done.signal()
        }
        if done.wait(timeout: .now() + 15) == .timedOut { throw PolicyError("The app did not finish launching in time") }
        if let failure = failure { throw PolicyError("Could not launch the app: \(failure)") }
        return .text("Launched")
    }

    private func withApp(_ args: ToolArguments, _ action: (NSRunningApplication) -> String) throws -> ToolResult {
        var app: NSRunningApplication?
        if let pid = try args.optionalInt("pid") {
            app = NSRunningApplication(processIdentifier: pid_t(pid))
        } else if let bundleId = try args.optionalString("bundleId") {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
        } else {
            throw ToolArgumentError("pid or bundleId is required")
        }
        guard let target = app else { throw PolicyError("Running app not found") }
        return .text(action(target))
    }

    // MARK: windows

    private func listWindows() throws -> ToolResult {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw PolicyError("Could not read the window list")
        }
        var indexByPid: [Int: Int] = [:]
        var items: [JSONValue] = []
        for info in raw {
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? Int,
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            let index = indexByPid[pid] ?? 0
            indexByPid[pid] = index + 1
            var bounds = CGRect.zero
            if let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) { bounds = rect }
            items.append(.object([
                "windowId": .int(number), "pid": .int(pid), "index": .int(index),
                "app": .string(info[kCGWindowOwnerName as String] as? String ?? ""),
                // The title is only present when the Screen Recording permission is granted.
                "title": .string(info[kCGWindowName as String] as? String ?? ""),
                "frame": rectJSON(bounds),
            ]))
        }
        return json(.object(["windows": .array(items)]))
    }

    /// The `windowIndex`-th window of the app, in the order the accessibility API reports them (front to back).
    private func axWindow(_ args: ToolArguments) throws -> AXUIElement {
        try requireAccessibility()
        let pid = try args.int("pid")
        let index = try args.int("windowIndex")
        guard index >= 0 else { throw ToolArgumentError("windowIndex must be 0 or greater") }
        var windowsRef: CFTypeRef?
        let app = AXUIElementCreateApplication(pid_t(pid))
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], index < windows.count else {
            throw PolicyError("Window not found")
        }
        return windows[index]
    }

    private func axFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pos = posRef, let size = sizeRef else { return nil }
        var origin = CGPoint.zero, dimension = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &dimension)
        return CGRect(origin: origin, size: dimension)
    }

    private func setWindowFrame(_ args: ToolArguments) throws -> ToolResult {
        let window = try axWindow(args)
        guard var frame = axFrame(window) else { throw PolicyError("Could not read the window position") }
        let x = try args.optionalDouble("x"), y = try args.optionalDouble("y")
        let width = try args.optionalDouble("width"), height = try args.optionalDouble("height")
        if x == nil, y == nil, width == nil, height == nil { throw ToolArgumentError("At least one of x, y, width, height is required") }
        if let x = x, let y = y { try InputPolicy.validatePoint(x: x, y: y) }
        if let w = width, w < 50 || w > 20_000 { throw ToolArgumentError("width is out of range") }
        if let h = height, h < 50 || h > 20_000 { throw ToolArgumentError("height is out of range") }
        if let x = x { frame.origin.x = CGFloat(x) }
        if let y = y { frame.origin.y = CGFloat(y) }
        if let w = width { frame.size.width = CGFloat(w) }
        if let h = height { frame.size.height = CGFloat(h) }
        var origin = frame.origin, size = frame.size
        // position -> size -> position: some apps clamp the first move to the old size (same order as the window layout gadget).
        guard let positionValue = AXValueCreate(.cgPoint, &origin), let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw PolicyError("Could not build the window values")
        }
        guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success else {
            throw PolicyError("Could not move the window (the app may have refused)")
        }
        return json(.object(["frame": rectJSON(axFrame(window) ?? frame)]))
    }

    private func minimizeWindow(_ args: ToolArguments) throws -> ToolResult {
        let window = try axWindow(args)
        let minimized = try args.optionalBool("minimized") ?? true
        guard AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                           NSNumber(value: minimized) as CFTypeRef) == .success else {
            throw PolicyError("Could not change the window minimized state")
        }
        return .text(minimized ? "Minimized" : "Restored")
    }

    // MARK: clipboard / open

    private func clipboardRead() -> ToolResult {
        let text = onMain { NSPasteboard.general.string(forType: .string) }
        guard let value = text else { return .text("(No text on the clipboard)") }
        return .text(String(value.prefix(262_144)))
    }

    private func clipboardWrite(_ args: ToolArguments) throws -> ToolResult {
        let text = try args.string("text")
        guard text.count <= 262_144 else { throw PolicyError("Text is too long") }
        let ok = onMain { () -> Bool in
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(text, forType: .string)
        }
        return ok ? .text("Wrote to the clipboard") : .error("Could not write to the clipboard")
    }

    private func openURL(_ args: ToolArguments) throws -> ToolResult {
        let url = try OpenPolicy.validateURL(try args.string("url"))
        let opened = onMain { NSWorkspace.shared.open(url) }
        return opened ? .text("Opened") : .error("Could not open")
    }

    private func openFile(_ args: ToolArguments) throws -> ToolResult {
        let path = try OpenPolicy.validateFilePath(try args.string("path"))
        let url = URL(fileURLWithPath: path)
        // A symlink must not smuggle in an executable kind of file.
        _ = try OpenPolicy.validateFilePath(url.resolvingSymlinksInPath().path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PolicyError("File not found") }
        let opened = onMain { NSWorkspace.shared.open(url) }
        return opened ? .text("Opened") : .error("Could not open")
    }
}
