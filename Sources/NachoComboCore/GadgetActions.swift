import Foundation

/// A global keyboard command of a gadget (snap left, open the shelf, capture an area...). Each one can be given a
/// different shortcut or none in the gallery; `defaultShortcut` is what a fresh install uses.
public struct GadgetAction: Equatable {
    public let id: String
    public let module: ModuleID
    public let title: String
    public let defaultShortcut: ToolShortcut?

    public init(id: String, module: ModuleID, title: String, defaultShortcut: ToolShortcut?) {
        self.id = id
        self.module = module
        self.title = title
        self.defaultShortcut = defaultShortcut
    }
}

/// A user's choice for one action. `shortcut == nil` means the user removed the shortcut.
public struct ActionBinding: Codable, Equatable {
    public var shortcut: ToolShortcut?
    public init(shortcut: ToolShortcut?) { self.shortcut = shortcut }
}

public enum GadgetActions {
    private static func key(_ code: UInt32, _ modifiers: UInt32) -> ToolShortcut { ToolShortcut(keyCode: code, modifiers: modifiers) }

    public static func snapID(_ action: SnapAction) -> String { "snap.\(action.rawValue)" }

    /// Every snap position, with the ⌃⌥ layout of keyboard window managers as defaults.
    public static let snap: [GadgetAction] = SnapAction.allCases.map { action in
        let spec = HotKeySpec.spec(for: action)
        return GadgetAction(id: snapID(action), module: .windowSnap, title: action.displayName,
                            defaultShortcut: spec.map { key($0.keyCode, $0.carbonModifiers) })
    }

    public static let other: [GadgetAction] = {
        let co = ToolShortcut.control | ToolShortcut.option
        return [
            GadgetAction(id: "menuBar.toggle", module: .menuBar, title: "Expand / Collapse", defaultShortcut: nil),
            GadgetAction(id: "menuBar.showAll", module: .menuBar, title: "Show Always-Hidden Icons", defaultShortcut: nil),
            GadgetAction(id: "shelf.toggle", module: .fileShelf, title: "Show / Hide Shelf", defaultShortcut: key(1, co)),
            GadgetAction(id: "shelf.paste", module: .fileShelf, title: "Add Clipboard to Shelf", defaultShortcut: nil),
            GadgetAction(id: "capture.area", module: .captureFloat, title: "Capture Area",
                         defaultShortcut: key(19, ToolShortcut.command | ToolShortcut.shift)),
            GadgetAction(id: "capture.previous", module: .captureFloat, title: "Capture Previous Area", defaultShortcut: nil),
            GadgetAction(id: "capture.window", module: .captureFloat, title: "Capture Window", defaultShortcut: nil),
            GadgetAction(id: "capture.screen", module: .captureFloat, title: "Capture Screen", defaultShortcut: nil),
            GadgetAction(id: "capture.text", module: .captureFloat, title: "Copy Text from Area", defaultShortcut: nil),
            GadgetAction(id: "capture.lock", module: .captureFloat, title: "Lock / Unlock All Floats", defaultShortcut: nil),
            GadgetAction(id: "capture.hide", module: .captureFloat, title: "Hide / Show All Floats", defaultShortcut: nil),
            GadgetAction(id: "capture.closeAll", module: .captureFloat, title: "Close All Floats", defaultShortcut: nil),
            GadgetAction(id: "dim.toggle", module: .focusDim, title: "Pause / Resume Dimming",
                         defaultShortcut: key(4, co | ToolShortcut.command)),
            GadgetAction(id: "monitor.cpu", module: .systemMonitor, title: "Open CPU Panel", defaultShortcut: nil),
            GadgetAction(id: "monitor.memory", module: .systemMonitor, title: "Open Memory Panel", defaultShortcut: nil),
            GadgetAction(id: "monitor.disk", module: .systemMonitor, title: "Open Disk Panel", defaultShortcut: nil),
            GadgetAction(id: "monitor.network", module: .systemMonitor, title: "Open Network Panel", defaultShortcut: nil),
            GadgetAction(id: "monitor.sensors", module: .systemMonitor, title: "Open Sensors Panel", defaultShortcut: nil),
            GadgetAction(id: "monitor.battery", module: .systemMonitor, title: "Open Battery Panel", defaultShortcut: nil),
        ]
    }()

    public static let all: [GadgetAction] = snap + other

    /// Window Snap's positions in the groups the Shortcuts tab shows; every SnapAction appears exactly once.
    public static let snapGroups: [(title: String, actions: [SnapAction])] = [
        ("Halves", [.left, .right, .centerHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird]),
        ("Two Thirds", [.firstTwoThirds, .centerTwoThirds, .lastTwoThirds]),
        ("Size and Position", [.maximize, .almostMaximize, .maximizeHeight, .center, .smaller, .larger, .restore]),
        ("Displays", [.nextDisplay, .previousDisplay]),
    ]

    /// A gadget's actions as the Shortcuts tab lists them: Window Snap in titled groups, the others as one list.
    public static func groups(of module: ModuleID) -> [(title: String?, actions: [GadgetAction])] {
        guard module == .windowSnap else { return [(nil, of(module))] }
        return snapGroups.map { group in (group.title, group.actions.compactMap { action(snapID($0)) }) }
    }

    public static func of(_ module: ModuleID) -> [GadgetAction] { all.filter { $0.module == module } }
    public static func action(_ id: String) -> GadgetAction? { all.first { $0.id == id } }
}

public extension AppSettings {
    /// The shortcut an action uses now: the user's choice, else the default.
    func shortcut(forAction id: String) -> ToolShortcut? {
        if let binding = actionShortcuts[id] { return binding.shortcut }
        return GadgetActions.action(id)?.defaultShortcut
    }

    /// Every action that has a shortcut now, as (name, key, modifiers) for conflict checks.
    var effectiveActionShortcuts: [(name: String, id: String, keyCode: UInt32, modifiers: UInt32)] {
        GadgetActions.all.compactMap { action in
            guard let s = shortcut(forAction: action.id) else { return nil }
            return ("\(action.module.displayName) \(action.title) \(s.label)", action.id, s.keyCode,
                    s.modifiers & ToolShortcut.allModifiers)
        }
    }
}
