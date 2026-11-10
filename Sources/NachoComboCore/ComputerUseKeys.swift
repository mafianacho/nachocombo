import Foundation

public protocol RandomBytesSource {
    func bytes(count: Int) -> [UInt8]
}

/// Default entropy source. `SystemRandomNumberGenerator` is the OS CSPRNG (getentropy / arc4random on macOS,
/// getrandom on Linux). The app may inject a SecRandomCopyBytes-backed source instead.
public struct SystemRandomBytes: RandomBytesSource {
    public init() {}
    public func bytes(count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}

public enum APIKeyError: Error, Equatable {
    case invalidLabel
    case tooManyKeys
    case notFound
    case persistFailed
}

/// What is stored about a key. The key itself is never stored: only its SHA-256 (the key is 256 bits of
/// randomness, so a plain hash is enough and no salting or stretching is needed).
public struct APIKeyRecord: Codable, Equatable {
    public var id: String
    public var label: String
    public var hash: String
    public var createdAt: Date
    public var lastUsedAt: Date?
}

/// The only moment the plaintext key exists outside the client. Show it once, then drop it.
public struct IssuedKey: Equatable {
    public let record: APIKeyRecord
    public let token: String
}

public final class APIKeyStore {
    public static let tokenPrefix = "nccu_"
    public static let maxActiveKeys = 8
    public static let maxLabelLength = 40
    /// `lastUsedAt` is persisted at most this often, so a busy client does not rewrite the file on every request.
    private static let persistInterval: TimeInterval = 60

    public let url: URL?
    public private(set) var lastLoadProblem: String?
    private var stored: [APIKeyRecord] = []
    private var lastPersisted = Date.distantPast
    private let random: RandomBytesSource
    private let now: () -> Date
    private let lock = NSLock()

    private struct FileFormat: Codable {
        var version: Int
        var keys: [APIKeyRecord]
    }

    public init(url: URL?, random: RandomBytesSource = SystemRandomBytes(), now: @escaping () -> Date = Date.init) {
        self.url = url
        self.random = random
        self.now = now
        load()
    }

    public static func defaultURL() -> URL {
        SettingsStore.defaultURL().deletingLastPathComponent().appendingPathComponent("computer-use-keys.json")
    }

    public var records: [APIKeyRecord] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    @discardableResult
    public func create(label: String) throws -> IssuedKey {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= APIKeyStore.maxLabelLength else { throw APIKeyError.invalidLabel }
        lock.lock(); defer { lock.unlock() }
        guard stored.count < APIKeyStore.maxActiveKeys else { throw APIKeyError.tooManyKeys }
        return try issueLocked(label: clean)
    }

    @discardableResult
    public func revoke(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return false }
        let removed = stored.remove(at: index)
        if (try? persistLocked()) == nil { stored.insert(removed, at: index); return false }
        return true
    }

    /// Replaces a key: the old key stops working at once, the new one keeps the label.
    @discardableResult
    public func reissue(id: String) throws -> IssuedKey {
        lock.lock(); defer { lock.unlock() }
        guard let index = stored.firstIndex(where: { $0.id == id }) else { throw APIKeyError.notFound }
        let old = stored.remove(at: index)
        do { return try issueLocked(label: old.label) } catch {
            stored.insert(old, at: index)
            throw error
        }
    }

    /// Checks every stored hash (no early exit) so timing does not reveal which key matched.
    public func authenticate(token: String) -> APIKeyRecord? {
        let candidate = [UInt8](SHA256.hex(of: Data(token.utf8)).utf8)
        lock.lock(); defer { lock.unlock() }
        var matched: Int?
        for (index, record) in stored.enumerated() where ConstantTime.equals(candidate, [UInt8](record.hash.utf8)) {
            matched = index
        }
        guard let hit = matched else { return nil }
        let time = now()
        stored[hit].lastUsedAt = time
        if time.timeIntervalSince(lastPersisted) >= APIKeyStore.persistInterval {
            if (try? persistLocked()) != nil { lastPersisted = time }
        }
        return stored[hit]
    }

    // MARK: private

    private func issueLocked(label: String) throws -> IssuedKey {
        let secret = random.bytes(count: 32)
        let token = APIKeyStore.tokenPrefix + APIKeyStore.base64URL(secret)
        let idBytes = random.bytes(count: 8)
        let record = APIKeyRecord(id: idBytes.map { String(format: "%02x", $0) }.joined(), label: label,
                                  hash: SHA256.hex(of: Data(token.utf8)), createdAt: now(), lastUsedAt: nil)
        stored.append(record)
        do { try persistLocked() } catch {
            stored.removeLast()
            throw APIKeyError.persistFailed
        }
        return IssuedKey(record: record, token: token)
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func load() {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            stored = try decoder.decode(FileFormat.self, from: Data(contentsOf: url)).keys
        } catch {
            // Fail closed: an unreadable key file means no key is valid. Keep a copy for inspection.
            lastLoadProblem = "Could not read the key file, so all keys are treated as invalid: \(error)"
            stored = []
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
        }
    }

    private func persistLocked() throws {
        guard let url = url else { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(FileFormat(version: 1, keys: stored))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
