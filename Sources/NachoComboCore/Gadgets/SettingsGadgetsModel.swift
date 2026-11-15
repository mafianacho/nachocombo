import Foundation

// NACHO-150: tools of Keep Awake, Focus Dim, Device Control, Mouse Tune, App Switch and Calendar Clock.
// This file is the testable core: argument validation against closed lists and the result shapes. The app side
// (`Sources/NachoCombo/SettingsGadgetsMCP.swift`) implements `SettingsGadgetsPort` with the real modules.

/// Keep Awake as the tools see it.
public struct AwakeSnapshot: Equatable {
    public var holding: Bool
    public var manual: Bool
    /// Seconds left of a timed hold (nil = no end or not holding).
    public var secondsLeft: Int?
    public var reason: String
    public var keepDisplay: Bool
    public var powerOnly: Bool
    public var batteryFloor: Int
    public init(holding: Bool, manual: Bool, secondsLeft: Int?, reason: String, keepDisplay: Bool, powerOnly: Bool, batteryFloor: Int) {
        self.holding = holding; self.manual = manual; self.secondsLeft = secondsLeft; self.reason = reason
        self.keepDisplay = keepDisplay; self.powerOnly = powerOnly; self.batteryFloor = batteryFloor
    }
}

public struct DimSnapshot: Equatable {
    public var paused: Bool
    public var percent: Int
    public var scope: String
    public var otherDisplays: Bool
    public var onlyInSession: Bool
    public init(paused: Bool, percent: Int, scope: String, otherDisplays: Bool, onlyInSession: Bool) {
        self.paused = paused; self.percent = percent; self.scope = scope
        self.otherDisplays = otherDisplays; self.onlyInSession = onlyInSession
    }
}

public struct SoundSnapshot: Equatable {
    public var outputName: String?
    public var volumePercent: Int?
    public var inputName: String?
    public var micMuted: Bool
    public init(outputName: String?, volumePercent: Int?, inputName: String?, micMuted: Bool) {
        self.outputName = outputName; self.volumePercent = volumePercent; self.inputName = inputName; self.micMuted = micMuted
    }
}

/// What the runner needs from the app. Every method is called on the main thread.
public protocol SettingsGadgetsPort: AnyObject {
    func options() -> GadgetOptions
    func apply(options: GadgetOptions)
    func awake() -> AwakeSnapshot
    func awakeHold(minutes: Int)
    func awakeStop()
    func dim() -> DimSnapshot
    func dimSetPaused(_ paused: Bool)
    func device() -> SoundSnapshot
    /// Volume and/or mute of the current sound output. Returns (ok, message).
    func deviceSetOutput(volumePercent: Int?, muted: Bool?) -> (Bool, String)
    func deviceSetMicMuted(_ muted: Bool)
}

/// Argument checks shared by the tools: only known keys, exact types, closed ranges.
enum SettingsArgs {
    struct Bad: Error { let text: String }

    static func check(_ args: [String: JSONValue], allowed: Set<String>, atLeastOne: Bool = false) throws {
        let extra = Set(args.keys).subtracting(allowed)
        if !extra.isEmpty { throw Bad(text: "unknown field \(extra.sorted().joined(separator: ", "))") }
        if atLeastOne && args.isEmpty { throw Bad(text: "give at least one of \(allowed.sorted().joined(separator: ", "))") }
    }

    static func bool(_ args: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let v = args[key] else { return nil }
        guard case .bool(let b) = v else { throw Bad(text: "\(key) must be true or false") }
        return b
    }

    static func int(_ args: [String: JSONValue], _ key: String, _ range: ClosedRange<Int>) throws -> Int? {
        guard let v = args[key] else { return nil }
        let n: Int
        switch v {
        case .int(let i): n = i
        case .double(let d) where d == d.rounded() && abs(d) < 1e9: n = Int(d)
        default: throw Bad(text: "\(key) must be a whole number")
        }
        guard range.contains(n) else { throw Bad(text: "\(key) must be \(range.lowerBound)-\(range.upperBound)") }
        return n
    }

    static func choice(_ args: [String: JSONValue], _ key: String, _ allowed: [String]) throws -> String? {
        guard let v = args[key] else { return nil }
        guard case .string(let s) = v, allowed.contains(s) else { throw Bad(text: "\(key) must be one of \(allowed.joined(separator: ", "))") }
        return s
    }

    static func number(_ args: [String: JSONValue], _ key: String, _ allowed: [Double]) throws -> Double? {
        guard let v = args[key] else { return nil }
        let d: Double
        switch v {
        case .int(let i): d = Double(i)
        case .double(let x): d = x
        default: throw Bad(text: "\(key) must be a number")
        }
        guard allowed.contains(d) else {
            throw Bad(text: "\(key) must be one of \(allowed.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: ", "))")
        }
        return d
    }
}

public final class SettingsGadgetToolRunner: GadgetToolRunning {
    public static let gadgets: [GadgetID] = [.awake, .dim, .device, .mouse, .appswitch, .calendar]
    public static let maxWorldClocks = 6
    public static let awakeMinutes = 1...1440
    public static let hours = ClockHours.allCases.map { $0.rawValue }

    private weak var port: SettingsGadgetsPort?
    private let onMain: (@escaping () -> Void) -> Void

    /// `onMain` defaults to the main queue; tests pass a synchronous hop.
    public init(port: SettingsGadgetsPort, onMain: @escaping (@escaping () -> Void) -> Void = { work in
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }) {
        self.port = port
        self.onMain = onMain
    }

    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        onMain { [weak self] in
            guard let self = self, let port = self.port else {
                return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing"))
            }
            do { done(try self.handle(tool, arguments, port)) }
            catch let bad as SettingsArgs.Bad { done(PetCommandOutcome(ok: false, message: "bad parameters: \(bad.text)")) }
            catch { done(PetCommandOutcome(ok: false, message: "\(error)")) }
        }
    }

    private func handle(_ tool: GadgetTool, _ a: [String: JSONValue], _ port: SettingsGadgetsPort) throws -> PetCommandOutcome {
        switch (tool.gadget, tool.action) {
        case (.awake, "status"): try SettingsArgs.check(a, allowed: []); return awakeResult(port.awake(), "Keep Awake status.")
        case (.awake, "start"):
            try SettingsArgs.check(a, allowed: ["minutes"])
            let minutes = try SettingsArgs.int(a, "minutes", 0...SettingsGadgetToolRunner.awakeMinutes.upperBound) ?? 0
            port.awakeHold(minutes: minutes)
            return awakeResult(port.awake(), minutes == 0 ? "Keeping the Mac awake until you stop it." : "Keeping the Mac awake for \(minutes) minutes.")
        case (.awake, "stop"):
            try SettingsArgs.check(a, allowed: [])
            port.awakeStop()
            return awakeResult(port.awake(), "The Mac may sleep as usual (manual hold released).")
        case (.dim, "status"): try SettingsArgs.check(a, allowed: []); return dimResult(port.dim(), "Focus Dim status.")
        case (.dim, "pause"), (.dim, "resume"):
            try SettingsArgs.check(a, allowed: [])
            let pause = tool.action == "pause"
            port.dimSetPaused(pause)
            return dimResult(port.dim(), pause ? "Focus Dim is paused." : "Focus Dim is dimming again.")
        case (.device, "status"):
            try SettingsArgs.check(a, allowed: [])
            let s = port.device()
            var d: [String: Any] = ["mic_muted": s.micMuted]
            if let n = s.outputName { d["output"] = n }
            if let v = s.volumePercent { d["volume"] = v }
            if let n = s.inputName { d["input"] = n }
            return PetCommandOutcome(ok: true, message: "Sound output \(s.volumePercent.map { "\($0)%" } ?? "volume unknown"); microphone \(s.micMuted ? "muted" : "on").", details: d)
        case (.device, "set_volume"):
            try SettingsArgs.check(a, allowed: ["volume", "muted"], atLeastOne: true)
            let volume = try SettingsArgs.int(a, "volume", 0...100)
            let muted = try SettingsArgs.bool(a, "muted")
            let (ok, message) = port.deviceSetOutput(volumePercent: volume, muted: muted)
            return PetCommandOutcome(ok: ok, message: message)
        case (.device, "set_mic_muted"):
            try SettingsArgs.check(a, allowed: ["muted"])
            guard let muted = try SettingsArgs.bool(a, "muted") else { throw SettingsArgs.Bad(text: "muted is required") }
            port.deviceSetMicMuted(muted)
            return PetCommandOutcome(ok: true, message: muted ? "Microphone muted." : "Microphone on.", details: ["mic_muted": port.device().micMuted])
        case (.mouse, "status"): try SettingsArgs.check(a, allowed: []); return mouseResult(port.options(), "Mouse Tune settings.")
        case (.mouse, "set"):
            try SettingsArgs.check(a, allowed: ["reverse_scroll", "smooth_scroll", "speed", "side_buttons", "middle_button"], atLeastOne: true)
            var o = port.options()
            if let v = try SettingsArgs.bool(a, "reverse_scroll") { o.mouseReverse = v }
            if let v = try SettingsArgs.bool(a, "smooth_scroll") { o.mouseSmooth = v }
            if let v = try SettingsArgs.number(a, "speed", GadgetOptions.mouseSpeedChoices) { o.mouseSpeed = v }
            if let v = try SettingsArgs.bool(a, "side_buttons") { o.mouseSideButtons = v }
            if let v = try SettingsArgs.choice(a, "middle_button", MiddleButton.allCases.map { $0.rawValue }) { o.mouseMiddle = MiddleButton(rawValue: v) ?? o.mouseMiddle }
            port.apply(options: o)
            return mouseResult(port.options(), "Mouse Tune settings changed.")
        case (.appswitch, "settings"): try SettingsArgs.check(a, allowed: []); return appResult(port.options(), "App Switch settings.")
        case (.appswitch, "set_settings"):
            try SettingsArgs.check(a, allowed: ["hide_on_repeat"], atLeastOne: true)
            var o = port.options()
            if let v = try SettingsArgs.bool(a, "hide_on_repeat") { o.appHideOnRepeat = v }
            port.apply(options: o)
            return appResult(port.options(), "App Switch settings changed.")
        case (.calendar, "status"): try SettingsArgs.check(a, allowed: []); return clockResult(port.options(), "Calendar Clock settings.")
        case (.calendar, "set"):
            try SettingsArgs.check(a, allowed: ["show_date", "show_weekday", "show_seconds", "hours", "show_next_event", "world_clocks"], atLeastOne: true)
            var o = port.options()
            if let v = try SettingsArgs.bool(a, "show_date") { o.clockDate = v }
            if let v = try SettingsArgs.bool(a, "show_weekday") { o.clockWeekday = v }
            if let v = try SettingsArgs.bool(a, "show_seconds") { o.clockSeconds = v }
            if let v = try SettingsArgs.choice(a, "hours", SettingsGadgetToolRunner.hours) { o.clockHours = ClockHours(rawValue: v) ?? o.clockHours }
            if let v = try SettingsArgs.bool(a, "show_next_event") { o.clockNextEvent = v }
            if let v = a["world_clocks"] { o.worldClocks = try Self.zones(v) }
            port.apply(options: o)
            return clockResult(port.options(), "Calendar Clock settings changed.")
        default:
            return .unavailable(tool)
        }
    }

    /// Time zone identifiers: known to Foundation, at most `maxWorldClocks`, no duplicates.
    static func zones(_ value: JSONValue) throws -> [String] {
        guard case .array(let items) = value else { throw SettingsArgs.Bad(text: "world_clocks must be a list of time zone ids") }
        guard items.count <= maxWorldClocks else { throw SettingsArgs.Bad(text: "world_clocks takes at most \(maxWorldClocks) zones") }
        var out: [String] = []
        for item in items {
            guard case .string(let id) = item, id.count <= 64, TimeZone(identifier: id) != nil else {
                throw SettingsArgs.Bad(text: "world_clocks needs valid time zone ids such as Asia/Seoul")
            }
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    // MARK: results

    private func awakeResult(_ s: AwakeSnapshot, _ message: String) -> PetCommandOutcome {
        var d: [String: Any] = ["holding": s.holding, "manual": s.manual, "reason": s.reason, "keep_display": s.keepDisplay,
                                "power_only": s.powerOnly, "battery_floor_percent": s.batteryFloor]
        if let left = s.secondsLeft { d["seconds_left"] = left }
        return PetCommandOutcome(ok: true, message: message, details: d)
    }

    private func dimResult(_ s: DimSnapshot, _ message: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: true, message: message, details: ["paused": s.paused, "strength_percent": s.percent, "scope": s.scope,
                                                                "other_displays": s.otherDisplays, "only_in_session": s.onlyInSession])
    }

    private func mouseResult(_ o: GadgetOptions, _ message: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: true, message: message, details: ["reverse_scroll": o.mouseReverse, "smooth_scroll": o.mouseSmooth,
                                                                "speed": o.mouseSpeed, "side_buttons": o.mouseSideButtons,
                                                                "middle_button": o.mouseMiddle.rawValue,
                                                                "speed_choices": GadgetOptions.mouseSpeedChoices])
    }

    private func appResult(_ o: GadgetOptions, _ message: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: true, message: message, details: ["hide_on_repeat": o.appHideOnRepeat,
                                                                "shortcut_apps": o.appShortcuts.filter { $0.shortcut != nil }.map { $0.name }])
    }

    private func clockResult(_ o: GadgetOptions, _ message: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: true, message: message, details: ["show_date": o.clockDate, "show_weekday": o.clockWeekday,
                                                                "show_seconds": o.clockSeconds, "hours": o.clockHours.rawValue,
                                                                "show_next_event": o.clockNextEvent, "world_clocks": o.worldClocks,
                                                                "hours_choices": SettingsGadgetToolRunner.hours])
    }
}
