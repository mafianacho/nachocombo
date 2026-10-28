import Foundation

/// When the settings window opens by itself at launch (opening the app again always shows it).
public enum LaunchWindow: String, Codable, CaseIterable {
    case always, whenNeeded, never

    public var displayName: String {
        switch self {
        case .always: return "Always"
        case .whenNeeded: return "When Something Needs You"
        case .never: return "Never"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by ModuleID.rawValue so that unknown future modules do not break decoding.
    public var enabledModules: [String: Bool]
    public var menuBarCollapsed: Bool
    /// System monitor choices. Optional so settings files written before it existed still decode.
    public var monitor: MonitorSettings?
    /// Focus dim strength (overlay opacity). Missing in files written by older versions.
    public var dimIntensity: Double
    /// Tools the user pinned to the menu bar. Independent of ON/OFF; nothing is pinned by default.
    public var pinnedTools: [String: Bool]
    /// Optional per-tool shortcut that opens the tool's panel screen. Unset by default.
    public var toolShortcuts: [String: ToolShortcut]
    /// Behaviour choices of the gadgets (auto-collapse, gaps, shelf trigger, dim scope...).
    public var options: GadgetOptions
    /// Action shortcuts the user changed or removed (GadgetAction.id → binding). Absent = the default.
    public var actionShortcuts: [String: ActionBinding]
    /// Code signature of the copy that last had each permission (GadgetPermission.rawValue → hex). An update changes the
    /// ad-hoc signature, which tells "the update reset it" apart from "you turned it off".
    public var permissionGrants: [String: String]
    public var launchWindow: LaunchWindow
    /// An orange dot on the menu bar icon while a gadget needs a permission or has an error.
    public var menuBarAttentionDot: Bool
    /// One-time hints the user closed ("menuBarSetup").
    public var dismissedHints: [String: Bool]
    /// The combo last ordered (Combo.id); the box may have changed since.
    public var combo: String?
    /// Combos the user made, in board order.
    public var customCombos: [SavedCombo]

    /// First launch: every module is OFF, so no permission prompt or monitoring starts before opt-in.
    public static let defaults = AppSettings(
        version: currentVersion, enabledModules: [:], menuBarCollapsed: false)

    public init(version: Int, enabledModules: [String: Bool], menuBarCollapsed: Bool, monitor: MonitorSettings? = nil,
                dimIntensity: Double = FocusDimLogic.defaultIntensity,
                pinnedTools: [String: Bool] = [:], toolShortcuts: [String: ToolShortcut] = [:],
                options: GadgetOptions = .defaults, actionShortcuts: [String: ActionBinding] = [:],
                permissionGrants: [String: String] = [:], launchWindow: LaunchWindow = .whenNeeded,
                menuBarAttentionDot: Bool = true, dismissedHints: [String: Bool] = [:], combo: String? = nil,
                customCombos: [SavedCombo] = []) {
        self.combo = combo
        self.customCombos = customCombos
        self.permissionGrants = permissionGrants
        self.launchWindow = launchWindow
        self.menuBarAttentionDot = menuBarAttentionDot
        self.dismissedHints = dismissedHints
        self.options = options
        self.actionShortcuts = actionShortcuts
        self.pinnedTools = pinnedTools
        self.toolShortcuts = toolShortcuts
        self.version = version
        self.enabledModules = enabledModules
        self.menuBarCollapsed = menuBarCollapsed
        self.monitor = monitor
        self.dimIntensity = FocusDimLogic.clamp(dimIntensity)
    }

    public var monitorSettings: MonitorSettings {
        get { monitor ?? .defaults }
        set { monitor = newValue }
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabledModules, menuBarCollapsed, monitor, dimIntensity, pinnedTools, toolShortcuts, options,
             actionShortcuts, permissionGrants, launchWindow, menuBarAttentionDot, dismissedHints, combo, customCombos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        enabledModules = try c.decode([String: Bool].self, forKey: .enabledModules)
        menuBarCollapsed = try c.decode(Bool.self, forKey: .menuBarCollapsed)
        // A broken monitor section falls back to its defaults instead of discarding the whole file.
        monitor = try? c.decodeIfPresent(MonitorSettings.self, forKey: .monitor)
        let raw = try c.decodeIfPresent(Double.self, forKey: .dimIntensity) ?? FocusDimLogic.defaultIntensity
        dimIntensity = FocusDimLogic.clamp(raw)
        // Files written by older versions have neither key: nothing pinned, no shortcuts.
        pinnedTools = try c.decodeIfPresent([String: Bool].self, forKey: .pinnedTools) ?? [:]
        toolShortcuts = try c.decodeIfPresent([String: ToolShortcut].self, forKey: .toolShortcuts) ?? [:]
        // Each option falls back on its own; a missing section means every default.
        options = (try? c.decodeIfPresent(GadgetOptions.self, forKey: .options)) ?? .defaults
        actionShortcuts = (try? c.decodeIfPresent([String: ActionBinding].self, forKey: .actionShortcuts)) ?? [:]
        permissionGrants = (try? c.decodeIfPresent([String: String].self, forKey: .permissionGrants)) ?? [:]
        launchWindow = (try? c.decodeIfPresent(LaunchWindow.self, forKey: .launchWindow)) ?? .whenNeeded
        menuBarAttentionDot = (try? c.decodeIfPresent(Bool.self, forKey: .menuBarAttentionDot)) ?? true
        dismissedHints = (try? c.decodeIfPresent([String: Bool].self, forKey: .dismissedHints)) ?? [:]
        combo = try? c.decodeIfPresent(String.self, forKey: .combo)
        customCombos = (try? c.decodeIfPresent([SavedCombo].self, forKey: .customCombos)) ?? []
    }

    public func hintDismissed(_ key: String) -> Bool { dismissedHints[key] ?? false }

    public func isPinned(_ id: ModuleID) -> Bool { pinnedTools[id.rawValue] ?? false }
    public func shortcut(for id: ModuleID) -> ToolShortcut? { toolShortcuts[id.rawValue] }

    public func isEnabled(_ id: ModuleID) -> Bool { enabledModules[id.rawValue] ?? false }

    public mutating func setEnabled(_ id: ModuleID, _ enabled: Bool) {
        enabledModules[id.rawValue] = enabled
    }
}

public final class SettingsStore {
    public let url: URL
    public private(set) var lastLoadProblem: String?

    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NachoCombo", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func load() -> AppSettings {
        lastLoadProblem = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return .defaults }
        do {
            let data = try Data(contentsOf: url)
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            settings.version = AppSettings.currentVersion
            return settings
        } catch {
            // A corrupt file must not block the app. Keep a copy for inspection and start from defaults.
            lastLoadProblem = "Could not read the settings file, using defaults: \(error)"
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return .defaults
        }
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
