import Foundation

// "Always allow" per gadget (NACHO-138 rule, boss decision msg 1571031689617211507). On the connector path a
// content_out / input_inject tool is declared with `"approval": "required"` (nacho-server shows an approval card every
// time) unless the user switched its gadget to "always allow" (default off). destructive tools always ask.
// The switches live in their own small file next to settings.json (`gadget-trust.json`, like the workspaces file);
// every change notifies the observers, and the connector declares its capabilities again.
//
// `disabled` is the extension point for NACHO-131 (the Connections tab switches single actions off): connector names
// in it are neither declared nor run. Memory only here; NACHO-131 decides where it is stored.

public final class GadgetTrust {
    /// The app-wide switches. In memory until `attach(url:)` (the app delegate does that at launch), so tests that
    /// build the hello frame never read the user's file.
    public static let shared = GadgetTrust()

    private let lock = NSLock()
    private var allowed: Set<GadgetID> = []
    private var off: Set<String> = []
    private var url: URL?
    private var observers: [UUID: () -> Void] = [:]
    private let trustable: () -> Set<GadgetID>

    /// `trustable`: the gadgets that may be switched (default: those with a content_out / input_inject connector tool).
    public init(url: URL? = nil, trustable: @escaping () -> Set<GadgetID> = { GadgetToolRegistry.trustableGadgets() }) {
        self.trustable = trustable
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

    /// The gadgets whose content_out / input_inject tools are declared without an approval card.
    public var alwaysAllowed: Set<GadgetID> {
        lock.lock(); defer { lock.unlock() }
        return allowed
    }

    public func isAlwaysAllowed(_ id: GadgetID) -> Bool { alwaysAllowed.contains(id) }

    public var trustableGadgets: Set<GadgetID> { trustable() }

    /// false (and nothing changes) for a gadget without a trustable tool.
    @discardableResult
    public func setAlwaysAllowed(_ id: GadgetID, _ on: Bool) -> Bool {
        guard !on || trustable().contains(id) else { return false }
        lock.lock()
        let changed = on ? allowed.insert(id).inserted : allowed.remove(id) != nil
        if changed { saveToDisk() }
        lock.unlock()
        if changed { notify() }
        return changed
    }

    /// Connector names the user switched off (NACHO-131 fills this).
    public var disabled: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return off }
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
        lock.lock(); observers[token] = change; lock.unlock()
        return token
    }

    public func removeObserver(_ token: UUID) {
        lock.lock(); observers[token] = nil; lock.unlock()
    }

    private func notify() {
        lock.lock()
        let calls = Array(observers.values)
        lock.unlock()
        for call in calls { call() }
    }

    // MARK: file (caller holds the lock)

    private struct Stored: Codable {
        var version: Int?
        var alwaysAllowed: [String]
    }

    private func loadFromDisk() -> Set<GadgetID> {
        guard let url = url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return [] }
        let ok = trustable()
        return Set(stored.alwaysAllowed.compactMap { GadgetID(rawValue: $0) }.filter { ok.contains($0) })
    }

    private func saveToDisk() {
        guard let url = url else { return }
        let stored = Stored(version: 1, alwaysAllowed: allowed.map { $0.rawValue }.sorted())
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            // A switch that cannot be stored stays on for this run only; nothing else depends on the file.
        }
    }
}
