import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 연결 보안 섹션(NACHO-264 U9: E5·E7·E8) 장면별 캡처·동작 시험. macOS CI 오프스크린 렌더이고 실제 Mac 화면이 아니다.
final class HubTrustCaptureTests: XCTestCase {
    private let conns = "[{\"id\":\"c1\",\"source\":\"gmail\",\"label\":\"Gmail\",\"status\":\"connected\",\"enabled\":true,\"account_label\":\"d***@example.com\",\"scope_summary\":\"읽기만 · 고른 라벨 2개\"},{\"id\":\"c2\",\"source\":\"google_calendar\",\"label\":\"구글 캘린더\",\"status\":\"needs_reauth\",\"enabled\":true,\"scope_summary\":\"읽기만\"}]"
    private let agents = "{\"agents\":[{\"id\":\"a1\",\"name\":\"나초\"},{\"id\":\"a2\",\"name\":\"두 번째 나초\"}],\"limits\":{}}"
    private let sharing = "[{\"source\":\"gmail\",\"label\":\"Gmail\",\"category\":\"mail\",\"audience\":\"friends\",\"share_plans_free_only\":false},{\"source\":\"google_calendar\",\"label\":\"구글 캘린더\",\"category\":\"calendar\",\"audience\":\"nobody\",\"share_plans_free_only\":false}]"
    private let allowances = "[{\"agent_id\":\"a1\",\"allowed\":true,\"enforced_by\":\"nacho_tool\"},{\"agent_id\":\"a2\",\"allowed\":false,\"enforced_by\":\"nacho_tool\"}]"
    private let log = "{\"status\":\"server_log\",\"summary\":{\"reads\":3,\"sends\":1,\"changes\":0,\"browser_work\":2,\"since\":\"2026-11-08T00:00:00Z\"},\"days\":[{\"date\":\"2026-11-15\",\"groups\":[{\"id\":\"g1\",\"kind\":\"service_request\",\"action\":\"read\",\"service_name\":\"Gmail\",\"agent_name_snapshot\":\"나초\",\"outcome\":\"ok\",\"count\":3,\"detail\":\"메일 3통 읽음\",\"time_text\":\"14:05\",\"context\":{\"password\":\"hunter2-CTX\"}},{\"id\":\"g2\",\"kind\":\"vault\",\"action\":\"secret_entered\",\"outcome\":\"ok\",\"count\":1,\"field\":\"password\",\"detail\":\"SECRET-DETAIL\",\"time_text\":\"14:10\",\"context\":{\"value\":\"4111111111111111\"}}]}],\"has_more\":true,\"archived\":false,\"next\":{\"before_ms\":1760000000000,\"before_id\":\"u-9\"}}"
    private let rules = "{\"rules\":[{\"rule_id\":\"r1\",\"summary\":\"배달앱에서 건당 20,000원 이하\",\"expired\":false,\"expires_at\":\"2026-12-01T00:00:00Z\",\"used\":5000,\"applies_to_agent_ids\":[\"a1\"]},{\"rule_id\":\"r2\",\"summary\":\"지난달 만료된 규칙\",\"expired\":true,\"used\":0,\"applies_to_agent_ids\":[]}],\"account_limit\":{\"value\":100000,\"currency\":\"KRW\",\"used\":5000},\"payment_auto\":[]}"

    private func http(logStatus: Int = 200, connsBody: String? = nil) -> HubFakeHTTP {
        HubFakeHTTP { [self] r in
            switch (r.method, r.url.path) {
            case ("GET", "/api/v1/connections"): return HubU9.json(connsBody ?? conns)
            case ("GET", "/api/v1/agents"): return HubU9.json(agents)
            case ("GET", "/api/v1/connections/sharing"): return HubU9.json(sharing)
            case ("GET", "/api/v1/connections/c1/agents"): return HubU9.json(allowances)
            case ("PUT", "/api/v1/connections/c1/agents"): return HubU9.json("[{\"agent_id\":\"a1\",\"allowed\":false},{\"agent_id\":\"a2\",\"allowed\":false}]")
            case ("PUT", "/api/v1/connections/gmail/sharing"): return HubU9.json("{\"source\":\"gmail\",\"label\":\"Gmail\",\"category\":\"mail\",\"audience\":\"nobody\",\"share_plans_free_only\":false}")
            case ("GET", "/api/v1/secure/log"):
                if logStatus != 200 { return HubU9.err(logStatus, "internal_error") }
                return HubU9.json(r.url.query?.contains("before_ms") == true ? "{\"days\":[{\"date\":\"2026-11-14\",\"groups\":[{\"id\":\"g3\",\"action\":\"send\",\"service_name\":\"Slack\",\"outcome\":\"ok\",\"count\":1,\"time_text\":\"09:00\"}]}],\"has_more\":false}" : log)
            case ("GET", "/api/v1/me/approval-rules"): return HubU9.json(rules)
            case ("PATCH", "/api/v1/me/approval-rules"): return HubU9.json("{\"ok\":true,\"rules\":{\"rules\":[],\"account_limit\":{\"value\":70000,\"currency\":\"KRW\",\"used\":0}}}")
            case ("DELETE", "/api/v1/me/approval-rules/r1"): return HubU9.json("{\"ok\":true}")
            default: return HubU9.err(404, "not_found")
            }
        }
    }

    private func section(_ w: PetHubWindow) throws -> TrustSection { try XCTUnwrap(w.currentSection as? TrustSection) }

    func testConnectionsTabListsServicesAndSharing() throws {
        let h = http()
        let w = HubU9.window(.trust, http: h)
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("Gmail"), all)
        XCTAssertTrue(all.contains("구글 캘린더"), all)
        XCTAssertTrue(all.contains("다시 로그인 필요"), all)
        XCTAssertTrue(all.contains("친구의 나초에게만"), all)
        XCTAssertEqual(Set(h.lines), ["GET /api/v1/connections", "GET /api/v1/agents", "GET /api/v1/connections/sharing"])
        try HubU9.captureAll(w, name: "trust-connections")
    }

    func testConnectionDetailAllowanceAndSharingWrites() throws {
        let h = http()
        let w = HubU9.window(.trust, http: h)
        HubU9.pump()
        XCTAssertTrue(HubU9.tapRow("Gmail", in: w.contentView!))
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("이 연결을 쓸 수 있는 나초") && all.contains("두 번째 나초"), all)
        XCTAssertTrue(all.contains("친구의 나초에게만"))
        try HubU9.captureAll(w, name: "trust-connection-detail")
        let sw = try XCTUnwrap(HubU9.find(HubSwitchRow.self, in: w.contentView!))
        sw.onChange?(false)
        HubU9.pump()
        let put = h.bodies("PUT", "/api/v1/connections/c1/agents")
        XCTAssertEqual(put.count, 1)
        XCTAssertTrue(put[0].contains("{\"agent_id\":\"a1\",\"allowed\":false}"), put[0])
        XCTAssertEqual(h.log.last { $0.method == "PUT" }?.headers["Idempotency-Key"]?.isEmpty, false)
        let seg = try XCTUnwrap(HubU9.find(NSSegmentedControl.self, in: w.contentView!, where: { $0.segmentCount == 2 }))
        (seg.target as? HubSegmentHandler)?.onSelect(0)
        HubU9.pump()
        XCTAssertEqual(h.bodies("PUT", "/api/v1/connections/gmail/sharing"), ["{\"audience\":\"nobody\"}"])
        // 연결 켜기/끄기·연동 요청은 보내지 않는다.
        XCTAssertFalse(h.lines.contains { $0.contains("/begin") || $0.contains("/disconnect") || $0.contains("/enabled") })
    }

    func testConnectionsEmptyAndError() throws {
        let empty = HubU9.window(.trust, http: http(connsBody: "[]"))
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(empty).contains("연결한 서비스가 아직 없어요"))
        try HubU9.capture(empty, dark: false, name: "trust-connections-empty")
        let bad = HubU9.window(.trust, http: HubFakeHTTP { _ in HubU9.err(500, "internal_error") })
        HubU9.pump()
        let all = HubU9.joined(bad)
        XCTAssertTrue(all.contains("일시적인 문제가 생겼어요. 다시 시도해 주세요.") && all.contains("다시 시도"), all)
    }

    func testAccessLogShowsNoSecretsAndPages() throws {
        let h = http()
        let w = HubU9.window(.trust, http: h)
        HubU9.pump()
        let s = try section(w)
        s.tabs.select(1)
        s.loadTab(1)
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("Gmail · 읽었어요"), all)
        XCTAssertTrue(all.contains("최근 7일 · 읽기 3 · 보내기 1 · 바꾸기 0 · 브라우저 작업 2"), all)
        XCTAssertTrue(all.contains("비밀번호 칸"))
        for secret in ["hunter2-CTX", "SECRET-DETAIL", "4111111111111111"] { XCTAssertFalse(all.contains(secret), "\(secret) 비표시") }
        XCTAssertNil(h.log.last { $0.url.path == "/api/v1/secure/log" }?.headers["X-Device-Auth"])
        try HubU9.captureAll(w, name: "trust-log")
        XCTAssertTrue(HubU9.tap("더 보기", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(h.lines.contains("GET /api/v1/secure/log?limit=50&before_ms=1760000000000&before_id=u-9"), h.lines.joined(separator: "\n"))
        XCTAssertTrue(HubU9.joined(w).contains("Slack · 보냈어요"))
    }

    func testAccessLogErrorShowsKorean() throws {
        let w = HubU9.window(.trust, http: http(logStatus: 500))
        HubU9.pump()
        let s = try section(w)
        s.tabs.select(1)
        s.loadTab(1)
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
    }

    func testRulesListLimitValidationAndSave() throws {
        let h = http()
        let w = HubU9.window(.trust, http: h)
        HubU9.pump()
        let s = try section(w)
        s.tabs.select(2)
        s.loadTab(2)
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("배달앱에서 건당 20,000원 이하") && all.contains("만료됨"), all)
        XCTAssertTrue(all.contains("100,000원"), all)
        try HubU9.captureAll(w, name: "trust-rules")
        let field = try XCTUnwrap(s.limitField)
        field.field.stringValue = "abc"
        s.saveLimit(currency: "KRW")
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w).contains("숫자만 넣어 주세요."))
        XCTAssertTrue(h.bodies("PATCH", "/api/v1/me/approval-rules").isEmpty, "잘못된 입력은 보내지 않는다")
        try HubU9.capture(w, dark: false, name: "trust-rules-invalid")
        field.field.stringValue = "70000"
        s.saveLimit(currency: "KRW")
        HubU9.pump()
        XCTAssertEqual(h.bodies("PATCH", "/api/v1/me/approval-rules"), ["{\"account_limit\":{\"currency\":\"KRW\",\"value\":70000}}"])
    }

    func testRuleDeleteNeedsTwoConfirmations() throws {
        let h = http()
        let w = HubU9.window(.trust, http: h)
        HubU9.pump()
        let s = try section(w)
        s.tabs.select(2)
        s.loadTab(2)
        HubU9.pump()
        let rule = HubApprovalRule(id: "r1", summary: "배달앱에서 건당 20,000원 이하", expired: false, expiresAt: nil, used: 0, appliesToAgentIDs: [])
        s.confirmDelete(rule)
        HubU9.pump()
        let sheet1 = try XCTUnwrap(w.attachedSheet?.contentView)
        XCTAssertTrue(HubU9.texts(sheet1).contains("이 규칙을 지울까요?"))
        XCTAssertTrue(h.log.filter { $0.method == "DELETE" }.isEmpty, "첫 확인 전엔 지우지 않는다")
        XCTAssertTrue(HubU9.tap("계속", in: sheet1))
        HubU9.pump()
        let sheet2 = try XCTUnwrap(w.attachedSheet?.contentView)
        XCTAssertTrue(HubU9.texts(sheet2).contains("정말 지울까요?"))
        XCTAssertTrue(h.log.filter { $0.method == "DELETE" }.isEmpty, "두 번째 확인 전엔 지우지 않는다")
        XCTAssertTrue(HubU9.tap("지우기", in: sheet2))
        HubU9.pump()
        XCTAssertEqual(h.log.filter { $0.method == "DELETE" }.map { $0.url.path }, ["/api/v1/me/approval-rules/r1"])
    }
}
