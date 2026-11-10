import Foundation

// Nacho Pet settings. Server URL validation is ported from nacho-gadget-app Core (PR #1 @1d685fa); the modes and the
// login (issuer) part are new for Nacho Combo.

/// Which nacho-server (and Keycloak realm) the pet talks to.
public enum PetServerMode: String, Codable, CaseIterable, Equatable {
    /// The production server and realm (default).
    case production
    /// A nacho-server running on this Mac (`config/default.toml`: 127.0.0.1:8787, Keycloak on localhost:18180).
    case local
    /// `tools/mock-server` (dev/test only): chat, uploads, connector and a stand-in Keycloak on one port.
    case mock
    /// Typed in by the user (validated).
    case custom

    public var displayName: String {
        switch self {
        case .production: return "Nacho (nacho.nachotown.com)"
        case .local: return "Local nacho-server"
        case .mock: return "Mock server (development)"
        case .custom: return "Custom"
        }
    }
}

public struct PetPosition: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PetSettings: Codable, Equatable {
    public var serverMode: PetServerMode = .production
    public var customServerURL: String = ""
    public var customIssuerURL: String = ""
    /// Where the user dragged the pet (bottom-left corner of its window, screen coordinates). nil = bottom right.
    public var petPosition: PetPosition?
    /// Nacho may arrange windows and switch gadgets on or off when asked in the chat (connector tools).
    public var allowComboControl: Bool = true

    public static let productionServerURL = "https://nacho.nachotown.com"
    public static let productionIssuerURL = "https://auth.nachotown.com/realms/nachotown"
    public static let localServerURL = "http://127.0.0.1:8787"
    public static let localIssuerURL = "http://localhost:18180/realms/nachotown"
    public static let mockServerURL = "http://127.0.0.1:8787"
    public static let mockIssuerURL = "http://127.0.0.1:8787/realms/nachotown"

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case serverMode, customServerURL, customIssuerURL, petPosition, allowComboControl
    }

    /// Every field falls back on its own, so a file from an older or newer version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverMode = (try? c.decodeIfPresent(PetServerMode.self, forKey: .serverMode)) ?? .production
        customServerURL = (try? c.decodeIfPresent(String.self, forKey: .customServerURL)) ?? ""
        customIssuerURL = (try? c.decodeIfPresent(String.self, forKey: .customIssuerURL)) ?? ""
        petPosition = try? c.decodeIfPresent(PetPosition.self, forKey: .petPosition)
        allowComboControl = (try? c.decodeIfPresent(Bool.self, forKey: .allowComboControl)) ?? true
    }

    /// Resolved server for the current mode, or nil when the custom URL is empty/invalid.
    public var endpoint: ServerEndpoint? {
        switch serverMode {
        case .production: return try? ServerEndpoint.parse(PetSettings.productionServerURL).get()
        case .local: return try? ServerEndpoint.parse(PetSettings.localServerURL).get()
        case .mock: return try? ServerEndpoint.parse(PetSettings.mockServerURL).get()
        case .custom: return try? ServerEndpoint.parse(customServerURL).get()
        }
    }

    /// Resolved login configuration for the current mode, or nil when the custom issuer is empty/invalid.
    public var oidc: OIDCConfig? {
        let raw: String
        switch serverMode {
        case .production: raw = PetSettings.productionIssuerURL
        case .local: raw = PetSettings.localIssuerURL
        case .mock: raw = PetSettings.mockIssuerURL
        case .custom: raw = customIssuerURL
        }
        guard case let .success(issuer) = IssuerURL.parse(raw) else { return nil }
        return OIDCConfig(issuer: issuer)
    }

    /// Checks what the user typed. Returns the first problem, or nil when the settings can be saved.
    public func validationProblem() -> String? {
        guard serverMode == .custom else { return nil }
        if case let .failure(e) = ServerEndpoint.parse(customServerURL) { return "서버 주소: " + e.koreanMessage }
        if case let .failure(e) = IssuerURL.parse(customIssuerURL) { return "로그인 주소: " + e.koreanMessage }
        return nil
    }

    /// A key that changes when the account world changes (other server or realm): tokens of one must not be used on
    /// another, so the token store is keyed by it.
    public var accountScope: String {
        "\(endpoint?.base.absoluteString ?? "-")|\(oidc?.issuer.absoluteString ?? "-")"
    }
}

public enum ServerURLError: Error, Equatable {
    case empty, tooLong, invalidScheme, noHost, hasCredentials, hasQueryOrFragment, plainHTTPNotLoopback, badPath

    public var koreanMessage: String {
        switch self {
        case .empty: return "주소를 입력해 주세요. 예: https://example.com"
        case .tooLong: return "주소가 너무 길어요. (최대 200자)"
        case .invalidScheme: return "주소는 http:// 또는 https:// 로 시작해야 해요."
        case .noHost: return "주소에 서버 이름이 없어요. 예: https://example.com"
        case .hasCredentials: return "주소에 아이디/비밀번호를 넣을 수 없어요."
        case .hasQueryOrFragment: return "주소 끝에 ? 나 # 를 붙일 수 없어요."
        case .plainHTTPNotLoopback: return "이 컴퓨터(127.0.0.1, localhost) 밖의 서버는 https:// 만 쓸 수 있어요."
        case .badPath: return "로그인 주소는 https://<서버>/realms/<이름> 모양이어야 해요."
        }
    }
}

/// Validated server base URL. Credentials, query and fragments are rejected; plain http is allowed only for loopback.
public struct ServerEndpoint: Equatable {
    public let base: URL  // http(s)://host[:port] without trailing slash
    public init(base: URL) { self.base = base }

    public var webSocketURL: URL { webSocket("/ws/chat") }
    public var connectorURL: URL { webSocket("/ws/connector") }

    private func webSocket(_ path: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.scheme = base.scheme == "https" ? "wss" : "ws"
        c.path = path
        return c.url!
    }

    public func rest(_ path: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        c.path = path
        return c.url!
    }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
    }

    public static func parse(_ raw: String) -> Result<ServerEndpoint, ServerURLError> {
        switch URLCheck.components(raw) {
        case let .failure(e): return .failure(e)
        case let .success(c):
            var b = URLComponents()
            b.scheme = c.scheme
            b.host = c.host
            b.port = c.port
            guard let url = b.url else { return .failure(.noHost) }
            return .success(ServerEndpoint(base: url))
        }
    }
}

/// Keycloak realm issuer, e.g. `https://auth.nachotown.com/realms/nachotown`.
public enum IssuerURL {
    public static func parse(_ raw: String) -> Result<URL, ServerURLError> {
        switch URLCheck.components(raw) {
        case let .failure(e): return .failure(e)
        case var .success(c):
            var path = c.path
            while path.hasSuffix("/") { path.removeLast() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // "", "realms", "<name>" — or a reverse-proxy prefix in front ("", "auth", "realms", "<name>").
            guard parts.count >= 3, parts.count <= 5, parts[0].isEmpty, parts[parts.count - 2] == "realms",
                  parts.dropFirst().allSatisfy({ URLCheck.isPathSegment($0) })
            else { return .failure(.badPath) }
            c.path = path
            guard let url = c.url else { return .failure(.badPath) }
            return .success(url)
        }
    }
}

enum URLCheck {
    static func components(_ raw: String) -> Result<URLComponents, ServerURLError> {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .failure(.empty) }
        if s.count > 200 { return .failure(.tooLong) }
        guard var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return .failure(.invalidScheme) }
        guard let host = c.host, !host.isEmpty else { return .failure(.noHost) }
        if c.user != nil || c.password != nil { return .failure(.hasCredentials) }
        if c.query != nil || c.fragment != nil { return .failure(.hasQueryOrFragment) }
        if scheme == "http" && !ServerEndpoint.isLoopback(host) { return .failure(.plainHTTPNotLoopback) }
        if let p = c.port, !(1...65535).contains(p) { return .failure(.noHost) }
        c.scheme = scheme
        c.host = host.lowercased()
        return .success(c)
    }

    static func isPathSegment(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64, s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "-_.".unicodeScalars.contains($0) }
    }
}

public protocol PetSettingsStoring {
    func load() -> PetSettings
    func save(_ s: PetSettings) throws
}

/// JSON file store (`~/Library/Application Support/NachoCombo/pet.json`). A corrupt file is moved aside
/// (`pet.json.corrupt`) and defaults are returned. Values read from disk are re-validated.
public final class PetSettingsStore: PetSettingsStoring {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static func defaultURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("NachoCombo", isDirectory: true).appendingPathComponent("pet.json")
    }

    public func load() -> PetSettings {
        guard let data = try? Data(contentsOf: url) else { return PetSettings() }
        if let s = try? JSONDecoder().decode(PetSettings.self, from: data) {
            return PetSettingsStore.sanitized(s)
        }
        let aside = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return PetSettings()
    }

    public func save(_ s: PetSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(s).write(to: url, options: .atomic)
    }

    /// A hand-edited file must not smuggle in a bad URL or a position that is not a number.
    public static func sanitized(_ s: PetSettings) -> PetSettings {
        var out = s
        if out.serverMode == .custom && out.validationProblem() != nil {
            out.serverMode = .production
            out.customServerURL = ""
            out.customIssuerURL = ""
        }
        if let p = out.petPosition, !(p.x.isFinite && p.y.isFinite) || abs(p.x) > 100_000 || abs(p.y) > 100_000 {
            out.petPosition = nil
        }
        return out
    }
}
