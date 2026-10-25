import Foundation

public enum ModuleID: String, Codable, CaseIterable {
    case menuBar
    case systemMonitor
    case windowSnap
    case fileShelf
    case captureFloat
    case focusDim

    public var displayName: String {
        switch self {
        case .menuBar: return "메뉴 막대 정리"
        case .systemMonitor: return "시스템 모니터"
        case .windowSnap: return "창 배치"
        case .fileShelf: return "파일 선반"
        case .captureFloat: return "캡처 고정"
        case .focusDim: return "집중 디밍"
        }
    }

    /// Only these modules own menu bar status items. Starting any other module must not
    /// re-create the menu bar divider pair.
    public var createsStatusItem: Bool {
        switch self {
        case .menuBar, .systemMonitor: return true
        default: return false
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
        case .off: return "꺼짐"
        case .running: return "동작 중"
        case .needsPermission: return "권한 필요"
        case .failed: return "오류"
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

/// Modules that can raise an OS permission dialog. The dialog is only allowed when the *user* just switched
/// the module on; restoring saved settings at launch or re-checking after activation never prompts.
public protocol PermissionPrompting: AnyObject {
    var allowPermissionPrompt: Bool { get set }
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
        for id in ModuleID.allCases where settings.isEnabled(id) { startModule(id, userInitiated: false) }
        onChange?()
    }

    @discardableResult
    public func setEnabled(_ id: ModuleID, _ enabled: Bool) -> ModuleState {
        settings.setEnabled(id, enabled)
        try? store.save(settings)
        if enabled {
            startModule(id, userInitiated: true)
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
        startModule(id, userInitiated: false)
        onChange?()
    }

    /// Lets a running module report that the OS took something away (e.g. permission revoked).
    public func report(_ id: ModuleID, state: ModuleState) {
        states[id] = state
        onChange?()
    }

    public func setDimIntensity(_ value: Double) {
        settings.dimIntensity = FocusDimLogic.clamp(value)
        try? store.save(settings)
        onChange?()
    }

    /// Pinning only adds/removes a menu bar entry point. It never turns the tool on or requests a permission.
    public func setPinned(_ id: ModuleID, _ pinned: Bool) {
        if pinned { settings.pinnedTools[id.rawValue] = true } else { settings.pinnedTools.removeValue(forKey: id.rawValue) }
        try? store.save(settings)
        onChange?()
    }

    /// Stores (or clears with nil) the tool-open shortcut. Returns the policy issue and stores nothing when invalid.
    @discardableResult
    public func setShortcut(_ id: ModuleID, _ shortcut: ToolShortcut?) -> ShortcutIssue? {
        if let shortcut = shortcut {
            if let issue = ShortcutPolicy.validate(shortcut, for: id, existing: settings.toolShortcuts) { return issue }
            settings.toolShortcuts[id.rawValue] = shortcut
        } else {
            settings.toolShortcuts.removeValue(forKey: id.rawValue)
        }
        try? store.save(settings)
        onChange?()
        return nil
    }

    public func status(of id: ModuleID) -> ToolStatusPresentation {
        ToolStatusPresentation.make(enabled: settings.isEnabled(id), state: states[id] ?? .off)
    }

    public func setMenuBarCollapsed(_ collapsed: Bool) {
        settings.menuBarCollapsed = collapsed
        try? store.save(settings)
        onChange?()
    }

    public func shutdown() {
        for id in ModuleID.allCases { modules[id]?.stop(); states[id] = .off }
    }

    private func startModule(_ id: ModuleID, userInitiated: Bool) {
        guard let module = modules[id] else { states[id] = .failed("모듈 없음"); return }
        if case .running = states[id] ?? .off { return }
        (module as? PermissionPrompting)?.allowPermissionPrompt = userInitiated
        let result = module.start()
        states[id] = result
        if result == .running { onStarted?(id) }
    }

    private func stopModule(_ id: ModuleID) {
        modules[id]?.stop()
        states[id] = .off
    }
}
