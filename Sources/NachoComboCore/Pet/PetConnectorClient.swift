import Foundation

// `/ws/connector` client (nacho-server docs/ws-protocol.md §3): Nacho Combo registers `PetCommands.capabilities`, the
// server forwards tool calls as `request` frames, the app runs them and answers with `response` (same `id`).
// Binding token: `POST /api/v1/agents/{agent_id}/connector-binding {kind, label}` → `{token:"nct_…"}`, shown only once;
// kept in the Keychain. One connector session per Nacho: a newer one replaces ours (`error{code:"replaced"}`) and we
// do not fight back (no automatic reconnect after a replacement).

public enum ConnectorPhase: Equatable {
    case off
    case connecting
    case ready
    case reconnecting(attempt: Int)
    /// Another connector (e.g. a second Mac) took over this Nacho's connector slot.
    case replaced
    case failed(String)

    public var koreanLabel: String {
        switch self {
        case .off: return "꺼짐"
        case .connecting: return "연결 중"
        case .ready: return "연결됨"
        case .reconnecting: return "다시 연결 중"
        case .replaced: return "다른 기기가 연결해 쉬는 중"
        case let .failed(m): return m
        }
    }
}

public enum ConnectorBinding {
    public static let kind = "nacho_combo"
    public static let label = "Nacho Combo (Mac)"

    public static func request(_ endpoint: ServerEndpoint, bearer: String?, agentID: String) -> PetHTTPRequest? {
        guard PetIDs.isUUID(agentID) else { return nil }
        return .postJSON(endpoint.rest("/api/v1/agents/\(agentID.lowercased())/connector-binding"), bearer: bearer,
                         json: ["kind": kind, "label": label])
    }

    /// `nct_` + hex. Anything else is not stored.
    public static func token(from data: Data) -> String? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any],
              let t = o["token"] as? String, t.hasPrefix("nct_"), t.count <= 200,
              t.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) })
        else { return nil }
        return t
    }

    static func secretKey(scope: String, agentID: String) -> String { "connector|\(scope)|\(agentID.lowercased())" }
    /// Which Nacho the stored binding belongs to, so signing out can delete it even when the chat is not connected.
    static func agentKey(scope: String) -> String { "connector-agent|\(scope)" }
}

public enum ConnectorFrames {
    public static func hello(token: String) -> String {
        encode(["type": "hello", "token": token, "capabilities": PetCommands.capabilities])
    }

    public static func response(id: String, outcome: PetCommandOutcome) -> String {
        encode(["type": "response", "id": id, "result": outcome.resultJSON])
    }

    public static func response(id: String, error: String) -> String {
        encode(["type": "response", "id": id, "error": error])
    }

    public static let ping = "{\"type\":\"ping\"}"

    static func encode(_ o: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public enum Incoming: Equatable {
        case ready(agentID: String)
        case request(id: String, capability: String, paramsJSON: String)
        case error(code: String)
        case pong
        case other
    }

    public static func decode(_ text: String) -> Incoming {
        guard let data = text.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data),
              let o = any as? [String: Any], let type = o["type"] as? String
        else { return .other }
        switch type {
        case "ready": return .ready(agentID: (o["agent_id"] as? String) ?? "")
        case "request":
            guard let id = o["id"] as? String, !id.isEmpty, id.count <= 100, let cap = o["capability"] as? String else { return .other }
            let params = o["params"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            return .request(id: id, capability: cap, paramsJSON: params.map { String(decoding: $0, as: UTF8.self) } ?? "{}")
        case "error": return .error(code: (o["code"] as? String) ?? "unknown")
        case "pong": return .pong
        default: return .other
        }
    }
}

/// Runs the commands on the Mac. The app's implementation hops to the main thread; it must call `done` exactly once.
public protocol PetCommandExecuting: AnyObject {
    func execute(_ command: PetCommand, done: @escaping (PetCommandOutcome) -> Void)
}

public final class PetConnectorClient {
    public let queue = DispatchQueue(label: "nacho.combo.pet.connector")
    public private(set) var phase: ConnectorPhase = .off
    public var onChange: ((ConnectorPhase) -> Void)?
    /// The server refused our binding token (revoked or unknown): the session issues a new one.
    public var onUnauthorized: (() -> Void)?
    /// Command log for diagnostics: capability + ok/refused (never parameters' free text).
    public private(set) var handled: [String] = []

    private let url: URL
    private let token: String
    private let makeTransport: () -> WebSocketTransport
    private weak var executor: PetCommandExecuting?
    private let policy: ReconnectPolicy
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var transport: WebSocketTransport?
    private var generation = 0
    private var attempt = 0
    private var wanted = false

    public init(url: URL, token: String, executor: PetCommandExecuting, makeTransport: @escaping () -> WebSocketTransport,
                policy: ReconnectPolicy = ReconnectPolicy(),
                schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.url = url
        self.token = token
        self.executor = executor
        self.makeTransport = makeTransport
        self.policy = policy
        let q = queue
        self.schedule = schedule ?? { delay, work in q.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    public func flush() { queue.sync {} }

    public func connect() {
        queue.async {
            self.wanted = true
            self.attempt = 0
            self.open()
        }
    }

    public func disconnect() {
        queue.async {
            self.wanted = false
            self.generation += 1
            self.transport?.close()
            self.transport = nil
            self.set(.off)
        }
    }

    private func set(_ p: ConnectorPhase) {
        phase = p
        onChange?(p)
    }

    private func open() {
        generation += 1
        let gen = generation
        transport?.close()
        let t = makeTransport()
        transport = t
        set(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
        // The token goes in the first frame (`hello`), not in a header, so it never shows up in proxy logs.
        t.connect(url: url, bearer: nil) { [weak self] ev in
            guard let self = self else { return }
            self.queue.async { self.handle(ev, gen) }
        }
    }

    private func handle(_ ev: TransportEvent, _ gen: Int) {
        guard gen == generation else { return }
        switch ev {
        case .opened:
            transport?.send(ConnectorFrames.hello(token: token))
        case let .text(s):
            switch ConnectorFrames.decode(s) {
            case .ready:
                attempt = 0
                set(.ready)
                schedulePing(gen)
            case let .request(id, capability, paramsJSON):
                run(id: id, capability: capability, paramsJSON: paramsJSON, gen: gen)
            case let .error(code):
                if code == "replaced" {
                    wanted = false
                    set(.replaced)
                } else if code == "unauthorized" || code == "not_found" || code == "forbidden" {
                    wanted = false
                    set(.failed("커넥터 연결이 거절됐어요."))
                    onUnauthorized?()
                }
            case .pong, .other:
                break
            }
        case let .closed(failure):
            transport = nil
            guard wanted else {
                switch phase {
                case .replaced, .failed: break  // keep the reason on screen
                default: set(.off)
                }
                return
            }
            attempt += 1
            let f = failure ?? TransportFailure(message: "closed")
            if policy.shouldRetry(attempt: attempt, failure: f) {
                set(.reconnecting(attempt: attempt))
                let retryGen = generation
                schedule(policy.delay(attempt: attempt, jitter: Double.random(in: 0...1))) { [weak self] in
                    guard let self = self, self.wanted, retryGen == self.generation else { return }
                    self.open()
                }
            } else {
                wanted = false
                set(.failed("커넥터에 연결하지 못했어요."))
            }
        }
    }

    private func run(id: String, capability: String, paramsJSON: String, gen: Int) {
        let params = paramsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        switch PetCommands.parse(capability: capability, params: params) {
        case let .failure(problem):
            handled.append("\(capability.prefix(64)):refused")
            transport?.send(ConnectorFrames.response(id: id, error: problem.message))
        case let .success(command):
            guard let ex = executor else {
                transport?.send(ConnectorFrames.response(id: id, error: "Nacho Combo is closing"))
                return
            }
            ex.execute(command) { [weak self] outcome in
                guard let self = self else { return }
                self.queue.async {
                    self.handled.append("\(capability):\(outcome.ok ? "ok" : "failed")")
                    guard gen == self.generation else { return }  // the socket changed: the server already timed out
                    self.transport?.send(ConnectorFrames.response(id: id, outcome: outcome))
                }
            }
        }
    }

    private func schedulePing(_ gen: Int) {
        schedule(30) { [weak self] in
            guard let self = self, gen == self.generation, self.phase == .ready else { return }
            self.transport?.send(ConnectorFrames.ping)
            self.schedulePing(gen)
        }
    }
}
