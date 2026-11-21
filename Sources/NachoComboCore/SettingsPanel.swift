import Foundation

// NACHO-856: the settings live in a panel that slides in from the right of the widget window; there is no separate
// settings window. This file is the pure model behind it: which page the panel shows, what each entry point opens,
// and how the panel reacts to clicks and edit mode.

/// The tabs of a gadget's panel. The old Overview is folded into the top of Settings.
public enum GadgetPanelTab: String, CaseIterable {
    case settings, shortcuts, permissions

    public var title: String {
        switch self {
        case .settings: return "설정"
        case .shortcuts: return "단축키"
        case .permissions: return "권한"
        }
    }

    /// The key the debug `ctl` takes. The old window's `overview` now means Settings.
    public init?(legacyKey: String) {
        switch legacyKey {
        case "overview", "settings": self = .settings
        case "shortcuts": self = .shortcuts
        case "permissions": self = .permissions
        default: return nil
        }
    }
}

/// The tabs of the app settings panel.
public enum AppPanelTab: String, CaseIterable {
    case general, permissions, combos, mcp

    public var title: String {
        switch self {
        case .general: return "일반"
        case .permissions: return "권한"
        case .combos: return "콤보"
        case .mcp: return "MCP"
        }
    }
}

/// What the panel shows.
public enum SettingsPanelRoute: Equatable {
    case gadget(ModuleID, GadgetPanelTab)
    case app(AppPanelTab)

    /// The tabs a gadget's panel offers (all gadgets alike; an empty Permissions tab says so).
    public static func tabs(for id: ModuleID) -> [GadgetPanelTab] { GadgetPanelTab.allCases }

    /// The old settings window's page key ("combos", "general", "permissions", "mcp", a module id). "home" (All
    /// Gadgets) has no route: the widget wall took its place.
    public init?(legacyPage: String) {
        switch legacyPage {
        case "general": self = .app(.general)
        case "permissions": self = .app(.permissions)
        case "combos": self = .app(.combos)
        case "mcp": self = .app(.mcp)
        default:
            guard let id = ModuleID(rawValue: legacyPage) else { return nil }
            self = .gadget(id, .settings)
        }
    }

    /// The page key, as the old window wrote it (debug `ctl` readouts).
    public var key: String {
        switch self {
        case .gadget(let id, _): return id.rawValue
        case .app(let tab): return tab.rawValue
        }
    }
}

/// Every way into the panel.
public enum SettingsEntry: Equatable {
    /// A widget tile was clicked (or Return on a focused tile).
    case widgetClick(ModuleID)
    /// A gadget asks for its settings (its own "Settings…" menu item, the pet's, the clock's).
    case gadgetOpenSettings(ModuleID)
    /// A permission is missing: notifications, the permission watcher, "Show Steps".
    case permissionNeeded(ModuleID)
    /// Opening at launch because the first gadget that needs help is shown (`launchWindow == whenNeeded`).
    case whenNeeded(ModuleID, needsPermission: Bool)
    /// The "설정" pill of the widget window, or "Settings…" of the menu bar menu.
    case settingsPill
    case menuBarSettings
    /// First launch: the combo welcome.
    case firstRunCombo
    case combos
    case permissionsOverview
    case mcp
    /// A hidden widget opened from the "+" menu.
    case hiddenWidgetSettings(ModuleID)
    /// The debug `ctl` and deep links, which still speak the old window's page and tab keys.
    case deepLink(page: String, tab: String?)

    /// nil: the entry closes the panel (the old "home" page) or names nothing known.
    public var route: SettingsPanelRoute? {
        switch self {
        case .widgetClick(let id), .gadgetOpenSettings(let id), .hiddenWidgetSettings(let id): return .gadget(id, .settings)
        case .permissionNeeded(let id): return .gadget(id, .permissions)
        case .whenNeeded(let id, let needsPermission): return .gadget(id, needsPermission ? .permissions : .settings)
        case .settingsPill, .menuBarSettings: return .app(.general)
        case .firstRunCombo, .combos: return .app(.combos)
        case .permissionsOverview: return .app(.permissions)
        case .mcp: return .app(.mcp)
        case .deepLink(let page, let tab):
            guard let base = SettingsPanelRoute(legacyPage: page) else { return nil }
            if case .gadget(let id, _) = base, let tab = tab, let mapped = GadgetPanelTab(legacyKey: tab) { return .gadget(id, mapped) }
            return base
        }
    }
}

/// The panel's open/closed state: which route is shown, and whether edit mode keeps it shut.
public struct SettingsPanelState: Equatable {
    public private(set) var route: SettingsPanelRoute?
    public private(set) var editing: Bool

    public init(route: SettingsPanelRoute? = nil, editing: Bool = false) {
        self.route = editing ? nil : route
        self.editing = editing
    }

    public var isOpen: Bool { route != nil }

    /// Shows a route (the same or another one: only the content changes). False while editing: the edit drawer owns that side.
    @discardableResult public mutating func open(_ next: SettingsPanelRoute) -> Bool {
        guard !editing else { return false }
        route = next
        return true
    }

    /// A widget tile was clicked: its panel opens, another tile's panel is swapped in, the same tile's closes it.
    @discardableResult public mutating func tileClick(_ id: ModuleID) -> Bool {
        guard !editing else { return false }
        if case .gadget(let shown, _)? = route, shown == id { route = nil } else { route = .gadget(id, .settings) }
        return true
    }

    /// The "설정" pill: opens the app settings, closes them when they are already shown.
    @discardableResult public mutating func settingsPillClick() -> Bool {
        guard !editing else { return false }
        if case .app? = route { route = nil } else { route = .app(.general) }
        return true
    }

    public mutating func close() { route = nil }

    /// Edit mode closes the panel and keeps it closed.
    public mutating func beginEditing() { route = nil; editing = true }
    public mutating func endEditing() { editing = false }
}
