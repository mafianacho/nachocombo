import Foundation

/// What a secret store answered. `unavailable` is not "signed out": the item may well be there (the user pressed
/// 거부 on the Keychain prompt, canceled it, or the Keychain is locked), so nothing may be overwritten or deleted
/// because of it; the next access asks again.
public enum PetSecretLookup: Equatable {
    case found(Data)
    case missing
    /// OSStatus (Keychain) or another store-specific code.
    case unavailable(Int32)
}

public struct PetSecretUnavailable: Error, Equatable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
}

/// Where secrets live: the Keychain in the app, a 0600 file in the dev CLI, memory in tests.
public protocol PetSecretStore: AnyObject {
    func lookup(_ key: String) -> PetSecretLookup
    func write(_ key: String, _ value: Data) throws
    func delete(_ key: String)
}

public extension PetSecretStore {
    /// The value, or nil when it is missing *or* could not be read. Use `lookup` where the two must differ.
    func read(_ key: String) -> Data? {
        if case let .found(data) = lookup(key) { return data }
        return nil
    }
}

public final class MemorySecretStore: PetSecretStore {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public func lookup(_ key: String) -> PetSecretLookup {
        lock.lock(); defer { lock.unlock() }
        return values[key].map { .found($0) } ?? .missing
    }
    public func write(_ key: String, _ value: Data) throws { lock.lock(); values[key] = value; lock.unlock() }
    public func delete(_ key: String) { lock.lock(); values[key] = nil; lock.unlock() }
    public var keys: [String] { lock.lock(); defer { lock.unlock() }; return Array(values.keys) }
}

/// Every pet secret (tokens of each account scope, connector bindings) in one item of `backing`, read once per launch
/// and kept in memory. Why one item: in the login Keychain each item has its own access list, and an ad-hoc signed
/// build is a new code identity (its cdhash), so before NACHO-156 every item could ask "allow access" on every new
/// build, and each launch read up to three items. Now a launch reads one item: at most one prompt.
///
/// Items of earlier versions (one per key) are moved in on first use: read once, copied into the bundle, and then never
/// read again. They are not deleted then (a delete can be one more prompt); they go when their key is deleted
/// (sign out, dead login), so an old item can never bring a signed-out login back.
///
/// A refused read (`unavailable`) is not cached as "empty": nothing is written over the bundle until it was read, and
/// the next access asks the Keychain again.
public final class PetSecretBundle: PetSecretStore {
    public static let account = "pet-secrets.v1"

    struct Contents: Codable, Equatable {
        var items: [String: Data] = [:]
        /// Keys whose item of an earlier version was moved in already (or found missing): not looked up again.
        var moved: Set<String> = []
    }

    private let backing: PetSecretStore
    private let lock = NSLock()
    private var contents: Contents?
    /// Earlier-version items found missing in this launch (no prompt, but no need to ask twice).
    private var checked: Set<String> = []

    public init(backing: PetSecretStore) { self.backing = backing }

    /// nil when the bundle is in memory; otherwise why it could not be read.
    private func loadLocked() -> Int32? {
        if contents != nil { return nil }
        switch backing.lookup(PetSecretBundle.account) {
        case let .found(data):
            // Unreadable contents hold nothing usable: start empty (the next write replaces them).
            contents = (try? JSONDecoder().decode(Contents.self, from: data)) ?? Contents()
        case .missing:
            contents = Contents()
        case let .unavailable(status):
            return status
        }
        return nil
    }

    private func saveLocked(_ next: Contents) throws {
        let data = try JSONEncoder().encode(next)
        try backing.write(PetSecretBundle.account, data)
        contents = next
    }

    public func lookup(_ key: String) -> PetSecretLookup {
        lock.lock(); defer { lock.unlock() }
        if let status = loadLocked() { return .unavailable(status) }
        guard var c = contents else { return .missing }
        if let data = c.items[key] { return .found(data) }
        if c.moved.contains(key) || checked.contains(key) || key == PetSecretBundle.account { return .missing }
        switch backing.lookup(key) {  // an item of an earlier version
        case .missing:
            checked.insert(key)
            return .missing
        case let .unavailable(status):
            return .unavailable(status)
        case let .found(data):
            c.items[key] = data
            c.moved.insert(key)
            if (try? saveLocked(c)) == nil {
                contents = c  // kept for this launch; saved with the next write, the old item stays meanwhile
            }
            return .found(data)
        }
    }

    public func write(_ key: String, _ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if let status = loadLocked() { throw PetSecretUnavailable(status: status) }
        var c = contents ?? Contents()
        c.items[key] = value
        c.moved.insert(key)  // an older item of this key is out of date now
        try saveLocked(c)
    }

    public func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        backing.delete(key)  // the item of an earlier version, if any
        checked.insert(key)
        if loadLocked() != nil {
            // Sign out (or a dead login) while the bundle cannot be read: the secret must not come back at the next
            // launch, and it cannot be taken out without reading the rest. Drop the bundle; signing in restores it.
            backing.delete(PetSecretBundle.account)
            contents = nil
            return
        }
        guard var c = contents, c.items[key] != nil || !c.moved.contains(key) else { return }
        c.items[key] = nil
        c.moved.insert(key)
        if (try? saveLocked(c)) == nil { contents = c }
    }
}
