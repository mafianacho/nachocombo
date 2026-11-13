import Foundation

/// What the chat bubble shows, as a list of items in order: the same pieces as the web mockup's `scenes.js`
/// (`mine`, `nacho`, `line`, `file`, `card`, `note`, `divider`, older button, first screen). The app draws each item
/// with one view (PetChatViews.swift); the rules about what shows where live here so Linux tests cover them.
public enum PetChatItem: Equatable {
    case older(loading: Bool)
    /// First screen: a centred question and a few example requests (tap = put it in the input field).
    case hello(title: String, examples: [String])
    case mine(text: String, attachments: [String], past: Bool)
    case nacho(text: String, past: Bool, streaming: Bool)
    case line(PetChatLine)
    case files([PetFileChip], mine: Bool)
    case card(PetCardItem)
    case note(String)
    case divider(String)
    /// Selection bar: the chip under a sent request ("Safari · 고른 글 129자 · 맥락 4개").
    case requestChip(String)
    /// Selection bar: 복사 · 다시 · 보낸 내용 보기 under the answer to a request.
    case answerActions(turnID: String, showingSent: Bool)
    /// Selection bar: what that request sent (read only), after 보낸 내용 보기.
    case sentContext([PetSelectionRow])
    /// Selection bar: the preview card before anything is sent.
    case selectionPreview(PetSelectionPreview)
    /// Selection bar: the first-use card (켜기 / 나중에).
    case selectionIntro
}

/// What the selection bar adds to the chat: its preview card, the first-use card, opened "보낸 내용 보기" lists.
public struct PetSelectionChatState: Equatable {
    public var preview: PetSelectionPreview?
    public var intro = false
    public var expanded: Set<String> = []
    public init(preview: PetSelectionPreview? = nil, intro: Bool = false, expanded: Set<String> = []) {
        self.preview = preview; self.intro = intro; self.expanded = expanded
    }
}

public struct PetChatLine: Equatable {
    public enum Kind: Equatable { case tool, progress, memory, notice, danger, usage, notification }
    public var kind: Kind
    /// SF Symbol name (the web mockup's stand-in icon names map 1:1, see the PR's port table).
    public var symbol: String?
    public var parts: [PetTextPart]
    public var alignTrailing = false

    public init(kind: Kind, symbol: String?, parts: [PetTextPart], alignTrailing: Bool = false) {
        self.kind = kind; self.symbol = symbol; self.parts = parts; self.alignTrailing = alignTrailing
    }

    public var plainText: String { parts.map { $0.text }.joined() }
}

public struct PetTextPart: Equatable {
    public enum Style: Equatable { case plain, secondary, ok, failed }
    public var text: String
    public var link: URL?
    public var tooltip: String?
    public var style: Style = .plain

    public init(_ text: String, link: URL? = nil, tooltip: String? = nil, style: Style = .plain) {
        self.text = text; self.link = link; self.tooltip = tooltip; self.style = style
    }
}

public struct PetFileChip: Equatable {
    public var name: String
    public var isImage: Bool
    public var url: URL?
    public var byNacho: Bool
    public var deleted: Bool
}

public struct PetCardItem: Equatable {
    public struct Option: Equatable {
        public var label: String
        /// The click (nil = not clickable: answered, sending, or a card for the phone).
        public var link: URL?
        /// The stored answer chose it.
        public var chosen: Bool
        /// 1…N (0 = unnumbered).
        public var number: Int = 0
        public var detail: String? = nil
        public var role: PetCardRow.Role = .option
        /// Ticked (several choices) or picked with a number key (Enter sends it).
        public var marked = false
        /// A check row of a multiple choice.
        public var tickable = false
    }
    public var id: String
    public var symbol: String
    public var title: String
    public var detail: String?
    public var options: [Option]
    /// A note under the options only where it adds something the question does not say ("휴대폰에서 승인해 주세요",
    /// "골랐어요", "보내는 중…"); never "골라 주세요" under a choice.
    public var status: String?
    public var statusWaits: Bool
    public var style: PetCardStyle = .elsewhere
    /// Approval: what, the result, whether it can be undone (one line each).
    public var summary: [String] = []
    /// Several choices: the 확정 button (nil link until something is ticked).
    public var confirm: Option? = nil
    /// The number keys and the expiry time (KST) while it waits.
    public var hint: String? = nil
    /// 다시 시도 after a failed answer.
    public var retry: URL? = nil
}

public enum PetLinks {
    /// Links in the transcript: `nachopet://<action>?…` (older, forget, undo, memfb, card).
    public static func url(_ action: String, _ items: [String: String] = [:]) -> URL {
        var c = URLComponents()
        c.scheme = "nachopet"
        c.host = action
        if !items.isEmpty { c.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }
}

/// Korean text rules shared by the app and the mockup.
public enum PetText {
    /// Tool names as the user reads them; the raw name stays in the tooltip.
    public static func toolName(_ raw: String) -> String {
        switch raw {
        case "search_web": return "웹 검색"
        case "read_page": return "페이지 읽기"
        case "browse_web": return "웹 둘러보기"
        case "remember": return "기억 떠올리기"
        case "read_files": return "자료 읽기"
        case "write_files", "write_file": return "파일 만들기"
        case "run_command": return "명령 실행"
        case "look_camera": return "사진 보기"
        case "delegate": return "다른 나초에게 맡기기"
        case "guide": return "안내 준비"
        case "stop": return "멈추기"
        case PetCommands.arrangeWindow: return "창 배치"
        case PetCommands.setGadget: return "가젯 켜기·끄기"
        case PetCommands.listGadgets: return "가젯 목록 보기"
        // Desktop actions (B lane, PetCommands.swift @ feat/pet-desktop-actions 1eef601): the wire names, as literals so
        // this file does not wait for that branch.
        case "combo_list_apps": return "앱 목록 보기"
        case "combo_open_app": return "앱 열기"
        case "combo_focus_app": return "앱 전환"
        case "combo_hide_app": return "앱 숨기기"
        case "combo_quit_app": return "앱 종료"
        case "combo_list_windows": return "창 목록 보기"
        case "combo_layout_windows": return "여러 창 배치"
        case "combo_set_system": return "소리·밝기·방해금지"
        case "combo_set_dim_strength": return "디밍 강도"
        case "combo_clear_shelf": return "선반 비우기"
        case "combo_workspace_save": return "작업 공간 저장"
        case "combo_workspace_apply": return "작업 공간 적용"
        case "combo_workspace_list": return "작업 공간 목록"
        default: return "도구"
        }
    }

    /// Under a pending file's name: what it is and what Nacho can do with it ("그림 · 보여요").
    public static func pendingNote(_ f: PetOutgoingFile) -> String {
        let kind = f.mime.hasPrefix("image/") ? "그림" : (f.mime.hasPrefix("text/") ? "글" : (f.mime == "application/pdf" ? "PDF" : "파일"))
        switch f.readability {
        case .seen: return "\(kind) · 보여요"
        case .read: return "\(kind) · 읽어요"
        case .storedOnly: return "\(kind) · 전달만 돼요"
        }
    }

    /// 39000 → "39,000" (always comma groups, whatever the Mac's region).
    public static func number(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + out
    }

    /// 39000 원 → "39,000원"; other currencies keep their code: "12,000 USD".
    public static func amount(_ n: Int, currency: String?) -> String {
        guard let c = currency, !c.isEmpty, c.uppercased() != "KRW", c != "원" else { return number(n) + "원" }
        return number(n) + " " + c
    }
}

public enum PetTranscript {
    public static let examples = ["창 왼쪽으로 붙여 줘", "킵 어웨이크 켜 줘", "이 캡처 뭐야?"]

    /// The header's one status line: connection, activity or the task's state. Task and card states show here only,
    /// never again as a line in the transcript.
    public static func headerStatus(_ st: PetSessionState, selection: PetSelectionChatState = PetSelectionChatState()) -> (text: String, dot: HeaderDot) {
        switch st.auth {
        case .signedOut: return ("로그인 전", .off)
        case .signingIn: return ("로그인 중", .busy)
        case let .failed(m): return (m, .warn)
        case .signedIn: break
        }
        switch st.chat.phase {
        case .connecting: return ("연결 중", .busy)
        case .reconnecting(let n): return ("다시 연결 중 (\(n))", .busy)
        case .authFailed: return ("다시 로그인해 주세요", .warn)
        case .disconnected: return ("쉬는 중", .off)
        case .connected: break
        }
        if st.chat.isBusy, let last = st.chat.turns.last, let sel = st.selectionTurns[last.clientMsgID],
           [.idle, .typing, .thinking].contains(st.chat.activity) {
            return (sel.action.progressText, .busy)
        }
        if selection.preview != nil, !st.chat.isBusy { return ("보낼 내용을 확인해 주세요", .wait) }
        if st.chat.isBusy {
            return (ActivityText.label(st.chat.activity == .idle ? .typing : st.chat.activity, tool: st.chat.activeTool), .busy)
        }
        if let t = st.chat.task {
            let waits = t.state == "waiting"
            if t.isOpen || st.chat.turns.last?.taskID == t.id { return ("\(t.title) · \(t.statusText)", waits ? .wait : (t.isOpen ? .busy : .ok)) }
        }
        if st.config?.serviceNotice != nil { return ("연결됨", .wait) }
        return ("연결됨", .ok)
    }

    public enum HeaderDot: Equatable { case ok, busy, wait, warn, off }

    /// "크레딧 180" next to the status; hidden while a task's status takes the space.
    public static func headerCredits(_ st: PetSessionState, selection: PetSelectionChatState = PetSelectionChatState()) -> String? {
        guard st.auth == .signedIn, let u = st.chat.usage, selection.preview == nil else { return nil }
        if let t = st.chat.task, t.isOpen || st.chat.turns.last?.taskID == t.id { return nil }
        return "크레딧 \(PetText.number(u.remaining))"
    }

    /// - Parameter undoSecondsLeft: seconds left to undo a forget this session asked for (nil = no longer possible).
    /// - Parameter cards: what the app keeps per card while the user answers it (ticks, number-key mark, sending, failure).
    public static func items(_ st: PetSessionState, undoSecondsLeft: (String) -> Int?,
                             selection: PetSelectionChatState = PetSelectionChatState(),
                             cards local: [String: PetCardLocal] = [:], now: Date = Date()) -> [PetChatItem] {
        let card: (PetCard) -> PetCardItem = { c in PetTranscript.card(c, local: local[c.id] ?? PetCardLocal(), now: now) }
        var out: [PetChatItem] = []
        let chat = st.chat
        if st.loadingHistory { out.append(.older(loading: true)) } else if chat.hasMoreHistory { out.append(.older(loading: false)) }

        // The room record: earlier talk, other devices, finished tasks.
        for m in chat.history {
            if let c = m.card { out.append(.card(card(chat.cards.first { $0.id == c.id } ?? c))); continue }
            if m.contentType == "system_note" { out.append(.note(m.text)); continue }
            let mine = m.role == "user"
            if !m.text.isEmpty { out.append(mine ? .mine(text: m.text, attachments: [], past: true) : .nacho(text: m.text, past: true, streaming: false)) }
            if !m.files.isEmpty { out.append(.files(m.files.map(chip), mine: mine)) }
        }
        if !chat.history.isEmpty, !chat.turns.isEmpty { out.append(.divider("이번 대화")) }
        if chat.turns.isEmpty, chat.history.isEmpty, selection.preview == nil, !selection.intro { out.append(.hello(title: "무엇을 도와드릴까요?", examples: examples)) }

        let turnIDs = Set(chat.turns.map { $0.clientMsgID })
        for turn in chat.turns {
            let request = st.selectionTurns[turn.clientMsgID]
            // A selection request shows its chip instead of the context file's name.
            out.append(.mine(text: turn.userText, attachments: request == nil ? turn.attachmentNames : [], past: false))
            if let r = request { out.append(.requestChip(r.chip)) }
            // What Nacho is doing on the way: tools and "still working on it" lines.
            if !turn.tools.isEmpty {
                var parts: [PetTextPart] = []
                for (i, t) in turn.tools.enumerated() {
                    if i > 0 { parts.append(PetTextPart(" · ", style: .secondary)) }
                    parts.append(PetTextPart(PetText.toolName(t.name), tooltip: t.name))
                    if t.finished { parts.append(t.isError ? PetTextPart(" ✕", style: .failed) : PetTextPart(" ✓", style: .ok)) }
                    else { parts.append(PetTextPart(" …", style: .secondary)) }
                }
                out.append(.line(PetChatLine(kind: .tool, symbol: "wrench.adjustable", parts: parts)))
            }
            for p in turn.progress { out.append(.line(PetChatLine(kind: .progress, symbol: "sparkles", parts: [PetTextPart(p)]))) }
            var answer = turn.assistantText
            var failure: String?
            switch turn.status {
            case .sending: break
            case .streaming: break
            case .done: if answer.isEmpty, turn.taskID != nil { answer = "일로 맡았어요. 진행 상황은 여기에 보여 드릴게요." }
            case .stopped: answer += answer.isEmpty ? "(멈췄어요)" : " (멈춤)"
            case let .failed(m): failure = m
            case .interrupted: failure = "연결이 끊겨 답이 끝나지 않았어요. 다시 연결되면 이어서 보여 드려요."
            }
            let streaming = turn.status == .streaming || turn.status == .sending
            if !answer.isEmpty || streaming { out.append(.nacho(text: answer, past: false, streaming: streaming)) }
            if let f = failure { out.append(.line(PetChatLine(kind: .danger, symbol: "exclamationmark.triangle", parts: [PetTextPart(f)]))) }
            if !turn.files.isEmpty { out.append(.files(turn.files.map(chip), mine: false)) }
            if let r = request, turn.status == .done, !answer.isEmpty {
                let open = selection.expanded.contains(turn.clientMsgID)
                out.append(.answerActions(turnID: turn.clientMsgID, showingSent: open))
                if open { out.append(.sentContext(r.rows)) }
            }
            for id in turn.cardIDs { if let c = chat.cards.first(where: { $0.id == id }) { out.append(.card(card(c))) } }
            // Memory: first what this answer used, then what it changed (one line per change, updated in place).
            if !turn.usedMemoryIDs.isEmpty, turn.status == .done {
                out.append(.line(PetChatLine(kind: .memory, symbol: "brain", parts: [
                    PetTextPart("이 답에 기억 \(turn.usedMemoryIDs.count)개를 썼어요"), PetTextPart(" · ", style: .secondary),
                    PetTextPart("기억이 틀렸어요", link: PetLinks.url("memfb", ["turn": turn.clientMsgID]))])))
            }
            for n in chat.memoryNotes where n.turnClientID == turn.clientMsgID { out.append(.line(memoryLine(n, undoSecondsLeft))) }
        }
        // Memory lines and cards that came from elsewhere (hub, another device, a task).
        for n in chat.memoryNotes where n.turnClientID.map({ !turnIDs.contains($0) }) ?? true { out.append(.line(memoryLine(n, undoSecondsLeft))) }
        let inTurns = Set(chat.turns.flatMap { $0.cardIDs })
        let inHistory = Set(chat.history.compactMap { $0.card?.id })
        for c in chat.cards where c.isPending && !inTurns.contains(c.id) && !inHistory.contains(c.id) { out.append(.card(card(c))) }
        if let n = chat.lastNotification { out.append(.line(PetChatLine(kind: .notification, symbol: "bell", parts: [PetTextPart(n)]))) }
        if let u = chat.usage, u.exhausted || u.lowBalance || u.blockReason != nil {
            out.append(.line(PetChatLine(kind: .usage, symbol: "creditcard", parts: [PetTextPart(u.summary)])))
        }
        if selection.intro { out.append(.selectionIntro) }
        if let p = selection.preview { out.append(.selectionPreview(p)) }
        return out
    }

    static func memoryLine(_ n: PetMemoryNote, _ undoSecondsLeft: (String) -> Int?) -> PetChatLine {
        var parts = [PetTextPart(n.forgottenAt != nil ? n.textAfterForget : n.text)]
        if n.forgottenAt != nil {
            if let s = undoSecondsLeft(n.updateID), s > 0 {
                parts.append(PetTextPart(" · ", style: .secondary))
                parts.append(PetTextPart("\(s)초 안에 되돌리기", link: PetLinks.url("undo", ["u": n.updateID])))
            }
        } else if n.action != "forgotten" {
            parts.append(PetTextPart(" · ", style: .secondary))
            parts.append(PetTextPart("잊어 줘", link: PetLinks.url("forget", ["u": n.updateID])))
        }
        return PetChatLine(kind: .memory, symbol: "brain", parts: parts)
    }

    static func chip(_ f: PetFileLink) -> PetFileChip {
        let url = f.deleted ? nil : f.url.flatMap { URL(string: $0) }.flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
        return PetFileChip(name: f.name, isImage: f.kind == "image", url: url, byNacho: f.byNacho, deleted: f.deleted)
    }

    /// One card as the chat shows it (also used by the dev CLI).
    public static func card(_ c: PetCard, local: PetCardLocal = PetCardLocal(), now: Date = Date()) -> PetCardItem {
        let style = PetCardStyle.of(c)
        let state = PetCardRules.stateLine(c, local: local, now: now)
        guard style != .elsewhere else {
            // Login, codes, payment cards, browser, connections: the phone app, as before.
            return PetCardItem(id: c.id, symbol: "iphone", title: c.title, detail: c.detail, options: [], status: state.status,
                               statusWaits: c.isPending, style: style)
        }
        let open = c.isPending && local.sending == nil
        let chosen = PetCardRules.chosenNumbers(c)
        let options = PetCardRules.rows(c).map { r in
            PetCardItem.Option(label: r.label, link: open ? PetLinks.url("cardrow", ["id": c.id, "n": String(r.number)]) : nil,
                               chosen: chosen.contains(r.number), number: r.number, detail: r.detail, role: r.role,
                               marked: c.isPending && (local.highlighted == r.number || (r.optionID.map { local.ticked.contains($0) } ?? false)),
                               tickable: style == .multiple)
        }
        var confirm: PetCardItem.Option?
        if style == .multiple, c.isPending {
            let ready = PetCardRules.confirm(c, ticked: local.ticked) != nil
            confirm = PetCardItem.Option(label: local.ticked.isEmpty ? "확정" : "확정 (\(local.ticked.count)개)",
                                         link: open && ready ? PetLinks.url("cardconfirm", ["id": c.id]) : nil, chosen: false, role: .primary)
        }
        var detail = c.detail
        var summary: [String] = style == .approval ? PetCardRules.approvalSummary(c) : []
        if style == .ruleProposal {
            // One rule: its sentence (as text) above 적용 / 아니요; several: numbered rows, then 아니요.
            let one = c.options.count == 1
            if one, let o = c.options.first { summary = [o.label] }
            let then = one ? "적용하면 이 범위는 다시 묻지 않아요." : "하나를 고르면 그 범위는 다시 묻지 않아요."
            detail = c.saidText.map { "“\($0)”라고 하셨어요. " + then } ?? then
        }
        return PetCardItem(id: c.id, symbol: style == .approval ? "checkmark.shield" : "questionmark.circle", title: c.title,
                           detail: style == .approval ? nil : detail, options: options, status: state.status,
                           statusWaits: state.waits, style: style, summary: summary,
                           confirm: confirm, hint: c.isPending ? state.hint : nil,
                           retry: state.retry ? PetLinks.url("cardretry", ["id": c.id]) : nil)
    }

    /// The newest card in the log that waits for an answer here: the number keys go to it.
    public static func activeCardID(_ items: [PetChatItem]) -> String? {
        for item in items.reversed() {
            if case let .card(c) = item, c.style != .elsewhere, c.statusWaits || c.options.contains(where: { $0.link != nil }) { return c.id }
        }
        return nil
    }
}

extension PetMemoryNote {
    /// The same line after "잊어 줘": "잊었어요: …".
    var textAfterForget: String {
        let previews = items.map { $0.preview }.filter { !$0.isEmpty }.joined(separator: ", ")
        return "잊었어요" + (previews.isEmpty ? "" : ": \(previews)")
    }
}
