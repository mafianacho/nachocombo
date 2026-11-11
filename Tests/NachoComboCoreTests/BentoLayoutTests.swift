import Foundation
import XCTest
@testable import NachoComboCore

/// The widget board: default order and sizes, packing (the design's 6 × 4 board), saving and restoring, the update
/// from 0.6 (no board in the file), and that moving, resizing, hiding and pinning never switch anything.
final class BentoLayoutTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bento-\(UUID().uuidString)").appendingPathComponent("settings.json")
    }

    func testDefaultBoardPutsNachoPetThenToolsThatAreOn() {
        var s = AppSettings.defaults
        s.setEnabled(.clipboard, true)
        s.setEnabled(.keepAwake, true)
        let ids = BentoLayout.defaults(for: s).items.map { $0.id }
        XCTAssertEqual(Array(ids.prefix(3)), ["nachoPet", "keepAwake", "clipboard"], "on tools in design order after the pet")
        XCTAssertEqual(Set(ids).count, ModuleID.allCases.count)
        XCTAssertEqual(ids.count, ModuleID.allCases.count)
        XCTAssertEqual(BentoLayout.defaults(for: s).item(.nachoPet)?.size, .large)
        XCTAssertEqual(BentoLayout.defaults(for: s).item(.clipboard)?.size, .wide)
        XCTAssertFalse(BentoLayout.defaults(for: s).items.contains { $0.hidden })
    }

    func testPackingInTheDesignOrderGivesTheDesignBoard() {
        // Everything in the design's order (b1): 6 columns, 4 rows, the last cell left for "+ 위젯 추가".
        let items = BentoLayout.designOrder.map { BentoItem(id: $0.rawValue, size: BentoLayout.defaultSize($0)) }
        let (placements, rows) = BentoPacker.pack(items, columns: 6, extra: ["add"])
        XCTAssertEqual(rows, 4)
        func at(_ id: String) -> [Int] {
            let p = placements.first { $0.id == id }!
            return [p.column, p.row, p.columns, p.rows]
        }
        XCTAssertEqual(at("nachoPet"), [0, 0, 2, 2])
        XCTAssertEqual(at("systemMonitor"), [2, 0, 2, 1])
        XCTAssertEqual(at("computerUse"), [4, 0, 2, 1])
        XCTAssertEqual(at("windowSnap"), [2, 1, 1, 1])
        XCTAssertEqual(at("keepAwake"), [3, 1, 1, 1])
        XCTAssertEqual(at("clipboard"), [4, 1, 2, 1])
        XCTAssertEqual(at("captureFloat"), [0, 2, 1, 1])
        XCTAssertEqual(at("deviceControl"), [2, 2, 2, 1])
        XCTAssertEqual(at("diskMap"), [5, 2, 1, 1])
        XCTAssertEqual(at("fileShelf"), [0, 3, 2, 1])
        XCTAssertEqual(at("mouseTune"), [4, 3, 1, 1])
        XCTAssertEqual(at("add"), [5, 3, 1, 1])
        // Never two widgets on one cell.
        var cells = Set<[Int]>()
        for p in placements { for x in p.column..<(p.column + p.columns) { for y in p.row..<(p.row + p.rows) { XCTAssertTrue(cells.insert([x, y]).inserted) } } }
    }

    func testNarrowBoardsReflowAndNarrowWideWidgets() {
        let items = BentoLayout.designOrder.map { BentoItem(id: $0.rawValue, size: BentoLayout.defaultSize($0)) }
        let (two, _) = BentoPacker.pack(items, columns: 2)
        XCTAssertTrue(two.allSatisfy { $0.column + $0.columns <= 2 })
        let (one, rows) = BentoPacker.pack(items, columns: 1)
        XCTAssertTrue(one.allSatisfy { $0.columns == 1 })
        XCTAssertGreaterThanOrEqual(rows, items.count)
        XCTAssertEqual(BentoPacker.columns(forWidth: 1138, minCell: 150, gap: 12), 6)
        XCTAssertEqual(BentoPacker.columns(forWidth: 700, minCell: 150, gap: 12), 4)
        XCTAssertEqual(BentoPacker.columns(forWidth: 400, minCell: 150, gap: 12), 2)
    }

    func testEditsAreSavedAndComeBackAfterARestart() throws {
        let store = SettingsStore(url: tempURL())
        let manager = ModuleManager(store: store, modules: [])
        manager.bootstrap()
        manager.updateBento { b in
            b.move(.clipboard, before: .nachoPet)
            b.setSize(.clipboard, .large)
            b.setHidden(.diskMap, true)
        }
        let again = ModuleManager(store: SettingsStore(url: store.url), modules: [])
        let board = again.settings.bentoLayout
        XCTAssertEqual(board.items.first?.id, "clipboard")
        XCTAssertEqual(board.item(.clipboard)?.size, .large)
        XCTAssertEqual(board.item(.diskMap)?.hidden, true)
        XCTAssertEqual(board.hiddenModules, [.diskMap])
        XCTAssertFalse(board.visible.contains { $0.id == "diskMap" })
        var b = board
        b.setHidden(.diskMap, false)
        XCTAssertEqual(b.items.last?.id, "diskMap", "a widget that comes back goes to the end")
        b.step(.clipboard, by: 1)
        XCTAssertEqual(b.visible.map { $0.id }.prefix(2), ["nachoPet", "clipboard"])
        b.step(.clipboard, by: -1)
        XCTAssertEqual(b.visible.first?.id, "clipboard")
        b.step(.clipboard, by: -1)
        XCTAssertEqual(b.visible.first?.id, "clipboard", "nothing before the first")
    }

    func testDropTakesTheTargetsPlace() {
        var b = BentoLayout(items: ["nachoPet", "systemMonitor", "computerUse", "windowSnap"].map { BentoItem(id: $0, size: .small) })
        b.drop(.nachoPet, onto: .computerUse)
        XCTAssertEqual(b.items.map { $0.id }, ["systemMonitor", "computerUse", "nachoPet", "windowSnap"])
        b.drop(.windowSnap, onto: .systemMonitor)
        XCTAssertEqual(b.items.map { $0.id }, ["windowSnap", "systemMonitor", "computerUse", "nachoPet"])
        b.drop(.windowSnap, onto: .windowSnap)
        XCTAssertEqual(b.items.first?.id, "windowSnap")
        for id in ModuleID.allCases { for size in BentoSize.allCases { XCTAssertFalse(BentoSizeText.describe(id, size).isEmpty) } }
    }

    func testUpdateFromA06FileKeepsEverySettingAndAddsTheBoardOnce() throws {
        // A settings file as 0.6.0 wrote it: tools on, pins, a shortcut, monitor and Computer Use choices, no "bento".
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var old = AppSettings.defaults
        old.setEnabled(.keepAwake, true)
        old.setEnabled(.nachoPet, false)
        old.pinnedTools = ["clipboard": true, "systemMonitor": true]
        old.toolShortcuts = ["clipboard": ToolShortcut(keyCode: 9, modifiers: 0x300)]
        old.dimIntensity = 0.42
        let encoder = JSONEncoder()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(old)) as? [String: Any])
        json.removeValue(forKey: "bento")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let manager = ModuleManager(store: SettingsStore(url: url), modules: [])
        XCTAssertNil(manager.settings.bento)
        manager.bootstrap()
        let s = SettingsStore(url: url).load()
        XCTAssertEqual(s.enabledModules, old.enabledModules)
        XCTAssertEqual(s.pinnedTools, old.pinnedTools)
        XCTAssertEqual(s.toolShortcuts, old.toolShortcuts)
        XCTAssertEqual(s.dimIntensity, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.options, old.options)
        XCTAssertEqual(s.computerUse, old.computerUse)
        XCTAssertEqual(s.bento?.items.prefix(2).map { $0.id }, ["nachoPet", "keepAwake"])
        // The board is stored once: switching tools later does not reorder it.
        manager.setEnabled(.diskMap, true)
        XCTAssertEqual(manager.settings.bentoLayout.items.map { $0.id }, s.bento?.items.map { $0.id })
    }

    func testBoardsFromOtherVersionsDecodeSafely() throws {
        let text = """
        {"version": 3, "items": [{"id": "futureTool", "size": "huge"}, {"id": "clipboard", "size": "giant", "hidden": true},
         {"id": "clipboard", "size": "wide"}, {"id": "nachoPet"}]}
        """
        let board = try JSONDecoder().decode(BentoLayout.self, from: Data(text.utf8)).normalized()
        XCTAssertEqual(board.items.count, ModuleID.allCases.count)
        XCTAssertEqual(board.items.first?.id, "clipboard")
        XCTAssertEqual(board.item(.clipboard)?.size, .small, "unknown size → one cell")
        XCTAssertEqual(board.item(.clipboard)?.hidden, true, "first entry wins")
        XCTAssertEqual(board.item(.nachoPet)?.size, .small)
        XCTAssertNil(board.items.first { $0.id == "futureTool" })
        // A broken board in an otherwise good file: the board falls back, the rest stays.
        var s = AppSettings.defaults
        s.setEnabled(.keepAwake, true)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        json["bento"] = ["items": 7]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.bento)
        XCTAssertTrue(decoded.isEnabled(.keepAwake))
    }

    func testBoardEditsAndPinsNeverSwitchToolsOrAskForPermissions() {
        let store = SettingsStore(url: tempURL())
        let snap = FakeModule(.windowSnap)
        let manager = ModuleManager(store: store, modules: [snap])
        manager.bootstrap()
        let enabled = manager.settings.enabledModules
        manager.updateBento { $0.setHidden(.windowSnap, true); $0.setSize(.windowSnap, .wide) }
        manager.setPinned(.windowSnap, true)
        XCTAssertEqual(snap.startCount, 0, "pinning or editing the board does not start the tool")
        XCTAssertEqual(manager.settings.enabledModules, enabled)
        XCTAssertEqual(manager.status(of: .windowSnap).dot, .off)
        XCTAssertTrue(manager.settings.isPinned(.windowSnap))
        // Switching it on and off leaves pin and board alone.
        manager.setEnabled(.windowSnap, true)
        manager.setEnabled(.windowSnap, false)
        XCTAssertTrue(manager.settings.isPinned(.windowSnap))
        XCTAssertEqual(manager.settings.bentoLayout.item(.windowSnap), BentoItem(id: "windowSnap", size: .wide, hidden: true))
    }
}
