import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// Draws the real AppKit widget board (main light/dark, edit mode with the size panel, the menu bar mini board) off
/// screen, so the design can be compared with the app without a Mac at hand. The values below are a TEST FIXTURE
/// in the state of the design pictures (b1–b4); the app itself only ever shows what its modules report.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class BentoCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    final class FixtureHost: BentoHost {
        var layout: BentoLayout
        var pinned: Set<ModuleID> = [.systemMonitor, .keepAwake, .nachoPet, .clipboard]
        let now = Date()

        init() {
            // The design's order (b1) regardless of which tools are on.
            layout = BentoLayout(items: BentoLayout.designOrder.map { BentoItem(id: $0.rawValue, size: BentoLayout.defaultSize($0)) })
        }

        var bentoLayout: BentoLayout { layout }
        func bentoUpdateLayout(_ change: (inout BentoLayout) -> Void) { change(&layout) }
        func bentoPetImage(signedIn: Bool) -> NSImage? { PetArt.image(signedIn ? .idle : .waiting) }
        func bentoSetEnabled(_ id: ModuleID, _ on: Bool) {}
        func bentoSetPinned(_ id: ModuleID, _ pinned: Bool) { if pinned { self.pinned.insert(id) } else { self.pinned.remove(id) } }
        func bentoOpen(_ id: ModuleID) {}
        func bentoPerform(_ id: ModuleID) {}
        func bentoOpenSettings() {}
        func bentoOpenBoard() {}

        private func status(_ dot: StatusDotKind) -> ToolStatusPresentation {
            ToolStatusPresentation(dot: dot, stateText: "", detail: nil, accessibilityText: "")
        }

        func bentoWidget(_ id: ModuleID) -> BentoWidget {
            let on: Set<ModuleID> = [.nachoPet, .systemMonitor, .computerUse, .windowSnap, .keepAwake, .clipboard, .captureFloat,
                                     .deviceControl, .calendarClock]
            let setup: Set<ModuleID> = [.nachoPet, .computerUse]
            let dot: StatusDotKind = setup.contains(id) ? .onNeedsSetup : (on.contains(id) ? .on : .off)
            let shortcuts: [ModuleID: String] = [.nachoPet: "⌥⌘N", .systemMonitor: "⌥⌘M", .clipboard: "⇧⌘V"]
            let body: BentoBody
            switch id {
            case .nachoPet: body = BentoBuilder.pet(auth: .signedOut, running: true)
            case .systemMonitor: body = BentoBuilder.monitor(running: true, cpuPercent: 2, memoryPercent: 37, diskFraction: 0.61,
                                                             down: 1_200_000, up: 84_000)
            case .computerUse: body = BentoBuilder.computerUse(accessibility: true, screenRecording: false)
            case .windowSnap: body = BentoBuilder.windowSnap(running: true, leftLabel: "⌃⌥←", otherShortcuts: 21)
            case .keepAwake: body = BentoBuilder.keepAwake(running: true, holds: true, manual: true, until: now.addingTimeInterval(74 * 60),
                                                           heldSince: now.addingTimeInterval(-46 * 60), reason: nil, presetMinutes: 120, now: now)
            case .clipboard: body = BentoBuilder.clipboard(running: true, items: [
                (.text, "회의는 금요일 오후 3시로 옮겼습니다", now.addingTimeInterval(-5)),
                (.link, "github.com/mafianacho/nachocombo", now.addingTimeInterval(-180)),
                (.image, "Image", now.addingTimeInterval(-720))], now: now)
            case .captureFloat: body = BentoBuilder.capture(running: true, floats: 2, shortcut: "⇧⌘2")
            case .focusDim: body = BentoBuilder.focusDim(running: false, intensity: 0.42, paused: false)
            case .deviceControl: body = BentoBuilder.devices(running: true, volume: 0.64, brightness: 80, output: "AirPods Pro")
            case .calendarClock:
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
                let day = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 9))!
                body = BentoBuilder.calendar(now: day, calendar: cal, running: true, access: true, showNext: true,
                                             next: (cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10))!, "주간 회의"))
            case .diskMap: body = BentoBuilder.disk(used: 612_000_000_000, total: 1_000_000_000_000,
                                                     folders: [("Users", 320_000_000_000), ("Applications", 180_000_000_000), ("Library", 110_000_000_000)])
            case .fileShelf: body = BentoBuilder.shelf(running: true, items: [(.file, "견적서.pdf"), (.image, "로고.png"), (.file, "자료.zip")])
            case .menuBar: body = BentoBuilder.menuBar(running: false, collapsed: true, failed: false)
            case .appSwitch: body = BentoBuilder.appSwitch(running: false, switcher: "⌥⇥", appShortcuts: 0)
            case .mouseTune: body = BentoBuilder.mouse(speed: 1.5, reverse: false)
            }
            return BentoWidget(id: id, status: status(dot), enabled: on.contains(id), pinned: pinned.contains(id),
                               shortcut: shortcuts[id], body: body)
        }
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func render(_ view: NSView, size: NSSize, appearance: NSAppearance.Name, name: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
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
        XCTAssertGreaterThan(png.count, 10_000, "\(name) is not empty")
    }

    private func board(host: FixtureHost, editing: Bool, select: ModuleID? = nil) -> (BentoWindowController, NSView) {
        let controller = BentoWindowController(host: host)
        controller.reload()
        if editing {
            controller.beginEditing()
            if let id = select { controller.board.select(id) }
        }
        return (controller, controller.window.contentView!)
    }

    func testMainBoardLightAndDark() throws {
        for (appearance, name) in [(NSAppearance.Name.aqua, "b1-impl-light"), (.darkAqua, "b2-impl-dark")] {
            let host = FixtureHost()
            let (controller, view) = board(host: host, editing: false)
            controller.window.appearance = NSAppearance(named: appearance)
            controller.window.setContentSize(BentoWindowController.defaultSize)
            controller.window.contentView?.layoutSubtreeIfNeeded()
            controller.reload()
            XCTAssertEqual(controller.board.columns, 6)
            XCTAssertEqual(controller.board.cardViews.count, BentoLayout.designOrder.count)
            controller.window.contentView = nil
            try render(view, size: BentoWindowController.defaultSize, appearance: appearance, name: name)
        }
    }

    func testEditModeWithSizePanel() throws {
        let host = FixtureHost()
        let (controller, view) = board(host: host, editing: true, select: .clipboard)
        controller.window.setContentSize(BentoWindowController.defaultSize)
        controller.reload()
        controller.board.select(.clipboard)
        XCTAssertTrue(controller.board.editing)
        XCTAssertEqual(controller.board.selectedID, .clipboard)
        controller.window.contentView = nil
        try render(view, size: BentoWindowController.defaultSize, appearance: .aqua, name: "b3-impl-edit")
        // Size changes from the panel land in the layout; hiding takes the widget off the board.
        controller.board.setSize(.clipboard, .large)
        XCTAssertEqual(host.layout.item(.clipboard)?.size, .large)
        controller.board.hide(.diskMap)
        XCTAssertEqual(host.layout.hiddenModules, [.diskMap])
        XCTAssertFalse(controller.board.cardViews.contains { $0.module == .diskMap })
    }

    func testMenuBarMiniBoard() throws {
        let host = FixtureHost()
        let mini = BentoMiniView()
        mini.host = host
        mini.update()
        let size = mini.frame.size
        XCTAssertEqual(size.width, Brand.Bento.miniWidth)
        // The design's desk: a wallpaper and the popover's light glass, then the mini board on it.
        let desk = MiniDesk(frame: NSRect(x: 0, y: 0, width: size.width + 60, height: size.height + 60))
        desk.addSubview(mini)
        mini.translatesAutoresizingMaskIntoConstraints = true
        mini.frame = NSRect(x: 30, y: 30, width: size.width, height: size.height)
        try render(desk, size: desk.frame.size, appearance: .aqua, name: "b4-impl-mini")
        // Order follows the board; the pinned set only.
        XCTAssertEqual(host.layout.items.filter { host.pinned.contains($0.module!) }.map { $0.id },
                       ["nachoPet", "systemMonitor", "keepAwake", "clipboard"])
    }

    func testOffWidgetsFadeOnlyTheirBody() {
        let card = BentoCardView(module: .focusDim)
        let host = FixtureHost()
        card.apply(host.bentoWidget(.focusDim), petImage: nil)
        XCTAssertEqual(card.bodyView.alphaValue, Brand.Bento.offAlpha, accuracy: 0.001)
        XCTAssertEqual(card.alphaValue, 1)
        let on = BentoCardView(module: .systemMonitor)
        on.apply(host.bentoWidget(.systemMonitor), petImage: nil)
        XCTAssertEqual(on.bodyView.alphaValue, 1)
        XCTAssertTrue(on.accessibilityLabel()?.contains("켜짐") ?? false)
    }
}

/// The b4 desk behind the mini board: a wallpaper gradient and the popover's glass.
final class MiniDesk: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [NSColor(srgbRed: 0x5B / 255.0, green: 0x6F / 255.0, blue: 0xD6 / 255.0, alpha: 1),
                            NSColor(srgbRed: 0x9B / 255.0, green: 0x6B / 255.0, blue: 0xD6 / 255.0, alpha: 1),
                            NSColor(srgbRed: 0xF0 / 255.0, green: 0x9A / 255.0, blue: 0x7A / 255.0, alpha: 1)])?.draw(in: bounds, angle: -70)
        let pop = bounds.insetBy(dx: 18, dy: 18)
        NSColor(srgbRed: 250 / 255.0, green: 248 / 255.0, blue: 252 / 255.0, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: pop, xRadius: 20, yRadius: 20).fill()
    }
}
