import Foundation

// 나초 앱 창(허브)의 공용 API. 기존 PetHTTPRequest/PetHTTPClient/ServerEndpoint/PetAPIError를 그대로 쓰고
// 새 네트워크 층은 만들지 않는다. 요청 만들기는 순수 함수라 시험이 바이트를 그대로 확인한다.
//   GET: 쿼리 · POST/PATCH/PUT/DELETE: JSON 본문(키 정렬, DELETE는 줄 것이 있을 때만) · `Idempotency-Key` 헤더
//   `expected_version`은 언제나 본문(nacho-server spec `ExpectedVersion`·`DeletePolicies`처럼 본문으로 받는다)
// 오류 본문 {"error":{code,message,reason}} → 한국어(ErrorText). 401은 토큰을 새로 받아 한 번만 다시 보낸다.

/// 서버 JSON 객체를 앱 모듈에서도 읽도록 감싼 값(`JSONObject`는 Core 안에서만 보인다).
public struct HubObject {
    public let raw: [String: Any]
    public init(_ raw: [String: Any]) { self.raw = raw }
    public func str(_ k: String) -> String? { raw[k] as? String }
    public func int(_ k: String) -> Int? { raw.int(k) }
    public func bool(_ k: String) -> Bool? { raw[k] as? Bool }
    public func obj(_ k: String) -> HubObject? { raw.obj(k).map(HubObject.init) }
    public func objs(_ k: String) -> [HubObject] { raw.objs(k).map(HubObject.init) }
    public func strs(_ k: String) -> [String] { raw.strs(k) }
}

/// 커서 목록 한 쪽. 서버는 두 방식을 쓴다(nacho-server spec):
///   - `X-Next-Before` 헤더 또는 본문 `next_before` → 다음 요청 쿼리 `before`
///   - 본문 `next_cursor` → 다음 요청 쿼리 `cursor`
/// `cursorParam`이 어느 쪽인지 알려 주니, 다음 쪽은 `nextQuery`를 그대로 붙인다.
public struct HubPage {
    public var items: [HubObject]
    public var nextCursor: String?
    public var hasMore: Bool
    /// 다음 요청에서 `nextCursor`를 실을 쿼리 이름(`before` 또는 `cursor`).
    public var cursorParam: String = "before"

    /// 다음 쪽 쿼리(`[(cursorParam, nextCursor)]`). 다음 쪽이 없으면 nil.
    public var nextQuery: [(String, String)]? {
        guard hasMore, let c = nextCursor else { return nil }
        return [(cursorParam, c)]
    }
}

public extension PetAPIError {
    /// 409 version_conflict (expected_version이 낡았다): 새로 불러오면 된다.
    var isVersionConflict: Bool { code == "version_conflict" }
    var isNotFound: Bool { status == 404 || code == "not_found" }
}

public enum HubAPI {
    public static func newIdempotencyKey() -> String { UUID().uuidString.lowercased() }

    // MARK: requests (pure)

    static func url(_ e: ServerEndpoint, _ path: String, query: [(String, String)]) -> URL {
        var c = URLComponents(url: e.rest(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            // 키 순서는 부른 사람이 정한 그대로 둔다(바이트가 안정적이다).
            c.percentEncodedQuery = query.map { "\(PetHTTPRequest.formEscape($0.0))=\(PetHTTPRequest.formEscape($0.1))" }.joined(separator: "&")
        }
        return c.url!
    }

    private static func finish(_ r: PetHTTPRequest, idempotencyKey: String?) -> PetHTTPRequest {
        var r = r
        if let k = idempotencyKey, !k.isEmpty { r.headers["Idempotency-Key"] = k }
        return r
    }

    private static func withBody(_ method: String, _ e: ServerEndpoint, _ path: String, query: [(String, String)], bearer: String?,
                                 json: [String: Any], idempotencyKey: String?, expectedVersion: Int?) -> PetHTTPRequest {
        var body = json
        if let v = expectedVersion { body["expected_version"] = v }
        var r = PetHTTPRequest.postJSON(url(e, path, query: query), bearer: bearer, json: body)
        r.method = method
        return finish(r, idempotencyKey: idempotencyKey)
    }

    public static func get(_ e: ServerEndpoint, _ path: String, query: [(String, String)] = [], bearer: String?) -> PetHTTPRequest {
        .get(url(e, path, query: query), bearer: bearer)
    }

    public static func post(_ e: ServerEndpoint, _ path: String, query: [(String, String)] = [], bearer: String?, json: [String: Any] = [:],
                            idempotencyKey: String? = nil, expectedVersion: Int? = nil) -> PetHTTPRequest {
        withBody("POST", e, path, query: query, bearer: bearer, json: json, idempotencyKey: idempotencyKey, expectedVersion: expectedVersion)
    }

    public static func patch(_ e: ServerEndpoint, _ path: String, query: [(String, String)] = [], bearer: String?, json: [String: Any],
                             idempotencyKey: String? = nil, expectedVersion: Int? = nil) -> PetHTTPRequest {
        withBody("PATCH", e, path, query: query, bearer: bearer, json: json, idempotencyKey: idempotencyKey, expectedVersion: expectedVersion)
    }

    public static func put(_ e: ServerEndpoint, _ path: String, query: [(String, String)] = [], bearer: String?, json: [String: Any],
                           idempotencyKey: String? = nil, expectedVersion: Int? = nil) -> PetHTTPRequest {
        withBody("PUT", e, path, query: query, bearer: bearer, json: json, idempotencyKey: idempotencyKey, expectedVersion: expectedVersion)
    }

    /// DELETE는 줄 것(`json`·`expectedVersion`)이 있을 때만 JSON 본문을 싣는다(예: `DELETE /api/v1/agents/{id}`의 `DeletePolicies`).
    public static func delete(_ e: ServerEndpoint, _ path: String, query: [(String, String)] = [], bearer: String?, json: [String: Any]? = nil,
                              idempotencyKey: String? = nil, expectedVersion: Int? = nil) -> PetHTTPRequest {
        if json != nil || expectedVersion != nil {
            return withBody("DELETE", e, path, query: query, bearer: bearer, json: json ?? [:], idempotencyKey: idempotencyKey, expectedVersion: expectedVersion)
        }
        var r = PetHTTPRequest.get(url(e, path, query: query), bearer: bearer)
        r.method = "DELETE"
        return finish(r, idempotencyKey: idempotencyKey)
    }

    // MARK: responses

    /// 2xx가 아니면 한국어 문구가 든 오류로 바꾼다.
    public static func error(_ resp: PetHTTPResponse) -> PetAPIError { PetAPIError.from(resp) }

    public static func object(_ resp: PetHTTPResponse) -> Result<HubObject, PetAPIError> {
        guard (200...299).contains(resp.status) else { return .failure(error(resp)) }
        guard let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? [String: Any] else { return .failure(.badResponse) }
        return .success(HubObject(o))
    }

    /// 본문이 배열이거나 `{items|<key>: [...], next_cursor|next_before, has_more}`인 목록.
    /// 다음 커서는 `X-Next-Before` 헤더 → 본문 `next_cursor` → `next_before` 순서로 읽는다.
    public static func page(_ resp: PetHTTPResponse, key: String = "items") -> Result<HubPage, PetAPIError> {
        guard (200...299).contains(resp.status) else { return .failure(error(resp)) }
        guard let any = try? JSONSerialization.jsonObject(with: resp.body) else { return .failure(.badResponse) }
        var rows: [Any]
        var o: [String: Any] = [:]
        if let arr = any as? [Any] {
            rows = arr
        } else if let dict = any as? [String: Any], let arr = (dict[key] ?? dict["items"]) as? [Any] {
            rows = arr
            o = dict
        } else {
            return .failure(.badResponse)
        }
        let header = resp.header("X-Next-Before").flatMap { $0.isEmpty ? nil : $0 }
        let cursor: String?
        let param: String
        if let h = header { cursor = h; param = "before" }
        else if let c = o.str("next_cursor"), !c.isEmpty { cursor = c; param = "cursor" }
        else if let b = o.str("next_before"), !b.isEmpty { cursor = b; param = "before" }
        else { cursor = nil; param = "before" }
        let more = o.bool("has_more") ?? (cursor != nil)
        return .success(HubPage(items: rows.compactMap { ($0 as? [String: Any]).map(HubObject.init) }, nextCursor: cursor, hasMore: more, cursorParam: param))
    }

    /// 2xx이고 본문이 필요 없는 응답(204 등).
    public static func empty(_ resp: PetHTTPResponse) -> Result<Void, PetAPIError> {
        (200...299).contains(resp.status) ? .success(()) : .failure(error(resp))
    }
}

/// 토큰을 주는 함수. `forceRefresh`가 true면 서버가 401을 줬으니 새로 받는다. nil이면 로그인이 안 된 것이다.
public typealias HubTokenProvider = (_ forceRefresh: Bool, _ done: @escaping (String?) -> Void) -> Void

/// 허브의 모든 섹션이 쓰는 요청 실행기. 401이면 토큰을 새로 받아 한 번만 다시 보낸다.
public final class HubClient {
    public let endpoint: ServerEndpoint
    private let http: PetHTTPClient
    private let tokens: HubTokenProvider

    public init(endpoint: ServerEndpoint, http: PetHTTPClient, tokens: @escaping HubTokenProvider) {
        self.endpoint = endpoint
        self.http = http
        self.tokens = tokens
    }

    /// `build`는 토큰을 받아 요청을 만든다(HubAPI.get 등). 완료 콜백은 임의의 큐에서 불린다.
    public func send(_ build: @escaping (String?) -> PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        attempt(build, forceRefresh: false, completion: completion)
    }

    private func attempt(_ build: @escaping (String?) -> PetHTTPRequest, forceRefresh: Bool,
                         completion: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        tokens(forceRefresh) { [weak self] token in
            guard let self = self else { return }
            guard let token = token, !token.isEmpty else {
                completion(.failure(PetAPIError(status: 401, code: "unauthorized", text: ErrorText.userMessage(code: "unauthorized", reason: nil, fallback: ""))))
                return
            }
            self.http.send(build(token)) { r in
                switch r {
                case .failure: completion(.failure(.network))
                case let .success(resp):
                    if resp.status == 401, !forceRefresh {
                        self.attempt(build, forceRefresh: true, completion: completion)
                    } else if (200...299).contains(resp.status) {
                        completion(.success(resp))
                    } else {
                        completion(.failure(HubAPI.error(resp)))
                    }
                }
            }
        }
    }
}
