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

public struct ChatMessage: Equatable {
    public var id: String
    public var seq: Int?
    public var role: String  // "user" | "assistant" | ...
    public var text: String
    public var clientMsgID: String?
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
    case usage(remaining: Int?)
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

    public init(roomID: String?, clientID: String?, event: ServerEvent) {
        self.roomID = roomID
        self.clientID = clientID
        self.event = event
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
            event = .message(
                ChatMessage(
                    id: (m["id"] as? String) ?? "", seq: m["seq"] as? Int,
                    role: (m["role"] as? String) ?? "",
                    text: (m["text"] as? String) ?? "",
                    clientMsgID: m["client_msg_id"] as? String))
        case "usage":
            event = .usage(remaining: obj["remaining"] as? Int)
        case "done":
            event = .done(messageID: str("message_id"), stopped: (obj["stopped"] as? Bool) ?? false)
        case "error":
            event = .error(ErrorInfo(code: str("code") ?? "unknown", message: str("message") ?? "", reason: str("reason")))
        case "pong":
            event = .pong
        default:
            event = .unknown(type: type)
        }
        return ServerFrame(roomID: room, clientID: client, event: event)
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
