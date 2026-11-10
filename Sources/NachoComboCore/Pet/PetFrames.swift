import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).
// WS contract: nacho-server docs/ws-protocol.md §1 (read-only reference). Unknown `type`s and fields are ignored.

public enum ActivityKind: String, Equatable {
    case thinking, typing, tool, retrying, idle
}

public struct ReadyInfo: Equatable {
    public var userID: String
    public var agentID: String
    public var agentName: String
    public var roomID: String
}

public struct ErrorInfo: Equatable {
    public var code: String
    public var message: String
    public var reason: String?
}

public enum ServerEvent: Equatable {
    case ready(ReadyInfo)
    case turnStarted(turnID: String, duplicate: Bool)
    case textDelta(String)
    case activity(ActivityKind, tool: String?)
    case message(ChatMessage)
    case usage(PetUsage)
    case toolStarted(callID: String, name: String)
    case toolFinished(callID: String, name: String, isError: Bool, durationMs: Int?)
    case card(PetCard)
    case task(PetTask)
    case memory(PetMemoryNote)
    case notification(kind: String, title: String, body: String?)
    case done(messageID: String?, stopped: Bool)
    case error(ErrorInfo)
    case pong
    case unknown(type: String)
}

/// One decoded server frame. `clientID` is present on events of a turn started by this session.
public struct ServerFrame: Equatable {
    public var roomID: String?
    public var clientID: String?
    public var event: ServerEvent
    /// `task_id` of `turn_started` / `done` (the turn was handed to a task) and of task-scoped events.
    public var taskID: String?

    public init(roomID: String?, clientID: String?, event: ServerEvent, taskID: String? = nil) {
        self.roomID = roomID
        self.clientID = clientID
        self.event = event
        self.taskID = taskID
    }

    /// Returns nil when `text` is not a JSON object with a string `type`.
    public static func decode(_ text: String) -> ServerFrame? {
        guard let data = text.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data),
            let obj = any as? [String: Any],
            let type = obj["type"] as? String
        else { return nil }
        let room = obj["room_id"] as? String
        let client = obj["client_id"] as? String
        func str(_ k: String) -> String? { obj[k] as? String }
        let event: ServerEvent
        switch type {
        case "ready":
            event = .ready(
                ReadyInfo(
                    userID: str("user_id") ?? "", agentID: str("agent_id") ?? "",
                    agentName: str("agent_name") ?? "", roomID: room ?? ""))
        case "turn_started":
            event = .turnStarted(turnID: str("turn_id") ?? "", duplicate: (obj["duplicate"] as? Bool) ?? false)
        case "text_delta":
            event = .textDelta(str("text") ?? "")
        case "activity":
            let act = obj["activity"] as? [String: Any]
            let kind = ActivityKind(rawValue: (act?["kind"] as? String) ?? "") ?? .idle
            event = .activity(kind, tool: act?["tool"] as? String)
        case "message":
            guard let m = obj["message"] as? [String: Any] else { event = .unknown(type: type); break }
            event = .message(ChatMessage.decode(m))
        case "usage":
            event = PetUsage.decode(obj).map { .usage($0) } ?? .unknown(type: type)
        case "tool_call_started":
            event = .toolStarted(callID: str("call_id") ?? "", name: str("name") ?? "")
        case "tool_call_finished":
            let meta = obj["meta"] as? [String: Any] ?? [:]
            event = .toolFinished(callID: str("call_id") ?? "", name: str("name") ?? "", isError: meta.bool("is_error") ?? false,
                                  durationMs: meta.int("duration_ms"))
        case "card_update":
            event = (obj["request"] as? [String: Any]).map { .card(PetCard.decode($0)) } ?? .unknown(type: type)
        case "task_update":
            event = (obj["task"] as? [String: Any]).map { .task(PetTask.decode($0)) } ?? .unknown(type: type)
        case "memory_update":
            event = (obj["update"] as? [String: Any]).map { .memory(PetMemoryNote.decode($0)) } ?? .unknown(type: type)
        case "notification":
            let n = obj["notification"] as? [String: Any] ?? [:]
            event = .notification(kind: n.str("kind") ?? "", title: n.str("title") ?? "", body: n.str("body"))
        case "done":
            event = .done(messageID: str("message_id"), stopped: (obj["stopped"] as? Bool) ?? false)
        case "error":
            event = .error(ErrorInfo(code: str("code") ?? "unknown", message: str("message") ?? "", reason: str("reason")))
        case "pong":
            event = .pong
        default:
            event = .unknown(type: type)
        }
        return ServerFrame(roomID: room, clientID: client, event: event, taskID: obj["task_id"] as? String)
    }
}

/// Frames the app sends.
public enum ClientFrame: Equatable {
    /// `attachmentIDs` are ids returned by `POST /api/v1/media/uploads` (sent as `attachments: [{attachment_id}]`).
    case message(text: String, roomID: String?, clientMsgID: String, attachmentIDs: [String] = [])
    case stop(roomID: String)
    case read(roomID: String, seq: Int)
    case ping

    public func encode() -> String {
        var o: [String: Any]
        switch self {
        case let .message(text, roomID, id, attachmentIDs):
            o = ["type": "message", "text": text, "client_msg_id": id, "client_id": id]
            if let r = roomID { o["room_id"] = r }
            if !attachmentIDs.isEmpty { o["attachments"] = attachmentIDs.map { ["attachment_id": $0] } }
        case let .stop(roomID):
            o = ["type": "stop", "room_id": roomID]
        case let .read(roomID, seq):
            o = ["type": "read", "room_id": roomID, "seq": seq]
        case .ping:
            o = ["type": "ping"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
