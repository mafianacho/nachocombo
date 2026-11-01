import XCTest
@testable import NachoComboCore

final class DiskMapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let home = "/Users/sam"

    private func file(_ name: String, _ size: Int64, days: Double = 1) -> DiskNode {
        DiskNode(name: name, kind: .file, size: size, fileCount: 1, modified: now.timeIntervalSince1970 - days * 86_400)
    }

    /// root (100) ─ a (60) ─ a1 (40), a2 (20)
    ///            └ b (40)
    private func tree() -> (root: DiskNode, a: DiskNode, a1: DiskNode, b: DiskNode) {
        let root = DiskNode(name: "Disk", kind: .folder, size: 100, fileCount: 3, basePath: "/")
        let a = DiskNode(name: "a", kind: .folder, size: 60, fileCount: 2)
        let a1 = file("a1", 40), a2 = file("a2", 20), b = file("b", 40)
        root.add(a)
        root.add(b)
        a.add(a1)
        a.add(a2)
        return (root, a, a1, b)
    }

    // MARK: tree

    func testPathsJoinFromTheScanRoot() {
        let t = tree()
        XCTAssertEqual(t.a1.path, "/a/a1")
        let scan = DiskNode(name: "Work", kind: .folder, basePath: "/tmp/Work")
        let inner = DiskNode(name: "x", kind: .file)
        scan.add(inner)
        XCTAssertEqual(inner.path, "/tmp/Work/x")
        XCTAssertTrue(t.a1.isInside(t.root))
        XCTAssertFalse(t.b.isInside(t.a))
        XCTAssertTrue(t.root.descendant(at: "/a/a1") === t.a1)
        XCTAssertNil(t.root.descendant(at: "/nowhere"))
    }

    func testASumStandsForItsFolderOnDisk() {
        let t = tree()
        t.a.addSmaller(bytes: 5, items: 2, modified: 0)
        XCTAssertEqual(t.a.children.last?.kind, .smaller)
        XCTAssertEqual(t.a.children.last?.path, "/a")
        XCTAssertEqual(t.a.children.last?.isItem, false)
    }

    func testDetachShrinksEveryFolderAbove() {
        let t = tree()
        t.a1.detach()
        XCTAssertEqual(t.a.size, 20)
        XCTAssertEqual(t.root.size, 60)
        XCTAssertEqual(t.root.fileCount, 2)
        XCTAssertEqual(t.a.children.count, 1)
        XCTAssertNil(t.a1.parent)
    }

    func testAdoptingANewScanMovesTheDifferenceUpward() {
        let t = tree()
        let fresh = DiskNode(name: "a", kind: .folder, size: 90, fileCount: 5, modified: 7)
        fresh.add(file("new", 90))
        t.a.adopt(contentsOf: fresh)
        XCTAssertEqual(t.a.size, 90)
        XCTAssertEqual(t.root.size, 130)
        XCTAssertEqual(t.root.fileCount, 6)
        XCTAssertTrue(t.a.children.first?.parent === t.a)
        XCTAssertFalse(t.a.isCollapsed)
    }

    func testTrimKeepsTheLargestAndSumsTheRest() {
        let folder = DiskNode(name: "big", kind: .folder, size: 0)
        for index in 0..<200 { folder.add(file("f\(index)", Int64(index + 1))) }
        folder.size = folder.children.reduce(0) { $0 + $1.size }
        let before = folder.size
        folder.trim()
        XCTAssertLessThanOrEqual(folder.children.count, DiskNode.mostKept + 1)
        XCTAssertEqual(folder.children.first?.name, "f199")
        XCTAssertEqual(folder.children.last?.kind, .smaller)
        XCTAssertEqual(folder.children.reduce(0) { $0 + $1.size }, before, "nothing is lost")
        XCTAssertEqual(folder.children.last?.fileCount, 200 - (folder.children.count - 1))
    }

    func testTrimPutsTheSumLastEvenWhenItIsTheLargest() {
        let folder = DiskNode(name: "big", kind: .folder, size: 110)
        folder.add(DiskNode(name: "many", kind: .smaller, size: 100, fileCount: 40))
        folder.add(file("one", 10))
        folder.trim()
        XCTAssertEqual(folder.children.map { $0.kind }, [.file, .smaller])
    }

    // MARK: space and text

    func testSpaceAddsUp() {
        let space = DiskSpace(total: 1000, free: 200, available: 260)
        XCTAssertEqual(space.used, 800)
        XCTAssertEqual(space.purgeable, 60)
        XCTAssertEqual(space.hidden(scanned: 700), 100)
        XCTAssertEqual(space.hidden(scanned: 900), 0, "clones can add up to more than is used")
        XCTAssertEqual(space.freeFraction, 0.2, accuracy: 1e-9)
        let odd = DiskSpace(total: 100, free: 150, available: 10)
        XCTAssertEqual(odd.free, 100)
        XCTAssertEqual(odd.available, 100)
    }

    func testSizesReadLikeFinder() {
        XCTAssertEqual(DiskFormat.size(0), "0 KB")
        XCTAssertEqual(DiskFormat.size(4096), "4 KB")
        XCTAssertEqual(DiskFormat.size(812_000_000), "812 MB")
        XCTAssertEqual(DiskFormat.size(77_100_000_000), "77.1 GB")
        XCTAssertEqual(DiskFormat.size(582_000_000_000), "582 GB")
        XCTAssertEqual(DiskFormat.size(1_240_000_000_000), "1.24 TB")
        XCTAssertEqual(DiskFormat.size(999_900_000), "1.0 GB")
        XCTAssertEqual(DiskFormat.files(1), "1 file")
        XCTAssertEqual(DiskFormat.files(2301), "2,301 files")
    }

    func testAgeText() {
        func age(_ days: Double) -> String? { DiskFormat.age(now.timeIntervalSince1970 - days * 86_400, now: now) }
        XCTAssertEqual(age(0.2), "today")
        XCTAssertEqual(age(1.5), "yesterday")
        XCTAssertEqual(age(12), "12 days ago")
        XCTAssertEqual(age(90), "3 months ago")
        XCTAssertEqual(age(800), "2 years ago")
        XCTAssertNil(DiskFormat.age(0, now: now))
    }

    func testAgeHeatRunsFromFreshToStale() {
        func heat(_ days: Double) -> Double { DiskColoring.ageHeat(modified: now.timeIntervalSince1970 - days * 86_400, now: now) }
        XCTAssertEqual(heat(0), 0, accuracy: 1e-9)
        XCTAssertEqual(heat(1000), 1, accuracy: 1e-9)
        XCTAssertLessThan(heat(7), heat(30))
        XCTAssertLessThan(heat(30), heat(365))
        XCTAssertEqual(DiskColoring.ageHeat(modified: 0, now: now), 0.5, "unknown stays in the middle")
    }

    // MARK: removal policy

    private func verdict(_ path: String) -> DiskRemovalVerdict { DiskRemovalPolicy.verdict(path: path, home: home) }

    func testMacOSItselfIsNeverOffered() {
        for path in ["/", "/System", "/System/Library/CoreServices", "/usr", "/usr/bin/git", "/bin/ls", "/sbin", "/dev/null",
                     "/private/etc/hosts", "/private/var/db/dslocal", "/private/var/vm/swapfile0", "/Library/Apple/usr",
                     "/private/var/folders/ab/cd"] {
            XCTAssertTrue(verdict(path).isBlocked, path)
        }
    }

    func testFoldersMacOSKeepsAreNotOfferedButTheirContentsAre() {
        for path in ["/Applications", "/Applications/", "/Library", "/Users", "/Users/sam", "/Users/sam/Library", "/Users/sam/Documents",
                     "/Users/sam/Desktop", "/Users/sam/Downloads", "/Users/sam/Pictures", "/Users/sam/.Trash", "/Volumes", "/private",
                     "/private/var", "/private/tmp", "/opt"] {
            XCTAssertTrue(verdict(path).isBlocked, path)
        }
        XCTAssertEqual(verdict("/Users/sam/Downloads/Installer.dmg"), .allowed)
        XCTAssertEqual(verdict("/Users/sam/Documents/Old"), .allowed)
        XCTAssertEqual(verdict("/usr/local/lib/node_modules"), .allowed)
        XCTAssertEqual(verdict("/Users/Shared/Adobe"), .allowed)
    }

    func testAnotherAccountIsLeftAlone() {
        XCTAssertTrue(verdict("/Users/alex").isBlocked)
        XCTAssertTrue(verdict("/Users/alex/Movies/film.mov").isBlocked)
    }

    func testRiskyItemsCarryAWarning() {
        XCTAssertNotNil(verdict("/Users/sam/Library/Caches/com.app").cautionText)
        XCTAssertTrue(verdict("/Users/sam/Library/Mobile Documents/com~apple~CloudDocs").cautionText?.contains("syncs") ?? false)
        XCTAssertTrue(verdict("/Users/sam/Library/CloudStorage/Dropbox").cautionText?.contains("syncs") ?? false)
        XCTAssertNotNil(verdict("/Applications/Figma.app").cautionText)
        XCTAssertNotNil(verdict("/Library/Developer/Toolchains").cautionText)
        XCTAssertNotNil(verdict("/opt/homebrew").cautionText)
        XCTAssertNotNil(verdict("/Users/sam/Pictures/Photos Library.photoslibrary").cautionText)
        XCTAssertNotNil(verdict("/Users/sam/Projects/site/.git").cautionText)
    }

    // MARK: collection

    func testAFolderReplacesWhatWasPickedInsideIt() {
        let t = tree()
        var list = DiskCollection()
        XCTAssertTrue(list.add(t.a1))
        XCTAssertFalse(list.add(t.a1), "only once")
        XCTAssertEqual(list.bytes, 40)
        XCTAssertTrue(list.add(t.a))
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.bytes, 60)
        XCTAssertFalse(list.add(t.a1), "already inside a picked folder")
        XCTAssertTrue(list.contains(t.a1))
        XCTAssertTrue(list.add(t.b))
        XCTAssertEqual(list.bytes, 100)
    }

    func testOnlyRealItemsCanBePicked() {
        var list = DiskCollection()
        XCTAssertFalse(list.add(DiskNode(name: "1 smaller item", kind: .smaller, size: 5)))
        XCTAssertFalse(list.add(DiskNode(name: "Free", kind: .free, size: 5)))
        XCTAssertFalse(list.add(DiskNode(name: "Hidden", kind: .hidden, size: 5)))
        XCTAssertTrue(list.isEmpty)
    }

    func testItemsThatLeftTheTreeAreForgotten() {
        let t = tree()
        var list = DiskCollection()
        list.add(t.a1)
        list.add(t.b)
        t.b.detach()
        list.keep(in: t.root)
        XCTAssertEqual(list.items.count, 1)
        XCTAssertTrue(list.items.first === t.a1)
    }

    // MARK: sunburst

    func testWheelCoversTheWholeCircle() {
        let t = tree()
        let arcs = Sunburst.arcs(focus: t.root, rings: 3, smallestAngle: 0.001)
        let top = arcs.filter { $0.ring == 0 }
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top.reduce(0) { $0 + $1.span }, 2 * .pi, accuracy: 1e-9)
        XCTAssertEqual(top[0].node?.name, "a", "largest first, from twelve o'clock")
        XCTAssertEqual(top[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(top[0].span, 2 * .pi * 0.6, accuracy: 1e-9)
        let inner = arcs.filter { $0.ring == 1 }
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(inner.reduce(0) { $0 + $1.span }, top[0].span, accuracy: 1e-9, "children fill their parent's arc")
        // Children divide the parent's stretch of the color ramp: a stays in 0...0.6, b has the rest.
        XCTAssertEqual(top[0].tone, 0.3, accuracy: 1e-9)
        XCTAssertEqual(top[1].tone, 0.8, accuracy: 1e-9)
        XCTAssertEqual(inner[0].tone, 0.2, accuracy: 1e-9)
        XCTAssertEqual(inner[1].tone, 0.5, accuracy: 1e-9)
    }

    func testFreeSpaceTakesItsShareOfTheCircle() {
        let t = tree()
        let free = DiskNode(name: "Free", kind: .free, size: 300)
        let hidden = DiskNode(name: "Hidden", kind: .hidden, size: 100)
        let top = Sunburst.arcs(focus: t.root, slices: [free, hidden], rings: 2, smallestAngle: 0.001).filter { $0.ring == 0 }
        XCTAssertEqual(top.map { $0.node?.kind }, [.folder, .file, .hidden, .free])
        XCTAssertEqual(top[3].span, 2 * .pi * 0.6, accuracy: 1e-9)
        XCTAssertEqual(top[3].end, 2 * .pi, accuracy: 1e-9)
    }

    func testHiddenAndFreeSpaceStayOffTheColorRamp() {
        let t = tree()
        let slices = [DiskNode(name: "Hidden", kind: .hidden, size: 50), DiskNode(name: "Free", kind: .free, size: 50)]
        let tones = DiskTone.tones(of: t.root.children + slices)
        XCTAssertEqual(tones[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(tones[1], 0.8, accuracy: 1e-9)
        let top = Sunburst.arcs(focus: t.root, slices: slices, rings: 1, smallestAngle: 0.001)
        XCTAssertEqual(top[0].tone, 0.3, accuracy: 1e-9, "free space does not change the colors of the rest")
    }

    func testTooSmallArcsAreSummedUp() {
        let root = DiskNode(name: "r", kind: .folder, size: 1000, basePath: "/")
        root.add(file("big", 998))
        root.add(file("tiny", 1))
        root.add(file("tiny2", 1))
        let arcs = Sunburst.arcs(focus: root, rings: 1, smallestAngle: 0.1)
        XCTAssertEqual(arcs.count, 2)
        XCTAssertNil(arcs[1].node)
        XCTAssertEqual(arcs.last!.end, 2 * .pi, accuracy: 1e-9)
    }

    func testAnEmptyFolderHasNoWheel() {
        XCTAssertTrue(Sunburst.arcs(focus: DiskNode(name: "e", kind: .folder, basePath: "/e"), rings: 3, smallestAngle: 0.01).isEmpty)
    }

    func testArcLookup() {
        let t = tree()
        let arcs = Sunburst.arcs(focus: t.root, rings: 2, smallestAngle: 0.001)
        XCTAssertEqual(Sunburst.arc(in: arcs, ring: 0, angle: 0.5)?.node?.name, "a")
        XCTAssertEqual(Sunburst.arc(in: arcs, ring: 0, angle: 5)?.node?.name, "b")
        XCTAssertEqual(Sunburst.arc(in: arcs, ring: 1, angle: 0.5)?.node?.name, "a1")
        XCTAssertNil(Sunburst.arc(in: arcs, ring: 1, angle: 5), "b is a file: nothing around it")
    }

    // MARK: treemap

    func testSquarifyFillsTheRectangleExactly() {
        let rect = MapRect(x: 10, y: 20, width: 600, height: 400)
        let weights = [6.0, 6, 4, 3, 2, 2, 1].map { $0 * rect.area / 24 }
        let rects = Treemap.squarify(weights, in: rect)
        XCTAssertEqual(rects.count, weights.count)
        for (r, weight) in zip(rects, weights) {
            XCTAssertEqual(r.area, weight, accuracy: 1e-6)
            XCTAssertGreaterThanOrEqual(r.x, rect.x - 1e-6)
            XCTAssertGreaterThanOrEqual(r.y, rect.y - 1e-6)
            XCTAssertLessThanOrEqual(r.maxX, rect.maxX + 1e-6)
            XCTAssertLessThanOrEqual(r.maxY, rect.maxY + 1e-6)
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                let a = rects[i], b = rects[j]
                let overlapX = min(a.maxX, b.maxX) - max(a.x, b.x), overlapY = min(a.maxY, b.maxY) - max(a.y, b.y)
                XCTAssertFalse(overlapX > 1e-6 && overlapY > 1e-6, "tiles \(i) and \(j) overlap")
            }
        }
    }

    func testSquarifyKeepsTilesCloseToSquare() {
        let rect = MapRect(x: 0, y: 0, width: 900, height: 600)
        let weights = Array(repeating: rect.area / 36, count: 36)
        for r in Treemap.squarify(weights, in: rect) {
            XCTAssertLessThan(max(r.width / r.height, r.height / r.width), 2.5)
        }
    }

    func testTilesNestFoldersWithATitleStrip() {
        let t = tree()
        let tiles = Treemap.tiles(focus: t.root, in: MapRect(x: 0, y: 0, width: 800, height: 600))
        let group = tiles.first { $0.node === t.a }
        XCTAssertEqual(group?.isGroup, true)
        XCTAssertEqual(group?.headerHeight, 18)
        let inside = tiles.first { $0.node === t.a1 }
        XCTAssertEqual(inside?.depth, 1)
        XCTAssertEqual(inside?.tone ?? 0, 0.2, accuracy: 1e-9, "the same tone in both pictures")
        XCTAssertEqual(group?.tone ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(inside?.rect.y ?? 0, (group?.rect.y ?? 0) + 18)
        XCTAssertEqual(tiles.first { $0.node === t.b }?.isGroup, false)
    }

    func testAFolderHoldingOnlyOneFolderSpendsNoLevel() {
        let root = DiskNode(name: "r", kind: .folder, size: 100, basePath: "/")
        let app = DiskNode(name: "Big.app", kind: .folder, size: 100)
        let contents = DiskNode(name: "Contents", kind: .folder, size: 100)
        let frameworks = file("Frameworks", 70), resources = file("Resources", 30)
        root.add(app)
        app.add(contents)
        contents.add(frameworks)
        contents.add(resources)
        let tiles = Treemap.tiles(focus: root, in: MapRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(tiles.first { $0.node === contents }, "no block for Contents")
        XCTAssertEqual(tiles.first { $0.node === frameworks }?.depth, 1)
        XCTAssertEqual(tiles.first { $0.node === resources }?.depth, 1)
    }

    func testAGroupTooNarrowForItsTitleIsOneBlock() {
        let root = DiskNode(name: "r", kind: .folder, size: 1000, basePath: "/")
        let wide = DiskNode(name: "wide", kind: .folder, size: 960)
        let narrow = DiskNode(name: "narrow", kind: .folder, size: 40)
        root.add(wide)
        root.add(narrow)
        wide.add(file("w", 960))
        narrow.add(file("n", 40))
        let tiles = Treemap.tiles(focus: root, in: MapRect(x: 0, y: 0, width: 500, height: 300))
        XCTAssertEqual(tiles.first { $0.node === narrow }?.isGroup, false)
        XCTAssertEqual(tiles.first { $0.node === wide }?.isGroup, true)
    }

    func testHitTestingFindsTheDeepestTileAndTheGroupByItsTitle() {
        let t = tree()
        let tiles = Treemap.tiles(focus: t.root, in: MapRect(x: 0, y: 0, width: 800, height: 600))
        let group = tiles.first { $0.node === t.a }!
        let inner = tiles.first { $0.node === t.a1 }!
        XCTAssertTrue(Treemap.tile(in: tiles, x: inner.rect.x + 4, y: inner.rect.y + 4)?.node === t.a1)
        XCTAssertTrue(Treemap.tile(in: tiles, x: group.rect.x + 8, y: group.rect.y + 4)?.node === t.a)
    }

    func testTinyItemsBecomeOneBlock() {
        let root = DiskNode(name: "r", kind: .folder, size: 1_000_000, basePath: "/")
        root.add(file("big", 999_000))
        for index in 0..<100 { root.add(file("t\(index)", 10)) }
        let tiles = Treemap.tiles(focus: root, in: MapRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(tiles.filter { $0.node == nil }.count, 1)
        XCTAssertEqual(tiles.count, 2)
    }

    func testFreeSpaceIsABlockOfTheMap() {
        let t = tree()
        let free = DiskNode(name: "Free", kind: .free, size: 100)
        let tiles = Treemap.tiles(focus: t.root, slices: [free], in: MapRect(x: 0, y: 0, width: 800, height: 600))
        let tile = tiles.first { $0.node === free }
        XCTAssertNotNil(tile)
        XCTAssertEqual((tile?.rect.area ?? 0) / (800 * 600), 0.5, accuracy: 0.02)
    }

    func testTheGadgetNeedsNoPermissionToRun() {
        XCTAssertNil(ModuleID.diskMap.info.requiredPermission)
        XCTAssertEqual(ModuleID.diskMap.info.permissions.map { $0.permission }, [.fullDiskAccess])
        XCTAssertEqual(GadgetPermission.fullDiskAccess.tccService, "SystemPolicyAllFiles")
        XCTAssertEqual(GadgetPermission.fullDiskAccess.location(major: 15), "System Settings ▸ Privacy & Security ▸ Full Disk Access")
        XCTAssertEqual(GadgetActions.action("disk.show")?.module, .diskMap)
        XCTAssertFalse(ModuleID.diskMap.createsStatusItem)
    }

    func testPicturePreferencesAreKeptAndOlderSettingsLoad() throws {
        var options = GadgetOptions.defaults
        options.diskMapStyle = .blocks
        options.diskColoring = .age
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(GadgetOptions.self, from: data), options)
        let older = try JSONDecoder().decode(GadgetOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(older.diskMapStyle, .sunburst)
        XCTAssertEqual(older.diskColoring, .folder)
    }

    func testSampleDiskIsConsistent() {
        let sample = DiskSample.tree(now: now)
        XCTAssertEqual(sample.space.hidden(scanned: sample.root.size), Int64(19e9))
        XCTAssertGreaterThan(sample.space.free, 0)
        XCTAssertEqual(sample.root.children.first?.name, "Users")
    }
}

#if canImport(Darwin)
final class DiskScannerTests: XCTestCase {
    private var folder: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        folder = manager.temporaryDirectory.appendingPathComponent("diskscan-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try manager.removeItem(at: folder) }

    private func write(_ path: String, bytes: Int) throws {
        let url = folder.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func onDisk(_ path: String) throws -> Int64 {
        Int64(try folder.appendingPathComponent(path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0)
    }

    func testSizesMatchWhatTheDiskReports() throws {
        try write("a/one.bin", bytes: 3 << 20)
        try write("a/b/two.bin", bytes: 200_000)
        try write("three.bin", bytes: 100_000)
        let root = try XCTUnwrap(DiskScanner(path: folder.path).run())
        let expected = try onDisk("a/one.bin") + onDisk("a/b/two.bin") + onDisk("three.bin")
        XCTAssertEqual(root.size, expected)
        XCTAssertEqual(root.fileCount, 3)
        let a = try XCTUnwrap(root.children.first { $0.name == "a" })
        XCTAssertEqual(a.size, try onDisk("a/one.bin") + onDisk("a/b/two.bin"))
        XCTAssertEqual(a.path, root.path + "/a")
        XCTAssertEqual(root.descendant(at: root.path + "/a/one.bin")?.kind, .file)
        XCTAssertGreaterThan(root.modified, 0)
    }

    func testTinyFilesAreSummedAndNothingIsLost() throws {
        for index in 0..<50 { try write("many/f\(index)", bytes: 2000) }
        let root = try XCTUnwrap(DiskScanner(path: folder.path).run())
        XCTAssertEqual(root.fileCount, 50)
        let many = try XCTUnwrap(root.children.first { $0.name == "many" })
        let total = try (0..<50).reduce(Int64(0)) { $0 + (try onDisk("many/f\($1)")) }
        XCTAssertEqual(many.size, total)
    }

    func testSymbolicLinksAreNotFollowed() throws {
        try write("real/big.bin", bytes: 500_000)
        try manager.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder.appendingPathComponent("real"))
        let root = try XCTUnwrap(DiskScanner(path: folder.path).run())
        XCTAssertEqual(root.fileCount, 2, "the big file and the link itself")
        XCTAssertNil(root.children.first { $0.name == "link" && $0.isFolder })
    }

    func testAScanOfALinkRunsAtTheRealPlace() throws {
        try write("real/big.bin", bytes: 500_000)
        let link = folder.appendingPathComponent("link")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent("real"))
        let scanner = DiskScanner(path: link.path)
        let root = try XCTUnwrap(scanner.run())
        XCTAssertEqual(root.fileCount, 1)
        XCTAssertTrue(root.path.hasSuffix("/real"), "judged by where it really is: \(root.path)")
        XCTAssertFalse(root.path.hasSuffix("/link"))
    }

    func testALinkToAProtectedFolderIsJudgedByItsRealPath() throws {
        // /etc is a link to /private/etc on every Mac.
        let root = try XCTUnwrap(DiskScanner(path: "/etc").run())
        XCTAssertEqual(root.path, "/private/etc")
        XCTAssertTrue(DiskRemovalPolicy.verdict(path: root.path + "/hosts", home: "/Users/sam").isBlocked)
    }

    func testAHardLinkedFileCountsOnce() throws {
        try write("one/data.bin", bytes: 400_000)
        try manager.createDirectory(at: folder.appendingPathComponent("two"), withIntermediateDirectories: true)
        try manager.linkItem(at: folder.appendingPathComponent("one/data.bin"), to: folder.appendingPathComponent("two/again.bin"))
        let root = try XCTUnwrap(DiskScanner(path: folder.path).run())
        XCTAssertEqual(root.fileCount, 1)
        XCTAssertEqual(root.size, try onDisk("one/data.bin"))
    }

    func testAFolderThatCannotBeReadIsMarkedAndTheRestGoesOn() throws {
        try write("open/ok.bin", bytes: 100_000)
        try write("closed/secret.bin", bytes: 100_000)
        let closed = folder.appendingPathComponent("closed")
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: closed.path)
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }
        let scanner = DiskScanner(path: folder.path)
        let root = try XCTUnwrap(scanner.run())
        XCTAssertEqual(root.fileCount, 1)
        XCTAssertEqual(scanner.progress.unreadable, 1)
        XCTAssertEqual(root.children.first { $0.name == "closed" }?.isUnreadable, true)
    }

    func testAMissingFolderGivesNoResult() {
        XCTAssertNil(DiskScanner(path: folder.path + "/nope").run())
    }

    func testCancelGivesNoResult() throws {
        try write("a/b.bin", bytes: 1000)
        let scanner = DiskScanner(path: folder.path)
        scanner.cancel()
        XCTAssertNil(scanner.run())
    }

    func testSmallFoldersOfABigScanCollapseAndCanBeOpenedAgain() throws {
        // A big sparse-free file makes the 1 MiB floor irrelevant: the small folder stays below it in any case.
        try write("big/large.bin", bytes: 3 << 20)
        try write("tiny/deep/er/file.bin", bytes: 4000)
        let root = try XCTUnwrap(DiskScanner(path: folder.path).run())
        let tiny = try XCTUnwrap(root.children.first { $0.name == "tiny" })
        XCTAssertTrue(tiny.isCollapsed)
        XCTAssertTrue(tiny.children.isEmpty)
        XCTAssertEqual(tiny.fileCount, 1)
        let before = root.size
        let opened = try XCTUnwrap(DiskScanner(path: tiny.path, name: tiny.name).run())
        tiny.adopt(contentsOf: opened)
        XCTAssertFalse(tiny.isCollapsed)
        XCTAssertEqual(tiny.children.first?.name, "deep")
        XCTAssertEqual(root.size, before)
    }

    func testResultDoesNotDependOnTheNumberOfThreads() throws {
        for folderIndex in 0..<30 {
            for fileIndex in 0..<5 { try write("d\(folderIndex)/s/f\(fileIndex).bin", bytes: 70_000 + folderIndex * 100) }
        }
        let one = try XCTUnwrap(DiskScanner(path: folder.path, threads: 1).run())
        let many = try XCTUnwrap(DiskScanner(path: folder.path, threads: 8).run())
        XCTAssertEqual(one.size, many.size)
        XCTAssertEqual(one.fileCount, many.fileCount)
        XCTAssertEqual(one.children.count, many.children.count)
    }
}
#endif
