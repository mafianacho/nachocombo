import XCTest
@testable import NachoComboCore

/// NACHO-300: 업데이트 후 처음 실행할 때만 「새로운 기능」 창을 보여 줄지 판단하는 규칙.
final class WhatsNewGateTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "whatsnew-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func content(_ version: String = "0.11.0") -> WhatsNewContent {
        WhatsNewContent(version: version, items: [WhatsNewItem(title: "나초 앱 창", body: "한 줄 설명", gif: "a.gif")])
    }

    // MARK: 판단

    func testFreshInstallShowsNothingAndStoresCurrent() {
        let o = WhatsNewGate.decide(lastSeen: nil, current: "0.11.0", hasContent: true)
        XCTAssertFalse(o.show)
        XCTAssertEqual(o.store, "0.11.0")
    }

    /// 0.10.x 사용자는 이 키가 생기기 전 버전이라 저장 값이 없다. 설정 파일이 이미 있으면(신규 설치 아님) 업데이트로 본다.
    func testExistingInstallWithoutStoredValueIsAnUpdate() {
        let o = WhatsNewGate.decide(lastSeen: nil, current: "0.11.0", hasContent: true, freshInstall: false)
        XCTAssertTrue(o.show)
        XCTAssertEqual(o.store, "0.11.0")
    }

    func testFreshInstallFlagStillHidesWithoutStoredValue() {
        let o = WhatsNewGate.decide(lastSeen: nil, current: "0.11.0", hasContent: true, freshInstall: true)
        XCTAssertFalse(o.show)
        XCTAssertEqual(o.store, "0.11.0")
    }

    func testTrackerExistingInstallWithoutStoredValueShowsOnce() {
        let d = defaults()
        let tracker = WhatsNewTracker(defaults: d)
        XCTAssertEqual(tracker.evaluate(current: "0.11.0", content: content(), freshInstall: false), content())
        XCTAssertEqual(d.string(forKey: WhatsNewGate.defaultsKey), "0.11.0")
        XCTAssertNil(tracker.evaluate(current: "0.11.0", content: content(), freshInstall: false), "두 번째 실행에는 보여 주지 않는다")
    }

    func testUpdateWithContentShowsOnceAndStores() {
        let o = WhatsNewGate.decide(lastSeen: "0.10.0", current: "0.11.0", hasContent: true)
        XCTAssertTrue(o.show)
        XCTAssertEqual(o.store, "0.11.0")
    }

    func testSameVersionShowsNothing() {
        let o = WhatsNewGate.decide(lastSeen: "0.11.0", current: "0.11.0", hasContent: true)
        XCTAssertFalse(o.show)
        XCTAssertNil(o.store)
    }

    func testDowngradeShowsNothingAndKeepsStored() {
        let o = WhatsNewGate.decide(lastSeen: "0.12.0", current: "0.11.0", hasContent: true)
        XCTAssertFalse(o.show)
        XCTAssertNil(o.store)
    }

    func testUpdateWithoutContentStoresButShowsNothing() {
        let o = WhatsNewGate.decide(lastSeen: "0.10.0", current: "0.11.0", hasContent: false)
        XCTAssertFalse(o.show)
        XCTAssertEqual(o.store, "0.11.0")
    }

    func testNumericVersionComparison() {
        XCTAssertTrue(WhatsNewGate.decide(lastSeen: "0.9.0", current: "0.10.0", hasContent: true).show)
        XCTAssertTrue(WhatsNewGate.decide(lastSeen: "0.10.0", current: "0.11.0", hasContent: true).show)
        XCTAssertFalse(WhatsNewGate.decide(lastSeen: "0.10.0", current: "0.9.0", hasContent: true).show)
    }

    func testUnreadableStoredValueActsLikeFreshInstall() {
        let o = WhatsNewGate.decide(lastSeen: "banana", current: "0.11.0", hasContent: true)
        XCTAssertFalse(o.show)
        XCTAssertEqual(o.store, "0.11.0")
    }

    func testUnreadableCurrentVersionTouchesNothing() {
        let o = WhatsNewGate.decide(lastSeen: "0.10.0", current: "dev", hasContent: true)
        XCTAssertFalse(o.show)
        XCTAssertNil(o.store)
    }

    // MARK: 저장 값 (UserDefaults 키 하나)

    func testTrackerStoresUnderOneKeyAndShowsOnlyOnce() {
        let d = defaults()
        d.set("0.10.0", forKey: WhatsNewGate.defaultsKey)
        let tracker = WhatsNewTracker(defaults: d)
        XCTAssertEqual(tracker.evaluate(current: "0.11.0", content: content()), content())
        XCTAssertEqual(d.string(forKey: WhatsNewGate.defaultsKey), "0.11.0")
        XCTAssertNil(tracker.evaluate(current: "0.11.0", content: content()), "두 번째 실행에는 보여 주지 않는다")
    }

    func testTrackerFreshInstallStoresWithoutShowing() {
        let d = defaults()
        let tracker = WhatsNewTracker(defaults: d)
        XCTAssertNil(tracker.evaluate(current: "0.11.0", content: content()))
        XCTAssertEqual(d.string(forKey: WhatsNewGate.defaultsKey), "0.11.0")
    }

    func testTrackerMissingFileStoresWithoutShowing() {
        let d = defaults()
        d.set("0.10.0", forKey: WhatsNewGate.defaultsKey)
        XCTAssertNil(WhatsNewTracker(defaults: d).evaluate(current: "0.11.0", content: nil))
        XCTAssertEqual(d.string(forKey: WhatsNewGate.defaultsKey), "0.11.0")
    }

    func testTrackerIgnoresContentOfAnotherVersion() {
        let d = defaults()
        d.set("0.10.0", forKey: WhatsNewGate.defaultsKey)
        XCTAssertNil(WhatsNewTracker(defaults: d).evaluate(current: "0.11.0", content: content("0.10.0")))
    }

    func testTrackerDowngradeKeepsStoredValue() {
        let d = defaults()
        d.set("0.12.0", forKey: WhatsNewGate.defaultsKey)
        XCTAssertNil(WhatsNewTracker(defaults: d).evaluate(current: "0.11.0", content: content()))
        XCTAssertEqual(d.string(forKey: WhatsNewGate.defaultsKey), "0.12.0")
    }

    // MARK: 내용 파일

    func testParsesContentFile() throws {
        let json = #"{"version":"0.11.0","items":[{"title":"나초 앱 창","body":"한 줄","gif":"app.gif"},{"title":"기억","body":"둘째"}]}"#
        let c = try XCTUnwrap(WhatsNewContent.parse(Data(json.utf8)))
        XCTAssertEqual(c.version, "0.11.0")
        XCTAssertEqual(c.items.map { $0.title }, ["나초 앱 창", "기억"])
        XCTAssertEqual(c.items[0].gif, "app.gif")
        XCTAssertNil(c.items[1].gif)
    }

    func testBrokenJSONGivesNil() {
        XCTAssertNil(WhatsNewContent.parse(Data("{not json".utf8)))
        XCTAssertNil(WhatsNewContent.parse(Data()))
    }

    func testEmptyItemsOrBlankTitleGivesNil() {
        XCTAssertNil(WhatsNewContent.parse(Data(#"{"version":"0.11.0","items":[]}"#.utf8)))
        XCTAssertNil(WhatsNewContent.parse(Data(#"{"version":"0.11.0","items":[{"title":" ","body":"x"}]}"#.utf8)))
    }

    func testGifNameCannotEscapeTheFolder() {
        let json = #"{"version":"0.11.0","items":[{"title":"a","body":"b","gif":"../secret.gif"}]}"#
        XCTAssertNil(WhatsNewContent.parse(Data(json.utf8))?.items.first?.gif)
    }
}
