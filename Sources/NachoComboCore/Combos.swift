import Foundation

/// One thing that gets easier with a combo: a key (one of the user's action shortcuts, looked up when it is shown) or a
/// gesture, and what it does.
public struct ComboMoment: Equatable {
    public let module: ModuleID
    /// GadgetAction ids whose current shortcuts are shown as keys (none: the gesture is shown instead).
    public let actions: [String]
    /// What to do when there is no key ("Shake while dragging", "Click ‹").
    public let gesture: String
    public let result: String
}

/// The options a combo sets besides the switches. nil = left as it is.
public struct ComboTuning: Equatable, Codable {
    public var dimIntensity: Double?
    public var snapGap: Int?
    public var autoCollapseSeconds: Int?
    public var dimOtherDisplays: Bool?
    public var monitorItems: [MonitorItem]?

    public init(dimIntensity: Double? = nil, snapGap: Int? = nil, autoCollapseSeconds: Int? = nil,
                dimOtherDisplays: Bool? = nil, monitorItems: [MonitorItem]? = nil) {
        self.dimIntensity = dimIntensity
        self.snapGap = snapGap
        self.autoCollapseSeconds = autoCollapseSeconds
        self.dimOtherDisplays = dimOtherDisplays
        self.monitorItems = monitorItems
    }

    /// Writes the tuned values into the settings.
    public func apply(to settings: inout AppSettings) {
        if let v = dimIntensity { settings.dimIntensity = FocusDimLogic.clamp(v) }
        if let v = snapGap { settings.options.snapGap = v }
        if let v = autoCollapseSeconds { settings.options.autoCollapseSeconds = v }
        if let v = dimOtherDisplays { settings.options.dimOtherDisplays = v }
        if let items = monitorItems {
            var monitor = settings.monitorSettings
            for item in MonitorItem.allCases { monitor.setShown(item, items.contains(item)) }
            settings.monitorSettings = monitor
        }
    }

    /// What ordering would change, in words ("Gap Between Windows: None → 8 pt"); nothing when the value is already so.
    public func changes(from settings: AppSettings) -> [String] {
        var lines: [String] = []
        func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        func gap(_ v: Int) -> String { v == 0 ? "None" : "\(v) pt" }
        func seconds(_ v: Int) -> String { v == 0 ? "Never" : "\(v) s" }
        if let v = dimIntensity, abs(settings.dimIntensity - v) > 0.001 {
            lines.append("Dim strength: \(percent(settings.dimIntensity)) → \(percent(v))")
        }
        if let v = snapGap, settings.options.snapGap != v {
            lines.append("Gap Between Windows: \(gap(settings.options.snapGap)) → \(gap(v))")
        }
        if let v = autoCollapseSeconds, settings.options.autoCollapseSeconds != v {
            lines.append("Collapse Again After: \(seconds(settings.options.autoCollapseSeconds)) → \(seconds(v))")
        }
        if let v = dimOtherDisplays, settings.options.dimOtherDisplays != v {
            lines.append(v ? "Dim the other displays too" : "Dim only the display you work on")
        }
        if let items = monitorItems, settings.monitorSettings.shownItems != MonitorItem.allCases.filter({ items.contains($0) }) {
            lines.append("Menu bar items: " + items.map { $0.displayName }.joined(separator: ", "))
        }
        return lines
    }
}

/// A set of gadgets switched on together, with a few options tuned for one way of working. A starting point, not a
/// mode: after ordering, every gadget is still its own switch.
public struct Combo: Equatable {
    public let id: String
    public let number: Int
    public let name: String
    public let line: String
    /// Who it suits, one sentence.
    public let who: String
    public let gadgets: [ModuleID]
    public let moments: [ComboMoment]
    public let tuning: ComboTuning
    /// Made by the user (it can be edited and deleted); the five numbered presets are not.
    public let isCustom: Bool

    public init(id: String, number: Int, name: String, line: String, who: String, gadgets: [ModuleID],
                moments: [ComboMoment], tuning: ComboTuning, isCustom: Bool = false) {
        self.id = id
        self.number = number
        self.name = name
        self.line = line
        self.who = who
        self.gadgets = gadgets
        self.moments = moments
        self.tuning = tuning
        self.isCustom = isCustom
    }

    /// The permissions ordering will ask for (in gadget order), one per gadget that needs one.
    public var permissions: [GadgetPermission] {
        gadgets.compactMap { $0.info.requiredPermission }
    }
}

/// What ordering a combo does to the box as it is now.
public struct ComboPlan: Equatable {
    public let turnsOn: [ModuleID]
    public let staysOn: [ModuleID]
    public let turnsOff: [ModuleID]
    public let optionChanges: [String]

    public static func make(_ combo: Combo, settings: AppSettings) -> ComboPlan {
        let on = ModuleID.allCases.filter { settings.isEnabled($0) }
        return ComboPlan(turnsOn: combo.gadgets.filter { !on.contains($0) },
                         staysOn: combo.gadgets.filter { on.contains($0) },
                         turnsOff: on.filter { !combo.gadgets.contains($0) },
                         optionChanges: combo.tuning.changes(from: settings))
    }

    /// Nothing would change: this combo is the box as it is.
    public var isNoChange: Bool { turnsOn.isEmpty && turnsOff.isEmpty && optionChanges.isEmpty }
}

public enum ComboCatalog {
    private static func m(_ module: ModuleID, _ actions: [String] = [], _ gesture: String = "", _ result: String) -> ComboMoment {
        ComboMoment(module: module, actions: actions, gesture: gesture, result: result)
    }

    /// The five numbered combos that come with the app.
    public static let presets: [Combo] = [
        Combo(id: "starter", number: 1, name: "Starter", line: "Try the box without allowing anything.",
              who: "For a first taste: three gadgets that need no permission.",
              gadgets: [.menuBar, .fileShelf, .focusDim],
              moments: [m(.menuBar, [], "Click ‹", "Fold away the menu bar icons you rarely need"),
                        m(.fileShelf, [], "Shake while dragging", "A tray opens under the pointer"),
                        m(.focusDim, [], "Switch windows", "Everything behind the active window dims")],
              tuning: ComboTuning(dimIntensity: 0.4)),
        Combo(id: "desk", number: 2, name: "Desk", line: "Windows in place, files in reach, references on top.",
              who: "For documents and design work that moves between windows and files.",
              gadgets: [.windowSnap, .fileShelf, .captureFloat],
              moments: [m(.windowSnap, [GadgetActions.snapID(.left)], "", "Put the front window on the left half"),
                        m(.fileShelf, [], "Shake while dragging", "A tray opens under the pointer"),
                        m(.captureFloat, ["capture.area"], "", "Float a piece of the screen above your work")],
              tuning: ComboTuning(snapGap: 8)),
        Combo(id: "builder", number: 3, name: "Builder", line: "For long builds and busy menu bars.",
              who: "For developers who keep builds and terminals running for hours.",
              gadgets: [.systemMonitor, .windowSnap, .menuBar],
              moments: [m(.systemMonitor, [], "Glance at the menu bar", "CPU, memory and network, live"),
                        m(.windowSnap, [GadgetActions.snapID(.left), GadgetActions.snapID(.right)], "",
                          "Code and terminal side by side"),
                        m(.menuBar, [], "Click ‹", "Monitor items stay in sight, the rest folds away")],
              tuning: ComboTuning(monitorItems: [.cpu, .memory, .network])),
        Combo(id: "focus", number: 4, name: "Focus", line: "One window, quiet menu bar.",
              who: "For writing or studying in one window for a long time.",
              gadgets: [.focusDim, .menuBar],
              moments: [m(.focusDim, [], "Switch windows", "Only the window you work in stays bright"),
                        m(.focusDim, ["dim.toggle"], "", "Pause dimming for a moment"),
                        m(.menuBar, [], "Leave the menu bar", "Its icons fold away after 5 seconds")],
              tuning: ComboTuning(dimIntensity: 0.6, autoCollapseSeconds: 5, dimOtherDisplays: true)),
        Combo(id: "full", number: 5, name: "Full Combo", line: "Everything in the box.",
              who: "For anyone who installs all of these on every new Mac.",
              gadgets: ModuleID.allCases,
              moments: [m(.windowSnap, [GadgetActions.snapID(.left)], "", "Put the front window on the left half"),
                        m(.captureFloat, ["capture.area"], "", "Float a piece of the screen above your work"),
                        m(.systemMonitor, [], "Glance at the menu bar", "CPU, memory and network, live")],
              tuning: ComboTuning()),
    ]

    public static func combo(_ id: String) -> Combo? { presets.first { $0.id == id } }

    /// Every combo the user can order: the presets, then their own (numbered on from No.6).
    public static func combos(_ settings: AppSettings) -> [Combo] {
        presets + settings.customCombos.enumerated().map { custom($1, index: $0) }
    }

    public static func combo(_ id: String, in settings: AppSettings) -> Combo? {
        combos(settings).first { $0.id == id }
    }

    /// The combo whose gadgets are exactly the ones switched on (nil: a box of your own). When several match, the one
    /// ordered last wins.
    public static func current(_ settings: AppSettings) -> Combo? {
        let on = Set(ModuleID.allCases.filter { settings.isEnabled($0) })
        guard !on.isEmpty else { return nil }
        let matches = combos(settings).filter { Set($0.gadgets) == on }
        return matches.first { $0.id == settings.combo } ?? matches.first
    }

    // MARK: the user's own combos

    /// At most this many combos of one's own (one row on the board).
    public static let maxCustom = 5
    public static let maxNameLength = 24

    /// What gets easier with each gadget when the user makes their own combo, most telling first.
    private static let defaultMoments: [ComboMoment] = [
        m(.windowSnap, [GadgetActions.snapID(.left)], "", "Put the front window on the left half"),
        m(.captureFloat, ["capture.area"], "", "Float a piece of the screen above your work"),
        m(.fileShelf, [], "Shake while dragging", "A tray opens under the pointer"),
        m(.systemMonitor, [], "Glance at the menu bar", "CPU, memory and network, live"),
        m(.focusDim, [], "Switch windows", "Everything behind the active window dims"),
        m(.menuBar, [], "Click ‹", "Fold away the menu bar icons you rarely need"),
    ]

    /// Up to three moments for any mix of gadgets.
    public static func moments(for gadgets: [ModuleID]) -> [ComboMoment] {
        Array(defaultMoments.filter { gadgets.contains($0.module) }.prefix(3))
    }

    public static func custom(_ saved: SavedCombo, index: Int) -> Combo {
        let gadgets = ModuleID.allCases.filter { saved.gadgets.contains($0) }
        return Combo(id: saved.id, number: presets.count + index + 1, name: saved.name, line: "Your own mix.",
                     who: "Made by you. Change it any time with Edit.", gadgets: gadgets,
                     moments: moments(for: gadgets), tuning: saved.tuning, isCustom: true)
    }

    /// A free name: "My Combo", then "My Combo 2"… (or the given base).
    public static func freeName(_ base: String, in settings: AppSettings) -> String {
        let taken = Set(settings.customCombos.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// A new combo of one's own, starting from what is switched on now (or from a preset to change).
    public static func draft(from settings: AppSettings, copying combo: Combo? = nil) -> SavedCombo {
        if let combo = combo {
            return SavedCombo(id: "custom-" + UUID().uuidString.prefix(8).lowercased(),
                              name: freeName("My \(combo.name)", in: settings), gadgets: combo.gadgets, tuning: combo.tuning)
        }
        let on = ModuleID.allCases.filter { settings.isEnabled($0) }
        return SavedCombo(id: "custom-" + UUID().uuidString.prefix(8).lowercased(), name: freeName("My Combo", in: settings),
                          gadgets: on, tuning: ComboTuning())
    }
}

/// A combo the user made: a name, the gadgets it switches on and the options it sets.
public struct SavedCombo: Codable, Equatable {
    public var id: String
    public var name: String
    public var gadgets: [ModuleID]
    public var tuning: ComboTuning

    public init(id: String, name: String, gadgets: [ModuleID], tuning: ComboTuning) {
        self.id = id
        self.name = name
        self.gadgets = gadgets
        self.tuning = tuning
    }

    /// Trimmed and capped; an empty name becomes "My Combo".
    public var cleanName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "My Combo" : String(trimmed.prefix(ComboCatalog.maxNameLength))
    }

    /// A combo needs at least one gadget.
    public var isValid: Bool { !gadgets.isEmpty }
}

/// The box as it was before an order: switches, the options a combo can change, and the combo. Undo puts it back.
public struct BoxSnapshot: Equatable {
    public let enabled: [ModuleID: Bool]
    public let options: GadgetOptions
    public let dimIntensity: Double
    public let monitor: MonitorSettings
    public let combo: String?
}

public extension ModuleManager {
    /// Saves a combo of one's own (replacing the one with the same id). A new one past `maxCustom` is refused.
    @discardableResult
    func saveCombo(_ combo: SavedCombo) -> Bool {
        guard combo.isValid else { return false }
        var clean = combo
        clean.name = combo.cleanName
        clean.gadgets = ModuleID.allCases.filter { combo.gadgets.contains($0) }
        if let index = settings.customCombos.firstIndex(where: { $0.id == clean.id }) {
            update { $0.customCombos[index] = clean }
        } else {
            guard settings.customCombos.count < ComboCatalog.maxCustom else { return false }
            update { $0.customCombos.append(clean) }
        }
        return true
    }

    func deleteCombo(_ id: String) {
        update { settings in
            settings.customCombos.removeAll { $0.id == id }
            if settings.combo == id { settings.combo = nil }
        }
    }

    func snapshot() -> BoxSnapshot {
        var enabled: [ModuleID: Bool] = [:]
        for id in ModuleID.allCases { enabled[id] = settings.isEnabled(id) }
        return BoxSnapshot(enabled: enabled, options: settings.options, dimIntensity: settings.dimIntensity,
                           monitor: settings.monitorSettings, combo: settings.combo)
    }

    /// Puts the box back as it was. Gadgets come back on without raising a permission dialog.
    func restore(_ snapshot: BoxSnapshot) {
        update { settings in
            settings.options = snapshot.options
            settings.dimIntensity = snapshot.dimIntensity
            settings.monitorSettings = snapshot.monitor
            settings.combo = snapshot.combo
        }
        for id in ModuleID.allCases where !(snapshot.enabled[id] ?? false) && settings.isEnabled(id) { setEnabled(id, false) }
        for id in ModuleID.allCases where (snapshot.enabled[id] ?? false) && !settings.isEnabled(id) {
            setEnabled(id, true, userInitiated: false)
        }
    }

    /// Orders a combo: sets its options, switches off what it leaves out and switches on `enable` (the caller holds back
    /// the gadgets whose permission is missing, so ordering never raises a system dialog). Remembers the combo.
    func order(_ combo: Combo, enable: [ModuleID]) {
        let plan = ComboPlan.make(combo, settings: settings)
        update { settings in
            combo.tuning.apply(to: &settings)
            settings.combo = combo.id
        }
        for id in plan.turnsOff { setEnabled(id, false) }
        for id in enable where plan.turnsOn.contains(id) { setEnabled(id, true, userInitiated: false) }
    }
}
