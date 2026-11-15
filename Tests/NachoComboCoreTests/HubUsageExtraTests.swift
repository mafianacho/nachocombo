import XCTest
@testable import NachoComboCore

/// 사용량 확장(NACHO-264 U9: H2 사용 내역, 요금제 보기). 구매 호출이 코드에 없다는 것도 확인한다.
final class HubUsageExtraTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, headers: [:], body: Data(json.utf8)) }

    func testLedgerRequestAndNextPageUsesNextQuery() throws {
        let r = HubUsageAPI.ledger(e, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/me/usage/ledger?limit=30")
        XCTAssertNil(r.body)
        let json = "{\"ledger\":[{\"id\":\"l1\",\"entry_type\":\"usage\",\"task_label\":\"메일 정리\",\"agent_name\":\"나초\",\"credits\":-12,\"occurred_at\":\"2026-11-14T03:00:00Z\"},{\"id\":\"l2\",\"entry_type\":\"grant\",\"credits\":300,\"occurred_at\":\"2026-11-13T00:00:00Z\"}],\"next_cursor\":\"cur-2\"}"
        let (rows, page) = try HubUsageAPI.decodeLedger(resp(200, json)).get()
        XCTAssertEqual(rows.map { $0.title }, ["메일 정리", "지급"])
        XCTAssertEqual(rows.map { $0.creditsText }, ["-12", "+300"])
        XCTAssertEqual(rows[0].subtitle, "사용 · 나초")
        // 서버는 next_cursor를 `cursor`로 받는다. 이름은 nextQuery를 그대로 쓴다.
        let n = HubUsageAPI.ledger(e, bearer: "T", next: page.nextQuery)
        XCTAssertEqual(n.url.absoluteString, "https://nacho.example.com/api/v1/me/usage/ledger?limit=30&cursor=cur-2")
    }

    func testLedgerEmptyAndErrors() throws {
        let (rows, page) = try HubUsageAPI.decodeLedger(resp(200, "{\"ledger\":[]}")).get()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(HubUsageAPI.decodeLedger(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failureText, "로그인이 필요해요.")
        XCTAssertTrue(HubUsageAPI.decodeLedger(resp(500, "{\"error\":{\"code\":\"internal_error\",\"message\":\"x\"}}")).failureText?.contains("일시적인 문제") ?? false)
        XCTAssertEqual(HubUsageAPI.decodeLedger(resp(200, "oops")).failureText, PetAPIError.badResponse.text)
    }

    func testPlansRequestAndDecode() throws {
        let r = HubUsageAPI.plans(e, bearer: "T")
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example.com/api/v1/plans")
        let json = "{\"current_plan_id\":\"free\",\"plans\":[{\"id\":\"free\",\"label\":\"무료\",\"offered\":true,\"daily_allowance\":300,\"weekly_allowance\":0,\"period\":\"day\",\"prices\":[]},{\"id\":\"pro\",\"label\":\"프로\",\"offered\":true,\"weekly_allowance\":5000,\"daily_allowance\":0,\"period\":\"week\",\"prices\":[{\"display\":\"월 9,900원\"}]},{\"id\":\"hidden\",\"label\":\"숨김\",\"offered\":false}],\"credit_packs\":[],\"subscription\":{\"status\":\"active\",\"renews_at\":\"2026-12-01T00:00:00Z\"}}"
        let p = try HubUsageAPI.decodePlans(resp(200, json)).get()
        XCTAssertEqual(p.plans.map { $0.label }, ["무료", "프로"], "판매 중이 아닌 요금제는 빼고, 내 요금제는 남긴다")
        XCTAssertEqual(p.plans[0].allowanceText, "매일 300 크레딧")
        XCTAssertEqual(p.plans[1].allowanceText, "매주 5,000 크레딧")
        XCTAssertEqual(p.plans[1].priceText, "월 9,900원")
        XCTAssertTrue(p.plans[0].isCurrent)
        XCTAssertEqual(p.subscriptionText, "이용 중 · 2026-12-01T00:00:00Z")
        XCTAssertEqual(HubUsageAPI.decodePlans(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")).failureText, ErrorText.fromBody(Data("{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}".utf8), status: 404))
        XCTAssertEqual(try HubUsageAPI.decodePlans(resp(200, "{\"plans\":[]}")).get().plans, [])
    }

    /// 구매(H3)는 보스 결정 대기: 사용량 쪽 소스에 결제 호출 경로가 없어야 한다.
    func testNoPurchaseCallsInUsageSources() throws {
        let files = ["Sources/NachoComboCore/Pet/Hub/Usage/HubUsageExtra.swift",
                     "Sources/NachoCombo/Pet/Hub/Sections/UsageSection.swift",
                     "Sources/NachoCombo/Pet/Hub/Sections/UsageSection+Ledger.swift",
                     "Sources/NachoCombo/Pet/Hub/Sections/UsageSection+Plans.swift"]
        let forbidden = ["/payments", "/credits/purchases", "/credits/toss", "/pay/toss", "/billing", "/subscriptions", "/checkout", "purchases"]
        for f in files {
            let path = usageSourcePath(f)
            let src = try String(contentsOfFile: path, encoding: .utf8)
            for bad in forbidden { XCTAssertFalse(src.contains(bad), "\(f)에 \(bad)") }
            for m in ["\"POST\"", "HubAPI.post(", "HubAPI.put(", "HubAPI.patch(", "HubAPI.delete("] { XCTAssertFalse(src.contains(m), "\(f)에 쓰기 요청 \(m)") }
        }
        XCTAssertEqual(HubUsageAPI.purchaseNotice, "구매는 휴대폰의 나초 앱에서 할 수 있어요")
    }
}

private func usageSourcePath(_ rel: String, file: String = #filePath) -> String {
    var url = URL(fileURLWithPath: file)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.appendingPathComponent(rel).path
}

private extension Result {
    var failureText: String? { if case let .failure(e) = self, let p = e as? PetAPIError { return p.text }; return nil }
}
