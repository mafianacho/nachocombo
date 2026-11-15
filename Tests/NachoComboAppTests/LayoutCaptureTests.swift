import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-203 (NACHO-144 수용 항목): 창 배치 전후와 메뉴 막대 정리 전후 그림.
///
/// 이 그림은 계산 결과를 도식으로 보여 주는 것이다. 실제 macOS 창이나 메뉴 막대를 찍은 화면이 아니다.
/// - 창 배치: 실제 계산 코드 `WindowTiling`(grid·split)이 낸 프레임을 가짜 화면(1512×945) 위에 그린다. 앱 이름은 고정값이다.
/// - 메뉴 막대: 실제 모델 `MenuBarState`/`MenuBarItem`/`MenuBarDividers`로 고정 항목 9개를 만들고, "정리 후" 상태는
///   `MenuBarToolRunner`의 `tidy` 도구를 시험 대역(MenuBarToolsTests와 같은 방식)에 돌려 얻은 상태와 구분선 규칙으로 정한다.
/// AppKit 화면 밖 렌더, macOS CI 전용이며 실물 맥 검증이 아니다. 라이트 모드만 그린다.
/// 그림은 .build/bento-captures 와 테스트 로그(BENTO-CAPTURE 줄, base64 조각)로 나간다.
final class LayoutCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    // MARK: output

    private func emit(_ label: String, _ view: NSView) throws {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(label).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(label) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 2_000, "\(label) is not empty")
    }

    // MARK: window scenes

    private static let screen = CGRect(x: 0, y: 0, width: 1512, height: 945)
    private static let menuBarHeight: CGFloat = 33
    /// Visible frame: the screen below the menu bar (Cocoa, origin bottom-left).
    private static let visible = CGRect(x: 0, y: 0, width: 1512, height: 945 - 33)
    private static let apps = ["Safari", "Notes", "Terminal", "Mail", "Finder", "Calendar"]
    private static let colors: [NSColor] = [
        NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 1), NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.45, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.70, blue: 0.74, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.85, blue: 0.68, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.70, blue: 0.92, alpha: 1), NSColor(calibratedRed: 0.97, green: 0.68, blue: 0.62, alpha: 1),
    ]

    private final class ScreenView: NSView {
        let caption: String
        let frames: [CGRect]
        init(caption: String, frames: [CGRect]) {
            self.caption = caption
            self.frames = frames
            super.init(frame: CGRect(x: 0, y: 0, width: LayoutCaptureTests.screen.width / 2, height: LayoutCaptureTests.screen.height / 2 + 28))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            let scale: CGFloat = 0.5
            NSColor.white.setFill()
            bounds.fill()
            let top = bounds.height - 28
            NSString(string: caption).draw(at: CGPoint(x: 10, y: top + 6), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.saveGState()
            ctx?.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: top))
            NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: bounds.width, height: top).fill()
            // menu bar strip (diagram, not the real one)
            NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
            CGRect(x: 0, y: top - LayoutCaptureTests.menuBarHeight * scale, width: bounds.width,
                   height: LayoutCaptureTests.menuBarHeight * scale).fill()
            for (i, f) in frames.enumerated() {
                let r = CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale)
                LayoutCaptureTests.colors[i % LayoutCaptureTests.colors.count].setFill()
                r.fill()
                NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
                let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1
                path.stroke()
                NSString(string: "\(LayoutCaptureTests.apps[i % LayoutCaptureTests.apps.count]) #\(i + 1)").draw(
                    at: CGPoint(x: r.minX + 8, y: r.maxY - 22),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black])
            }
            ctx?.restoreGState()
        }
    }

    private func assertSound(_ frames: [CGRect], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let area = Self.visible.insetBy(dx: -0.01, dy: -0.01)
        for (i, f) in frames.enumerated() {
            XCTAssertTrue(area.contains(f), "\(name): window \(i + 1) leaves the screen", file: file, line: line)
            XCTAssertGreaterThan(f.width, 0, file: file, line: line)
            XCTAssertGreaterThan(f.height, 0, file: file, line: line)
            for j in (i + 1)..<max(frames.count, i + 1) {
                let o = f.intersection(frames[j])
                XCTAssertTrue(o.isNull || o.width * o.height < 1, "\(name): windows \(i + 1) and \(j + 1) overlap", file: file, line: line)
            }
        }
    }

    func testWindowLayoutScenes() throws {
        // 전: overlapping windows (fixed fixture frames)
        let before: [CGRect] = [
            CGRect(x: 60, y: 300, width: 760, height: 520), CGRect(x: 300, y: 180, width: 700, height: 520),
            CGRect(x: 560, y: 360, width: 640, height: 460), CGRect(x: 180, y: 80, width: 720, height: 440),
            CGRect(x: 760, y: 120, width: 640, height: 500),
        ]
        var overlaps = 0
        for i in before.indices { for j in (i + 1)..<before.count where before[i].intersects(before[j]) { overlaps += 1 } }
        XCTAssertGreaterThanOrEqual(overlaps, 4, "the before scene really overlaps")
        try emit("layout-before", ScreenView(caption: "전: 겹친 창 5개 (도식)", frames: before))

        let gap: CGFloat = 8
        let grid = try WindowTiling.grid(count: 6, in: Self.visible, gap: gap).get()
        XCTAssertEqual(grid.count, 6)
        XCTAssertEqual(WindowTiling.gridRows(6), [3, 3])
        assertSound(grid, "grid")
        try emit("layout-grid", ScreenView(caption: "후: 바둑판 — 창 6개 자동 격자 (WindowTiling.grid, 도식)", frames: grid))

        let thirds = try WindowTiling.split(parts: 3, direction: .horizontal, in: Self.visible, gap: gap).get()
        XCTAssertEqual(thirds.count, 3)
        assertSound(thirds, "thirds")
        XCTAssertEqual(thirds[0].width, thirds[2].width, accuracy: 0.5, "outer thirds are equal (gap trims the edges)")
        try emit("layout-thirds", ScreenView(caption: "후: 가로 3등분 (WindowTiling.split, 도식)", frames: thirds))

        let quarters = try WindowTiling.split(parts: 4, direction: .quadrant, in: Self.visible, gap: gap).get()
        XCTAssertEqual(quarters.count, 4)
        assertSound(quarters, "quarters")
        XCTAssertGreaterThan(quarters[0].minY, quarters[2].minY, "first quadrant is top-left")
        try emit("layout-quarters", ScreenView(caption: "후: 4분면 (WindowTiling.split quadrant, 도식)", frames: quarters))
    }

    // MARK: menu bar scenes

    private final class FakeOrganizer: MenuBarControlling {
        var current: MenuBarState
        init(_ s: MenuBarState) { current = s }
        func state(done: @escaping (MenuBarState) -> Void) { done(current) }
        func setCollapsed(_ collapsed: Bool, done: @escaping (MenuBarState) -> Void) { current.collapsed = collapsed; done(current) }
        func tidy(done: @escaping (MenuBarState) -> Void) { current.collapsed = true; current.showingAlwaysHidden = false; done(current) }
        func showHidden(done: @escaping (MenuBarState) -> Void) { current.collapsed = false; done(current) }
        func readItems(done: @escaping (MenuBarReading) -> Void) { done(.permissionNeeded) }
    }

    private final class BarView: NSView {
        struct Cell { let item: MenuBarItem; let zone: MenuBarZone }
        let caption: String
        let cells: [Cell]
        let hiddenCount: Int
        let showDividers: [Double]
        init(caption: String, cells: [Cell], hiddenCount: Int, dividers: [Double]) {
            self.caption = caption; self.cells = cells; self.hiddenCount = hiddenCount; self.showDividers = dividers
            super.init(frame: CGRect(x: 0, y: 0, width: 756, height: 110))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
            NSString(string: caption).draw(at: CGPoint(x: 10, y: 84), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
            let bar = CGRect(x: 0, y: 24, width: bounds.width, height: 40)
            NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
            bar.fill()
            for c in cells {
                let r = CGRect(x: c.item.x, y: bar.minY + 6, width: c.item.width, height: 28)
                (c.item.own ? NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.45, alpha: 1)
                            : NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 1)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                NSString(string: String(c.item.title.prefix(2))).draw(
                    at: CGPoint(x: r.minX + 6, y: r.minY + 6),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black])
                NSString(string: c.item.app).draw(at: CGPoint(x: r.minX, y: 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.darkGray])
            }
            for x in showDividers {
                NSColor.systemRed.setStroke()
                let p = NSBezierPath()
                p.move(to: CGPoint(x: x, y: bar.minY + 2)); p.line(to: CGPoint(x: x, y: bar.maxY - 2))
                p.lineWidth = 2
                p.stroke()
            }
            if hiddenCount > 0 {
                NSString(string: "숨긴 항목 \(hiddenCount)개").draw(
                    at: CGPoint(x: 10, y: bar.minY + 12),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.black])
            }
        }
    }

    private func fixtureItems() -> [MenuBarItem] {
        let names = [("Dropbox", "DB"), ("Slack", "SL"), ("1Password", "1P"), ("Zoom", "ZM"), ("Notion", "NO"),
                     ("Nacho Combo", "NC"), ("Wi-Fi", "WF"), ("Battery", "BT"), ("Clock", "CK")]
        // items sit at fixed x positions on a 756 pt wide diagram bar
        return names.enumerated().map { i, n in
            MenuBarItem(app: n.0, title: n.1, x: Double(280 + i * 52), y: 0, width: 40, height: 28, own: n.0 == "Nacho Combo")
        }
    }

    func testMenuBarScenes() throws {
        let items = fixtureItems()
        XCTAssertEqual(items.count, 9)
        // Dividers: first two items always hidden, next two hidden, rest visible.
        let dividers = MenuBarDividers(divider: items[4].x - 6, alwaysDivider: items[2].x - 6)
        let cellsAll = items.map { BarView.Cell(item: $0, zone: .visible) }
        try emit("menubar-before", BarView(caption: "전: 정리 전 — 항목 9개 모두 보임 (MenuBarItem, 도식)", cells: cellsAll, hiddenCount: 0, dividers: []))

        // 정리 후: the real tidy tool on the test double gives the state; the divider rules (MenuBarDividers) decide each item's zone.
        let fake = FakeOrganizer(MenuBarState(running: true, collapsed: false, hasAlwaysHiddenSection: true))
        var outcome: PetCommandOutcome?
        let tidyTool = try XCTUnwrap(MenuBarTools.tools.first { $0.action == "tidy" })
        MenuBarToolRunner(controller: fake).run(tidyTool, arguments: [:]) { outcome = $0 }
        let result = try XCTUnwrap(outcome)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.details?["collapsed"] as? Bool, true)
        XCTAssertTrue(fake.current.collapsed)

        let counts = MenuBarSerializer.counts(items, dividers: dividers)
        XCTAssertEqual(counts["always_hidden"], 2)
        XCTAssertEqual(counts["hidden"], 2)
        XCTAssertEqual(counts["visible"], 5)
        let hiddenTotal = (counts["hidden"] ?? 0) + (counts["always_hidden"] ?? 0)
        let shown = items.filter { dividers.zone(centerX: $0.centerX) == .visible }
        XCTAssertEqual(shown.count, items.count - hiddenTotal)
        // collapsed: hidden items fold away, visible ones slide right (pack against the right edge, 4 pt after each)
        var x = 756.0 - 12
        var packed: [BarView.Cell] = []
        for item in shown.reversed() {
            x -= item.width
            var moved = item
            moved.x = x
            packed.insert(BarView.Cell(item: moved, zone: .visible), at: 0)
            x -= 12
        }
        XCTAssertGreaterThanOrEqual(packed.first?.item.x ?? -1, 0, "folded bar stays on the diagram")
        try emit("menubar-after", BarView(caption: "후: 정리 후 — 숨김 규칙 적용 (MenuBarState.collapsed, 도식)", cells: packed, hiddenCount: hiddenTotal, dividers: []))
    }
}
