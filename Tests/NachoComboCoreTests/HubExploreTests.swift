import XCTest
@testable import NachoComboCore

/// 탐색(NACHO-264 U9: I1). 요청 바이트와 응답·오류 문구.
final class HubExploreTests: XCTestCase {
    private let e = ServerEndpoint(base: URL(string: "https://nacho.example.com")!)
    private func resp(_ status: Int, _ json: String) -> PetHTTPResponse { PetHTTPResponse(status: status, headers: [:], body: Data(json.utf8)) }
    private func body(_ r: PetHTTPRequest) -> String { String(data: r.body ?? Data(), encoding: .utf8) ?? "" }

    func testRequestBytes() {
        let s = HubExploreAPI.sections(e, bearer: "T")
        XCTAssertEqual(s.method, "GET")
        XCTAssertEqual(s.url.absoluteString, "https://nacho.example.com/api/v1/explore/sections")
        let a = HubExploreAPI.accept(e, offerID: "o-1", agentID: "a-1", clientMsgID: "m-1", bearer: "T")
        XCTAssertEqual(a.method, "POST")
        XCTAssertEqual(a.url.path, "/api/v1/explore/offers/o-1/accept")
        XCTAssertEqual(body(a), "{\"agent_id\":\"a-1\",\"client_msg_id\":\"m-1\"}")
        XCTAssertEqual(a.headers["Content-Type"], "application/json")
        let r = HubExploreAPI.reject(e, offerID: "o-1", bearer: "T")
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/api/v1/explore/offers/o-1/reject")
        let u = HubExploreAPI.undoReject(e, offerID: "o-1", bearer: "T")
        XCTAssertEqual(u.url.path, "/api/v1/explore/offers/o-1/reject/undo")
        XCTAssertEqual(u.method, "POST")
    }

    func testDecodeSectionsDropsEmptyAndAppendsMore() throws {
        let json = "{\"areas\":[\"daily\"],\"popular_ids\":[],\"sections\":[{\"section_id\":\"popular\",\"title\":\"인기\",\"items\":[{\"offer_id\":\"o1\",\"detail\":\"메일을 정리해 줘요\",\"cta_label\":\"맡기기\",\"area\":\"daily\",\"steps\":[\"훑기\",\"정리\"],\"usage_estimate\":{\"estimate_min\":10,\"estimate_max\":30,\"task_label\":\"x\"},\"reason\":\"지난달 메일을 보고\"}]},{\"section_id\":\"work\",\"title\":\"일\",\"items\":[]}],\"more_items\":[{\"offer_id\":\"o2\",\"title\":\"여행 계획\",\"detail\":\"d\",\"cta_label\":\"해 보기\",\"area\":\"travel\"}]}"
        let s = try HubExploreAPI.decodeSections(resp(200, json)).get()
        XCTAssertEqual(s.map { $0.id }, ["popular", "more"])
        XCTAssertEqual(s[0].offers[0].title, "메일을 정리해 줘요", "제목이 없으면 detail")
        XCTAssertEqual(s[0].offers[0].usageText, "예상 10~30 크레딧")
        XCTAssertEqual(s[0].offers[0].steps, ["훑기", "정리"])
        XCTAssertEqual(s[1].offers[0].ctaLabel, "해 보기")
        XCTAssertEqual(try HubExploreAPI.decodeSections(resp(200, "{\"sections\":[],\"more_items\":[]}")).get(), [])
    }

    func testAcceptedAndErrors() throws {
        let a = try HubExploreAPI.decodeAccepted(resp(200, "{\"ok\":true,\"room_id\":\"r1\",\"agent_id\":\"a\",\"seq\":1,\"message_id\":\"m\",\"task_id\":\"t1\",\"duplicate\":true}")).get()
        XCTAssertEqual(a, HubOfferAccepted(roomID: "r1", taskID: "t1", duplicate: true))
        XCTAssertNotNil(HubExploreAPI.decodeAccepted(resp(200, "{\"ok\":true}")).failureValue)
        let gone = HubExploreAPI.decodeAccepted(resp(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"x\"}}")).failureValue
        XCTAssertEqual(gone.map(HubExploreAPI.acceptErrorText), "이 제안은 이제 없어요. 목록을 새로 불러올게요.")
        let rest = HubExploreAPI.decodeAccepted(resp(409, "{\"error\":{\"code\":\"character_unavailable\",\"message\":\"x\",\"reason\":\"resting\"}}")).failureValue
        XCTAssertEqual(rest?.text, "나초가 지금 쉬고 있어요.")
        let broke = HubExploreAPI.decodeAccepted(resp(402, "{\"error\":{\"code\":\"task_not_startable\",\"message\":\"x\",\"reason\":\"credits_exhausted\"}}")).failureValue
        XCTAssertTrue(broke?.text.hasPrefix("지금은 일을 맡길 수 없어요.") ?? false, broke?.text ?? "")
        XCTAssertEqual(HubExploreAPI.decodeSections(resp(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"x\"}}")).failureValue?.text, "로그인이 필요해요.")
    }
}

private extension Result {
    var failureValue: PetAPIError? { if case let .failure(e) = self { return e as? PetAPIError }; return nil }
}
