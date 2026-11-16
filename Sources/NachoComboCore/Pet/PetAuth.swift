import Foundation

// Nacho Pet login: Keycloak (realm `mafianacho`, the unified IdP), public client `nacho-gadget-app`, Authorization Code + PKCE (S256),
// redirect `nachogadget://auth/callback` — the values nacho-server already accepts (docs/keycloak-nacho-gadget-app.md).
// Everything that decides (URLs, PKCE, callback checks, token parsing, refresh timing) is here so it is tested on Linux;
// the app only opens the system browser sheet and keeps the tokens in the Keychain.

public struct OIDCConfig: Equatable {
    public static let clientID = "nacho-gadget-app"
    public static let redirectURI = "nachogadget://auth/callback"
    public static let callbackScheme = "nachogadget"
    public static let scope = "openid"

    public let issuer: URL
    public init(issuer: URL) { self.issuer = issuer }

    private func endpoint(_ tail: String) -> URL { issuer.appendingPathComponent("protocol/openid-connect/" + tail) }
    public var authorizationEndpoint: URL { endpoint("auth") }
    public var tokenEndpoint: URL { endpoint("token") }
    public var logoutEndpoint: URL { endpoint("logout") }
}

public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// RFC 7636. The verifier is 32 random bytes in base64url (43 characters, inside the 43...128 range).
public struct PKCE: Equatable {
    public let verifier: String
    public let challenge: String
    public static let method = "S256"

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    public static func make(random: RandomBytesSource = SystemRandomBytes()) -> PKCE {
        PKCE(verifier: Base64URL.encode(random.bytes(count: 32)))
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(SHA256.hash(Data(verifier.utf8)))
    }
}

/// One sign-in attempt: what was sent to the browser and must come back.
public struct PendingSignIn: Equatable {
    public let url: URL
    public let state: String
    public let pkce: PKCE
}

public enum AuthProblem: Error, Equatable {
    case notConfigured
    case canceled
    case denied(String)
    case stateMismatch
    case badCallback
    case network
    case rejected(String)
    case badResponse
    case signedOut
    /// The Keychain did not hand out the stored login (거부, canceled, locked). The login is kept; asked again later.
    case secretsUnavailable

    public var koreanMessage: String {
        switch self {
        case .notConfigured: return "로그인 주소가 올바르지 않아요. 설정에서 확인해 주세요."
        case .canceled: return "로그인을 취소했어요."
        case .denied: return "로그인이 거절됐어요. 다시 시도해 주세요."
        case .stateMismatch, .badCallback: return "로그인 응답이 올바르지 않아 무시했어요. 다시 시도해 주세요."
        case .network: return "로그인 서버에 연결하지 못했어요. 네트워크를 확인해 주세요."
        case .rejected: return "로그인이 만료됐어요. 다시 로그인해 주세요."
        case .badResponse: return "로그인 서버 응답을 읽지 못했어요."
        case .signedOut: return "로그인이 필요해요."
        case .secretsUnavailable:
            return "키체인 접근이 거부돼 저장된 로그인을 읽지 못했어요. 나초를 다시 열면 키체인 창이 다시 떠요. '항상 허용'을 누르면 다음부터 묻지 않아요."
        }
    }
}

public enum OAuthRequests {
    public static func authorizationURL(_ config: OIDCConfig, pkce: PKCE, state: String) -> URL {
        var c = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: OIDCConfig.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: OIDCConfig.redirectURI),
            URLQueryItem(name: "scope", value: OIDCConfig.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
        ]
        // URLComponents leaves ':' and '/' of the redirect URI as they are; Keycloak compares the decoded value.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    public static func begin(_ config: OIDCConfig, random: RandomBytesSource = SystemRandomBytes()) -> PendingSignIn {
        let pkce = PKCE.make(random: random)
        let state = Base64URL.encode(random.bytes(count: 16))
        return PendingSignIn(url: authorizationURL(config, pkce: pkce, state: state), state: state, pkce: pkce)
    }

    /// Reads the browser's redirect. Only `nachogadget://auth/callback` with the expected `state` and a sane `code`
    /// passes; an `error` parameter (e.g. the user pressed cancel on the login page) is reported as such.
    public static func code(fromCallback url: URL, expectedState: String) -> Result<String, AuthProblem> {
        guard url.scheme?.lowercased() == OIDCConfig.callbackScheme, url.host?.lowercased() == "auth",
              url.path == "/callback", let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .failure(.badCallback) }
        let items = c.queryItems ?? []
        func value(_ name: String) -> String? {
            let v = items.filter { $0.name == name }
            return v.count == 1 ? v[0].value : nil  // duplicated parameters are refused
        }
        guard let state = value("state"), state == expectedState else { return .failure(.stateMismatch) }
        if let e = value("error") { return .failure(e == "access_denied" ? .canceled : .denied(e)) }
        guard let code = value("code"), !code.isEmpty, code.count <= 4096,
              code.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f })
        else { return .failure(.badCallback) }
        return .success(code)
    }

    public static func exchange(_ config: OIDCConfig, code: String, verifier: String) -> PetHTTPRequest {
        .postForm(config.tokenEndpoint, fields: [
            "grant_type": "authorization_code", "client_id": OIDCConfig.clientID, "code": code,
            "redirect_uri": OIDCConfig.redirectURI, "code_verifier": verifier,
        ])
    }

    public static func refresh(_ config: OIDCConfig, refreshToken: String) -> PetHTTPRequest {
        .postForm(config.tokenEndpoint, fields: [
            "grant_type": "refresh_token", "client_id": OIDCConfig.clientID, "refresh_token": refreshToken,
        ])
    }

    /// Keycloak ends the session (and invalidates the refresh token) on this call.
    public static func logout(_ config: OIDCConfig, refreshToken: String) -> PetHTTPRequest {
        .postForm(config.logoutEndpoint, fields: ["client_id": OIDCConfig.clientID, "refresh_token": refreshToken])
    }
}

/// Tokens of one signed-in account. Kept in the Keychain by the app; never logged.
public struct TokenSet: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date
    /// nil = the refresh token has no announced end (Keycloak `refresh_expires_in: 0`).
    public var refreshExpiresAt: Date?

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date, refreshExpiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt
    }

    /// Refreshed 60 s early so a WebSocket upgrade never starts with a token that dies on the way.
    public static let earlyRefresh: TimeInterval = 60

    public func accessIsFresh(now: Date) -> Bool { now.addingTimeInterval(TokenSet.earlyRefresh) < expiresAt }

    public func canRefresh(now: Date) -> Bool {
        guard refreshToken != nil else { return false }
        if let end = refreshExpiresAt { return now < end }
        return true
    }

    /// Token endpoint answer. Missing `expires_in` counts as 5 minutes; values are clamped to 10 s ... 1 day.
    public static func decode(_ data: Data, now: Date) -> Result<TokenSet, AuthProblem> {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else {
            return .failure(.badResponse)
        }
        if let e = o["error"] as? String { return .failure(.rejected(e)) }
        guard let access = o["access_token"] as? String, !access.isEmpty, access.count <= 16_384,
              !access.contains(" "), !access.contains("\n")
        else { return .failure(.badResponse) }
        if let type = o["token_type"] as? String, type.lowercased() != "bearer" { return .failure(.badResponse) }
        func seconds(_ key: String) -> Double? {
            if let n = o[key] as? Int { return Double(n) }
            if let n = o[key] as? Double { return n }
            return nil
        }
        let expiresIn = min(86_400, max(10, seconds("expires_in") ?? 300))
        let refresh = (o["refresh_token"] as? String).flatMap { $0.isEmpty || $0.count > 16_384 ? nil : $0 }
        var refreshEnd: Date?
        if let r = seconds("refresh_expires_in"), r > 0 { refreshEnd = now.addingTimeInterval(min(r, 400 * 86_400)) }
        return .success(TokenSet(accessToken: access, refreshToken: refresh, idToken: o["id_token"] as? String,
                                 expiresAt: now.addingTimeInterval(expiresIn), refreshExpiresAt: refreshEnd))
    }
}

/// Opens the login page and returns the redirect URL (the app: ASWebAuthenticationSession; the CLI: plain HTTP
/// against the mock server's stand-in login page).
public protocol PetAuthBrowser: AnyObject {
    func authorize(url: URL, callbackScheme: String, completion: @escaping (Result<URL, AuthProblem>) -> Void)
}

/// Token lifecycle for one account scope (server + realm). Thread-safe: everything runs on `queue`.
public final class PetAuth {
    public let config: OIDCConfig?
    private let scope: String
    private let http: PetHTTPClient
    private let secrets: PetSecretStore
    private let random: RandomBytesSource
    private let now: () -> Date
    private let queue = DispatchQueue(label: "nacho.combo.pet.auth")
    private var tokens: TokenSet?
    /// Set while the secret store refused to hand out the stored login (Keychain 거부, canceled, locked).
    private var storeProblem: Int32?
    private var refreshWaiters: [(Result<String, AuthProblem>) -> Void] = []

    public init(config: OIDCConfig?, scope: String, http: PetHTTPClient, secrets: PetSecretStore,
                random: RandomBytesSource = SystemRandomBytes(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.scope = scope
        self.http = http
        self.secrets = secrets
        self.random = random
        self.now = now
        loadStoredLocked()
    }

    /// Reads the stored login. A refused or canceled Keychain prompt (or a locked Keychain) is remembered as
    /// `storeProblem`, not as "signed out": the stored tokens stay where they are and are asked for again later.
    private func loadStoredLocked() {
        switch secrets.lookup(PetAuth.key(scope)) {
        case let .found(data):
            tokens = try? JSONDecoder().decode(TokenSet.self, from: data)
            storeProblem = nil
        case .missing:
            storeProblem = nil
        case let .unavailable(status):
            storeProblem = status
        }
    }

    static func key(_ scope: String) -> String { "tokens|" + scope }

    public var isSignedIn: Bool { queue.sync { tokens != nil } }

    /// No login in memory because the Keychain refused to hand out the stored one (not "signed out").
    public var secretsUnavailable: Bool { queue.sync { tokens == nil && storeProblem != nil } }

    /// After a refused read: asks the secret store again (the Keychain shows its prompt again). True when signed in.
    @discardableResult
    public func retryStoredTokens() -> Bool {
        queue.sync {
            if tokens == nil, storeProblem != nil { loadStoredLocked() }
            return tokens != nil
        }
    }

    /// Current access token without any network call (may be stale; the server answers 401 then).
    public var currentAccessToken: String? { queue.sync { tokens?.accessToken } }

    public func begin() -> Result<PendingSignIn, AuthProblem> {
        guard let c = config else { return .failure(.notConfigured) }
        return .success(OAuthRequests.begin(c, random: random))
    }

    public func complete(callback: URL, pending: PendingSignIn, completion: @escaping (Result<Void, AuthProblem>) -> Void) {
        guard let c = config else { completion(.failure(.notConfigured)); return }
        switch OAuthRequests.code(fromCallback: callback, expectedState: pending.state) {
        case let .failure(p): completion(.failure(p))
        case let .success(code):
            http.send(OAuthRequests.exchange(c, code: code, verifier: pending.pkce.verifier)) { [weak self] result in
                guard let self = self else { return }
                self.queue.async { completion(self.store(result)) }
            }
        }
    }

    /// A usable access token: the stored one while fresh, otherwise one refresh (concurrent callers share it).
    public func validAccessToken(completion: @escaping (Result<String, AuthProblem>) -> Void) {
        queue.async {
            guard let t = self.tokens else {
                completion(.failure(self.storeProblem != nil ? .secretsUnavailable : .signedOut))
                return
            }
            if t.accessIsFresh(now: self.now()) { completion(.success(t.accessToken)); return }
            self.refreshLocked(completion)
        }
    }

    /// Forces a refresh (the server said 401 although the token looked fresh).
    public func forceRefresh(completion: @escaping (Result<String, AuthProblem>) -> Void) {
        queue.async {
            guard self.tokens != nil else {
                completion(.failure(self.storeProblem != nil ? .secretsUnavailable : .signedOut))
                return
            }
            self.refreshLocked(completion)
        }
    }

    private func refreshLocked(_ completion: @escaping (Result<String, AuthProblem>) -> Void) {
        guard let c = config, let t = tokens, t.canRefresh(now: now()), let rt = t.refreshToken else {
            clearLocked()
            completion(.failure(.rejected("no_refresh")))
            return
        }
        refreshWaiters.append(completion)
        guard refreshWaiters.count == 1 else { return }
        http.send(OAuthRequests.refresh(c, refreshToken: rt)) { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                let r: Result<String, AuthProblem>
                switch self.store(result) {
                case .success: r = .success(self.tokens?.accessToken ?? "")
                case let .failure(p):
                    if case .rejected = p { self.clearLocked() }  // refresh token dead: back to signed out
                    r = .failure(p)
                }
                let waiters = self.refreshWaiters
                self.refreshWaiters = []
                waiters.forEach { $0(r) }
            }
        }
    }

    private func store(_ result: Result<PetHTTPResponse, Error>) -> Result<Void, AuthProblem> {
        switch result {
        case .failure: return .failure(.network)
        case let .success(resp):
            if resp.status >= 500 || resp.status == 0 { return .failure(.network) }
            let decoded = TokenSet.decode(resp.body, now: now())
            guard (200..<300).contains(resp.status) else {
                if case let .failure(.rejected(code)) = decoded { return .failure(.rejected(code)) }
                return .failure(.rejected("http_\(resp.status)"))
            }
            switch decoded {
            case let .failure(p): return .failure(p)
            case let .success(t):
                var t = t
                if t.refreshToken == nil { t.refreshToken = tokens?.refreshToken }  // Keycloak may omit it on refresh
                tokens = t
                // A store that refuses keeps these in memory only (never written over what it holds); asked again next time.
                if let data = try? JSONEncoder().encode(t) {
                    do { try secrets.write(PetAuth.key(scope), data); storeProblem = nil } catch {}
                }
                return .success(())
            }
        }
    }

    /// Ends the Keycloak session (best effort) and forgets the tokens here at once.
    public func signOut(completion: @escaping () -> Void = {}) {
        queue.async {
            let rt = self.tokens?.refreshToken
            self.clearLocked()
            guard let c = self.config, let r = rt else { completion(); return }
            self.http.send(OAuthRequests.logout(c, refreshToken: r)) { _ in completion() }
        }
    }

    private func clearLocked() {
        tokens = nil
        secrets.delete(PetAuth.key(scope))
    }
}
