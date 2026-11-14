import XCTest
@testable import NachoComboCore

final class CharAssetFakeHTTP: PetHTTPClient {
    var routes: [String: PetHTTPResponse] = [:]
    var failing: Set<String> = []
    private(set) var requests: [PetHTTPRequest] = []
    func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
        requests.append(request)
        let key = request.url.path
        if failing.contains(key) { completion(.failure(PetAPIError.network)); return }
        completion(.success(routes[key] ?? PetHTTPResponse(status: 404)))
    }
}

final class PetCharacterAssetsTests: XCTestCase {
    let endpoint = ServerEndpoint(base: URL(string: "https://nacho.example")!)
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("char-assets-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func png(_ n: UInt8) -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, n, n, n]) }

    func file(_ data: Data) -> CharacterAssetFile {
        let sha = SHA256.hex(of: data)
        return CharacterAssetFile(url: "/api/v1/character-assets/files/\(sha).png", sha256: sha, sizeBytes: data.count, contentType: "image/png")
    }

    func catalogJSON(version: String, flavor: String = "original", states: [String: CharacterAssetFile]) -> Data {
        let s = states.map { k, f in
            "\"\(k)\":{\"url\":\"\(f.url)\",\"sha256\":\"\(f.sha256)\",\"size_bytes\":\(f.sizeBytes),\"content_type\":\"\(f.contentType)\"}"
        }.joined(separator: ",")
        return Data("{\"catalog_version\":\"\(version)\",\"flavors\":[{\"key\":\"\(flavor)\",\"display_name\":\"x\",\"version\":1,\"states\":{\(s)}}]}".utf8)
    }

    func sync(_ http: CharAssetFakeHTTP) -> PetCharacterAssetSync {
        PetCharacterAssetSync(http: http, cache: PetCharacterAssetCache(directory: dir), endpoint: { self.endpoint })
    }

    func refresh(_ s: PetCharacterAssetSync) -> Bool {
        var out = false
        s.refresh { out = $0 }  // the fake answers synchronously
        return out
    }

    // MARK: resolver order

    func testResolverOrder() {
        let f = file(png(1))
        let cat = CharacterAssetCatalog.decode(catalogJSON(version: "v1", states: ["idle": f]))
        let bundled: Set<String> = ["original"]
        // server picture, once cached
        XCTAssertEqual(PetArtResolver.resolve(flavor: "original", state: "idle", catalog: cat, isCached: { _ in true }, bundledFlavors: bundled), .server(f))
        // not cached yet → bundle of the flavor
        XCTAssertEqual(PetArtResolver.resolve(flavor: "original", state: "idle", catalog: cat, isCached: { _ in false }, bundledFlavors: bundled), .bundle(flavor: "original"))
        // state missing from the catalog → bundle
        XCTAssertEqual(PetArtResolver.resolve(flavor: "original", state: "happy", catalog: cat, isCached: { _ in true }, bundledFlavors: bundled), .bundle(flavor: "original"))
        // no catalog at all (server down on first run) → bundle
        XCTAssertEqual(PetArtResolver.resolve(flavor: "original", state: "idle", catalog: nil, isCached: { _ in true }, bundledFlavors: bundled), .bundle(flavor: "original"))
    }

    func testNewFlavorFallsBackToOriginal() {
        let bundled: Set<String> = ["original"]
        XCTAssertEqual(PetArtResolver.resolve(flavor: "cheese", state: "idle", catalog: nil, isCached: { _ in false }, bundledFlavors: bundled), .bundle(flavor: "original"))
        XCTAssertEqual(PetArtResolver.resolve(flavor: "cheese", state: "idle", catalog: nil, isCached: { _ in false }, bundledFlavors: ["original", "cheese"]), .bundle(flavor: "cheese"))
    }

    // MARK: requests

    func testRequests() {
        let f = file(png(2))
        XCTAssertNil(PetCharacterAssetsAPI.listRequest(endpoint, etagVersion: nil).headers["If-None-Match"])
        let r = PetCharacterAssetsAPI.listRequest(endpoint, etagVersion: "abc")
        XCTAssertEqual(r.headers["If-None-Match"], "\"abc\"")
        XCTAssertNil(r.headers["Authorization"])
        XCTAssertEqual(r.url.absoluteString, "https://nacho.example/api/v1/character-assets")
        XCTAssertEqual(PetCharacterAssetsAPI.fileRequest(endpoint, file: f)?.url.path, f.url)
        var bad = f
        bad.url = "/api/v1/admin/secrets"
        XCTAssertNil(PetCharacterAssetsAPI.fileRequest(endpoint, file: bad))
    }

    // MARK: sync

    func testRefreshDownloadsAndCaches() {
        let data = png(3), f = file(data)
        let http = CharAssetFakeHTTP()
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 200, body: catalogJSON(version: "v1", states: ["idle": f]))
        http.routes[f.url] = PetHTTPResponse(status: 200, body: data)
        let s = sync(http)
        XCTAssertTrue(refresh(s))
        XCTAssertEqual(s.cache.read(f), data)
        XCTAssertEqual(s.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .server(f))
        // second start: catalog comes from disk, 304 keeps it, no second download
        let http2 = CharAssetFakeHTTP()
        http2.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 304)
        let s2 = sync(http2)
        XCTAssertFalse(refresh(s2))
        XCTAssertEqual(http2.requests.first?.headers["If-None-Match"], "\"v1\"")
        XCTAssertEqual(http2.requests.count, 1)
        XCTAssertEqual(s2.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .server(f))
    }

    func testServerErrorKeepsPreviousAndBundle() {
        let data = png(4), f = file(data)
        let http = CharAssetFakeHTTP()
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 200, body: catalogJSON(version: "v1", states: ["idle": f]))
        http.routes[f.url] = PetHTTPResponse(status: 200, body: data)
        let s = sync(http)
        _ = refresh(s)
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 500)
        XCTAssertFalse(refresh(s))
        XCTAssertEqual(s.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .server(f))
        // network down on a fresh device: bundle
        let down = CharAssetFakeHTTP()
        down.failing = ["/api/v1/character-assets"]
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("char-assets-\(UUID().uuidString)")
        let s3 = sync(down)
        XCTAssertFalse(refresh(s3))
        XCTAssertEqual(s3.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .bundle(flavor: "original"))
    }

    func testHashMismatchIsNotCached() {
        let good = png(5), f = file(good)
        let http = CharAssetFakeHTTP()
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 200, body: catalogJSON(version: "v1", states: ["idle": f]))
        http.routes[f.url] = PetHTTPResponse(status: 200, body: png(6))  // same size, other bytes
        let s = sync(http)
        _ = refresh(s)
        XCTAssertNil(s.cache.read(f))
        XCTAssertEqual(s.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .bundle(flavor: "original"))
    }

    func testTamperedCacheFileIsIgnored() {
        let data = png(7), f = file(data)
        let cache = PetCharacterAssetCache(directory: dir)
        XCTAssertTrue(cache.store(data, for: f))
        try? png(8).write(to: dir.appendingPathComponent(f.sha256 + ".png"))
        XCTAssertNil(PetCharacterAssetCache(directory: dir).read(f))  // a new run re-verifies from disk
        XCTAssertFalse(cache.store(Data("not an image".utf8), for: f))
    }

    func testNewCatalogPrunesOldFiles() {
        let a = png(9), b = png(10), fa = file(a), fb = file(b)
        let http = CharAssetFakeHTTP()
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 200, body: catalogJSON(version: "v1", states: ["idle": fa]))
        http.routes[fa.url] = PetHTTPResponse(status: 200, body: a)
        http.routes[fb.url] = PetHTTPResponse(status: 200, body: b)
        let s = sync(http)
        _ = refresh(s)
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 200, body: catalogJSON(version: "v2", states: ["idle": fb]))
        XCTAssertTrue(refresh(s))
        XCTAssertNil(s.cache.read(fa))
        XCTAssertEqual(s.cache.read(fb), b)
    }

    func testRepeatedLookupDoesNotTouchTheDiskAgain() {
        let data = png(11), f = file(data)
        let http = CharAssetFakeHTTP()
        http.routes["/api/v1/character-assets"] = PetHTTPResponse(status: 200, body: catalogJSON(version: "v1", states: ["idle": f]))
        http.routes[f.url] = PetHTTPResponse(status: 200, body: data)
        let s = sync(http)
        _ = refresh(s)
        XCTAssertEqual(s.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .server(f))
        // Gone from disk: `has` still answers from memory (verified once), until the next refresh/prune.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f.sha256 + ".png"))
        for _ in 0..<5 { XCTAssertEqual(s.source(flavor: "original", state: "idle", bundledFlavors: ["original"]), .server(f)) }
        // A fresh cache object (new run) verifies from disk again and finds nothing.
        XCTAssertFalse(PetCharacterAssetCache(directory: dir).has(f))
    }
}
