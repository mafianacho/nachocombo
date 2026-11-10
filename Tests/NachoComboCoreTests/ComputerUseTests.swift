import XCTest
@testable import NachoComboCore

// MARK: helpers

final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Deterministic "random" bytes for key tests; every call yields a different 32-byte value.
final class CountingRandom: RandomBytesSource {
    private var counter: UInt8 = 0
    func bytes(count: Int) -> [UInt8] {
        counter &+= 1
        return (0..<count).map { UInt8(truncatingIfNeeded: Int(counter) &* 7 &+ $0) }
    }
}

final class FakeBackend: ComputerUseBackend {
    private(set) var calls: [(tool: String, arguments: [String: JSONValue])] = []
    var result = ToolResult.text("done")
    func execute(tool: String, arguments: [String: JSONValue]) -> ToolResult {
        calls.append((tool, arguments))
        return result
    }
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("nacho-cu-test-\(UUID().uuidString)")
}

// MARK: crypto

final class ComputerUseCryptoTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(SHA256.hex(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // 56 bytes: the padding spills into a second block.
        XCTAssertEqual(SHA256.hex(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex(of: Data(repeating: 0x61, count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(ConstantTime.equals([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(ConstantTime.equals([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(ConstantTime.equals([1, 2, 3], [1, 2]))
        XCTAssertTrue(ConstantTime.equals([], []))
    }
}

// MARK: keys

final class APIKeyStoreTests: XCTestCase {
    private func makeStore(_ url: URL? = nil, clock: TestClock = TestClock()) -> APIKeyStore {
        APIKeyStore(url: url, random: CountingRandom(), now: { clock.now })
    }

    func testCreateReturnsTokenOnceAndStoresOnlyHash() throws {
        let url = tempDir().appendingPathComponent("keys.json")
        let store = makeStore(url)
        let issued = try store.create(label: "Laptop")
        XCTAssertTrue(issued.token.hasPrefix(APIKeyStore.tokenPrefix))
        // 32 random bytes as base64url without padding = 43 characters after the prefix.
        XCTAssertEqual(issued.token.count, APIKeyStore.tokenPrefix.count + 43)
        XCTAssertEqual(issued.record.label, "Laptop")
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains(issued.token), "the plaintext key must never be written")
        XCTAssertTrue(file.contains(issued.record.hash))
        XCTAssertEqual(issued.record.hash, SHA256.hex(of: Data(issued.token.utf8)))
        // The listing exposes records (hash, label, times) but never the token.
        XCTAssertEqual(store.records.map { $0.label }, ["Laptop"])
    }

    func testKeyFileIsPrivate() throws {
        let url = tempDir().appendingPathComponent("keys.json")
        _ = try makeStore(url).create(label: "a")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAuthenticateAcceptsRightKeyAndRejectsOthers() throws {
        let store = makeStore()
        let a = try store.create(label: "a")
        let b = try store.create(label: "b")
        XCTAssertEqual(store.authenticate(token: a.token)?.label, "a")
        XCTAssertEqual(store.authenticate(token: b.token)?.label, "b")
        XCTAssertNil(store.authenticate(token: a.token + "x"))
        XCTAssertNil(store.authenticate(token: ""))
        XCTAssertNil(store.authenticate(token: "nccu_" + String(repeating: "A", count: 43)))
    }

    func testRevokeInvalidatesImmediatelyAndPersists() throws {
        let url = tempDir().appendingPathComponent("keys.json")
        let store = makeStore(url)
        let a = try store.create(label: "a")
        XCTAssertNotNil(store.authenticate(token: a.token))
        XCTAssertTrue(store.revoke(id: a.record.id))
        XCTAssertNil(store.authenticate(token: a.token))
        XCTAssertFalse(store.revoke(id: a.record.id))
        XCTAssertTrue(APIKeyStore(url: url, random: CountingRandom()).records.isEmpty)
    }

    func testReissueReplacesKeyAndKeepsLabel() throws {
        let store = makeStore()
        let old = try store.create(label: "MacBook")
        let new = try store.reissue(id: old.record.id)
        XCTAssertNil(store.authenticate(token: old.token))
        XCTAssertEqual(store.authenticate(token: new.token)?.label, "MacBook")
        XCTAssertNotEqual(old.record.id, new.record.id)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertThrowsError(try store.reissue(id: "missing"))
    }

    func testLabelAndCountLimits() throws {
        let store = makeStore()
        XCTAssertThrowsError(try store.create(label: "   ")) { XCTAssertEqual($0 as? APIKeyError, .invalidLabel) }
        XCTAssertThrowsError(try store.create(label: String(repeating: "é", count: 41))) {
            XCTAssertEqual($0 as? APIKeyError, .invalidLabel)
        }
        for i in 0..<APIKeyStore.maxActiveKeys { _ = try store.create(label: "k\(i)") }
        XCTAssertThrowsError(try store.create(label: "extra")) { XCTAssertEqual($0 as? APIKeyError, .tooManyKeys) }
    }

    func testLastUsedIsRecordedAndSurvivesReload() throws {
        let clock = TestClock()
        let url = tempDir().appendingPathComponent("keys.json")
        let store = makeStore(url, clock: clock)
        let k = try store.create(label: "a")
        XCTAssertNil(store.records.first?.lastUsedAt)
        clock.advance(120)
        XCTAssertNotNil(store.authenticate(token: k.token))
        XCTAssertEqual(store.records.first?.lastUsedAt, clock.now)
        let reloaded = APIKeyStore(url: url, random: CountingRandom(), now: { clock.now })
        XCTAssertEqual(reloaded.records.first?.lastUsedAt, clock.now)
        XCTAssertNotNil(reloaded.authenticate(token: k.token))
    }

    func testCorruptKeyFileFailsClosed() throws {
        let url = tempDir().appendingPathComponent("keys.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        let store = APIKeyStore(url: url, random: CountingRandom())
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.lastLoadProblem)
    }
}

// MARK: rate limits

final class ComputerUseLimiterTests: XCTestCase {
    func testLocksAfterRepeatedFailuresAndExpires() {
        let clock = TestClock()
        let limiter = AuthFailureLimiter(maxFailures: 3, window: 60, lockout: 30, now: { clock.now })
        for _ in 0..<2 { limiter.recordFailure(client: "c"); XCTAssertNil(limiter.retryAfter(client: "c")) }
        limiter.recordFailure(client: "c")
        XCTAssertEqual(limiter.retryAfter(client: "c") ?? 0, 30, accuracy: 0.5)
        XCTAssertNil(limiter.retryAfter(client: "other"))
        clock.advance(31)
        XCTAssertNil(limiter.retryAfter(client: "c"))
    }

    func testSuccessResetsFailureCount() {
        let clock = TestClock()
        let limiter = AuthFailureLimiter(maxFailures: 3, window: 60, lockout: 30, now: { clock.now })
        limiter.recordFailure(client: "c"); limiter.recordFailure(client: "c")
        limiter.recordSuccess(client: "c")
        limiter.recordFailure(client: "c"); limiter.recordFailure(client: "c")
        XCTAssertNil(limiter.retryAfter(client: "c"))
    }

    func testOldFailuresFallOutOfTheWindow() {
        let clock = TestClock()
        let limiter = AuthFailureLimiter(maxFailures: 3, window: 60, lockout: 30, now: { clock.now })
        limiter.recordFailure(client: "c"); limiter.recordFailure(client: "c")
        clock.advance(61)
        limiter.recordFailure(client: "c")
        XCTAssertNil(limiter.retryAfter(client: "c"))
    }

    func testRequestRateLimitPerKey() {
        let clock = TestClock()
        let limiter = RequestRateLimiter(limit: 3, window: 10, now: { clock.now })
        XCTAssertTrue(limiter.allow(key: "k")); XCTAssertTrue(limiter.allow(key: "k")); XCTAssertTrue(limiter.allow(key: "k"))
        XCTAssertFalse(limiter.allow(key: "k"))
        XCTAssertTrue(limiter.allow(key: "other"))
        clock.advance(11)
        XCTAssertTrue(limiter.allow(key: "k"))
    }
}

// MARK: JSON-RPC

final class JSONRPCTests: XCTestCase {
    private func parse(_ text: String) -> JSONRPCParsed { JSONRPCCodec.parse(Data(text.utf8)) }

    func testParsesRequestAndNotification() {
        guard case .single(.request(let id, let method, let params)) =
            parse(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"a":1}}"#) else { return XCTFail() }
        XCTAssertEqual(id, .int(7)); XCTAssertEqual(method, "tools/list"); XCTAssertEqual(params, .object(["a": .int(1)]))
        guard case .single(.request(let sid, _, _)) = parse(#"{"jsonrpc":"2.0","id":"x","method":"ping"}"#) else { return XCTFail() }
        XCTAssertEqual(sid, .string("x"))
        guard case .single(.notification(let m, _)) =
            parse(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) else { return XCTFail() }
        XCTAssertEqual(m, "notifications/initialized")
    }

    func testInvalidJSONIsParseError() {
        guard case .invalid(let id, let err) = parse("{not json") else { return XCTFail() }
        XCTAssertNil(id); XCTAssertEqual(err.code, JSONRPCError.parseError)
    }

    func testStructuralErrorsAreInvalidRequest() {
        for body in [#"{"jsonrpc":"2.0","id":1}"#, #"{"jsonrpc":"1.0","id":1,"method":"x"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":5}"#, #"[]"#, #"42"#,
                     #"{"jsonrpc":"2.0","id":{"a":1},"method":"x"}"#] {
            guard case .invalid(_, let err) = parse(body) else { return XCTFail(body) }
            XCTAssertEqual(err.code, JSONRPCError.invalidRequest, body)
        }
    }

    func testBatch() {
        guard case .batch(let items) = parse(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"n"}]"#)
        else { return XCTFail() }
        XCTAssertEqual(items.count, 2)
    }

    func testJSONValueKeepsBoolIntAndDoubleApart() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"b":true,"i":1,"d":1.5,"s":"x","n":null,"a":[1,"y"]}"#.utf8))
        guard case .object(let o) = value else { return XCTFail() }
        XCTAssertEqual(o["b"], .bool(true)); XCTAssertEqual(o["i"], .int(1)); XCTAssertEqual(o["d"], .double(1.5))
        XCTAssertEqual(o["n"], .null); XCTAssertEqual(o["a"], .array([.int(1), .string("y")]))
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    func testEncodeResultAndError() throws {
        let ok = try JSONSerialization.jsonObject(with: JSONRPCCodec.encodeResult(id: .int(3), result: .object(["x": .int(1)]))) as? [String: Any]
        XCTAssertEqual(ok?["jsonrpc"] as? String, "2.0"); XCTAssertEqual(ok?["id"] as? Int, 3)
        let bad = try JSONSerialization.jsonObject(with: JSONRPCCodec.encodeError(id: nil, error: .methodNotFound("zz"))) as? [String: Any]
        XCTAssertTrue(bad?["id"] is NSNull)
        XCTAssertEqual((bad?["error"] as? [String: Any])?["code"] as? Int, JSONRPCError.methodNotFound)
    }
}

// MARK: settings

final class ComputerUseSettingsTests: XCTestCase {
    func testModuleExistsAndDefaultsOffWithEverythingDisabled() {
        XCTAssertTrue(ModuleID.allCases.contains(.computerUse))
        XCTAssertEqual(ModuleID.computerUse.displayName, "Computer Use")
        XCTAssertFalse(ModuleID.computerUse.createsStatusItem)
        let s = AppSettings.defaults
        XCTAssertFalse(s.isEnabled(.computerUse))
        for group in ToolGroup.allCases { XCTAssertFalse(s.computerUse.isEnabled(group)) }
        XCTAssertEqual(s.computerUse.bindAddress, "127.0.0.1")
        XCTAssertTrue(s.computerUse.requiredPermissions.isEmpty)
    }

    func testHighRiskGroupsAreExactlyTheFourDangerousOnes() {
        XCTAssertEqual(Set(ToolGroup.allCases.filter { $0.isHighRisk }), [.appleScript, .shell, .fileAccess, .processControl])
    }

    func testPermissionsAreOnlyRequiredForEnabledGroups() {
        var c = ComputerUseSettings()
        c.setEnabled(.clipboard, true)
        XCTAssertTrue(c.requiredPermissions.isEmpty)
        c.setEnabled(.screen, true)
        XCTAssertEqual(c.requiredPermissions, [.screenRecording])
        c.setEnabled(.input, true)
        XCTAssertEqual(c.requiredPermissions, [.screenRecording, .accessibility])
        c.setEnabled(.screen, false)
        XCTAssertEqual(c.requiredPermissions, [.accessibility])
    }

    func testBindAddressMustBeLoopback() {
        XCTAssertTrue(ComputerUseSettings.isLoopback("127.0.0.1"))
        XCTAssertTrue(ComputerUseSettings.isLoopback("::1"))
        XCTAssertFalse(ComputerUseSettings.isLoopback("0.0.0.0"))
        XCTAssertFalse(ComputerUseSettings.isLoopback("192.168.0.10"))
        XCTAssertFalse(ComputerUseSettings.isLoopback(""))
        let json = #"{"port":9000,"bindAddress":"0.0.0.0","enabledGroups":{"screen":true},"allowedHosts":[]}"#
        let loaded = try? JSONDecoder().decode(ComputerUseSettings.self, from: Data(json.utf8))
        XCTAssertEqual(loaded?.bindAddress, "127.0.0.1", "a non-loopback address in a settings file is coerced, never honoured")
        XCTAssertEqual(loaded?.port, 9000)
    }

    func testPortRange() {
        XCTAssertTrue(ComputerUseSettings.isValidPort(47653))
        XCTAssertFalse(ComputerUseSettings.isValidPort(80))
        XCTAssertFalse(ComputerUseSettings.isValidPort(70000))
        let loaded = try? JSONDecoder().decode(ComputerUseSettings.self, from: Data(#"{"port":22}"#.utf8))
        XCTAssertEqual(loaded?.port, ComputerUseSettings.defaultPort)
    }

    func testOldSettingsFileWithoutComputerUseStillLoadsAndKeepsSixModules() throws {
        let url = tempDir().appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"enabledModules":{"menuBar":true,"focusDim":true},"menuBarCollapsed":true}"#.utf8).write(to: url)
        let s = SettingsStore(url: url).load()
        XCTAssertTrue(s.isEnabled(.menuBar)); XCTAssertTrue(s.isEnabled(.focusDim)); XCTAssertTrue(s.menuBarCollapsed)
        XCTAssertFalse(s.isEnabled(.computerUse))
        XCTAssertEqual(s.computerUse, ComputerUseSettings())
    }

    func testGroupSwitchesPersistThroughManager() {
        let store = SettingsStore(url: tempDir().appendingPathComponent("settings.json"))
        let manager = ModuleManager(store: store, modules: [])
        manager.setComputerUse { $0.setEnabled(.shell, true); $0.port = 50000 }
        let reloaded = SettingsStore(url: store.url).load()
        XCTAssertTrue(reloaded.computerUse.isEnabled(.shell))
        XCTAssertEqual(reloaded.computerUse.port, 50000)
    }

    func testTurningModuleOffStopsItWithoutTouchingGroupChoices() {
        let store = SettingsStore(url: tempDir().appendingPathComponent("settings.json"))
        let module = FakeModule(.computerUse)
        let manager = ModuleManager(store: store, modules: [module])
        manager.setComputerUse { $0.setEnabled(.screen, true) }
        XCTAssertEqual(manager.setEnabled(.computerUse, true), .running)
        XCTAssertEqual(manager.setEnabled(.computerUse, false), .off)
        XCTAssertFalse(module.active)
        XCTAssertTrue(SettingsStore(url: store.url).load().computerUse.isEnabled(.screen))
        XCTAssertFalse(SettingsStore(url: store.url).load().isEnabled(.computerUse))
    }
}

// MARK: tool catalog and argument handling

final class ComputerUseCatalogTests: XCTestCase {
    func testEveryToolBelongsToAGroupAndHasUniqueNameAndObjectSchema() {
        let names = ToolCatalog.all.map { $0.name }
        XCTAssertEqual(names.count, Set(names).count)
        for tool in ToolCatalog.all {
            guard case .object(let schema) = tool.inputSchema else { XCTFail(tool.name); continue }
            XCTAssertEqual(schema["type"], .string("object"), tool.name)
            XCTAssertFalse(tool.description.isEmpty)
        }
        for group in ToolGroup.allCases { XCTAssertFalse(ToolCatalog.tools(in: group).isEmpty, "\(group)") }
    }

    func testDangerousToolsLiveInHighRiskGroups() {
        for name in ["applescript_run", "shell_run", "file_read", "file_write", "process_kill"] {
            XCTAssertTrue(ToolCatalog.definition(named: name)?.group.isHighRisk == true, name)
        }
        for name in ["screen_capture", "mouse_click", "type_text", "clipboard_read", "open_url"] {
            XCTAssertTrue(ToolCatalog.definition(named: name)?.group.isHighRisk == false, name)
        }
    }

    func testToolArguments() throws {
        let args = ToolArguments(["s": .string("x"), "i": .int(3), "d": .double(2.5), "b": .bool(true), "n": .int(2),
                                  "l": .array([.string("a"), .string("b")])])
        XCTAssertEqual(try args.string("s"), "x")
        XCTAssertEqual(try args.int("i"), 3)
        XCTAssertEqual(try args.double("d"), 2.5)
        XCTAssertEqual(try args.double("n"), 2)
        XCTAssertEqual(try args.bool("b"), true)
        XCTAssertEqual(try args.stringList("l"), ["a", "b"])
        XCTAssertNil(try args.optionalString("missing"))
        XCTAssertThrowsError(try args.string("missing"))
        XCTAssertThrowsError(try args.int("s"))
        XCTAssertThrowsError(try args.int("d"), "a fractional number is not an integer")
        XCTAssertThrowsError(try ToolArguments(["x": .double(.infinity)]).double("x"))
    }
}

// MARK: policies

final class ComputerUsePolicyTests: XCTestCase {
    func testKeyNamesAndModifiers() {
        XCTAssertEqual(KeyboardMap.keyCode(for: "a"), 0)
        XCTAssertEqual(KeyboardMap.keyCode(for: "A"), 0)
        XCTAssertEqual(KeyboardMap.keyCode(for: "return"), 36)
        XCTAssertEqual(KeyboardMap.keyCode(for: "Enter"), 36)
        XCTAssertEqual(KeyboardMap.keyCode(for: "esc"), 53)
        XCTAssertEqual(KeyboardMap.keyCode(for: "left"), 123)
        XCTAssertEqual(KeyboardMap.keyCode(for: "f5"), 96)
        XCTAssertEqual(KeyboardMap.keyCode(for: "space"), 49)
        XCTAssertNil(KeyboardMap.keyCode(for: "no-such-key"))
        XCTAssertEqual(try KeyboardMap.modifierFlags(["cmd", "shift"]), KeyboardMap.command | KeyboardMap.shift)
        XCTAssertEqual(try KeyboardMap.modifierFlags(["Control", "alt", "option"]), KeyboardMap.control | KeyboardMap.option)
        XCTAssertEqual(try KeyboardMap.modifierFlags([]), 0)
        XCTAssertThrowsError(try KeyboardMap.modifierFlags(["hyper"]))
    }

    func testOpenURLAllowsOnlyWebAndMail() throws {
        XCTAssertNoThrow(try OpenPolicy.validateURL("https://example.com/a?b=1"))
        XCTAssertNoThrow(try OpenPolicy.validateURL("http://localhost:8080"))
        XCTAssertNoThrow(try OpenPolicy.validateURL("mailto:a@b.com"))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "vnc://host", "x-apple.systempreferences:", "", "not a url", "tel:123"] {
            XCTAssertThrowsError(try OpenPolicy.validateURL(bad), bad)
        }
    }

    func testOpenFileBlocksExecutableKinds() {
        XCTAssertNoThrow(try OpenPolicy.validateFilePath("/Users/me/Documents/report.pdf"))
        for bad in ["relative/path.txt", "/Users/me/run.command", "/Users/me/x.SH", "/Applications/Foo.app", "/tmp/a.pkg",
                    "/tmp/a.dmg", "/tmp/a.scpt", "/tmp/a.workflow", "/Users/me/../../etc/x.command", ""] {
            XCTAssertThrowsError(try OpenPolicy.validateFilePath(bad), bad)
        }
    }

    func testFilePolicyProtectsSecretsAndOwnState() {
        let policy = FilePolicy(home: "/Users/me", protectedPaths: ["/Users/me/Library/Application Support/NachoCombo"])
        XCTAssertNoThrow(try policy.check(path: "/Users/me/notes.txt", write: true))
        XCTAssertNoThrow(try policy.check(path: "/Users/me/.zshrc", write: false))
        for bad in ["/Users/me/.ssh/id_rsa", "/Users/me/.ssh", "/Users/me/Library/Keychains/login.keychain-db",
                    "/Users/me/Library/Application Support/NachoCombo/computer-use-keys.json",
                    "/Users/me/Documents/../.ssh/id_rsa", "relative.txt", ""] {
            XCTAssertThrowsError(try policy.check(path: bad, write: false), bad)
        }
        XCTAssertThrowsError(try policy.check(path: "/Users/me/.zshrc", write: true), "shell init files are never writable")
        XCTAssertThrowsError(try policy.check(path: "/Users/me/Library/LaunchAgents/x.plist", write: true))
        XCTAssertThrowsError(try policy.check(path: "/etc/hosts", write: true))
        XCTAssertNoThrow(try policy.check(path: "/etc/hosts", write: false))
    }

    func testProcessKillRules() {
        XCTAssertNoThrow(try ProcessPolicy.validateKill(pid: 4242, signal: "TERM", ownPid: 100))
        XCTAssertNoThrow(try ProcessPolicy.validateKill(pid: 4242, signal: nil, ownPid: 100))
        XCTAssertEqual(try ProcessPolicy.validateKill(pid: 4242, signal: nil, ownPid: 100), 15)
        XCTAssertEqual(try ProcessPolicy.validateKill(pid: 4242, signal: "KILL", ownPid: 100), 9)
        for (pid, sig) in [(0, "TERM"), (1, "TERM"), (-1, "TERM"), (100, "TERM"), (4242, "STOP"), (4242, "99")] as [(Int, String)] {
            XCTAssertThrowsError(try ProcessPolicy.validateKill(pid: pid, signal: sig, ownPid: 100), "\(pid) \(sig)")
        }
    }

    func testInputBounds() {
        XCTAssertNoThrow(try InputPolicy.validatePoint(x: 10, y: -5))
        XCTAssertThrowsError(try InputPolicy.validatePoint(x: .nan, y: 0))
        XCTAssertThrowsError(try InputPolicy.validatePoint(x: 1e9, y: 0))
        XCTAssertNoThrow(try InputPolicy.validateText(String(repeating: "a", count: 4000)))
        XCTAssertThrowsError(try InputPolicy.validateText(String(repeating: "a", count: 4001)))
        XCTAssertThrowsError(try InputPolicy.validateText(""))
        XCTAssertEqual(try InputPolicy.validateClickCount(nil), 1)
        XCTAssertEqual(try InputPolicy.validateClickCount(3), 3)
        XCTAssertThrowsError(try InputPolicy.validateClickCount(4))
        XCTAssertEqual(ScreenshotPolicy.clampMaxWidth(nil), ScreenshotPolicy.defaultMaxWidth)
        XCTAssertEqual(ScreenshotPolicy.clampMaxWidth(10), ScreenshotPolicy.minWidth)
        XCTAssertEqual(ScreenshotPolicy.clampMaxWidth(100_000), ScreenshotPolicy.maxWidthLimit)
        XCTAssertEqual(ShellPolicy.clampTimeout(nil), ShellPolicy.defaultTimeout)
        XCTAssertEqual(ShellPolicy.clampTimeout(9999), ShellPolicy.maxTimeout)
        XCTAssertEqual(ShellPolicy.clampTimeout(0), 1)
    }
}

// MARK: HTTP parser

final class ComputerUseHTTPParserTests: XCTestCase {
    private func raw(_ s: String) -> Data { Data(s.utf8) }

    func testParsesRequestWithBody() {
        let text = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47653\r\nContent-Length: 5\r\nAuthorization: Bearer abc\r\n\r\nhello"
        guard case .request(let req, let consumed) = HTTPParser.parse(raw(text)) else { return XCTFail() }
        XCTAssertEqual(req.method, "POST"); XCTAssertEqual(req.path, "/mcp")
        XCTAssertEqual(req.header("authorization"), "Bearer abc")
        XCTAssertEqual(req.header("HOST"), "127.0.0.1:47653")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "hello")
        XCTAssertEqual(consumed, text.utf8.count)
    }

    func testNeedsMoreUntilBodyComplete() {
        XCTAssertEqual(HTTPParser.parse(raw("POST /mcp HTTP/1.1\r\nContent-Le")), .needMore)
        XCTAssertEqual(HTTPParser.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nhel")), .needMore)
    }

    func testRejectsOversizeAndMalformed() {
        let big = "POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"
        guard case .invalid(let r1) = HTTPParser.parse(raw(big)) else { return XCTFail() }
        XCTAssertEqual(r1.status, 413)
        let hugeHeader = "POST /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 20000)
        guard case .invalid(let r2) = HTTPParser.parse(raw(hugeHeader)) else { return XCTFail() }
        XCTAssertEqual(r2.status, 431)
        guard case .invalid(let r3) = HTTPParser.parse(raw("garbage\r\n\r\n")) else { return XCTFail() }
        XCTAssertEqual(r3.status, 400)
        guard case .invalid(let r4) = HTTPParser.parse(raw("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n")) else { return XCTFail() }
        XCTAssertEqual(r4.status, 400)
        guard case .invalid(let r5) = HTTPParser.parse(raw("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) else { return XCTFail() }
        XCTAssertEqual(r5.status, 411)
    }

    func testResponseSerialization() {
        let response = HTTPResponse(status: 401, headers: [("WWW-Authenticate", "Bearer")], body: Data("x".utf8))
        let text = String(data: response.serialized(), encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 1\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nx"))
    }
}

// MARK: service (auth, switches, logging)

final class ComputerUseServiceTests: XCTestCase {
    private var clock = TestClock()
    private var backend = FakeBackend()
    private var settings = ComputerUseSettings()
    private var keys: APIKeyStore!
    private var service: ComputerUseService!
    private var token = ""

    override func setUpWithError() throws {
        clock = TestClock(); backend = FakeBackend(); settings = ComputerUseSettings()
        keys = APIKeyStore(url: nil, random: CountingRandom(), now: { [clock] in clock.now })
        token = try keys.create(label: "Test Key").token
        service = ComputerUseService(settings: { [unowned self] in self.settings }, keys: keys, backend: backend,
                                     now: { [clock] in clock.now })
    }

    private func post(_ body: String, auth: String? = nil, host: String = "127.0.0.1:47653", origin: String? = nil,
                      method: String = "POST", path: String = "/mcp", useToken: Bool = true) -> HTTPResponse {
        var headers = ["host": host, "content-type": "application/json"]
        if let auth = auth { headers["authorization"] = auth } else if useToken { headers["authorization"] = "Bearer \(token)" }
        if let origin = origin { headers["origin"] = origin }
        return service.handle(HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8)), peer: "127.0.0.1")
    }

    private func json(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
    }

    private func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
    }

    private func call(_ tool: String, _ arguments: String = "{}") -> HTTPResponse {
        post(rpc(1, "tools/call", #"{"name":"\#(tool)","arguments":\#(arguments)}"#))
    }

    private func toolNames() -> [String] {
        let result = json(post(rpc(2, "tools/list")))["result"] as? [String: Any]
        return ((result?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    // --- authentication

    func testMissingAndWrongKeysAreRejectedWith401BeforeAnything() {
        let missing = post(rpc(1, "initialize"), useToken: false)
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.header("WWW-Authenticate"), "Bearer")
        let wrong = post(rpc(1, "initialize"), auth: "Bearer nccu_wrong")
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(post(rpc(1, "initialize"), auth: "Basic abc").status, 401)
        XCTAssertEqual(post(rpc(1, "initialize"), auth: "Bearer").status, 401)
        XCTAssertEqual(missing.body, wrong.body, "missing and wrong keys must be indistinguishable")
        XCTAssertEqual(post("", useToken: false).status, 401)
        clock.advance(120)   // five failures lock the client out (429); wait it out to check the next case
        XCTAssertEqual(post("", method: "GET", useToken: false).status, 401, "unauthenticated callers learn nothing about methods")
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testValidKeyInitializes() {
        let response = post(rpc(1, "initialize", #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}"#))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.header("Content-Type"), "application/json")
        let result = json(response)["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertNotNil((result?["serverInfo"] as? [String: Any])?["name"])
    }

    func testUnknownProtocolVersionFallsBackToLatestSupported() {
        let result = json(post(rpc(1, "initialize", #"{"protocolVersion":"1999-01-01"}"#)))["result"] as? [String: Any]
        XCTAssertEqual(result?["protocolVersion"] as? String, ComputerUseService.supportedProtocolVersions[0])
    }

    func testRevokedKeyIsRejectedImmediately() throws {
        XCTAssertEqual(post(rpc(1, "ping")).status, 200)
        XCTAssertTrue(keys.revoke(id: keys.records[0].id))
        XCTAssertEqual(post(rpc(2, "ping")).status, 401)
    }

    func testRepeatedWrongKeysLockOutEvenTheRightKey() {
        for _ in 0..<5 { XCTAssertEqual(post(rpc(1, "ping"), auth: "Bearer bad").status, 401) }
        let locked = post(rpc(1, "ping"))
        XCTAssertEqual(locked.status, 429)
        XCTAssertNotNil(locked.header("Retry-After"))
        clock.advance(120)
        XCTAssertEqual(post(rpc(1, "ping")).status, 200)
    }

    func testHostAndOriginChecksBlockRebinding() {
        XCTAssertEqual(post(rpc(1, "ping"), host: "evil.example.com").status, 403)
        XCTAssertEqual(post(rpc(1, "ping"), host: "localhost:47653").status, 200)
        XCTAssertEqual(post(rpc(1, "ping"), host: "[::1]:47653").status, 200)
        XCTAssertEqual(post(rpc(1, "ping"), origin: "https://evil.example.com").status, 403)
        XCTAssertEqual(post(rpc(1, "ping"), origin: "http://localhost:3000").status, 200)
        settings.allowedHosts = ["mac.example.net"]
        XCTAssertEqual(post(rpc(1, "ping"), host: "mac.example.net").status, 200)
    }

    func testOnlyPostOnMcpPath() {
        XCTAssertEqual(post(rpc(1, "ping"), path: "/other").status, 404)
        XCTAssertEqual(post("", method: "GET").status, 405)
        XCTAssertEqual(post("", method: "DELETE").status, 405)
    }

    func testStoppedServiceRefusesEverything() {
        service.stop()
        XCTAssertEqual(post(rpc(1, "ping")).status, 503)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    // --- JSON-RPC behaviour

    func testBadJSONAndUnknownMethod() {
        let parse = json(post("{oops"))
        XCTAssertEqual((parse["error"] as? [String: Any])?["code"] as? Int, JSONRPCError.parseError)
        let unknown = json(post(rpc(1, "does/not/exist")))
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, JSONRPCError.methodNotFound)
    }

    func testNotificationGets202WithNoBody() {
        let response = post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(response.status, 202)
        XCTAssertTrue(response.body.isEmpty)
    }

    func testBatchRequestsAreAnsweredInOrder() {
        let response = post("[\(rpc(1, "ping")),\(rpc(2, "tools/list"))]")
        let items = (try? JSONSerialization.jsonObject(with: response.body)) as? [[String: Any]]
        XCTAssertEqual(items?.count, 2)
        XCTAssertEqual(items?[0]["id"] as? Int, 1)
        XCTAssertEqual(items?[1]["id"] as? Int, 2)
    }

    // --- tool switches (fail closed)

    func testNothingIsListedOrCallableWhileAllGroupsAreOff() {
        XCTAssertTrue(toolNames().isEmpty)
        let result = json(call("screen_capture"))["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testEnablingAGroupExposesOnlyThatGroup() {
        settings.setEnabled(.clipboard, true)
        XCTAssertEqual(Set(toolNames()), Set(ToolCatalog.tools(in: .clipboard).map { $0.name }))
        _ = call("clipboard_read")
        XCTAssertEqual(backend.calls.map { $0.tool }, ["clipboard_read"])
        let other = json(call("mouse_click", #"{"x":1,"y":2}"#))["result"] as? [String: Any]
        XCTAssertEqual(other?["isError"] as? Bool, true)
        XCTAssertEqual(backend.calls.count, 1, "a tool of a disabled group never reaches the backend")
    }

    func testHighRiskGroupsStayHiddenWhenOnlyNormalGroupsAreOn() {
        for group in ToolGroup.allCases where !group.isHighRisk { settings.setEnabled(group, true) }
        let names = Set(toolNames())
        for name in ["applescript_run", "shell_run", "file_read", "file_write", "process_kill"] {
            XCTAssertFalse(names.contains(name), name)
            XCTAssertEqual((json(call(name))["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        XCTAssertTrue(backend.calls.isEmpty)
    }

    func testSwitchTurnedOffMidSessionTakesEffectOnTheNextCall() {
        settings.setEnabled(.shell, true)
        _ = call("shell_run", #"{"command":"echo hi"}"#)
        XCTAssertEqual(backend.calls.count, 1)
        settings.setEnabled(.shell, false)
        _ = call("shell_run", #"{"command":"echo hi"}"#)
        XCTAssertEqual(backend.calls.count, 1)
    }

    func testUnknownToolIsAProtocolError() {
        let err = json(call("no_such_tool"))["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, JSONRPCError.invalidParams)
    }

    func testToolResultIsPassedThroughIncludingImages() {
        settings.setEnabled(.screen, true)
        backend.result = ToolResult(content: [.image(base64: "QUJD", mimeType: "image/png"), .text("1x1")], isError: false)
        let result = json(call("screen_capture", #"{"target":"display"}"#))["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?[0]["type"] as? String, "image")
        XCTAssertEqual(content?[0]["data"] as? String, "QUJD")
        XCTAssertEqual(content?[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(content?[1]["type"] as? String, "text")
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertEqual(backend.calls.first?.arguments["target"], .string("display"))
    }

    func testEmergencyStopBlocksAllToolsUntilReset() {
        settings.setEnabled(.clipboard, true)
        service.emergencyStop()
        XCTAssertTrue(service.isEmergencyStopped)
        XCTAssertTrue(toolNames().isEmpty)
        XCTAssertEqual((json(call("clipboard_read"))["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(backend.calls.isEmpty)
        service.resetEmergencyStop()
        XCTAssertFalse(toolNames().isEmpty)
    }

    // --- logging and per-key limits

    func testCallLogHoldsToolNameTimeAndKeyLabelOnly() {
        settings.setEnabled(.clipboard, true); settings.setEnabled(.shell, true)
        _ = call("clipboard_write", #"{"text":"the password is hunter2"}"#)
        _ = call("shell_run", #"{"command":"cat ~/secret-file-xyz"}"#)
        _ = call("mouse_click", #"{"x":1,"y":2}"#)    // disabled -> logged as denied
        let entries = service.callLog.entries
        XCTAssertEqual(entries.map { $0.tool }, ["clipboard_write", "shell_run", "mouse_click"])
        XCTAssertEqual(entries.map { $0.keyLabel }, ["Test Key", "Test Key", "Test Key"])
        XCTAssertEqual(entries.map { $0.outcome }, [.ok, .ok, .denied])
        XCTAssertEqual(entries.map { $0.highRisk }, [false, true, false])
        XCTAssertEqual(entries[0].time, clock.now)
        let dump = "\(entries)"
        XCTAssertFalse(dump.contains("hunter2")); XCTAssertFalse(dump.contains("secret-file-xyz"))
        XCTAssertFalse(dump.contains(token))
        XCTAssertEqual(service.diagnostics.values.filter { $0.contains(token) }.count, 0)
    }

    func testCallLogIsBounded() {
        settings.setEnabled(.clipboard, true)
        service = ComputerUseService(settings: { [unowned self] in self.settings }, keys: keys, backend: backend,
                                     requests: RequestRateLimiter(limit: 100_000, window: 60, now: { [clock] in clock.now }),
                                     now: { [clock] in clock.now })
        for _ in 0..<(CallLog.capacity + 25) { _ = call("clipboard_read") }
        XCTAssertEqual(service.callLog.entries.count, CallLog.capacity)
    }

    func testCallLogNotifiesObserverWithoutArguments() {
        settings.setEnabled(.clipboard, true)
        var seen: [CallLogEntry] = []
        service.callLog.onEntry = { seen.append($0) }
        _ = call("clipboard_write", #"{"text":"hunter2"}"#)
        XCTAssertEqual(seen.map { $0.tool }, ["clipboard_write"])
        XCTAssertFalse("\(seen)".contains("hunter2"))
    }

    func testPerKeyRequestRateLimit() {
        service = ComputerUseService(settings: { [unowned self] in self.settings }, keys: keys, backend: backend,
                                     requests: RequestRateLimiter(limit: 3, window: 60, now: { [clock] in clock.now }),
                                     now: { [clock] in clock.now })
        for _ in 0..<3 { XCTAssertEqual(post(rpc(1, "ping")).status, 200) }
        let limited = post(rpc(1, "ping"))
        XCTAssertEqual(limited.status, 429)
        XCTAssertNotNil(limited.header("Retry-After"))
    }

    func testBackendErrorsAreReturnedAsToolErrorsAndLogged() {
        settings.setEnabled(.clipboard, true)
        backend.result = ToolResult.error("boom")
        let result = json(call("clipboard_read"))["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        XCTAssertEqual(service.callLog.entries.last?.outcome, .error)
    }

    func testMalformedToolCallParamsAreInvalidParams() {
        settings.setEnabled(.clipboard, true)
        let err = json(post(rpc(1, "tools/call", #"{"arguments":{}}"#)))["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, JSONRPCError.invalidParams)
        let err2 = json(post(rpc(1, "tools/call", #"{"name":"clipboard_read","arguments":[1]}"#)))["error"] as? [String: Any]
        XCTAssertEqual(err2?["code"] as? Int, JSONRPCError.invalidParams)
        XCTAssertTrue(backend.calls.isEmpty)
    }
}
