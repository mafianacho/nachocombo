import XCTest
@testable import NachoComboCore

/// 라이브 뷰 URL 허용 규칙 (NACHO-271 C4). 서버가 준 보기 주소 중 https이고 서버 호스트 또는 나초딥 뷰어 호스트(443)인 것만 연다.
final class HubTasksLiveViewTests: XCTestCase {
    private let host = "nacho.example.com"

    func testAllowsHttpsServerHost() {
        let u = HubLiveView.allowedURL("https://nacho.example.com/api/v1/remote/viewer#t=vt_x", serverHost: host)
        XCTAssertEqual(u?.host, "nacho.example.com")
        XCTAssertEqual(u?.fragment, "t=vt_x")
        XCTAssertNotNil(HubLiveView.allowedURL("https://NACHO.example.com/v", serverHost: host), "호스트 대소문자는 가리지 않는다")
    }

    func testRejectsHttp() {
        XCTAssertNil(HubLiveView.allowedURL("http://nacho.example.com/api/v1/remote/viewer#t=x", serverHost: host))
    }

    func testRejectsOtherHosts() {
        XCTAssertNil(HubLiveView.allowedURL("https://evil.example.org/viewer#t=x", serverHost: host))
        XCTAssertNil(HubLiveView.allowedURL("https://nacho.example.com.evil.org/viewer", serverHost: host))
        XCTAssertNil(HubLiveView.allowedURL("https://evil.org/?h=nacho.example.com", serverHost: host))
        XCTAssertNil(HubLiveView.allowedURL("https://nacho.example.com@evil.org/viewer", serverHost: host), "userinfo로 속이는 주소")
    }

    func testRejectsOtherSchemesAndGarbage() {
        for s in ["wss://nacho.example.com/ws", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,x", "//nacho.example.com/v", "", "not a url", "https:///x"] {
            XCTAssertNil(HubLiveView.allowedURL(s, serverHost: host), s)
        }
    }

    func testRejectsEmptyServerHost() {
        XCTAssertNil(HubLiveView.allowedURL("https://nacho.example.com/v", serverHost: ""))
    }

    func testRejectsUserinfoAndOddPorts() {
        XCTAssertNil(HubLiveView.allowedURL("https://user:pw@nacho.example.com/v", serverHost: host))
        XCTAssertNil(HubLiveView.allowedURL("https://nacho.example.com:8443/v", serverHost: host), "서버와 다른 포트")
        XCTAssertNotNil(HubLiveView.allowedURL("https://nacho.example.com:8443/v", serverHost: host, serverPort: 8443))
    }

    /// spec: viewer_url은 나초딥 호스팅 뷰어(`https://<나초딥>/api/v1/remote/viewer#t=…`)라 서버와 호스트가 다르다.
    func testAllowsNachodipViewerHostExactlyOverDefaultPort() {
        let u = HubLiveView.allowedURL("https://dip.mafianacho.com/api/v1/remote/viewer#t=vt_x", serverHost: host)
        XCTAssertEqual(u?.host, "dip.mafianacho.com")
        XCTAssertNotNil(HubLiveView.allowedURL("https://DIP.mafianacho.com/api/v1/remote/viewer#t=vt_x", serverHost: host))
        for bad in ["http://dip.mafianacho.com/api/v1/remote/viewer#t=x", "https://dip.mafianacho.com:8443/v#t=x",
                    "https://dip.mafianacho.com.evil.org/v#t=x", "https://evil.dip.mafianacho.com/v#t=x", "https://mafianacho.com/v#t=x",
                    "https://u@dip.mafianacho.com/v#t=x", "wss://dip.mafianacho.com/api/v1/remote/ws"] {
            XCTAssertNil(HubLiveView.allowedURL(bad, serverHost: host), bad)
        }
        XCTAssertNil(HubLiveView.allowedURL("https://dip.mafianacho.com/v#t=x", serverHost: host, viewerHosts: []), "목록이 비면 서버 호스트만")
    }

    func testHelpTextIsKoreanAndSaysNothingIsSentFromMac() {
        XCTAssertTrue(HubLiveView.helpLines.joined().contains("맥 화면"))
        XCTAssertTrue(HubLiveView.helpLines.count >= 3)
    }
}
