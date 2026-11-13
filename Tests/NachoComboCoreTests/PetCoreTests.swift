import XCTest
@testable import NachoComboCore

// New for Nacho Combo: login (PKCE), uploads, connector commands and the session that ties them together.

/// Fixed bytes so verifiers and states are predictable.
final class PetFixedRandom: RandomBytesSource {
    var next: UInt8 = 1
    func bytes(count: Int) -> [UInt8] {
        defer { next &+= 1 }
        return [UInt8](repeating: next, count: count)
    }
}

/// Answers by "METHOD path". `on` sets the answer; `then` queues more (consumed in order, the last one repeats).
final class PetStubHTTP: PetHTTPClient {
    private let lock = NSLock()
    private var answers: [String: [PetHTTPResponse]] = [:]
    private(set) var requests: [PetHTTPRequest] = []
    var failNetwork = false
    /// Response headers by "METHOD path".
    var headers: [String: [String: String]] = [:]

    func on(_ method: String, _ path: String, _ status: Int, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        answers["\(method) \(path)"] = [PetHTTPResponse(status: status, body: Data(body.utf8))]
    }

    func then(_ method: String, _ path: String, _ status: Int, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        answers["\(method) \(path)", default: []].append(PetHTTPResponse(status: status, body: Data(body.utf8)))
    }

    func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
        lock.lock()
        requests.append(request)
        let key = "\(request.method) \(request.url.path)"
        var list = answers[key] ?? []
        var r = list.first ?? PetHTTPResponse(status: 404, body: Data("{}".utf8))
        if let h = headers[key] { r.headers = h }
        if list.count > 1 { list.removeFirst(); answers[key] = list }
        let fail = failNetwork
        lock.unlock()
        if fail { completion(.failure(URLError(.notConnectedToInternet))); return }
        completion(.success(r))
    }

    func sent(_ method: String, _ path: String) -> [PetHTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.method == method && $0.url.path == path }
    }

    static func form(_ r: PetHTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: r.body ?? Data(), as: UTF8.self).split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    static func json(_ r: PetHTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
    }
}

let petTokenJSON = #"{"access_token":"at-1","token_type":"Bearer","expires_in":300,"refresh_token":"rt-1","refresh_expires_in":1800,"id_token":"id-1"}"#

final class PetAuthTests: XCTestCase {
    let config = OIDCConfig(issuer: URL(string: "https://auth.nachotown.com/realms/nachotown")!)

    func testPKCEMatchesRFC7636Example() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let made = PKCE.make(random: PetFixedRandom())
        XCTAssertEqual(made.verifier.count, 43)
        XCTAssertFalse(made.verifier.contains("="))
        XCTAssertFalse(made.verifier.contains("+") || made.verifier.contains("/"))
    }

    func testAuthorizationURLCarriesTheServerAcceptedValues() {
        let pending = OAuthRequests.begin(config, random: PetFixedRandom())
        let c = URLComponents(url: pending.url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.host, "auth.nachotown.com")
        XCTAssertEqual(c.path, "/realms/nachotown/protocol/openid-connect/auth")
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        XCTAssertEqual(q["client_id"], "nacho-gadget-app")
        XCTAssertEqual(q["redirect_uri"], "nachogadget://auth/callback")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], pending.pkce.challenge)
        XCTAssertEqual(q["state"], pending.state)
        XCTAssertEqual(q["scope"], "openid")
        XCTAssertNotEqual(pending.state, pending.pkce.verifier)
    }

    func testCallbackChecks() {
        func cb(_ s: String) -> Result<String, AuthProblem> {
            OAuthRequests.code(fromCallback: URL(string: s)!, expectedState: "st")
        }
        XCTAssertEqual(cb("nachogadget://auth/callback?code=abc&state=st&session_state=x"), .success("abc"))
        XCTAssertEqual(cb("nachogadget://auth/callback?code=abc&state=other"), .failure(.stateMismatch))
        XCTAssertEqual(cb("nachogadget://auth/callback?code=abc"), .failure(.stateMismatch))
        XCTAssertEqual(cb("nachogadget://auth/callback?error=access_denied&state=st"), .failure(.canceled))
        XCTAssertEqual(cb("nachogadget://auth/callback?error=login_required&state=st"), .failure(.denied("login_required")))
        XCTAssertEqual(cb("nachogadget://auth/callback?error=access_denied&state=evil"), .failure(.stateMismatch))
        XCTAssertEqual(cb("nachogadget://evil/callback?code=abc&state=st"), .failure(.badCallback))
        XCTAssertEqual(cb("https://auth/callback?code=abc&state=st"), .failure(.badCallback))
        XCTAssertEqual(cb("nachogadget://auth/callback?code=a&code=b&state=st"), .failure(.badCallback))
        XCTAssertEqual(cb("nachogadget://auth/callback?code=&state=st"), .failure(.badCallback))
        XCTAssertEqual(cb("nachogadget://auth/callback?code=a%20b&state=st"), .failure(.badCallback))
    }

    func testTokenDecoding() {
        let now = Date(timeIntervalSince1970: 1_000)
        let t = try! TokenSet.decode(Data(petTokenJSON.utf8), now: now).get()
        XCTAssertEqual(t.accessToken, "at-1")
        XCTAssertEqual(t.refreshToken, "rt-1")
        XCTAssertEqual(t.expiresAt, now.addingTimeInterval(300))
        XCTAssertEqual(t.refreshExpiresAt, now.addingTimeInterval(1800))
        XCTAssertTrue(t.accessIsFresh(now: now.addingTimeInterval(200)))
        XCTAssertFalse(t.accessIsFresh(now: now.addingTimeInterval(250)), "refreshed a minute early")
        XCTAssertTrue(t.canRefresh(now: now.addingTimeInterval(1799)))
        XCTAssertFalse(t.canRefresh(now: now.addingTimeInterval(1800)))
        XCTAssertEqual(TokenSet.decode(Data(#"{"error":"invalid_grant"}"#.utf8), now: now), .failure(.rejected("invalid_grant")))
        XCTAssertEqual(TokenSet.decode(Data(#"{"access_token":"a","token_type":"mac"}"#.utf8), now: now), .failure(.badResponse))
        XCTAssertEqual(TokenSet.decode(Data(#"{"access_token":"a b"}"#.utf8), now: now), .failure(.badResponse))
        XCTAssertEqual(TokenSet.decode(Data("nope".utf8), now: now), .failure(.badResponse))
        let offline = try! TokenSet.decode(Data(#"{"access_token":"a","expires_in":1,"refresh_token":"r","refresh_expires_in":0}"#.utf8), now: now).get()
        XCTAssertEqual(offline.expiresAt, now.addingTimeInterval(10), "clamped")
        XCTAssertNil(offline.refreshExpiresAt)
        XCTAssertTrue(offline.canRefresh(now: now.addingTimeInterval(1_000_000)))
    }

    private func signedIn(_ http: PetStubHTTP, _ secrets: MemorySecretStore, clock: @escaping () -> Date) -> PetAuth {
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        let auth = PetAuth(config: config, scope: "s", http: http, secrets: secrets, random: PetFixedRandom(), now: clock)
        let pending = try! auth.begin().get()
        let ex = expectation(description: "signin")
        auth.complete(callback: URL(string: "nachogadget://auth/callback?code=c1&state=\(pending.state)")!, pending: pending) { r in
            if case let .failure(p) = r { XCTFail("sign-in failed: \(p)") }
            ex.fulfill()
        }
        wait(for: [ex], timeout: 5)
        let form = PetStubHTTP.form(http.requests.last!)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "c1")
        XCTAssertEqual(form["code_verifier"], pending.pkce.verifier)
        XCTAssertEqual(form["redirect_uri"], "nachogadget://auth/callback")
        XCTAssertEqual(form["client_id"], "nacho-gadget-app")
        return auth
    }

    private func token(_ auth: PetAuth) -> Result<String, AuthProblem> {
        let ex = expectation(description: "token")
        var out: Result<String, AuthProblem>!
        auth.validAccessToken { out = $0; ex.fulfill() }
        wait(for: [ex], timeout: 5)
        return out
    }

    func testSignInStoresTokensAndRefreshesWhenStale() {
        var now = Date(timeIntervalSince1970: 1_000)
        let http = PetStubHTTP(), secrets = MemorySecretStore()
        let auth = signedIn(http, secrets, clock: { now })
        XCTAssertNotNil(secrets.read("tokens|s"), "kept in the secret store")
        XCTAssertEqual(PetAuth(config: config, scope: "s", http: http, secrets: secrets).currentAccessToken, "at-1",
                       "a new launch finds the session")
        XCTAssertNil(PetAuth(config: config, scope: "other", http: http, secrets: secrets).currentAccessToken,
                     "another server never sees these tokens")
        XCTAssertEqual(token(auth), .success("at-1"))
        XCTAssertEqual(http.requests.count, 1, "fresh: no network")
        now = now.addingTimeInterval(290)
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token",
                200, #"{"access_token":"at-2","expires_in":300}"#)
        XCTAssertEqual(token(auth), .success("at-2"))
        let form = PetStubHTTP.form(http.requests.last!)
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "rt-1")
        now = now.addingTimeInterval(290)
        XCTAssertEqual(token(auth), .success("at-2"), "repeated last answer; the old refresh token was kept")
        XCTAssertEqual(PetStubHTTP.form(http.requests.last!)["refresh_token"], "rt-1")
    }

    func testConcurrentRefreshSharesOneRequest() {
        var now = Date(timeIntervalSince1970: 1_000)
        let http = PetStubHTTP(), secrets = MemorySecretStore()
        let auth = signedIn(http, secrets, clock: { now })
        now = now.addingTimeInterval(1000)
        let before = http.requests.count
        let group = DispatchGroup()
        for _ in 0..<5 { group.enter(); auth.validAccessToken { _ in group.leave() } }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(http.requests.count - before, 1)
    }

    func testDeadRefreshTokenSignsOut() {
        var now = Date(timeIntervalSince1970: 1_000)
        let http = PetStubHTTP(), secrets = MemorySecretStore()
        let auth = signedIn(http, secrets, clock: { now })
        now = now.addingTimeInterval(1000)
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 400, #"{"error":"invalid_grant"}"#)
        XCTAssertEqual(token(auth), .failure(.rejected("invalid_grant")))
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(secrets.read("tokens|s"))
        XCTAssertEqual(token(auth), .failure(.signedOut))
    }

    func testNetworkFailureKeepsTheSession() {
        var now = Date(timeIntervalSince1970: 1_000)
        let http = PetStubHTTP(), secrets = MemorySecretStore()
        let auth = signedIn(http, secrets, clock: { now })
        now = now.addingTimeInterval(1000)
        http.failNetwork = true
        XCTAssertEqual(token(auth), .failure(.network))
        XCTAssertTrue(auth.isSignedIn, "offline is not signed out")
    }

    func testSignOutEndsTheKeycloakSessionAndForgets() {
        let http = PetStubHTTP(), secrets = MemorySecretStore()
        let auth = signedIn(http, secrets, clock: Date.init)
        let ex = expectation(description: "out")
        auth.signOut { ex.fulfill() }
        wait(for: [ex], timeout: 5)
        let logout = http.sent("POST", "/realms/nachotown/protocol/openid-connect/logout")
        XCTAssertEqual(logout.count, 1)
        XCTAssertEqual(PetStubHTTP.form(logout[0])["refresh_token"], "rt-1")
        XCTAssertFalse(auth.isSignedIn)
        XCTAssertNil(secrets.read("tokens|s"))
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(PetHTTPRequest.formEscape("a+b&c=d e/é"), "a%2Bb%26c%3Dd%20e%2F%C3%A9")
    }
}

final class PetMediaTests: XCTestCase {
    func testPrepareChecksTypeSizeAndName() {
        let png = try! PetMedia.prepare(name: "/Users/x/Desktop/Capture 1.png", data: Data([1, 2, 3])).get()
        XCTAssertEqual(png.name, "Capture 1.png")
        XCTAssertEqual(png.mime, "image/png")
        XCTAssertEqual(png.kind, "image")
        XCTAssertEqual(png.readability, .seen)
        XCTAssertEqual(try? PetMedia.prepare(name: "notes.md", data: Data("hi".utf8)).get().readability, .read)
        XCTAssertEqual(try? PetMedia.prepare(name: "a.pdf", data: Data([1])).get().readability, .storedOnly)
        XCTAssertEqual(try? PetMedia.prepare(name: "a.mp4", data: Data([1])).get().kind, "video")
        XCTAssertEqual(PetMedia.prepare(name: "run.sh", data: Data([1])), .failure(.unsupportedType))
        XCTAssertEqual(PetMedia.prepare(name: "noext", data: Data([1])), .failure(.unsupportedType))
        XCTAssertEqual(PetMedia.prepare(name: "x.svg", data: Data([1]), mime: "application/x-sh"), .failure(.unsupportedType))
        XCTAssertEqual(PetMedia.prepare(name: "a.png", data: Data()), .failure(.empty))
        XCTAssertEqual(PetMedia.prepare(name: "a.png", data: Data(count: PetMedia.maxUploadBytes + 1)), .failure(.tooLarge))
        XCTAssertEqual(PetMedia.sanitizedName("a\u{0}b\nc.txt"), "abc.txt")
        XCTAssertEqual(PetMedia.sanitizedName(".."), "file")
        let long = PetMedia.sanitizedName(String(repeating: "가", count: 300) + ".png")
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix(".png"))
        XCTAssertEqual(PetMedia.fileExtension(".profile"), "")
        XCTAssertEqual(PetMedia.readability(mime: "image/png", bytes: PetMedia.maxSeenImageBytes + 1), .storedOnly)
        XCTAssertTrue(PetMedia.shouldShrinkForNacho(mime: "image/png", bytes: PetMedia.maxSeenImageBytes + 1))
        XCTAssertFalse(PetMedia.shouldShrinkForNacho(mime: "application/pdf", bytes: 30_000_000))
    }

    func testUploadRequestAndErrors() {
        let ep = try! ServerEndpoint.parse("http://127.0.0.1:8787").get()
        let file = try! PetMedia.prepare(name: "a.png", data: Data([0xff, 0x00])).get()
        let req = PetMedia.uploadRequest(ep, bearer: "tok", file: file)
        XCTAssertEqual(req.url.absoluteString, "http://127.0.0.1:8787/api/v1/media/uploads")
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok")
        let body = PetStubHTTP.json(req)
        XCTAssertEqual(body["bytes_base64"] as? String, "/wA=")
        XCTAssertEqual(body["mime"] as? String, "image/png")
        XCTAssertEqual(body["kind"] as? String, "image")
        XCTAssertNil(PetMedia.decodeUpload(Data(#"{"attachment_id":"../x"}"#.utf8)))

        let http = PetStubHTTP()
        func run() -> Result<PetAttachment, MediaProblem> {
            let ex = expectation(description: "up")
            var out: Result<PetAttachment, MediaProblem>!
            PetMedia.upload(file, endpoint: ep, bearer: "t", http: http) { out = $0; ex.fulfill() }
            wait(for: [ex], timeout: 5)
            return out
        }
        http.on("POST", "/api/v1/media/uploads", 201, #"{"attachment_id":"0193aaaa-0000-7000-8000-00000000000a","kind":"image","name":"a.png","mime":"image/png","bytes":2}"#)
        XCTAssertEqual(try? run().get().attachmentID, "0193aaaa-0000-7000-8000-00000000000a")
        http.on("POST", "/api/v1/media/uploads", 413, "{}")
        XCTAssertEqual(run(), .failure(.tooLarge))
        http.on("POST", "/api/v1/media/uploads", 400, #"{"error":{"code":"validation_error"}}"#)
        XCTAssertEqual(run(), .failure(.unsupportedType))
        http.on("POST", "/api/v1/media/uploads", 401, "{}")
        XCTAssertEqual(run(), .failure(.unauthorized))
    }

    func testMessageFrameCarriesAttachmentIDs() {
        let m = ClientFrame.message(text: "", roomID: nil, clientMsgID: "c", attachmentIDs: ["id1", "id2"]).encode()
        let o = try! JSONSerialization.jsonObject(with: Data(m.utf8)) as! [String: Any]
        let a = o["attachments"] as! [[String: Any]]
        XCTAssertEqual(a.map { $0["attachment_id"] as? String }, ["id1", "id2"])
        XCTAssertNil((try! JSONSerialization.jsonObject(with: Data(ClientFrame.message(text: "x", roomID: nil, clientMsgID: "c").encode().utf8)) as! [String: Any])["attachments"])
        XCTAssertEqual(OutgoingText.validate("  ", allowEmpty: true), .success(""))
        XCTAssertEqual(OutgoingText.validate("  "), .failure(.empty))
    }
}

final class PetCommandsTests: XCTestCase {
    func testCapabilitiesAreWellFormed() {
        let caps = PetCommands.capabilities
        XCTAssertEqual(caps.map { $0["name"] as? String }, PetCommands.names)
        for c in caps {
            let name = c["name"] as! String
            XCTAssertTrue(name.range(of: "^[a-zA-Z0-9_-]{1,64}$", options: .regularExpression) != nil)
            XCTAssertNotNil(c["input_schema"] as? [String: Any])
            XCTAssertTrue(JSONSerialization.isValidJSONObject(c))
        }
        XCTAssertFalse(PetCommands.toggleable.contains(.computerUse))
        XCTAssertFalse(PetCommands.toggleable.contains(.nachoPet))
        XCTAssertTrue(PetCommands.toggleable.contains(.windowSnap))
    }

    func testParse() {
        XCTAssertEqual(PetCommands.parse(capability: "combo_arrange_window", params: ["position": "left"]),
                       .success(.arrangeWindow(.left, app: nil)))
        XCTAssertEqual(PetCommands.parse(capability: "combo_arrange_window", params: ["position": "top-left", "app": " Safari "]),
                       .success(.arrangeWindow(.topLeft, app: "Safari")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_arrange_window", params: ["position": "sideways"]),
                       .failure(.badParams("position must be one of \(SnapAction.allCases.map { $0.rawValue }.joined(separator: ", "))")))
        if case .success = PetCommands.parse(capability: "combo_arrange_window", params: ["position": "left", "app": String(repeating: "x", count: 101)]) {
            XCTFail("long app name accepted")
        }
        if case .success = PetCommands.parse(capability: "combo_arrange_window", params: ["position": "left", "app": "a\nb"]) {
            XCTFail("control characters accepted")
        }
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_gadget", params: ["gadget": "windowSnap", "on": true]),
                       .success(.setGadget(.windowSnap, on: true)))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_gadget", params: ["gadget": "Keep Awake", "on": false]),
                       .success(.setGadget(.keepAwake, on: false)))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_gadget", params: ["gadget": "computerUse", "on": true]),
                       .failure(.notAllowed("Computer Use can only be switched by the user in Nacho Combo")))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_gadget", params: ["gadget": "nachoPet", "on": false]),
                       .failure(.notAllowed("Nacho Pet can only be switched by the user in Nacho Combo")))
        if case .success = PetCommands.parse(capability: "combo_set_gadget", params: ["gadget": "windowSnap", "on": "yes"]) {
            XCTFail("string accepted as bool")
        }
        XCTAssertEqual(PetCommands.parse(capability: "combo_list_gadgets", params: nil), .success(.listGadgets))
        XCTAssertEqual(PetCommands.parse(capability: "run_shell", params: [:]), .failure(.unknownCapability("run_shell")))
    }

    func testParsesTheSameFromServerJSON() {
        // What the server forwards is JSON: booleans must not be confused with numbers.
        let json = try! JSONSerialization.jsonObject(with: Data(#"{"gadget":"focusDim","on":true}"#.utf8))
        XCTAssertEqual(PetCommands.parse(capability: "combo_set_gadget", params: json), .success(.setGadget(.focusDim, on: true)))
    }
}

/// Records commands and answers ok.
final class PetRecordingExecutor: PetCommandExecuting {
    private let lock = NSLock()
    private(set) var commands: [PetCommand] = []
    func execute(_ command: PetCommand, done: @escaping (PetCommandOutcome) -> Void) {
        lock.lock(); commands.append(command); lock.unlock()
        done(PetCommandOutcome(ok: true, message: "done"))
    }
}

/// Hands out fake transports and remembers them (thread-safe: chat and connector create theirs on their own queues).
final class PetTransportFactory {
    private let lock = NSLock()
    private var all: [PetFakeTransport] = []
    func make() -> WebSocketTransport {
        let t = PetFakeTransport()
        lock.lock(); all.append(t); lock.unlock()
        return t
    }
    func with(path: String) -> [PetFakeTransport] {
        lock.lock(); defer { lock.unlock() }
        return all.filter { $0.url?.path == path }
    }
}

final class PetConnectorClientTests: XCTestCase {
    func testHelloRequestResponseAndReplacement() throws {
        let factory = PetTransportFactory()
        let ex = PetRecordingExecutor()
        var scheduled: [() -> Void] = []
        let c = PetConnectorClient(url: URL(string: "ws://127.0.0.1:8787/ws/connector")!, token: "nct_abc", executor: ex,
                                   makeTransport: factory.make, schedule: { _, w in scheduled.append(w) })
        c.connect(); c.flush()
        let t = factory.with(path: "/ws/connector")[0]
        XCTAssertNil(t.bearer, "token only in the hello frame")
        t.handler?(.opened); c.flush()
        let hello = try JSONSerialization.jsonObject(with: Data(t.sent[0].utf8)) as! [String: Any]
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["token"] as? String, "nct_abc")
        XCTAssertEqual((hello["capabilities"] as? [[String: Any]])?.count, PetCommands.names.count)
        t.deliver(#"{"type":"ready","agent_id":"a","kind":"nacho_combo"}"#); c.flush()
        XCTAssertEqual(c.phase, .ready)
        t.deliver(#"{"type":"request","id":"r1","capability":"combo_arrange_window","params":{"position":"right"}}"#); c.flush(); c.flush()
        XCTAssertEqual(ex.commands, [.arrangeWindow(.right, app: nil)])
        let resp = try JSONSerialization.jsonObject(with: Data(t.sent.last!.utf8)) as! [String: Any]
        XCTAssertEqual(resp["id"] as? String, "r1")
        XCTAssertEqual((resp["result"] as? [String: Any])?["ok"] as? Bool, true)
        t.deliver(#"{"type":"request","id":"r2","capability":"combo_set_gadget","params":{"gadget":"computerUse","on":true}}"#); c.flush()
        let refused = try JSONSerialization.jsonObject(with: Data(t.sent.last!.utf8)) as! [String: Any]
        XCTAssertEqual(refused["id"] as? String, "r2")
        XCTAssertNotNil(refused["error"] as? String)
        XCTAssertEqual(ex.commands.count, 1, "refused before reaching the app")
        t.deliver(#"{"type":"error","code":"replaced","message":"another connector session took over"}"#); c.flush()
        t.handler?(.closed(nil)); c.flush()
        XCTAssertEqual(c.phase, .replaced)
        XCTAssertEqual(factory.with(path: "/ws/connector").count, 1, "no fight for the slot")
        _ = scheduled
    }

    func testBindingRequestAndToken() {
        let ep = try! ServerEndpoint.parse("https://nacho.nachotown.com").get()
        XCTAssertNil(ConnectorBinding.request(ep, bearer: "t", agentID: "../../admin"))
        let r = ConnectorBinding.request(ep, bearer: "t", agentID: "0193AAAA-0000-7000-8000-000000000002")!
        XCTAssertEqual(r.url.absoluteString, "https://nacho.nachotown.com/api/v1/agents/0193aaaa-0000-7000-8000-000000000002/connector-binding")
        XCTAssertEqual(PetStubHTTP.json(r)["kind"] as? String, "nacho_combo")
        XCTAssertEqual(ConnectorBinding.token(from: Data(#"{"token":"nct_0a1b","endpoint":"/ws/connector"}"#.utf8)), "nct_0a1b")
        XCTAssertNil(ConnectorBinding.token(from: Data(#"{"token":"Bearer x"}"#.utf8)))
    }
}

/// Answers the login page with a redirect carrying the state it was given.
final class PetFakeBrowser: PetAuthBrowser {
    var opened: [URL] = []
    var cancel = false
    func authorize(url: URL, callbackScheme: String, completion: @escaping (Result<URL, AuthProblem>) -> Void) {
        opened.append(url)
        if cancel { completion(.failure(.canceled)); return }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        completion(.success(URL(string: "nachogadget://auth/callback?code=c1&state=\(state)")!))
    }
}

final class PetSessionTests: XCTestCase {
    let agent = "0193aaaa-0000-7000-8000-000000000002"
    var http: PetStubHTTP!
    var secrets: MemorySecretStore!
    var browser: PetFakeBrowser!
    var factory: PetTransportFactory!
    var executor: PetRecordingExecutor!

    override func setUp() {
        http = PetStubHTTP()
        secrets = MemorySecretStore()
        browser = PetFakeBrowser()
        factory = PetTransportFactory()
        executor = PetRecordingExecutor()
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, petTokenJSON)
        http.on("POST", "/api/v1/agents/\(agent)/connector-binding", 200, #"{"token":"nct_feed","endpoint":"/ws/connector"}"#)
    }

    private func session(_ mutate: (inout PetSettings) -> Void = { _ in }) -> PetSession {
        var s = PetSettings()
        s.serverMode = .mock
        mutate(&s)
        return PetSession(settings: s, http: http, secrets: secrets, browser: browser, makeTransport: factory.make,
                          executor: executor, random: PetFixedRandom())
    }

    private func settle(_ s: PetSession) { for _ in 0..<6 { s.flush(); Thread.sleep(forTimeInterval: 0.01) } }

    private var ready: String {
        #"{"type":"ready","user_id":"u","agent_id":"\#(agent)","agent_name":"나초","room_id":"r"}"#
    }

    func testNothingConnectsBeforeTheChatOpens() {
        let s = session()
        settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedOut)
        XCTAssertTrue(http.requests.isEmpty)
        s.open(); settle(s)
        XCTAssertTrue(factory.with(path: "/ws/chat").isEmpty, "signed out: no socket")
    }

    func testSignInConnectsChatThenConnectorAndRunsACommand() throws {
        let s = session()
        s.signIn(); settle(s)
        XCTAssertEqual(browser.opened.count, 1)
        XCTAssertEqual(browser.opened[0].host, "127.0.0.1")
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        let chat = factory.with(path: "/ws/chat")
        XCTAssertEqual(chat.count, 1)
        XCTAssertEqual(chat[0].bearer, "at-1")
        chat[0].deliver(ready); settle(s)
        XCTAssertEqual(s.snapshot.chat.phase, .connected)
        XCTAssertEqual(http.sent("POST", "/api/v1/agents/\(agent)/connector-binding").count, 1)
        XCTAssertEqual(http.sent("POST", "/api/v1/agents/\(agent)/connector-binding")[0].headers["Authorization"], "Bearer at-1")
        let conn = factory.with(path: "/ws/connector")
        XCTAssertEqual(conn.count, 1)
        conn[0].handler?(.opened); settle(s)
        conn[0].deliver(#"{"type":"ready","agent_id":"a","kind":"nacho_combo"}"#); settle(s)
        XCTAssertEqual(s.snapshot.connector, .ready)
        conn[0].deliver(#"{"type":"request","id":"q","capability":"combo_set_gadget","params":{"gadget":"keepAwake","on":true}}"#); settle(s)
        XCTAssertEqual(executor.commands, [.setGadget(.keepAwake, on: true)])
        XCTAssertEqual(secrets.read(ConnectorBinding.secretKey(scope: s.settings.accountScope, agentID: agent)), Data("nct_feed".utf8))

        // Next launch: the binding token is reused, no second POST.
        let again = session()
        again.open(); settle(again)
        factory.with(path: "/ws/chat").last!.deliver(ready); settle(again)
        XCTAssertEqual(http.sent("POST", "/api/v1/agents/\(agent)/connector-binding").count, 1)
        XCTAssertEqual(factory.with(path: "/ws/connector").count, 2)
    }

    func testComboControlOffMeansNoConnector() {
        let s = session { $0.allowComboControl = false }
        s.signIn(); settle(s)
        factory.with(path: "/ws/chat")[0].deliver(ready); settle(s)
        XCTAssertTrue(factory.with(path: "/ws/connector").isEmpty)
        XCTAssertTrue(http.sent("POST", "/api/v1/agents/\(agent)/connector-binding").isEmpty)
    }

    func testAttachUploadsThenSendsTheIDs() throws {
        http.on("POST", "/api/v1/media/uploads", 201, #"{"attachment_id":"0193aaaa-0000-7000-8000-0000000000a1","kind":"image","name":"c.png","mime":"image/png","bytes":3}"#)
        http.then("POST", "/api/v1/media/uploads", 201, #"{"attachment_id":"0193aaaa-0000-7000-8000-0000000000a2","kind":"file","name":"n.md","mime":"text/markdown","bytes":2}"#)
        let s = session { $0.allowComboControl = false }
        s.signIn(); settle(s)
        let chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(ready); settle(s)
        XCTAssertNil(s.attach(try PetMedia.prepare(name: "c.png", data: Data([1, 2, 3])).get()))
        XCTAssertNil(s.attach(try PetMedia.prepare(name: "n.md", data: Data("hi".utf8)).get()))
        XCTAssertEqual(s.snapshot.pending.count, 2)
        let done = expectation(description: "send")
        s.send(text: "이거 뭐야?") { refusal in XCTAssertNil(refusal); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(http.sent("POST", "/api/v1/media/uploads").count, 2)
        let frame = try JSONSerialization.jsonObject(with: Data(chat.sent.last!.utf8)) as! [String: Any]
        XCTAssertEqual(frame["text"] as? String, "이거 뭐야?")
        XCTAssertEqual((frame["attachments"] as? [[String: Any]])?.compactMap { $0["attachment_id"] as? String },
                       ["0193aaaa-0000-7000-8000-0000000000a1", "0193aaaa-0000-7000-8000-0000000000a2"])
        XCTAssertTrue(s.snapshot.pending.isEmpty)
        XCTAssertEqual(s.snapshot.chat.turns.last?.attachmentNames, ["c.png", "n.md"])
        for _ in 0..<PetMedia.maxAttachments { s.attach(try PetMedia.prepare(name: "x.png", data: Data([1])).get()) }
        XCTAssertEqual(s.attach(try PetMedia.prepare(name: "y.png", data: Data([1])).get()), MediaProblem.tooMany.koreanMessage)
    }

    func testFailedUploadKeepsTheFilesAndSendsNothing() throws {
        http.on("POST", "/api/v1/media/uploads", 413, "{}")
        let s = session { $0.allowComboControl = false }
        s.signIn(); settle(s)
        let chat = factory.with(path: "/ws/chat")[0]
        chat.deliver(ready); settle(s)
        s.attach(try PetMedia.prepare(name: "c.png", data: Data([1])).get())
        let done = expectation(description: "send")
        s.send(text: "봐줘") { refusal in XCTAssertEqual(refusal, MediaProblem.tooLarge.koreanMessage); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(s.snapshot.pending.count, 1)
        XCTAssertTrue(chat.sent.isEmpty)
    }

    func testExpiredTokenRefreshesOnceAndReconnects() {
        let s = session { $0.allowComboControl = false }
        s.signIn(); settle(s)
        http.on("POST", "/realms/nachotown/protocol/openid-connect/token", 200, #"{"access_token":"at-2","expires_in":300,"refresh_token":"rt-2"}"#)
        factory.with(path: "/ws/chat")[0].handler?(.closed(TransportFailure(httpStatus: 401, message: "401"))); settle(s)
        let chats = factory.with(path: "/ws/chat")
        XCTAssertEqual(chats.count, 2)
        XCTAssertEqual(chats[1].bearer, "at-2")
        XCTAssertEqual(s.snapshot.auth, .signedIn)
        chats[1].handler?(.closed(TransportFailure(httpStatus: 401, message: "401"))); settle(s)
        XCTAssertEqual(factory.with(path: "/ws/chat").count, 2, "a second 401 in a row does not loop")
    }

    func testCanceledLoginStaysSignedOutAndSignOutForgets() {
        browser.cancel = true
        let s = session()
        s.signIn(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedOut)
        XCTAssertEqual(s.snapshot.notice, AuthProblem.canceled.koreanMessage)
        browser.cancel = false
        s.signIn(); settle(s)
        factory.with(path: "/ws/chat")[0].deliver(ready); settle(s)
        s.signOut(); settle(s)
        XCTAssertEqual(s.snapshot.auth, .signedOut)
        XCTAssertTrue(factory.with(path: "/ws/chat")[0].closed)
        XCTAssertTrue(secrets.keys.isEmpty, "tokens and the connector binding are gone")
    }

    func testSignOutInALaterLaunchAlsoForgetsTheConnectorBinding() {
        let s = session()
        s.signIn(); settle(s)
        factory.with(path: "/ws/chat")[0].deliver(ready); settle(s)
        XCTAssertNotNil(secrets.read(ConnectorBinding.secretKey(scope: s.settings.accountScope, agentID: agent)))
        s.shutdown()
        let later = session()  // a new launch: nothing connected, the agent id only on disk
        later.signOut(); settle(later)
        XCTAssertTrue(secrets.keys.isEmpty)
    }

    func testShutdownClosesEverything() {
        let s = session()
        s.signIn(); settle(s)
        factory.with(path: "/ws/chat")[0].deliver(ready); settle(s)
        s.shutdown(); settle(s)
        XCTAssertTrue(factory.with(path: "/ws/chat").allSatisfy { $0.closed })
        XCTAssertTrue(factory.with(path: "/ws/connector").allSatisfy { $0.closed })
        XCTAssertEqual(s.snapshot.connector, .off)
        XCTAssertEqual(s.snapshot.chat.phase, .disconnected)
    }
}

final class PetFaceTests: XCTestCase {
    func testLongWaitAndConnectingFaces() {
        let t0 = Date(timeIntervalSince1970: 0)
        var chat = ChatState()
        XCTAssertEqual(PetFace.derive(dictating: false, chat: chat, now: t0.addingTimeInterval(60), lastInteraction: t0), .idle)
        XCTAssertEqual(PetFace.derive(dictating: false, chat: chat, now: t0.addingTimeInterval(PetFace.tiredAfter), lastInteraction: t0), .tired)
        XCTAssertEqual(PetFace.derive(dictating: false, chat: chat, now: t0.addingTimeInterval(PetFace.sleepAfter), lastInteraction: t0), .sleeping)
        chat.phase = .reconnecting(attempt: 1)
        XCTAssertEqual(PetFace.derive(dictating: false, chat: chat, now: t0, lastInteraction: t0), .waiting)
        XCTAssertEqual(PetFace.derive(dictating: true, chat: chat, now: t0, lastInteraction: t0), .listening)
        XCTAssertEqual(Set(PetFace.allCases.map { $0.assetName }).count, PetFace.allCases.count)
    }
}
