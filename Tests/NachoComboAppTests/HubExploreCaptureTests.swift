import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// 탐색 섹션(NACHO-264 U9: I1) 장면별 캡처·동작 시험. macOS CI 오프스크린 렌더.
final class HubExploreCaptureTests: XCTestCase {
    private let sections = "{\"areas\":[\"daily\"],\"popular_ids\":[],\"sections\":[{\"section_id\":\"popular\",\"title\":\"인기\",\"items\":[{\"offer_id\":\"o1\",\"title\":\"메일함 정리\",\"detail\":\"쌓인 메일을 훑어 중요한 것만 알려 줘요\",\"cta_label\":\"맡기기\",\"area\":\"daily\",\"steps\":[\"메일 훑기\",\"중요한 것 고르기\"],\"usage_estimate\":{\"estimate_min\":10,\"estimate_max\":30,\"task_label\":\"x\"},\"reason\":\"지난달 메일을 보고 제안했어요\"},{\"offer_id\":\"o2\",\"detail\":\"이번 주말 여행 계획 짜기\",\"cta_label\":\"해 보기\",\"area\":\"travel\",\"steps\":[]}]}],\"more_items\":[]}"
    private let agents = "{\"agents\":[{\"id\":\"a1\",\"name\":\"나초\"},{\"id\":\"a2\",\"name\":\"두 번째 나초\"}],\"limits\":{}}"

    private func http(acceptReply: (Int, String, [String: String])? = nil, emptySections: Bool = false) -> HubFakeHTTP {
        HubFakeHTTP { [self] r in
            switch (r.method, r.url.path) {
            case ("GET", "/api/v1/explore/sections"): return HubU9.json(emptySections ? "{\"areas\":[],\"popular_ids\":[],\"sections\":[],\"more_items\":[]}" : sections)
            case ("GET", "/api/v1/agents"): return HubU9.json(agents)
            case ("POST", "/api/v1/explore/offers/o1/accept"): return acceptReply ?? HubU9.json("{\"ok\":true,\"room_id\":\"r1\",\"agent_id\":\"a1\",\"seq\":1,\"message_id\":\"m\",\"duplicate\":false}")
            case ("POST", "/api/v1/explore/offers/o1/reject"), ("POST", "/api/v1/explore/offers/o1/reject/undo"): return HubU9.json("{\"ok\":true}")
            default: return HubU9.err(404, "not_found")
            }
        }
    }

    private func section(_ w: PetHubWindow) throws -> ExploreSection { try XCTUnwrap(w.currentSection as? ExploreSection) }

    func testCardsShowOfferDetails() throws {
        let h = http()
        let w = HubU9.window(.explore, http: h)
        HubU9.pump()
        let all = HubU9.joined(w)
        for t in ["인기", "메일함 정리", "1. 메일 훑기", "예상 10~30 크레딧", "지난달 메일을 보고 제안했어요", "이번 주말 여행 계획 짜기", "해 보기", "맡을 나초"] {
            XCTAssertTrue(all.contains(t), "\(t)\n\(all)")
        }
        XCTAssertTrue(h.log.allSatisfy { $0.method == "GET" }, "열기만으로는 아무것도 맡기지 않는다")
        try HubU9.captureAll(w, name: "explore-cards")
    }

    func testAcceptSendsAgentAndClientMsgID() throws {
        let h = http()
        let w = HubU9.window(.explore, http: h)
        HubU9.pump()
        XCTAssertTrue(HubU9.tap("맡기기", in: w.contentView!))
        HubU9.pump()
        let body = h.bodies("POST", "/api/v1/explore/offers/o1/accept")
        XCTAssertEqual(body.count, 1)
        XCTAssertTrue(body[0].hasPrefix("{\"agent_id\":\"a1\",\"client_msg_id\":\""), body[0])
        XCTAssertEqual(h.log.filter { $0.url.path.hasSuffix("/accept") }.count, 1, "한 번 눌렀으면 한 번만")
    }

    func testAcceptGoneReloadsAndRestingAgentShowsKorean() throws {
        let gone = http(acceptReply: HubU9.err(404, "not_found"))
        let w = HubU9.window(.explore, http: gone)
        HubU9.pump()
        _ = HubU9.tap("맡기기", in: w.contentView!)
        HubU9.pump()
        XCTAssertEqual(gone.lines.filter { $0 == "GET /api/v1/explore/sections" }.count, 2, "없어진 제안이면 목록을 새로 불러온다")
        let rest = http(acceptReply: HubU9.err(409, "character_unavailable", reason: "resting"))
        let w2 = HubU9.window(.explore, http: rest)
        HubU9.pump()
        _ = HubU9.tap("맡기기", in: w2.contentView!)
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w2).contains("나초가 지금 쉬고 있어요."), HubU9.joined(w2))
    }

    func testRejectThenUndo() throws {
        let h = http()
        let w = HubU9.window(.explore, http: h)
        HubU9.pump()
        let s = try section(w)
        XCTAssertTrue(HubU9.tap("관심 없어요", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(h.lines.contains("POST /api/v1/explore/offers/o1/reject"))
        XCTAssertNotNil(s.lastRejected)
        XCTAssertTrue(HubU9.joined(w).contains("「메일함 정리」 숨김 되돌리기"))
        try HubU9.capture(w, dark: false, name: "explore-undo")
        XCTAssertTrue(HubU9.tap("「메일함 정리」 숨김 되돌리기", in: w.contentView!))
        HubU9.pump()
        XCTAssertTrue(h.lines.contains("POST /api/v1/explore/offers/o1/reject/undo"))
        XCTAssertNil(s.lastRejected)
    }

    func testEmptyAndSignedErrorStates() throws {
        let w = HubU9.window(.explore, http: http(emptySections: true))
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(w).contains("지금 둘러볼 제안이 없어요."))
        try HubU9.capture(w, dark: false, name: "explore-empty")
        let bad = HubU9.window(.explore, http: HubFakeHTTP { _ in HubU9.err(500, "internal_error") })
        HubU9.pump()
        XCTAssertTrue(HubU9.joined(bad).contains("일시적인 문제가 생겼어요. 다시 시도해 주세요."))
    }

    /// 쓰기 중에 다른 섹션으로 옮겨 컨텍스트(클라이언트)가 바뀌어도 결과(토스트)가 사라지지 않는다.
    func testWriteResultSurvivesNavigatingAway() throws {
        let h = http()
        var hold = false
        var pending: [(String?) -> Void] = []
        let provider: HubTokenProvider = { _, done in if hold { pending.append(done) } else { done("fake-token") } }
        let w = HubU9.window(.explore, http: h, tokens: provider)
        HubU9.pump()
        XCTAssertTrue(h.lines.contains("GET /api/v1/explore/sections"))
        // 이제부터 토큰 발급을 붙잡아 둔다(비동기 토큰 갱신).
        hold = true
        let s = try section(w)
        s.reject(HubOffer(id: "o1", title: "메일함 정리", detail: "", ctaLabel: "맡기기", area: "", steps: [], reason: nil, usageText: nil))
        XCTAssertEqual(pending.count, 1, "토큰을 기다리는 중")
        // 다른 섹션으로 갔다 오면 컨텍스트와 클라이언트가 새로 만들어진다.
        hold = false
        w.select(.usage)
        w.select(.explore)
        for done in pending { done("fake-token") }
        HubU9.pump(0.5)
        XCTAssertTrue(h.lines.contains("POST /api/v1/explore/offers/o1/reject"), "요청이 끝까지 간다: \(h.lines)")
        XCTAssertNotNil(s.lastRejected, "결과가 반영된다")
    }
}
