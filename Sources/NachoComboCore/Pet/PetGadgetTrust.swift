import Foundation

// "Always allow" per gadget (NACHO-138). Content that leaves the Mac (clipboard text, a shelf file, a capture) is asked
// for with an approval card every time; the user can switch one gadget to "always allow". The switch is stored in the
// app's own folder (default off), and a gadget that is switched on declares its content actions without the
// `approval` field (`PetCommands.capabilities(allowQuit:alwaysAllowed:disabled:)`).
//
// `disabled` is the extension point of NACHO-131 (the Connections tab switches single Mac actions off): capability
// names in it are neither declared nor run. This file only holds the set; it has no storage or screen for it.

public final class PetGadgetTrust {
    /// The app-wide switches. In memory until `attach(url:)` (the app delegate does that at launch), so tests that
    /// build the hello frame never read the user's file.
    public static let shared = PetGadgetTrust()

    private let lock = NSLock()
    private var allowed: Set<ModuleID> = []
    private var off: Set<String> = []
    private var url: URL?
    private var observers: [UUID: () -> Void] = [:]

    public init(url: URL? = nil) {
        self.url = url
        if url != nil { allowed = loadFromDisk() }
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NachoCombo", isDirectory: true).appendingPathComponent("gadget-trust.json")
    }

    /// Starts keeping the switches in `url` (read now, written on every change).
    public func attach(url: URL) {
        lock.lock()
        self.url = url
        let loaded = loadFromDisk()
        let changed = loaded != allowed
        allowed = loaded
        lock.unlock()
        if changed { notify() }
    }

    /// The gadgets whose content actions run without an approval card.
    public var alwaysAllowed: Set<ModuleID> {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    public func isAlwaysAllowed(_ id: ModuleID) -> Bool { alwaysAllowed.contains(id) }

    /// Only the gadgets with a content action can be switched (`PetGadgetCommands.trustable`).
    @discardableResult
    public func setAlwaysAllowed(_ id: ModuleID, _ on: Bool) -> Bool {
        guard PetGadgetCommands.trustable.contains(id) else { return false }
        lock.lock()
        let changed = on ? allowed.insert(id).inserted : allowed.remove(id) != nil
        if changed { saveToDisk() }
        lock.unlock()
        if changed { notify() }
        return changed
    }

    /// Capability names the user switched off (NACHO-131 fills this).
    public var disabled: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return off
        }
        set {
            lock.lock()
            let changed = newValue != off
            off = newValue
            lock.unlock()
            if changed { notify() }
        }
    }

    /// Called (on the thread that changed the switch) after `alwaysAllowed` or `disabled` changed.
    @discardableResult
    public func observe(_ change: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        observers[token] = change
        lock.unlock()
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock()
        observers[token] = nil
        lock.unlock()
    }

    private func notify() {
        lock.lock()
        let calls = Array(observers.values)
        lock.unlock()
        for call in calls { call() }
    }

    // MARK: file (caller holds the lock)

    private struct Stored: Codable { var alwaysAllowed: [String] }

    private func loadFromDisk() -> Set<ModuleID> {
        guard let url = url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [] }
        return Set(stored.alwaysAllowed.compactMap { ModuleID(rawValue: $0) }.filter { PetGadgetCommands.trustable.contains($0) })
    }

    private func saveToDisk() {
        guard let url = url else { return }
        let stored = Stored(alwaysAllowed: allowed.map { $0.rawValue }.sorted())
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            // A switch that cannot be stored stays on for this run only; nothing else depends on the file.
        }
    }
}
