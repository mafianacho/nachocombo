import Foundation

// The pet's brain, shared by the app and the dev CLI: login → `/ws/chat` → uploads → `/ws/connector`.
// Nothing connects at launch: the first open of the chat (or a send) connects, so starting the Mac does not log in
// anywhere or ping the phone with "connector connected". All state changes happen on `queue`; `onChange` is called
// there after every change (the app hops to the main thread).

public enum PetAuthPhase: Equatable {
    case signedOut
    case signingIn
    case signedIn
    case failed(String)
}

public struct PetPendingFile: Equatable, Identifiable {
    public let id: Int
    public let file: PetOutgoingFile
}

public struct PetSessionState: Equatable {
    public var auth: PetAuthPhase = .signedOut
    public var chat = ChatState()
    public var connector: ConnectorPhase = .off
    public var pending: [PetPendingFile] = []
    public var uploading = false
    /// Last message for the user that is not part of a turn (Korean).
    public var notice: String?
    public var lastInteraction = Date()
    /// `GET /client/config` (dictation on/off and limits, service status). Nil until loaded.
    public var config: PetClientConfig?
    public var loadingHistory = false
    public var dictating = false
    /// Requests from the selection bar by the turn's client message id (chip, 다시, 보낸 내용 보기). Memory only.
    public var selectionTurns: [String: PetSelectionSent] = [:]
    public init() {}
}

public final class PetSession {
    public let queue = DispatchQueue(label: "nacho.combo.pet.session")
    public private(set) var state = PetSessionState()
    public var onChange: ((PetSessionState) -> Void)?
    public private(set) var settings: PetSettings

    private let http: PetHTTPClient
    private let secrets: PetSecretStore
    private weak var browser: PetAuthBrowser?
    private let makeTransport: () -> WebSocketTransport
    private weak var executor: PetCommandExecuting?
    private let random: RandomBytesSource
    private let now: () -> Date
    private var auth: PetAuth
    private var chat: ChatClient?
    private var connector: PetConnectorClient?
    private var connectorAgent: String?
    private var connectorReissued = false
    private var refreshTried = false
    private var nextPendingID = 1
    private var opened = false

    public init(settings: PetSettings, http: PetHTTPClient, secrets: PetSecretStore, browser: PetAuthBrowser?,
                makeTransport: @escaping () -> WebSocketTransport, executor: PetCommandExecuting?,
                random: RandomBytesSource = SystemRandomBytes(), now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.http = http
        self.secrets = secrets
        self.browser = browser
        self.makeTransport = makeTransport
        self.executor = executor
        self.random = random
        self.now = now
        auth = PetAuth(config: settings.oidc, scope: settings.accountScope, http: http, secrets: secrets, random: random, now: now)
        state.auth = auth.isSignedIn ? .signedIn : .signedOut
        state.lastInteraction = now()
    }

    /// Test helper: waits until queued work ran.
    public func flush() { queue.sync {} }

    public var snapshot: PetSessionState { queue.sync { state } }

    private func publish() { onChange?(state) }

    // MARK: lifecycle

    /// The chat was opened: connect if signed in (once; later calls only refresh the interaction time).
    public func open() {
        queue.async {
            self.state.lastInteraction = self.now()
            self.opened = true
            if self.state.auth == .signedIn, self.chat == nil { self.connectChat() }
            self.publish()
        }
    }

    public func touch() {
        queue.async {
            self.state.lastInteraction = self.now()
            self.publish()
        }
    }

    public func reconnect() {
        queue.async {
            self.refreshTried = false
            self.dropClients(keepChat: false)
            if self.state.auth == .signedIn { self.connectChat() } else { self.state.notice = AuthProblem.signedOut.koreanMessage }
            self.publish()
        }
    }

    /// Everything off: sockets closed, nothing scheduled. Tokens stay (signing out is separate).
    public func shutdown() {
        queue.sync {
            self.opened = false
            self.dropClients(keepChat: false)
            self.state.pending = []
            self.state.selectionTurns = [:]
            self.state.uploading = false
        }
    }

    /// New server or realm: other tokens apply, so everything restarts.
    public func apply(settings new: PetSettings) {
        queue.async {
            let scopeChanged = new.accountScope != self.settings.accountScope
            self.settings = new
            if scopeChanged {
                self.dropClients(keepChat: false)
                self.auth = PetAuth(config: new.oidc, scope: new.accountScope, http: self.http, secrets: self.secrets,
                                    random: self.random, now: self.now)
                self.state = PetSessionState()
                self.state.auth = self.auth.isSignedIn ? .signedIn : .signedOut
                if self.opened, self.state.auth == .signedIn { self.connectChat() }
            } else if !new.allowComboControl {
                self.connector?.disconnect()
                self.connector = nil
                self.connectorAgent = nil
                self.state.connector = .off
            } else if let agent = self.state.chat.agentID, self.state.chat.phase == .connected {
                self.ensureConnector(agentID: agent)
            }
            self.publish()
        }
    }

    private func dropClients(keepChat: Bool) {
        connector?.disconnect()
        connector = nil
        connectorAgent = nil
        state.connector = .off
        if !keepChat {
            chat?.disconnect()
            chat = nil
            state.chat = ChatState()
        }
    }

    // MARK: login

    public func signIn() {
        queue.async {
            guard self.state.auth != .signingIn else { return }
            guard let browser = self.browser else { self.state.notice = AuthProblem.notConfigured.koreanMessage; self.publish(); return }
            switch self.auth.begin() {
            case let .failure(p):
                self.state.auth = .failed(p.koreanMessage)
                self.publish()
            case let .success(pending):
                self.state.auth = .signingIn
                self.state.notice = nil
                self.publish()
                let auth = self.auth
                browser.authorize(url: pending.url, callbackScheme: OIDCConfig.callbackScheme) { [weak self] result in
                    guard let self = self else { return }
                    self.queue.async {
                        guard auth === self.auth else { return }  // settings changed meanwhile
                        switch result {
                        case let .failure(p): self.signInFailed(p)
                        case let .success(url):
                            auth.complete(callback: url, pending: pending) { [weak self] r in
                                guard let self = self else { return }
                                self.queue.async {
                                    guard auth === self.auth else { return }
                                    switch r {
                                    case .success:
                                        self.state.auth = .signedIn
                                        self.state.notice = nil
                                        self.refreshTried = false
                                        self.opened = true
                                        self.connectChat()
                                        self.publish()
                                    case let .failure(p): self.signInFailed(p)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func signInFailed(_ p: AuthProblem) {
        state.auth = p == .canceled ? .signedOut : .failed(p.koreanMessage)
        state.notice = p.koreanMessage
        publish()
    }

    public func signOut() {
        queue.async {
            let scope = self.settings.accountScope
            let stored = self.secrets.read(ConnectorBinding.agentKey(scope: scope)).flatMap { String(data: $0, encoding: .utf8) }
            for agent in Set([self.connectorAgent, self.state.chat.agentID, stored].compactMap { $0 }) {
                self.secrets.delete(ConnectorBinding.secretKey(scope: scope, agentID: agent))
            }
            self.secrets.delete(ConnectorBinding.agentKey(scope: scope))
            self.dropClients(keepChat: false)
            self.state.pending = []
            self.state.selectionTurns = [:]
            self.state.auth = .signedOut
            self.state.notice = "로그아웃했어요."
            self.auth.signOut()
            self.publish()
        }
    }

    // MARK: chat

    private func connectChat() {
        guard let endpoint = settings.endpoint else {
            state.notice = "서버 주소가 올바르지 않아요. 설정에서 확인해 주세요."
            return
        }
        chat?.disconnect()
        chat = nil
        let auth = self.auth
        auth.validAccessToken { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard auth === self.auth, self.chat == nil else { return }
                switch result {
                case .success:
                    let c = ChatClient(endpoint: endpoint, token: { [weak auth] in auth?.currentAccessToken },
                                       makeTransport: self.makeTransport)
                    c.onChange = { [weak self, weak c] st in
                        guard let self = self else { return }
                        self.queue.async {
                            guard let c = c, self.chat === c else { return }
                            self.chatChanged(st)
                        }
                    }
                    self.chat = c
                    c.connect()
                case .failure(.network):
                    self.state.notice = AuthProblem.network.koreanMessage
                    self.publish()
                case let .failure(p):
                    self.state.auth = .signedOut
                    self.state.notice = p == .signedOut ? p.koreanMessage : AuthProblem.rejected("").koreanMessage
                    self.publish()
                }
            }
        }
    }

    private func chatChanged(_ st: ChatState) {
        let wasDone = state.chat.lastFinishedAt
        let wasConnected = state.chat.phase == .connected
        state.chat = st
        if st.phase == .connected, !wasConnected { afterConnected() }
        if st.lastFinishedAt != wasDone, st.lastFinishedAt != nil { markRead() }
        if st.lastFinishedAt != wasDone { state.lastInteraction = now() }
        switch st.phase {
        case .connected:
            refreshTried = false
            if let agent = st.agentID { ensureConnector(agentID: agent) }
        case .authFailed:
            connector?.disconnect()
            connector = nil
            connectorAgent = nil
            state.connector = .off
            if !refreshTried {
                // The token may have expired between the check and the upgrade: one refresh, then one new connection.
                refreshTried = true
                let auth = self.auth
                auth.forceRefresh { [weak self] r in
                    guard let self = self else { return }
                    self.queue.async {
                        guard auth === self.auth else { return }
                        switch r {
                        case .success:
                            self.chat?.disconnect()
                            self.chat = nil
                            self.connectChat()
                        case .failure(.network):
                            self.state.notice = AuthProblem.network.koreanMessage
                        case .failure:
                            self.state.auth = .signedOut
                            self.state.notice = AuthProblem.rejected("").koreanMessage
                        }
                        self.publish()
                    }
                }
            }
        default:
            break
        }
        publish()
    }

    // MARK: attachments

    /// Adds a file for the next message. Returns why it was refused (Korean), or nil.
    @discardableResult
    public func attach(_ file: PetOutgoingFile) -> String? {
        queue.sync {
            guard state.pending.count < PetMedia.maxAttachments else { return MediaProblem.tooMany.koreanMessage }
            state.pending.append(PetPendingFile(id: nextPendingID, file: file))
            nextPendingID += 1
            state.lastInteraction = now()
            state.notice = nil
            publish()
            return nil
        }
    }

    public func removePending(id: Int) {
        queue.async {
            self.state.pending.removeAll { $0.id == id }
            self.publish()
        }
    }

    // MARK: send / stop

    /// Uploads the waiting files, then sends one message. `completion` gets the refusal text (Korean) or nil.
    public func send(text: String, completion: ((String?) -> Void)? = nil) {
        queue.async {
            let finish: (String?) -> Void = { msg in
                if let m = msg { self.state.notice = m }
                self.publish()
                completion?(msg)
            }
            self.state.lastInteraction = self.now()
            guard self.state.auth == .signedIn else { finish(AuthProblem.signedOut.koreanMessage); return }
            guard let chat = self.chat, self.state.chat.phase == .connected, let endpoint = self.settings.endpoint else {
                if self.chat == nil { self.connectChat() }
                finish(SendRefusal.notConnected.koreanMessage)
                return
            }
            guard !self.state.uploading else { finish("파일을 올리는 중이에요. 잠시만요."); return }
            if self.state.chat.isBusy { finish(SendRefusal.busy.koreanMessage); return }
            let files = self.state.pending
            if case let .failure(p) = OutgoingText.validate(text, allowEmpty: !files.isEmpty) { finish(p.koreanMessage); return }
            if files.isEmpty {
                if case let .failure(r) = chat.send(text: text) { finish(r.koreanMessage) } else { self.state.notice = nil; finish(nil) }
                return
            }
            self.state.uploading = true
            self.publish()
            self.upload(files.map { $0.file }, endpoint: endpoint, done: []) { result in
                self.state.uploading = false
                switch result {
                case let .failure(p):
                    if p == .unauthorized { self.state.auth = .signedOut }
                    finish(p.koreanMessage)
                case let .success(attachments):
                    guard self.chat === chat else { finish(SendRefusal.notConnected.koreanMessage); return }
                    switch chat.send(text: text, attachments: attachments) {
                    case let .failure(r): finish(r.koreanMessage)
                    case .success:
                        let sent = Set(files.map { $0.id })
                        self.state.pending.removeAll { sent.contains($0.id) }
                        self.state.notice = nil
                        finish(nil)
                    }
                }
            }
        }
    }

    /// A selection-bar request: uploads only its context file (files waiting in the composer stay there) and sends
    /// the instruction. The turn is remembered for its chip and the answer's actions.
    public func sendSelection(_ sent: PetSelectionSent, completion: @escaping (String?) -> Void) {
        queue.async {
            let finish: (String?) -> Void = { msg in
                if let m = msg { self.state.notice = m }
                self.publish()
                completion(msg)
            }
            self.state.lastInteraction = self.now()
            guard self.state.auth == .signedIn else { finish(AuthProblem.signedOut.koreanMessage); return }
            guard let chat = self.chat, self.state.chat.phase == .connected, let endpoint = self.settings.endpoint else {
                if self.chat == nil { self.connectChat() }
                finish(SendRefusal.notConnected.koreanMessage)
                return
            }
            guard !self.state.uploading else { finish("파일을 올리는 중이에요. 잠시만요."); return }
            if self.state.chat.isBusy { finish(SendRefusal.busy.koreanMessage); return }
            self.state.uploading = true
            self.publish()
            self.upload([sent.file], endpoint: endpoint, done: []) { result in
                self.state.uploading = false
                switch result {
                case let .failure(p):
                    if p == .unauthorized { self.state.auth = .signedOut }
                    finish(p.koreanMessage)
                case let .success(attachments):
                    guard self.chat === chat else { finish(SendRefusal.notConnected.koreanMessage); return }
                    switch chat.send(text: sent.instruction, attachments: attachments) {
                    case let .failure(r): finish(r.koreanMessage)
                    case let .success(id):
                        self.state.selectionTurns[id] = sent
                        self.state.notice = nil
                        finish(nil)
                    }
                }
            }
        }
    }

    /// One file after the other (on `queue`), each with a token that is fresh at that moment.
    private func upload(_ files: [PetOutgoingFile], endpoint: ServerEndpoint, done: [PetAttachment],
                        completion: @escaping (Result<[PetAttachment], MediaProblem>) -> Void) {
        guard let file = files.first else { completion(.success(done)); return }
        let auth = self.auth
        auth.validAccessToken { [weak self] tok in
            guard let self = self else { return }
            guard case let .success(token) = tok else {
                self.queue.async { completion(.failure(.unauthorized)) }
                return
            }
            PetMedia.upload(file, endpoint: endpoint, bearer: token, http: self.http) { r in
                self.queue.async {
                    switch r {
                    case let .failure(p): completion(.failure(p))
                    case let .success(a): self.upload(Array(files.dropFirst()), endpoint: endpoint, done: done + [a], completion: completion)
                    }
                }
            }
        }
    }

    public func stop() {
        queue.async { self.chat?.stop() }
    }

    // MARK: connector (window arrangement, gadget switches)

    private func ensureConnector(agentID: String) {
        guard settings.allowComboControl, let executor = executor, let endpoint = settings.endpoint else { return }
        if connectorAgent == agentID { return }  // running, being set up, or given up until the next reconnect
        if state.connector == .replaced { return }  // another device holds the slot; the user can press reconnect
        connector?.disconnect()
        connector = nil
        connectorAgent = agentID
        let key = ConnectorBinding.secretKey(scope: settings.accountScope, agentID: agentID)
        if let data = secrets.read(key), let token = String(data: data, encoding: .utf8), !token.isEmpty {
            startConnector(token: token, endpoint: endpoint, executor: executor, agentID: agentID)
            return
        }
        state.connector = .connecting
        let auth = self.auth
        auth.validAccessToken { [weak self] tok in
            guard let self = self else { return }
            guard case let .success(bearer) = tok, let req = ConnectorBinding.request(endpoint, bearer: bearer, agentID: agentID) else {
                self.queue.async { self.state.connector = .failed("커넥터 연결을 만들지 못했어요."); self.publish() }
                return
            }
            self.http.send(req) { r in
                self.queue.async {
                    guard auth === self.auth, self.connectorAgent == agentID else { return }
                    guard case let .success(resp) = r, (200..<300).contains(resp.status),
                          let token = ConnectorBinding.token(from: resp.body)
                    else {
                        self.state.connector = .failed("커넥터 연결을 만들지 못했어요.")
                        self.publish()
                        return
                    }
                    try? self.secrets.write(key, Data(token.utf8))
                    try? self.secrets.write(ConnectorBinding.agentKey(scope: self.settings.accountScope), Data(agentID.utf8))
                    self.startConnector(token: token, endpoint: endpoint, executor: executor, agentID: agentID)
                    self.publish()
                }
            }
        }
    }

    private func startConnector(token: String, endpoint: ServerEndpoint, executor: PetCommandExecuting, agentID: String) {
        let c = PetConnectorClient(url: endpoint.connectorURL, token: token, executor: executor, makeTransport: makeTransport)
        c.onChange = { [weak self, weak c] phase in
            guard let self = self else { return }
            self.queue.async {
                guard let c = c, self.connector === c else { return }
                self.state.connector = phase
                self.publish()
            }
        }
        c.onUnauthorized = { [weak self, weak c] in
            guard let self = self else { return }
            self.queue.async {
                guard let c = c, self.connector === c else { return }
                self.secrets.delete(ConnectorBinding.secretKey(scope: self.settings.accountScope, agentID: agentID))
                self.connector = nil
                self.connectorAgent = nil
                guard !self.connectorReissued else { return }
                self.connectorReissued = true
                self.ensureConnector(agentID: agentID)
            }
        }
        connector = c
        c.connect()
    }

    /// Commands Nacho ran on this Mac (diagnostics).
    public var handledCommands: [String] { queue.sync { connector?.handled ?? [] } }

    /// A fresh access token (nil when signed out) for a one-off REST call such as `GET /api/v1/me`.
    public func withAccessToken(_ body: @escaping (String?) -> Void) {
        queue.async { self.auth.validAccessToken { body(try? $0.get()) } }
    }

    // MARK: connections screen

    public func loadConnectors(completion: @escaping (Result<ConnectorOverview, ConnectorError>) -> Void) {
        queue.async {
            guard let endpoint = self.settings.endpoint else { completion(.failure(.badResponse)); return }
            let http = self.http
            self.auth.validAccessToken { tok in
                guard case let .success(token) = tok else { completion(.failure(.unauthorized)); return }
                ConnectorsAPI(endpoint: endpoint, fetcher: http, token: { token }).load(completion: completion)
            }
        }
    }
}

// MARK: - server features besides the socket (history, recovery, usage, dictation, memory, cards)

extension PetSession {
    /// Runs `body` on `queue` with calls carrying a fresh token; reports sign-in problems itself.
    private func withCalls(_ body: @escaping (PetServerCalls?) -> Void) {
        guard let endpoint = settings.endpoint else { body(nil); return }
        let auth = self.auth
        let http = self.http
        auth.validAccessToken { [weak self] tok in
            guard let self = self else { return }
            self.queue.async {
                guard auth === self.auth, case let .success(token) = tok else { body(nil); return }
                body(PetServerCalls(endpoint: endpoint, http: http, bearer: token))
            }
        }
    }

    private func failed(_ e: PetAPIError) {
        if e.isUnauthorized { state.auth = .signedOut }
        state.notice = e.text
        publish()
    }

    /// The socket is (again) usable: load the record once, then fill gaps from the delta; usage and server config.
    private func afterConnected() {
        if state.config == nil { loadClientConfig() }
        refreshUsage()
        guard let room = state.chat.roomID, !room.isEmpty else { return }
        if !state.chat.historyLoaded {
            loadHistory(roomID: room, beforeSeq: nil)
        } else {
            let since = state.chat.lastSeq
            withCalls { calls in
                calls?.delta(roomID: room, sinceSeq: since) { r in
                    self.queue.async {
                        guard case let .success(d) = r, let chat = self.chat else { return }
                        chat.update { s in
                            guard s.roomID == room else { return }
                            s.recover(d.messages)
                        }
                    }
                }
            }
        }
    }

    private func loadHistory(roomID: String, beforeSeq: Int?) {
        guard !state.loadingHistory else { return }
        state.loadingHistory = true
        publish()
        withCalls { calls in
            guard let calls = calls else { self.state.loadingHistory = false; self.publish(); return }
            calls.history(roomID: roomID, beforeSeq: beforeSeq) { r in
                self.queue.async {
                    self.state.loadingHistory = false
                    switch r {
                    case let .failure(e): self.failed(e)
                    case let .success(page):
                        self.chat?.update { s in
                            guard s.roomID == roomID else { return }
                            s.mergeHistory(page.messages, hasMore: page.hasMore, older: beforeSeq != nil)
                        }
                        self.publish()
                    }
                }
            }
        }
    }

    /// "이전 대화 더 보기": the page before the oldest message shown.
    public func loadOlderHistory() {
        queue.async {
            guard let room = self.state.chat.roomID, !room.isEmpty, self.state.chat.hasMoreHistory else { return }
            let oldest = self.state.chat.history.compactMap { $0.seq }.min()
                ?? self.state.chat.turns.compactMap { $0.userSeq }.min()
            self.loadHistory(roomID: room, beforeSeq: oldest)
        }
    }

    /// The read mark follows what the pet showed, so the phone app does not count it as unread.
    private func markRead() {
        chat?.markRead(seq: state.chat.lastSeq)
    }

    public func refreshUsage() {
        queue.async {
            guard self.state.auth == .signedIn else { return }
            self.withCalls { calls in
                calls?.usage { r in
                    self.queue.async {
                        guard case let .success(u) = r else { return }
                        self.chat?.update { $0.usage = u }
                        self.state.chat.usage = u
                        self.publish()
                    }
                }
            }
        }
    }

    private func loadClientConfig() {
        guard let endpoint = settings.endpoint else { return }
        PetServerCalls(endpoint: endpoint, http: http, bearer: nil).clientConfig { r in
            self.queue.async {
                guard case let .success(c) = r else { return }
                self.state.config = c
                if let n = c.serviceNotice { self.state.notice = n }
                self.publish()
            }
        }
    }

    /// Server dictation (ADR 0014): recorded audio → text for the input field. Free; the server limits it per minute/day.
    /// `completion` (on `queue`): the text, or the Korean reason.
    public func dictate(audio: Data, mime: String, fileName: String, durationSec: Double?,
                        completion: @escaping (Result<String, PetAPIError>) -> Void) {
        queue.async {
            let config = self.state.config ?? .fallback
            let refuse: (String) -> Void = { text in completion(.failure(PetAPIError(status: 0, code: "refused", text: text))) }
            guard config.dictationEnabled else { refuse("이 서버는 받아쓰기를 지원하지 않아요."); return }
            guard !audio.isEmpty else { refuse("녹음된 소리가 없어요."); return }
            guard audio.count <= config.dictationMaxBytes else { refuse("녹음이 너무 길어요. \(config.dictationMaxSec)초 안으로 말해 주세요."); return }
            if let d = durationSec, d > Double(config.dictationMaxSec) + 1 { refuse("녹음이 너무 길어요. \(config.dictationMaxSec)초 안으로 말해 주세요."); return }
            let base = mime.split(separator: ";").first.map(String.init) ?? mime
            guard PetServerAPI.dictationTypes.contains(base) else { refuse(ErrorText.userMessage(code: "unsupported_media_type", reason: nil, fallback: "")); return }
            guard !self.state.dictating else { refuse("받아쓰는 중이에요."); return }
            self.state.dictating = true
            self.publish()
            self.withCalls { calls in
                guard let calls = calls else {
                    self.state.dictating = false
                    self.publish()
                    completion(.failure(PetAPIError(status: 401, code: "unauthorized", text: AuthProblem.signedOut.koreanMessage)))
                    return
                }
                calls.dictate(audio: audio, mime: mime, fileName: fileName, durationSec: durationSec) { r in
                    self.queue.async {
                        self.state.dictating = false
                        if case let .failure(e) = r, e.isUnauthorized { self.state.auth = .signedOut }
                        self.publish()
                        completion(r)
                    }
                }
            }
        }
    }

    // MARK: memory

    /// "잊어줘" on a "기억했어요" line: forgets its memories (undo possible for 10 seconds).
    public func forgetMemory(updateID: String) {
        queue.async {
            guard let note = self.state.chat.memoryNotes.first(where: { $0.updateID == updateID }), note.forgottenAt == nil else { return }
            let at = self.now()
            self.chat?.update { s in
                if let i = s.memoryNotes.firstIndex(where: { $0.updateID == updateID }) { s.memoryNotes[i].forgottenAt = at; s.memoryNotes[i].action = "forgotten" }
            }
            self.withCalls { calls in
                guard let calls = calls else { return }
                let group = DispatchGroup()
                var errors: [PetAPIError] = []
                for item in note.items {
                    group.enter()
                    calls.forget(memoryID: item.memoryID, kind: item.kind) { r in
                        self.queue.async {
                            if case let .failure(e) = r, e.code != "not_found" { errors.append(e) }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: self.queue) {
                    guard let e = errors.first else { return }
                    self.chat?.update { s in
                        if let i = s.memoryNotes.firstIndex(where: { $0.updateID == updateID }) {
                            s.memoryNotes[i].forgottenAt = nil
                            s.memoryNotes[i].action = note.action
                        }
                    }
                    self.failed(e)
                }
            }
        }
    }

    /// Seconds the server keeps a forgotten memory restorable (spec/memory.tsp: 10 s).
    public static let restoreWindow: TimeInterval = 10

    public func canUndoForget(updateID: String) -> Bool {
        queue.sync {
            guard let at = state.chat.memoryNotes.first(where: { $0.updateID == updateID })?.forgottenAt else { return false }
            return now().timeIntervalSince(at) < Self.restoreWindow
        }
    }

    public func undoForget(updateID: String) {
        queue.async {
            guard let note = self.state.chat.memoryNotes.first(where: { $0.updateID == updateID }), let at = note.forgottenAt else { return }
            guard self.now().timeIntervalSince(at) < Self.restoreWindow else {
                self.state.notice = ErrorText.userMessage(code: "restore_expired", reason: nil, fallback: "")
                self.publish()
                return
            }
            self.withCalls { calls in
                guard let calls = calls else { return }
                let group = DispatchGroup()
                var errors: [PetAPIError] = []
                for item in note.items {
                    group.enter()
                    calls.restore(memoryID: item.memoryID) { r in
                        self.queue.async {
                            if case let .failure(e) = r { errors.append(e) }
                            group.leave()
                        }
                    }
                }
                group.notify(queue: self.queue) {
                    if let e = errors.first { self.failed(e); return }
                    self.chat?.update { s in
                        if let i = s.memoryNotes.firstIndex(where: { $0.updateID == updateID }) {
                            s.memoryNotes[i].forgottenAt = nil
                            s.memoryNotes[i].action = "created"
                        }
                    }
                }
            }
        }
    }

    /// "기억이 틀렸어요" under an answer: a correction about the memories that answer used (or general feedback).
    public func sendMemoryFeedback(turnID: String, text: String, completion: ((String?) -> Void)? = nil) {
        queue.async {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 2000 else { completion?("고칠 내용을 2000자 안으로 써 주세요."); return }
            let turn = self.state.chat.turns.first { $0.clientMsgID == turnID }
            let ids = turn?.usedMemoryIDs ?? []
            let room = self.state.chat.roomID
            let agent = self.state.chat.agentID
            let key = "pet-fb-\(turnID)-\(String(trimmed.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }, radix: 16))"
            self.withCalls { calls in
                guard let calls = calls else { completion?(AuthProblem.signedOut.koreanMessage); return }
                calls.feedback(text: trimmed, kind: ids.isEmpty ? "preference" : "correction", memoryIDs: ids, roomID: room,
                               agentID: agent, idempotencyKey: key) { r in
                    self.queue.async {
                        switch r {
                        case .success:
                            self.state.notice = "알려 줘서 고마워요. 기억을 고칠게요."
                            self.publish()
                            completion?(nil)
                        case let .failure(e):
                            self.failed(e)
                            completion?(e.text)
                        }
                    }
                }
            }
        }
    }

    // MARK: cards

    /// Answers an approval / choice card: approve | deny | choose (+ options) | dismiss.
    public func answerCard(id: String, action: String, optionIDs: [String] = [], completion: ((String?) -> Void)? = nil) {
        queue.async {
            guard let card = self.state.chat.cards.first(where: { $0.id == id }) else { completion?("이 요청을 찾지 못했어요."); return }
            guard card.isPending else { completion?(card.statusText); return }
            self.withCalls { calls in
                guard let calls = calls else { completion?(AuthProblem.signedOut.koreanMessage); return }
                calls.answer(card: card, action: action, optionIDs: optionIDs) { r in
                    self.queue.async {
                        switch r {
                        case let .success(updated):
                            self.chat?.update { $0.upsert(card: updated) }
                            completion?(nil)
                        case let .failure(e):
                            // Closed or changed meanwhile: show the server's current card.
                            if ["already_answered", "expired", "superseded", "version_conflict"].contains(e.code ?? "") {
                                calls.http.send(.get(PetServerAPI.url(calls.endpoint, "/api/v1/chat/requests/\(id)"), bearer: calls.bearer)) { rr in
                                    guard case let .success(resp) = rr, (200..<300).contains(resp.status),
                                          let c = PetServerAPI.decodeCard(resp.body) else { return }
                                    self.chat?.update { $0.upsert(card: c) }
                                }
                            }
                            self.failed(e)
                            completion?(e.text)
                        }
                    }
                }
            }
        }
    }
}

extension PetSession: PetSelectionSending {}
