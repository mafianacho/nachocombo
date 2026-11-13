import XCTest
@testable import NachoComboCore

/// The chat bubble follows the pet, flips below it at the top of the screen, stays on the pet's screen, and keeps the
/// size the user dragged it to (saved, restored after a relaunch, reset to the default).
final class PetChatLayoutTests: XCTestCase {
    private let screen = PetRect(x: 0, y: 0, width: 1440, height: 875)
    private let pet = PetTokens.Size.pet
    private let def = PetChatLayout.defaultSize
    private let tail = PetTokens.Size.chatTail
    private let gap = PetTokens.Size.chatGapToPet
    private let margin = PetChatLayout.screenMargin

    private func petAt(_ x: Double, _ y: Double) -> PetRect { PetRect(x: x, y: y, width: pet, height: pet) }

    // MARK: follow

    func testAbovePetRightEdgesLinedUpTailOnPet() {
        let p = petAt(1200, 30)
        let at = PetChatLayout.place(body: def, pet: p, screen: screen)
        XCTAssertEqual(at.x, p.maxX - def.width)
        XCTAssertEqual(at.y, p.maxY + gap)
        XCTAssertFalse(at.tailOnTop)
        // The tail's tip is over the pet's centre.
        XCTAssertEqual(at.x + def.width - at.tailFromRight, p.midX)
    }

    func testFollowsADraggedPet() {
        let before = PetChatLayout.place(body: def, pet: petAt(1200, 30), screen: screen)
        let moved = petAt(700, 120)
        let after = PetChatLayout.place(body: def, pet: moved, screen: screen)
        XCTAssertEqual(after.x - before.x, 700 - 1200)
        XCTAssertEqual(after.y - before.y, 120 - 30)
        XCTAssertEqual(after.x + def.width - after.tailFromRight, moved.midX)
    }

    func testFlipsBelowThePetAtTheTopOfTheScreen() {
        let p = petAt(900, 700)
        let at = PetChatLayout.place(body: def, pet: p, screen: screen)
        XCTAssertTrue(at.tailOnTop)
        XCTAssertEqual(at.y, p.minY - (def.height + tail) - gap)
        XCTAssertEqual(at.x + def.width - at.tailFromRight, p.midX)
    }

    func testStaysOnThePetsScreen() {
        // Pet at the left edge: the chat cannot line up with its right edge, so it is pushed onto the screen and the
        // tail slides along the bottom edge to stay over the pet...
        let left = PetChatLayout.place(body: def, pet: petAt(0, 30), screen: screen)
        XCTAssertEqual(left.x, screen.minX + margin)
        XCTAssertEqual(left.x + def.width - left.tailFromRight, petAt(0, 30).midX)
        // ...but never past the rounded corner (pet half off the screen).
        let off = PetChatLayout.place(body: def, pet: petAt(-100, 30), screen: screen)
        XCTAssertEqual(off.tailFromRight, def.width - PetTokens.Radius.window - tail)
        // A second screen to the right (another monitor): clamped to that screen, not the first one.
        let second = PetRect(x: 1440, y: -200, width: 1920, height: 1080)
        let there = PetChatLayout.place(body: def, pet: PetRect(x: 3300, y: -180, width: pet, height: pet), screen: second)
        XCTAssertLessThanOrEqual(there.x + def.width, second.maxX - margin)
        XCTAssertGreaterThanOrEqual(there.x, second.minX + margin)
        XCTAssertGreaterThanOrEqual(there.y, second.minY + margin)
    }

    func testResizedChatStillFollowsAndPointsAtThePet() {
        let big = PetChatSize(width: 640, height: 700)
        let p = petAt(1200, 30)
        let at = PetChatLayout.place(body: big, pet: p, screen: screen)
        XCTAssertEqual(at.x, p.maxX - big.width)
        XCTAssertFalse(at.tailOnTop)
        XCTAssertEqual(at.x + big.width - at.tailFromRight, p.midX)
        XCTAssertEqual(at.bodyHeight, big.height)
        // Too tall for either side of a pet in the middle: the side with more room (below), shown as tall as that
        // room, tail up, still pointing at it, and never covering the pet.
        let mid = petAt(1000, 500)
        let flipped = PetChatLayout.place(body: big, pet: mid, screen: screen)
        XCTAssertTrue(flipped.tailOnTop)
        XCTAssertEqual(flipped.x + big.width - flipped.tailFromRight, mid.midX)
        XCTAssertEqual(flipped.bodyHeight, mid.minY - gap - margin - tail)
        XCTAssertLessThanOrEqual(flipped.y + flipped.bodyHeight + tail, mid.minY)
        XCTAssertEqual(flipped.y, screen.minY + margin)
        // More room above (pet low): above, shortened to the room above.
        let low = petAt(1200, 30)
        let tall = PetChatSize(width: 400, height: 860)
        let up = PetChatLayout.place(body: tall, pet: low, screen: screen)
        XCTAssertFalse(up.tailOnTop)
        XCTAssertEqual(up.y, low.maxY + gap)
        XCTAssertEqual(up.y + up.bodyHeight + tail, screen.maxY - margin)
        // A default chat that fits keeps the old rule exactly (no shortening).
        XCTAssertEqual(PetChatLayout.place(body: def, pet: petAt(900, 700), screen: screen).bodyHeight, def.height)
    }

    // MARK: size

    func testClampKeepsTheBodyBetweenMinimumAndScreen() {
        XCTAssertEqual(PetChatLayout.clamp(nil, screen: screen), def)
        XCTAssertEqual(PetChatLayout.clamp(PetChatSize(width: 10, height: 10), screen: screen), PetChatLayout.minimumSize)
        let huge = PetChatLayout.clamp(PetChatSize(width: 9999, height: 9999), screen: screen)
        XCTAssertEqual(huge, PetChatSize(width: screen.width - 2 * margin, height: screen.height - 2 * margin - tail))
        XCTAssertEqual(PetChatLayout.clamp(PetChatSize(width: .nan, height: 500), screen: screen), def)
        XCTAssertEqual(PetChatLayout.clamp(PetChatSize(width: 500.4, height: 600.6), screen: nil), PetChatSize(width: 500, height: 601))
        // The default fits the minimum: the design's size is a valid size.
        XCTAssertLessThanOrEqual(PetChatLayout.minimumSize.width, def.width)
        XCTAssertLessThanOrEqual(PetChatLayout.minimumSize.height, def.height)
    }

    func testDraggingTheFreeEdges() {
        XCTAssertEqual(PetChatLayout.resizableEdges(tailOnTop: false), [.left, .top, .topLeft])
        XCTAssertEqual(PetChatLayout.resizableEdges(tailOnTop: true), [.left, .bottom, .bottomLeft])
        let limit = PetChatSize(width: 2000, height: 2000)
        // Left edge to the left = wider; top edge up = taller; bottom edge down = taller (AppKit y grows upward).
        XCTAssertEqual(PetChatLayout.resized(def, edge: .left, dx: -100, dy: 50, limit: limit), PetChatSize(width: 460, height: 520))
        XCTAssertEqual(PetChatLayout.resized(def, edge: .top, dx: -100, dy: 80, limit: limit), PetChatSize(width: 360, height: 600))
        XCTAssertEqual(PetChatLayout.resized(def, edge: .bottom, dx: 0, dy: -80, limit: limit), PetChatSize(width: 360, height: 600))
        XCTAssertEqual(PetChatLayout.resized(def, edge: .topLeft, dx: -40, dy: -60, limit: limit), PetChatSize(width: 400, height: 460))
        XCTAssertEqual(PetChatLayout.resized(def, edge: .bottomLeft, dx: 500, dy: 500, limit: limit), PetChatLayout.minimumSize)
    }

    func testDragStopsAtTheScreenOnThePetsSide() {
        let p = petAt(1200, 30)
        let limit = PetChatLayout.dragLimit(pet: p, screen: screen, tailOnTop: false)
        XCTAssertEqual(limit.height, screen.maxY - margin - (p.maxY + gap) - tail)
        let grown = PetChatLayout.resized(def, edge: .topLeft, dx: -5000, dy: 5000, limit: limit)
        XCTAssertEqual(grown.width, screen.width - 2 * margin)
        // At the limit the chat still fits above the pet: it does not flip in the middle of the drag.
        let at = PetChatLayout.place(body: grown, pet: p, screen: screen)
        XCTAssertFalse(at.tailOnTop)
        XCTAssertLessThanOrEqual(at.y + grown.height + tail, screen.maxY - margin)
        // Below the pet: the room under it.
        let high = petAt(900, 700)
        XCTAssertEqual(PetChatLayout.dragLimit(pet: high, screen: screen, tailOnTop: true).height, high.minY - gap - tail - margin)
        // Never below the minimum, even with no room.
        XCTAssertEqual(PetChatLayout.dragLimit(pet: petAt(900, 760), screen: screen, tailOnTop: false).height, PetChatLayout.minimumSize.height)
    }

    func testDefaultIsNotSaved() {
        XCTAssertNil(PetChatLayout.saved(def))
        XCTAssertEqual(PetChatLayout.saved(PetChatSize(width: 500, height: 600)), PetChatSize(width: 500, height: 600))
    }

    // MARK: saved and restored (relaunch)

    private var dir: URL!
    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pet-chat-layout-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Written against the settings file only (no new API), so it ran RED before the chat size was a setting:
    /// a resized chat must come back at the same size after the app is quit and opened again.
    func testSavedChatSizeSurvivesARelaunch() throws {
        let file = dir.appendingPathComponent("pet.json")
        try Data(#"{"serverMode":"production","chatSize":{"width":520,"height":640}}"#.utf8).write(to: file)
        let first = PetSettingsStore(url: file)
        try first.save(first.load())  // the app saves its settings on the next change
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let size = try XCTUnwrap(json["chatSize"] as? [String: Any], "the chat size was dropped on load or save")
        XCTAssertEqual(size["width"] as? Double, 520)
        XCTAssertEqual(size["height"] as? Double, 640)
    }

    func testChatSizeSettingRoundTripAndSanitize() throws {
        let file = dir.appendingPathComponent("pet.json")
        let store = PetSettingsStore(url: file)
        var s = PetSettings()
        XCTAssertNil(s.chatSize)
        s.chatSize = PetChatSize(width: 480, height: 600)
        try store.save(s)
        XCTAssertEqual(PetSettingsStore(url: file).load().chatSize, PetChatSize(width: 480, height: 600))
        // A hand-edited file cannot make it tiny, absurd or not a number; old files without the key load as default.
        s.chatSize = PetChatSize(width: 5, height: 5)
        XCTAssertEqual(PetSettingsStore.sanitized(s).chatSize, PetChatLayout.minimumSize)
        s.chatSize = PetChatSize(width: 1e9, height: 600)
        XCTAssertNil(PetSettingsStore.sanitized(s).chatSize)
        s.chatSize = PetChatSize(width: .infinity, height: 600)
        XCTAssertNil(PetSettingsStore.sanitized(s).chatSize)
        try Data(#"{"serverMode":"production","chatSize":"big"}"#.utf8).write(to: file)
        let loaded = PetSettingsStore(url: file).load()
        XCTAssertNil(loaded.chatSize)
        XCTAssertEqual(loaded.serverMode, .production)
    }
}
