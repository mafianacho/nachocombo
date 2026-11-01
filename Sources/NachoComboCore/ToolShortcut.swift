import Foundation

/// A user-chosen global shortcut that opens a tool's panel screen directly.
/// It never runs the tool's action; the tool's own action shortcuts (e.g. ⌃⌥S) are separate and fixed.
public struct ToolShortcut: Codable, Equatable {
    public var keyCode: UInt32
    /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12
    public static let allModifiers: UInt32 = command | shift | option | control

    public var label: String { KeyNames.label(keyCode: keyCode, modifiers: modifiers) }
}

public enum KeyNames {
    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`",
        51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func name(forKeyCode code: UInt32) -> String? { names[code] }

    public static func isFunctionKey(_ code: UInt32) -> Bool {
        [96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122].contains(code)
    }

    public static func modifierGlyphs(_ modifiers: UInt32) -> String {
        var s = ""
        if modifiers & ToolShortcut.control != 0 { s += "⌃" }
        if modifiers & ToolShortcut.option != 0 { s += "⌥" }
        if modifiers & ToolShortcut.shift != 0 { s += "⇧" }
        if modifiers & ToolShortcut.command != 0 { s += "⌘" }
        return s
    }

    public static func label(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierGlyphs(modifiers) + (names[keyCode] ?? "Key \(keyCode)")
    }
}

public enum ShortcutIssue: Equatable {
    case unsupportedKey
    case needsMoreModifiers
    case reservedBySystem(String)
    case conflictsWithAction(String)
    case conflictsWithTool(ModuleID)

    public var message: String {
        switch self {
        case .unsupportedKey:
            return "This key cannot be used in a shortcut."
        case .needsMoreModifiers:
            return "Use at least two modifier keys (open shortcuts also need ⌃ or ⌥), so it never clashes with typing."
        case .reservedBySystem(let name):
            return "macOS uses this combination (\(name))."
        case .conflictsWithAction(let name):
            return "Already used as an action shortcut (\(name))."
        case .conflictsWithTool(let id):
            return "Same as the open shortcut of ‘\(id.displayName)’."
        }
    }
}

public enum ShortcutPolicy {
    /// Default action shortcuts owned by the gadgets (what a fresh install registers).
    public static var actionShortcuts: [(name: String, keyCode: UInt32, modifiers: UInt32)] {
        AppSettings.defaults.effectiveActionShortcuts.map { ($0.name, $0.keyCode, $0.modifiers) }
    }

    private static let reserved: [(name: String, keyCode: UInt32, modifiers: UInt32)] = {
        let c = ToolShortcut.command, o = ToolShortcut.option, ct = ToolShortcut.control, s = ToolShortcut.shift
        return [
            ("Lock Screen ⌃⌘Q", 12, ct | c), ("Full Screen ⌃⌘F", 3, ct | c), ("Emoji ⌃⌘Space", 49, ct | c),
            ("Force Quit ⌘⌥⎋", 53, c | o), ("Hide Dock ⌘⌥D", 2, c | o), ("Finder Search ⌘⌥Space", 49, c | o),
            ("Hide Others ⌘⌥H", 4, c | o), ("Minimize All ⌘⌥M", 46, c | o),
            ("Screenshot ⇧⌘3", 20, s | c), ("Screenshot ⇧⌘4", 21, s | c), ("Screenshot ⇧⌘5", 23, s | c),
            ("Screenshot ⇧⌘6", 22, s | c),
            ("Screenshot ⌃⇧⌘3", 20, ct | s | c), ("Screenshot ⌃⇧⌘4", 21, ct | s | c), ("Screenshot ⌃⇧⌘5", 23, ct | s | c),
            ("Switch Space ⌃⌥Space", 49, ct | o), ("Spotlight ⌘Space", 49, c), ("Input Source ⌃Space", 49, ct),
            ("Mission Control ⌃↑", 126, ct), ("App Windows ⌃↓", 125, ct),
            ("App Switcher ⌘Tab", 48, c), ("App Switcher ⌘⇧Tab", 48, c | s),
        ]
    }()

    /// Tool-open shortcut check. `actions` are the action shortcuts in use (defaults unless given).
    public static func validate(_ shortcut: ToolShortcut, for id: ModuleID, existing: [String: ToolShortcut],
                                actions: [(name: String, keyCode: UInt32, modifiers: UInt32)]? = nil) -> ShortcutIssue? {
        let mods = shortcut.modifiers & ToolShortcut.allModifiers
        guard KeyNames.name(forKeyCode: shortcut.keyCode) != nil, shortcut.keyCode != 51, shortcut.keyCode != 53 else {
            return .unsupportedKey
        }
        let count = [ToolShortcut.command, ToolShortcut.shift, ToolShortcut.option, ToolShortcut.control]
            .filter { mods & $0 != 0 }.count
        let hasControlOrOption = mods & (ToolShortcut.control | ToolShortcut.option) != 0
        let functionKey = KeyNames.isFunctionKey(shortcut.keyCode)
        let enough = functionKey ? (mods & (ToolShortcut.control | ToolShortcut.option | ToolShortcut.command) != 0)
                                 : (count >= 2 && hasControlOrOption)
        guard enough else { return .needsMoreModifiers }
        if let hit = reserved.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == mods }) {
            return .reservedBySystem(hit.name)
        }
        if let hit = (actions ?? actionShortcuts).first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == mods }) {
            return .conflictsWithAction(hit.name)
        }
        for other in ModuleID.allCases where other != id {
            if let s = existing[other.rawValue], s.keyCode == shortcut.keyCode,
               s.modifiers & ToolShortcut.allModifiers == mods {
                return .conflictsWithTool(other)
            }
        }
        return nil
    }

    /// Action shortcut check: any two modifiers (or one with a function key), not a macOS combination, not used by
    /// another action or a tool-open shortcut. Delete is allowed (Restore uses ⌃⌥⌫); Escape is not.
    public static func validateAction(_ shortcut: ToolShortcut, actionID: String, settings: AppSettings) -> ShortcutIssue? {
        let mods = shortcut.modifiers & ToolShortcut.allModifiers
        guard KeyNames.name(forKeyCode: shortcut.keyCode) != nil, shortcut.keyCode != 53 else { return .unsupportedKey }
        let count = [ToolShortcut.command, ToolShortcut.shift, ToolShortcut.option, ToolShortcut.control]
            .filter { mods & $0 != 0 }.count
        // Tab with ⌥ (or ⌥⇧) is held to switch windows, like ⌘Tab: one modifier is enough there.
        let holdToSwitch = shortcut.keyCode == 48 && (mods == ToolShortcut.option || mods == ToolShortcut.option | ToolShortcut.shift)
        let enough = KeyNames.isFunctionKey(shortcut.keyCode) ? count >= 1 : (count >= 2 || holdToSwitch)
        guard enough else { return .needsMoreModifiers }
        if let hit = reserved.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == mods }) {
            return .reservedBySystem(hit.name)
        }
        if let hit = settings.options.appShortcuts.first(where: {
            $0.shortcut?.keyCode == shortcut.keyCode && ($0.shortcut?.modifiers ?? 0) & ToolShortcut.allModifiers == mods
        }) {
            return .conflictsWithAction("\(hit.name) (App Switch)")
        }
        if let hit = settings.effectiveActionShortcuts.first(where: {
            $0.id != actionID && $0.keyCode == shortcut.keyCode && $0.modifiers == mods
        }) {
            return .conflictsWithAction(hit.name)
        }
        for id in ModuleID.allCases {
            if let s = settings.toolShortcuts[id.rawValue], s.keyCode == shortcut.keyCode,
               s.modifiers & ToolShortcut.allModifiers == mods {
                return .conflictsWithTool(id)
            }
        }
        return nil
    }
}

public extension ShortcutPolicy {
    /// An app shortcut (App Switch): two modifiers, not a macOS combination, not another action, tool or app shortcut.
    static func validateAppShortcut(_ shortcut: ToolShortcut, bundleID: String, settings: AppSettings) -> ShortcutIssue? {
        let mods = shortcut.modifiers & ToolShortcut.allModifiers
        guard KeyNames.name(forKeyCode: shortcut.keyCode) != nil, shortcut.keyCode != 53 else { return .unsupportedKey }
        let count = [ToolShortcut.command, ToolShortcut.shift, ToolShortcut.option, ToolShortcut.control]
            .filter { mods & $0 != 0 }.count
        guard KeyNames.isFunctionKey(shortcut.keyCode) ? count >= 1 : count >= 2 else { return .needsMoreModifiers }
        if let hit = reserved.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == mods }) {
            return .reservedBySystem(hit.name)
        }
        if let hit = settings.effectiveActionShortcuts.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == mods }) {
            return .conflictsWithAction(hit.name)
        }
        if let hit = settings.options.appShortcuts.first(where: {
            $0.bundleID != bundleID && $0.shortcut?.keyCode == shortcut.keyCode
                && ($0.shortcut?.modifiers ?? 0) & ToolShortcut.allModifiers == mods
        }) {
            return .conflictsWithAction("\(hit.name) (App Switch)")
        }
        for id in ModuleID.allCases {
            if let s = settings.toolShortcuts[id.rawValue], s.keyCode == shortcut.keyCode,
               s.modifiers & ToolShortcut.allModifiers == mods {
                return .conflictsWithTool(id)
            }
        }
        return nil
    }
}
