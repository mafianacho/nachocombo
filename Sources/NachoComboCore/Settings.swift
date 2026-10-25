import Foundation

public struct AppSettings: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by ModuleID.rawValue so that unknown future modules do not break decoding.
    public var enabledModules: [String: Bool]
    public var menuBarCollapsed: Bool
    /// Focus dim strength (overlay opacity). Missing in files written by older versions.
    public var dimIntensity: Double
    /// Tools the user pinned to the menu bar. Independent of ON/OFF; nothing is pinned by default.
    public var pinnedTools: [String: Bool]
    /// Optional per-tool shortcut that opens the tool's panel screen. Unset by default.
    public var toolShortcuts: [String: ToolShortcut]

    /// First launch: every module is OFF, so no permission prompt or monitoring starts before opt-in.
    public static let defaults = AppSettings(
        version: currentVersion, enabledModules: [:], menuBarCollapsed: false)

    public init(version: Int, enabledModules: [String: Bool], menuBarCollapsed: Bool,
                dimIntensity: Double = FocusDimLogic.defaultIntensity,
                pinnedTools: [String: Bool] = [:], toolShortcuts: [String: ToolShortcut] = [:]) {
        self.pinnedTools = pinnedTools
        self.toolShortcuts = toolShortcuts
        self.version = version
        self.enabledModules = enabledModules
        self.menuBarCollapsed = menuBarCollapsed
        self.dimIntensity = FocusDimLogic.clamp(dimIntensity)
    }

    private enum CodingKeys: String, CodingKey {
        case version, enabledModules, menuBarCollapsed, dimIntensity, pinnedTools, toolShortcuts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        enabledModules = try c.decode([String: Bool].self, forKey: .enabledModules)
        menuBarCollapsed = try c.decode(Bool.self, forKey: .menuBarCollapsed)
        let raw = try c.decodeIfPresent(Double.self, forKey: .dimIntensity) ?? FocusDimLogic.defaultIntensity
        dimIntensity = FocusDimLogic.clamp(raw)
        // Files written by older versions have neither key: nothing pinned, no shortcuts.
        pinnedTools = try c.decodeIfPresent([String: Bool].self, forKey: .pinnedTools) ?? [:]
        toolShortcuts = try c.decodeIfPresent([String: ToolShortcut].self, forKey: .toolShortcuts) ?? [:]
    }

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
            lastLoadProblem = "설정 파일을 읽지 못해 기본값을 사용합니다: \(error)"
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
