import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 나초 앱 창(허브, NACHO-266 U0)을 가짜 HTTP로 장면별·라이트/다크로 그린다. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다.
/// 그림은 .build/bento-captures에 쓰고, base64 조각은 테스트 로그(BENTO-CAPTURE 줄)로 CI에 남긴다. 데이터는 모두 가짜다.
final class HubWindowCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private enum Reply { case usage, serverError, hang }

    private final class FakeHTTP: PetHTTPClient {
        let reply: Reply
        var paths: [String] = []
        init(_ r: Reply) { reply = r }
        func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
            paths.append(request.method + " " + request.url.path)
            switch reply {
            case .hang: return
            case .serverError:
                completion(.success(PetHTTPResponse(status: 500, body: Data("{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}".utf8))))
            case .usage:
                let body = "{\"plan_id\":\"free\",\"period\":\"week\",\"allowance\":300,\"remaining\":120,\"reset_at\":\"2026-11-20T00:00:00Z\","
                    + "\"exhausted\":false,\"low_balance\":false,\"limits\":[{\"kind\":\"light_chat\",\"used\":12,\"cap\":50}]}"
                completion(.success(PetHTTPResponse(status: 200, body: Data(body.utf8))))
            }
        }
    }

    private func makeWindow(signedIn: Bool, reply: Reply, section: HubSectionID) -> (PetHubWindow, FakeHTTP) {
        let http = FakeHTTP(reply)
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let client = HubClient(endpoint: endpoint, http: http, tokens: { _, done in done("fake-token") })
        let env = HubEnvironment(isSignedIn: { signedIn }, client: { signedIn ? client : nil }, signIn: {})
        return (PetHubWindow(env: env, autosaveName: nil, initial: section), http)
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    private func capture(_ window: PetHubWindow, dark: Bool, name: String) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(PetHubWindow.defaultSize)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        try snapshot(root, dark: dark, name: name)
    }

    private func snapshot(_ root: NSView, dark: Bool, name: String) throws {
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try emit(png, name: "hub-\(name)-\(dark ? "dark" : "light")")
    }

    // MARK: scenes

    func testSidebarListsAllThirteenSectionsInOrder() throws {
        let (w, _) = makeWindow(signedIn: true, reply: .usage, section: .usage)
        let all = texts(try XCTUnwrap(w.contentView))
        let titles = HubSectionID.allCases.map { $0.title }
        XCTAssertEqual(titles.count, 13)
        var last = -1
        for t in titles {
            let i = try XCTUnwrap(all.firstIndex(of: t), "\(t) is in the sidebar")
            XCTAssertGreaterThan(i, last, "\(t) keeps its place")
            last = i
        }
        XCTAssertEqual(HubSections.factories.map { $0.0 }, HubSectionID.allCases, "one factory per section, same order")
    }

    func testEveryPlaceholderSectionSaysComingSoon() throws {
        // 자리만 있는 섹션만 본다. 섹션을 구현하는 PR은 이 집합에 자기 id를 한 줄로 더한다.
        let implemented: Set<HubSectionID> = [.usage, .groups, .tasks, .schedules, .trust, .explore, .archive, .notifications, .account, .nachos, .friends, .memory, .rooms]
        for id in HubSectionID.allCases where !implemented.contains(id) {
            let (w, http) = makeWindow(signedIn: true, reply: .usage, section: id)
            XCTAssertTrue(texts(try XCTUnwrap(w.contentView)).contains("준비 중이에요."), "\(id) shows the placeholder")
            XCTAssertTrue(http.paths.isEmpty, "\(id) asks nothing")
        }
    }

    func testSignedOutShowsLoginNoticeAndAsksNothing() throws {
        let (w, http) = makeWindow(signedIn: false, reply: .usage, section: .usage)
        let all = texts(try XCTUnwrap(w.contentView)).joined(separator: "\n")
        XCTAssertTrue(all.contains("나초 계정으로 로그인해 주세요"), all)
        XCTAssertFalse(all.contains("남은 크레딧"))
        XCTAssertTrue(http.paths.isEmpty)
        for dark in [false, true] { try capture(w, dark: dark, name: "signed-out") }
    }

    func testUsageShowsServerNumbersThroughHubAPI() throws {
        let (w, http) = makeWindow(signedIn: true, reply: .usage, section: .usage)
        XCTAssertEqual(http.paths, ["GET /api/v1/me/usage"])
        let all = texts(try XCTUnwrap(w.contentView)).joined(separator: "\n")
        XCTAssertTrue(all.contains("120 / 300"), all)
        XCTAssertTrue(all.contains("가벼운 대화"), all)
        for dark in [false, true] { try capture(w, dark: dark, name: "window-usage") }
    }

    func testUsageErrorShowsKoreanTextAndRetry() throws {
        let (w, _) = makeWindow(signedIn: true, reply: .serverError, section: .usage)
        let all = texts(try XCTUnwrap(w.contentView)).joined(separator: "\n")
        XCTAssertTrue(all.contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."), all)
        XCTAssertTrue(all.contains("다시 시도"), all)
        for dark in [false, true] { try capture(w, dark: dark, name: "usage-error") }
    }

    func testUsageLoadingState() throws {
        let (w, _) = makeWindow(signedIn: true, reply: .hang, section: .usage)
        XCTAssertTrue(texts(try XCTUnwrap(w.contentView)).contains("불러오는 중…"))
        for dark in [false, true] { try capture(w, dark: dark, name: "usage-loading") }
    }

    func testDoubleConfirmCardsAndToast() throws {
        let steps = [
            HubConfirmStep(title: "이 예약을 지울까요?", message: "지우면 다시 돌릴 수 없어요. 다음 실행 3건도 함께 사라져요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "한 번 더 확인해요. 되돌릴 수 없어요.", confirmTitle: "지우기"),
        ]
        for dark in [false, true] {
            for (i, step) in steps.enumerated() {
                let card = HubConfirmCard(step: step, onCancel: {}, onConfirm: {})
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 220))
                host.wantsLayer = true
                host.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)).cgColor
                host.addSubview(card)
                NSLayoutConstraint.activate([card.centerXAnchor.constraint(equalTo: host.centerXAnchor), card.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                w.contentView = host
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(texts(card).contains(step.title))
                try snapshot(host, dark: dark, name: "confirm\(i + 1)")
            }
        }
    }

    func testFormFieldValidationShowsKoreanProblem() {
        let f = HubFormField(title: "이름", validator: HubFormField.nonEmpty("이름", maxLength: 5))
        XCTAssertFalse(f.validate())
        XCTAssertTrue(texts(f).contains("이름을(를) 입력해 주세요."))
        f.field.stringValue = "여섯글자넘어요"
        XCTAssertFalse(f.validate())
        XCTAssertTrue(texts(f).contains("이름은(는) 5자까지 쓸 수 있어요."))
        f.field.stringValue = "나초"
        XCTAssertTrue(f.validate())
    }

    func testPlaceholderFilesDoNotFetch() {
        // 자리 섹션은 서버를 부르지 않는다(위 시험) — 여기서는 자리 파일마다 클래스가 있는지만 본다.
        for id in HubSectionID.allCases { XCTAssertEqual(HubSections.make(id).id, id) }
    }

    private func emit(_ png: Data, name: String) throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(name) is not empty")
    }
}
