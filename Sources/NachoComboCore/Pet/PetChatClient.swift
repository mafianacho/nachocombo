import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa); attachments added for capture/shelf → pet.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TransportEvent {
    case opened
    case text(String)
    case closed(TransportFailure?)  // nil failure = clean close
}

/// One WebSocket connection. A new transport object is created for every connection attempt.
public protocol WebSocketTransport: AnyObject {
    func connect(url: URL, bearer: String?, handler: @escaping (TransportEvent) -> Void)
    func send(_ text: String)
    func close()
}

public enum OutgoingText {
    public static let maxCodePoints = 4000  // client-side limit (server limit unknown: see docs/PROTOCOL-NOTES.md)

    public enum Problem: Equatable, Error {
        case empty, tooLong
        public var koreanMessage: String {
            switch self {
            case .empty: return "보낼 내용을 입력해 주세요."
            case .tooLong: return "한 번에 보낼 수 있는 길이는 \(OutgoingText.maxCodePoints)자까지예요."
            }
        }
    }

    /// Trims, rejects empty / over-long / NUL-containing text. Length is counted in Unicode code points.
    /// `allowEmpty`: a message that carries attachments may have no text (the server accepts attachment-only turns).
    public static func validate(_ raw: String, allowEmpty: Bool = false) -> Result<String, Problem> {
        let t = raw.replacingOccurrences(of: "\u{0}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty && !allowEmpty { return .failure(.empty) }
        if t.unicodeScalars.count > maxCodePoints { return .failure(.tooLong) }
        return .success(t)
    }
}

/// `/ws/chat` client: connect with Bearer, stream turns, stop, ping, reconnect with backoff.
/// All state changes happen on `queue`; `onChange` is called on that queue after every change.
public final class ChatClient {
    public let queue = DispatchQueue(label: "nacho.combo.pet.chat")
    public private(set) var state = ChatState()
    public var onChange: ((ChatState) -> Void)?

    private let endpoint: ServerEndpoint
    private let token: () -> String?
    private let makeTransport: () -> WebSocketTransport
    private let policy: ReconnectPolicy
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let jitter: () -> Double
    private let pingInterval: TimeInterval

    private var transport: WebSocketTransport?
    private var generation = 0  // invalidates callbacks of older connections and timers
    private var attempt = 0
    private var wantConnected = false

    public init(
        endpoint: ServerEndpoint,
        token: @escaping () -> String?,
        makeTransport: @escaping () -> WebSocketTransport,
        policy: ReconnectPolicy = ReconnectPolicy(),
        pingInterval: TimeInterval = 30,
        jitter: @escaping () -> Double = { Double.random(in: 0...1) },
        schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.token = token
        self.makeTransport = makeTransport
        self.policy = policy
        self.pingInterval = pingInterval
        self.jitter = jitter
        let q = queue
        self.schedule = schedule ?? { delay, work in q.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Test helper: waits until all queued work ran.
    public func flush() { queue.sync {} }

    // MARK: public API (thread-safe)

    public func connect() {
        queue.async {
            self.wantConnected = true
            self.attempt = 0
            self.openConnection()
        }
    }

    public func disconnect() {
        queue.async {
            self.wantConnected = false
            self.generation += 1
            self.transport?.close()
            self.transport = nil
            self.state.connectionLost()
            self.state.phase = .disconnected
            self.publish()
        }
    }

    /// Validates and sends one user message. Returns the client_msg_id, or the reason it was refused.
    /// `attachments` must already be uploaded (`POST /api/v1/media/uploads`); at most `PetMedia.maxAttachments`.
    @discardableResult
    public func send(text raw: String, attachments: [PetAttachment] = []) -> Result<String, SendRefusal> {
        if attachments.count > PetMedia.maxAttachments { return .failure(.tooManyAttachments) }
        switch OutgoingText.validate(raw, allowEmpty: !attachments.isEmpty) {
        case let .failure(p): return .failure(.invalidText(p))
        case let .success(text):
            return queue.sync {
                guard state.phase == .connected, let t = transport else { return .failure(.notConnected) }
                if state.isBusy { return .failure(.busy) }
                let id = "g-" + String(UUID().uuidString.lowercased().prefix(12))
                state.beginTurn(text: text, clientMsgID: id, attachmentNames: attachments.map { $0.name })
                t.send(ClientFrame.message(text: text, roomID: state.roomID, clientMsgID: id,
                                           attachmentIDs: attachments.map { $0.attachmentID }).encode())
                publish()
                return .success(id)
            }
        }
    }

    /// Changes the chat state from outside (room record, recovered answers, memory lines) and publishes it.
    public func update(_ body: @escaping (inout ChatState) -> Void) {
        queue.async {
            body(&self.state)
            self.publish()
        }
    }

    /// Read mark (`{type:read,room_id,seq}`), forward only; the server answers nothing unless it fails.
    public func markRead(seq: Int) {
        queue.async {
            guard self.state.phase == .connected, let room = self.state.roomID, !room.isEmpty, seq > 0, let t = self.transport else { return }
            t.send(ClientFrame.read(roomID: room, seq: seq).encode())
        }
    }

    public func stop() {
        queue.async {
            guard self.state.isBusy, let room = self.state.roomID, let t = self.transport else { return }
            self.state.markStopRequested()
            t.send(ClientFrame.stop(roomID: room).encode())
            self.publish()
        }
    }

    // MARK: connection handling (queue only)

    private func openConnection() {
        generation += 1
        let gen = generation
        transport?.close()
        let t = makeTransport()
        transport = t
        state.phase = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
        publish()
        t.connect(url: endpoint.webSocketURL, bearer: token()) { [weak self] ev in
            guard let self = self else { return }
            self.queue.async { self.handle(ev, generation: gen) }
        }
    }

    private func handle(_ ev: TransportEvent, generation gen: Int) {
        guard gen == generation else { return }
        switch ev {
        case .opened:
            break  // `ready` frame marks the connection usable
        case let .text(s):
            guard let frame = ServerFrame.decode(s) else { return }
            if case .ready = frame.event {
                attempt = 0
                schedulePing(gen)
            }
            state.apply(frame)
            publish()
        case let .closed(failure):
            transport = nil
            state.connectionLost()
            guard wantConnected else {
                state.phase = .disconnected
                publish()
                return
            }
            let f = failure ?? TransportFailure(message: "연결이 닫혔어요")
            attempt += 1
            if f.httpStatus == 401 || f.httpStatus == 403 {
                state.phase = .authFailed
                state.notice = ErrorText.userMessage(code: "unauthorized", reason: nil, fallback: "")
                wantConnected = false
            } else if policy.shouldRetry(attempt: attempt, failure: f) {
                state.phase = .reconnecting(attempt: attempt)
                let delay = policy.delay(attempt: attempt, jitter: jitter())
                let retryGen = generation
                schedule(delay) { [weak self] in
                    guard let self = self, self.wantConnected, retryGen == self.generation else { return }
                    self.openConnection()
                }
            } else {
                state.phase = .disconnected
                state.notice = "서버에 연결하지 못했어요. 설정에서 서버 주소를 확인해 주세요."
                wantConnected = false
            }
            publish()
        }
    }

    private func schedulePing(_ gen: Int) {
        schedule(pingInterval) { [weak self] in
            guard let self = self, gen == self.generation, self.state.phase == .connected else { return }
            self.transport?.send(ClientFrame.ping.encode())
            self.schedulePing(gen)
        }
    }

    private func publish() { onChange?(state) }
}

public enum SendRefusal: Equatable, Error {
    case invalidText(OutgoingText.Problem)
    case notConnected
    case busy
    case tooManyAttachments

    public var koreanMessage: String {
        switch self {
        case let .invalidText(p): return p.koreanMessage
        case .tooManyAttachments: return "한 번에 붙일 수 있는 파일은 \(PetMedia.maxAttachments)개까지예요."
        case .notConnected: return "서버에 연결되어 있지 않아요."
        case .busy: return "나초가 아직 답하고 있어요. 끝난 뒤에 보내 주세요."
        }
    }
}

// MARK: URLSession transport (macOS app; swift-corelibs-foundation on Linux has no URLSessionWebSocketTask)

#if !os(Linux)

public final class URLSessionTransport: NSObject, WebSocketTransport, URLSessionWebSocketDelegate {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var handler: ((TransportEvent) -> Void)?
    private let lock = NSLock()
    private var finished = false

    public override init() { super.init() }

    public func connect(url: URL, bearer: String?, handler: @escaping (TransportEvent) -> Void) {
        self.handler = handler
        var req = URLRequest(url: url)
        if let b = bearer, !b.isEmpty { req.setValue("Bearer \(b)", forHTTPHeaderField: "Authorization") }
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receiveLoop(t)
    }

    public func send(_ text: String) {
        task?.send(.string(text)) { [weak self] err in
            if let err = err { self?.finish(TransportFailure(message: err.localizedDescription)) }
        }
    }

    public func close() {
        lock.lock(); finished = true; lock.unlock()  // caller initiated: no `closed` event
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(.string(s)):
                self.handler?(.text(s))
                self.receiveLoop(t)
            case let .success(.data(d)):
                if let s = String(data: d, encoding: .utf8) { self.handler?(.text(s)) }
                self.receiveLoop(t)
            case .success:
                self.receiveLoop(t)
            case let .failure(err):
                let status = (t.response as? HTTPURLResponse)?.statusCode
                self.finish(TransportFailure(httpStatus: status, message: err.localizedDescription))
            }
        }
    }

    private func finish(_ f: TransportFailure?) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        handler?(.closed(f))
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        handler?(.opened)
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        finish(nil)
    }
}
#endif
