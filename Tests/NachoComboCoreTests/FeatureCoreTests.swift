import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NachoComboCore

final class FeatureCoreTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nacho-combo-feature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: settings / modules

    func testNewModulesDefaultOffAndOldSettingsFileStillLoads() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"version":1,"enabledModules":{"menuBar":true},"menuBarCollapsed":false}"#.utf8).write(to: url)
        let s = SettingsStore(url: url).load()
        XCTAssertTrue(s.isEnabled(.menuBar))
        for id in [ModuleID.fileShelf, .captureFloat, .focusDim] { XCTAssertFalse(s.isEnabled(id)) }
        XCTAssertEqual(s.dimIntensity, FocusDimLogic.defaultIntensity)
    }

    func testDimIntensityIsClampedOnLoadAndPersisted() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"version":1,"enabledModules":{},"menuBarCollapsed":false,"dimIntensity":5}"#.utf8).write(to: url)
        XCTAssertEqual(SettingsStore(url: url).load().dimIntensity, FocusDimLogic.maximumIntensity)
        let manager = ModuleManager(store: SettingsStore(url: url), modules: [])
        manager.setDimIntensity(0.01)
        XCTAssertEqual(manager.settings.dimIntensity, FocusDimLogic.minimumIntensity)
        manager.setDimIntensity(0.35)
        XCTAssertEqual(SettingsStore(url: url).load().dimIntensity, 0.35, accuracy: 0.0001)
    }

    func testOnlyMenuBarAndMonitorCreateStatusItems() {
        XCTAssertTrue(ModuleID.menuBar.createsStatusItem)
        XCTAssertTrue(ModuleID.systemMonitor.createsStatusItem)
        for id in [ModuleID.windowSnap, .fileShelf, .captureFloat, .focusDim] { XCTAssertFalse(id.createsStatusItem) }
    }

    func testEachNewModuleTurnsOffIndependently() throws {
        let dir = try tempDir()
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        let a = FakeModule(.fileShelf), b = FakeModule(.captureFloat), c = FakeModule(.focusDim)
        let manager = ModuleManager(store: store, modules: [a, b, c])
        for id in [ModuleID.fileShelf, .captureFloat, .focusDim] { XCTAssertEqual(manager.setEnabled(id, true), .running) }
        XCTAssertEqual(manager.setEnabled(.captureFloat, false), .off)
        XCTAssertTrue(a.active); XCTAssertFalse(b.active); XCTAssertTrue(c.active)
        let reloaded = SettingsStore(url: store.url).load()
        XCTAssertTrue(reloaded.isEnabled(.fileShelf)); XCTAssertFalse(reloaded.isEnabled(.captureFloat))
        manager.shutdown()
        XCTAssertFalse(a.active); XCTAssertFalse(c.active)
    }

    func testPermissionPromptOnlyForUserInitiatedSwitchOn() throws {
        final class PromptModule: FeatureModule, PermissionPrompting {
            let id = ModuleID.captureFloat
            var allowPermissionPrompt = false
            var allowedAtStart: [Bool] = []
            func start() -> ModuleState { allowedAtStart.append(allowPermissionPrompt); return .needsPermission("x") }
            func stop() {}
            var diagnostics: [String: String] { [:] }
        }
        let dir = try tempDir()
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"))
        var saved = AppSettings.defaults
        saved.setEnabled(.captureFloat, true)
        try store.save(saved)
        let module = PromptModule()
        let manager = ModuleManager(store: store, modules: [module])
        manager.bootstrap()                    // restoring saved ON: no OS dialog
        manager.retry(.captureFloat)           // re-check after returning from System Settings: no dialog
        manager.setEnabled(.captureFloat, false)
        manager.setEnabled(.captureFloat, true) // the user switches it on: dialog allowed
        XCTAssertEqual(module.allowedAtStart, [false, false, true])
    }

    // MARK: shelf

    func testShelfNeverTouchesOriginalFiles() throws {
        let dir = try tempDir()
        let original = dir.appendingPathComponent("keep.txt")
        try Data("hello".utf8).write(to: original)
        let store = ShelfStore(ownedDirectory: dir.appendingPathComponent("Shelf"))
        let item = try XCTUnwrap(store.addFile(original))
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(store.addFile(original)?.id, item.id, "same file is not added twice")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.remove(id: item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "remove must not delete the original")
        store.addFile(original)
        store.clear()
        store.removeAllOwnedFiles()
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try String(contentsOf: original), "hello")
    }

    func testShelfRejectsMissingFilesAndEmptyText() throws {
        let store = ShelfStore(ownedDirectory: try tempDir())
        XCTAssertNil(store.addFile(URL(fileURLWithPath: "/definitely/not/here.bin")))
        XCTAssertNil(store.addFile(URL(string: "https://example.com/a.png")!))
        XCTAssertNil(store.addText("  \n "))
        XCTAssertEqual(store.items.count, 0)
    }

    func testShelfTextAndOwnedImageCopies() throws {
        let dir = try tempDir()
        let owned = dir.appendingPathComponent("Shelf")
        let store = ShelfStore(ownedDirectory: owned)
        let t1 = store.addText("First line\nSecond line")
        XCTAssertEqual(t1?.title, "First line")
        XCTAssertEqual(store.addText("First line\nSecond line")?.id, t1?.id)
        XCTAssertEqual(ShelfStore.titleForText(String(repeating: "a", count: 60)).count, 41)
        let image = try store.addImagePNG(Data([0x89, 0x50, 0x4E, 0x47]))
        let imageURL = try XCTUnwrap(image.fileURL)
        XCTAssertTrue(image.ownsFile)
        XCTAssertTrue(imageURL.path.hasPrefix(owned.standardizedFileURL.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(store.remove(id: image.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path), "kept while the removal can be undone")
        store.discardUndo()
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path), "shelf-created copy is cleaned up")
        let second = try store.addImagePNG(Data([1]))
        store.removeAllOwnedFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(second.fileURL).path))
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: focus dim

    private func win(_ n: Int, pid: Int32, layer: Int = 0, w: CGFloat = 400, h: CGFloat = 300, alpha: Double = 1) -> WindowSnapshot {
        WindowSnapshot(number: n, ownerPID: pid, layer: layer, frame: CGRect(x: 0, y: 0, width: w, height: h), alpha: alpha)
    }

    func testActiveWindowIsTopMostOrdinaryWindowOfFrontmostApp() {
        let list = [win(9, pid: 5, layer: 25), win(8, pid: 7), win(7, pid: 5, w: 10, h: 10), win(6, pid: 5), win(5, pid: 5)]
        XCTAssertEqual(FocusDimLogic.activeWindow(in: list, frontmostPID: 5, excluding: [])?.number, 6)
        XCTAssertEqual(FocusDimLogic.activeWindow(in: list, frontmostPID: 7, excluding: [])?.number, 8)
        XCTAssertEqual(FocusDimLogic.activeWindow(in: list, frontmostPID: 5, excluding: [6])?.number, 5)
        XCTAssertNil(FocusDimLogic.activeWindow(in: list, frontmostPID: 99, excluding: []))
        XCTAssertNil(FocusDimLogic.activeWindow(in: [win(1, pid: 5, alpha: 0)], frontmostPID: 5, excluding: []))
        XCTAssertNil(FocusDimLogic.activeWindow(in: [], frontmostPID: 5, excluding: []))
    }

    func testWindowSwitchChangesActiveWindow() {
        var list = [win(3, pid: 1), win(2, pid: 2)]
        XCTAssertEqual(FocusDimLogic.activeWindow(in: list, frontmostPID: 1, excluding: [])?.number, 3)
        list = [win(2, pid: 2), win(3, pid: 1)]
        XCTAssertEqual(FocusDimLogic.activeWindow(in: list, frontmostPID: 2, excluding: [])?.number, 2)
    }

    func testIntensityClamp() {
        XCTAssertEqual(FocusDimLogic.clamp(0), FocusDimLogic.minimumIntensity)
        XCTAssertEqual(FocusDimLogic.clamp(1), FocusDimLogic.maximumIntensity)
        XCTAssertEqual(FocusDimLogic.clamp(0.4), 0.4)
        XCTAssertEqual(FocusDimLogic.clamp(.nan), FocusDimLogic.defaultIntensity)
    }

    func testOverlayOrderPredicate() {
        XCTAssertTrue(FocusDimLogic.isBelow(10, active: 20, in: [20, 30, 10]))
        XCTAssertFalse(FocusDimLogic.isBelow(10, active: 20, in: [10, 20]))
        XCTAssertFalse(FocusDimLogic.isBelow(10, active: 20, in: [20]))
    }

    // MARK: capture math

    func testSelectionRectIsDirectionIndependent() {
        let a = CGPoint(x: 300, y: 200), b = CGPoint(x: 100, y: 50)
        XCTAssertEqual(RegionSelection.rect(from: a, to: b), CGRect(x: 100, y: 50, width: 200, height: 150))
        XCTAssertEqual(RegionSelection.rect(from: b, to: a), RegionSelection.rect(from: a, to: b))
        XCTAssertFalse(RegionSelection.isCapturable(CGRect(x: 0, y: 0, width: 7, height: 100)))
        XCTAssertTrue(RegionSelection.isCapturable(CGRect(x: 0, y: 0, width: 8, height: 8)))
        XCTAssertEqual(RegionSelection.clamp(CGRect(x: -50, y: -50, width: 200, height: 200), to: CGRect(x: 0, y: 0, width: 100, height: 100)),
                       CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(RegionSelection.clamp(CGRect(x: 500, y: 500, width: 10, height: 10), to: CGRect(x: 0, y: 0, width: 100, height: 100)), .zero)
    }

    func testCaptureRectConvertsCocoaToDisplayCoordinates() {
        let cocoa = CGRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertEqual(RegionSelection.captureRect(fromCocoa: cocoa, primaryScreenHeight: 800), CGRect(x: 100, y: 450, width: 400, height: 300))
    }

    func testFloatResizeKeepsAspectAndLimits() {
        let original = CGSize(width: 400, height: 200)
        XCTAssertEqual(FloatSizing.resized(original: original, proposedWidth: 200, max: CGSize(width: 1000, height: 1000)), CGSize(width: 200, height: 100))
        XCTAssertEqual(FloatSizing.resized(original: original, proposedWidth: 5, max: CGSize(width: 1000, height: 1000)).width, FloatSizing.minimumWidth)
        let capped = FloatSizing.resized(original: original, proposedWidth: 5000, max: CGSize(width: 1000, height: 300))
        XCTAssertEqual(capped, CGSize(width: 600, height: 300))
        XCTAssertEqual(FloatSizing.scaled(original, percent: 50), CGSize(width: 200, height: 100))
        XCTAssertGreaterThan(FloatSizing.resized(original: .zero, proposedWidth: 100, max: .zero).width, 0)
    }

    // MARK: shelf additions

    func testShelfUndoRestoresTheLastRemoval() throws {
        let dir = try tempDir()
        let store = ShelfStore(ownedDirectory: dir.appendingPathComponent("Shelf"))
        let text = try XCTUnwrap(store.addText("note"))
        let image = try store.addImagePNG(Data([1, 2]))
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.items.map { $0.id }, [text.id, image.id])
        XCTAssertFalse(store.undo(), "one level of undo")
        // A newer removal replaces the undo, and the older stash's own copies are deleted then.
        XCTAssertTrue(store.remove(id: image.id))
        XCTAssertTrue(store.remove(id: text.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(image.fileURL).path))
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.items.map { $0.id }, [text.id])
    }

    func testShelfLinksAndOwnedFilesStayInsideTheShelf() throws {
        let dir = try tempDir()
        let owned = dir.appendingPathComponent("Shelf")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let store = ShelfStore(ownedDirectory: owned)
        let link = try XCTUnwrap(store.addLink(URL(string: "https://example.com/docs/page")!))
        XCTAssertEqual(link.kind, .link)
        XCTAssertEqual(link.title, "example.com/docs/page")
        XCTAssertEqual(link.linkURL, URL(string: "https://example.com/docs/page"))
        XCTAssertEqual(store.addLink(URL(string: "https://example.com/docs/page")!)?.id, link.id)
        XCTAssertNil(store.addLink(URL(fileURLWithPath: "/tmp")))
        // A promised file written into the shelf folder is owned; anything outside is refused.
        let promised = owned.appendingPathComponent("photo.jpg")
        try Data([0xFF]).write(to: promised)
        let item = try XCTUnwrap(store.addOwnedFile(promised))
        XCTAssertTrue(item.ownsFile)
        XCTAssertEqual(item.kind, .image)
        let outside = dir.appendingPathComponent("mine.txt")
        try Data("x".utf8).write(to: outside)
        XCTAssertNil(store.addOwnedFile(outside))
        XCTAssertNil(store.addOwnedFile(owned.appendingPathComponent("../mine.txt")))
        store.removeAllOwnedFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: promised.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testShakeNeedsQuickReversals() {
        var shake = ShakeDetector()
        var t = 0.0
        var fired = false
        for x in [0, 30, 0, 30, 0] as [CGFloat] {
            t += 0.1
            fired = shake.add(x: x, time: t) || fired
        }
        XCTAssertTrue(fired)
        // Slow reversals (outside the window) and small jitter do not count.
        shake.reset()
        fired = false
        t = 0
        for x in [0, 30, 0, 30, 0] as [CGFloat] {
            t += 0.5
            fired = shake.add(x: x, time: t) || fired
        }
        XCTAssertFalse(fired)
        shake.reset()
        fired = false
        for (i, x) in ([0, 10, 0, 10, 0, 10, 0] as [CGFloat]).enumerated() {
            fired = shake.add(x: x, time: Double(i) * 0.05) || fired
        }
        XCTAssertFalse(fired)
    }
}
