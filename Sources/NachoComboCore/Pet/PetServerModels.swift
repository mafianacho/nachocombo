import Foundation

// Nacho Pet ↔ nacho-server: the parts of the server's models the pet shows. Decoded leniently from JSON objects
// (unknown fields ignored, missing optional fields = nil) so a server that adds fields never breaks the pet.
// Contract: nacho-server spec/rooms.tsp (Message, Attachment, Activity), spec/cards.tsp (CardRequest),
// spec/tasks.tsp (Task), spec/memory.tsp (MemoryUpdate), spec/usage.tsp (UsageState), spec/client-config.tsp,
// docs/ws-protocol.md §1.3, docs/error-codes.md. Read-only reference; nothing here is sent back except ids.

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? Int { return n }
        if let d = self[k] as? Double, d.isFinite, abs(d) < 9e15 { return Int(d) }
        return nil
    }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func obj(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func objs(_ k: String) -> [[String: Any]] { (self[k] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
    func strs(_ k: String) -> [String] { (self[k] as? [Any])?.compactMap { $0 as? String } ?? [] }
}

/// A file on a message: uploaded by the user, or made by Nacho (`origin: "agent"`, built-in `write_file`).
public struct PetFileLink: Equatable {
    public var attachmentID: String?
    public var name: String
    public var kind: String
    public var mime: String?
    public var bytes: Int?
    /// Signed URL (expires, default 600 s) or an external link. Nil when deleted.
    public var url: String?
    public var deleted: Bool
    public var byNacho: Bool

    static func decode(_ o: JSONObject) -> PetFileLink {
        PetFileLink(attachmentID: o.str("attachment_id"), name: o.str("name") ?? o.str("kind") ?? "file",
                    kind: o.str("kind") ?? "file", mime: o.str("mime"), bytes: o.int("bytes"), url: o.str("url"),
                    deleted: o.bool("deleted") ?? false, byNacho: o.str("origin") == "agent")
    }
}

/// A committed room message (`message` event, history, delta). `text` is the server's display text.
public struct ChatMessage: Equatable {
    public var id: String
    public var seq: Int?
    public var role: String  // user | assistant | system | tool
    public var senderKind: String?
    public var text: String
    public var clientMsgID: String?
    /// text | tool_calls | tool_result | card | system_note
    public var contentType: String
    /// system_note kind (handoff, voice_call, page_created, auto_approved …)
    public var noteKind: String?
    /// A short "still working on it" line (ADR-0021): shown as progress, folded in the record.
    public var interim: Bool
    public var taskResult: Bool
    public var taskID: String?
    public var files: [PetFileLink]
    public var usedMemoryIDs: [String]
    public var card: PetCard?
    public var createdAt: String?

    public init(id: String, seq: Int? = nil, role: String, text: String, clientMsgID: String? = nil, contentType: String = "text") {
        self.id = id
        self.seq = seq
        self.role = role
        self.text = text
        self.clientMsgID = clientMsgID
        self.contentType = contentType
        senderKind = nil
        noteKind = nil
        interim = false
        taskResult = false
        taskID = nil
        files = []
        usedMemoryIDs = []
        card = nil
        createdAt = nil
    }

    static func decode(_ m: JSONObject) -> ChatMessage {
        let content = m.obj("content") ?? [:]
        var msg = ChatMessage(id: m.str("id") ?? "", seq: m.int("seq"), role: m.str("role") ?? "", text: m.str("text") ?? "",
                              clientMsgID: m.str("client_msg_id"), contentType: content.str("type") ?? "text")
        if msg.text.isEmpty, msg.contentType == "text" || msg.contentType == "system_note" { msg.text = content.str("text") ?? "" }
        msg.senderKind = m.str("sender_kind")
        msg.noteKind = content.str("kind")
        msg.interim = m.bool("interim") ?? false
        msg.taskResult = m.bool("task_result") ?? false
        msg.taskID = m.str("task_id")
        msg.files = m.objs("attachments").map(PetFileLink.decode)
        if let a = m.obj("attachment"), let name = a.str("name") {
            msg.files.append(PetFileLink(attachmentID: a.str("file_id"), name: name, kind: a.str("kind") ?? "page", mime: nil,
                                         bytes: nil, url: nil, deleted: a.bool("deleted") ?? false, byNacho: true))
        }
        msg.usedMemoryIDs = m.strs("used_memory_ids")
        msg.card = m.obj("card").map(PetCard.decode)
        msg.createdAt = m.str("created_at")
        return msg
    }

    /// Shown in the transcript (tool messages and empty card shells are not).
    public var isVisible: Bool {
        switch contentType {
        case "tool_calls", "tool_result": return false
        default: return !(text.isEmpty && files.isEmpty && card == nil)
        }
    }
}

/// A card (approval, choice, login, OTP …). The pet answers approval and choice; the rest are pointed to the phone app.
public struct PetCard: Equatable {
    public struct Option: Equatable {
        public var id: String
        public var label: String
    }

    public var id: String
    public var kind: String
    public var status: String  // pending | answered | dismissed | expired | superseded
    public var version: Int
    public var taskID: String?
    public var title: String
    public var detail: String?
    public var options: [Option]
    public var multiple: Bool
    public var answeredAction: String?
    public var expiresAt: String?

    static func decode(_ o: JSONObject) -> PetCard {
        let p = o.obj("payload") ?? [:]
        var detail: [String] = []
        if let merchant = p.str("merchant") { detail.append(merchant) }
        if let amount = p.int("amount") { detail.append(PetText.amount(amount, currency: p.str("currency"))) }
        if let counterpart = p.str("counterpart") { detail.append(counterpart) }
        if let rev = p.str("reversibility_text") { detail.append(rev) }
        let options = p.objs("options").compactMap { opt -> Option? in
            guard let id = opt.str("id"), let label = opt.str("label") else { return nil }
            return Option(id: id, label: label)
        }
        return PetCard(id: o.str("id") ?? o.str("request_id") ?? "", kind: o.str("kind") ?? "", status: o.str("status") ?? "pending",
                       version: o.int("version") ?? 0, taskID: o.str("task_id"),
                       title: p.str("title") ?? p.str("question") ?? o.str("kind") ?? "",
                       detail: detail.isEmpty ? nil : detail.joined(separator: " · "), options: options,
                       multiple: p.bool("multiple") ?? false, answeredAction: o.str("answered_action"), expiresAt: o.str("expires_at"))
    }

    public var isPending: Bool { status == "pending" }

    /// The pet answers choices itself. Approvals (payments, calls, sending, deleting …), logins, codes and payment cards
    /// stay on the phone app until the bosses decide otherwise (PR body: "보류").
    public var answerableHere: Bool { kind == "choice" || kind == "suggestions" }

    public var statusText: String {
        switch status {
        case "answered":
            switch answeredAction {
            case "approve": return "승인했어요"
            case "submit": return "보냈어요"
            case "cancel": return "취소했어요"
            case "decline", "deny": return "거절했어요"
            case "choose": return "골랐어요"
            default: return "답했어요"
            }
        case "dismissed": return "닫았어요"
        case "expired": return "시간이 지나 만료됐어요"
        case "superseded": return "새 요청으로 바뀌었어요"
        default:
            if answerableHere { return "골라 주세요" }
            return kind == "approval" ? "휴대폰의 나초 앱에서 승인해 주세요" : "휴대폰의 나초 앱에서 이어서 해 주세요"
        }
    }
}

/// A task's state (`task_update`): what Nacho is doing outside a plain answer.
public struct PetTask: Equatable {
    public var id: String
    public var state: String  // planned queued running waiting done failed interrupted canceled
    public var title: String
    public var step: String?
    public var waitReason: String?
    public var pendingRequestID: String?
    public var failure: String?

    static func decode(_ o: JSONObject) -> PetTask {
        let step = o.obj("current_step")
        var stepText = step?.str("text")
        if let s = stepText, let i = step?.int("index"), let n = step?.int("total"), n > 0 { stepText = "\(s) (\(i)/\(n))" }
        return PetTask(id: o.str("id") ?? "", state: o.str("state") ?? "", title: o.str("title") ?? "작업",
                       step: stepText, waitReason: o.str("wait_reason"), pendingRequestID: o.str("pending_request_id"),
                       failure: o.obj("failure").map { ErrorText.userMessage(code: $0.str("code") ?? "", reason: nil, fallback: "") })
    }

    public var isOpen: Bool { ["planned", "queued", "running", "waiting"].contains(state) }

    public var statusText: String {
        switch state {
        case "planned", "queued": return "곧 시작해요"
        case "running": return step ?? "하고 있어요"
        case "waiting":
            switch waitReason {
            case "approval": return "승인을 기다려요"
            case "input": return "답을 기다려요"
            case "login", "connection", "browser": return "휴대폰 앱에서 연결·로그인이 필요해요"
            case "over_cap", "resume_confirm": return "크레딧이 채워지면 이어서 해요"
            default: return "기다리고 있어요"
            }
        case "done": return "끝냈어요"
        case "failed": return failure ?? "하지 못했어요"
        case "interrupted": return "중간에 멈췄어요 (쓴 크레딧은 돌려받아요)"
        case "canceled": return "취소했어요"
        default: return state
        }
    }
}

/// "기억했어요" (`memory_update`). One line per `update_id`.
public struct PetMemoryNote: Equatable {
    public struct Item: Equatable {
        public var memoryID: String
        public var kind: String  // fact | episode
        public var preview: String
    }

    public var updateID: String
    public var action: String  // created | updated | forgotten | restored
    public var items: [Item]
    public var source: String
    public var visibility: String?
    public var afterSeq: Int?
    /// The turn of this session it came with (nil = hub / another device).
    public var turnClientID: String?
    /// This session asked the server to forget it (undo possible for 10 s).
    public var forgottenAt: Date?

    static func decode(_ o: JSONObject) -> PetMemoryNote {
        var items = o.objs("items").compactMap { i -> Item? in
            guard let id = i.str("memory_id") else { return nil }
            return Item(memoryID: id, kind: i.str("kind") ?? "fact", preview: i.str("preview") ?? "")
        }
        if items.isEmpty {
            let kind = o.str("kind") ?? "fact"
            items = o.strs("memory_ids").map { Item(memoryID: $0, kind: kind, preview: o.str("preview") ?? "") }
        }
        return PetMemoryNote(updateID: o.str("update_id") ?? UUID().uuidString, action: o.str("action") ?? "created", items: items,
                             source: o.str("source") ?? "chat", visibility: o.str("visibility"), afterSeq: o.int("after_seq"),
                             turnClientID: nil, forgottenAt: nil)
    }

    public var text: String {
        let previews = items.map { $0.preview }.filter { !$0.isEmpty }.joined(separator: ", ")
        switch action {
        case "forgotten": return "잊었어요" + (previews.isEmpty ? "" : ": \(previews)")
        case "restored": return "다시 기억해요: \(previews)"
        case "updated": return "기억을 고쳤어요: \(previews)"
        default: return "기억했어요: \(previews)"
        }
    }
}

/// Usage in credits (`usage` event and `GET /api/v1/me/usage`). Read only: buying is on the phone app.
public struct PetUsage: Equatable {
    public var remaining: Int
    public var availableToStart: Int?
    public var blockReason: String?
    public var lightChatUsed: Int?
    public var lightChatCap: Int?
    public var planID: String?
    public var allowance: Int?
    public var period: String?
    public var resetAt: String?
    public var exhausted: Bool
    public var lowBalance: Bool

    /// From `UsageState` (REST) or the `usage` event (which carries the state too).
    static func decode(_ o: JSONObject) -> PetUsage? {
        let s = o.obj("state") ?? o
        guard let remaining = o.int("remaining") ?? s.int("remaining") else { return nil }
        var light = (o.int("light_chat_used"), o.int("light_chat_cap"))
        if light.0 == nil, let l = s.objs("limits").first(where: { $0.str("kind") == "light_chat" }) {
            light = (l.int("used"), l.int("cap"))
        }
        return PetUsage(remaining: remaining, availableToStart: o.int("available_to_start") ?? s.int("available_to_start"),
                        blockReason: o.str("block_reason") ?? s.str("block_reason"), lightChatUsed: light.0, lightChatCap: light.1,
                        planID: s.str("plan_id"), allowance: s.int("allowance"), period: s.str("period"), resetAt: s.str("reset_at"),
                        exhausted: s.bool("exhausted") ?? false, lowBalance: s.bool("low_balance") ?? false)
    }

    public var summary: String {
        var parts: [String] = []
        let n = PetText.number
        if let a = allowance, a > 0 { parts.append("크레딧 \(n(remaining))/\(n(a))") } else { parts.append("크레딧 \(n(remaining))") }
        if let u = lightChatUsed, let c = lightChatCap, c > 0 { parts.append("가벼운 대화 \(n(u))/\(n(c))") }
        if let r = blockReason { parts.append(ErrorText.blockReason(r)) } else if exhausted { parts.append("모두 썼어요") }
        else if lowBalance { parts.append("얼마 안 남았어요") }
        return parts.joined(separator: " · ")
    }
}

/// `GET /client/config` (no sign-in): what the server offers right now.
public struct PetClientConfig: Equatable {
    public var dictationEnabled: Bool
    public var dictationMaxSec: Int
    public var dictationMaxBytes: Int
    public var mediaMaxBytes: Int
    public var serviceState: String
    public var serviceMessage: String?

    public static let fallback = PetClientConfig(dictationEnabled: false, dictationMaxSec: 60, dictationMaxBytes: 2_000_000,
                                                 mediaMaxBytes: PetMedia.maxUploadBytes, serviceState: "ok", serviceMessage: nil)

    public static func decode(_ data: Data) -> PetClientConfig? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return nil }
        let d = o.obj("dictation") ?? [:]
        let status = o.obj("service_status") ?? [:]
        return PetClientConfig(dictationEnabled: d.bool("enabled") ?? false, dictationMaxSec: max(1, d.int("max_sec") ?? 60),
                               dictationMaxBytes: max(1, d.int("max_bytes") ?? 2_000_000),
                               mediaMaxBytes: max(1, o.int("media_max_bytes") ?? PetMedia.maxUploadBytes),
                               serviceState: status.str("state") ?? "ok", serviceMessage: status.str("message"))
    }

    public var serviceNotice: String? {
        switch serviceState {
        case "maintenance": return "나초 서버 점검 중이에요." + (serviceMessage.map { " \($0)" } ?? "")
        case "service_ended": return "나초 서비스가 끝났어요." + (serviceMessage.map { " \($0)" } ?? "")
        case "degraded": return "나초 서버가 느릴 수 있어요."
        default: return nil
        }
    }
}

/// The 11 activity tool keys the app shows (spec/rooms.tsp ActivityTool), in Korean.
public enum ActivityText {
    public static func label(_ kind: ActivityKind, tool: String?) -> String {
        switch kind {
        case .thinking: return "생각하는 중"
        case .typing: return "답하는 중"
        case .retrying: return "다시 해 보는 중"
        case .idle: return "쉬는 중"
        case .tool:
            switch tool {
            case "search_web": return "웹에서 찾는 중"
            case "read_page": return "페이지 읽는 중"
            case "browse_web": return "웹을 둘러보는 중"
            case "remember": return "기억을 떠올리는 중"
            case "read_files": return "자료 읽는 중"
            case "write_files": return "파일 만드는 중"
            case "run_command": return "명령 실행하는 중"
            case "look_camera": return "사진 보는 중"
            case "delegate": return "다른 나초에게 맡기는 중"
            case "guide": return "안내 준비하는 중"
            case "stop": return "멈추는 중"
            default: return "도구 쓰는 중"
            }
        }
    }
}
