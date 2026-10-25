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
        modifierGlyphs(modifiers) + (names[keyCode] ?? "키\(keyCode)")
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
            return "이 키는 단축키로 쓸 수 없습니다."
        case .needsMoreModifiers:
            return "⌃ 또는 ⌥를 포함해 수정 키를 두 개 이상 눌러야 합니다(일반 입력·앱 단축키와의 충돌 방지)."
        case .reservedBySystem(let name):
            return "macOS가 쓰는 조합입니다(\(name))."
        case .conflictsWithAction(let name):
            return "이미 기능 실행 단축키로 쓰입니다(\(name))."
        case .conflictsWithTool(let id):
            return "‘\(id.displayName)’ 열기 단축키와 같습니다."
        }
    }
}

public enum ShortcutPolicy {
    /// Fixed action shortcuts owned by the gadgets. A tool-open shortcut must never shadow them.
    public static let actionShortcuts: [(name: String, keyCode: UInt32, modifiers: UInt32)] = {
        let co = ToolShortcut.control | ToolShortcut.option
        return [
            ("창 배치 왼쪽 ⌃⌥←", 123, co), ("창 배치 오른쪽 ⌃⌥→", 124, co), ("창 배치 최대화 ⌃⌥↩", 36, co),
            ("파일 선반 ⌃⌥S", 1, co), ("캡처 고정 ⌃⌥C", 8, co), ("집중 디밍 해제 ⌃⌥D", 2, co),
        ]
    }()

    private static let reserved: [(name: String, keyCode: UInt32, modifiers: UInt32)] = {
        let c = ToolShortcut.command, o = ToolShortcut.option, ct = ToolShortcut.control, s = ToolShortcut.shift
        return [
            ("화면 잠금 ⌃⌘Q", 12, ct | c), ("전체 화면 ⌃⌘F", 3, ct | c), ("이모지 ⌃⌘Space", 49, ct | c),
            ("강제 종료 ⌘⌥⎋", 53, c | o), ("Dock 숨김 ⌘⌥D", 2, c | o), ("Finder 검색 ⌘⌥Space", 49, c | o),
            ("다른 앱 숨기기 ⌘⌥H", 4, c | o), ("모두 최소화 ⌘⌥M", 46, c | o),
            ("화면 캡처 ⌃⇧⌘3", 20, ct | s | c), ("화면 캡처 ⌃⇧⌘4", 21, ct | s | c), ("화면 캡처 ⌃⇧⌘5", 23, ct | s | c),
            ("스페이스 이동 ⌃⌥Space", 49, ct | o),
        ]
    }()

    public static func validate(_ shortcut: ToolShortcut, for id: ModuleID,
                                existing: [String: ToolShortcut]) -> ShortcutIssue? {
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
        if let hit = actionShortcuts.first(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == mods }) {
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
}
