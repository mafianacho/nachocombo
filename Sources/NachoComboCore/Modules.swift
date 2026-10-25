import Foundation

public enum ModuleID: String, Codable, CaseIterable {
    case menuBar
    case systemMonitor
    case windowSnap

    public var displayName: String {
        switch self {
        case .menuBar: return "Menu Bar Organizer"
        case .systemMonitor: return "System Monitor"
        case .windowSnap: return "Window Snap"
        }
    }
}

public enum ModuleState: Equatable {
    case off
    case running
    /// The user switched the module on, but the OS permission is missing. Nothing is running.
    case needsPermission(String)
    case failed(String)

    public var label: String {
        switch self {
        case .off: return "Off"
        case .running: return "Running"
        case .needsPermission: return "Needs Permission"
        case .failed: return "Error"
        }
    }
}

/// A feature that owns OS resources (status items, timers, hotkeys).
/// `stop()` MUST release every one of them; the manager relies on it for the OFF contract.
public protocol FeatureModule: AnyObject {
    var id: ModuleID { get }
    func start() -> ModuleState
    func stop()
    /// Live counters used for verification (timers, hotkeys, status items...).
    var diagnostics: [String: String] { get }
}

public final class ModuleManager {
    public private(set) var settings: AppSettings
    public private(set) var states: [ModuleID: ModuleState] = [:]
    public var onChange: (() -> Void)?
    /// Called after a module reached `.running` (e.g. to re-order status items).
    public var onStarted: ((ModuleID) -> Void)?

    private let store: SettingsStore
    private var modules: [ModuleID: FeatureModule] = [:]

    public init(store: SettingsStore, modules: [FeatureModule]) {
        self.store = store
        self.settings = store.load()
        for module in modules { self.modules[module.id] = module }
        for id in ModuleID.allCases { states[id] = .off }
    }

    public func module(_ id: ModuleID) -> FeatureModule? { modules[id] }

    /// Starts every module the user left enabled in the saved settings.
    public func bootstrap() {
        for id in ModuleID.allCases where settings.isEnabled(id) { startModule(id) }
        onChange?()
    }

    @discardableResult
    public func setEnabled(_ id: ModuleID, _ enabled: Bool) -> ModuleState {
        settings.setEnabled(id, enabled)
        try? store.save(settings)
        if enabled {
            startModule(id)
        } else {
            stopModule(id)
        }
        onChange?()
        return states[id] ?? .off
    }

    /// Re-attempt a module that is enabled but blocked (e.g. permission just granted).
    public func retry(_ id: ModuleID) {
        guard settings.isEnabled(id) else { return }
        if case .running = states[id] ?? .off { return }
        startModule(id)
        onChange?()
    }

    /// Lets a running module report that the OS took something away (e.g. permission revoked).
    public func report(_ id: ModuleID, state: ModuleState) {
        states[id] = state
        onChange?()
    }

    public func setMenuBarCollapsed(_ collapsed: Bool) {
        settings.menuBarCollapsed = collapsed
        try? store.save(settings)
        onChange?()
    }

    public func setMonitorSettings(_ value: MonitorSettings) {
        guard settings.monitorSettings != value else { return }
        settings.monitorSettings = value
        try? store.save(settings)
        onChange?()
    }

    public func shutdown() {
        for id in ModuleID.allCases { modules[id]?.stop(); states[id] = .off }
    }

    private func startModule(_ id: ModuleID) {
        guard let module = modules[id] else { states[id] = .failed("Module missing"); return }
        if case .running = states[id] ?? .off { return }
        let result = module.start()
        states[id] = result
        if result == .running { onStarted?(id) }
    }

    private func stopModule(_ id: ModuleID) {
        modules[id]?.stop()
        states[id] = .off
    }
}
