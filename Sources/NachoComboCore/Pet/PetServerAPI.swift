import Foundation

// Nacho Pet ↔ nacho-server REST calls the pet makes besides the chat socket. Contract (nacho-server origin/main):
//   GET  /api/v1/rooms/{id}/history?view=app&limit&before_seq   → Message[] + header X-Has-More   (spec/rooms.tsp)
//   GET  /api/v1/rooms/{id}/delta?view=app&since_seq            → RoomDelta {messages,last_seq,read_seq,has_more}
//   read mark: WS frame {type:read,room_id,seq} (PetChatClient.markRead)
//   GET  /api/v1/me/usage                                       → UsageState                      (spec/usage.tsp)
//   GET  /client/config  (no token)                             → ClientConfig                    (spec/client-config.tsp)
//   POST /api/v1/dictation  multipart file/language/duration_sec → {text,language,duration_sec?}   (spec/dictation.tsp, ADR 0014)
//   POST /api/v1/memory/feedback {text,kind,memory_ids,room_id} + Idempotency-Key → 201 FeedbackOutcome (spec/memory.tsp)
//   DELETE /api/v1/memory/facts|episodes/{id} → 204;  POST /api/v1/memory/{id}/restore → 200 | 410 restore_expired
//   POST /api/v1/chat/requests/{id}/answer {action,option_id?,option_ids?,expected_version} → CardRequest (spec/cards.tsp)
// Errors: {"error":{"code","message","reason?"}} (docs/error-codes.md) → ErrorText.

public struct PetAPIError: Error, Equatable {
    public var status: Int  // 0 = no answer (network)
    public var code: String?
    public var text: String  // Korean, for the user

    public static let network = PetAPIError(status: 0, code: nil, text: "서버에 연결하지 못했어요. 네트워크를 확인해 주세요.")
    public static let badResponse = PetAPIError(status: 0, code: "bad_response", text: "서버 응답을 읽지 못했어요.")

    static func from(_ resp: PetHTTPResponse) -> PetAPIError {
        PetAPIError(status: resp.status, code: PetServerError.code(resp.body), text: ErrorText.fromBody(resp.body, status: resp.status))
    }

    public var isUnauthorized: Bool { status == 401 || code == "unauthorized" }
}

public struct PetHistoryPage: Equatable {
    public var messages: [ChatMessage]
    public var hasMore: Bool
}

public struct PetDelta: Equatable {
    public var messages: [ChatMessage]
    public var lastSeq: Int
    public var readSeq: Int
    public var hasMore: Bool
    public var activity: ActivityKind?
}

public enum PetServerAPI {
    public static let historyPageSize = 50

    static func url(_ endpoint: ServerEndpoint, _ path: String, query: [(String, String)] = []) -> URL {
        var c = URLComponents(url: endpoint.rest(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        return c.url!
    }

    // MARK: requests (pure; tested against the contract)

    public static func historyRequest(_ e: ServerEndpoint, bearer: String?, roomID: String, beforeSeq: Int?,
                                      limit: Int = historyPageSize) -> PetHTTPRequest {
        var q = [("view", "app"), ("limit", String(limit))]
        if let b = beforeSeq { q.append(("before_seq", String(b))) }
        return .get(url(e, "/api/v1/rooms/\(roomID)/history", query: q), bearer: bearer)
    }

    public static func deltaRequest(_ e: ServerEndpoint, bearer: String?, roomID: String, sinceSeq: Int) -> PetHTTPRequest {
        .get(url(e, "/api/v1/rooms/\(roomID)/delta", query: [("view", "app"), ("since_seq", String(sinceSeq))]), bearer: bearer)
    }

    public static func usageRequest(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        .get(url(e, "/api/v1/me/usage"), bearer: bearer)
    }

    public static func clientConfigRequest(_ e: ServerEndpoint) -> PetHTTPRequest {
        .get(url(e, "/client/config"), bearer: nil)
    }

    /// Multipart: `file` (the audio, with its Content-Type), `language`, `duration_sec`.
    public static func dictationRequest(_ e: ServerEndpoint, bearer: String?, audio: Data, mime: String, fileName: String,
                                        language: String, durationSec: Double?, boundary: String) -> PetHTTPRequest {
        var body = Data()
        func part(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        part("language", language)
        if let d = durationSec { part("duration_sec", String(format: "%.2f", d)) }
        body.append(Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
                          + "Content-Type: \(mime)\r\n\r\n").utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var h = ["Accept": "application/json", "Content-Type": "multipart/form-data; boundary=\(boundary)"]
        if let b = bearer { h["Authorization"] = "Bearer \(b)" }
        return PetHTTPRequest(method: "POST", url: url(e, "/api/v1/dictation"), headers: h, body: body)
    }

    /// "이 기억이 틀렸어요": a correction about the memories an answer used.
    public static func feedbackRequest(_ e: ServerEndpoint, bearer: String?, text: String, kind: String, memoryIDs: [String],
                                       roomID: String?, agentID: String?, idempotencyKey: String) -> PetHTTPRequest {
        var json: [String: Any] = ["text": text, "kind": kind]
        if !memoryIDs.isEmpty { json["memory_ids"] = memoryIDs }
        if let r = roomID { json["room_id"] = r }
        if let a = agentID { json["agent_id"] = a }
        var r = PetHTTPRequest.postJSON(url(e, "/api/v1/memory/feedback"), bearer: bearer, json: json)
        r.headers["Idempotency-Key"] = idempotencyKey
        return r
    }

    public static func forgetRequest(_ e: ServerEndpoint, bearer: String?, memoryID: String, kind: String) -> PetHTTPRequest {
        var r = PetHTTPRequest.get(url(e, "/api/v1/memory/\(kind == "episode" ? "episodes" : "facts")/\(memoryID)"), bearer: bearer)
        r.method = "DELETE"
        return r
    }

    public static func restoreRequest(_ e: ServerEndpoint, bearer: String?, memoryID: String) -> PetHTTPRequest {
        .postJSON(url(e, "/api/v1/memory/\(memoryID)/restore"), bearer: bearer, json: [:])
    }

    /// approval: approve | deny · choice/suggestions: choose (+ option_id / option_ids) · any: dismiss.
    public static func answerCardRequest(_ e: ServerEndpoint, bearer: String?, card: PetCard, action: String,
                                         optionIDs: [String] = []) -> PetHTTPRequest {
        var json: [String: Any] = ["action": action, "expected_version": card.version]
        if card.multiple, !optionIDs.isEmpty { json["option_ids"] = optionIDs } else if let o = optionIDs.first { json["option_id"] = o }
        return .postJSON(url(e, "/api/v1/chat/requests/\(card.id)/answer"), bearer: bearer, json: json)
    }

    /// `GET /api/v1/tasks/{id}` → Task (spec/tasks.tsp).
    public static func taskRequest(_ e: ServerEndpoint, bearer: String?, taskID: String) -> PetHTTPRequest {
        .get(url(e, "/api/v1/tasks/\(taskID)"), bearer: bearer)
    }

    /// `POST /api/v1/tasks/{id}/start {expected_estimate_id}` → Task, or 409 `estimate_changed` with the task
    /// carrying the new estimate. Not planned → the current task (idempotent).
    public static func startTaskRequest(_ e: ServerEndpoint, bearer: String?, taskID: String, expectedEstimateID: String?) -> PetHTTPRequest {
        var json: [String: Any] = [:]
        if let id = expectedEstimateID { json["expected_estimate_id"] = id }
        return .postJSON(url(e, "/api/v1/tasks/\(taskID)/start"), bearer: bearer, json: json)
    }

    /// `POST /api/v1/tasks/{id}/cancel` → Task (canceled; already ended → the current task).
    public static func cancelTaskRequest(_ e: ServerEndpoint, bearer: String?, taskID: String) -> PetHTTPRequest {
        .postJSON(url(e, "/api/v1/tasks/\(taskID)/cancel"), bearer: bearer, json: [:])
    }

    // MARK: decoding

    public static func decodeHistory(_ resp: PetHTTPResponse) -> PetHistoryPage? {
        guard let arr = (try? JSONSerialization.jsonObject(with: resp.body)) as? [Any] else { return nil }
        let messages = arr.compactMap { $0 as? JSONObject }.map(ChatMessage.decode)
        return PetHistoryPage(messages: messages, hasMore: resp.header("X-Has-More")?.lowercased() == "true")
    }

    public static func decodeDelta(_ data: Data) -> PetDelta? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject, let msgs = o["messages"] as? [Any] else { return nil }
        let activity = o.obj("activity")?.str("kind").flatMap(ActivityKind.init(rawValue:))
        return PetDelta(messages: msgs.compactMap { $0 as? JSONObject }.map(ChatMessage.decode), lastSeq: o.int("last_seq") ?? 0,
                        readSeq: o.int("read_seq") ?? 0, hasMore: o.bool("has_more") ?? false, activity: activity)
    }

    public static func decodeUsage(_ data: Data) -> PetUsage? {
        (try? JSONSerialization.jsonObject(with: data) as? JSONObject).flatMap { $0 }.flatMap(PetUsage.decode)
    }

    public static func decodeDictation(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? JSONObject)?.str("text")
    }

    public static func decodeCard(_ data: Data) -> PetCard? {
        ((try? JSONSerialization.jsonObject(with: data)) as? JSONObject).map(PetCard.decode)
    }

    /// Audio types the server takes (spec/dictation.tsp DictationUpload.file).
    public static let dictationTypes = ["audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac", "audio/wav", "audio/webm", "audio/mpeg"]
}

/// Runs the requests with a bearer token and maps answers; all completions on an arbitrary queue.
public struct PetServerCalls {
    public let endpoint: ServerEndpoint
    public let http: PetHTTPClient
    public let bearer: String?

    public init(endpoint: ServerEndpoint, http: PetHTTPClient, bearer: String?) {
        self.endpoint = endpoint
        self.http = http
        self.bearer = bearer
    }

    private func run<T>(_ req: PetHTTPRequest, ok: ClosedRange<Int> = 200...299, _ decode: @escaping (PetHTTPResponse) -> T?,
                        _ completion: @escaping (Result<T, PetAPIError>) -> Void) {
        http.send(req) { r in
            switch r {
            case .failure: completion(.failure(.network))
            case let .success(resp):
                guard ok.contains(resp.status) else { completion(.failure(.from(resp))); return }
                if let v = decode(resp) { completion(.success(v)) } else { completion(.failure(.badResponse)) }
            }
        }
    }

    public func history(roomID: String, beforeSeq: Int?, completion: @escaping (Result<PetHistoryPage, PetAPIError>) -> Void) {
        run(PetServerAPI.historyRequest(endpoint, bearer: bearer, roomID: roomID, beforeSeq: beforeSeq), PetServerAPI.decodeHistory, completion)
    }

    /// Everything since `sinceSeq` (follows `has_more`, at most 5 pages = 2500 messages).
    public func delta(roomID: String, sinceSeq: Int, pages: Int = 5, collected: [ChatMessage] = [],
                      completion: @escaping (Result<PetDelta, PetAPIError>) -> Void) {
        run(PetServerAPI.deltaRequest(endpoint, bearer: bearer, roomID: roomID, sinceSeq: sinceSeq), { PetServerAPI.decodeDelta($0.body) }) { r in
            switch r {
            case let .failure(e): completion(.failure(e))
            case var .success(d):
                d.messages = collected + d.messages
                if d.hasMore, pages > 1, d.lastSeq > sinceSeq, let last = d.messages.compactMap({ $0.seq }).max(), last > sinceSeq {
                    self.delta(roomID: roomID, sinceSeq: last, pages: pages - 1, collected: d.messages, completion: completion)
                } else {
                    completion(.success(d))
                }
            }
        }
    }

    public func usage(completion: @escaping (Result<PetUsage, PetAPIError>) -> Void) {
        run(PetServerAPI.usageRequest(endpoint, bearer: bearer), { PetServerAPI.decodeUsage($0.body) }, completion)
    }

    public func clientConfig(completion: @escaping (Result<PetClientConfig, PetAPIError>) -> Void) {
        run(PetServerAPI.clientConfigRequest(endpoint), { PetClientConfig.decode($0.body) }, completion)
    }

    public func dictate(audio: Data, mime: String, fileName: String, language: String = "ko", durationSec: Double?,
                        boundary: String = "nacho-\(UUID().uuidString)", completion: @escaping (Result<String, PetAPIError>) -> Void) {
        let req = PetServerAPI.dictationRequest(endpoint, bearer: bearer, audio: audio, mime: mime, fileName: fileName,
                                                language: language, durationSec: durationSec, boundary: boundary)
        run(req, { PetServerAPI.decodeDictation($0.body) }, completion)
    }

    public func feedback(text: String, kind: String, memoryIDs: [String], roomID: String?, agentID: String?, idempotencyKey: String,
                         completion: @escaping (Result<Void, PetAPIError>) -> Void) {
        run(PetServerAPI.feedbackRequest(endpoint, bearer: bearer, text: text, kind: kind, memoryIDs: memoryIDs, roomID: roomID,
                                         agentID: agentID, idempotencyKey: idempotencyKey), { _ in () }, completion)
    }

    public func forget(memoryID: String, kind: String, completion: @escaping (Result<Void, PetAPIError>) -> Void) {
        run(PetServerAPI.forgetRequest(endpoint, bearer: bearer, memoryID: memoryID, kind: kind), { _ in () }, completion)
    }

    public func restore(memoryID: String, completion: @escaping (Result<Void, PetAPIError>) -> Void) {
        run(PetServerAPI.restoreRequest(endpoint, bearer: bearer, memoryID: memoryID), { _ in () }, completion)
    }

    public func answer(card: PetCard, action: String, optionIDs: [String], completion: @escaping (Result<PetCard, PetAPIError>) -> Void) {
        run(PetServerAPI.answerCardRequest(endpoint, bearer: bearer, card: card, action: action, optionIDs: optionIDs),
            { PetServerAPI.decodeCard($0.body) }, completion)
    }

    public func task(id: String, completion: @escaping (Result<PetTask, PetAPIError>) -> Void) {
        run(PetServerAPI.taskRequest(endpoint, bearer: bearer, taskID: id), { PetTask.decode($0.body) }, completion)
    }

    /// Start a planned task. 409 `estimate_changed` is not an error here: it carries the task with the new estimate.
    public func startTask(id: String, expectedEstimateID: String?, completion: @escaping (Result<PetTaskStart, PetAPIError>) -> Void) {
        http.send(PetServerAPI.startTaskRequest(endpoint, bearer: bearer, taskID: id, expectedEstimateID: expectedEstimateID)) { r in
            switch r {
            case .failure: completion(.failure(.network))
            case let .success(resp):
                if (200...299).contains(resp.status) {
                    completion(PetTask.decode(resp.body).map { .success(.started($0)) } ?? .failure(.badResponse))
                } else if resp.status == 409, PetServerError.code(resp.body) == "estimate_changed",
                          let o = (try? JSONSerialization.jsonObject(with: resp.body)) as? JSONObject, let t = o.obj("task") {
                    completion(.success(.estimateChanged(PetTask.decode(t))))
                } else {
                    completion(.failure(.from(resp)))
                }
            }
        }
    }

    public func cancelTask(id: String, completion: @escaping (Result<PetTask, PetAPIError>) -> Void) {
        run(PetServerAPI.cancelTaskRequest(endpoint, bearer: bearer, taskID: id), { PetTask.decode($0.body) }, completion)
    }
}

/// The answer to `POST /tasks/{id}/start`.
public enum PetTaskStart: Equatable {
    /// Started (running / queued), or the task's current state when it was not planned any more.
    case started(PetTask)
    /// Not started: the estimate changed since the user saw it; the task carries the new one.
    case estimateChanged(PetTask)
}
