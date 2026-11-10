import XCTest
@testable import NachoComboCore

// LAN mode (same-network access): listen mode setting, address / Host policy, per-client limits.

private func lanSettings() -> ComputerUseSettings {
    var s = ComputerUseSettings()
    s.listenMode = .lan
    return s
}

// MARK: settings

final class ComputerUseListenModeTests: XCTestCase {
    private func decode(_ json: String) -> ComputerUseSettings? {
        try? JSONDecoder().decode(ComputerUseSettings.self, from: Data(json.utf8))
    }

    func testDefaultIsLocalOnlyAndNeedsNoTLS() {
        let s = ComputerUseSettings()
        XCTAssertEqual(s.listenMode, .localOnly)
        XCTAssertFalse(s.requiresTLS)
        XCTAssertEqual(s.effectiveBindAddress, "127.0.0.1")
        XCTAssertEqual(AppSettings.defaults.computerUse.listenMode, .localOnly)
    }

    func testLanModeRequiresTLSAndListensOnAllInterfaces() {
        let s = lanSettings()
        XCTAssertTrue(s.requiresTLS)
        XCTAssertEqual(s.effectiveBindAddress, ComputerUseSettings.lanBindAddress)
        XCTAssertEqual(s.bindAddress, "127.0.0.1", "the stored bindAddress itself stays loopback")
    }

    func testOldFileWithoutListenModeMigratesToLocalOnly() {
        let s = decode(#"{"port":9000,"bindAddress":"127.0.0.1","enabledGroups":{"screen":true},"allowedHosts":["a.example.net"]}"#)
        XCTAssertEqual(s?.listenMode, .localOnly)
        XCTAssertEqual(s?.port, 9000)
        XCTAssertEqual(s?.allowedHosts, ["a.example.net"])
        XCTAssertEqual(s?.isEnabled(.screen), true)
    }

    func testInvalidListenModeValuesFallBackToLocalOnly() {
        for raw in [#""0.0.0.0""#, #""LAN""#, #""""#, "7", "null", "true", #"["lan"]"#, #"{"lan":true}"#] {
            let s = decode(#"{"listenMode":\#(raw)}"#)
            XCTAssertNotNil(s, "\(raw) must not break decoding")
            XCTAssertEqual(s?.listenMode, .localOnly, "\(raw)")
        }
    }

    func testLanModeSurvivesEncodeDecode() throws {
        let data = try JSONEncoder().encode(lanSettings())
        XCTAssertEqual(try JSONDecoder().decode(ComputerUseSettings.self, from: data).listenMode, .lan)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""listenMode":"lan""#))
    }

    func testBindAddressIsStillCoercedInLanMode() {
        let s = decode(#"{"listenMode":"lan","bindAddress":"0.0.0.0"}"#)
        XCTAssertEqual(s?.listenMode, .lan)
        XCTAssertEqual(s?.bindAddress, "127.0.0.1")
    }

    func testListenModePersistsThroughSettingsStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nacho-cu-lan-\(UUID().uuidString)").appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        var all = AppSettings.defaults
        all.computerUse.listenMode = .lan
        try store.save(all)
        XCTAssertEqual(store.load().computerUse.listenMode, .lan)
    }
}

// MARK: address and Host policy

final class ComputerUseNetworkPolicyTests: XCTestCase {
    func testPrivateAndLoopbackAddresses() {
        let yes = ["10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.168.255.254",
                   "169.254.1.1", "127.0.0.1", "127.5.5.5", "::1", "fc00::1", "fd12:3456:789a::1", "fdff::1",
                   "fe80::1", "fe80::1%en0", "febf::1", "::ffff:192.168.0.1", "::ffff:c0a8:1", "::FFFF:10.1.2.3",
                   "0:0:0:0:0:0:0:1", "[::1]", "FD00::ABCD"]
        for a in yes { XCTAssertTrue(ComputerUseNetworkPolicy.isPrivateAddress(a), a) }
    }

    func testPublicAndMalformedAddressesAreNotPrivate() {
        let no = ["172.15.255.255", "172.32.0.1", "8.8.8.8", "192.169.0.1", "192.167.255.255", "11.0.0.1", "9.255.255.255",
                  "100.64.0.1", "0.0.0.0", "169.253.0.1", "169.255.0.1", "255.255.255.255", "2001:db8::1", "2606:4700::1111",
                  "fe00::1", "fec0::1", "::", "::ffff:8.8.8.8", "::ffff:808:808", "fbff::1", "fe7f::1",
                  "", " ", "abc", "localhost", "1.2.3", "1.2.3.4.5", "256.1.1.1", "010.0.0.1", "10.0.0.01", "1.2.3.4 ", " 10.0.0.1",
                  "10.0.0.1/8", "10.0.0.1:80", "-1.0.0.1", "+10.0.0.1", "0x0a.0.0.1", "10.0.0", "::g", ":::1", "1::2::3",
                  "1:2:3:4:5:6:7:8:9", "fd00:::1", "fd00::1::", "[fd00::1", "fd00::1]", "192.168.0.1%en0", "10.0.0.1\n"]
        for a in no { XCTAssertFalse(ComputerUseNetworkPolicy.isPrivateAddress(a), a.debugDescription) }
    }

    func testLoopbackOnlyPredicate() {
        for a in ["127.0.0.1", "127.9.9.9", "::1", "[::1]", "::ffff:127.0.0.1"] {
            XCTAssertTrue(ComputerUseNetworkPolicy.isLoopbackAddress(a), a)
        }
        for a in ["192.168.0.1", "10.0.0.1", "fe80::1", "8.8.8.8", "", "localhost", "unknown"] {
            XCTAssertFalse(ComputerUseNetworkPolicy.isLoopbackAddress(a), a)
        }
    }

    func testRemoteAddressRulesFollowTheListenMode() {
        let local = ComputerUseSettings(), lan = lanSettings()
        XCTAssertTrue(ComputerUseNetworkPolicy.isRemoteAddressAllowed("127.0.0.1", local))
        XCTAssertTrue(ComputerUseNetworkPolicy.isRemoteAddressAllowed("::1", local))
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("192.168.0.10", local), "local-only never serves the LAN")
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("10.0.0.2", local))
        XCTAssertTrue(ComputerUseNetworkPolicy.isRemoteAddressAllowed("192.168.0.10", lan))
        XCTAssertTrue(ComputerUseNetworkPolicy.isRemoteAddressAllowed("fe80::2%en0", lan))
        XCTAssertTrue(ComputerUseNetworkPolicy.isRemoteAddressAllowed("127.0.0.1", lan))
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("8.8.8.8", lan), "public peers are refused even in LAN mode")
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("2001:db8::1", lan))
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("unknown", lan), "unparsable peer fails closed")
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("", lan))
        XCTAssertFalse(ComputerUseNetworkPolicy.isRemoteAddressAllowed("unknown", local))
    }

    func testLocalOnlyHostRulesAreUnchanged() {
        var s = ComputerUseSettings()
        for h in ["localhost", "localhost:47653", "127.0.0.1", "127.0.0.1:1", "[::1]:47653", "LOCALHOST", "[0:0:0:0:0:0:0:1]"] {
            XCTAssertTrue(ComputerUseNetworkPolicy.isHostAllowed(h, s), h)
        }
        for h in ["192.168.0.5", "192.168.0.5:47653", "mac.local", "10.0.0.1", "evil.example.com", "8.8.8.8", "", "[fd00::1]:1", "::1", "[::ffff:127.0.0.1]", "127.0.0.2"] {
            XCTAssertFalse(ComputerUseNetworkPolicy.isHostAllowed(h, s), h)
        }
        s.allowedHosts = ["Mac.Example.Net"]
        XCTAssertTrue(ComputerUseNetworkPolicy.isHostAllowed("mac.example.net:443", s))
    }

    func testLanHostAcceptsPrivateLiteralsLocalNamesAndAllowedHosts() {
        var s = lanSettings()
        for h in ["192.168.0.5", "192.168.0.5:47653", "10.1.2.3:47653", "172.20.0.9", "169.254.9.9", "[fd00::1]:47653", "[fe80::1]:47653",
                  "[::1]:47653", "127.0.0.1", "localhost:47653", "mac.local", "My-Mac.local:47653", "mac.local.", "a.b.local",
                  "MAC.LOCAL", "[::ffff:192.168.0.5]:47653"] {
            XCTAssertTrue(ComputerUseNetworkPolicy.isHostAllowed(h, s), h)
        }
        XCTAssertFalse(ComputerUseNetworkPolicy.isHostAllowed("tunnel.example.net", s))
        s.allowedHosts = ["tunnel.example.net"]
        XCTAssertTrue(ComputerUseNetworkPolicy.isHostAllowed("tunnel.example.net:443", s))
    }

    func testLanHostRejectsPublicAddressesAndRebindingNames() {
        let s = lanSettings()
        let bad = ["8.8.8.8", "8.8.8.8:47653", "172.32.0.1", "100.64.0.1", "0.0.0.0", "[2001:db8::1]:47653", "[2606:4700::1111]",
                   "evil.example.com", "evil.com:47653", "192.168.0.5.evil.com", "10.0.0.1.nip.io", "mac.local.evil.com",
                   "evil.local.evil.com", "local", ".local", "a..local", "-a.local", "a-.local", "mac_book.local.example", "ma c.local",
                   "mac.local/x", "192.168.0.5@evil.com", "evil.com:80@192.168.0.5", "user@mac.local", "192.168.0.5:abc", "192.168.0.5:",
                   "", " ", "[", "[]", "[192.168.0.5]", "[mac.local]", "mac.local:", "mac.local:80:80", "localhost.evil.com",
                   "0x7f.0.0.1", "2130706433", "010.0.0.1", "192.168.0.5\t", "mac\u{0}.local"]
        for h in bad { XCTAssertFalse(ComputerUseNetworkPolicy.isHostAllowed(h, s), h.debugDescription) }
    }

    func testClientIDNormalisation() {
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID("192.168.0.9"), "192.168.0.9")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID("::ffff:192.168.0.9"), "192.168.0.9")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID("::FFFF:C0A8:9"), "192.168.0.9")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID("FE80::A%en0"), "fe80::a")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID("[FD00::1]"), "fd00::1")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID(" 10.0.0.1 "), "10.0.0.1")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID("unknown"), "unknown")
        XCTAssertEqual(ComputerUseNetworkPolicy.normalizeClientID(String(repeating: "x", count: 500)).count, 64)
    }
}

// MARK: service in LAN mode, per-client limits

final class ComputerUseLANServiceTests: XCTestCase {
    private var clock = TestClock()
    private var backend = FakeBackend()
    private var settings = ComputerUseSettings()
    private var keys: APIKeyStore!
    private var token = ""

    override func setUpWithError() throws {
        clock = TestClock(); backend = FakeBackend(); settings = ComputerUseSettings()
        keys = APIKeyStore(url: nil, random: CountingRandom(), now: { [clock] in clock.now })
        token = try keys.create(label: "LAN key").token
    }

    private func makeService(requests: RequestRateLimiter? = nil, clientRequests: RequestRateLimiter? = nil) -> ComputerUseService {
        ComputerUseService(settings: { [unowned self] in self.settings }, keys: keys, backend: backend,
                           requests: requests, clientRequests: clientRequests, now: { [clock] in clock.now })
    }

    private func ping(_ service: ComputerUseService, client: String, host: String = "192.168.0.5:47653", origin: String? = nil,
                      auth: String? = nil) -> HTTPResponse {
        var headers = ["host": host, "content-type": "application/json", "authorization": auth ?? "Bearer \(token)"]
        if let origin = origin { headers["origin"] = origin }
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        return service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body), clientID: client)
    }

    func testLocalOnlyRefusesEveryNonLoopbackPeerBeforeLookingAtTheKey() {
        let service = makeService()
        XCTAssertEqual(ping(service, client: "127.0.0.1", host: "127.0.0.1:47653").status, 200)
        XCTAssertEqual(ping(service, client: "::1", host: "[::1]:47653").status, 200)
        XCTAssertEqual(ping(service, client: "192.168.0.10", host: "127.0.0.1:47653").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", host: "192.168.0.5:47653").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", auth: "Bearer wrong").status, 403, "no 401 oracle for outsiders")
        XCTAssertEqual(ping(service, client: "unknown", host: "127.0.0.1:47653").status, 403)
    }

    func testLanModeServesPrivatePeersWithAPrivateHost() {
        settings.listenMode = .lan
        let service = makeService()
        XCTAssertEqual(ping(service, client: "192.168.0.10").status, 200)
        XCTAssertEqual(ping(service, client: "10.0.0.7", host: "mac.local:47653").status, 200)
        XCTAssertEqual(ping(service, client: "fe80::2%en0", host: "[fe80::1]:47653").status, 200)
        XCTAssertEqual(ping(service, client: "127.0.0.1", host: "localhost:47653").status, 200)
    }

    func testLanModeRefusesPublicPeersAndPublicOrRebindingHosts() {
        settings.listenMode = .lan
        let service = makeService()
        XCTAssertEqual(ping(service, client: "8.8.8.8").status, 403)
        XCTAssertEqual(ping(service, client: "2001:db8::5").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", host: "evil.example.com").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", host: "8.8.8.8:47653").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", host: "192.168.0.5.evil.com").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", host: "10.0.0.1.nip.io").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", origin: "https://evil.example.com").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", origin: "null").status, 403)
        XCTAssertEqual(ping(service, client: "192.168.0.10", origin: "http://192.168.0.7:3000").status, 200)
    }

    func testSwitchingBackToLocalOnlyTakesEffectOnTheNextRequest() {
        settings.listenMode = .lan
        let service = makeService()
        XCTAssertEqual(ping(service, client: "192.168.0.10").status, 200)
        settings.listenMode = .localOnly
        XCTAssertEqual(ping(service, client: "192.168.0.10").status, 403)
    }

    func testFailureLockoutIsPerClient() {
        settings.listenMode = .lan
        let service = makeService()
        for _ in 0..<5 { XCTAssertEqual(ping(service, client: "192.168.0.66", auth: "Bearer bad").status, 401) }
        let locked = ping(service, client: "192.168.0.66")
        XCTAssertEqual(locked.status, 429, "the attacking client is locked even with the right key")
        XCTAssertNotNil(locked.header("Retry-After"))
        XCTAssertEqual(ping(service, client: "192.168.0.10").status, 200, "another computer on the LAN is not affected")
        clock.advance(61)
        XCTAssertEqual(ping(service, client: "192.168.0.66").status, 200)
    }

    func testEquivalentSpellingsOfOneAddressShareOneLockout() {
        settings.listenMode = .lan
        let service = makeService()
        let spellings = ["192.168.0.66", "::ffff:192.168.0.66", "::FFFF:C0A8:42", "192.168.0.66", "::ffff:192.168.0.66"]
        for c in spellings { XCTAssertEqual(ping(service, client: c, auth: "Bearer bad").status, 401) }
        XCTAssertEqual(ping(service, client: "192.168.0.66").status, 429)
    }

    func testRequestRateLimitIsPerClientAndPerKey() {
        settings.listenMode = .lan
        let service = makeService(requests: RequestRateLimiter(limit: 1_000, window: 60, now: { [clock] in clock.now }),
                                  clientRequests: RequestRateLimiter(limit: 3, window: 60, now: { [clock] in clock.now }))
        for _ in 0..<3 { XCTAssertEqual(ping(service, client: "192.168.0.10").status, 200) }
        let limited = ping(service, client: "192.168.0.10")
        XCTAssertEqual(limited.status, 429)
        XCTAssertNotNil(limited.header("Retry-After"))
        XCTAssertEqual(ping(service, client: "192.168.0.11").status, 200, "a second computer has its own budget")
        clock.advance(61)
        XCTAssertEqual(ping(service, client: "192.168.0.10").status, 200)
    }

    func testKeyRateLimitStillAppliesAcrossClients() {
        settings.listenMode = .lan
        let service = makeService(requests: RequestRateLimiter(limit: 2, window: 60, now: { [clock] in clock.now }),
                                  clientRequests: RequestRateLimiter(limit: 1_000, window: 60, now: { [clock] in clock.now }))
        XCTAssertEqual(ping(service, client: "192.168.0.10").status, 200)
        XCTAssertEqual(ping(service, client: "192.168.0.11").status, 200)
        XCTAssertEqual(ping(service, client: "192.168.0.12").status, 429, "the per-key limit is shared by all clients")
    }

    func testOldPeerLabelStillCompilesAndMeansTheSameAsClientID() {
        let service = makeService()
        let headers = ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"]
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        XCTAssertEqual(service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body), peer: "127.0.0.1").status, 200)
        XCTAssertEqual(service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body), peer: "192.168.0.9").status, 403)
    }

    func testLimiterTablesStayBounded() {
        let clock = TestClock()
        let limiter = RequestRateLimiter(limit: 5, window: 60, now: { clock.now })
        for i in 0..<5_000 { _ = limiter.allow(key: "client-\(i)") }
        XCTAssertLessThanOrEqual(limiter.trackedKeyCount, 1_024 + 1)
        clock.advance(61)
        _ = limiter.allow(key: "fresh")
        XCTAssertEqual(limiter.trackedKeyCount, 1, "expired entries are dropped")
    }
}
