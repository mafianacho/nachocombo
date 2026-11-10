import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP request of the pet (REST to nacho-server, token calls to Keycloak). Bodies are built by Core functions so
/// the app, the CLI and the tests send exactly the same bytes.
public struct PetHTTPRequest: Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    public static func get(_ url: URL, bearer: String?) -> PetHTTPRequest {
        var h = ["Accept": "application/json"]
        if let b = bearer, !b.isEmpty { h["Authorization"] = "Bearer " + b }
        return PetHTTPRequest(method: "GET", url: url, headers: h)
    }

    public static func postJSON(_ url: URL, bearer: String?, json: [String: Any]) -> PetHTTPRequest {
        var h = ["Accept": "application/json", "Content-Type": "application/json"]
        if let b = bearer, !b.isEmpty { h["Authorization"] = "Bearer " + b }
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        return PetHTTPRequest(method: "POST", url: url, headers: h, body: data)
    }

    /// `application/x-www-form-urlencoded` (OAuth token endpoint). Keys are sorted for stable bytes.
    public static func postForm(_ url: URL, fields: [String: String]) -> PetHTTPRequest {
        let body = fields.keys.sorted().map { "\(PetHTTPRequest.formEscape($0))=\(PetHTTPRequest.formEscape(fields[$0] ?? ""))" }
            .joined(separator: "&")
        return PetHTTPRequest(method: "POST", url: url,
                              headers: ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded"],
                              body: Data(body.utf8))
    }

    /// RFC 3986 unreserved characters stay, everything else is percent-encoded (also `+`, `&`, `=`).
    public static func formEscape(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

public struct PetHTTPResponse: Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.key.lowercased() == n }?.value
    }
}

public protocol PetHTTPClient: AnyObject {
    /// Redirects are never followed (the OAuth callback is a custom scheme and must be read, not opened).
    func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void)
}

/// URLSession with an ephemeral configuration (no cookies or cache on disk) and redirects turned off.
public final class URLSessionPetHTTP: NSObject, PetHTTPClient, URLSessionTaskDelegate {
    private var session: URLSession!

    public init(timeout: TimeInterval = 30) {
        super.init()
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.httpCookieStorage = nil
        c.urlCache = nil
        session = URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: PetHTTPRequest, completion: @escaping (Result<PetHTTPResponse, Error>) -> Void) {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        session.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            let http = resp as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                if let k = k as? String, let v = v as? String { headers[k] = v }
            }
            completion(.success(PetHTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data ?? Data())))
        }.resume()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Server error body `{"error":{"code","message"}}` or `{"code","message"}` → code (nil if not JSON).
public enum PetServerError {
    public static func code(_ data: Data) -> String? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else { return nil }
        if let e = o["error"] as? [String: Any], let c = e["code"] as? String { return c }
        if let c = o["code"] as? String { return c }
        if let c = o["error"] as? String { return c }
        return nil
    }
}
