import XCTest
@testable import NachoComboCore

/// NACHO-151: gadget detail shows each action's risk and the "이 가젯은 항상 허용" switch (stored, declared again, no effect on destructive).
final class GadgetAlwaysAllowDetailTests: XCTestCase {
    private let content = GadgetTool(gadget: .clipboard, action: "t_read", korean: "시험용으로 클립보드 글을 나초에게 보내요.", english: "Read clipboard.", output: "text", risk: .contentOut)
    private let wipe = GadgetTool(gadget: .clipboard, action: "t_wipe", korean: "시험용으로 클립보드 기록을 지워요.", english: "Wipe history.", output: "ok", risk: .destructive)
    private let look = GadgetTool(gadget: .clipboard, action: "t_count", korean: "시험용으로 기록 개수를 세요.", english: "Count.", output: "n", risk: .read)
    private let plain = GadgetTool(gadget: .window, action: "t_arrange", korean: "시험용으로 창을 정리해요.", english: "Arrange.", output: "ok", risk: .change)
    private var tools: [GadgetTool] { [content, wipe, look, plain] }

    private func detail(_ g: GadgetID, always: Set<GadgetID> = [], disabled: Set<String> = []) -> ConnectionsDetail {
        ConnectionsDetailBuilder.gadget(GadgetSwitchState(id: g, phase: .on), disabled: disabled, alwaysAllowed: always, tools: tools)
    }

    func testRiskTextPerAction() {
        let d = detail(.clipboard)
        func text(_ t: GadgetTool) -> String?? { d.abilities.first { $0.id == t.connectorName }.map { $0.riskText } }
        XCTAssertEqual(text(content), .some("보내기 전에 매번 물어봐요"))
        XCTAssertEqual(text(wipe), .some("매번 물어봐요(항상 허용 안 됨)"))
        XCTAssertEqual(text(look), .some(nil))
        XCTAssertEqual(d.abilities.map { $0.id }, tools.filter { $0.gadget == .clipboard }.map { $0.connectorName }, "list matches the registry")
    }

    func testAlwaysAllowOnlyForGadgetsWithContentActions() {
        XCTAssertNotNil(detail(.clipboard).alwaysAllow)
        XCTAssertNil(detail(.window).alwaysAllow)
        XCTAssertFalse(detail(.clipboard).alwaysAllow!.isOn, "default off")
        XCTAssertTrue(detail(.clipboard, always: [.clipboard]).alwaysAllow!.isOn)
        XCTAssertTrue(detail(.clipboard).alwaysAllow!.confirmText.contains("묻지 않고"))
    }

    func testAlwaysAllowedChangesTextButNotDestructive() {
        let d = detail(.clipboard, always: [.clipboard])
        XCTAssertEqual(d.abilities.first { $0.id == content.connectorName }?.riskText, "이 가젯은 항상 허용이라 묻지 않고 해요")
        XCTAssertEqual(d.abilities.first { $0.id == wipe.connectorName }?.riskText, "매번 물어봐요(항상 허용 안 됨)")
    }

    func testSwitchStoresRedeclaresAndDropsApproval() {
        let trust = GadgetTrust(trustable: { GadgetToolRegistry.trustableGadgets(in: self.tools) })
        var redeclared = 0
        trust.observe { redeclared += 1 }
        func approval(_ t: GadgetTool) -> String? {
            let caps = PetCommands.capabilities(allowQuit: true, alwaysAllowed: trust.alwaysAllowed, disabled: trust.disabled, tools: tools)
            return caps.first { $0["name"] as? String == t.declaredConnectorName }?["approval"] as? String
        }
        XCTAssertEqual(approval(content), "required")
        XCTAssertTrue(trust.setAlwaysAllowed(.clipboard, true))
        XCTAssertEqual(redeclared, 1)
        XCTAssertNil(approval(content), "approval gone")
        XCTAssertEqual(approval(wipe), "required", "destructive unaffected")
        XCTAssertTrue(trust.setAlwaysAllowed(.clipboard, false))
        XCTAssertEqual(redeclared, 2)
        XCTAssertEqual(approval(content), "required", "back to every time")
    }

    func testSingleActionOffDropsItFromDeclaration() {
        let trust = GadgetTrust(trustable: { [.clipboard] })
        trust.setActionEnabled(content, false)
        let caps = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: trust.disabled, tools: tools)
        XCTAssertNil(caps.first { $0["name"] as? String == content.declaredConnectorName })
        XCTAssertFalse(detail(.clipboard, disabled: trust.disabled).abilities.first { $0.id == content.connectorName }!.isOn!)
    }
}
