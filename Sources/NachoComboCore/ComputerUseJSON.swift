import Foundation

/// A JSON document node. Unlike `Any`, it keeps booleans, integers and doubles apart on every platform.
public enum JSONValue: Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public struct JSONRPCError: Error, Equatable {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: methodNotFound, message: "Method not found: \(method)")
    }
    public static func invalidParams(_ message: String) -> JSONRPCError {
        JSONRPCError(code: invalidParams, message: message)
    }
}

public enum JSONRPCInbound: Equatable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    /// A JSON-RPC reply to something the server asked. The server never asks, so it is acknowledged and ignored.
    case response
    case invalid(id: JSONValue?, error: JSONRPCError)
}

public enum JSONRPCParsed: Equatable {
    case single(JSONRPCInbound)
    case batch([JSONRPCInbound])
    case invalid(id: JSONValue?, error: JSONRPCError)
}

public enum JSONRPCCodec {
    public static func parse(_ data: Data) -> JSONRPCParsed {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .invalid(id: nil, error: JSONRPCError(code: JSONRPCError.parseError, message: "Parse error"))
        }
        switch value {
        case .array(let items):
            guard !items.isEmpty else {
                return .invalid(id: nil, error: JSONRPCError(code: JSONRPCError.invalidRequest, message: "Empty batch"))
            }
            return .batch(items.map(inbound(from:)))
        default:
            if case .invalid(let id, let error) = inbound(from: value) { return .invalid(id: id, error: error) }
            return .single(inbound(from: value))
        }
    }

    private static func inbound(from value: JSONValue) -> JSONRPCInbound {
        let bad = { (id: JSONValue?) -> JSONRPCInbound in
            .invalid(id: id, error: JSONRPCError(code: JSONRPCError.invalidRequest, message: "Invalid Request"))
        }
        guard case .object(let object) = value else { return bad(nil) }
        // The id is echoed in errors only when it is a string, number or null.
        var id: JSONValue?
        switch object["id"] {
        case .some(.string), .some(.int), .some(.double), .some(.null): id = object["id"]
        case .none: id = nil
        default: return bad(nil)
        }
        guard object["jsonrpc"] == .string("2.0") else { return bad(id) }
        if object["method"] == nil, object["result"] != nil || object["error"] != nil { return .response }
        guard case .some(.string(let method)) = object["method"] else { return bad(id) }
        if let id = id, id != .null { return .request(id: id, method: method, params: object["params"]) }
        return .notification(method: method, params: object["params"])
    }

    public static func encodeResult(id: JSONValue, result: JSONValue) -> Data {
        encode(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    public static func encodeError(id: JSONValue?, error: JSONRPCError) -> Data {
        encode(.object(["jsonrpc": .string("2.0"), "id": id ?? .null,
                        "error": .object(["code": .int(error.code), "message": .string(error.message)])]))
    }

    public static func encode(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("null".utf8)
    }
}
