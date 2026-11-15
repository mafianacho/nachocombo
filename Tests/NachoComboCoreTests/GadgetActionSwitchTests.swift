import XCTest
@testable import NachoComboCore

/// NACHO-239 / NACHO-131: single Mac actions switched off in the Connections tab are stored and survive a restart.
final class GadgetActionSwitchTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nacho-trust-\(UUID().uuidString)/gadget-trust.json")
    }

    func testDisabledActionsSurviveARestart() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trust = GadgetTrust(url: url, trustable: { [.clipboard] })
        trust.disabled = ["combo_window_arrange", "combo_clipboard_read"]
        let again = GadgetTrust(url: url, trustable: { [.clipboard] })
        XCTAssertEqual(again.disabled, ["combo_window_arrange", "combo_clipboard_read"])
    }

    func testDisabledAndAlwaysAllowedShareOneFileWithoutClobbering() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let trust = GadgetTrust(url: url, trustable: { [.clipboard] })
        XCTAssertTrue(trust.setAlwaysAllowed(.clipboard, true))
        trust.disabled = ["combo_window_arrange"]
        let again = GadgetTrust(url: url, trustable: { [.clipboard] })
        XCTAssertEqual(again.alwaysAllowed, [.clipboard])
        XCTAssertEqual(again.disabled, ["combo_window_arrange"])
        XCTAssertTrue(again.setAlwaysAllowed(.clipboard, false))
        XCTAssertEqual(GadgetTrust(url: url, trustable: { [.clipboard] }).disabled, ["combo_window_arrange"],
                       "switching 'always allow' off keeps the disabled actions")
    }

    func testAttachLoadsDisabledAndNotifies() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = GadgetTrust(url: url, trustable: { [] })
        first.disabled = ["combo_window_arrange"]
        let app = GadgetTrust(trustable: { [] })
        var changes = 0
        app.observe { changes += 1 }
        app.attach(url: url)
        XCTAssertEqual(app.disabled, ["combo_window_arrange"])
        XCTAssertEqual(changes, 1)
    }

    func testAFileWithoutDisabledStillLoads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"alwaysAllowed":["clipboard"]}"#.utf8).write(to: url)
        let trust = GadgetTrust(url: url, trustable: { [.clipboard] })
        XCTAssertEqual(trust.alwaysAllowed, [.clipboard])
        XCTAssertEqual(trust.disabled, [])
    }

    func testJunkNamesInTheFileAreDropped() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let long = String(repeating: "a", count: 80)
        try Data(#"{"version":2,"alwaysAllowed":[],"disabled":["combo_ok","bad name","\#(long)",""]}"#.utf8).write(to: url)
        XCTAssertEqual(GadgetTrust(url: url, trustable: { [] }).disabled, ["combo_ok"])
    }
}
