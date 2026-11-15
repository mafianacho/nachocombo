import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 「연결」 탭이 서버에 거는 호출 (NACHO-239). Contracts: nacho-server spec connections.tsp / tools.tsp.
//   PUT    /api/v1/tools/{id}/switch              {enabled}                 → 갱신된 도구, locked면 409 reason tool_locked (NACHO-132)
//   PATCH  /api/v1/connections/{id}               {enabled, expected_version}  서비스 켜기/끄기
//   PATCH  /api/v1/connections/{id}/scope         {level, expected_version}    권한 범위
//   DELETE /api/v1/connections/{id}                                            연결 해제
//   GET    /api/v1/connections/catalog?q=         카탈로그 검색
//   GET    /api/v1/connections/{source}           서비스 상세
//   POST   /api/v1/connections/begin              연동 시작 (Idempotency-Key)
//   GET    /api/v1/connections/attempts/{id}      시도 상태 (completion)
//   DELETE /api/v1/connections/attempts/{id}      시도 취소
//   POST   /api/v1/connections/attempts/{id}/app-password   {email, app_password}
// Request builders are pure (tested for their bytes). An app password is only in the body of that one request:
// never in a log, an error text or a returned value.

public enum ConnectionsFailure: Error, Equatable {
    case unauthorized
    /// 409 `tool_locked`.
    case locked
    /// 404 / 405 / 501: this server does not have the call yet (an older nacho-server).
    case notAvailable
    case notFound
    /// 409 `needs_reconsent`: a wider scope needs the provider's consent again.
    case needsReconsent
    /// 409 / 400 with a code (the code only, never a body).
    case conflict(String?)
    case server(Int)
    case network
    case badResponse

    public var koreanMessage: String {
        switch self {
        case .unauthorized: return "로그인이 필요해요."
        case .locked: return "나초가 대화하는 데 꼭 필요한 도구라서 끌 수 없어요."
        case .notAvailable: return "이 서버는 아직 이 기능을 지원하지 않아요. 서버가 업데이트되면 쓸 수 있어요."
        case .notFound: return "대상을 찾지 못했어요. 목록을 새로 불러와 주세요."
        case .needsReconsent: return "더 넓은 권한은 서비스에서 다시 동의해야 해요. 연결을 다시 해 주세요."
        case let .conflict(code):
            switch code {
            case "authentication_failed"?: return "로그인에 실패했어요. 입력한 내용을 확인해 주세요."
            case "attempt_expired"?: return "시간이 지났어요. 처음부터 다시 연결해 주세요."
            case "support_status"?: return "지금은 이 서비스를 연결할 수 없어요."
            case "version_conflict"?, "stale_version"?: return "다른 곳에서 먼저 바뀌었어요. 목록을 새로 불러왔어요."
            default: return "지금은 바꿀 수 없어요. 잠시 뒤 다시 시도해 주세요."
            }
        case let .server(code): return "서버가 오류를 돌려줬어요. (HTTP \(code))"
        case .network: return "서버에 연결하지 못했어요. 네트워크를 확인해 주세요."
        case .badResponse: return "서버 응답을 읽지 못했어요."
        }
    }

    static func from(_ resp: PetHTTPResponse) -> ConnectionsFailure {
        let reason = ConnectionsAPI.errorReason(resp.body)
        let code = PetServerError.code(resp.body)
        switch resp.status {
        case 401, 403: return .unauthorized
        // 404 with a server error body: the item is gone. 404 without one (no such route), 405, 501: an older server.
        case 404: return code != nil ? .notFound : .notAvailable
        case 405, 501: return .notAvailable
        case 409:
            if reason == "tool_locked" { return .locked }
            if code == "needs_reconsent" || reason == "needs_reconsent" { return .needsReconsent }
            return .conflict(reason ?? code)
        case 400: return .conflict(reason ?? code)
        case 502: return .conflict(reason ?? code ?? "transport")
        default: return .server(resp.status)
        }
    }
}

public struct CatalogRow: Equatable, Identifiable {
    public var id: String { source }
    public var source: String
    public var label: String
    public var summary: String
    public var connectKind: String
    public var supportStatus: String
    public var supportReason: String?
    public var connected: Bool

    public var plan: MacConnectPlan { MacConnectPlan.plan(connectKind: connectKind, supportStatus: supportStatus, supportReason: supportReason) }
}

public struct BeginInfo: Equatable {
    public var attemptID: String
    public var connectKind: String
    /// OAuth consent page; http(s) only (`SafeLink`).
    public var authorizeURL: URL?
    /// oauth | app_password | qr | device | site
    public var next: String
}

public struct AttemptInfo: Equatable {
    public var attemptID: String
    public var source: String
    public var state: String
    public var failure: String?
    public var connectionID: String?

    public var isTerminal: Bool { ["completed", "failed", "canceled", "expired"].contains(state) }
}

public final class ConnectionsAPI {
    private let endpoint: ServerEndpoint
    private let fetcher: PetHTTPClient
    private let token: () -> String?

    public init(endpoint: ServerEndpoint, fetcher: PetHTTPClient = URLSessionPetHTTP(timeout: 20), token: @escaping () -> String?) {
        self.endpoint = endpoint
        self.fetcher = fetcher
        self.token = token
    }

    // MARK: requests

    private func json(_ method: String, _ path: String, _ body: [String: Any], extra: [String: String] = [:]) -> PetHTTPRequest {
        var h = ["Accept": "application/json", "Content-Type": "application/json"]
        if let b = token(), !b.isEmpty { h["Authorization"] = "Bearer " + b }
        for (k, v) in extra { h[k] = v }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return PetHTTPRequest(method: method, url: endpoint.rest(path), headers: h, body: data)
    }

    private func plain(_ method: String, _ path: String, query: [(String, String)] = []) -> PetHTTPRequest {
        var h = ["Accept": "application/json"]
        if let b = token(), !b.isEmpty { h["Authorization"] = "Bearer " + b }
        return PetHTTPRequest(method: method, url: PetServerAPI.url(endpoint, path, query: query), headers: h)
    }

    /// Path segment from a server id: ids are uuids or sources (`naver_mail`, `custom:12`); anything else is refused.
    func segment(_ id: String) -> String? {
        guard !id.isEmpty, id.count <= 80,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == ":" || $0 == "." })
        else { return nil }
        return id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? id
    }

    static func errorReason(_ data: Data) -> String? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
              let e = o["error"] as? [String: Any] else { return nil }
        return e["reason"] as? String
    }

    public func toolSwitchRequest(id: String, enabled: Bool) -> PetHTTPRequest? {
        segment(id).map { json("PUT", "/api/v1/tools/\($0)/switch", ["enabled": enabled]) }
    }

    public func connectionSwitchRequest(id: String, enabled: Bool, version: Int) -> PetHTTPRequest? {
        segment(id).map { json("PATCH", "/api/v1/connections/\($0)", ["enabled": enabled, "expected_version": version]) }
    }

    public func scopeRequest(id: String, level: String, version: Int) -> PetHTTPRequest? {
        segment(id).map { json("PATCH", "/api/v1/connections/\($0)/scope", ["level": level, "expected_version": version]) }
    }

    public func disconnectRequest(id: String) -> PetHTTPRequest? { segment(id).map { plain("DELETE", "/api/v1/connections/\($0)") } }

    public func catalogRequest(query: String) -> PetHTTPRequest {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return plain("GET", "/api/v1/connections/catalog", query: q.isEmpty ? [] : [("q", String(q.prefix(80)))])
    }

    public func detailRequest(source: String) -> PetHTTPRequest? { segment(source).map { plain("GET", "/api/v1/connections/\($0)") } }

    public func beginRequest(source: String, idempotencyKey: String = UUID().uuidString) -> PetHTTPRequest {
        json("POST", "/api/v1/connections/begin", ["source": source], extra: ["Idempotency-Key": idempotencyKey])
    }

    public func attemptRequest(id: String) -> PetHTTPRequest? { segment(id).map { plain("GET", "/api/v1/connections/attempts/\($0)") } }

    public func cancelAttemptRequest(id: String) -> PetHTTPRequest? { segment(id).map { plain("DELETE", "/api/v1/connections/attempts/\($0)") } }

    public func appPasswordRequest(attemptID: String, email: String, password: String) -> PetHTTPRequest? {
        segment(attemptID).map { json("POST", "/api/v1/connections/attempts/\($0)/app-password", ["email": email, "app_password": password]) }
    }

    // MARK: calls

    private func run<T>(_ request: PetHTTPRequest?, decode: @escaping (Data) -> T?, done: @escaping (Result<T, ConnectionsFailure>) -> Void) {
        guard let request = request else { done(.failure(.notFound)); return }
        fetcher.send(request) { result in
            switch result {
            case .failure: done(.failure(.network))
            case let .success(resp):
                guard (200..<300).contains(resp.status) else { done(.failure(ConnectionsFailure.from(resp))); return }
                if let v = decode(resp.body) { done(.success(v)) } else { done(.failure(.badResponse)) }
            }
        }
    }

    /// Answers from the server, or a failure; the updated row comes back (a server without `user_enabled` answers the
    /// row without it: the app then does not know the switch took, so it reads the list again).
    public func setToolEnabled(id: String, enabled: Bool, done: @escaping (Result<ToolRow, ConnectionsFailure>) -> Void) {
        run(toolSwitchRequest(id: id, enabled: enabled), decode: { (data: Data) -> ToolRow? in
            guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
                  let wrapped = try? JSONSerialization.data(withJSONObject: ["tools": [o]]) else { return nil }
            return ConnectorDecoder.tools(wrapped)?.tools.first
        }, done: { (r: Result<ToolRow, ConnectionsFailure>) in
            if case let .success(row) = r, !ConnectionsAPI.answerCarriesSwitch(row, enabled: enabled) { done(.failure(.notAvailable)); return }
            done(r)
        })
    }

    /// The answer must show the switch the user asked for. A server that ignores the call (no `user_enabled` yet) would
    /// answer a row that looks on: that counts as not available, never as a switch that took.
    static func answerCarriesSwitch(_ row: ToolRow, enabled: Bool) -> Bool { row.userEnabled == enabled }

    public func setConnectionEnabled(id: String, enabled: Bool, version: Int, done: @escaping (Result<Void, ConnectionsFailure>) -> Void) {
        run(connectionSwitchRequest(id: id, enabled: enabled, version: version), decode: { _ in () }, done: done)
    }

    public func setScopeLevel(id: String, level: String, version: Int, done: @escaping (Result<Void, ConnectionsFailure>) -> Void) {
        run(scopeRequest(id: id, level: level, version: version), decode: { _ in () }, done: done)
    }

    public func disconnect(id: String, done: @escaping (Result<Void, ConnectionsFailure>) -> Void) {
        run(disconnectRequest(id: id), decode: { _ in () }, done: done)
    }

    public func catalog(query: String, done: @escaping (Result<[CatalogRow], ConnectionsFailure>) -> Void) {
        run(catalogRequest(query: query), decode: ConnectionsAPI.decodeCatalog, done: done)
    }

    public func detail(source: String, done: @escaping (Result<ConnectionDetailInfo, ConnectionsFailure>) -> Void) {
        run(detailRequest(source: source), decode: ConnectionDetailInfo.decode, done: done)
    }

    public func begin(source: String, done: @escaping (Result<BeginInfo, ConnectionsFailure>) -> Void) {
        run(beginRequest(source: source), decode: ConnectionsAPI.decodeBegin, done: done)
    }

    public func attempt(id: String, done: @escaping (Result<AttemptInfo, ConnectionsFailure>) -> Void) {
        run(attemptRequest(id: id), decode: ConnectionsAPI.decodeAttempt, done: done)
    }

    public func cancelAttempt(id: String, done: @escaping (Result<Void, ConnectionsFailure>) -> Void) {
        run(cancelAttemptRequest(id: id), decode: { _ in () }, done: done)
    }

    public func submitAppPassword(attemptID: String, email: String, password: String, done: @escaping (Result<Void, ConnectionsFailure>) -> Void) {
        run(appPasswordRequest(attemptID: attemptID, email: email, password: password), decode: { _ in () }, done: done)
    }

    // MARK: decoding

    static func decodeCatalog(_ data: Data) -> [CatalogRow]? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else { return nil }
        let items = (o["items"] as? [[String: Any]]) ?? []
        return items.compactMap { i in
            guard let source = i["source"] as? String else { return nil }
            return CatalogRow(source: source, label: (i["label"] as? String) ?? source, summary: (i["summary"] as? String) ?? "",
                              connectKind: (i["connect_kind"] as? String) ?? "unknown",
                              supportStatus: (i["support_status"] as? String) ?? "unverified",
                              supportReason: i["support_reason"] as? String, connected: (i["connected"] as? Bool) ?? false)
        }
    }

    static func decodeBegin(_ data: Data) -> BeginInfo? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
              let id = o["attempt_id"] as? String else { return nil }
        return BeginInfo(attemptID: id, connectKind: (o["connect_kind"] as? String) ?? "unknown",
                         authorizeURL: SafeLink.openable(o["authorize_url"] as? String), next: (o["next"] as? String) ?? "")
    }

    static func decodeAttempt(_ data: Data) -> AttemptInfo? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
              let id = o["attempt_id"] as? String, let state = o["state"] as? String else { return nil }
        return AttemptInfo(attemptID: id, source: (o["source"] as? String) ?? "", state: state, failure: o["failure"] as? String,
                           connectionID: (o["connection"] as? [String: Any])?["id"] as? String)
    }
}
