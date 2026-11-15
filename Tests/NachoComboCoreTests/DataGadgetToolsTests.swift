import Foundation
import XCTest
@testable import NachoComboCore

// NACHO-149: the data gadget tools (System Monitor, Disk Map, Clipboard History, File Shelf, Capture Float) on the
// NachoCombo MCP registry: serialization without content, argument checks, risk → approval, gadget_off /
// permission_needed, disk limits, and the MCP / connector round trips. A fake host stands in for the Mac.

/// Content values that must never show up in a list result or a log.
private let secretClip = "SECRET-CLIP-4f1e: the user's copied text"
private let secretSnippet = "SECRET-SNIPPET-77: a note on the shelf"

final class FakeDataHost: DataGadgetHost {
    var stats: MonitorStats? = MonitorStats(cpuPercent: 42.345, memoryPercent: 71.26, memoryUsedBytes: 12, memoryTotalBytes: 16,
                                            memoryPressurePercent: 30, swapUsedBytes: 0, networkDownBytesPerSecond: 1234.56,
                                            networkUpBytesPerSecond: 10, diskUsedPercent: 88.04, batteryPercent: 64, batteryCharging: true,
                                            onPowerAdapter: true, cpuTemperatureCelsius: 55.55, gpuTemperatureCelsius: nil, loadAverage: [2.345, 1.5, 1])
    var disk: DiskMapState = .empty
    var homeDirectory = "/Users/sam"
    var folders: Set<String> = ["/Users/sam", "/Users/sam/Downloads"]
    var scans: [String] = []
    var clips: [ClipboardItem] = []
    var copied: [UUID] = []
    var clearedClipboard = 0
    var shelf: [ShelfRow] = []
    var handed: [UUID] = []
    var handRefusal: String?
    var forgotten: [UUID] = []
    var shelfCleared = 0
    var captureModes: [CaptureAskMode] = []
    var captureDone: ((CaptureAskResult) -> Void)?
    var answerCaptureAtOnce: CaptureAskResult? = .attached
    var pinned: [(width: Int, height: Int)] = [(800, 600)]
    var closed = 0

    func monitorStats() -> MonitorStats? { stats }
    func diskState() -> DiskMapState { disk }
    func isDirectory(_ path: String) -> Bool { folders.contains(path) }
    func diskStartScan(path: String) -> Bool { scans.append(path); return true }
    func clipboardItems() -> [ClipboardItem] { clips }
    func clipboardCopyAgain(id: UUID) -> Bool { copied.append(id); return clips.contains { $0.id == id } }
    func clipboardClearUnpinned() -> Int {
        let n = clips.filter { !$0.pinned }.count
        clips.removeAll { !$0.pinned }
        clearedClipboard += 1
        return n
    }
    func shelfRows() -> [ShelfRow] { shelf }
    func shelfHandToNacho(id: UUID) -> String? { handed.append(id); return handRefusal }
    func shelfForget(id: UUID) -> Bool { forgotten.append(id); return true }
    func shelfClear() -> Int { shelfCleared += 1; let n = shelf.count; shelf = []; return n }
    func captureAsk(_ mode: CaptureAskMode, done: @escaping (CaptureAskResult) -> Void) {
        captureModes.append(mode)
        if let r = answerCaptureAtOnce { done(r) } else { captureDone = done }
    }
    func pinnedCaptures() -> [(width: Int, height: Int)] { pinned }
    func captureCloseAll() -> Int { closed += 1; let n = pinned.count; pinned = []; return n }
}

private func json(_ o: PetCommandOutcome) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: o.resultJSON, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

private func tool(_ mcpName: String) -> GadgetTool {
    guard let t = GadgetToolRegistry.mcpTool(named: mcpName) ?? GadgetToolRegistry.all.first(where: { $0.mcpName == mcpName }) else {
        XCTFail("no tool \(mcpName)")
        return GadgetToolRegistry.all[0]
    }
    return t
}

final class DataGadgetToolsTests: XCTestCase {
    private var host = FakeDataHost()
    private var later: [(TimeInterval, () -> Void)] = []
    private var runner: DataGadgetRunner!
    private var fallback = RecordingGadgetRunner()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        host = FakeDataHost(); later = []; fallback = RecordingGadgetRunner()
        runner = DataGadgetRunner(host: host, fallback: fallback, onMain: { $0() }, after: { [unowned self] d, w in self.later.append((d, w)) },
                                  now: { [unowned self] in self.now })
    }

    /// Runs one tool and returns its outcome (the fake host answers at once).
    private func call(_ name: String, _ args: [String: JSONValue] = [:]) -> PetCommandOutcome {
        var out: PetCommandOutcome?
        var calls = 0
        runner.run(tool(name), arguments: args) { out = $0; calls += 1 }
        XCTAssertEqual(calls, 1, "\(name): done exactly once")
        return out ?? PetCommandOutcome(ok: false, message: "no answer")
    }

    private func reason(_ o: PetCommandOutcome) -> String? { o.details?["reason"] as? String }
    private func items(_ o: PetCommandOutcome) -> [[String: Any]] { o.details?["items"] as? [[String: Any]] ?? [] }

    // MARK: registry

    func testDataGadgetToolsAreRegisteredWithTheirRiskAndExits() {
        let expected: [(String, GadgetToolRisk, Set<GadgetToolExit>)] = [
            ("monitor_stats", .read, [.mcp, .connector]),
            ("disk_top_items", .read, [.mcp, .connector]), ("disk_scan", .change, [.mcp, .connector]),
            ("clipboard_list", .read, [.mcp, .connector]), ("clipboard_get_item", .contentOut, [.mcp, .connector]),
            ("clipboard_copy_again", .change, [.mcp, .connector]), ("clipboard_clear", .destructive, [.mcp, .connector]),
            ("shelf_list", .read, [.mcp, .connector]), ("shelf_give", .contentOut, [.connector]),
            ("shelf_forget", .change, [.mcp, .connector]), ("shelf_clear", .destructive, [.mcp, .connector]),
            ("capture_ask", .contentOut, [.connector]), ("capture_list_pinned", .read, [.mcp, .connector]),
            ("capture_close_all", .change, [.mcp, .connector]),
        ]
        for (name, risk, exits) in expected {
            let t = tool(name)
            XCTAssertEqual(t.risk, risk, name)
            XCTAssertEqual(t.exits, exits, name)
            XCTAssertTrue(t.requiresGadgetOn || name == "shelf_clear", "\(name): new tools answer gadget_off")
        }
        let ours = GadgetToolRegistry.all.filter { DataGadgetRunner.gadgets.contains($0.gadget) }.map { $0.mcpName }
        XCTAssertEqual(Set(ours), Set(expected.map { $0.0 }), "nothing else on these gadgets")
        XCTAssertEqual(tool("capture_ask").permissions, [.screenRecording])
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
        for g in DataGadgetRunner.gadgets {
            XCTAssertNotNil(GadgetToolRegistry.guide(for: g), "\(g.rawValue) has a guide")
        }
        XCTAssertTrue(GadgetToolRegistry.prompts.contains { $0.name == "monitor_why_slow" })
    }

    func testDiskMapHasNoToolThatDeletesOrMoves() {
        for t in GadgetToolRegistry.all where t.gadget == .disk {
            XCTAssertTrue([.read, .change].contains(t.risk), t.mcpName)
            for word in ["delete", "remove", "trash", "move", "erase", "clean"] { XCTAssertFalse(t.action.contains(word), t.mcpName) }
        }
    }

    func testClearShelfIsNowDestructiveUnderBothNames() {
        let old = GadgetToolRegistry.connectorTool(named: "combo_clear_shelf")
        XCTAssertEqual(old?.risk, .destructive)
        XCTAssertEqual(old?.mcpName, "shelf_clear")
        XCTAssertEqual(GadgetToolRegistry.connectorTool(named: "combo_shelf_clear")?.legacyConnectorName, "combo_clear_shelf")
        XCTAssertEqual(old?.connectorApproval(alwaysAllowed: true), true, "approval every time, always allow or not")
    }

    func testRiskToApprovalOnTheConnectorPath() {
        func approval(_ caps: [[String: Any]], _ name: String) -> String?? {
            guard let c = caps.first(where: { $0["name"] as? String == name }) else { return .none }
            return .some(c["approval"] as? String)
        }
        let off = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: [])
        for name in ["combo_monitor_stats", "combo_disk_top_items", "combo_disk_scan", "combo_clipboard_list", "combo_clipboard_copy_again",
                     "combo_shelf_list", "combo_shelf_forget", "combo_capture_list_pinned", "combo_capture_close_all"] {
            XCTAssertEqual(approval(off, name), .some(nil), "\(name): read/change run at once")
        }
        for name in ["combo_clipboard_get_item", "combo_shelf_give", "combo_capture_ask", "combo_clipboard_clear", "combo_clear_shelf"] {
            XCTAssertEqual(approval(off, name), .some("required"), "\(name): approval by default")
        }
        let on = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [.clipboard, .shelf, .capture], disabled: [])
        for name in ["combo_clipboard_get_item", "combo_shelf_give", "combo_capture_ask"] {
            XCTAssertEqual(approval(on, name), .some(nil), "\(name): always allowed lifts the card")
        }
        XCTAssertEqual(approval(on, "combo_clipboard_clear"), .some("required"), "destructive ignores always allow")
        XCTAssertEqual(approval(on, "combo_clear_shelf"), .some("required"), "destructive ignores always allow")
        XCTAssertTrue(GadgetToolRegistry.trustableGadgets().isSuperset(of: [.clipboard, .shelf, .capture]))
        XCTAssertFalse(GadgetToolRegistry.trustableGadgets().contains(.monitor), "no content tool, no always allow")
        XCTAssertFalse(GadgetToolRegistry.trustableGadgets().contains(.disk))
    }

    // MARK: monitor

    func testMonitorStatsAreRoundedAndMissingValuesAreNull() {
        host.stats?.topProcesses = (1...7).map {
            ProcessGroupUsage(key: "k\($0)", name: "App \($0)", bundlePath: nil, path: "/x", processCount: 1, cpuPercent: Double($0), memory: 100)
        }
        let o = call("monitor_stats")
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.details?["cpu_percent"] as? Double, 42.3)
        XCTAssertEqual(o.details?["memory_percent"] as? Double, 71.3)
        XCTAssertEqual(o.details?["cpu_temperature_celsius"] as? Double, 55.6)
        XCTAssertTrue(o.details?["gpu_temperature_celsius"] is NSNull, "no GPU temperature: null")
        XCTAssertEqual(o.details?["battery_charging"] as? Bool, true)
        XCTAssertEqual(o.details?["load_average"] as? [Double], [2.35, 1.5, 1])
        let top = o.details?["top_apps"] as? [[String: Any]] ?? []
        XCTAssertEqual(top.count, 5, "busiest five only")
        XCTAssertEqual(top.first?["name"] as? String, "App 7")
        XCTAssertTrue(o.message.contains("CPU 42%"))
        host.stats = nil
        XCTAssertEqual(reason(call("monitor_stats")), "no_reading")
        XCTAssertEqual(reason(call("monitor_stats", ["x": .int(1)])), "bad_parameters", "closed parameter list")
    }

    // MARK: disk

    private func diskTree() -> DiskNode {
        let root = DiskNode(name: "sam", kind: .folder, size: 1000, fileCount: 6, basePath: "/Users/sam")
        let a = DiskNode(name: "Movies", kind: .folder, size: 600, fileCount: 2, modified: 1_799_000_000)
        let b = DiskNode(name: "Downloads", kind: .folder, size: 300, fileCount: 3)
        let c = DiskNode(name: "deep", kind: .folder, size: 250, fileCount: 1)
        let d = DiskNode(name: "deeper", kind: .folder, size: 240, fileCount: 1)
        let big = DiskNode(name: "film.mov", kind: .file, size: 500, fileCount: 1)
        let small = DiskNode(name: "a.zip", kind: .file, size: 50, fileCount: 1)
        let tiny = DiskNode(name: "x.txt", kind: .file, size: 5, fileCount: 1)
        root.add(a); root.add(b); a.add(big); b.add(c); c.add(d); d.add(small); root.add(tiny)
        return root
    }

    func testDiskTopListsLargestFoldersAndFilesOfTheLastScan() {
        host.disk = .ready(root: diskTree(), scannedAt: now.addingTimeInterval(-600))
        let o = call("disk_top_items", ["count": .int(3)])
        XCTAssertTrue(o.ok)
        XCTAssertEqual(items(o).map { $0["name"] as? String }, ["Movies", "film.mov", "Downloads"])
        XCTAssertEqual(items(o).first?["path"] as? String, "/Users/sam/Movies")
        XCTAssertEqual(items(o).first?["kind"] as? String, "folder")
        XCTAssertNotNil(items(o).first?["modified_at"])
        XCTAssertEqual(o.details?["scanned_at"] as? String, "2027-01-15T07:50:00Z")
        XCTAssertTrue(o.message.contains("10 minutes ago"))
        let folders = items(call("disk_top_items", ["kind": .string("folders"), "count": .int(50)])).map { $0["name"] as? String }
        XCTAssertEqual(folders, ["Movies", "Downloads", "deep"], "two levels deep; deeper folders are inside them")
        let files = items(call("disk_top_items", ["kind": .string("files")])).map { $0["name"] as? String }
        XCTAssertEqual(files, ["film.mov", "a.zip", "x.txt"], "files anywhere in the scan")
    }

    func testDiskTopIsCappedAndChecksItsArguments() {
        let root = DiskNode(name: "sam", kind: .folder, basePath: "/Users/sam")
        for i in 0..<80 { root.add(DiskNode(name: "f\(i)", kind: .file, size: Int64(i), fileCount: 1)) }
        host.disk = .ready(root: root, scannedAt: now)
        XCTAssertEqual(items(call("disk_top_items")).count, DataGadgetRunner.defaultDiskItems)
        XCTAssertEqual(items(call("disk_top_items", ["count": .int(50)])).count, 50)
        XCTAssertEqual(reason(call("disk_top_items", ["count": .int(51)])), "bad_parameters", "at most 50")
        XCTAssertEqual(reason(call("disk_top_items", ["count": .int(0)])), "bad_parameters")
        XCTAssertEqual(reason(call("disk_top_items", ["count": .string("ten")])), "bad_parameters")
        XCTAssertEqual(reason(call("disk_top_items", ["kind": .string("apps")])), "bad_parameters")
        XCTAssertEqual(reason(call("disk_top_items", ["depth": .int(9)])), "bad_parameters")
        XCTAssertEqual(DataGadgetRunner.diskTop(root, count: 500, kind: .files).count, DataGadgetRunner.maxDiskItems)
        host.disk = .empty
        XCTAssertEqual(reason(call("disk_top_items")), "no_scan")
        host.disk = .scanning(path: "/Users/sam")
        XCTAssertEqual(reason(call("disk_top_items")), "scanning")
    }

    func testDiskScanStaysInsideTheHomeFolder() {
        XCTAssertTrue(call("disk_scan").ok)
        XCTAssertTrue(call("disk_scan", ["path": .string("~/Downloads")]).ok)
        XCTAssertTrue(call("disk_scan", ["path": .string("/Users/sam/Downloads/")]).ok)
        XCTAssertEqual(host.scans, ["/Users/sam", "/Users/sam/Downloads", "/Users/sam/Downloads"])
        XCTAssertEqual(reason(call("disk_scan", ["path": .string("/")])), "outside_home")
        XCTAssertEqual(reason(call("disk_scan", ["path": .string("/etc")])), "outside_home")
        XCTAssertEqual(reason(call("disk_scan", ["path": .string("~/../other")])), "outside_home", "no way out with ..")
        XCTAssertEqual(reason(call("disk_scan", ["path": .string("/Users/samuel")])), "outside_home", "a prefix is not inside")
        XCTAssertEqual(reason(call("disk_scan", ["path": .string("~/Nope")])), "not_a_folder")
        XCTAssertEqual(reason(call("disk_scan", ["path": .string("Downloads")])), "bad_parameters", "relative paths are refused")
        XCTAssertEqual(reason(call("disk_scan", ["path": .int(1)])), "bad_parameters")
        XCTAssertEqual(host.scans.count, 3, "no refused path was scanned")
    }

    // MARK: clipboard

    private func clips() -> [ClipboardItem] {
        [ClipboardItem(kind: .text, text: secretClip, sourceApp: "Notes", date: now, pinned: true),
         ClipboardItem(kind: .link, text: "https://example.com/private", date: now.addingTimeInterval(-60)),
         ClipboardItem(kind: .image, text: "", imagePNG: Data(repeating: 1, count: 2048), date: now.addingTimeInterval(-120)),
         ClipboardItem(kind: .files, text: "/Users/sam/a.pdf\n/Users/sam/b.pdf", date: now.addingTimeInterval(-180))]
    }

    func testClipboardListHasNoContentOrPreview() {
        host.clips = clips()
        let o = call("clipboard_list")
        let text = json(o)
        XCTAssertFalse(text.contains("SECRET-CLIP"), "no preview of text")
        XCTAssertFalse(text.contains("example.com"), "no preview of links")
        XCTAssertFalse(text.contains("a.pdf"), "no file names")
        XCTAssertFalse(text.contains("Notes"), "no source app")
        let rows = items(o)
        XCTAssertEqual(rows.map { $0["kind"] as? String }, ["text", "link", "image", "files"])
        XCTAssertEqual(rows.map { $0["length"] as? Int }, [secretClip.count, 27, 2048, 2])
        XCTAssertEqual(rows.map { $0["unit"] as? String }, ["characters", "characters", "bytes", "files"])
        XCTAssertEqual(rows.first?["pinned"] as? Bool, true)
        XCTAssertEqual(rows.first?["index"] as? Int, 1)
        XCTAssertEqual((rows.first?["id"] as? String)?.count, 8)
        XCTAssertEqual(Set(rows.first?.keys ?? [:].keys), ["index", "id", "kind", "length", "unit", "copied_at", "pinned"])
        host.clips = []
        XCTAssertTrue(call("clipboard_list").message.contains("empty"))
    }

    func testClipboardGetItemReadsOneItemAndChecksTheNumber() {
        host.clips = clips()
        let o = call("clipboard_get_item", ["index": .int(1)])
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.details?["text"] as? String, secretClip)
        XCTAssertEqual(o.details?["truncated"] as? Bool, false)
        XCTAssertFalse(o.message.contains("SECRET"), "the message line carries no content")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(3)])), "not_text", "a picture is not read as text")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(5)])), "out_of_range")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(0)])), "bad_parameters")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(201)])), "bad_parameters")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .double(1.5)])), "bad_parameters")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .string("1")])), "bad_parameters")
        XCTAssertEqual(reason(call("clipboard_get_item", [:])), "bad_parameters", "index is required")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(1), "preview": .bool(true)])), "bad_parameters")
        let id = DataGadgetRunner.shortID(host.clips[1].id)
        XCTAssertTrue(call("clipboard_get_item", ["index": .int(2), "id": .string(id)]).ok)
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(1), "id": .string(id)])), "list_changed",
                       "the approved number now points at another item")
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(1), "id": .string("zz")])), "bad_parameters")
        host.clips = []
        XCTAssertEqual(reason(call("clipboard_get_item", ["index": .int(1)])), "out_of_range")
    }

    func testClipboardReadIsCutAtTheLimit() {
        host.clips = [ClipboardItem(kind: .text, text: String(repeating: "가", count: DataGadgetRunner.maxReadCharacters + 10))]
        let o = call("clipboard_get_item", ["index": .int(1)])
        XCTAssertEqual((o.details?["text"] as? String)?.count, DataGadgetRunner.maxReadCharacters)
        XCTAssertEqual(o.details?["truncated"] as? Bool, true)
        XCTAssertEqual(o.details?["length"] as? Int, DataGadgetRunner.maxReadCharacters + 10)
    }

    func testClipboardCopyAgainAndClear() {
        host.clips = clips()
        XCTAssertTrue(call("clipboard_copy_again", ["index": .int(2)]).ok)
        XCTAssertEqual(host.copied, [host.clips[1].id])
        XCTAssertEqual(reason(call("clipboard_copy_again", ["index": .int(9)])), "out_of_range")
        let cleared = call("clipboard_clear")
        XCTAssertEqual(cleared.details?["cleared"] as? Int, 3)
        XCTAssertTrue(cleared.message.contains("cannot be undone"))
        XCTAssertEqual(host.clips.count, 1, "the pinned item stays")
    }

    // MARK: shelf

    private func rows() -> [ShelfRow] {
        // The real store: a snippet's shelf title is its first line, a link's is its address.
        let store = ShelfStore(ownedDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString)"))
        let snippet = store.addText(secretSnippet)!
        let link = store.addLink(URL(string: "https://example.com/private-page")!)!
        return [ShelfRow(id: UUID(), name: "report.pdf", kind: .file, size: 2048),
                ShelfRow(snippet, fileSize: { _ in nil }),
                ShelfRow(ShelfItem(kind: .image, fileURL: URL(fileURLWithPath: "/tmp/gone.png"), text: nil, ownsFile: true, title: "Image 1.png"),
                         fileSize: { _ in nil }),
                ShelfRow(link, fileSize: { _ in nil })]
    }

    func testShelfListShowsNamesKindsAndSizesOnly() {
        host.shelf = rows()
        let o = call("shelf_list")
        XCTAssertFalse(json(o).contains("SECRET-SNIPPET"), "a snippet's text (and its first-line title) is content")
        XCTAssertFalse(json(o).contains("example.com"), "a link's address is content")
        let r = items(o)
        XCTAssertEqual(r.map { $0["name"] as? String }, ["report.pdf", "text snippet", "Image 1.png", "web link"])
        XCTAssertEqual(r.map { $0["kind"] as? String }, ["file", "text", "image", "link"])
        XCTAssertEqual(r[0]["bytes"] as? Int64, 2048)
        XCTAssertEqual(r[1]["characters"] as? Int64, Int64(secretSnippet.count))
        XCTAssertTrue(r[2]["bytes"] is NSNull, "a file that is gone has no size")
    }

    func testShelfGiveAttachesToTheNextChatMessage() {
        host.shelf = rows()
        let o = call("shelf_give", ["index": .int(1)])
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.details?["delivery"] as? String, "chat_attachment")
        XCTAssertEqual(o.details?["attached"] as? Bool, true)
        XCTAssertEqual(host.handed, [host.shelf[0].id])
        host.handRefusal = "이 파일 형식은 보낼 수 없어요."
        let refused = call("shelf_give", ["index": .int(2)])
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(reason(refused), "not_attached")
        XCTAssertEqual(refused.details?["guide_ko"] as? String, "이 파일 형식은 보낼 수 없어요.")
        XCTAssertEqual(reason(call("shelf_give", ["index": .int(5)])), "out_of_range")
    }

    func testShelfForgetAndClear() {
        host.shelf = rows()
        let o = call("shelf_forget", ["index": .int(3)])
        XCTAssertTrue(o.ok)
        XCTAssertTrue(o.message.contains("original file is untouched"))
        XCTAssertEqual(host.forgotten, [host.shelf[2].id])
        // shelf_clear keeps its old combo_clear_shelf executor (the fallback) …
        XCTAssertTrue(call("shelf_clear").ok)
        XCTAssertEqual(fallback.calls.map { $0.name }, ["shelf_clear"])
        XCTAssertEqual(host.shelfCleared, 0)
        // … and without one the runner empties the shelf itself.
        let alone = DataGadgetRunner(host: host, onMain: { $0() })
        var out: PetCommandOutcome?
        alone.run(tool("shelf_clear"), arguments: [:]) { out = $0 }
        XCTAssertEqual(out?.details?["cleared"] as? Int, 4)
    }

    // MARK: capture

    func testCaptureScreenAnswersWhenAttached() {
        let o = call("capture_ask", ["mode": .string("screen")])
        XCTAssertTrue(o.ok)
        XCTAssertEqual(o.details?["delivery"] as? String, "chat_attachment")
        XCTAssertEqual(host.captureModes, [.screen])
        XCTAssertTrue(later.isEmpty, "no waiting timer for the whole screen")
        host.answerCaptureAtOnce = .cancelled
        XCTAssertEqual(reason(call("capture_ask", ["mode": .string("area")])), "cancelled")
        host.answerCaptureAtOnce = .failed("캡처한 그림을 만들지 못했어요.")
        XCTAssertEqual(reason(call("capture_ask", ["mode": .string("screen")])), "not_attached")
        XCTAssertEqual(reason(call("capture_ask", ["mode": .string("window")])), "bad_parameters")
        XCTAssertEqual(host.captureModes, [.screen, .area, .screen], "a bad mode never starts a capture")
    }

    func testAreaCaptureAnswersPendingBeforeTheServerGivesUpAndOnlyOnce() {
        host.answerCaptureAtOnce = nil
        var answers: [PetCommandOutcome] = []
        runner.run(tool("capture_ask"), arguments: [:]) { answers.append($0) }
        XCTAssertEqual(host.captureModes, [.area], "area is the default")
        XCTAssertTrue(answers.isEmpty, "waits for the user's drag")
        XCTAssertEqual(later.map { $0.0 }, [DataGadgetRunner.areaAnswerSeconds])
        XCTAssertLessThan(DataGadgetRunner.areaAnswerSeconds, 60, "nacho-server waits 60 s for a connector answer")
        later[0].1()
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.details?["pending"] as? Bool, true)
        host.captureDone?(.attached)
        XCTAssertEqual(answers.count, 1, "done exactly once")
        // A drag that ends first wins; the timer then does nothing.
        answers = []; later = []
        runner.run(tool("capture_ask"), arguments: ["mode": .string("area")]) { answers.append($0) }
        host.captureDone?(.attached)
        later.first?.1()
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.details?["attached"] as? Bool, true)
    }

    func testPinnedCapturesListAndCloseAll() {
        let list = call("capture_list_pinned")
        XCTAssertEqual(items(list).first?["width"] as? Int, 800)
        XCTAssertEqual(call("capture_close_all").details?["closed"] as? Int, 1)
        XCTAssertTrue(call("capture_list_pinned").message.contains("No pinned"))
    }

    // MARK: dispatcher: gadget off, permissions

    func testSwitchedOffGadgetAnswersGadgetOffAndNothingRuns() {
        let d = GadgetToolDispatcher(gadgetIsOn: { _ in false }, permissionGranted: { _ in true })
        d.register(runner, for: DataGadgetRunner.gadgets)
        for name in ["monitor_stats", "disk_top_items", "clipboard_list", "clipboard_get_item", "shelf_list", "capture_ask", "capture_list_pinned"] {
            let o = d.runAndWait(tool(name), arguments: ["index": .int(1)], exit: .connector, timeout: 1)
            XCTAssertEqual(reason(o), "gadget_off", name)
            XCTAssertEqual(o.details?["hint"] as? String, "ask the user with ask_choice, then call combo_set_gadget")
            XCTAssertEqual(o.details?["gadget"] as? String, tool(name).gadget.rawValue)
        }
        XCTAssertTrue(host.captureModes.isEmpty)
        XCTAssertTrue(host.copied.isEmpty)
    }

    func testCaptureWithoutScreenRecordingAnswersPermissionNeeded() {
        let d = GadgetToolDispatcher(gadgetIsOn: { _ in true }, permissionGranted: { $0 != .screenRecording })
        d.register(runner, for: DataGadgetRunner.gadgets)
        let o = d.runAndWait(tool("capture_ask"), arguments: [:], exit: .connector, timeout: 1)
        XCTAssertEqual(reason(o), "permission_needed")
        XCTAssertEqual(o.details?["permission"] as? String, "screenRecording")
        XCTAssertTrue((o.details?["guide_ko"] as? String ?? "").contains("시스템 설정 > 개인정보 보호 및 보안 > 화면 기록"))
        XCTAssertTrue(host.captureModes.isEmpty)
        XCTAssertTrue(d.runAndWait(tool("capture_list_pinned"), arguments: [:], exit: .connector, timeout: 1).ok, "listing needs no permission")
    }

    // MARK: guides

    func testGuidesRenderPerExit() {
        let mcp = GadgetToolRegistry.guide(for: .clipboard)!.render(for: .mcp)
        XCTAssertTrue(mcp.contains("`clipboard_get_item {\"id\":\"3f2a9c1b\",\"index\":2}`"))
        let nacho = GadgetToolRegistry.guide(for: .shelf)!.render(for: .connector)
        XCTAssertTrue(nacho.contains("`combo_shelf_give {\"index\":1}`"))
        XCTAssertTrue(nacho.contains("`combo_clear_shelf`"), "the declared old name on Nacho's side")
        XCTAssertTrue(nacho.contains("destructive"))
        let shelfMCP = GadgetToolRegistry.guide(for: .shelf)!.render(for: .mcp)
        XCTAssertFalse(shelfMCP.contains("shelf_give {"), "give is Nacho's only")
        let capture = GadgetToolRegistry.guide(for: .capture)!.render(for: .connector)
        XCTAssertTrue(capture.contains("화면 기록"))
        XCTAssertTrue(GadgetToolRegistry.guide(for: .disk)!.render(for: .mcp).contains("삭제 도구는 없어요"))
    }
}

// MARK: round trips

final class DataGadgetRoundTripTests: XCTestCase {
    private var host = FakeDataHost()
    private var log: [String] = []

    private func runner() -> DataGadgetRunner { DataGadgetRunner(host: host, onMain: { $0() }, after: { _, _ in }) }

    /// initialize → resources/read → prompts/get → tools/call for each of the five gadgets, printed with the key masked
    /// and contents redacted (the round-trip log of the PR).
    func testMCPRoundTripCallsEachDataGadget() throws {
        host.clips = [ClipboardItem(kind: .text, text: secretClip)]
        host.shelf = [ShelfRow(ShelfItem(kind: .text, fileURL: nil, text: secretSnippet, ownsFile: false, title: ShelfStore.titleForText(secretSnippet)),
                               fileSize: { _ in nil })]
        host.disk = .ready(root: {
            let r = DiskNode(name: "sam", kind: .folder, size: 10, fileCount: 1, basePath: "/Users/sam")
            r.add(DiskNode(name: "Movies", kind: .folder, size: 9, fileCount: 1))
            return r
        }(), scannedAt: Date())
        var settings = ComputerUseSettings()
        for g in DataGadgetRunner.gadgets { settings.setGadgetEnabled(g, true) }
        let keys = APIKeyStore(url: nil, random: CountingRandom())
        let token = try keys.create(label: "Test Key").token
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(runner(), for: DataGadgetRunner.gadgets)
        let service = NachoComboMCPService(settings: { settings }, keys: keys, backend: FakeBackend(), gadgets: dispatcher)
        func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> [String: Any] {
            let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
            let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                               body: Data(body.utf8)), peer: "127.0.0.1")
            let text = String(decoding: r.body, as: UTF8.self)
            // Contents are redacted in the log: the text field of clipboard_get_item, nothing else carries content.
            let shown = text.replacingOccurrences(of: secretClip, with: "<redacted>")
            log.append("> \(method) \(params)")
            log.append("< \(r.status) \(shown.count > 220 ? String(shown.prefix(220)) + "…" : shown)")
            return (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        }
        func callOK(_ id: Int, _ name: String, _ args: String = "{}") -> [String: Any] {
            let o = rpc(id, "tools/call", #"{"name":"\#(name)","arguments":\#(args)}"#)
            let result = o["result"] as? [String: Any] ?? [:]
            XCTAssertEqual(result["isError"] as? Bool, false, name)
            let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        _ = rpc(1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"roundtrip","version":"1"}}"#)
        let list = ((rpc(2, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertTrue(Set(list).isSuperset(of: ["monitor_stats", "disk_top_items", "clipboard_list", "clipboard_get_item", "shelf_list", "capture_list_pinned"]))
        XCTAssertFalse(list.contains("shelf_give"), "Nacho only")
        XCTAssertFalse(list.contains("capture_ask"), "Nacho only")
        let resources = ((rpc(3, "resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
        for g in DataGadgetRunner.gadgets { XCTAssertTrue(resources.contains(g.guideURI), g.rawValue) }
        _ = rpc(4, "resources/read", #"{"uri":"nachocombo://gadgets/monitor/guide"}"#)
        _ = rpc(5, "prompts/get", #"{"name":"monitor_why_slow","arguments":{}}"#)
        XCTAssertEqual(callOK(6, "monitor_stats")["cpu_percent"] as? Double, 42.3)
        XCTAssertEqual((callOK(7, "disk_top_items", #"{"count":5}"#)["items"] as? [[String: Any]])?.first?["name"] as? String, "Movies")
        XCTAssertEqual((callOK(8, "clipboard_list")["items"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(callOK(9, "clipboard_get_item", #"{"index":1}"#)["text"] as? String, secretClip)
        XCTAssertEqual((callOK(10, "shelf_list")["items"] as? [[String: Any]])?.first?["name"] as? String, "text snippet")
        XCTAssertEqual((callOK(11, "capture_list_pinned")["items"] as? [[String: Any]])?.count, 1)
        let text = log.joined(separator: "\n")
        XCTAssertFalse(text.contains(token))
        XCTAssertFalse(text.contains("SECRET"), "no clipboard or shelf content in the log")
        XCTAssertFalse(service.callLog.entries.map { "\($0)" }.joined().contains("SECRET"), "the server's call log keeps names only")
        print("MCP-ROUNDTRIP-NACHO-149 (Authorization: Bearer ****, contents <redacted>)\n" + text)
    }

    /// Nacho's path: hello declares the approvals, a read runs at once, a content tool runs (after the server's card).
    func testConnectorRoundTripThroughTheBridge() {
        host.clips = [ClipboardItem(kind: .text, text: secretClip)]
        host.shelf = [ShelfRow(id: UUID(), name: "report.pdf", kind: .file, size: 10)]
        let factory = PetTransportFactory()
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(runner(), for: DataGadgetRunner.gadgets)
        let client = PetConnectorClient(url: URL(string: "ws://127.0.0.1:8787/ws/connector")!, token: "nct_abc", executor: PetRecordingExecutor(),
                                        makeTransport: factory.make, schedule: { _, _ in }, trust: GadgetTrust(), dispatcher: dispatcher)
        client.connect(); client.flush()
        let t = factory.with(path: "/ws/connector")[0]
        t.handler?(.opened); client.flush()
        t.deliver(#"{"type":"ready","agent_id":"a"}"#); client.flush()
        func object(_ s: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:] }
        let hello = t.sent.map(object).first { $0["type"] as? String == "hello" } ?? [:]
        let caps = (hello["capabilities"] as? [[String: Any]]) ?? []
        func approval(_ n: String) -> String? { caps.first { $0["name"] as? String == n }?["approval"] as? String }
        XCTAssertEqual(approval("combo_clipboard_get_item"), "required")
        XCTAssertEqual(approval("combo_shelf_give"), "required")
        XCTAssertEqual(approval("combo_capture_ask"), "required")
        XCTAssertEqual(approval("combo_clear_shelf"), "required")
        XCTAssertNil(approval("combo_monitor_stats"))
        func request(_ id: String, _ cap: String, _ params: String = "{}") -> [String: Any] {
            t.deliver(#"{"type":"request","id":"\#(id)","capability":"\#(cap)","params":\#(params)}"#)
            client.flush(); client.flush()
            return (t.sent.map(object).last { $0["id"] as? String == id }?["result"] as? [String: Any]) ?? [:]
        }
        XCTAssertEqual(request("1", "combo_monitor_stats")["ok"] as? Bool, true)
        XCTAssertEqual(request("2", "combo_clipboard_get_item", #"{"index":1}"#)["text"] as? String, secretClip)
        XCTAssertEqual(request("3", "combo_shelf_give", #"{"index":1}"#)["delivery"] as? String, "chat_attachment")
        XCTAssertEqual(host.handed, [host.shelf[0].id])
        XCTAssertEqual(request("4", "combo_clipboard_get_item", #"{"index":7}"#)["reason"] as? String, "out_of_range")
        XCTAssertFalse(client.handled.joined().contains("SECRET"), "the bridge log keeps names and ok/failed only")
    }
}
