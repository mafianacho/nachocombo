import Foundation

public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPResponse: Equatable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    /// One response per connection (`Connection: close`): no keep-alive state to leak or to time out.
    public func serialized() -> Data {
        var text = "HTTP/1.1 \(status) \(HTTPResponse.statusText(status))\r\n"
        for (name, value) in headers where name.lowercased() != "content-length" && name.lowercased() != "connection" {
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    static func json(_ status: Int, _ body: Data, extra: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + extra, body: body)
    }

    static func error(_ status: Int, _ message: String, extra: [(String, String)] = []) -> HTTPResponse {
        json(status, JSONRPCCodec.encode(.object(["error": .string(message)])), extra: extra)
    }
}

public enum HTTPParseResult: Equatable {
    case needMore
    case request(HTTPRequest, consumed: Int)
    case invalid(HTTPResponse)
}

/// A deliberately small HTTP/1.1 reader: one request per connection, Content-Length bodies only, hard size caps.
/// Not supported (answered with an error): chunked bodies. `Expect: 100-continue` is ignored (the client just
/// sends the body after its own timeout).
public enum HTTPParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 1024 * 1024

    public static func parse(_ buffer: Data, maxHeaderBytes: Int = HTTPParser.maxHeaderBytes,
                             maxBodyBytes: Int = HTTPParser.maxBodyBytes) -> HTTPParseResult {
        let bytes = [UInt8](buffer)
        guard let headEnd = findHeaderEnd(bytes) else {
            return bytes.count > maxHeaderBytes ? .invalid(.error(431, "headers too large")) : .needMore
        }
        guard headEnd <= maxHeaderBytes else { return .invalid(.error(431, "headers too large")) }
        guard let head = String(bytes: bytes[0..<headEnd], encoding: .utf8) else { return .invalid(.error(400, "bad request")) }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."), requestLine[1].hasPrefix("/"),
              requestLine[0].allSatisfy({ $0.isLetter }) else { return .invalid(.error(400, "bad request")) }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid(.error(400, "bad request")) }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length", let existing = headers[name], existing != value { return .invalid(.error(400, "bad request")) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(.error(411, "content-length required")) }

        var length = 0
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(raw) else {
                return .invalid(.error(400, "bad request"))
            }
            guard n <= maxBodyBytes else { return .invalid(.error(413, "body too large")) }
            length = n
        }
        let bodyStart = headEnd + 4
        guard bytes.count >= bodyStart + length else { return .needMore }
        let request = HTTPRequest(method: requestLine[0].uppercased(), path: requestLine[1], headers: headers,
                                  body: Data(bytes[bodyStart..<(bodyStart + length)]))
        return .request(request, consumed: bodyStart + length)
    }

    /// Index of the first byte of the blank line terminator ("\r\n\r\n"), or nil.
    private static func findHeaderEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = 0
        while i <= bytes.count - 4 {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}
