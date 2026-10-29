import AppKit
import NachoComboCore

/// Focus Dim's focus sessions: a timer (25 minutes by default) with a break after it, a countdown in the menu bar while
/// it runs, and a Shortcut of the user's own at the start and the end (run with the `shortcuts` command, which needs no
/// permission). The status item exists only during a session.
final class FocusSessionController: NSObject, NSMenuDelegate {
    var optionsProvider: () -> GadgetOptions = { .defaults }
    /// The phase changed (the shade may come or go).
    var onPhaseChange: (() -> Void)?
    var onStatusItemsChanged: (() -> Void)?
    var openSettings: (() -> Void)?

    private(set) var session = FocusSession()
    private var timer: Timer?
    private var item: NSStatusItem?
    private(set) var lastShortcutRun = "-"

    var phase: FocusSession.Phase { session.phase }
    var isActive: Bool { session.isActive }
    var completed: Int { session.completed }

    var remainingText: String { FocusSession.clock(session.remaining(now: Date())) }

    var statusText: String {
        switch session.phase {
        case .idle: return session.completed > 0 ? "\(session.completed) focus session\(session.completed == 1 ? "" : "s") done" : "No session"
        case .focus: return "Focus · \(remainingText) left"
        case .rest: return "Break · \(remainingText) left"
        }
    }

    func toggle() { session.isActive ? stop() : start() }

    func start() {
        let options = optionsProvider()
        session.start(now: Date(), minutes: options.focusMinutes)
        run(options.sessionStartShortcut)
        showItem()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
        onPhaseChange?()
    }

    func stop() {
        let wasFocusing = session.phase == .focus
        session.stop()
        timer?.invalidate()
        timer = nil
        removeItem()
        if wasFocusing { run(optionsProvider().sessionEndShortcut) }
        onPhaseChange?()
    }

    /// Ends the gadget's part without running the end Shortcut (the gadget is being switched off).
    func cancel() {
        session.stop()
        timer?.invalidate()
        timer = nil
        removeItem()
    }

    func skipBreak() {
        guard session.phase == .rest else { return }
        stop()
    }

    private func tick() {
        let options = optionsProvider()
        switch session.tick(now: Date(), breakMinutes: options.breakMinutes) {
        case .focusEnded?:
            NSSound(named: "Glass")?.play()
            run(options.sessionEndShortcut)
            let note = session.phase == .rest ? "Focus done. Take a \(options.breakMinutes)-minute break." : "Focus done."
            Toast.show(note, near: NSEvent.mouseLocation)
            onPhaseChange?()
        case .restEnded?:
            NSSound(named: "Purr")?.play()
            Toast.show("Break over", near: NSEvent.mouseLocation)
            onPhaseChange?()
        case nil:
            break
        }
        guard session.isActive else {
            timer?.invalidate()
            timer = nil
            removeItem()
            return
        }
        refreshItem()
    }

    /// Runs one of the user's Shortcuts by name (fire and forget).
    private func run(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", trimmed]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); lastShortcutRun = trimmed } catch { lastShortcutRun = "error:\(trimmed)" }
    }

    /// The user's Shortcuts, for the pickers (read once, in the background).
    static private(set) var shortcutNames: [String] = []
    static private var loading = false

    static func loadShortcutNames(_ done: @escaping () -> Void) {
        guard !loading, shortcutNames.isEmpty else { done(); return }
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                    .filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
            DispatchQueue.main.async {
                shortcutNames = names
                loading = false
                done()
            }
        }
    }

    // MARK: status item

    private func showItem() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(itemClicked)
        item.button?.imagePosition = .imageLeading
        self.item = item
        onStatusItemsChanged?()
    }

    private func removeItem() {
        guard let item = item else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }

    private func refreshItem() {
        guard let button = item?.button else { return }
        let symbol = session.phase == .rest ? "cup.and.saucer" : "timer"
        if let image = UI.symbol(symbol, size: 13, weight: .medium, description: "Focus session") {
            image.isTemplate = true
            button.image = image
        }
        button.attributedTitle = NSAttributedString(string: " " + remainingText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        button.toolTip = "Focus Dim — \(statusText)"
        button.setAccessibilityLabel("Focus session")
        button.setAccessibilityValue(statusText)
    }

    @objc private func itemClicked() {
        guard let item = item else { return }
        let menu = NSMenu()
        menu.delegate = self
        let state = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        if session.phase == .rest {
            menu.addItem(ClosureMenuItem(title: "Skip the Break") { [weak self] in self?.skipBreak() })
        }
        menu.addItem(ClosureMenuItem(title: "Stop Focus Session") { [weak self] in self?.stop() })
        menu.addItem(ClosureMenuItem(title: "Focus Dim Settings…") { [weak self] in self?.openSettings?() })
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { item?.menu = nil }

    var diagnostics: [String: String] {
        ["sessionPhase": session.phase.rawValue, "sessionRemaining": remainingText, "sessionItem": "\(item != nil)",
         "sessionsDone": "\(session.completed)", "sessionShortcut": lastShortcutRun]
    }
}
