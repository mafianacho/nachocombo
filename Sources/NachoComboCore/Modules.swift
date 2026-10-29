import Foundation

public enum ModuleID: String, Codable, CaseIterable {
    case menuBar
    case systemMonitor
    case windowSnap
    case fileShelf
    case captureFloat
    case focusDim
    case keepAwake
    case clipboard
    case deviceControl
    case appSwitch
    case mouseTune
    case calendarClock

    public var displayName: String {
        switch self {
        case .menuBar: return "Menu Bar Organizer"
        case .systemMonitor: return "System Monitor"
        case .windowSnap: return "Window Snap"
        case .fileShelf: return "File Shelf"
        case .captureFloat: return "Capture Float"
        case .focusDim: return "Focus Dim"
        case .keepAwake: return "Keep Awake"
        case .clipboard: return "Clipboard History"
        case .deviceControl: return "Device Control"
        case .appSwitch: return "App Switch"
        case .mouseTune: return "Mouse Tune"
        case .calendarClock: return "Calendar Clock"
        }
    }

    /// Only these modules own menu bar status items. Starting any other module must not
    /// re-create the menu bar divider pair.
    public var createsStatusItem: Bool {
        switch self {
        case .menuBar, .systemMonitor, .keepAwake, .calendarClock: return true
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

    /// `userInitiated: false` switches a gadget on without letting it raise a permission dialog (a combo order holds
    /// those back until the user presses Allow).
    @discardableResult
    public func setEnabled(_ id: ModuleID, _ enabled: Bool, userInitiated: Bool = true) -> ModuleState {
        settings.setEnabled(id, enabled)
        try? store.save(settings)
        if enabled {
            startModule(id, userInitiated: userInitiated)
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
            let actions = settings.effectiveActionShortcuts.map { ($0.name, $0.keyCode, $0.modifiers) }
            if let issue = ShortcutPolicy.validate(shortcut, for: id, existing: settings.toolShortcuts, actions: actions) {
                return issue
            }
            settings.toolShortcuts[id.rawValue] = shortcut
        } else {
            settings.toolShortcuts.removeValue(forKey: id.rawValue)
        }
        try? store.save(settings)
        onChange?()
        return nil
    }

    /// Gives an action a new shortcut, removes it (`nil`), or with `reset` goes back to the default.
    /// Returns the policy issue and stores nothing when the shortcut is not allowed.
    @discardableResult
    public func setActionShortcut(_ id: String, _ shortcut: ToolShortcut?, reset: Bool = false) -> ShortcutIssue? {
        if reset {
            settings.actionShortcuts.removeValue(forKey: id)
        } else {
            if let shortcut = shortcut,
               let issue = ShortcutPolicy.validateAction(shortcut, actionID: id, settings: settings) { return issue }
            if shortcut == GadgetActions.action(id)?.defaultShortcut {
                settings.actionShortcuts.removeValue(forKey: id)
            } else {
                settings.actionShortcuts[id] = ActionBinding(shortcut: shortcut)
            }
        }
        try? store.save(settings)
        onChange?()
        return nil
    }

    public func status(of id: ModuleID) -> ToolStatusPresentation {
        ToolStatusPresentation.make(enabled: settings.isEnabled(id), state: states[id] ?? .off,
                                    permission: id.info.requiredPermission?.displayName)
    }

    /// Changes app-level choices (launch window, hints, permission bookkeeping) and saves them.
    public func update(_ change: (inout AppSettings) -> Void) {
        var value = settings
        change(&value)
        guard value != settings else { return }
        settings = value
        try? store.save(settings)
        onChange?()
    }

    /// Every gadget off and every choice back to its default. The permission bookkeeping stays: it describes this Mac's
    /// privacy settings, not a choice made here.
    public func resetAll() {
        for id in ModuleID.allCases { stopModule(id) }
        var fresh = AppSettings.defaults
        fresh.permissionGrants = settings.permissionGrants
        settings = fresh
        try? store.save(settings)
        onChange?()
    }

    /// Puts one gadget's action shortcuts back to their defaults. A default another gadget's action now uses is left
    /// empty instead, so the reset never creates a clash.
    public func resetActionShortcuts(of module: ModuleID) {
        let actions = GadgetActions.of(module)
        for action in actions { settings.actionShortcuts.removeValue(forKey: action.id) }
        let others = settings.effectiveActionShortcuts.filter { item in !actions.contains { $0.id == item.id } }
        for action in actions {
            guard let wanted = action.defaultShortcut else { continue }
            let mods = wanted.modifiers & ToolShortcut.allModifiers
            if others.contains(where: { $0.keyCode == wanted.keyCode && $0.modifiers == mods }) {
                settings.actionShortcuts[action.id] = ActionBinding(shortcut: nil)
            }
        }
        try? store.save(settings)
        onChange?()
    }

    public func setMenuBarCollapsed(_ collapsed: Bool) {
        settings.menuBarCollapsed = collapsed
        try? store.save(settings)
        onChange?()
    }

    public func setOptions(_ value: GadgetOptions) {
        guard settings.options != value else { return }
        settings.options = value
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

    private func startModule(_ id: ModuleID, userInitiated: Bool) {
        guard let module = modules[id] else { states[id] = .failed("Module missing"); return }
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
