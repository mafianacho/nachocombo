import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa); extended with the room record (history/delta),
// tool progress, cards, tasks, memory notes and usage (nacho-server docs/ws-protocol.md §1.3, §1.6).

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

/// One tool call of a turn (`tool_call_started` / `tool_call_finished`).
public struct ToolStep: Equatable {
    public var callID: String
    public var name: String
    public var finished = false
    public var isError = false
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
    /// Seq of the stored user message / Nacho's answer (from `message` events).
    public var userSeq: Int?
    public var answerSeq: Int?
    /// "찾아보고 있어요" lines while the turn runs (interim messages, ADR-0021).
    public var progress: [String] = []
    public var tools: [ToolStep] = []
    /// Files on Nacho's answer (e.g. made with `write_file`).
    public var files: [PetFileLink] = []
    /// Memories the answer used (for "this memory is wrong" feedback).
    public var usedMemoryIDs: [String] = []
    /// Cards this turn raised.
    public var cardIDs: [String] = []
    public var taskID: String?
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

    /// Messages of the room that are not turns of this session: the record before, other devices, tasks.
    public var history: [ChatMessage] = []
    /// There are older messages than `history` holds (load with `before_seq`).
    public var hasMoreHistory = false
    /// The record was loaded once for this room.
    public var historyLoaded = false
    /// Cards by id, in arrival order.
    public var cards: [PetCard] = []
    public var task: PetTask?
    /// Every task this chat has heard of (`task_update`, start/cancel answers, lookups for plan notes), by id.
    public var tasks: [String: PetTask] = [:]
    /// [시작] / [취소] pressed and not answered yet, by task id ("start" | "cancel"): the buttons are off meanwhile.
    public var taskActions: [String: String] = [:]
    /// One line under a plan card after a refused start/cancel or a changed estimate, by task id.
    public var taskNotices: [String: String] = [:]
    public var usage: PetUsage?
    public var memoryNotes: [PetMemoryNote] = []
    /// Last notification worth a line (credits granted, connector events …).
    public var lastNotification: String?

    public init() {}

    public var activeTurnIndex: Int? {
        turns.lastIndex { $0.status == .sending || $0.status == .streaming }
    }
    public var isBusy: Bool { activeTurnIndex != nil }

    /// When the last turn ended (`done`/`stopped`), for the pet's "happy" moment.
    public var lastFinishedAt: Date?

    /// Highest seq seen in this room (for `delta?since_seq=` and the read mark).
    public var lastSeq: Int {
        max(history.compactMap { $0.seq }.max() ?? 0, turns.flatMap { [$0.userSeq, $0.answerSeq] }.compactMap { $0 }.max() ?? 0)
    }

    public var pendingCards: [PetCard] { cards.filter { $0.isPending } }

    public mutating func beginTurn(text: String, clientMsgID: String, attachmentNames: [String] = []) {
        var turn = ChatTurn(clientMsgID: clientMsgID, userText: text)
        turn.attachmentNames = attachmentNames
        turns.append(turn)
        notice = nil
        if let t = task, !t.isOpen { task = nil }
    }

    public mutating func markStopRequested() {
        if let i = activeTurnIndex { turns[i].stopRequested = true }
    }

    /// Connection dropped: unfinished turns become `interrupted`. The server keeps running them; `recover` fills them
    /// in from the delta after reconnecting.
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
        return nil  // a turn of another session
    }

    public mutating func upsert(card: PetCard) {
        if let i = cards.firstIndex(where: { $0.id == card.id }) {
            if card.version >= cards[i].version { cards[i] = card }
        } else {
            cards.append(card)
        }
    }

    private mutating func addHistory(_ m: ChatMessage) {
        if let c = m.card { upsert(card: c) }
        guard m.isVisible, !m.interim else { return }
        if let i = history.firstIndex(where: { $0.id == m.id }) { history[i] = m; return }
        history.append(m)
        history.sort { ($0.seq ?? Int.max) < ($1.seq ?? Int.max) }
    }

    /// A stored message: to the turn of this session it belongs to, or to the room record.
    public mutating func take(_ m: ChatMessage, clientID: String?) {
        if m.role == "user", let c = m.clientMsgID, let i = turns.lastIndex(where: { $0.clientMsgID == c }) {
            turns[i].userSeq = m.seq
            return
        }
        // Turns handed to a task get their answer later through the hub, without client_id: match by task_id.
        let byTask = m.taskID.flatMap { t in turns.lastIndex { $0.taskID == t } }
        guard let i = clientID.flatMap({ c in turns.lastIndex { $0.clientMsgID == c } }) ?? (m.role == "user" ? nil : byTask) else {
            addHistory(m)
            return
        }
        if let c = m.card {
            upsert(card: c)
            if !turns[i].cardIDs.contains(c.id) { turns[i].cardIDs.append(c.id) }
            return
        }
        if m.interim {
            if !m.text.isEmpty, turns[i].progress.last != m.text { turns[i].progress.append(m.text) }
            return
        }
        guard m.role == "assistant", m.contentType == "text" else {
            if m.contentType == "system_note" { addHistory(m) }
            return
        }
        // The committed answer is authoritative for the final text.
        if !m.text.isEmpty { turns[i].assistantText = m.text }
        turns[i].answerSeq = m.seq
        turns[i].files = m.files
        turns[i].usedMemoryIDs = m.usedMemoryIDs
        if let t = m.taskID { turns[i].taskID = t }
    }

    public mutating func apply(_ frame: ServerFrame) {
        switch frame.event {
        case let .ready(info):
            if roomID != nil, roomID != info.roomID { history = []; historyLoaded = false; hasMoreHistory = false }
            roomID = info.roomID
            agentID = info.agentID.isEmpty ? nil : info.agentID
            if !info.agentName.isEmpty { agentName = info.agentName }
            phase = .connected
        case let .turnStarted(_, duplicate):
            if let i = index(for: frame.clientID) {
                if turns[i].status == .sending { turns[i].status = duplicate ? .done : .streaming }
                if let t = frame.taskID { turns[i].taskID = t }
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
            take(m, clientID: frame.clientID)
        case let .usage(u):
            usage = u
        case let .toolStarted(callID, name):
            if let i = index(for: frame.clientID), !turns[i].tools.contains(where: { $0.callID == callID }) {
                turns[i].tools.append(ToolStep(callID: callID, name: name))
            }
        case let .toolFinished(callID, name, isError, _):
            if let i = index(for: frame.clientID) {
                if let j = turns[i].tools.firstIndex(where: { $0.callID == callID }) {
                    turns[i].tools[j].finished = true
                    turns[i].tools[j].isError = isError
                } else {
                    turns[i].tools.append(ToolStep(callID: callID, name: name, finished: true, isError: isError))
                }
            }
        case let .card(c):
            upsert(card: c)
            if let ci = frame.clientID, let i = turns.lastIndex(where: { $0.clientMsgID == ci }), !turns[i].cardIDs.contains(c.id) {
                turns[i].cardIDs.append(c.id)
            }
        case let .task(t):
            applyTask(t, current: true)
            if let ci = frame.clientID, let i = turns.lastIndex(where: { $0.clientMsgID == ci }), turns[i].taskID == nil { turns[i].taskID = t.id }
        case var .memory(note):
            note.turnClientID = frame.clientID
            applyMemory(note)
        case let .notification(kind, title, body):
            if ["credit_granted", "payment_confirmed", "usage_low"].contains(kind) || kind.hasPrefix("connector_") {
                lastNotification = body.map { "\(title) — \($0)" } ?? title
            }
        case .pong, .unknown:
            break
        case let .done(_, stopped):
            if let i = index(for: frame.clientID) {
                if let t = frame.taskID { turns[i].taskID = t }
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

    /// A task's new state. `current` (a `task_update`) makes it the header's task; an answer to start/cancel or a
    /// lookup only refreshes the header when it is already about that task. An older version never wins.
    public mutating func applyTask(_ t: PetTask, current: Bool = false) {
        guard !t.id.isEmpty else { return }
        if let old = tasks[t.id], old.version > 0, t.version > 0, t.version < old.version { return }
        tasks[t.id] = t
        if current || task == nil || task?.id == t.id { task = t }
        if !t.needsStartConfirm { taskNotices[t.id] = nil }
    }

    /// The plan note (`system_note` kind `plan`) the server posts for a task it holds until the user starts it.
    public func planNote(taskID: String) -> ChatMessage? {
        history.last { $0.noteKind == "plan" && $0.taskID == taskID }
    }

    /// A `memory_update`: new lines are added; the user's own forget/undo (echoed by the hub) updates its line.
    public mutating func applyMemory(_ incoming: PetMemoryNote) {
        var note = incoming
        if let i = memoryNotes.firstIndex(where: { $0.updateID == note.updateID }) {
            note.forgottenAt = memoryNotes[i].forgottenAt
            if note.turnClientID == nil { note.turnClientID = memoryNotes[i].turnClientID }
            memoryNotes[i] = note
        } else if note.action == "forgotten" || note.action == "restored",
                  let i = memoryNotes.lastIndex(where: { old in old.items.contains { o in note.items.contains { $0.memoryID == o.memoryID } } }) {
            memoryNotes[i].action = note.action == "restored" ? "created" : "forgotten"
            if note.action == "restored" { memoryNotes[i].forgottenAt = nil }
        } else {
            memoryNotes.append(note)
        }
        if memoryNotes.count > 50 { memoryNotes.removeFirst(memoryNotes.count - 50) }
    }

    // MARK: the room record (REST)

    /// A page of `GET /rooms/{id}/history?view=app`. `older` = scrolled up (`before_seq`), else the latest page.
    public mutating func mergeHistory(_ page: [ChatMessage], hasMore: Bool, older: Bool) {
        let mine = Set(turns.map { $0.clientMsgID })
        for m in page {
            if let c = m.clientMsgID, mine.contains(c) { continue }
            // Answers to turns of this session are already shown in the turn.
            if let s = m.seq, turns.contains(where: { $0.answerSeq == s }) { continue }
            addHistory(m)
        }
        if older || !historyLoaded { hasMoreHistory = hasMore }
        historyLoaded = true
    }

    /// `GET /rooms/{id}/delta` after reconnecting: interrupted turns get the answer the server finished meanwhile,
    /// everything else goes to the record.
    public mutating func recover(_ messages: [ChatMessage]) {
        // The turn of this session whose user message came last. The delta starts after the last seq seen, so when the
        // server's echo of the question arrived before the drop, only the answer is in it: start with that turn.
        var current: Int? = turns.lastIndex { ($0.status == .interrupted || $0.status == .sending) && $0.userSeq != nil && $0.answerSeq == nil }
        for m in messages.sorted(by: { ($0.seq ?? 0) < ($1.seq ?? 0) }) {
            if m.role == "user" {
                if let c = m.clientMsgID, let i = turns.lastIndex(where: { $0.clientMsgID == c }) {
                    turns[i].userSeq = m.seq
                    current = i
                    continue
                }
                current = nil
            }
            if let i = current, m.role != "user" {
                let wasAnswer = m.role == "assistant" && !m.interim && m.contentType == "text"
                take(m, clientID: turns[i].clientMsgID)
                if wasAnswer, turns[i].status == .interrupted || turns[i].status == .sending { turns[i].status = .done }
                continue
            }
            if let s = m.seq, turns.contains(where: { $0.answerSeq == s || $0.userSeq == s }) { continue }
            addHistory(m)
        }
    }
}

/// Korean messages for server error codes (nacho-server docs/error-codes.md). The pet branches on `code` and
/// `reason` only and never shows the server's English `message`.
public enum ErrorText {
    public static func userMessage(code: String, reason: String?, fallback: String) -> String {
        switch code {
        case "unauthorized": return "로그인이 필요해요."
        case "validation_error": return "입력을 다시 확인해 주세요."
        case "invalid_input":
            if reason == "reply_to" { return "답장할 메시지를 찾지 못했어요." }
            return "보낼 수 없는 내용이에요."
        case "bad_frame": return "앱이 잘못된 요청을 보냈어요. 앱을 업데이트해 주세요."
        case "credits_exhausted": return reason.map(blockReason) ?? "사용량이 모두 소진됐어요."
        case "task_not_startable": return "지금은 일을 맡길 수 없어요. " + (reason.map(blockReason) ?? "사용량을 확인해 주세요.")
        case "light_chat_limit": return "오늘 가벼운 대화 한도에 도달했어요."
        case "quota_exceeded": return "이번 사용량을 다 썼어요."
        case "phone_verification_required": return "전화번호 인증이 필요해요. 휴대폰의 나초 앱에서 인증해 주세요."
        case "forbidden": return "이 기능은 쓸 수 없어요."
        case "suspended": return "이용이 제한된 계정이에요."
        case "account_deleting": return "삭제 중인 계정이에요."
        case "not_member": return "이 대화방에 들어갈 수 없어요."
        case "not_found": return "보낸 첨부를 서버에서 찾지 못했어요. 다시 붙여 주세요."
        case "conflict": return "이미 처리된 요청이에요."
        case "version_conflict": return "다른 곳에서 먼저 바뀌었어요. 새로 불러올게요."
        case "expired": return "시간이 지나 만료됐어요."
        case "superseded": return "새 요청으로 바뀌었어요."
        case "already_answered": return "이미 답한 요청이에요."
        case "character_unavailable", "agent_unavailable":
            return reason == "deleting" ? "이 나초는 지워지는 중이에요." : "나초가 지금 쉬고 있어요."
        case "connection_required": return "먼저 서비스 연결이 필요해요. 휴대폰의 나초 앱에서 연결해 주세요."
        case "connection_needs_reauth": return "연결한 서비스에 다시 로그인해야 해요."
        case "scope_blocked": return "허락한 범위 밖이라 하지 않았어요."
        case "run_active": return "진행 중인 단톡 일을 먼저 끝내 주세요."
        case "payload_too_large": return "파일이 너무 커요."
        case "unsupported_media_type": return "이 녹음 형식은 받을 수 없어요. 글로 써 주세요."
        case "restore_expired": return "되돌릴 수 있는 시간이 지났어요."
        case "too_many_requests":
            return "잠시 너무 많이 요청했어요." + (reason.flatMap(retryAt).map { " \($0)에 다시 해 주세요." } ?? " 잠시 뒤 다시 해 주세요.")
        case "internal_error": return "일시적인 문제가 생겼어요. 다시 시도해 주세요."
        case "not_implemented": return "아직 서버에서 준비되지 않은 기능이에요."
        case "upstream_error", "transport": return "서버가 답을 만들지 못했어요. 잠시 뒤 다시 시도해 주세요."
        case "outcome_unknown": return "보냈는지 확인이 필요해요. 다시 보내기 전에 결과를 확인해 주세요."
        case "service_disabled": return "지금은 쓸 수 없는 기능이에요."
        case "agent_limit": return "만들 수 있는 나초 수를 넘었어요."
        case "payment_error": return "결제가 되지 않았어요. 휴대폰의 나초 앱에서 확인해 주세요."
        case "estimate_changed": return "예상 사용량이 바뀌었어요. 휴대폰의 나초 앱에서 다시 확인해 주세요."
        case "connector_unavailable": return "이 맥의 나초 콤보 연결이 끊겼어요."
        case "vault_not_ready": return "금고가 아직 준비되지 않았어요."
        default: return "문제가 생겼어요. (\(code))"
        }
    }

    /// BlockReason (usage.block_reason; the reason of credits_exhausted / task_not_startable).
    public static func blockReason(_ r: String) -> String {
        switch r {
        case "credits_exhausted": return "크레딧이 모자라요."
        case "heavy_daily_limit": return "오늘 맡길 수 있는 큰 일을 다 썼어요."
        case "free_call_limit": return "오늘 무료 전화를 다 썼어요."
        case "plan_cost_cap": return "이번 달 사용 한도에 닿았어요."
        case "refund_review": return "환급을 확인하는 동안 잠시 멈췄어요."
        case "phone_verification_required": return "전화번호를 인증하면 무료 크레딧을 받아요."
        case "light_chat_limit": return "오늘 가벼운 대화 한도에 도달했어요."
        default: return "지금은 맡길 수 없어요."
        }
    }

    /// `too_many_requests` reason = RFC 3339 time it is allowed again → local "a h:mm" text; nil if not a time.
    public static func retryAt(_ reason: String) -> String? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = frac.date(from: reason) ?? ISO8601DateFormatter().date(from: reason) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "ko_KR")
        out.dateFormat = Calendar.current.isDateInToday(d) ? "a h:mm" : "M월 d일 a h:mm"
        return out.string(from: d)
    }

    /// `{"error":{"code","message","reason"}}` of a REST answer, in Korean.
    public static func fromBody(_ data: Data, status: Int) -> String {
        if let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let e = o["error"] as? [String: Any],
           let code = e["code"] as? String {
            return userMessage(code: code, reason: e["reason"] as? String, fallback: "")
        }
        switch status {
        case 401: return userMessage(code: "unauthorized", reason: nil, fallback: "")
        case 404: return "찾지 못했어요."
        case 413: return userMessage(code: "payload_too_large", reason: nil, fallback: "")
        case 429: return userMessage(code: "too_many_requests", reason: nil, fallback: "")
        case 500...: return userMessage(code: "internal_error", reason: nil, fallback: "")
        default: return "문제가 생겼어요. (HTTP \(status))"
        }
    }
}
