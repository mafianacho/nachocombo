import AppKit
import NachoComboCore

/// Registers the per-tool "open this tool's panel" shortcuts. These only navigate the panel; the gadgets' action
/// shortcuts are registered by `ActionShortcutCenter` and only while their gadget runs.
final class ToolShortcutCenter {
    private let hotKeys = HotKeyCenter(signature: 0x4E43_544F)   // 'NCTO'
    private(set) var failed: Set<ModuleID> = []
    private(set) var firedCount = 0
    var onTrigger: ((ModuleID) -> Void)?

    var registeredCount: Int { hotKeys.registeredCount }

    func apply(_ shortcuts: [String: ToolShortcut]) {
        hotKeys.unregisterAll()
        failed = []
        for (index, id) in ModuleID.allCases.enumerated() {
            guard let s = shortcuts[id.rawValue] else { continue }
            let ok = hotKeys.register(id: UInt32(index + 1), keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
                self?.firedCount += 1
                DispatchQueue.main.async { self?.onTrigger?(id) }
            }
            if !ok { failed.insert(id) }
        }
    }

    /// While the user records a new shortcut the existing ones must not swallow the key press.
    func suspend() { hotKeys.unregisterAll() }
}

/// Registers the gadgets' action shortcuts (snap left, show shelf, capture area...) for the gadgets that are running.
/// A gadget that is off has none registered; the owner re-applies whenever a gadget or a shortcut changes.
final class ActionShortcutCenter {
    private let hotKeys = HotKeyCenter(signature: 0x4E43_4143)   // 'NCAC'
    private(set) var registered: [String: ToolShortcut] = [:]
    /// Set, wanted, but refused by macOS (usually another app holds the combination).
    private(set) var failed: Set<String> = []
    private(set) var firedCount = 0
    var onTrigger: ((String) -> Void)?

    var registeredCount: Int { hotKeys.registeredCount }

    func registeredCount(for module: ModuleID) -> Int {
        registered.keys.filter { GadgetActions.action($0)?.module == module }.count
    }

    /// `wanted`: action id → shortcut, for running gadgets only.
    func apply(_ wanted: [String: ToolShortcut]) {
        hotKeys.unregisterAll()
        registered = [:]
        failed = []
        for (index, action) in GadgetActions.all.enumerated() {
            guard let s = wanted[action.id] else { continue }
            let id = action.id
            let ok = hotKeys.register(id: UInt32(index + 1), keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
                self?.firedCount += 1
                DispatchQueue.main.async { self?.onTrigger?(id) }
            }
            if ok { registered[id] = s } else { failed.insert(id) }
        }
    }

    func suspend() {
        hotKeys.unregisterAll()
        registered = [:]
    }
}
