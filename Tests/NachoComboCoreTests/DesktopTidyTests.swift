import XCTest
@testable import NachoComboCore

/// NACHO-38: the desktop tidy engine on a temporary folder used as the desktop. No real desktop is touched.
final class DesktopTidyTests: XCTestCase {
    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    private let fm = FileManager.default
    private var root: URL!
    private var desktop: URL!
    private var journal: URL!
    private var clock: Clock!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("desktop-tidy-\(UUID().uuidString)", isDirectory: true)
        desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        journal = root.appendingPathComponent("support/desktop-tidy/journal.json")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func engine() -> DesktopTidyEngine {
        DesktopTidyEngine(desktop: desktop, journalURL: journal, now: { [clock] in clock!.date })
    }

    @discardableResult
    private func make(_ name: String, _ text: String = "x", age: TimeInterval = 3600, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? desktop).appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: clock.date.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    private func tidied(_ category: DesktopCategory, _ name: String) -> URL {
        desktop.appendingPathComponent("정리됨").appendingPathComponent(category.folderName).appendingPathComponent(name)
    }
    private func plan(_ e: DesktopTidyEngine, file: StaticString = #filePath, line: UInt = #line) throws -> DesktopTidyPlan {
        switch e.plan() {
        case .success(let p): return p
        case .failure(let err): XCTFail("plan failed: \(err)", file: file, line: line); throw err
        }
    }
    private func applied(_ e: DesktopTidyEngine, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> DesktopTidyApplied {
        switch e.apply(planID: id) {
        case .success(let a): return a
        case .failure(let err): XCTFail("apply failed: \(err)", file: file, line: line); throw err
        }
    }

    // MARK: classification

    func testClassificationFirstMatchWinsAndScreenshotsComeFirst() {
        let table: [(String, DesktopCategory)] = [
            ("스크린샷 2026-11-14 오후 3.04.05.png", .screenshot), ("Screenshot 2026-11-14 at 15.04.png", .screenshot),
            ("Screen Shot 2020-01-01.JPG", .screenshot), ("Screenshot.png", .image), ("스크린샷.png", .image),
            ("Screenshot 1.pdf", .document), ("사진.HEIC", .image), ("a.svg", .image), ("보고서.hwpx", .document), ("a.numbers", .document),
            ("a.tar", .archive), ("a.tgz", .archive), ("Nacho.dmg", .installer), ("x.mpkg", .installer), ("movie.mov", .other), ("README", .other),
        ]
        for (name, want) in table { XCTAssertEqual(DesktopCategory.classify(name: name), want, name) }
        // The Finder may name files with decomposed Hangul.
        XCTAssertEqual(DesktopCategory.classify(name: "스크린샷 1.png".decomposedStringWithCanonicalMapping), .screenshot)
        XCTAssertEqual(DesktopCategory.allCases.map { $0.folderName }, ["스크린샷", "이미지", "문서", "압축", "설치 파일", "기타"])
    }

    // MARK: plan

    func testPlanTakesOnlyPlainOldFilesAndMovesNothing() throws {
        try make("보고서.pdf")
        try make("사진.png")
        try make("메모")
        try make(".DS_Store")
        try make(".hidden.txt")
        try make("받는 중.zip.crdownload")
        try make("a.download")
        try make("b.part")
        try make("방금.txt", age: 30)
        try make("경계.txt", age: 119)
        try make("정확히.txt", age: 120)
        try fm.createDirectory(at: desktop.appendingPathComponent("폴더"), withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop.appendingPathComponent("Safari.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: desktop.appendingPathComponent("정리됨/문서"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: desktop.appendingPathComponent("바로가기.pdf"), withDestinationURL: desktop.appendingPathComponent("보고서.pdf"))
        let before = try fm.contentsOfDirectory(atPath: desktop.path).sorted()

        let p = try plan(engine())

        XCTAssertEqual(p.candidates.map { $0.name }, ["메모", "보고서.pdf", "사진.png", "정확히.txt"].sorted(), "old regular files only")
        XCTAssertEqual(p.counts[.document], 2)
        XCTAssertEqual(p.counts[.image], 1)
        XCTAssertEqual(p.counts[.other], 1)
        XCTAssertEqual(p.skippedCount, 5, "crdownload, .download, .part, the 30 s file and the 119 s file (hidden files, folders and links are not counted)")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: desktop.path).sorted(), before, "planning moves nothing")
        XCTAssertEqual(p.expiresAt.timeIntervalSince(p.createdAt), 600)
    }

    func testPlanOfAnEmptyDesktopHasNoPlanToApply() throws {
        let e = engine()
        let p = try plan(e)
        XCTAssertEqual(p.total, 0)
        XCTAssertEqual(e.apply(planID: p.id), .failure(.planNotFound))
    }

    func testUnreadableDesktop() {
        let e = DesktopTidyEngine(desktop: root.appendingPathComponent("missing"), journalURL: journal, now: { [clock] in clock!.date })
        XCTAssertEqual(e.plan(), .failure(.desktopUnreadable))
    }

    // MARK: apply

    func testApplyMovesIntoCategoryFoldersAndKeepsTheContent() throws {
        try make("스크린샷 1.png", "shot")
        try make("보고서.pdf", "report")
        try make("Nacho.dmg", "dmg")
        let e = engine()
        let p = try plan(e)
        let done = try applied(e, p.id)

        XCTAssertEqual(done.moves.count, 3)
        XCTAssertEqual(done.counts[.screenshot], 1)
        XCTAssertTrue(done.skipped.isEmpty)
        XCTAssertTrue(done.journalSaved)
        XCTAssertEqual(try String(contentsOf: tidied(.screenshot, "스크린샷 1.png")), "shot")
        XCTAssertEqual(try String(contentsOf: tidied(.document, "보고서.pdf")), "report")
        XCTAssertEqual(try String(contentsOf: tidied(.installer, "Nacho.dmg")), "dmg")
        XCTAssertFalse(exists(desktop.appendingPathComponent("보고서.pdf")))
        XCTAssertEqual(e.apply(planID: p.id), .failure(.planNotFound), "a plan runs once")
    }

    func testNameClashGetsANumberAndNothingIsOverwritten() throws {
        try make("a.pdf", "first")
        let e = engine()
        _ = try applied(e, try plan(e).id)
        try make("a.pdf", "second")
        _ = try applied(e, try plan(e).id)
        try make("a.pdf", "third")
        _ = try applied(e, try plan(e).id)
        try make("noext", "n1")
        _ = try applied(e, try plan(e).id)
        try make("noext", "n2")
        _ = try applied(e, try plan(e).id)

        XCTAssertEqual(try String(contentsOf: tidied(.document, "a.pdf")), "first")
        XCTAssertEqual(try String(contentsOf: tidied(.document, "a 2.pdf")), "second")
        XCTAssertEqual(try String(contentsOf: tidied(.document, "a 3.pdf")), "third")
        XCTAssertEqual(try String(contentsOf: tidied(.other, "noext")), "n1")
        XCTAssertEqual(try String(contentsOf: tidied(.other, "noext 2")), "n2")
    }

    func testAPlanIsStaleAfterTenMinutes() throws {
        try make("a.pdf")
        let e = engine()
        let p = try plan(e)
        clock.date = clock.date.addingTimeInterval(601)
        XCTAssertEqual(e.apply(planID: p.id), .failure(.planStale))
        XCTAssertTrue(exists(desktop.appendingPathComponent("a.pdf")), "nothing moved")
        XCTAssertEqual(e.apply(planID: "deadbeef"), .failure(.planNotFound))
        // Just inside the lifetime still runs.
        let again = try plan(e)
        clock.date = clock.date.addingTimeInterval(599)
        XCTAssertEqual(try applied(e, again.id).moves.count, 1)
    }

    func testFilesChangedAfterThePlanAreSkippedAndReported() throws {
        try make("same.pdf")
        try make("edited.pdf", "old")
        try make("grown.txt", "old")
        try make("touched.txt")
        try make("gone.txt")
        try make("swapped.txt")
        let e = engine()
        let p = try plan(e)
        // after the plan
        try make("edited.pdf", "old")  // same size, different time
        try make("grown.txt", "old and more", age: 3600)
        try fm.setAttributes([.modificationDate: clock.date.addingTimeInterval(-10)], ofItemAtPath: desktop.appendingPathComponent("touched.txt").path)
        try fm.removeItem(at: desktop.appendingPathComponent("gone.txt"))
        try fm.removeItem(at: desktop.appendingPathComponent("swapped.txt"))
        try fm.createDirectory(at: desktop.appendingPathComponent("swapped.txt"), withIntermediateDirectories: true)
        // make() above wrote edited.pdf with the same age, so give it a different time to be a real change
        try fm.setAttributes([.modificationDate: clock.date.addingTimeInterval(-1800)], ofItemAtPath: desktop.appendingPathComponent("edited.pdf").path)

        let done = try applied(e, p.id)

        XCTAssertEqual(done.moves.map { ($0.from as NSString).lastPathComponent }, ["same.pdf"])
        let reasons = Dictionary(uniqueKeysWithValues: done.skipped.map { ($0.name, $0.reason) })
        XCTAssertEqual(reasons["edited.pdf"], "changed")
        XCTAssertEqual(reasons["grown.txt"], "changed")
        XCTAssertEqual(reasons["touched.txt"], "recent")
        XCTAssertEqual(reasons["gone.txt"], "missing")
        XCTAssertEqual(reasons["swapped.txt"], "not_a_file")
        XCTAssertTrue(exists(desktop.appendingPathComponent("edited.pdf")), "skipped files stay")
    }

    func testNothingMovedWritesNoJournalEntry() throws {
        try make("a.pdf")
        let e = engine()
        let p = try plan(e)
        try fm.removeItem(at: desktop.appendingPathComponent("a.pdf"))
        let done = try applied(e, p.id)
        XCTAssertNil(done.tidyID)
        XCTAssertTrue(e.history().isEmpty)
    }

    // MARK: journal

    func testJournalHoldsTidyIDTimeAndMoves() throws {
        try make("a.pdf")
        let e = engine()
        let done = try applied(e, try plan(e).id)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any]
        let entry = (json?["entries"] as? [[String: Any]])?.first
        XCTAssertEqual(entry?["tidy_id"] as? String, done.tidyID)
        XCTAssertNotNil(entry?["at"] as? String)
        let move = (entry?["moves"] as? [[String: String]])?.first
        XCTAssertEqual(move?["from"], desktop.appendingPathComponent("a.pdf").path)
        XCTAssertEqual(move?["to"], tidied(.document, "a.pdf").path)
        let rows = e.history()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].count, 1)
        XCTAssertFalse(rows[0].undone)
    }

    func testEntriesOlderThanThirtyDaysAreDroppedButFilesAreNotTouched() throws {
        try make("a.pdf", "keep me")
        let e = engine()
        _ = try applied(e, try plan(e).id)
        clock.date = clock.date.addingTimeInterval(29 * 86_400)
        XCTAssertEqual(e.history().count, 1)
        try make("b.pdf")
        _ = try applied(e, try plan(e).id)
        XCTAssertEqual(e.history().count, 2)
        clock.date = clock.date.addingTimeInterval(2 * 86_400)  // a.pdf's tidy is now 31 days old, b's is 2
        e.pruneJournal()
        XCTAssertEqual(e.history().count, 1)
        let onDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any]
        XCTAssertEqual((onDisk?["entries"] as? [Any])?.count, 1, "the record is gone from the file")
        XCTAssertEqual(try String(contentsOf: tidied(.document, "a.pdf")), "keep me", "the file is not touched")
    }

    func testAnUnreadableJournalIsKeptAsideNotOverwritten() throws {
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: journal)
        try make("a.pdf")
        let e = engine()
        _ = try applied(e, try plan(e).id)
        let names = try fm.contentsOfDirectory(atPath: journal.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains { $0.hasPrefix("journal-unreadable-") }, "\(names)")
        XCTAssertEqual(e.history().count, 1)
    }

    // MARK: undo

    func testUndoPutsEverythingBackAndMarksTheTidy() throws {
        try make("a.pdf", "A")
        try make("b.png", "B")
        let e = engine()
        let done = try applied(e, try plan(e).id)
        let result = try XCTUnwrap(try? e.undo().get())
        XCTAssertEqual(result.tidyID, done.tidyID)
        XCTAssertEqual(result.restored, 2)
        XCTAssertTrue(result.complete)
        XCTAssertTrue(result.notRestored.isEmpty)
        XCTAssertEqual(try String(contentsOf: desktop.appendingPathComponent("a.pdf")), "A")
        XCTAssertEqual(try String(contentsOf: desktop.appendingPathComponent("b.png")), "B")
        XCTAssertTrue(exists(desktop.appendingPathComponent("정리됨/문서")), "the empty category folder stays")
        XCTAssertEqual(e.history().first?.undone, true)
        XCTAssertEqual(e.undo(), .failure(.nothingToUndo))
        XCTAssertEqual(e.undo(tidyID: done.tidyID), .failure(.alreadyUndone))
        XCTAssertEqual(e.undo(tidyID: "nope"), .failure(.tidyNotFound))
    }

    func testUndoTakesTheLatestNotUndoneTidyOrTheNamedOne() throws {
        try make("a.pdf")
        let e = engine()
        let first = try applied(e, try plan(e).id)
        try make("b.pdf")
        let second = try applied(e, try plan(e).id)
        XCTAssertEqual(try e.undo(tidyID: first.tidyID).get().restored, 1)
        XCTAssertTrue(exists(desktop.appendingPathComponent("a.pdf")))
        XCTAssertFalse(exists(desktop.appendingPathComponent("b.pdf")))
        XCTAssertEqual(try e.undo().get().tidyID, second.tidyID, "the latest one not undone yet")
    }

    func testUndoNeverOverwritesAndReportsWhatItCouldNotDo() throws {
        try make("taken.pdf", "moved")
        try make("lost.pdf", "lost")
        try make("fine.pdf", "fine")
        let e = engine()
        let done = try applied(e, try plan(e).id)
        try make("taken.pdf", "NEW FILE ON DESKTOP")
        try fm.removeItem(at: tidied(.document, "lost.pdf"))

        let result = try e.undo().get()

        XCTAssertEqual(result.restored, 1)
        XCTAssertFalse(result.complete, "the conflict is still to be restored")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.notRestored.map { ($0.name, $0.reason) }),
                       ["taken.pdf": "conflict", "lost.pdf": "not_found"])
        XCTAssertEqual(try String(contentsOf: desktop.appendingPathComponent("taken.pdf")), "NEW FILE ON DESKTOP", "not overwritten")
        XCTAssertEqual(try String(contentsOf: tidied(.document, "taken.pdf")), "moved", "stays in 정리됨")
        XCTAssertEqual(try String(contentsOf: desktop.appendingPathComponent("fine.pdf")), "fine")
        let row = try XCTUnwrap(e.history().first)
        XCTAssertFalse(row.undone)
        XCTAssertEqual(row.pendingRestore, 1)
        XCTAssertEqual(row.count, 3, "the count of the tidy itself")
        // The user clears the conflict; undo again finishes the rest only.
        try fm.moveItem(at: desktop.appendingPathComponent("taken.pdf"), to: desktop.appendingPathComponent("taken-new.pdf"))
        let again = try e.undo(tidyID: done.tidyID).get()
        XCTAssertEqual(again.restored, 1)
        XCTAssertTrue(again.complete)
        XCTAssertEqual(try String(contentsOf: desktop.appendingPathComponent("taken.pdf")), "moved")
    }

    func testATamperedJournalCannotMoveFilesOutsideTheTidyFolders() throws {
        let outside = try make("secret.txt", "outside", in: root)
        try fm.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record: [String: Any] = ["entries": [["tidy_id": "evil0001", "at": DesktopTidyEngine.iso(clock.date),
                                                  "moves": [["from": desktop.appendingPathComponent("stolen.txt").path, "to": outside.path],
                                                            ["from": root.appendingPathComponent("elsewhere.txt").path,
                                                             "to": tidied(.other, "x").path]]]]]
        try JSONSerialization.data(withJSONObject: record).write(to: journal)
        let result = try engine().undo().get()
        XCTAssertEqual(result.restored, 0)
        XCTAssertEqual(result.notRestored.map { $0.reason }, ["invalid_record", "invalid_record"])
        XCTAssertTrue(exists(outside))
        XCTAssertFalse(exists(desktop.appendingPathComponent("stolen.txt")))
    }

    // MARK: nothing is deleted

    func testNoFileIsEverDeletedOrChangedAcrossTidyAndUndo() throws {
        var expected: [String: String] = [:]
        for (i, name) in ["a.pdf", "b.png", "c.zip", "d.dmg", "e", "스크린샷 1.png"].enumerated() {
            try make(name, "content \(i)")
            expected[name] = "content \(i)"
        }
        func contents() throws -> [String: String] {
            var out: [String: String] = [:]
            let walker = try XCTUnwrap(fm.enumerator(at: desktop, includingPropertiesForKeys: nil))
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out[url.lastPathComponent] = try String(contentsOf: url)
            }
            return out
        }
        let e = engine()
        XCTAssertEqual(try contents(), expected)
        _ = try applied(e, try plan(e).id)
        XCTAssertEqual(try contents(), expected, "after tidy")
        _ = try e.undo().get()
        XCTAssertEqual(try contents(), expected, "after undo")
        _ = try applied(e, try plan(e).id)
        XCTAssertEqual(try contents(), expected, "after a second tidy")
    }

    func testTheEngineSourceNeverRemovesAFile() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/NachoComboCore/DesktopTidy.swift")
        guard let text = try? String(contentsOf: source) else { throw XCTSkip("source not next to the tests") }
        for forbidden in ["removeItem", "trashItem", "unlink(", "remove(", "replaceItem", "FileHandle(forWriting"] {
            XCTAssertFalse(text.contains(forbidden), "DesktopTidy.swift uses \(forbidden)")
        }
        XCTAssertTrue(text.contains("moveItem"))
    }
}
