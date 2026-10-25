import Foundation

public struct AppSettings: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Keyed by ModuleID.rawValue so that unknown future modules do not break decoding.
    public var enabledModules: [String: Bool]
    public var menuBarCollapsed: Bool
    /// System monitor choices. Optional so settings files written before it existed still decode.
    public var monitor: MonitorSettings?

    /// First launch: every module is OFF, so no permission prompt or monitoring starts before opt-in.
    public static let defaults = AppSettings(
        version: currentVersion, enabledModules: [:], menuBarCollapsed: false)

    public init(version: Int, enabledModules: [String: Bool], menuBarCollapsed: Bool, monitor: MonitorSettings? = nil) {
        self.version = version
        self.enabledModules = enabledModules
        self.menuBarCollapsed = menuBarCollapsed
        self.monitor = monitor
    }

    public var monitorSettings: MonitorSettings {
        get { monitor ?? .defaults }
        set { monitor = newValue }
    }

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
