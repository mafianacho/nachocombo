import Foundation
import XCTest
@testable import NachoComboCore

// NACHO-150: Keep Awake, Focus Dim, Device Control, Mouse Tune, App Switch, Calendar Clock tools.

private final class FakePort: SettingsGadgetsPort {
    var opts = GadgetOptions.defaults
    var awakeState = AwakeSnapshot(holding: false, manual: false, secondsLeft: nil, reason: "Sleeps as usual", keepDisplay: true, powerOnly: false, batteryFloor: 20)
    var dimState = DimSnapshot(paused: false, percent: 50, scope: "frontWindow", otherDisplays: true, onlyInSession: false)
    var deviceState = SoundSnapshot(outputName: "Speakers", volumePercent: 40, inputName: "Mic", micMuted: false)
    var deviceAnswer: (Bool, String) = (true, "set")
    private(set) var calls: [String] = []

    func options() -> GadgetOptions { opts }
    func apply(options: GadgetOptions) { calls.append("apply"); opts = options }
    func awake() -> AwakeSnapshot { awakeState }
    func awakeHold(minutes: Int) {
        calls.append("hold(\(minutes))")
        awakeState.holding = true; awakeState.manual = true; awakeState.secondsLeft = minutes > 0 ? minutes * 60 : nil
    }
    func awakeStop() { calls.append("stop"); awakeState.holding = false; awakeState.manual = false; awakeState.secondsLeft = nil }
    func dim() -> DimSnapshot { dimState }
    func dimSetPaused(_ paused: Bool) { calls.append("paused(\(paused))"); dimState.paused = paused }
    func device() -> SoundSnapshot { deviceState }
    func deviceSetOutput(volumePercent: Int?, muted: Bool?) -> (Bool, String) {
        calls.append("output(\(volumePercent.map(String.init) ?? "-"),\(muted.map(String.init) ?? "-"))"); return deviceAnswer
    }
    func deviceSetMicMuted(_ muted: Bool) { calls.append("mic(\(muted))"); deviceState.micMuted = muted }
}

private let allTools = AwakeTools.tools + DimTools.tools + DeviceTools.tools + MouseTools.tools + AppSwitchTools.tools + CalendarTools.tools
private func tool(_ name: String) -> GadgetTool { allTools.first { $0.mcpName == name }! }

private func call(_ port: FakePort, _ name: String, _ args: [String: JSONValue] = [:]) -> PetCommandOutcome {
    var result: PetCommandOutcome?
    var count = 0
    SettingsGadgetToolRunner(port: port, onMain: { $0() }).run(tool(name), arguments: args) { result = $0; count += 1 }
    XCTAssertEqual(count, 1, "done must be called exactly once")
    return result!
}

final class SettingsGadgetsRegistryTests: XCTestCase {
    func testToolsAreRegisteredWithRisks() {
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
        let names = Set(GadgetToolRegistry.all.map { $0.mcpName })
        for n in ["awake_status", "awake_start", "awake_stop", "dim_status", "dim_set_strength", "dim_pause", "dim_resume",
                  "device_status", "device_set_volume", "device_set_mic_muted", "device_set", "mouse_status", "mouse_set",
                  "appswitch_settings", "appswitch_set_settings", "appswitch_list", "calendar_status", "calendar_set"] {
            XCTAssertTrue(names.contains(n), n)
        }
        for n in ["awake_status", "dim_status", "device_status", "mouse_status", "appswitch_settings", "calendar_status"] {
            XCTAssertEqual(tool(n).risk, .read, n)
        }
        for n in ["awake_start", "awake_stop", "dim_pause", "dim_resume", "device_set_volume", "device_set_mic_muted", "mouse_set", "appswitch_set_settings", "calendar_set"] {
            XCTAssertEqual(tool(n).risk, .change, n)
            XCTAssertTrue(tool(n).requiresGadgetOn, n)
        }
        // no tool of this lane reads calendar content, so none is content_out
        XCTAssertFalse(CalendarTools.tools.contains { $0.risk == .contentOut })
    }

    func testOldNamesStayAndGuidesExist() {
        XCTAssertEqual(tool("dim_set_strength").connectorNames.contains(PetCommands.setDimStrength), true)
        XCTAssertFalse(tool("dim_set_strength").requiresGadgetOn)
        XCTAssertTrue(tool("device_set").connectorNames.contains(PetCommands.setSystem))
        for g in SettingsGadgetToolRunner.gadgets {
            let guide = GadgetToolRegistry.guide(for: g)
            XCTAssertNotNil(guide, g.rawValue)
            XCTAssertEqual(GadgetToolRegistry.guide(for: g)?.gadget, g)
            XCTAssertEqual(g.guideURI, "nachocombo://gadgets/\(g.rawValue)/guide")
            XCTAssertFalse(GadgetToolRegistry.prompts.filter { $0.gadget == g }.isEmpty, "\(g.rawValue) needs a prompt")
            let text = guide!.render(for: .mcp)
            XCTAssertTrue(text.contains("\(g.rawValue)_"), g.rawValue)
        }
        XCTAssertTrue(GadgetToolRegistry.prompts.map { $0.name }.contains("awake_presentation"))
    }
}

final class SettingsGadgetsRunnerTests: XCTestCase {
    func testAwakeStatusSerializes() {
        let port = FakePort()
        let out = call(port, "awake_status")
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.details?["holding"] as? Bool, false)
        XCTAssertEqual(out.details?["battery_floor_percent"] as? Int, 20)
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: out.resultJSON))
    }

    func testAwakeStartAndStopValidateMinutes() {
        let port = FakePort()
        let started = call(port, "awake_start", ["minutes": .int(90)])
        XCTAssertTrue(started.ok)
        XCTAssertEqual(started.details?["seconds_left"] as? Int, 5400)
        XCTAssertEqual(port.calls, ["hold(90)"])
        XCTAssertFalse(call(FakePort(), "awake_start", ["minutes": .int(1441)]).ok)
        XCTAssertFalse(call(FakePort(), "awake_start", ["minutes": .int(-1)]).ok)
        XCTAssertFalse(call(FakePort(), "awake_start", ["minutes": .string("60")]).ok)
        XCTAssertFalse(call(FakePort(), "awake_start", ["hours": .int(1)]).ok)
        XCTAssertEqual(call(port, "awake_start").details?["holding"] as? Bool, true)
        XCTAssertTrue(call(port, "awake_stop").ok)
        XCTAssertEqual(port.awakeState.holding, false)
    }

    func testRejectedArgumentsNeverTouchThePort() {
        let port = FakePort()
        XCTAssertFalse(call(port, "awake_start", ["minutes": .int(9999)]).ok)
        XCTAssertFalse(call(port, "mouse_set", ["speed": .double(9)]).ok)
        XCTAssertFalse(call(port, "mouse_set", ["middle_button": .string("rm -rf")]).ok)
        XCTAssertFalse(call(port, "mouse_set", [:]).ok)
        XCTAssertFalse(call(port, "device_set_volume", ["volume": .int(101)]).ok)
        XCTAssertFalse(call(port, "device_set_volume", [:]).ok)
        XCTAssertFalse(call(port, "calendar_set", ["hours": .string("thirty")]).ok)
        XCTAssertFalse(call(port, "calendar_set", ["world_clocks": .array([.string("Nowhere/City")])]).ok)
        XCTAssertFalse(call(port, "appswitch_set_settings", ["hide_on_repeat": .string("yes")]).ok)
        XCTAssertFalse(call(port, "dim_pause", ["x": .int(1)]).ok)
        XCTAssertEqual(port.calls, [])
    }

    func testDimStatusPauseResume() {
        let port = FakePort()
        XCTAssertEqual(call(port, "dim_status").details?["strength_percent"] as? Int, 50)
        XCTAssertEqual(call(port, "dim_pause").details?["paused"] as? Bool, true)
        XCTAssertEqual(call(port, "dim_resume").details?["paused"] as? Bool, false)
        XCTAssertEqual(port.calls, ["paused(true)", "paused(false)"])
    }

    func testDeviceReadAndSafeChanges() {
        let port = FakePort()
        let status = call(port, "device_status")
        XCTAssertEqual(status.details?["volume"] as? Int, 40)
        XCTAssertEqual(status.details?["mic_muted"] as? Bool, false)
        XCTAssertTrue(call(port, "device_set_volume", ["volume": .int(30), "muted": .bool(false)]).ok)
        XCTAssertEqual(call(port, "device_set_mic_muted", ["muted": .bool(true)]).details?["mic_muted"] as? Bool, true)
        XCTAssertEqual(port.calls, ["output(30,false)", "mic(true)"])
        port.deviceAnswer = (false, "no volume control")
        let failed = call(port, "device_set_volume", ["volume": .int(10)])
        XCTAssertFalse(failed.ok)
        XCTAssertEqual(failed.message, "no volume control")
        // nothing here switches devices or touches Do Not Disturb (only the old `set` knows dnd)
        XCTAssertEqual(Set(DeviceTools.tools.map { $0.action }), ["set", "status", "set_volume", "set_mic_muted"])
    }

    func testMouseSetChangesOnlyGivenItems() {
        let port = FakePort()
        let out = call(port, "mouse_set", ["reverse_scroll": .bool(false), "speed": .double(1.5), "middle_button": .string("missionControl")])
        XCTAssertTrue(out.ok)
        XCTAssertEqual(port.opts.mouseReverse, false)
        XCTAssertEqual(port.opts.mouseSpeed, 1.5)
        XCTAssertEqual(port.opts.mouseMiddle, .missionControl)
        XCTAssertEqual(port.opts.mouseSmooth, GadgetOptions.defaults.mouseSmooth)
        XCTAssertEqual(out.details?["speed"] as? Double, 1.5)
        XCTAssertTrue(call(port, "mouse_set", ["speed": .int(2)]).ok)
        XCTAssertEqual(port.opts.mouseSpeed, 2)
        XCTAssertEqual(call(port, "mouse_status").details?["middle_button"] as? String, "missionControl")
    }

    func testAppSwitchSettings() {
        let port = FakePort()
        port.opts.appShortcuts = [AppHotKey(bundleID: "com.apple.Safari", name: "Safari", shortcut: nil)]
        let status = call(port, "appswitch_settings")
        XCTAssertEqual(status.details?["hide_on_repeat"] as? Bool, true)
        XCTAssertEqual((status.details?["shortcut_apps"] as? [String]) ?? [], [])
        XCTAssertEqual(call(port, "appswitch_set_settings", ["hide_on_repeat": .bool(false)]).details?["hide_on_repeat"] as? Bool, false)
        XCTAssertEqual(port.opts.appHideOnRepeat, false)
    }

    func testCalendarClockSettingsAndWorldClocks() {
        let port = FakePort()
        let out = call(port, "calendar_set", ["show_seconds": .bool(true), "hours": .string("twentyFour"),
                                             "world_clocks": .array([.string("Asia/Seoul"), .string("Asia/Seoul"), .string("America/New_York")])])
        XCTAssertTrue(out.ok)
        XCTAssertEqual(port.opts.clockSeconds, true)
        XCTAssertEqual(port.opts.clockHours, .twentyFour)
        XCTAssertEqual(port.opts.worldClocks, ["Asia/Seoul", "America/New_York"])
        let seven = (0..<7).map { _ in JSONValue.string("Asia/Seoul") }
        XCTAssertFalse(call(port, "calendar_set", ["world_clocks": .array(seven)]).ok)
        XCTAssertEqual(port.opts.worldClocks.count, 2)
        XCTAssertTrue(call(port, "calendar_set", ["world_clocks": .array([])]).ok)
        XCTAssertEqual(port.opts.worldClocks, [])
        XCTAssertEqual(call(port, "calendar_status").details?["hours"] as? String, "twentyFour")
    }

    func testGadgetOffAnswersWithoutRunning() {
        let port = FakePort()
        let dispatcher = GadgetToolDispatcher(gadgetIsOn: { $0 != .mouse && $0 != .awake }, permissionGranted: { _ in true })
        dispatcher.register(SettingsGadgetToolRunner(port: port, onMain: { $0() }), for: SettingsGadgetToolRunner.gadgets)
        for name in ["mouse_set", "awake_start", "awake_status"] {
            let args: [String: JSONValue] = name == "mouse_set" ? ["smooth_scroll": .bool(false)] : [:]
            let out = dispatcher.runAndWait(tool(name), arguments: args, exit: .connector, timeout: 2)
            XCTAssertFalse(out.ok, name)
            XCTAssertEqual(out.details?["reason"] as? String, "gadget_off", name)
        }
        XCTAssertEqual(port.calls, [])
        XCTAssertTrue(dispatcher.runAndWait(tool("calendar_status"), arguments: [:], exit: .connector, timeout: 2).ok)
    }

    func testDeallocatedPortAnswersOnce() {
        var port: FakePort? = FakePort()
        let runner = SettingsGadgetToolRunner(port: port!, onMain: { $0() })
        port = nil
        var count = 0
        var ok = true
        runner.run(tool("awake_status"), arguments: [:]) { ok = $0.ok; count += 1 }
        XCTAssertEqual(count, 1)
        XCTAssertFalse(ok)
    }
}

/// The real MCP server in front of the six gadgets: one tools/call each (no AppKit).
final class SettingsGadgetsMCPRoundTripTests: XCTestCase {
    private var settings = ComputerUseSettings()
    private var service: NachoComboMCPService!
    private var token = ""
    private var log: [String] = []
    private let port = FakePort()

    override func setUpWithError() throws {
        let keys = APIKeyStore(url: nil, random: CountingRandom())
        token = try keys.create(label: "Test Key").token
        let dispatcher = GadgetToolDispatcher(gadgetIsOn: { _ in true }, permissionGranted: { _ in true })
        dispatcher.register(SettingsGadgetToolRunner(port: port, onMain: { $0() }), for: SettingsGadgetToolRunner.gadgets)
        service = NachoComboMCPService(settings: { [unowned self] in self.settings }, keys: keys, backend: FakeBackend(), gadgets: dispatcher)
    }

    private func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> [String: Any] {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                           body: Data(body.utf8)), peer: "127.0.0.1")
        let text = String(decoding: r.body, as: UTF8.self)
        log.append("> \(method) \(params)")
        log.append("< \(r.status) \(text.count > 200 ? String(text.prefix(200)) + "…" : text)")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    func testEachGadgetAnswersToolsCall() {
        for g in SettingsGadgetToolRunner.gadgets { settings.setGadgetEnabled(g, true) }
        let names = Set((((rpc(1, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
        XCTAssertTrue(names.isSuperset(of: ["awake_start", "dim_pause", "device_set_volume", "mouse_set", "appswitch_set_settings", "calendar_set"]))
        let calls: [(String, String)] = [
            ("awake_start", #"{"minutes":30}"#), ("dim_status", "{}"), ("device_status", "{}"),
            ("mouse_set", #"{"speed":2}"#), ("appswitch_settings", "{}"), ("calendar_set", #"{"show_seconds":true}"#),
        ]
        for (i, call) in calls.enumerated() {
            let r = rpc(10 + i, "tools/call", #"{"name":"\#(call.0)","arguments":\#(call.1)}"#)
            XCTAssertEqual((r["result"] as? [String: Any])?["isError"] as? Bool, false, call.0)
        }
        let guide = rpc(30, "resources/read", #"{"uri":"nachocombo://gadgets/calendar/guide"}"#)
        XCTAssertTrue(String(describing: guide).contains("calendar_set"))
        let bad = rpc(31, "tools/call", #"{"name":"awake_start","arguments":{"minutes":5000}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(port.opts.mouseSpeed, 2)
        XCTAssertFalse(log.joined().contains(token))
        print("MCP-ROUNDTRIP six gadgets (Authorization: Bearer ****)\n" + log.joined(separator: "\n"))
    }
}
