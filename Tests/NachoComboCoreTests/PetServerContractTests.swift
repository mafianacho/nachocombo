import Foundation
import XCTest

@testable import NachoComboCore

/// Every REST call the pet makes must be a route of nacho-server's spec. `routes` is the pet's subset of
/// `scripts/server-contract-routes.py ../nacho-server` at `specRef`; `scripts/check-server-contract.sh` re-checks it
/// against a newer nacho-server checkout (the server repo is private, so CI checks this pinned copy).
enum PetServerContract {
    static let specRef = "nacho-server origin/main 2db5f4e (2026-11-11)"
    static let routes: Set<String> = [
        "GET /client/config",
        "GET /api/v1/me",
        "GET /api/v1/me/usage",
        "GET /api/v1/connections",
        "GET /api/v1/tools",
        "POST /api/v1/media/uploads",
        "POST /api/v1/agents/{id}/connector-binding",
        "GET /api/v1/rooms/{id}/history",
        "GET /api/v1/rooms/{id}/delta",
        "POST /api/v1/dictation",
        "POST /api/v1/memory/feedback",
        "DELETE /api/v1/memory/facts/{id}",
        "DELETE /api/v1/memory/episodes/{id}",
        "POST /api/v1/memory/{id}/restore",
        "GET /api/v1/chat/requests/{id}",
        "POST /api/v1/chat/requests/{id}/answer",
    ]

    /// "GET /api/v1/rooms/{id}/history" for a built request (ids → {id}, query dropped).
    static func route(_ r: PetHTTPRequest, ids: [String]) -> String {
        var path = r.url.path
        for id in ids { path = path.replacingOccurrences(of: "/\(id)", with: "/{id}") }
        return "\(r.method) \(path)"
    }
}

final class PetServerContractTests: XCTestCase {
    func testEveryRequestThePetBuildsIsInTheServerSpec() {
        let e = ServerEndpoint(base: URL(string: "https://api.nachotown.com")!)
        let room = "0193aaaa-0000-7000-8000-000000000003", mem = "0193aaaa-0000-7000-8000-0000000000f1"
        let card = PetCard.decode(["id": "0193aaaa-0000-7000-8000-0000000000c1", "kind": "choice", "version": 1])
        let agent = "0193aaaa-0000-7000-8000-000000000002"
        let file = try! PetMedia.prepare(name: "a.png", data: Data([0x89, 0x50, 0x4e, 0x47])).get()
        let built: [PetHTTPRequest] = [
            PetServerAPI.clientConfigRequest(e),
            .get(e.rest("/api/v1/me"), bearer: "t"),
            PetServerAPI.usageRequest(e, bearer: "t"),
            .get(e.rest("/api/v1/connections"), bearer: "t"),  // ConnectorsAPI.load (PetConnectors.swift)
            .get(e.rest("/api/v1/tools"), bearer: "t"),
            PetMedia.uploadRequest(e, bearer: "t", file: file),
            ConnectorBinding.request(e, bearer: "t", agentID: agent)!,
            PetServerAPI.historyRequest(e, bearer: "t", roomID: room, beforeSeq: 5),
            PetServerAPI.deltaRequest(e, bearer: "t", roomID: room, sinceSeq: 5),
            PetServerAPI.dictationRequest(e, bearer: "t", audio: Data([1]), mime: "audio/mp4", fileName: "d.m4a", language: "ko",
                                          durationSec: 1, boundary: "b"),
            PetServerAPI.feedbackRequest(e, bearer: "t", text: "x", kind: "correction", memoryIDs: [mem], roomID: room, agentID: nil,
                                         idempotencyKey: "k"),
            PetServerAPI.forgetRequest(e, bearer: "t", memoryID: mem, kind: "fact"),
            PetServerAPI.forgetRequest(e, bearer: "t", memoryID: mem, kind: "episode"),
            PetServerAPI.restoreRequest(e, bearer: "t", memoryID: mem),
            .get(PetServerAPI.url(e, "/api/v1/chat/requests/\(card.id)"), bearer: "t"),
            PetServerAPI.answerCardRequest(e, bearer: "t", card: card, action: "choose", optionIDs: ["a"]),
        ]
        let used = Set(built.map { PetServerContract.route($0, ids: [room, mem, card.id, agent]) })
        XCTAssertEqual(used.subtracting(PetServerContract.routes), [], "not in \(PetServerContract.specRef)")
        XCTAssertEqual(PetServerContract.routes.subtracting(used), [], "listed but never built")
    }
}
