import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).

public enum ConnectionPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case authFailed
}

public enum TurnStatus: Equatable {
    case sending  // frame sent, no turn_started yet
    case streaming
    case done
    case stopped
    case failed(String)  // Korean user-facing reason
    case interrupted  // connection dropped before done
}

public struct ChatTurn: Equatable, Identifiable {
    public var id: String { clientMsgID }
    public var clientMsgID: String
    public var userText: String
    public var assistantText: String = ""
    public var status: TurnStatus = .sending
    public var stopRequested = false
    /// File names of the pictures/files sent with this turn (shown under the user's text).
    public var attachmentNames: [String] = []
}

/// Pure chat reducer: every server frame goes through `apply`, so the UI and the CLI render the same state.
public struct ChatState: Equatable {
    public var phase: ConnectionPhase = .disconnected
    public var roomID: String?
    /// The Nacho this chat talks to (`ready.agent_id`); the connector binding is issued for it.
    public var agentID: String?
    public var agentName: String = "나초"
    public var turns: [ChatTurn] = []
    public var activity: ActivityKind = .idle
    public var activeTool: String?
    public var notice: String?  // last non-turn error shown to the user

    public init() {}

    public var activeTurnIndex: Int? {
        turns.lastIndex { $0.status == .sending || $0.status == .streaming }
    }
    public var isBusy: Bool { activeTurnIndex != nil }

    /// When the last turn ended (`done`/`stopped`), for the pet's "happy" moment.
    public var lastFinishedAt: Date?

    public mutating func beginTurn(text: String, clientMsgID: String, attachmentNames: [String] = []) {
        var turn = ChatTurn(clientMsgID: clientMsgID, userText: text)
        turn.attachmentNames = attachmentNames
        turns.append(turn)
        notice = nil
    }

    public mutating func markStopRequested() {
        if let i = activeTurnIndex { turns[i].stopRequested = true }
    }

    /// Connection dropped: unfinished turns become `interrupted` (server keeps running them; see docs/PROTOCOL-NOTES.md).
    public mutating func connectionLost() {
        for i in turns.indices where turns[i].status == .sending || turns[i].status == .streaming {
            turns[i].status = .interrupted
        }
        activity = .idle
        activeTool = nil
    }

    private func index(for clientID: String?) -> Int? {
        if let c = clientID, let i = turns.lastIndex(where: { $0.clientMsgID == c }) { return i }
        if clientID == nil { return activeTurnIndex }
        return nil  // a turn of another session: not shown in this MVP
    }

    public mutating func apply(_ frame: ServerFrame) {
        switch frame.event {
        case let .ready(info):
            roomID = info.roomID
            agentID = info.agentID.isEmpty ? nil : info.agentID
            if !info.agentName.isEmpty { agentName = info.agentName }
            phase = .connected
        case let .turnStarted(_, duplicate):
            if let i = index(for: frame.clientID), turns[i].status == .sending {
                turns[i].status = duplicate ? .done : .streaming
            }
        case let .textDelta(t):
            if let i = index(for: frame.clientID) {
                if turns[i].status == .sending { turns[i].status = .streaming }
                turns[i].assistantText += t
            }
        case let .activity(kind, tool):
            activity = kind
            activeTool = kind == .tool ? tool : nil
        case let .message(m):
            // The committed assistant message is authoritative for the final text.
            if m.role == "assistant", let i = index(for: frame.clientID), !m.text.isEmpty {
                turns[i].assistantText = m.text
            }
        case .usage, .pong, .unknown:
            break
        case let .done(_, stopped):
            if let i = index(for: frame.clientID) {
                turns[i].status = stopped ? .stopped : .done
                lastFinishedAt = Date()
            }
            activity = .idle
            activeTool = nil
        case let .error(e):
            if let i = index(for: frame.clientID) ?? (frame.roomID != nil ? activeTurnIndex : nil) {
                turns[i].status = .failed(ErrorText.userMessage(code: e.code, reason: e.reason, fallback: e.message))
            } else {
                notice = ErrorText.userMessage(code: e.code, reason: e.reason, fallback: e.message)
            }
            if e.code == "unauthorized" { phase = .authFailed }
            activity = .idle
            activeTool = nil
        }
    }
}

/// Korean messages for server error codes (docs/error-codes.md). Unknown codes fall back to a generic text,
/// never the raw English server message.
public enum ErrorText {
    public static func userMessage(code: String, reason: String?, fallback: String) -> String {
        switch code {
        case "unauthorized": return "로그인이 필요해요."
        case "credits_exhausted": return "사용량이 모두 소진됐어요."
        case "light_chat_limit": return "오늘 가벼운 대화 한도에 도달했어요."
        case "invalid_input": return "보낼 수 없는 내용이에요."
        case "bad_frame": return "앱이 잘못된 요청을 보냈어요."
        case "upstream_error": return "서버가 답을 만들지 못했어요. 잠시 뒤 다시 시도해 주세요."
        case "character_unavailable": return "나초가 지금 쉬고 있어요."
        case "not_found": return "보낸 첨부를 서버에서 찾지 못했어요. 다시 붙여 주세요."
        case "task_not_startable": return "지금은 일을 맡길 수 없어요. 사용량을 확인해 주세요."
        default: return "문제가 생겼어요. (\(code))"
        }
    }
}
