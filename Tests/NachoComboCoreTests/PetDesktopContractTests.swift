import Foundation
import XCTest
@testable import NachoComboCore

/// The connector contract with nacho-server (combo_* names, Korean descriptions of at most 200 characters, risky
/// capabilities only with `"approval": "required"`) and the parameter checks of the desktop actions. Uses only
/// `PetCommands.capabilities` / `PetCommands.parse`, so it also runs against the version before the desktop actions.
final class PetDesktopContractTests: XCTestCase {
    private func caps() -> [String: [String: Any]] {
        var byName: [String: [String: Any]] = [:]
        for c in PetCommands.capabilities { byName[c["name"] as! String] = c }
        return byName
    }

    func testHelloDeclaresTheDesktopActions() {
        let names = Set(caps().keys)
        for name in ["combo_list_apps", "combo_open_app", "combo_focus_app", "combo_hide_app", "combo_list_windows",
                     "combo_layout_windows", "combo_set_system", "combo_set_dim_strength", "combo_clear_shelf",
                     "combo_workspace_save", "combo_workspace_apply", "combo_workspace_list",
                     "combo_arrange_window", "combo_set_gadget", "combo_list_gadgets"] {
            XCTAssertTrue(names.contains(name), "\(name) is not declared")
        }
        // Risky and not approved on the server yet: not declared at all.
        XCTAssertFalse(names.contains("combo_quit_app"))
    }

    func testEveryDescriptionIsShortKoreanAndEverySchemaIsAnObject() {
        for (name, c) in caps() {
            XCTAssertTrue(name.hasPrefix("combo_"), name)
            XCTAssertTrue(name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil, name)
            let d = c["description"] as? String ?? ""
            XCTAssertLessThanOrEqual(d.count, 200, "\(name): \(d.count) characters")
            XCTAssertGreaterThanOrEqual(d.count, 30, "\(name): too short to choose by")
            let hangul = d.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
            XCTAssertGreaterThan(hangul * 2, d.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count,
                                 "\(name): description is not mostly Korean")
            let schema = c["input_schema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", name)
            XCTAssertNotNil(schema?["properties"] as? [String: Any], name)
            XCTAssertNil(c["approval"], "\(name) asks for approval but is declared without the server's approval card")
            XCTAssertTrue(JSONSerialization.isValidJSONObject(c), name)
        }
    }

    private func refused(_ capability: String, _ params: Any?, file: StaticString = #filePath, line: UInt = #line) {
        switch PetCommands.parse(capability: capability, params: params) {
        case .success(let command): XCTFail("\(capability) \(String(describing: params)) accepted as \(command)", file: file, line: line)
        case .failure(.badParams): break
        case .failure(let other): XCTFail("\(capability): expected bad parameters, got \(other)", file: file, line: line)
        }
    }

    func testNewCapabilitiesRefuseBadParameters() {
        refused("combo_open_app", [:])
        refused("combo_open_app", ["app": 5])
        refused("combo_open_app", ["app": "   "])
        refused("combo_open_app", ["app": String(repeating: "가", count: 101)])
        refused("combo_open_app", ["app": "Safari\nrm"])
        refused("combo_open_app", ["app": "Safari", "path": "/bin/sh"])
        refused("combo_focus_app", ["app": ["Safari"]])
        refused("combo_hide_app", nil)
        refused("combo_open_app", "Safari")
        refused("combo_list_apps", ["installed": "yes"])
        refused("combo_list_apps", ["installed": 1])
        refused("combo_set_system", [:])
        refused("combo_set_system", ["volume": 101])
        refused("combo_set_system", ["volume": -1])
        refused("combo_set_system", ["volume": 55.5])
        refused("combo_set_system", ["volume": "50"])
        refused("combo_set_system", ["volume": true])
        refused("combo_set_system", ["brightness": 200])
        refused("combo_set_system", ["dnd": 1])
        refused("combo_set_system", ["volume": 30, "mute": true])
        refused("combo_set_dim_strength", ["percent": 5])
        refused("combo_set_dim_strength", ["percent": 95])
        refused("combo_clear_shelf", ["all": true])
        refused("combo_list_windows", ["titles": true])
        refused("combo_layout_windows", [:])
        refused("combo_layout_windows", ["items": []])
        refused("combo_layout_windows", ["items": [["app": "Safari"]]])
        refused("combo_layout_windows", ["items": [["app": "Safari", "position": "next-display"]]])
        refused("combo_layout_windows", ["items": [["app": "Safari", "position": "left", "display": 0]]])
        refused("combo_layout_windows", ["items": [["app": "Safari", "position": "left", "display": 1.5]]])
        refused("combo_layout_windows", ["items": [["app": "Safari", "position": "left", "click": [10, 10]]]])
        refused("combo_layout_windows", ["items": [["app": "Safari", "position": "left"], ["app": "safari", "position": "right"]]])
        refused("combo_layout_windows", ["items": Array(repeating: ["app": "Notes", "position": "left"], count: 9)])
        refused("combo_workspace_save", [:])
        refused("combo_workspace_save", ["name": ""])
        refused("combo_workspace_save", ["name": String(repeating: "a", count: 41)])
        refused("combo_workspace_save", ["name": "업무\n모드"])
        refused("combo_workspace_apply", ["name": 3])
    }

    func testQuitIsRefusedWhileTheServerCannotAskForApproval() {
        XCTAssertEqual(PetCommands.parse(capability: "combo_quit_app", params: ["app": "Safari"]),
                       .failure(.notAllowed("quitting apps is switched off in this Nacho Combo until the server asks the user to approve it")))
    }

    func testGoodParametersFromServerJSON() {
        let json = try! JSONSerialization.jsonObject(with: Data(#"{"volume":40,"brightness":70.0,"dnd":false}"#.utf8))
        if case .failure(let p) = PetCommands.parse(capability: "combo_set_system", params: json) { XCTFail("\(p)") }
        let layout = try! JSONSerialization.jsonObject(with: Data(
            #"{"items":[{"app":"사파리","position":"left"},{"app":"Notes","position":"right","display":2,"window":1}]}"#.utf8))
        if case .failure(let p) = PetCommands.parse(capability: "combo_layout_windows", params: layout) { XCTFail("\(p)") }
        let flag = try! JSONSerialization.jsonObject(with: Data(#"{"installed":true}"#.utf8))
        if case .failure(let p) = PetCommands.parse(capability: "combo_list_apps", params: flag) { XCTFail("\(p)") }
        let number = try! JSONSerialization.jsonObject(with: Data(#"{"volume":true}"#.utf8))
        if case .success = PetCommands.parse(capability: "combo_set_system", params: number) { XCTFail("JSON true read as a volume") }
        let one = try! JSONSerialization.jsonObject(with: Data(#"{"dnd":1}"#.utf8))
        if case .success = PetCommands.parse(capability: "combo_set_system", params: one) { XCTFail("JSON 1 read as a boolean") }
    }
}
