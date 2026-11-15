import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// NACHO-264 U9 섹션 캡처 시험의 공용 도구. 가짜 HTTP로 장면을 그리고(macOS CI 오프스크린 렌더, 실제 Mac 화면이 아니다),
/// 그림은 .build/bento-captures에 쓰고 base64 조각은 로그(BENTO-CAPTURE 줄)로 남긴다. 데이터는 모두 가짜다.
final class HubFakeHTTP: PetHTTPClient {
    var route: (PetHTTPRequest) -> (Int, String, [String: String])
    private(set) var log: [PetHTTPRequest] = []
    init(_ route: @escaping (PetHTTPRequest) -> (Int, String, [String: String])) { self.route = route }
    func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
        log.append(request)
        let (status, body, headers) = route(request)
        completion(.success(PetHTTPResponse(status: status, headers: headers, body: Data(body.utf8))))
    }
    var lines: [String] { log.map { r in r.method + " " + r.url.path + (r.url.query.map { "?" + $0 } ?? "") } }
    func bodies(_ method: String, _ path: String) -> [String] {
        log.filter { $0.method == method && $0.url.path == path }.map { String(data: $0.body ?? Data(), encoding: .utf8) ?? "" }
    }
}

enum HubU9 {
    static func window(_ section: HubSectionID, http: HubFakeHTTP, tokens: HubTokenProvider? = nil) -> PetHubWindow {
        _ = NSApplication.shared
        let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
        let provider: HubTokenProvider = tokens ?? { _, done in done("fake-token") }
        let env = HubEnvironment(isSignedIn: { true }, client: { HubClient(endpoint: endpoint, http: http, tokens: provider) }, signIn: {})
        return PetHubWindow(env: env, autosaveName: nil, initial: section)
    }

    /// 메인 큐로 돌아오는 결과를 기다린다.
    static func pump(_ seconds: Double = 0.25) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    static func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        if let s = v as? NSSegmentedControl { for i in 0..<s.segmentCount { out.append(s.label(forSegment: i) ?? "") } }
        for s in v.subviews where !s.isHidden { out += texts(s) }
        return out
    }

    static func joined(_ w: NSWindow) -> String { texts(w.contentView!).joined(separator: "\n") }

    static func find<T: NSView>(_ type: T.Type, in v: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let t = v as? T, match(t) { return t }
        for s in v.subviews where !s.isHidden { if let f = find(type, in: s, where: match) { return f } }
        return nil
    }

    /// 제목이 같은 단추(PetPill) 하나를 눌러 본다.
    @discardableResult
    static func tap(_ title: String, in v: NSView) -> Bool {
        guard let p = find(PetPill.self, in: v, where: { pill in texts(pill).contains(title) }) else { return false }
        p.onClick?()
        return true
    }

    static func tapRow(_ title: String, in v: NSView) -> Bool {
        guard let r = find(HubRow.self, in: v, where: { row in texts(row).contains(title) }) else { return false }
        r.onClick?()
        return true
    }

    static func outDir() -> URL { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures") }

    static func capture(_ window: PetHubWindow, dark: Bool, name: String, size: NSSize = PetHubWindow.defaultSize) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outDir(), withIntermediateDirectories: true)
        let label = "hub-\(name)-\(dark ? "dark" : "light")"
        try png.write(to: outDir().appendingPathComponent("\(label).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(label) \(i + 1)/\(n) \(b64[idx..<end]) .")
            fflush(stdout)
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 5_000, "\(label) is not empty")
    }

    /// 라이트·다크 둘 다, 기본 크기와 가장 좁은 크기로 담는다.
    static func captureAll(_ window: PetHubWindow, name: String) throws {
        for dark in [false, true] {
            try capture(window, dark: dark, name: name)
            try capture(window, dark: dark, name: name + "-narrow", size: PetHubWindow.minimumSize)
        }
    }

    static func json(_ s: String) -> (Int, String, [String: String]) { (200, s, [:]) }
    static func err(_ status: Int, _ code: String, reason: String? = nil) -> (Int, String, [String: String]) {
        (status, "{\"error\":{\"code\":\"\(code)\",\"message\":\"x\"" + (reason.map { ",\"reason\":\"\($0)\"" } ?? "") + "}}", [:])
    }
}
