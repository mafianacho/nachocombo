import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// Nacho's desktop actions run for real on the CI Mac (a macOS runner VM, not a user's Mac): open / switch / hide
/// apps, several windows arranged at once, a workspace saved → windows moved → workspace put back, the system
/// controls this Mac does not support, and the settings section without the Accessibility permission. Screen pictures
/// go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines). Whether the runner grants
/// Accessibility / Screen Recording to the test process is printed (DESKTOP-LIVE lines); window steps that need it are
/// checked only when it is granted, the no-permission answers are checked when it is not.
final class PetDesktopLiveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
    }

    /// The main display as the runner shows it, scaled to 1280 wide, with a caption bar on top.
    private func screenShot(_ name: String, caption: String) {
        guard let image = CGDisplayCreateImage(CGMainDisplayID()) else {
            print("DESKTOP-LIVE capture \(name): no image")
            return
        }
        let scale = min(1, 1280 / CGFloat(image.width))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h + 28, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        NSColor.white.setFill()
        NSRect(x: 0, y: h, width: w, height: 28).fill()
        let text = "\(caption)  ·  macOS CI runner (\(ProcessInfo.processInfo.operatingSystemVersionString)), not a user's Mac" as NSString
        text.draw(at: NSPoint(x: 10, y: h + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                                 .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep.representation(using: .png, properties: [:]) { try? emit(png, name: name) }
    }

    private func makeDesktop(store: URL) -> (PetDesktopActions, ModuleManager) {
        let dir = store.deletingLastPathComponent()
        let snap = WindowSnapModule()
        let shelf = ShelfModule(store: ShelfStore(ownedDirectory: dir.appendingPathComponent("shelf")))
        let manager = ModuleManager(store: SettingsStore(url: dir.appendingPathComponent("settings.json")), modules: [snap, shelf])
        return (PetDesktopActions(manager: manager, snap: snap, shelf: shelf, storeURL: store), manager)
    }

    /// Runs one command the way the chat does (parse, then the executor) and waits for its answer.
    private func ask(_ desktop: PetDesktopActions, _ capability: String, _ params: [String: Any]? = nil,
                     timeout: TimeInterval = 30) -> PetCommandOutcome {
        guard case let .success(command) = PetCommands.parse(capability: capability, params: params) else {
            XCTFail("\(capability) was refused by the parser")
            return PetCommandOutcome(ok: false, message: "refused")
        }
        let answered = expectation(description: capability)
        var result = PetCommandOutcome(ok: false, message: "no answer")
        XCTAssertTrue(desktop.run(command) { outcome in
            result = outcome
            answered.fulfill()
        })
        wait(for: [answered], timeout: timeout)
        let json = (try? JSONSerialization.data(withJSONObject: result.resultJSON, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "?"
        print("DESKTOP-LIVE \(capability) \(json.prefix(1500))")
        return result
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func frames(_ desktop: PetDesktopActions, bundleIDs: [String]) -> [String: [Int]] {
        let o = ask(desktop, "combo_list_windows")
        var result: [String: [Int]] = [:]
        for w in (o.resultJSON["windows"] as? [[String: Any]]) ?? [] {
            guard let id = w["bundle_id"] as? String, bundleIDs.contains(id), (w["window"] as? Int) == 1 else { continue }
            result[id] = ["x", "y", "width", "height"].compactMap { w[$0] as? Int }
        }
        return result
    }

    func testDesktopActionsOnTheCIMac() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pet-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (desktop, _) = makeDesktop(store: dir.appendingPathComponent("workspaces.json"))
        let trusted = AXIsProcessTrusted()
        print("DESKTOP-LIVE accessibility=\(trusted) screens=\(NSScreen.screens.map { NSStringFromRect($0.frame) })")
        screenShot("desktop-0-start", caption: "⓪ start")

        // Apps: names are matched against running and installed apps (English names on the runner).
        let list = ask(desktop, "combo_list_apps", ["installed": true])
        XCTAssertTrue(list.ok)
        let installed = (list.resultJSON["installed"] as? [String]) ?? []
        XCTAssertTrue(installed.contains("Calculator"), "installed apps: \(installed.prefix(40))")

        let opened = ask(desktop, "combo_open_app", ["app": "calculator"])
        XCTAssertTrue(opened.ok, opened.message)
        let monitor = ask(desktop, "combo_open_app", ["app": "com.apple.ActivityMonitor"])
        XCTAssertTrue(monitor.ok, monitor.message)
        settle(4)
        screenShot("desktop-1-opened", caption: "① 계산기·활성 상태 보기 열기 (combo_open_app)")
        let switched = ask(desktop, "combo_focus_app", ["app": "Calculator"])
        XCTAssertTrue(switched.ok, switched.message)
        settle(2)
        screenShot("desktop-2-focused", caption: "② 계산기로 전환 (combo_focus_app)")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.calculator")
        let unknown = ask(desktop, "combo_open_app", ["app": "Photoshop 2099"])
        XCTAssertFalse(unknown.ok)
        XCTAssertTrue(unknown.message.contains("No app"), unknown.message)
        let hidden = ask(desktop, "combo_hide_app", ["app": "Calculator"])
        XCTAssertTrue(hidden.ok, hidden.message)
        let finder = ask(desktop, "combo_hide_app", ["app": "Finder"])
        XCTAssertFalse(finder.ok, "Finder is never hidden")

        // System: what this Mac cannot do is answered with the reason.
        let system = ask(desktop, "combo_set_system", ["volume": 30, "brightness": 60, "dnd": true])
        let parts = (system.resultJSON["results"] as? [[String: Any]]) ?? []
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.last?["ok"] as? Bool, false)
        XCTAssertTrue((parts.last?["message"] as? String ?? "").contains("Do Not Disturb"))

        // Workspaces and windows.
        let ids = ["com.apple.ActivityMonitor", "com.apple.calculator"]
        guard trusted else {
            let windows = ask(desktop, "combo_list_windows")
            XCTAssertFalse(windows.ok)
            XCTAssertTrue(windows.message.contains("Privacy & Security > Accessibility"), windows.message)
            let saved = ask(desktop, "combo_workspace_save", ["name": "업무 모드"])
            XCTAssertFalse(saved.ok)
            XCTAssertEqual(saved.resultJSON["needs_permission"] as? String, "accessibility")
            print("DESKTOP-LIVE windows skipped: the runner gives this test no Accessibility permission")
            return
        }
        _ = ask(desktop, "combo_focus_app", ["app": "Calculator"])
        settle(2)
        screenShot("desktop-3-layout-before", caption: "③ 여러 창 배치 전")
        let layout = ask(desktop, "combo_layout_windows", ["items": [["app": "Activity Monitor", "position": "left"],
                                                                     ["app": "Calculator", "position": "top-right"]]])
        print("DESKTOP-LIVE layout ok=\(layout.ok)")
        settle(2)
        screenShot("desktop-4-layout-after", caption: "④ 여러 창 배치 후: 활성 상태 보기 왼쪽 반, 계산기 오른쪽 위 (combo_layout_windows)")
        let arranged = frames(desktop, bundleIDs: ids)

        let saved = ask(desktop, "combo_workspace_save", ["name": "업무 모드"])
        XCTAssertTrue(saved.ok, saved.message)
        _ = ask(desktop, "combo_layout_windows", ["items": [["app": "Activity Monitor", "position": "center"],
                                                            ["app": "Calculator", "position": "bottom-left"]]])
        settle(2)
        screenShot("desktop-5-moved", caption: "⑤ 작업 공간 저장 뒤 다른 배치로 바꿈")
        let moved = frames(desktop, bundleIDs: ids)
        XCTAssertNotEqual(moved, arranged, "the second layout moved the windows")
        let applied = ask(desktop, "combo_workspace_apply", ["name": "업무모드"], timeout: 40)
        XCTAssertTrue(applied.ok, applied.message)
        settle(2)
        screenShot("desktop-6-applied", caption: "⑥ '업무 모드' 작업 공간 적용 (combo_workspace_apply)")
        let back = frames(desktop, bundleIDs: ids)
        for id in ids {
            guard let a = arranged[id], let b = back[id], a.count == 4, b.count == 4 else { continue }
            for k in 0..<4 { XCTAssertEqual(Double(a[k]), Double(b[k]), accuracy: 6, "\(id) frame \(a) → \(b)") }
        }
        let listed = ask(desktop, "combo_workspace_list")
        XCTAssertTrue(listed.message.contains("업무 모드"))
        for id in ids { NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() } }
    }

    /// The Nacho Pet settings section without the permission and with two saved workspaces (AppKit off-screen render).
    func testSettingsSectionWithoutAccessibility() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pet-desktop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("workspaces.json")
        var store = DesktopWorkspaceStore()
        // TEST FIXTURE: two workspaces as saved by Nacho.
        _ = store.save(DesktopWorkspace(name: "집중 모드", savedAt: Date(timeIntervalSince1970: 1_794_000_000), displays: "",
                                        apps: [.init(bundleID: "com.apple.Notes", name: "메모")],
                                        windows: [SavedWindow(bundleID: "com.apple.Notes", appName: "메모", frame: .zero, order: 0)],
                                        gadgets: ["focusDim": true]))
        _ = store.save(DesktopWorkspace(name: "업무 모드", savedAt: Date(timeIntervalSince1970: 1_794_100_000), displays: "",
                                        apps: [.init(bundleID: "com.apple.Safari", name: "Safari"), .init(bundleID: "com.apple.Notes", name: "메모")],
                                        windows: [], gadgets: ["windowSnap": true, "keepAwake": true]))
        try store.write(to: url)
        let (desktop, _) = makeDesktop(store: url)
        desktop.isTrusted = { false }
        let section = PetWorkspaceSettingsSection(desktop: desktop, width: 420)
        let answer = ask(desktop, "combo_list_windows")
        XCTAssertFalse(answer.ok)
        XCTAssertTrue(answer.message.contains("손쉬운 사용"))

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        section.view.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(section.view)
        NSLayoutConstraint.activate([section.view.topAnchor.constraint(equalTo: bg.topAnchor, constant: 16),
                                     section.view.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
                                     section.view.widthAnchor.constraint(equalToConstant: 420)])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 452, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = bg
        bg.layoutSubtreeIfNeeded()
        let height = section.view.fittingSize.height + 32
        window.setContentSize(NSSize(width: 452, height: height))
        bg.layoutSubtreeIfNeeded()
        bg.displayIfNeeded()
        let rep = try XCTUnwrap(bg.bitmapImageRepForCachingDisplay(in: bg.bounds))
        bg.cacheDisplay(in: bg.bounds, to: rep)
        try emit(try XCTUnwrap(rep.representation(using: .png, properties: [:])), name: "desktop-7-settings-no-permission")

        // Delete removes the workspace from the file.
        let texts = allText(section.view)
        XCTAssertTrue(texts.contains { $0.contains("not allowed") })
        XCTAssertTrue(texts.contains("업무 모드"))
        desktop.deleteWorkspace(named: "업무 모드")
        section.refresh()
        XCTAssertEqual(DesktopWorkspaceStore.load(from: url).workspaces.map { $0.name }, ["집중 모드"])
        XCTAssertFalse(allText(section.view).contains("업무 모드"))
    }

    private func allText(_ view: NSView) -> [String] {
        var out: [String] = []
        if let f = view as? NSTextField, !f.isHidden { out.append(f.stringValue) }
        for v in view.subviews { out += allText(v) }
        return out
    }
}
