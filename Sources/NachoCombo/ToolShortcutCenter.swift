import AppKit
import NachoComboCore

/// Registers the per-tool "open this tool's panel" shortcuts. These only navigate the panel;
/// the gadgets' own action shortcuts stay inside the gadgets and stop when the gadget is switched off.
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

/// Click, then press the new combination. Esc cancels. Nothing is stored here: the owner validates and saves.
final class ShortcutRecorderButton: NSButton {
    var onRecord: ((ToolShortcut) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?
    private var monitor: Any?
    private(set) var isRecording = false
    var shortcut: ToolShortcut? { didSet { refreshTitle() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(clicked)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTitle()
    }

    private func refreshTitle() {
        let text = isRecording ? "키를 누르세요… (Esc 취소)" : (shortcut?.label ?? "미설정 — 클릭해서 지정")
        // The control glyph (U+2303) is enlarged so it does not read as a plain "^".
        attributedTitle = UI.styled(text, font: UI.font(.callout), color: .labelColor)
        setAccessibilityValue(text)
    }

    @objc private func clicked() { isRecording ? stop() : start() }

    private func start() {
        isRecording = true
        refreshTitle()
        onRecordingChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            if event.keyCode == 53 { self.stop(); return nil }          // Esc cancels
            let mods = UI.modifiersToCarbon(event.modifierFlags)
            self.stop()
            self.onRecord?(ToolShortcut(keyCode: UInt32(event.keyCode), modifiers: mods))
            return nil
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        refreshTitle()
        onRecordingChange?(false)
    }
}
