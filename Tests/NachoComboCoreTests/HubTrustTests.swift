import XCTest
@testable import NachoComboCore

/// 연결 보안(NACHO-264 U9: E5·E7·E8). 요청은 바이트 단위, 응답은 정상·빈 목록·401·404·409·서버 오류 문구까지.
final class HubTrustTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, headers: [:], body: Data(json.utf8)) }

    // MARK: E5 requests

    func testConnectionsAndAgentsAreReadOnlyGets() {
        let c = HubTrustAPI.connections(e, bearer: "T")
        XCTAssertEqual(c.method, "GET")
        XCTAssertEqual(c.url.absoluteString, "https://nacho.example.com/api/v1/connections")
        XCTAssertNil(c.body)
        XCTAssertEqual(HubTrustAPI.agents(e, bearer: "T").url.path, "/api/v1/agents")
    }

    func testAllowancesGetAndPutBytes() {
        let g = HubTrustAPI.allowances(e, connectionID: "c-1", bearer: "T")
        XCTAssertEqual(g.method, "GET")
        XCTAssertEqual(g.url.path, "/api/v1/connections/c-1/agents")
        let p = HubTrustAPI.putAllowances(e, connectionID: "c-1", items: [
            HubAllowance(agentID: "a1", allowed: true, writeKinds: nil),
            HubAllowance(agentID: "a2", allowed: false, writeKinds: ["send"]),
        ], bearer: "T", idempotencyKey: "K")
        XCTAssertEqual(p.method, "PUT")
        XCTAssertEqual(p.url.path, "/api/v1/connections/c-1/agents")
        XCTAssertEqual(p.headers["Content-Type"], "application/json")
        XCTAssertEqual(p.headers["Authorization"], "Bearer T")
        XCTAssertEqual(p.headers["Idempotency-Key"], "K")
        XCTAssertEqual(body(p), "[{\"agent_id\":\"a1\",\"allowed\":true},{\"agent_id\":\"a2\",\"allowed\":false,\"write_kinds\":[\"send\"]}]")
    }

    func testSharingRequests() {
        XCTAssertEqual(HubTrustAPI.sharing(e, bearer: "T").url.path, "/api/v1/connections/sharing")
        let mail = HubTrustAPI.putSharing(e, source: "gmail", category: "mail", audience: .friends, bearer: "T")
        XCTAssertEqual(mail.method, "PUT")
        XCTAssertEqual(mail.url.path, "/api/v1/connections/gmail/sharing")
        XCTAssertEqual(body(mail), "{\"audience\":\"friends\"}")
        let cal = HubTrustAPI.putSharing(e, source: "google_calendar", category: "calendar", audience: .friends, bearer: "T")
        XCTAssertEqual(body(cal), "{\"audience\":\"friends\",\"share_plans_free_only\":true}")
        let none = HubTrustAPI.putSharing(e, source: "google_calendar", category: "calendar", audience: .nobody, bearer: "T")
        XCTAssertEqual(body(none), "{\"audience\":\"nobody\"}")
        XCTAssertEqual(HubAudience.selectable, [.nobody, .friends], "everyone은 새로 고를 수 없다")
    }

    func testNoConnectionToggleOrConnectCalls() throws {
        // 켜기/끄기·연동은 연결 탭(#47) 몫: 이 Core에는 PATCH /connections/{id}, begin, disconnect 요청이 없다.
        let src = try String(contentsOfFile: trustSourcePath("Sources/NachoComboCore/Pet/Hub/Trust/HubTrust.swift"), encoding: .utf8)
        for bad in ["/connections/begin", "/disconnect", "/scope\"", "\"PATCH\", e, \"/api/v1/connections"] {
            XCTAssertFalse(src.contains(bad), bad)
        }
    }

    func testDecodeConnectionsAllowancesSharing() throws {
        let c = try HubTrustAPI.decodeConnections(resp(200, "[{\"id\":\"c1\",\"source\":\"gmail\",\"label\":\"Gmail\",\"status\":\"connected\",\"enabled\":true,\"account_label\":\"d***@x.com\",\"scope_summary\":\"읽기만\"},{\"nope\":1}]")).get()
        XCTAssertEqual(c, [HubConnection(id: "c1", source: "gmail", label: "Gmail", accountLabel: "d***@x.com", status: "connected", enabled: true, scopeSummary: "읽기만")])
        XCTAssertEqual(c[0].statusText, "연결됨")
        XCTAssertEqual(try HubTrustAPI.decodeConnections(resp(200, "[]")).get(), [])
        let a = try HubTrustAPI.decodeAllowances(resp(200, "[{\"agent_id\":\"a1\",\"allowed\":true,\"enforced_by\":\"nacho_tool\"},{\"agent_id\":\"a2\",\"allowed\":false,\"write_kinds\":[\"send\"]}]")).get()
        XCTAssertEqual(a, [HubAllowance(agentID: "a1", allowed: true, writeKinds: nil), HubAllowance(agentID: "a2", allowed: false, writeKinds: ["send"])])
        let s = try HubTrustAPI.decodeSharing(resp(200, "[{\"source\":\"gmail\",\"label\":\"Gmail\",\"category\":\"mail\",\"audience\":\"friends\",\"share_plans_free_only\":false},{\"source\":\"x\",\"audience\":\"weird\"}]")).get()
        XCTAssertEqual(s.map { $0.audience }, [.friends, .nobody])
        let ag = try HubTrustAPI.decodeAgents(resp(200, "{\"agents\":[{\"id\":\"a1\",\"name\":\"나초\"}],\"limits\":{}}")).get()
        XCTAssertEqual(ag, [HubAgentRef(id: "a1", name: "나초")])
    }

    func testErrorsAreKorean() {
        XCTAssertEqual(HubTrustAPI.decodeConnections(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failure?.text, "로그인이 필요해요.")
        XCTAssertEqual(HubTrustAPI.decodeAllowances(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")).failure?.isNotFound, true)
        XCTAssertTrue(HubTrustAPI.decodeSharing(resp(500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")).failure?.text.contains("일시적인 문제") ?? false)
        XCTAssertEqual(HubTrustAPI.decodeSharingRow(resp(400, "{\"error\":{\"code\":\"validation_error\",\"message\":\"x\"}}")).failure?.text, "입력을 다시 확인해 주세요.")
    }

    // MARK: E7 secure log — 비밀 값 비표시

    private let secretLog = """
    {"status":"server_log","summary":{"reads":3,"sends":1,"changes":0,"browser_work":2,"since":"2026-11-08T00:00:00Z"},
     "days":[{"date":"2026-11-15","groups":[
       {"id":"g1","kind":"service_request","action":"read","service_name":"Gmail","agent_name_snapshot":"나초","outcome":"ok","count":3,"detail":"메일 3통 읽음","time_text":"14:05","context":{"password":"hunter2-CTX"},"requests":[{"target_label":"TARGET-SECRET","detail":"REQ-SECRET"}]},
       {"id":"g2","kind":"vault","action":"secret_entered","outcome":"ok","count":1,"field":"password","detail":"비밀번호는 SECRET-DETAIL","time_text":"14:10","context":{"value":"4111111111111111"},"flagged":true}]}],
     "has_more":true,"archived":false,"next":{"before_ms":1760000000000,"before_id":"u-9"}}
    """

    func testAccessLogRequestHasNoDeviceAuthAndPagesWithServerCursor() {
        let r = HubTrustAPI.accessLog(e, bearer: "T")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/secure/log?limit=50")
        XCTAssertNil(r.headers["X-Device-Auth"])
        let n = HubTrustAPI.accessLog(e, bearer: "T", limit: 20, next: [("before_ms", "17"), ("before_id", "u-9")])
        XCTAssertEqual(n.url.absoluteString, "https://nacho.example.com/api/v1/secure/log?limit=20&before_ms=17&before_id=u-9")
    }

    func testAccessLogDoesNotSurfaceSecretValues() throws {
        let log = try HubTrustAPI.decodeAccessLog(resp(200, secretLog)).get()
        XCTAssertEqual(log.rows.count, 2)
        XCTAssertEqual(log.summary?.reads, 3)
        XCTAssertEqual(log.summary?.browserWork, 2)
        XCTAssertTrue(log.hasMore)
        XCTAssertEqual(log.nextQuery?.map { "\($0.0)=\($0.1)" }, ["before_ms=1760000000000", "before_id=u-9"])
        let everything = log.rows.map { [$0.title, $0.subtitle ?? "", $0.timeText, $0.outcome].joined(separator: "|") }.joined(separator: "\n")
        XCTAssertTrue(everything.contains("Gmail · 읽었어요"), everything)
        XCTAssertTrue(everything.contains("메일 3통 읽음"), everything)
        XCTAssertTrue(everything.contains("비밀번호 칸"), "어떤 칸이 쓰였는지는 보여 준다: \(everything)")
        for secret in ["hunter2-CTX", "TARGET-SECRET", "REQ-SECRET", "SECRET-DETAIL", "4111111111111111"] {
            XCTAssertFalse(everything.contains(secret), "\(secret) 비표시")
        }
        XCTAssertTrue(log.rows[1].flagged)
    }

    func testAccessLogEmptyAndErrors() throws {
        let empty = try HubTrustAPI.decodeAccessLog(resp(200, "{\"status\":\"server_log\",\"days\":[],\"has_more\":false,\"archived\":false}")).get()
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertNil(empty.nextQuery)
        // has_more인데 next가 없으면 이어 받지 않는다.
        XCTAssertFalse(try HubTrustAPI.decodeAccessLog(resp(200, "{\"days\":[],\"has_more\":true}")).get().hasMore)
        XCTAssertEqual(HubTrustAPI.decodeAccessLog(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failure?.isUnauthorized, true)
        XCTAssertEqual(HubTrustAPI.decodeAccessLog(resp(200, "[1]")).failure, .badResponse)
    }

    // MARK: E8 approval rules

    func testApprovalRuleRequests() {
        XCTAssertEqual(HubTrustAPI.approvalRules(e, bearer: "T").url.path, "/api/v1/me/approval-rules")
        let set = HubTrustAPI.patchAccountLimit(e, value: 50000, bearer: "T")
        XCTAssertEqual(set.method, "PATCH")
        XCTAssertEqual(set.url.path, "/api/v1/me/approval-rules")
        XCTAssertEqual(body(set), "{\"account_limit\":{\"currency\":\"KRW\",\"value\":50000}}")
        XCTAssertEqual(body(HubTrustAPI.patchAccountLimit(e, value: nil, bearer: "T")), "{\"account_limit\":{\"currency\":\"KRW\",\"value\":null}}")
        let d = HubTrustAPI.deleteRule(e, id: "r-1", bearer: "T")
        XCTAssertEqual(d.method, "DELETE")
        XCTAssertEqual(d.url.path, "/api/v1/me/approval-rules/r-1")
        XCTAssertNil(d.body)
    }

    func testLimitInputValidation() throws {
        XCTAssertEqual(try HubTrustAPI.parseLimit("").get(), nil)
        XCTAssertEqual(try HubTrustAPI.parseLimit(" 50,000 ").get(), 50000)
        XCTAssertEqual(HubTrustAPI.parseLimit("0").failure?.text, "1원 이상으로 넣어 주세요. 한도를 없애려면 칸을 비워 주세요.")
        XCTAssertEqual(HubTrustAPI.parseLimit("-5").failure?.text, "숫자만 넣어 주세요.")
        XCTAssertEqual(HubTrustAPI.parseLimit("12.5").failure?.text, "숫자만 넣어 주세요.")
        XCTAssertEqual(HubTrustAPI.parseLimit("abc").failure?.text, "숫자만 넣어 주세요.")
        XCTAssertEqual(HubTrustAPI.parseLimit("99999999999999").failure?.text, "너무 큰 금액이에요.")
    }

    func testDecodeApprovalRules() throws {
        let json = "{\"rules\":[{\"rule_id\":\"r1\",\"summary\":\"배달앱에서 건당 2만원 이하\",\"expired\":false,\"expires_at\":\"2026-12-01T00:00:00Z\",\"used\":5000,\"applies_to_agent_ids\":[\"a1\"]},{\"summary\":\"id 없음\"}],\"account_limit\":{\"value\":100000,\"currency\":\"KRW\",\"used\":5000},\"payment_auto\":[]}"
        let r = try HubTrustAPI.decodeApprovalRules(resp(200, json)).get()
        XCTAssertEqual(r.rules, [HubApprovalRule(id: "r1", summary: "배달앱에서 건당 2만원 이하", expired: false, expiresAt: "2026-12-01T00:00:00Z", used: 5000, appliesToAgentIDs: ["a1"])])
        XCTAssertEqual(r.limitValue, 100000)
        XCTAssertEqual(r.limitUsed, 5000)
        let none = try HubTrustAPI.decodeApprovalRules(resp(200, "{\"rules\":[],\"account_limit\":null,\"payment_auto\":[]}")).get()
        XCTAssertTrue(none.rules.isEmpty)
        XCTAssertNil(none.limitValue)
        let patched = try HubTrustAPI.decodePatchedRules(resp(200, "{\"ok\":true,\"rules\":{\"rules\":[],\"account_limit\":{\"value\":7,\"currency\":\"KRW\",\"used\":0}}}")).get()
        XCTAssertEqual(patched.limitValue, 7)
        XCTAssertEqual(HubTrustAPI.decodePatchedRules(resp(200, "{\"ok\":true}")).failure, .badResponse)
        XCTAssertEqual(HubTrustAPI.decodeApprovalRules(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")).failure?.isNotFound, true)
        XCTAssertEqual(HubTrustAPI.decodePatchedRules(resp(400, "{\"error\":{\"code\":\"invalid_input\",\"message\":\"x\"}}")).failure?.text, "보낼 수 없는 내용이에요.")
    }
}

/// 이 시험 파일 기준으로 레포 루트의 파일 경로를 만든다.
fileprivate func trustSourcePath(_ rel: String, file: String = #filePath) -> String {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(rel).path
}

private extension Result {
    var failure: Failure? { if case let .failure(e) = self { return e }; return nil }
}
