import Foundation

// Character pictures from nacho-server (NACHO-158 contract v1, public, no token):
//   GET /api/v1/character-assets                      → {catalog_version, flavors[{key,display_name,version,states{state:{url,sha256,size_bytes,content_type}}}]}
//        ETag "<catalog_version>", If-None-Match → 304
//   GET /api/v1/character-assets/files/{sha256}.{png|webp} → the bytes (content addressed, immutable)
// Fallback v1 (per flavor+state): server picture (cached, sha256 checked) → that flavor's bundled picture → the bundled
// `original` picture of the same state. Network errors, bad files and unknown flavors fall through silently. The bundled
// pictures (Resources/Nacho) are never removed.

public struct CharacterAssetFile: Equatable, Decodable {
    public var url: String
    public var sha256: String
    public var sizeBytes: Int
    public var contentType: String

    public init(url: String, sha256: String, sizeBytes: Int, contentType: String) {
        self.url = url; self.sha256 = sha256; self.sizeBytes = sizeBytes; self.contentType = contentType
    }

    static let maxBytes = 1 << 20
    static let filesPrefix = "/api/v1/character-assets/files/"

    /// Only a well formed, content-addressed file of the contract is fetched (no other path, no traversal).
    var isWellFormed: Bool {
        guard sha256.count == 64, sha256.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
              contentType == "image/png" || contentType == "image/webp", sizeBytes > 0, sizeBytes <= CharacterAssetFile.maxBytes
        else { return false }
        return url == CharacterAssetFile.filesPrefix + sha256 + "." + fileExtension
    }

    var fileExtension: String { contentType == "image/webp" ? "webp" : "png" }
}

public struct CharacterAssetFlavor: Equatable, Decodable {
    public var key: String
    public var displayName: String
    public var version: Int
    public var states: [String: CharacterAssetFile]
}

public struct CharacterAssetCatalog: Equatable, Decodable {
    public var catalogVersion: String
    public var flavors: [CharacterAssetFlavor]

    public init(catalogVersion: String, flavors: [CharacterAssetFlavor]) {
        self.catalogVersion = catalogVersion; self.flavors = flavors
    }

    public static func decode(_ data: Data) -> CharacterAssetCatalog? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try? d.decode(CharacterAssetCatalog.self, from: data)
    }

    public func file(flavor: String, state: String) -> CharacterAssetFile? {
        guard let f = flavors.first(where: { $0.key == flavor }), let file = f.states[state], file.isWellFormed else { return nil }
        return file
    }
}

/// Where one (flavor, state) picture comes from.
public enum PetArtSource: Equatable {
    case server(CharacterAssetFile)
    case bundle(flavor: String)
}

public enum PetArtResolver {
    public static let originalFlavor = "original"

    /// - Parameters:
    ///   - isCached: true when the file with this sha256 is on the device and verified.
    ///   - bundledFlavors: flavors that ship a bundled picture for this state.
    public static func resolve(flavor: String, state: String, catalog: CharacterAssetCatalog?,
                               isCached: (String) -> Bool, bundledFlavors: Set<String>) -> PetArtSource {
        if let file = catalog?.file(flavor: flavor, state: state), isCached(file.sha256) { return .server(file) }
        if bundledFlavors.contains(flavor) { return .bundle(flavor: flavor) }
        return .bundle(flavor: originalFlavor)
    }
}

public enum PetCharacterAssetsAPI {
    public static func listRequest(_ e: ServerEndpoint, etagVersion: String?) -> PetHTTPRequest {
        var r = PetHTTPRequest.get(PetServerAPI.url(e, "/api/v1/character-assets"), bearer: nil)
        if let v = etagVersion, !v.isEmpty { r.headers["If-None-Match"] = "\"" + v + "\"" }
        return r
    }

    public static func fileRequest(_ e: ServerEndpoint, file: CharacterAssetFile) -> PetHTTPRequest? {
        guard file.isWellFormed else { return nil }
        var r = PetHTTPRequest.get(PetServerAPI.url(e, file.url), bearer: nil)
        r.headers["Accept"] = file.contentType
        return r
    }
}

/// Verified pictures on disk, named by sha256. A file that does not hash to its name is never kept or returned.
public final class PetCharacterAssetCache {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private func path(_ file: CharacterAssetFile) -> URL {
        directory.appendingPathComponent(file.sha256 + "." + file.fileExtension)
    }

    static func magicMatches(_ data: Data, contentType: String) -> Bool {
        let b = [UInt8](data.prefix(12))
        if contentType == "image/png" { return b.count >= 8 && Array(b[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] }
        return b.count >= 12 && Array(b[0..<4]) == Array("RIFF".utf8) && Array(b[8..<12]) == Array("WEBP".utf8)
    }

    /// The bytes if they are what the catalog promised (size, type bytes, sha256), else nil.
    static func valid(_ data: Data, for file: CharacterAssetFile) -> Bool {
        file.isWellFormed && data.count == file.sizeBytes && magicMatches(data, contentType: file.contentType)
            && SHA256.hex(of: data) == file.sha256
    }

    @discardableResult
    public func store(_ data: Data, for file: CharacterAssetFile) -> Bool {
        guard PetCharacterAssetCache.valid(data, for: file) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: path(file), options: .atomic)
            return true
        } catch { return false }
    }

    public func read(_ file: CharacterAssetFile) -> Data? {
        guard let data = try? Data(contentsOf: path(file)), PetCharacterAssetCache.valid(data, for: file) else { return nil }
        return data
    }

    public func has(_ file: CharacterAssetFile) -> Bool { read(file) != nil }

    var catalogURL: URL { directory.appendingPathComponent("catalog.json") }

    func saveCatalog(_ body: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? body.write(to: catalogURL, options: .atomic)
    }

    func loadCatalog() -> CharacterAssetCatalog? {
        guard let d = try? Data(contentsOf: catalogURL) else { return nil }
        return CharacterAssetCatalog.decode(d)
    }

    /// Removes pictures the catalog no longer lists (only inside this cache directory).
    func prune(keeping catalog: CharacterAssetCatalog) {
        let keep = Set(catalog.flavors.flatMap { $0.states.values }.filter { $0.isWellFormed }.map { $0.sha256 + "." + $0.fileExtension })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for n in names where n != "catalog.json" && !keep.contains(n) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(n))
        }
    }
}

/// Fetches the catalog (If-None-Match) and the pictures of the wanted flavors into the cache. Every failure is silent:
/// the previous catalog and cache stay, and the resolver falls back to the bundled pictures.
public final class PetCharacterAssetSync {
    private let http: PetHTTPClient
    public let cache: PetCharacterAssetCache
    private let endpoint: () -> ServerEndpoint?
    private let wantedFlavors: () -> [String]
    private let lock = NSLock()
    private var current: CharacterAssetCatalog?
    private var loaded = false
    private var running = false

    public init(http: PetHTTPClient, cache: PetCharacterAssetCache, endpoint: @escaping () -> ServerEndpoint?,
                wantedFlavors: @escaping () -> [String] = { [PetArtResolver.originalFlavor] }) {
        self.http = http; self.cache = cache; self.endpoint = endpoint; self.wantedFlavors = wantedFlavors
    }

    public var catalog: CharacterAssetCatalog? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { current = cache.loadCatalog(); loaded = true }
        return current
    }

    private func setCatalog(_ c: CharacterAssetCatalog) { lock.lock(); current = c; loaded = true; lock.unlock() }

    public func source(flavor: String, state: String, bundledFlavors: Set<String>) -> PetArtSource {
        PetArtResolver.resolve(flavor: flavor, state: state, catalog: catalog, isCached: { sha in
            guard let file = self.catalog?.flavors.flatMap({ $0.states.values }).first(where: { $0.sha256 == sha }) else { return false }
            return self.cache.has(file)
        }, bundledFlavors: bundledFlavors)
    }

    /// `completion(true)` when the cache gained a picture or the catalog changed.
    public func refresh(completion: @escaping (Bool) -> Void) {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        let finish: (Bool) -> Void = { [weak self] changed in
            self?.lock.lock(); self?.running = false; self?.lock.unlock()
            completion(changed)
        }
        guard let e = endpoint() else { finish(false); return }
        let known = catalog
        http.send(PetCharacterAssetsAPI.listRequest(e, etagVersion: known?.catalogVersion)) { [weak self] result in
            guard let self = self else { return }
            var changed = false
            if case let .success(resp) = result, resp.status == 200, let fresh = CharacterAssetCatalog.decode(resp.body) {
                self.cache.saveCatalog(resp.body)
                self.setCatalog(fresh)
                changed = fresh != known
            }
            // 304, errors and bad bodies keep the catalog we have; missing pictures are still tried.
            guard let cat = self.catalog else { finish(changed); return }
            let wanted = Set(self.wantedFlavors())
            var todo: [CharacterAssetFile] = []
            var seen = Set<String>()
            for f in cat.flavors where wanted.contains(f.key) {
                for file in f.states.values where file.isWellFormed && !seen.contains(file.sha256) && !self.cache.has(file) {
                    seen.insert(file.sha256); todo.append(file)
                }
            }
            self.download(todo, endpoint: e, gained: false) { gained in
                if changed { self.cache.prune(keeping: cat) }
                finish(changed || gained)
            }
        }
    }

    private func download(_ files: [CharacterAssetFile], endpoint e: ServerEndpoint, gained: Bool, done: @escaping (Bool) -> Void) {
        guard let file = files.first else { done(gained); return }
        let rest = Array(files.dropFirst())
        guard let req = PetCharacterAssetsAPI.fileRequest(e, file: file) else {
            download(rest, endpoint: e, gained: gained, done: done); return
        }
        http.send(req) { [weak self] result in
            guard let self = self else { return }
            var ok = false
            if case let .success(resp) = result, resp.status == 200 { ok = self.cache.store(resp.body, for: file) }
            self.download(rest, endpoint: e, gained: gained || ok, done: done)
        }
    }
}
