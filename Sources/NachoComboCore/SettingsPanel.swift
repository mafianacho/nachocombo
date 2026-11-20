import Foundation

// NACHO-856: the settings live in a panel that slides in from the right of the widget window; there is no separate
// settings window. This file is the pure model behind it. (RED stage: placeholders only.)

public enum GadgetPanelTab: String, CaseIterable {
    case settings, shortcuts, permissions
    public var title: String { "" }
}

public enum AppPanelTab: String, CaseIterable {
    case general, permissions, combos, mcp
    public var title: String { "" }
}

public enum SettingsPanelRoute: Equatable {
    case gadget(ModuleID, GadgetPanelTab)
    case app(AppPanelTab)
    public static func tabs(for id: ModuleID) -> [GadgetPanelTab] { [] }
    public init?(legacyPage: String) { return nil }
    public var key: String { "" }
}

public enum SettingsEntry: Equatable {
    case widgetClick(ModuleID)
    case gadgetOpenSettings(ModuleID)
    case permissionNeeded(ModuleID)
    case whenNeeded(ModuleID, needsPermission: Bool)
    case settingsPill
    case menuBarSettings
    case firstRunCombo
    case combos
    case permissionsOverview
    case mcp
    case hiddenWidgetSettings(ModuleID)
    case deepLink(page: String, tab: String?)
    public var route: SettingsPanelRoute? { nil }
}

public struct SettingsPanelState: Equatable {
    public private(set) var route: SettingsPanelRoute?
    public private(set) var editing: Bool
    public init(route: SettingsPanelRoute? = nil, editing: Bool = false) { self.route = route; self.editing = editing }
    public var isOpen: Bool { false }
    @discardableResult public mutating func open(_ next: SettingsPanelRoute) -> Bool { false }
    @discardableResult public mutating func tileClick(_ id: ModuleID) -> Bool { false }
    @discardableResult public mutating func settingsPillClick() -> Bool { false }
    public mutating func close() {}
    public mutating func beginEditing() {}
    public mutating func endEditing() {}
}
