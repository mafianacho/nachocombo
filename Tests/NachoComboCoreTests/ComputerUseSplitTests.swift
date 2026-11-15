import XCTest
@testable import NachoComboCore

/// NACHO-195: the Computer Use gadget is one switch (Nacho's), the MCP server is its own switch, and the old saved
/// values keep working.
final class ComputerUseSplitTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nc-split-\(UUID().uuidString)/settings.json")
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    // MARK: switching on asks only for what is missing

    func testSwitchOnRequestsOnlyMissingPermissions() {
        XCTAssertEqual(ComputerUseGadgetPermissions.toRequest(granted: { _ in true }), [], "both granted: nothing asked")
        XCTAssertEqual(ComputerUseGadgetPermissions.toRequest(granted: { $0 == .screenRecording }), [.accessibility], "only Accessibility missing")
        XCTAssertEqual(ComputerUseGadgetPermissions.toRequest(granted: { $0 == .accessibility }), [.screenRecording], "only Screen Recording missing")
        XCTAssertEqual(ComputerUseGadgetPermissions.toRequest(granted: { _ in false }), [.accessibility, .screenRecording], "both missing")
        XCTAssertEqual(ComputerUseGadgetPermissions.toRequest(granted: { _ in false }, alreadyRequested: [.accessibility]), [.screenRecording],
                       "one that was already asked since the switch went on is not asked again")
    }

    func testOneLinePerMissingPermission() {
        XCTAssertEqual(ComputerUseGadgetPermissions.line(for: .accessibility), "Accessibility permission is needed")
        XCTAssertEqual(ComputerUseGadgetPermissions.missing(granted: { $0 == .accessibility }), [.screenRecording])
        XCTAssertEqual(ComputerUseGadgetPermissions.missing(granted: { _ in true }), [], "a granted permission shows no line")
    }

    // MARK: gadget on brings Nacho's tool groups, never the risky ones

    func testSwitchingTheGadgetOnTurnsOnTheDefaultGroupsOnly() {
        let manager = ModuleManager(store: SettingsStore(url: tempURL()), modules: [FakeModule(.computerUse)])
        _ = manager.setEnabled(.computerUse, true)
        let on = manager.settings.computerUse
        for group in ToolGroup.allCases { XCTAssertEqual(on.isEnabled(group), !group.isHighRisk, "\(group)") }
        XCTAssertFalse(on.serverEnabled, "the gadget switch never opens the external port")
    }

    func testGadgetOnKeepsGroupChoicesTheUserAlreadyMade() throws {
        let url = tempURL()
        try write(#"{"version":1,"enabledModules":{},"menuBarCollapsed":false,"computerUse":{"enabledGroups":{"screen":true,"input":false}}}"#, to: url)
        let manager = ModuleManager(store: SettingsStore(url: url), modules: [FakeModule(.computerUse)])
        _ = manager.setEnabled(.computerUse, true)
        XCTAssertTrue(manager.settings.computerUse.isEnabled(.screen))
        XCTAssertFalse(manager.settings.computerUse.isEnabled(.input), "an explicit off stays off")
        XCTAssertFalse(manager.settings.computerUse.isEnabled(.clipboard))
    }

    // MARK: saved values

    func testOldSettingsKeepPortLanGroupsAndTheGadgetBringsTheServerOn() throws {
        let url = tempURL()
        try write(#"{"version":1,"enabledModules":{"computerUse":true},"menuBarCollapsed":false,"computerUse":{"port":50123,"listenMode":"lan","allowedHosts":["tunnel.example"],"enabledGroups":{"screen":true,"shell":true,"input":false}}}"#, to: url)
        let s = SettingsStore(url: url).load()
        XCTAssertEqual(s.computerUse.port, 50123)
        XCTAssertEqual(s.computerUse.listenMode, .lan)
        XCTAssertEqual(s.computerUse.allowedHosts, ["tunnel.example"])
        XCTAssertTrue(s.computerUse.isEnabled(.screen) && s.computerUse.isEnabled(.shell) && !s.computerUse.isEnabled(.input))
        XCTAssertTrue(s.computerUse.serverEnabled, "the gadget was on, so the server stays on after the update")
    }

    func testOldSettingsWithTheGadgetOffKeepTheServerOff() throws {
        let url = tempURL()
        try write(#"{"version":1,"enabledModules":{"computerUse":false},"menuBarCollapsed":false,"computerUse":{"port":50123}}"#, to: url)
        let s = SettingsStore(url: url).load()
        XCTAssertEqual(s.computerUse.port, 50123)
        XCTAssertFalse(s.computerUse.serverEnabled)
    }

    func testAnExplicitServerSwitchIsNeverOverriddenByTheMigration() throws {
        let url = tempURL()
        try write(#"{"version":1,"enabledModules":{"computerUse":true},"menuBarCollapsed":false,"computerUse":{"serverEnabled":false}}"#, to: url)
        XCTAssertFalse(SettingsStore(url: url).load().computerUse.serverEnabled, "the user turned the server off after the update")
    }

    func testMigratedValueIsSavedAndStable() throws {
        let url = tempURL()
        try write(#"{"version":1,"enabledModules":{"computerUse":true},"menuBarCollapsed":false,"computerUse":{"port":50123}}"#, to: url)
        let store = SettingsStore(url: url)
        try store.save(store.load())
        var again = store.load()
        XCTAssertTrue(again.computerUse.serverEnabled)
        again.setEnabled(.computerUse, false)               // later the gadget goes off; the saved server switch stays
        try store.save(again)
        XCTAssertTrue(store.load().computerUse.serverEnabled)
    }

    func testKeyFileIsStillReadAfterTheSplit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nc-keys-\(UUID().uuidString)/computer-use-keys.json")
        let first = APIKeyStore(url: url, random: CountingRandom())
        let issued = try first.create(label: "Laptop")
        let second = APIKeyStore(url: url, random: CountingRandom())
        XCTAssertEqual(second.records.map { $0.label }, ["Laptop"])
        XCTAssertNotNil(second.authenticate(token: issued.token))
    }

    // MARK: independence

    func testServerOffGadgetOnKeepsNachoRunningAndThePortClosed() {
        var s = ComputerUseSettings()
        s.serverEnabled = false
        XCTAssertEqual(s.serverDecision(gadgetOn: true, emergencyStopped: false), .closed, "no external port")
        XCTAssertTrue(ComputerUseSettings.nachoPathAvailable(gadgetOn: true, emergencyStopped: false), "Nacho still works")
    }

    func testServerOnWorksWithTheGadgetOffButWithoutComputerTools() {
        var s = ComputerUseSettings(); s.serverEnabled = true
        s.setEnabled(.screen, true)
        XCTAssertEqual(s.serverDecision(gadgetOn: false, emergencyStopped: false), .openGadgetToolsOnly)
        XCTAssertEqual(s.serverDecision(gadgetOn: true, emergencyStopped: false), .openWithComputerTools)
        XCTAssertTrue(s.withoutComputerGroups().enabledToolGroups.isEmpty)
        XCTAssertTrue(s.withoutComputerGroups().serverEnabled)
    }

    func testEmergencyStopClosesBothAtOnce() {
        var s = ComputerUseSettings(); s.serverEnabled = true
        XCTAssertEqual(s.serverDecision(gadgetOn: true, emergencyStopped: true), .closed)
        XCTAssertFalse(ComputerUseSettings.nachoPathAvailable(gadgetOn: true, emergencyStopped: true))
    }

    // MARK: per-gadget exposure

    func testGadgetExposureSavesAndShowsInToolsList() throws {
        let url = tempURL()
        let manager = ModuleManager(store: SettingsStore(url: url), modules: [])
        manager.setComputerUse { $0.serverEnabled = true; $0.setGadgetEnabled(.window, true) }
        let reloaded = SettingsStore(url: url).load().computerUse
        XCTAssertTrue(reloaded.isGadgetEnabled(.window))
        XCTAssertFalse(reloaded.isGadgetEnabled(.monitor))

        let keys = APIKeyStore(url: nil, random: CountingRandom())
        let token = try keys.create(label: "Test Key").token
        var current = reloaded
        let service = NachoComboMCPService(settings: { current }, keys: keys, backend: FakeBackend(), gadgets: GadgetToolDispatcher())
        func names() -> [String] {
            let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#
            let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                               body: Data(body.utf8)), peer: "127.0.0.1")
            let o = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
            return (((o?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        }
        XCTAssertTrue(names().contains("window_arrange"))
        XCTAssertFalse(names().contains { $0.hasPrefix("monitor_") })
        current.setGadgetEnabled(.window, false)
        XCTAssertFalse(names().contains("window_arrange"))
    }
}
