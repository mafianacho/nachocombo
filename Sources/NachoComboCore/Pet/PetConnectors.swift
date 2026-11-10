import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).
// REST read models for the connector/tool screen. Contracts: nacho-server spec connections.tsp (GET /api/v1/connections)
// and tools.tsp (GET /api/v1/tools). Decoded tolerantly: unknown fields are ignored, missing optional fields are nil.

public struct ConnectionRow: Equatable, Identifiable {
    public var id: String  // connection id (uuid)
    public var source: String
    public var label: String
    public var status: String  // connected | needs_reauth | disconnected | error | <unknown>
    public var needsAttention: String?
    public var accountLabel: String?
    public var scopeSummary: String
    public var link: URL?  // optional server-provided management link (http/https only)

    public var statusText: String {
        if let a = needsAttention {
            switch a {
            case "needs_reauth": return "다시 로그인이 필요해요"
            case "degraded": return "일부 기능이 불안정해요"
            case "expiring": return "곧 만료돼요"
            default: break
            }
        }
        switch status {
        case "connected": return "연결됨"
        case "needs_reauth": return "다시 로그인이 필요해요"
        case "disconnected": return "연결 끊김"
        case "error": return "오류"
        default: return "알 수 없음"
        }
    }
    public var isHealthy: Bool { status == "connected" && needsAttention == nil }
}

public struct ToolRow: Equatable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var kind: String  // builtin | http | mcp | connector | connection
    public var source: String?
    public var enabled: Bool

    public var kindText: String {
        switch kind {
        case "builtin": return "기본"
        case "http": return "HTTP"
        case "mcp": return "MCP"
        case "connector": return "커넥터"
        case "connection": return "서비스 연결"
        default: return kind
        }
    }
}

public struct CapabilityRow: Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
}

public struct ConnectorOverview: Equatable {
    public var connections: [ConnectionRow] = []
    public var tools: [ToolRow] = []
    public var capabilities: [CapabilityRow] = []
    public init() {}
}

public enum SafeLink {
    /// Only http(s) links with a host may be opened in the browser (no file:, javascript:, custom schemes).
    public static func openable(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 2000,
            let c = URLComponents(string: raw), let s = c.scheme?.lowercased(),
            s == "https" || s == "http", let h = c.host, !h.isEmpty, c.user == nil, c.password == nil,
            let url = c.url
        else { return nil }
        if s == "http" && !ServerEndpoint.isLoopback(h) { return nil }
        return url
    }
}

public enum ConnectorDecoder {
    public static func connections(_ data: Data) -> [ConnectionRow]? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let arr = any as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let source = o["source"] as? String else { return nil }
            return ConnectionRow(
                id: (o["id"] as? String) ?? source, source: source,
                label: (o["label"] as? String) ?? source,
                status: (o["status"] as? String) ?? "unknown",
                needsAttention: o["needs_attention"] as? String,
                accountLabel: o["account_label"] as? String,
                scopeSummary: (o["scope_summary"] as? String) ?? "",
                link: SafeLink.openable((o["link"] as? String) ?? (o["manage_url"] as? String)))
        }
    }

    public static func tools(_ data: Data) -> (tools: [ToolRow], capabilities: [CapabilityRow])? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else { return nil }
        let tools: [ToolRow] = ((o["tools"] as? [[String: Any]]) ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let cfg = t["config"] as? [String: Any]
            return ToolRow(
                id: (t["id"] as? String) ?? name, name: name,
                description: (t["search_description"] as? String) ?? (t["operation_description"] as? String) ?? "",
                kind: (cfg?["kind"] as? String) ?? "builtin", source: t["source"] as? String,
                enabled: (t["enabled"] as? Bool) ?? true)
        }
        let caps: [CapabilityRow] = ((o["connector_capabilities"] as? [[String: Any]]) ?? []).compactMap { c in
            guard let n = c["name"] as? String else { return nil }
            return CapabilityRow(name: n, description: (c["description"] as? String) ?? "")
        }
        return (tools, caps)
    }
}

public enum ConnectorError: Error, Equatable {
    case unauthorized, server(Int), network(String), badResponse

    public var koreanMessage: String {
        switch self {
        case .unauthorized: return "로그인이 필요해요."
        case let .server(code): return "서버가 오류를 돌려줬어요. (HTTP \(code))"
        case .network: return "서버에 연결하지 못했어요. 서버 주소를 확인해 주세요."
        case .badResponse: return "서버 응답을 읽지 못했어요."
        }
    }
}

/// Reads connections + tools. Both calls must succeed; a partial list would hide a broken connection.
public final class ConnectorsAPI {
    private let endpoint: ServerEndpoint
    private let fetcher: PetHTTPClient
    private let token: () -> String?

    public init(endpoint: ServerEndpoint, fetcher: PetHTTPClient = URLSessionPetHTTP(timeout: 15), token: @escaping () -> String?) {
        self.endpoint = endpoint
        self.fetcher = fetcher
        self.token = token
    }

    public func load(completion: @escaping (Result<ConnectorOverview, ConnectorError>) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var conn: Result<[ConnectionRow], ConnectorError>?
        var tools: Result<(tools: [ToolRow], capabilities: [CapabilityRow]), ConnectorError>?

        func run<T>(_ path: String, decode: @escaping (Data) -> T?, store: @escaping (Result<T, ConnectorError>) -> Void) {
            group.enter()
            fetcher.send(.get(endpoint.rest(path), bearer: token())) { result in
                let r: Result<T, ConnectorError>
                switch result {
                case let .failure(e): r = .failure(.network(e.localizedDescription))
                case let .success(resp):
                    let code = resp.status, data = resp.body
                    if code == 401 || code == 403 {
                        r = .failure(.unauthorized)
                    } else if !(200..<300).contains(code) {
                        r = .failure(.server(code))
                    } else if let v = decode(data) {
                        r = .success(v)
                    } else {
                        r = .failure(.badResponse)
                    }
                }
                lock.lock(); store(r); lock.unlock()
                group.leave()
            }
        }
        run("/api/v1/connections", decode: ConnectorDecoder.connections) { conn = $0 }
        run("/api/v1/tools", decode: ConnectorDecoder.tools) { tools = $0 }
        group.notify(queue: .global()) {
            switch (conn, tools) {
            case let (.success(c)?, .success(t)?):
                var o = ConnectorOverview()
                o.connections = c
                o.tools = t.tools
                o.capabilities = t.capabilities
                completion(.success(o))
            case let (.failure(e)?, _): completion(.failure(e))
            case let (_, .failure(e)?): completion(.failure(e))
            default: completion(.failure(.badResponse))
            }
        }
    }
}
