import Foundation

/// Menu Bar Organizer model for the MCP / Nacho tools (NACHO-148). Pure Swift: the AppKit side (`MenuBarOrganizerModule`,
/// Accessibility reader) only fills these values in. No private APIs.

/// Where a menu bar item sits relative to the organizer's dividers.
public enum MenuBarZone: String, Equatable {
    /// Right of the divider: stays on screen when the bar is collapsed.
    case visible
    /// Between the always-hidden divider and the divider: folds away when collapsed.
    case hidden
    /// Left of the always-hidden divider: stays folded even while expanded (until "show hidden").
    case alwaysHidden = "always_hidden"
}

/// Horizontal centres of the organizer's own divider windows (screen x). nil = that divider does not exist.
public struct MenuBarDividers: Equatable {
    public var divider: Double?
    public var alwaysDivider: Double?
    public init(divider: Double?, alwaysDivider: Double? = nil) {
        self.divider = divider
        self.alwaysDivider = alwaysDivider
    }

    /// Items left of a divider belong to its section. Without a divider (gadget not running) everything is visible.
    public func zone(centerX: Double) -> MenuBarZone {
        guard let d = divider else { return .visible }
        if let a = alwaysDivider, centerX < a { return .alwaysHidden }
        return centerX < d ? .hidden : .visible
    }
}

/// One status item read through Accessibility (`AXExtrasMenuBar`).
public struct MenuBarItem: Equatable {
    public var app: String
    public var title: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// An item of Nacho Combo itself (toggle, dividers, other gadgets' status items).
    public var own: Bool

    public init(app: String, title: String, x: Double, y: Double, width: Double, height: Double, own: Bool = false) {
        self.app = app
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.own = own
    }

    public var centerX: Double { x + width / 2 }
}

public enum MenuBarSerializer {
    public static let maxItems = 80
    public static let maxTextLength = 60

    /// Items left to right, at most `maxItems`, each with its zone; text is single-line and capped.
    public static func serialize(_ items: [MenuBarItem], dividers: MenuBarDividers, screenMinX: Double = 0) -> [[String: Any]] {
        items.sorted { $0.x < $1.x }.prefix(maxItems).map { item in
            [
                "app": clean(item.app),
                "title": clean(item.title),
                "x": Int(item.x.rounded()), "y": Int(item.y.rounded()),
                "width": Int(item.width.rounded()), "height": Int(item.height.rounded()),
                "zone": dividers.zone(centerX: item.centerX).rawValue,
                "on_screen": item.x + item.width > screenMinX,
                "own": item.own,
            ]
        }
    }

    static func clean(_ text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(flat.prefix(maxTextLength))
    }

    /// Item counts per zone, over the full list (not capped).
    public static func counts(_ items: [MenuBarItem], dividers: MenuBarDividers) -> [String: Int] {
        var out = ["visible": 0, "hidden": 0, "always_hidden": 0]
        for i in items { out[dividers.zone(centerX: i.centerX).rawValue, default: 0] += 1 }
        return out
    }
}

/// What the organizer is doing now.
public struct MenuBarState: Equatable {
    public var running: Bool
    public var collapsed: Bool
    public var showingAlwaysHidden: Bool
    /// An always-hidden divider exists (option on and gadget running).
    public var hasAlwaysHiddenSection: Bool
    public var autoCollapseSeconds: Int
    public var expandOnHover: Bool
    /// macOS did not let the divider grow, so collapsing hides nothing.
    public var dividerFailed: Bool

    public init(running: Bool, collapsed: Bool, showingAlwaysHidden: Bool = false, hasAlwaysHiddenSection: Bool = false,
                autoCollapseSeconds: Int = 10, expandOnHover: Bool = false, dividerFailed: Bool = false) {
        self.running = running
        self.collapsed = collapsed
        self.showingAlwaysHidden = showingAlwaysHidden
        self.hasAlwaysHiddenSection = hasAlwaysHiddenSection
        self.autoCollapseSeconds = autoCollapseSeconds
        self.expandOnHover = expandOnHover
        self.dividerFailed = dividerFailed
    }

    public var details: [String: Any] {
        ["collapsed": collapsed, "showing_always_hidden": showingAlwaysHidden,
         "always_hidden_section": hasAlwaysHiddenSection, "auto_collapse_seconds": autoCollapseSeconds,
         "expand_on_hover": expandOnHover, "divider_failed": dividerFailed]
    }

    public var summaryLine: String {
        let fold = collapsed ? "folded" : (showingAlwaysHidden ? "expanded (always-hidden section shown)" : "expanded")
        let auto = autoCollapseSeconds > 0 ? "auto-collapse after \(autoCollapseSeconds) s" : "auto-collapse off"
        return "Menu bar is \(fold); \(auto); always-hidden section \(hasAlwaysHiddenSection ? "on" : "off")."
    }
}

/// The result of reading the menu bar through Accessibility.
public enum MenuBarReading {
    case items([MenuBarItem], dividers: MenuBarDividers)
    /// Accessibility is not allowed (or was revoked while reading).
    case permissionNeeded
}

/// App side of the menu bar tools. Every call answers through `done`, exactly once, on any thread; the app implements it
/// by hopping to the main thread (never blocks).
public protocol MenuBarControlling: AnyObject {
    func state(done: @escaping (MenuBarState) -> Void)
    /// Folds (true) or unfolds (false). The answer is the state after macOS had time to apply it.
    func setCollapsed(_ collapsed: Bool, done: @escaping (MenuBarState) -> Void)
    /// Folds now and drops the "always-hidden shown" state: the hide rules (divider, auto-collapse) apply at once.
    func tidy(done: @escaping (MenuBarState) -> Void)
    /// Unfolds everything including the always-hidden section, until the next fold.
    func showHidden(done: @escaping (MenuBarState) -> Void)
    func readItems(done: @escaping (MenuBarReading) -> Void)
}

public struct MenuBarProblem: Error, Equatable { public let message: String }

/// Parsed tool call.
public enum MenuBarCommand: Equatable {
    case status
    case listItems
    case tidy
    case setCollapsed(Bool)
    case showHidden

    public static func parse(action: String, arguments: [String: JSONValue]) -> Result<MenuBarCommand, MenuBarProblem> {
        func bad(_ text: String) -> Result<MenuBarCommand, MenuBarProblem> { .failure(MenuBarProblem(message: text)) }
        let allowed: Set<String> = action == "set_collapsed" ? ["collapsed"] : []
        let extra = Set(arguments.keys).subtracting(allowed)
        guard extra.isEmpty else { return bad("bad parameters: unknown field \(extra.sorted().joined(separator: ", "))") }
        switch action {
        case "status": return .success(.status)
        case "list_items": return .success(.listItems)
        case "tidy": return .success(.tidy)
        case "show_hidden": return .success(.showHidden)
        case "set_collapsed":
            guard case .bool(let value)? = arguments["collapsed"] else { return bad("bad parameters: collapsed must be true or false") }
            return .success(.setCollapsed(value))
        default: return bad("unknown menubar action \(action)")
        }
    }
}

/// Runs the `menubar_*` tools against a `MenuBarControlling`.
public final class MenuBarToolRunner: GadgetToolRunning {
    private weak var controller: MenuBarControlling?

    public init(controller: MenuBarControlling) { self.controller = controller }

    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        let command: MenuBarCommand
        switch MenuBarCommand.parse(action: tool.action, arguments: arguments) {
        case .failure(let problem): return done(PetCommandOutcome(ok: false, message: problem.message))
        case .success(let c): command = c
        }
        guard let c = controller else { return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing")) }
        switch command {
        case .status:
            c.state { done(Self.statusOutcome($0)) }
        case .listItems:
            c.readItems { reading in
                switch reading {
                case .permissionNeeded: done(.permissionNeeded(.menubar, .accessibility))
                case let .items(items, dividers): done(Self.itemsOutcome(items, dividers: dividers))
                }
            }
        case .tidy:
            c.state { before in
                guard before.running else { return done(.gadgetOff(.menubar)) }
                c.tidy { after in done(Self.foldOutcome(before: before, after: after, verb: "Tidied")) }
            }
        case .setCollapsed(let value):
            c.state { before in
                guard before.running else { return done(.gadgetOff(.menubar)) }
                c.setCollapsed(value) { after in done(Self.foldOutcome(before: before, after: after, verb: value ? "Folded" : "Unfolded")) }
            }
        case .showHidden:
            c.state { before in
                guard before.running else { return done(.gadgetOff(.menubar)) }
                c.showHidden { after in
                    var note = after.hasAlwaysHiddenSection ? "" : " (the always-hidden section is off, so this only unfolded the bar)"
                    if after.collapsed { note += " — still folded" }
                    done(PetCommandOutcome(ok: !after.collapsed, message: "Showing all menu bar items\(note).", details: after.details))
                }
            }
        }
    }

    static func statusOutcome(_ s: MenuBarState) -> PetCommandOutcome {
        guard s.running else { return .gadgetOff(.menubar) }
        return PetCommandOutcome(ok: true, message: s.summaryLine, details: s.details)
    }

    static func itemsOutcome(_ items: [MenuBarItem], dividers: MenuBarDividers) -> PetCommandOutcome {
        let list = MenuBarSerializer.serialize(items, dividers: dividers)
        var details: [String: Any] = ["items": list, "count": items.count, "zones": MenuBarSerializer.counts(items, dividers: dividers),
                                      "dividers_known": dividers.divider != nil]
        if items.count > list.count { details["truncated"] = true }
        let note = dividers.divider == nil ? " The organizer is not running, so every item counts as visible." : ""
        return PetCommandOutcome(ok: true, message: "\(items.count) menu bar items read through Accessibility.\(note)", details: details)
    }

    static func foldOutcome(before: MenuBarState, after: MenuBarState, verb: String) -> PetCommandOutcome {
        if after.dividerFailed {
            return PetCommandOutcome(ok: false, message: "macOS kept the divider small, so folding hides nothing on this Mac.",
                                     details: after.details.merging(["reason": "divider_failed"]) { a, _ in a })
        }
        var details = after.details
        details["changed"] = before.collapsed != after.collapsed || before.showingAlwaysHidden != after.showingAlwaysHidden
        return PetCommandOutcome(ok: true, message: "\(verb). \(after.summaryLine)", details: details)
    }
}
