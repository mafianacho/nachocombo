import XCTest
@testable import NachoComboCore

// NACHO-156: a Keychain prompt per item and per launch, and a refused or canceled prompt that looked like "signed
// out". These pin: one Keychain read serves every pet secret, a refused read never deletes or overwrites the stored
// login, and an expired access token is refreshed silently across a restart (only a rejected refresh asks to sign in).

/// Stand-in for the login Keychain. Reading an item that exists can show the macOS "allow access" prompt (an
/// ad-hoc signed build is a new partition every build); reading a missing item never does. `prompts` counts those.
final class PetScriptedKeychain: PetSecretStore {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// Every read is refused with this status (errSecUserCanceled = -128, errSecAuthFailed = -25293).
    var refuseAll: Int32?
    /// Only these items are refused.
    var refused: Set<String> = []
    var failWrites = false
    private(set) var prompts = 0
    private(set) var deleted: [String] = []

    subscript(key: String) -> Data? {
        get { lock.lock(); defer { lock.unlock() }; return items[key] }
        set { lock.lock(); items[key] = newValue; lock.unlock() }
    }

    var accounts: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(items.keys) }

    func lookup(_ key: String) -> PetSecretLookup {
        lock.lock(); defer { lock.unlock() }
        if let s = refuseAll { prompts += 1; return .unavailable(s) }
        if refused.contains(key) { prompts += 1; return .unavailable(-128) }
        guard let d = items[key] else { return .missing }
        prompts += 1
        return .found(d)
    }

    func write(_ key: String, _ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites || refuseAll != nil { throw PetSecretUnavailable(status: -25293) }
        items[key] = value
    }

    func delete(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        deleted.append(key)
        items[key] = nil
    }

    func resetPrompts() { lock.lock(); prompts = 0; lock.unlock() }
}

private let petTokensBlob = Data(#"{"accessToken":"at-old","refreshToken":"rt-old","expiresAt":0,"refreshExpiresAt":null}"#.utf8)

final class PetSecretBundleTests: XCTestCase {
    func testOneKeychainReadServesEveryPetSecretOfALaunch() throws {
        let kc = PetScriptedKeychain()
        let first = PetSecretBundle(backing: kc)
        try first.write("tokens|s", Data("t".utf8))
        try first.write("connector-agent|s", Data("a".utf8))
        try first.write("connector|s|a", Data("c".utf8))
        XCTAssertEqual(kc.accounts, [PetSecretBundle.account], "one Keychain item holds them all")

        kc.resetPrompts()
        let launch = PetSecretBundle(backing: kc)  // next launch
        XCTAssertEqual(launch.lookup("tokens|s"), .found(Data("t".utf8)))
        XCTAssertEqual(launch.lookup("connector-agent|s"), .found(Data("a".utf8)))
        XCTAssertEqual(launch.lookup("connector|s|a"), .found(Data("c".utf8)))
        XCTAssertEqual(launch.lookup("tokens|other"), .missing)
        XCTAssertEqual(kc.prompts, 1, "at most one Keychain prompt per launch")
    }

    func testItemsOfEarlierVersionsMoveIntoTheBundleWithoutLoss() {
        let kc = PetScriptedKeychain()
        kc["tokens|s"] = petTokensBlob
        kc["connector-agent|s"] = Data("a".utf8)
        kc["connector|s|a"] = Data("c".utf8)
        let first = PetSecretBundle(backing: kc)
        XCTAssertEqual(first.lookup("tokens|s"), .found(petTokensBlob))
        XCTAssertEqual(first.lookup("connector-agent|s"), .found(Data("a".utf8)))
        XCTAssertEqual(first.lookup("connector|s|a"), .found(Data("c".utf8)))
        XCTAssertNotNil(kc[PetSecretBundle.account], "moved into the bundle")
        XCTAssertEqual(kc["tokens|s"], petTokensBlob, "the old item is kept (deleting it could prompt again)")
        XCTAssertTrue(kc.deleted.isEmpty)

        kc.resetPrompts()
        let launch = PetSecretBundle(backing: kc)
        XCTAssertEqual(launch.lookup("tokens|s"), .found(petTokensBlob))
        XCTAssertEqual(launch.lookup("connector|s|a"), .found(Data("c".utf8)))
        XCTAssertEqual(kc.prompts, 1, "the old items are not read again")
    }

    func testARefusedReadNeverOverwritesTheBundleAndIsAskedAgain() throws {
        let kc = PetScriptedKeychain()
        try PetSecretBundle(backing: kc).write("tokens|s", Data("t".utf8))
        let stored = kc[PetSecretBundle.account]
        kc.refuseAll = -128
        let launch = PetSecretBundle(backing: kc)
        XCTAssertEqual(launch.lookup("tokens|s"), .unavailable(-128))
        XCTAssertThrowsError(try launch.write("tokens|s", Data("new".utf8)))
        XCTAssertEqual(kc[PetSecretBundle.account], stored, "not overwritten with a bundle that lost the rest")
        XCTAssertTrue(kc.deleted.isEmpty)
        kc.refuseAll = nil
        XCTAssertEqual(launch.lookup("tokens|s"), .found(Data("t".utf8)), "the next access asks again")
    }

    func testAFailedWriteKeepsWhatWasStored() throws {
        let kc = PetScriptedKeychain()
        let b = PetSecretBundle(backing: kc)
        try b.write("tokens|s", Data("t".utf8))
        kc.failWrites = true
        XCTAssertThrowsError(try b.write("tokens|s", Data("new".utf8)))
        XCTAssertEqual(b.lookup("tokens|s"), .found(Data("t".utf8)))
        kc.failWrites = false
        XCTAssertEqual(PetSecretBundle(backing: kc).lookup("tokens|s"), .found(Data("t".utf8)))
    }

    func testDeleteRemovesTheValueAndTheOldItem() throws {
        let kc = PetScriptedKeychain()
        kc["tokens|s"] = petTokensBlob
        let b = PetSecretBundle(backing: kc)
        try b.write("connector|s|a", Data("c".utf8))
        b.delete("tokens|s")
        XCTAssertEqual(b.lookup("tokens|s"), .missing)
        XCTAssertNil(kc["tokens|s"], "an old item would bring a signed-out login back")
        XCTAssertEqual(PetSecretBundle(backing: kc).lookup("tokens|s"), .missing)
        XCTAssertEqual(PetSecretBundle(backing: kc).lookup("connector|s|a"), .found(Data("c".utf8)), "the rest stays")
    }
}

final class PetKeychainRefusalTests: XCTestCase {
    let config = OIDCConfig(issuer: URL(string: "https://auth.nachotown.com/realms/nachotown")!)
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    let tokenPath = "/realms/nachotown/protocol/openid-connect/token"
    var http: PetStubHTTP!
    var kc: PetScriptedKeychain!
    var browser: PetFakeBrowser!
    var factory: PetTransportFactory!
    var executor: PetRecordingExecutor!  // the session keeps it weakly
    var now = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        http = PetStubHTTP()
        kc = PetScriptedKeychain()
        browser = PetFakeBrowser()
        factory = PetTransportFactory()
        executor = PetRecordingExecutor()
        now = Date(timeIntervalSince1970: 1_000)
        http.on("POST", tokenPath, 200, petTokenJSON)
        http.on("POST", "/api/v1/agents/\(agent)/connector-binding", 200, #"{"token":"nct_feed","endpoint":"/ws/connector"}"#)
    }

    private func session(_ secrets: PetSecretStore? = nil) -> PetSession {
        var s = PetSettings()
        s.serverMode = .mock
        return PetSession(settings: s, http: http, secrets: secrets ?? kc, browser: browser, makeTransport: factory.make,
                          executor: executor, random: PetFixedRandom(), now: { [unowned self] in self.now })
    }

    private func settle(_ s: PetSession) { for _ in 0..<6 { s.flush(); Thread.sleep(forTimeInterval: 0.01) } }

    private var ready: String {
        #"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"r"}"#
    }

    private func signedInLaunch(_ secrets: PetSecretStore? = nil) -> PetSession {
        let s = session(secrets)
        s.signIn(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        factory.with(path: "/ws/chat").last!.deliver(ready); settle(s)
        s.shutdown()
        return s
    }

    private func token(_ auth: PetAuth) -> Result<String, AuthProblem> {
        let ex = expectation(description: "token")
        var out: Result<String, AuthProblem>!
        auth.validAccessToken { out = $0; ex.fulfill() }
        wait(for: [ex], timeout: 5)
        return out
    }

    // MARK: refused Keychain ≠ signed out

    func testPetAuthTellsARefusedKeychainFromNoLogin() {
        kc["tokens|s"] = petTokensBlob
        kc.refuseAll = -128
        let auth = PetAuth(config: config, scope: "s", http: http, secrets: kc, now: { [unowned self] in self.now })
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertTrue(auth.secretsUnavailable)
        XCTAssertEqual(token(auth), .failure(.secretsUnavailable))
        XCTAssertTrue(http.requests.isEmpty, "no refresh, no login")
        XCTAssertEqual(kc["tokens|s"], petTokensBlob)
        XCTAssertTrue(kc.deleted.isEmpty)
        XCTAssertFalse(auth.retryStoredTokens(), "still refused")
        kc.refuseAll = nil
        XCTAssertTrue(auth.retryStoredTokens())
        XCTAssertFalse(auth.secretsUnavailable)
        XCTAssertEqual(auth.currentAccessToken, "at-old")
        XCTAssertFalse(PetAuth(config: config, scope: "none", http: http, secrets: kc).secretsUnavailable, "missing is not refused")
    }

    func testRefusedKeychainAtLaunchKeepsTheLoginAndRestoresItOnTheNextAccess() {
        _ = signedInLaunch()
        let browserOpens = browser.opened.count
        kc.refuseAll = -128  // next launch: 거부 on the Keychain prompt
        let s = session()
        settle(s)
        XCTAssertEqual(s.snapshot.auth, .failed(AuthProblem.secretsUnavailable.koreanMessage), "not signed out")
        XCTAssertEqual(s.snapshot.notice, AuthProblem.secretsUnavailable.koreanMessage)
        s.open(); settle(s)
        XCTAssertNotEqual(s.snapshot.auth, .signedOut)
        XCTAssertTrue(kc.deleted.isEmpty, "nothing deleted")
        XCTAssertFalse(kc.accounts.isEmpty, "nothing deleted")
        XCTAssertEqual(browser.opened.count, browserOpens, "no login page")

        kc.refuseAll = nil  // allowed this time
        s.open(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        XCTAssertNil(s.snapshot.notice)
        XCTAssertEqual(factory.with(path: "/ws/chat").last?.bearer, "at-1", "the stored login, restored")
        XCTAssertEqual(browser.opened.count, browserOpens)
    }

    func testSignInWhileRefusedFirstTriesTheStoredLogin() {
        _ = signedInLaunch()
        let browserOpens = browser.opened.count
        kc.refuseAll = -128
        let s = session()
        settle(s)
        kc.refuseAll = nil
        s.signIn(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        XCTAssertEqual(browser.opened.count, browserOpens, "restored from the Keychain, no login page")
    }

    func testARefusedConnectorSecretIsNotReissuedOverTheStoredOne() {
        _ = signedInLaunch()
        let key = ConnectorBinding.secretKey(scope: session().settings.accountScope, agentID: agent)
        let stored = kc[key]
        XCTAssertNotNil(stored)
        let posts = http.sent("POST", "/api/v1/agents/\(agent)/connector-binding").count
        kc.refused = [key]
        let s = session()
        s.open(); settle(s)
        factory.with(path: "/ws/chat").last!.deliver(ready); settle(s)
        XCTAssertEqual(http.sent("POST", "/api/v1/agents/\(agent)/connector-binding").count, posts, "no new binding")
        XCTAssertEqual(kc[key], stored)
        if case .failed = s.snapshot.connector {} else { XCTFail("connector: \(s.snapshot.connector)") }
    }

    func testTheAppStoreAsksTheKeychainOncePerLaunch() {
        _ = signedInLaunch(PetSecretBundle(backing: kc))
        kc.resetPrompts()
        let s = session(PetSecretBundle(backing: kc))  // restart
        s.open(); settle(s)
        factory.with(path: "/ws/chat").last!.deliver(ready); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        XCTAssertEqual(factory.with(path: "/ws/connector").count, 2, "connector binding reused")
        XCTAssertEqual(kc.prompts, 1, "tokens + connector binding: one Keychain read")
    }

    // MARK: restart and refresh (current behaviour, pinned)

    func testRestartWithAnExpiredAccessTokenRefreshesSilently() {
        _ = signedInLaunch()
        let opens = browser.opened.count
        now = now.addingTimeInterval(600)  // access (300 s) expired, refresh (1800 s) alive
        http.on("POST", tokenPath, 200, #"{"access_token":"at-2","expires_in":300,"refresh_token":"rt-2","refresh_expires_in":1800}"#)
        let s = session()
        XCTAssertEqual(s.snapshot.auth, .signedIn, "restored at launch")
        s.open(); settle(s)
        XCTAssertEqual(PetStubHTTP.form(http.requests.last { $0.url.path == tokenPath }!)["grant_type"], "refresh_token")
        XCTAssertEqual(factory.with(path: "/ws/chat").last?.bearer, "at-2")
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        XCTAssertEqual(browser.opened.count, opens, "no login page")

        now = now.addingTimeInterval(600)  // and again on the launch after that, with the rotated refresh token
        http.on("POST", tokenPath, 200, #"{"access_token":"at-3","expires_in":300,"refresh_token":"rt-3","refresh_expires_in":1800}"#)
        s.shutdown()
        let again = session()
        again.open(); settle(again)
        XCTAssertEqual(PetStubHTTP.form(http.requests.last { $0.url.path == tokenPath }!)["refresh_token"], "rt-2")
        XCTAssertEqual(factory.with(path: "/ws/chat").last?.bearer, "at-3")
        XCTAssertEqual(browser.opened.count, opens)
    }

    func testRestartWhenTheRefreshIsRejectedAsksToSignIn() {
        _ = signedInLaunch()
        let opens = browser.opened.count
        now = now.addingTimeInterval(600)
        http.on("POST", tokenPath, 400, #"{"error":"invalid_grant","error_description":"Session not active"}"#)
        let s = session()
        s.open(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedOut)
        XCTAssertEqual(s.snapshot.notice, AuthProblem.rejected("").koreanMessage)
        XCTAssertNil(kc["tokens|\(s.settings.accountScope)"], "the dead login is forgotten")
        XCTAssertEqual(browser.opened.count, opens, "the login page waits for the user")
    }

    func testRestartAfterTheRefreshLifetimeAsksToSignInWithoutCallingTheServer() {
        _ = signedInLaunch()
        let before = http.sent("POST", tokenPath).count
        now = now.addingTimeInterval(1900)  // refresh_expires_in 1800 (Keycloak SSO idle) passed while the app was closed
        let s = session()
        s.open(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedOut)
        XCTAssertEqual(http.sent("POST", tokenPath).count, before)
    }

    func testRestartOfflineKeepsTheLogin() {
        _ = signedInLaunch()
        now = now.addingTimeInterval(600)
        http.failNetwork = true
        let s = session()
        s.open(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        XCTAssertEqual(s.snapshot.notice, AuthProblem.network.koreanMessage)
        XCTAssertNotNil(kc["tokens|\(s.settings.accountScope)"])
    }
}
