import Foundation

// "Always allow" per gadget (NACHO-138 rule, boss decision msg 1571031689617211507). On the connector path a
// content_out / input_inject tool is declared with `"approval": "required"` (nacho-server shows an approval card every
// time) unless the user switched its gadget to "always allow" (default off). destructive tools always ask.
// The switches live in their own small file next to settings.json (`gadget-trust.json`, like the workspaces file);
// every change notifies the observers, and the connector declares its capabilities again.
//
// `disabled` is where the Connections tab (NACHO-131 / NACHO-239) switches single Mac actions off: connector names in
// it are neither declared nor run. It is stored in the same file as the "always allow" switches, so a restart keeps it.

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
        if url != nil { (allowed, off) = loadFromDisk() }
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
        let changed = loaded.allowed != allowed || loaded.disabled != off
        allowed = loaded.allowed
        off = loaded.disabled
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

    /// Connector names the user switched off in the Connections tab. Stored; the setter notifies the observers.
    public var disabled: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return off }
        set {
            lock.lock()
            let changed = newValue != off
            off = newValue
            if changed { saveToDisk() }
            lock.unlock()
            if changed { notify() }
        }
    }

    /// Whether the user left this action on. Every name the connector knows the tool by counts.
    public func isActionEnabled(_ tool: GadgetTool) -> Bool { disabled.isDisjoint(with: tool.connectorNames) }

    /// Switches one Mac action on or off. The canonical connector name is stored (`combo_<gadget>_<action>`); switching on
    /// removes every name the tool answers to, so an old name saved by an earlier build cannot keep it off.
    public func setActionEnabled(_ tool: GadgetTool, _ enabled: Bool) {
        var names = disabled
        if enabled { names.subtract(tool.connectorNames) } else { names.insert(tool.connectorName) }
        disabled = names
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
        /// Version 2: connector names switched off in the Connections tab. Absent in a version 1 file.
        var disabled: [String]?
    }

    static let maxDisabled = 256

    /// A connector name is `[A-Za-z0-9_-]{1,64}` (the MCP/connector naming rule); anything else in the file is dropped.
    static func isConnectorName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
                || $0 == "_" || $0 == "-"
        }
    }

    private func loadFromDisk() -> (allowed: Set<GadgetID>, disabled: Set<String>) {
        guard let url = url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return ([], []) }
        let ok = trustable()
        let names = (stored.disabled ?? []).filter(GadgetTrust.isConnectorName).prefix(GadgetTrust.maxDisabled)
        return (Set(stored.alwaysAllowed.compactMap { GadgetID(rawValue: $0) }.filter { ok.contains($0) }), Set(names))
    }

    private func saveToDisk() {
        guard let url = url else { return }
        let stored = Stored(version: 2, alwaysAllowed: allowed.map { $0.rawValue }.sorted(), disabled: off.sorted())
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: url, options: .atomic)
        } catch {
            // A switch that cannot be stored stays on for this run only; nothing else depends on the file.
        }
    }
}
