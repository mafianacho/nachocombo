import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-195: the Computer Use gadget is one switch (the card shows a short line, the emergency stop and a line for each
/// missing OS permission), and everything about the server moved to Settings ▸ MCP. Both are drawn off screen on macOS
/// CI (light and dark), with the OS permissions answered by the test, not a real Mac. Keys and the account are TEST
/// FIXTURES; a key value is never shown. Pictures go to .build/bento-captures and, base64 in chunks, to the test log
/// (BENTO-CAPTURE lines) for CI.
final class ComputerUseSimplifyCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        ComputerUseModule.permissionOverride = nil
        super.tearDown()
    }

    private final class StubModule: FeatureModule {
        let id: ModuleID
        init(_ id: ModuleID) { self.id = id }
        func start() -> ModuleState { .running }
        func stop() {}
        var diagnostics: [String: String] { [:] }
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func world() -> (ModuleManager, ComputerUseModule) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nc-cap-\(UUID().uuidString)/settings.json")
        let manager = ModuleManager(store: SettingsStore(url: url), modules: [StubModule(.computerUse)])
        let module = ComputerUseModule(keys: APIKeyStore(url: nil))
        module.currentSettings = { manager.settings.computerUse }
        module.gadgetOn = { manager.settings.isEnabled(.computerUse) }
        return (manager, module)
    }

    private func grant(accessibility: Bool, screen: Bool) {
        ComputerUseModule.permissionOverride = { $0 == .accessibility ? accessibility : $0 == .screenRecording ? screen : true }
    }

    /// The gadget page the way the settings window builds it: the header with its one switch, then the card.
    private func gadgetPage(on: Bool, accessibility: Bool, screen: Bool) -> NSView {
        grant(accessibility: accessibility, screen: screen)
        let (manager, module) = world()
        if on { _ = manager.setEnabled(.computerUse, true) }
        let card = ComputerUseGadgetCard(module: module, manager: manager, width: GadgetDetailView.cardInner)
        card.refresh(state: on ? .running : .off)
        let icon = NSImageView(image: GadgetIcon.image(for: .computerUse, size: 32))
        let title = UI.label("Computer Use", style: .title2, weight: .bold)
        let toggle = NSSwitch()
        toggle.state = on ? .on : .off
        toggle.setAccessibilityLabel("Computer Use")
        let header = UI.hstack([icon, title, UI.spacer(), toggle], spacing: 10)
        header.widthAnchor.constraint(equalToConstant: GadgetDetailView.cardInner).isActive = true
        return UI.vstack([header, card.view], spacing: 14)
    }

    private func mcpPage(_ configure: (ModuleManager, ComputerUseModule) -> Void) -> NSView {
        grant(accessibility: true, screen: true)
        let (manager, module) = world()
        _ = manager.setEnabled(.computerUse, true)
        configure(manager, module)
        let card = ComputerUseCard(module: module, manager: manager, width: GadgetDetailView.cardInner)
        card.refresh(state: .running)
        return MCPPage(body: card.view)
    }

    @discardableResult
    private func capture(_ content: NSView, name: String, dark: Bool, margin: CGFloat = 24) throws -> Data {
        let background = DetailBackgroundView()
        background.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: margin),
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: margin),
        ])
        let width = max(content.fittingSize.width, GadgetDetailView.cardInner) + margin * 2
        background.setFrameSize(NSSize(width: width, height: 10))
        background.layoutSubtreeIfNeeded()
        background.setFrameSize(NSSize(width: width, height: content.fittingSize.height + margin * 2))
        background.layoutSubtreeIfNeeded()
        background.displayIfNeeded()
        let rep = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
        background.cacheDisplay(in: background.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try emit(png, name: "\(name)-\(dark ? "dark" : "light")")
        return png
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
        XCTAssertGreaterThan(png.count, 2_000, "\(name) is not empty")
    }

    private func texts(in view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField, !field.isHidden { out.append(field.stringValue) }
        for sub in view.subviews where !sub.isHidden { out += texts(in: sub) }
        return out
    }

    // MARK: Computer Use gadget

    func testGadgetScreenIsOneSwitchOffOnMissingDone() throws {
        for dark in [false, true] {
            let off = gadgetPage(on: false, accessibility: false, screen: false)
            try capture(off, name: "cu-gadget-off", dark: dark)
            XCTAssertFalse(texts(in: off).contains { $0.contains("permission is needed") }, "off: no permission line")

            let on = gadgetPage(on: true, accessibility: true, screen: true)
            try capture(on, name: "cu-gadget-on", dark: dark)
            XCTAssertFalse(texts(in: on).contains { $0.contains("permission is needed") }, "both allowed: no line")

            let missing = gadgetPage(on: true, accessibility: false, screen: true)
            try capture(missing, name: "cu-gadget-permission-missing", dark: dark)
            let lines = texts(in: missing).filter { $0.contains("permission is needed") }
            XCTAssertEqual(lines, ["Accessibility permission is needed"], "only the missing permission shows")

            let done = gadgetPage(on: true, accessibility: true, screen: true)
            try capture(done, name: "cu-gadget-permission-done", dark: dark)
            XCTAssertTrue(texts(in: done).filter { $0.contains("permission is needed") }.isEmpty)
        }
    }

    func testGadgetScreenHasNoServerControls() throws {
        let page = gadgetPage(on: true, accessibility: true, screen: true)
        let all = texts(in: page).joined(separator: "\n")
        for word in ["Port", "LAN", "TLS", "Tool Groups", "API Keys", "Recent Calls", "Fingerprint"] {
            XCTAssertFalse(all.contains(word), "\(word) moved to Settings ▸ MCP")
        }
    }

    // MARK: Settings ▸ MCP

    func testMCPPageFull() throws {
        for dark in [false, true] {
            let page = mcpPage { manager, _ in
                manager.setComputerUse { $0.serverEnabled = true; $0.setGadgetEnabled(.window, true); $0.setGadgetEnabled(.monitor, true) }
            }
            try capture(page, name: "mcp-page", dark: dark)
            let all = texts(in: page).joined(separator: "\n")
            for word in ["MCP Server", "Computer Use Tool Groups", "Gadget Tools", "API Keys", "Recent Calls", "Client Connection Example"] {
                XCTAssertTrue(all.contains(word), "\(word) is on the MCP page")
            }
        }
    }

    func testMCPPageAfterKeyIssued() throws {
        for dark in [false, true] {
            let page = mcpPage { manager, module in
                manager.setComputerUse { $0.serverEnabled = true }
                _ = try? module.keys.create(label: "Laptop")
            }
            try capture(page, name: "mcp-key-issued", dark: dark)
            XCTAssertTrue(texts(in: page).contains { $0.contains("Laptop") })

            // The dialog that shows a key once, with the value masked (the real value is never drawn or logged).
            let alert = ComputerUseCard.revealAlert(title: "New key “Laptop”", token: "••••••••••••••••••••••••••••••••")
            alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            alert.layout()
            let view = try XCTUnwrap(alert.window.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try emit(try XCTUnwrap(rep.representation(using: .png, properties: [:])), name: "mcp-key-reveal-masked-\(dark ? "dark" : "light")")
        }
    }

    func testMCPPageLANOn() throws {
        for dark in [false, true] {
            let page = mcpPage { manager, _ in manager.setComputerUse { $0.serverEnabled = true; $0.listenMode = .lan } }
            try capture(page, name: "mcp-lan-on", dark: dark)
            let all = texts(in: page).joined(separator: "\n")
            XCTAssertTrue(all.contains("TLS Certificate Fingerprint"))
            XCTAssertTrue(all.contains("Connection Addresses"))
        }
    }
}
