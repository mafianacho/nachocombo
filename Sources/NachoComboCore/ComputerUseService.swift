import Foundation

public struct CallLogEntry: Equatable {
    public enum Outcome: String, Equatable { case ok, error, denied }
    public let time: Date
    public let tool: String
    public let keyLabel: String
    public let outcome: Outcome
    public let highRisk: Bool
}

/// Who called which tool and when. Arguments, results, screen contents and typed text are never recorded.
public final class CallLog {
    public static let capacity = 200
    private var stored: [CallLogEntry] = []
    private let lock = NSLock()
    /// Called (on the calling thread, outside the lock) after an entry was added. Lets the UI refresh without a timer.
    public var onEntry: ((CallLogEntry) -> Void)?

    public init() {}

    public var entries: [CallLogEntry] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func append(_ entry: CallLogEntry) {
        lock.lock()
        stored.append(entry)
        if stored.count > CallLog.capacity { stored.removeFirst(stored.count - CallLog.capacity) }
        lock.unlock()
        onEntry?(entry)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        stored.removeAll()
    }
}

/// The MCP endpoint without any networking: `handle` turns one parsed HTTP request into one HTTP response.
/// Order of checks (every step fails closed): running -> path -> peer address -> Host/Origin -> client lockout -> key ->
/// client rate -> key rate -> method -> JSON-RPC -> emergency stop -> tool group switch -> backend.
public final class ComputerUseService {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let endpointPath = "/mcp"
    public static let serverName = "nacho-combo-computer-use"
    public static let serverVersion = "0.1.0"

    public let callLog: CallLog
    private let settings: () -> ComputerUseSettings
    private let keys: APIKeyStore
    private let backend: ComputerUseBackend
    private let failures: AuthFailureLimiter
    private let requests: RequestRateLimiter
    private let clientRequests: RequestRateLimiter
    private let now: () -> Date

    private let stateLock = NSLock()
    private let executionLock = NSLock()
    private var accepting = true
    private var emergency = false
    private var authFailureCount = 0
    private var callCount = 0

    public init(settings: @escaping () -> ComputerUseSettings, keys: APIKeyStore, backend: ComputerUseBackend,
                failures: AuthFailureLimiter? = nil, requests: RequestRateLimiter? = nil, clientRequests: RequestRateLimiter? = nil, callLog: CallLog = CallLog(),
                now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.keys = keys
        self.backend = backend
        self.failures = failures ?? AuthFailureLimiter(now: now)
        self.requests = requests ?? RequestRateLimiter(now: now)
        self.clientRequests = clientRequests ?? RequestRateLimiter(now: now)
        self.callLog = callLog
        self.now = now
    }

    // MARK: lifecycle

    /// After this every request is refused with 503. Used when the module is switched off.
    public func stop() { stateLock.lock(); accepting = false; stateLock.unlock() }

    public func emergencyStop() { stateLock.lock(); emergency = true; stateLock.unlock() }
    public func resetEmergencyStop() { stateLock.lock(); emergency = false; stateLock.unlock() }
    public var isEmergencyStopped: Bool { stateLock.lock(); defer { stateLock.unlock() }; return emergency }
    private var isAccepting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return accepting }

    /// Counters only: no keys, no content.
    public var diagnostics: [String: String] {
        stateLock.lock(); defer { stateLock.unlock() }
        return ["accepting": "\(accepting)", "emergencyStopped": "\(emergency)", "authFailures": "\(authFailureCount)",
                "toolCalls": "\(callCount)", "activeKeys": "\(keys.records.count)"]
    }

    // MARK: HTTP

    /// Same as `handle(_:clientID:)`; the old label from before LAN mode.
    public func handle(_ request: HTTPRequest, peer: String) -> HTTPResponse { handle(request, clientID: peer) }

    /// `clientID` is the peer IP of the connection as text. Failure lockouts and the client request limit are kept per
    /// (normalised) client; the key request limit stays per key.
    public func handle(_ request: HTTPRequest, clientID rawClientID: String) -> HTTPResponse {
        let clientID = ComputerUseNetworkPolicy.normalizeClientID(rawClientID)
        guard isAccepting else { return .error(503, "service stopped") }
        guard request.path == ComputerUseService.endpointPath else { return .error(404, "not found") }
        let config = settings()
        // Outsiders learn nothing: no key check, no failure bookkeeping.
        guard ComputerUseNetworkPolicy.isRemoteAddressAllowed(clientID, config) else { return .error(403, "forbidden client address") }
        guard hostAndOriginAllowed(request, config) else { return .error(403, "forbidden host or origin") }

        if let wait = failures.retryAfter(client: clientID) {
            return .error(429, "too many failed attempts", extra: [("Retry-After", "\(Int(wait.rounded(.up)))")])
        }
        guard let token = bearerToken(request), let key = keys.authenticate(token: token) else {
            failures.recordFailure(client: clientID)
            stateLock.lock(); authFailureCount += 1; stateLock.unlock()
            return .error(401, "unauthorized", extra: [("WWW-Authenticate", "Bearer")])
        }
        failures.recordSuccess(client: clientID)
        guard clientRequests.allow(key: clientID) else {
            return .error(429, "rate limit exceeded", extra: [("Retry-After", "\(clientRequests.retryAfterSeconds)")])
        }
        guard requests.allow(key: key.id) else {
            return .error(429, "rate limit exceeded", extra: [("Retry-After", "\(requests.retryAfterSeconds)")])
        }
        guard request.method == "POST" else { return .error(405, "method not allowed", extra: [("Allow", "POST")]) }

        switch JSONRPCCodec.parse(request.body) {
        case .invalid(let id, let error):
            return .json(400, JSONRPCCodec.encodeError(id: id, error: error))
        case .single(let message):
            guard let reply = respond(to: message, key: key, config: config) else { return HTTPResponse(status: 202) }
            return .json(200, reply)
        case .batch(let messages):
            let replies = messages.compactMap { respond(to: $0, key: key, config: config) }
            guard !replies.isEmpty else { return HTTPResponse(status: 202) }
            var body = Data("[".utf8)
            for (index, reply) in replies.enumerated() {
                if index > 0 { body.append(Data(",".utf8)) }
                body.append(reply)
            }
            body.append(Data("]".utf8))
            return .json(200, body)
        }
    }

    private func bearerToken(_ request: HTTPRequest) -> String? {
        guard let header = request.header("authorization") else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: Host / Origin (DNS rebinding and browser cross-site calls)

    private func hostAndOriginAllowed(_ request: HTTPRequest, _ config: ComputerUseSettings) -> Bool {
        guard let host = request.header("host"), ComputerUseNetworkPolicy.isHostAllowed(host, config) else { return false }
        if let origin = request.header("origin") {
            guard let range = origin.range(of: "://") else { return false }   // includes the literal "null"
            let authority = origin[range.upperBound...].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first ?? ""
            guard ComputerUseNetworkPolicy.isHostAllowed(String(authority), config) else { return false }
        }
        return true
    }

    // MARK: JSON-RPC

    /// nil = nothing to send back (notification or client reply).
    private func respond(to message: JSONRPCInbound, key: APIKeyRecord, config: ComputerUseSettings) -> Data? {
        switch message {
        case .response, .notification:
            return nil
        case .invalid(let id, let error):
            return JSONRPCCodec.encodeError(id: id, error: error)
        case .request(let id, let method, let params):
            switch method {
            case "initialize":
                let requested = params?.objectValue?["protocolVersion"]?.stringValue
                let version = requested.flatMap { ComputerUseService.supportedProtocolVersions.contains($0) ? $0 : nil }
                    ?? ComputerUseService.supportedProtocolVersions[0]
                return JSONRPCCodec.encodeResult(id: id, result: .object([
                    "protocolVersion": .string(version),
                    "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                    "serverInfo": .object(["name": .string(ComputerUseService.serverName),
                                           "version": .string(ComputerUseService.serverVersion)]),
                    "instructions": .string("Nacho Combo Computer Use: only tools from the groups the user turned on are listed. Coordinates are screen coordinates (in points)."),
                ]))
            case "ping":
                return JSONRPCCodec.encodeResult(id: id, result: .object([:]))
            case "tools/list":
                let tools = isEmergencyStopped ? [] : ToolCatalog.all.filter { config.isEnabled($0.group) }
                return JSONRPCCodec.encodeResult(id: id, result: .object(["tools": .array(tools.map { $0.json })]))
            case "tools/call":
                return callTool(id: id, params: params, key: key, config: config)
            default:
                return JSONRPCCodec.encodeError(id: id, error: .methodNotFound(method))
            }
        }
    }

    private func callTool(id: JSONValue, params: JSONValue?, key: APIKeyRecord, config: ComputerUseSettings) -> Data {
        guard let object = params?.objectValue, let name = object["name"]?.stringValue else {
            return JSONRPCCodec.encodeError(id: id, error: .invalidParams("name is required"))
        }
        var arguments: [String: JSONValue] = [:]
        switch object["arguments"] {
        case .none, .some(.null): break
        case .some(.object(let o)): arguments = o
        default: return JSONRPCCodec.encodeError(id: id, error: .invalidParams("arguments must be an object"))
        }
        guard let tool = ToolCatalog.definition(named: name) else {
            return JSONRPCCodec.encodeError(id: id, error: .invalidParams("Unknown tool: \(name.prefix(64))"))
        }

        func record(_ outcome: CallLogEntry.Outcome) {
            callLog.append(CallLogEntry(time: now(), tool: tool.name, keyLabel: key.label, outcome: outcome, highRisk: tool.group.isHighRisk))
        }
        stateLock.lock(); callCount += 1; stateLock.unlock()

        if isEmergencyStopped {
            record(.denied)
            return JSONRPCCodec.encodeResult(id: id, result: ToolResult.error("Emergency stop is active. Turn Computer Use back on in the app.").json)
        }
        guard config.isEnabled(tool.group) else {
            record(.denied)
            return JSONRPCCodec.encodeResult(id: id, result: ToolResult.error("'\(tool.name)' tool is turned off. Turn on that tool group in Nacho Combo on the Mac.").json)
        }
        executionLock.lock()
        let result = backend.execute(tool: tool.name, arguments: arguments)
        executionLock.unlock()
        record(result.isError ? .error : .ok)
        return JSONRPCCodec.encodeResult(id: id, result: result.json)
    }
}
