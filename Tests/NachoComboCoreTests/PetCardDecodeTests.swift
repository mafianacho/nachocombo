import Foundation
import XCTest

@testable import NachoComboCore

/// Cards the chat answers by kind (spec/cards.tsp). Written against the old card model too: on the base commit these
/// fail (approvals were left to the phone and a rule proposal showed the raw kind with no choices).
final class PetCardDecodeTests: XCTestCase {
    func testApprovalsChoicesSuggestionsAndRuleProposalsAreAnsweredHereInputCardsAreNot() {
        for kind in ["approval", "choice", "suggestions", "rule_proposal"] {
            XCTAssertTrue(PetCard.decode(["id": "c", "kind": kind, "status": "pending", "payload": [:]]).answerableHere, kind)
        }
        for kind in ["login", "otp", "security_code", "payment_card", "browser", "connection", "connections"] {
            XCTAssertFalse(PetCard.decode(["id": "c", "kind": kind, "status": "pending", "payload": [:]]).answerableHere, kind)
        }
    }

    func testRuleProposalReadsItsRuleOptions() {
        let c = PetCard.decode(["id": "r1", "kind": "rule_proposal", "status": "pending", "version": 1,
                                "payload": ["said_text": "3만 원까지 괜찮아",
                                            "rule_options": [["id": "o1", "summary": "배달앱에서 건당 30,000원 이하", "action_type": "payment",
                                                              "expires_at": "2026-12-13T00:00:00Z"]]]])
        XCTAssertEqual(c.options.map { $0.label }, ["배달앱에서 건당 30,000원 이하"])
        XCTAssertEqual(c.options.map { $0.id }, ["o1"])
        XCTAssertNotEqual(c.title, "rule_proposal", "never the raw kind as the question")
    }
}
