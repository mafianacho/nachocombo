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

/// The NachoCombo MCP server (formerly the Computer Use MCP server).
public typealias NachoComboMCPService = ComputerUseService

/// The MCP endpoint without any networking: `handle` turns one parsed HTTP request into one HTTP response.
/// Order of checks (every step fails closed): running -> path -> peer address -> Host/Origin -> client lockout -> key ->
/// client rate -> key rate -> method -> JSON-RPC -> emergency stop -> tool group / gadget switch -> backend / runner.
/// Tools come from the gadget registry (Computer Use tools under the tool group switches, every other gadget under its
/// own switch), resources are the gadget guides (`nachocombo://gadgets/<id>/guide`), prompts are the gadgets' flows.
public final class ComputerUseService {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let endpointPath = "/mcp"
    public static let serverName = "NachoCombo MCP"
    public static let serverVersion = "0.2.0"
    /// MCP "resource not found".
    public static let resourceNotFound = -32002

    public let callLog: CallLog
    private let settings: () -> ComputerUseSettings
    private let keys: APIKeyStore
    private let backend: ComputerUseBackend
    private let gadgets: GadgetToolDispatcher
    private let registry: [GadgetTool]
    private let guides: [GadgetGuide]
    private let prompts: [GadgetPrompt]
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
                now: @escaping () -> Date = Date.init, gadgets: GadgetToolDispatcher = .shared,
                registry: [GadgetTool] = GadgetToolRegistry.all, guides: [GadgetGuide] = GadgetToolRegistry.guides,
                prompts: [GadgetPrompt] = GadgetToolRegistry.prompts) {
        self.settings = settings
        self.gadgets = gadgets
        self.registry = registry
        self.guides = guides
        self.prompts = prompts
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
                    "capabilities": .object(["tools": .object(["listChanged": .bool(false)]),
                                             "resources": .object(["listChanged": .bool(false), "subscribe": .bool(false)]),
                                             "prompts": .object(["listChanged": .bool(false)])]),
                    "serverInfo": .object(["name": .string(ComputerUseService.serverName),
                                           "version": .string(ComputerUseService.serverVersion)]),
                    "instructions": .string("NachoCombo MCP: tools of the Nacho Combo gadgets on this Mac. Only tools of the gadgets and Computer Use groups the user turned on are listed. "
                                            + "Read a gadget's guide (resources/read nachocombo://gadgets/<id>/guide) before using it. Coordinates are screen coordinates (in points)."),
                ]))
            case "ping":
                return JSONRPCCodec.encodeResult(id: id, result: .object([:]))
            case "tools/list":
                let tools = isEmergencyStopped ? [] : registry.filter { config.offers($0) }
                return JSONRPCCodec.encodeResult(id: id, result: .object(["tools": .array(tools.map { ComputerUseService.json($0) })]))
            case "tools/call":
                return callTool(id: id, params: params, key: key, config: config)
            case "resources/list":
                return JSONRPCCodec.encodeResult(id: id, result: .object(["resources": .array(guides.map { g in
                    .object(["uri": .string(g.gadget.guideURI), "name": .string("\(g.gadget.rawValue)_guide"),
                             "title": .string("\(g.gadget.displayName) guide"),
                             "description": .string("How to use the \(g.gadget.displayName) tools: what they do, order of calls, examples, limits."),
                             "mimeType": .string(GadgetGuide.mimeType)])
                })]))
            case "resources/templates/list":
                return JSONRPCCodec.encodeResult(id: id, result: .object(["resourceTemplates": .array([])]))
            case "resources/read":
                guard let uri = params?.objectValue?["uri"]?.stringValue else {
                    return JSONRPCCodec.encodeError(id: id, error: .invalidParams("uri is required"))
                }
                guard let guide = guides.first(where: { $0.gadget.guideURI == uri }) else {
                    return JSONRPCCodec.encodeError(id: id, error: JSONRPCError(code: ComputerUseService.resourceNotFound,
                                                                                 message: "Resource not found: \(uri.prefix(100))"))
                }
                return JSONRPCCodec.encodeResult(id: id, result: .object(["contents": .array([.object([
                    "uri": .string(uri), "mimeType": .string(GadgetGuide.mimeType),
                    "text": .string(guide.render(for: .mcp, tools: registry)),
                ])])]))
            case "prompts/list":
                return JSONRPCCodec.encodeResult(id: id, result: .object(["prompts": .array(prompts.map { p in
                    .object(["name": .string(p.name), "description": .string(p.description),
                             "arguments": .array(p.arguments.map { a in
                                 .object(["name": .string(a.name), "description": .string(a.description), "required": .bool(a.required)])
                             })])
                })]))
            case "prompts/get":
                return getPrompt(id: id, params: params)
            default:
                return JSONRPCCodec.encodeError(id: id, error: .methodNotFound(method))
            }
        }
    }

    static func json(_ t: GadgetTool) -> JSONValue {
        .object(["name": .string(t.mcpName), "description": .string(t.englishDescription), "inputSchema": t.inputSchema])
    }

    private func getPrompt(id: JSONValue, params: JSONValue?) -> Data {
        guard let object = params?.objectValue, let name = object["name"]?.stringValue else {
            return JSONRPCCodec.encodeError(id: id, error: .invalidParams("name is required"))
        }
        guard let prompt = prompts.first(where: { $0.name == name }) else {
            return JSONRPCCodec.encodeError(id: id, error: .invalidParams("Unknown prompt: \(name.prefix(64))"))
        }
        var values: [String: String] = [:]
        switch object["arguments"] {
        case .none, .some(.null): break
        case .some(.object(let o)):
            for (k, v) in o {
                guard prompt.arguments.contains(where: { $0.name == k }) else {
                    return JSONRPCCodec.encodeError(id: id, error: .invalidParams("Unknown argument: \(k.prefix(64))"))
                }
                guard case .string(let s) = v, s.count <= 200 else {
                    return JSONRPCCodec.encodeError(id: id, error: .invalidParams("'\(k.prefix(64))' must be a string of at most 200 characters"))
                }
                values[k] = s
            }
        default: return JSONRPCCodec.encodeError(id: id, error: .invalidParams("arguments must be an object"))
        }
        for a in prompt.arguments where a.required && (values[a.name] ?? "").isEmpty {
            return JSONRPCCodec.encodeError(id: id, error: .invalidParams("Missing required argument '\(a.name)'"))
        }
        return JSONRPCCodec.encodeResult(id: id, result: .object([
            "description": .string(prompt.description),
            "messages": .array([.object(["role": .string("user"),
                                         "content": .object(["type": .string("text"), "text": .string(prompt.render(values))])])]),
        ]))
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
        // New names (`computer_screen_capture`, `window_arrange`) and old Computer Use names (`screen_capture`).
        guard let tool = GadgetToolRegistry.mcpTool(named: name, in: registry) else {
            return JSONRPCCodec.encodeError(id: id, error: .invalidParams("Unknown tool: \(name.prefix(64))"))
        }
        let highRisk = tool.mcpGroup?.isHighRisk ?? (tool.risk == .destructive)

        // The log keeps the name the client used (no arguments, no results).
        func record(_ outcome: CallLogEntry.Outcome) {
            callLog.append(CallLogEntry(time: now(), tool: name, keyLabel: key.label, outcome: outcome, highRisk: highRisk))
        }
        stateLock.lock(); callCount += 1; stateLock.unlock()

        if isEmergencyStopped {
            record(.denied)
            return JSONRPCCodec.encodeResult(id: id, result: ToolResult.error("Emergency stop is active. Turn Computer Use back on in the app.").json)
        }
        guard config.offers(tool) else {
            record(.denied)
            let which = tool.mcpGroup != nil ? "that tool group" : "the \(tool.gadget.displayName) gadget for NachoCombo MCP"
            return JSONRPCCodec.encodeResult(id: id, result: ToolResult.error("'\(name.prefix(64))' tool is turned off. Turn on \(which) in Nacho Combo on the Mac.").json)
        }
        if let legacy = tool.legacyMCPName {
            executionLock.lock()
            let result = backend.execute(tool: legacy, arguments: arguments)
            executionLock.unlock()
            record(result.isError ? .error : .ok)
            return JSONRPCCodec.encodeResult(id: id, result: result.json)
        }
        let outcome = gadgets.runAndWait(tool, arguments: arguments, exit: .mcp)
        record(outcome.ok ? .ok : .error)
        let data = (try? JSONSerialization.data(withJSONObject: outcome.resultJSON, options: [.sortedKeys])) ?? Data("{}".utf8)
        let result = ToolResult(content: [.text(String(decoding: data, as: UTF8.self))], isError: !outcome.ok)
        return JSONRPCCodec.encodeResult(id: id, result: result.json)
    }
}
