import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-300: 「새로운 기능」 창을 라이트·다크로 그리고(첫 장·가운데 장·마지막 장·닫기), 번들 GIF의 장면 프레임을
/// 나초 앱 창(허브)에서 뽑는다. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다. 데이터는 모두 가짜다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 로그(BENTO-CAPTURE 줄)로 CI에 남긴다.
final class WhatsNewCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL { HubU9.outDir() }

    // MARK: 창

    private var repoWhatsNew: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/WhatsNew")
    }

    private func bundledContent() throws -> WhatsNewContent {
        let data = try Data(contentsOf: repoWhatsNew.appendingPathComponent("0.11.0.json"))
        return try XCTUnwrap(WhatsNewContent.parse(data), "Resources/WhatsNew/0.11.0.json은 읽혀야 한다")
    }

    func testBundledFileIsValidAndGifsAreSmall() throws {
        let c = try bundledContent()
        XCTAssertEqual(c.version, "0.11.0")
        XCTAssertTrue((3...5).contains(c.items.count))
        for item in c.items {
            XCTAssertFalse(item.body.contains("\n"), "설명은 한 줄")
            let name = try XCTUnwrap(item.gif)
            let size = try FileManager.default.attributesOfItem(atPath: repoWhatsNew.appendingPathComponent(name).path)[.size] as? Int ?? 0
            XCTAssertGreaterThan(size, 1_000, name)
            XCTAssertLessThanOrEqual(size, 1_500_000, "\(name) 장당 1.5MB 이하")
        }
    }

    func testWindowPagesInLightAndDark() throws {
        let content = try bundledContent()
        let window = WhatsNewWindow(content: content) { [repoWhatsNew] in repoWhatsNew.appendingPathComponent($0) }
        var closed = 0
        window.onClose = { closed += 1 }
        XCTAssertEqual(window.index, 0)
        let mid = content.items.count / 2
        let steps: [(String, Int)] = [("first", 0), ("middle", mid), ("last", content.items.count - 1)]
        for (name, i) in steps {
            window.show(i)
            XCTAssertTrue(HubU9.joined(window).contains(content.items[i].title), "\(name): 제목")
            XCTAssertTrue(HubU9.joined(window).contains("\(i + 1) / \(content.items.count)"), "\(name): 쪽 표시")
            for dark in [false, true] { try snap(window, dark: dark, name: "whatsnew-\(name)") }
        }
        XCTAssertTrue(HubU9.joined(window).contains("닫기"), "마지막 장의 단추는 닫기")
        window.go(1)
        XCTAssertEqual(closed, 1, "마지막 장에서 닫기를 누르면 닫힌다")
        XCTAssertFalse(window.isVisible)
    }

    func testPrevNextBounds() throws {
        let content = try bundledContent()
        let window = WhatsNewWindow(content: content) { _ in nil }
        window.go(-1)
        XCTAssertEqual(window.index, 0)
        window.go(1)
        XCTAssertEqual(window.index, 1)
        window.go(-1)
        XCTAssertEqual(window.index, 0)
    }

    func testMissingGifStillShowsText() {
        let content = WhatsNewContent(version: "0.11.0", items: [WhatsNewItem(title: "제목", body: "설명", gif: "none.gif")])
        let window = WhatsNewWindow(content: content) { _ in nil }
        XCTAssertTrue(HubU9.joined(window).contains("제목"))
    }

    func testPresenterWithoutFileShowsNothing() {
        let presenter = WhatsNewPresenter(bundle: Bundle(for: WhatsNewCaptureTests.self))
        XCTAssertNil(presenter.loadContent())
        XCTAssertFalse(presenter.isAvailable)
        presenter.showAgain()   // 창도 오류도 없다
        presenter.showIfUpdated(tracker: WhatsNewTracker(defaults: UserDefaults(suiteName: "whatsnew-none-\(UUID().uuidString)")!))
    }

    private func snap(_ window: NSWindow, dark: Bool, name: String) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        try emit(try XCTUnwrap(rep.representation(using: .png, properties: [:])), name: "\(name)-\(dark ? "dark" : "light")")
    }

    // MARK: GIF 프레임 (나초 앱 창 장면)

    private func fact(_ id: String, _ text: String, _ cat: String, _ inferred: Bool, seen: Bool) -> String {
        "{\"id\":\"\(id)\",\"text\":\"\(text)\",\"category\":\"\(cat)\",\"visibility\":\"shared\",\"source_type\":\"\(inferred ? "inferred" : "user")\",\"inferred\":\(inferred),\"edited_by_user\":false,\"version\":3,\"created_at\":\"2026-11-03T01:00:00Z\""
            + (seen ? ",\"seen_at\":\"2026-11-04T01:00:00Z\"" : "") + "}"
    }

    private func notification(_ id: String, _ title: String, _ body: String, read: Bool, at: String) -> String {
        "{\"id\":\"\(id)\",\"user_id\":\"u\",\"kind\":\"task_done\",\"title\":\"\(title)\",\"body\":\"\(body)\",\"data\":{},"
            + "\"read_at\":\(read ? "\"2026-11-15T10:00:00Z\"" : "null"),\"created_at\":\"\(at)\"}"
    }

    private func fakeHTTP() -> HubFakeHTTP {
        HubFakeHTTP { [self] r in
            switch r.method + " " + r.url.path {
            case "GET /api/v1/memory/facts":
                return (200, "{\"facts\":[" + fact("f1", "커피는 라떼를 좋아해요", "favorites", false, seen: true) + ","
                    + fact("f2", "아침에 산책을 해요", "rhythm", true, seen: false) + ","
                    + fact("f3", "동생 이름은 하나예요", "people", false, seen: true) + "],\"unseen_count\":1,\"has_more\":false}", [:])
            case "GET /api/v1/memory/episodes":
                return (200, "{\"sections\":[],\"month\":\"2026-11\",\"day_counts\":[]}", [:])
            case "GET /api/v1/me/memory-settings":
                return (200, "{\"memory_paused\":false,\"memory_indicator_enabled\":true}", [:])
            case "GET /api/v1/me/notifications":
                return (200, "[" + notification("n1", "작업이 끝났어요", "가짜 주간 보고서 정리", read: false, at: "2026-11-15T09:00:00Z") + ","
                    + notification("n2", "예약 작업을 실행했어요", "가짜 아침 요약", read: true, at: "2026-11-14T08:00:00Z") + "]", [:])
            case "GET /api/v1/activity":
                return (200, "{\"sections\":[{\"key\":\"2026-11-15\",\"date_label\":\"오늘\",\"items\":[{\"id\":\"a1\",\"kind\":\"friend_request\",\"created_at_ms\":1,\"time_label\":\"14:05\",\"unread\":true,\"actor\":{\"user_id\":\"u1\",\"actor_kind\":\"person\",\"display_name\":\"가짜친구\"},\"action\":\"accept_decline\"}]}],\"activity_unread_count\":1}", [:])
            case "POST /api/v1/activity/seen":
                return (200, "{\"ok\":true,\"seen_at\":\"2026-11-15T10:00:00Z\",\"activity_unread_count\":0}", [:])
            case "GET /api/v1/me/notification-settings":
                return (200, "{\"all_enabled\":true,\"items\":{},\"muted_agent_ids\":[]}", [:])
            default:
                return (200, "{}", [:])
            }
        }
    }

    private func frame(_ w: PetHubWindow, _ name: String) throws {
        HubU9.pump(0.2)
        try HubU9.capture(w, dark: false, name: "gifframe-\(name)")
    }

    func testGifFramesFromTheAppWindow() throws {
        // 1. 나초 앱 창: 사이드바를 따라 섹션이 바뀐다.
        let w1 = HubU9.window(.memory, http: fakeHTTP())
        try frame(w1, "app-1")
        w1.select(.notifications)
        try frame(w1, "app-2")
        w1.select(.memory)
        try frame(w1, "app-3")

        // 2. 기억 관리: 목록 → 자세히 → 고치기.
        let w2 = HubU9.window(.memory, http: fakeHTTP())
        let memory = try XCTUnwrap(w2.currentSection as? MemorySection)
        try frame(w2, "memory-1")
        memory.showFact(memory.facts[1])
        try frame(w2, "memory-2")
        memory.showFactForm(editing: memory.facts[0])
        try frame(w2, "memory-3")

        // 3. 알림: 알림 목록 → 활동 탭.
        let w3 = HubU9.window(.notifications, http: fakeHTTP())
        let notifications = try XCTUnwrap(w3.currentSection as? NotificationsSection)
        try frame(w3, "notify-1")
        notifications.select(.activity)
        try frame(w3, "notify-2")
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        var idx = b64.startIndex
        var i = 0
        let n = (b64.count + chunk - 1) / chunk
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 3_000, "\(name) is not empty")
    }
}
