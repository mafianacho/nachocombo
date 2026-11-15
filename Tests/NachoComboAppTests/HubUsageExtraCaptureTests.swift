import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 사용량 확장(NACHO-264 U9: H2 사용 내역·요금제 보기) 장면별 캡처·동작 시험. macOS CI 오프스크린 렌더.
final class HubUsageExtraCaptureTests: XCTestCase {
    private let usage = "{\"plan_id\":\"free\",\"period\":\"week\",\"allowance\":300,\"remaining\":120,\"reset_at\":\"2026-11-20T00:00:00Z\",\"exhausted\":false,\"low_balance\":false,\"limits\":[]}"
    private let ledger = "{\"ledger\":[{\"id\":\"l1\",\"entry_type\":\"usage\",\"task_label\":\"메일 정리\",\"agent_name\":\"나초\",\"credits\":-12,\"occurred_at\":\"2026-11-14T03:00:00Z\"},{\"id\":\"l2\",\"entry_type\":\"grant\",\"credits\":300,\"occurred_at\":\"2026-11-13T00:00:00Z\"}],\"next_cursor\":\"cur-2\"}"
    private let plans = "{\"current_plan_id\":\"free\",\"plans\":[{\"id\":\"free\",\"label\":\"무료\",\"offered\":true,\"daily_allowance\":300,\"period\":\"day\",\"prices\":[]},{\"id\":\"pro\",\"label\":\"프로\",\"offered\":true,\"weekly_allowance\":5000,\"period\":\"week\",\"prices\":[{\"display\":\"월 9,900원\"}]}],\"credit_packs\":[],\"subscription\":null}"

    private func http(ledgerBody: String? = nil, plansStatus: Int = 200) -> HubFakeHTTP {
        HubFakeHTTP { [self] r in
            switch r.url.path {
            case "/api/v1/me/usage": return HubU9.json(usage)
            case "/api/v1/me/usage/ledger":
                return HubU9.json(r.url.query?.contains("cursor=") == true ? "{\"ledger\":[{\"id\":\"l3\",\"entry_type\":\"refund\",\"credits\":5,\"occurred_at\":\"2026-11-12T00:00:00Z\"}]}" : (ledgerBody ?? ledger))
            case "/api/v1/plans": return plansStatus == 200 ? HubU9.json(plans) : HubU9.err(plansStatus, "internal_error")
            default: return HubU9.err(404, "not_found")
            }
        }
    }

    func testLedgerScreenPagesAndShowsSigns() throws {
        let h = http()
        let w = HubU9.window(.usage, http: h)
        HubU9.pump()
        XCTAssertTrue(HubU9.tap("사용 내역", in: w.contentView!))
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("메일 정리") && all.contains("-12") && all.contains("+300"), all)
        try HubU9.captureAll(w, name: "usage-ledger")
        XCTAssertTrue(HubU9.tap("더 보기", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(h.lines.contains("GET /api/v1/me/usage/ledger?limit=30&cursor=cur-2"), h.lines.joined(separator: "\n"))
        XCTAssertTrue(HubU9.joined(w).contains("환불"))
    }

    func testLedgerEmpty() throws {
        let w = HubU9.window(.usage, http: http(ledgerBody: "{\"ledger\":[]}"))
        HubU9.pump()
        XCTAssertTrue(HubU9.tap("사용 내역", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w).contains("아직 사용 내역이 없어요."))
        try HubU9.capture(w, dark: false, name: "usage-ledger-empty")
    }

    func testPlansAreReadOnlyWithPurchaseNotice() throws {
        let h = http()
        let w = HubU9.window(.usage, http: h)
        HubU9.pump()
        XCTAssertTrue(HubU9.tap("요금제 보기", in: w.contentView!))
        HubU9.pump()
        let all = HubU9.joined(w)
        XCTAssertTrue(all.contains("무료 · 내 요금제") && all.contains("월 9,900원"), all)
        XCTAssertTrue(all.contains("구매는 휴대폰의 나초 앱에서 할 수 있어요"), all)
        XCTAssertNil(HubU9.find(PetPill.self, in: w.contentView!, where: { HubU9.texts($0).contains(where: { $0.contains("구매") || $0.contains("결제") || $0.contains("업그레이드") }) }), "결제 단추 없음")
        XCTAssertTrue(h.log.allSatisfy { $0.method == "GET" }, "읽기만: \(h.lines)")
        try HubU9.captureAll(w, name: "usage-plans")
    }

    func testPlansServerErrorShowsKorean() throws {
        let w = HubU9.window(.usage, http: http(plansStatus: 500))
        HubU9.pump()
        XCTAssertTrue(HubU9.tap("요금제 보기", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
    }
}
