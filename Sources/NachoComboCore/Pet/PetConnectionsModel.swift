import Foundation

// 「연결」 탭 (NACHO-131 / NACHO-239): what the tab shows, as plain values. Three sections (도구 / 커넥터 / 가젯), one row per
// item (name, one status line, a switch), and a detail per row. The AppKit view only draws these values, so everything
// the user reads is tested here. Gadget actions come from `GadgetToolRegistry` (no second list).

public enum ConnectionsSection: String, CaseIterable, Equatable {
    case tools, connectors, gadgets

    public var title: String {
        switch self {
        case .tools: return "도구"
        case .connectors: return "커넥터"
        case .gadgets: return "가젯"
        }
    }

    public var emptyText: String {
        switch self {
        case .tools: return "나초가 쓸 수 있는 도구가 아직 없어요."
        case .connectors: return "연결된 서비스가 아직 없어요."
        case .gadgets: return "나초콤보 가젯이 없어요."
        }
    }
}

/// What a row or a detail is about. Connectors are identified by the connection id (the PATCH/DELETE path).
public enum ConnectionsRef: Hashable {
    case tool(String)
    case connector(String)
    case gadget(GadgetID)
}

public enum ConnectionsTone: Equatable {
    case normal
    /// Needs the user (sign in again, a macOS permission, an error).
    case attention
    case off
}

public enum ConnectionsSwitchState: Equatable {
    case on
    case off
    /// A default tool Nacho needs in every chat: shown with a lock, the switch is blocked.
    case locked
    /// Cannot be switched here; the text says why and where.
    case fixed(String)

    public var isOn: Bool {
        switch self {
        case .on, .locked: return true
        case .off, .fixed: return false
        }
    }

    public var canToggle: Bool {
        switch self {
        case .on, .off: return true
        case .locked, .fixed: return false
        }
    }
}

public struct ConnectionsRow: Equatable, Identifiable {
    public var ref: ConnectionsRef
    public var section: ConnectionsSection
    public var title: String
    public var status: String
    public var tone: ConnectionsTone
    public var control: ConnectionsSwitchState

    public init(ref: ConnectionsRef, section: ConnectionsSection, title: String, status: String, tone: ConnectionsTone,
                control: ConnectionsSwitchState) {
        self.ref = ref
        self.section = section
        self.title = title
        self.status = status
        self.tone = tone
        self.control = control
    }

    public var id: String {
        switch ref {
        case let .tool(i): return "tool:\(i)"
        case let .connector(i): return "connector:\(i)"
        case let .gadget(g): return "gadget:\(g.rawValue)"
        }
    }
}

public struct ConnectionsSectionRows: Equatable {
    public var section: ConnectionsSection
    public var rows: [ConnectionsRow]
}

// MARK: - connection health

public enum ConnectionHealth: Equatable {
    case connected, needsReauth, off, needsPermission, error, disconnected, unknown

    public var label: String {
        switch self {
        case .connected: return "연결됨"
        case .needsReauth: return "다시 로그인 필요"
        case .off: return "꺼짐"
        case .needsPermission: return "권한 필요"
        case .error: return "오류"
        case .disconnected: return "연결 끊김"
        case .unknown: return "알 수 없음"
        }
    }
}

extension ConnectionRow {
    /// One state for the row and the detail. A switched-off service reads "꺼짐" whatever else it needs.
    public var health: ConnectionHealth {
        if status == "disconnected" { return .disconnected }
        if !enabled { return .off }
        if status == "needs_reauth" || needsAttention == "needs_reauth" { return .needsReauth }
        if status == "needs_permission" || needsAttention == "needs_permission" { return .needsPermission }
        if status == "error" { return .error }
        if status == "connected" { return .connected }
        return .unknown
    }

    /// The small note under a healthy connection that is about to need attention.
    public var attentionNote: String? {
        switch needsAttention {
        case "degraded": return "일부 기능이 불안정해요"
        case "expiring": return "곧 다시 로그인해야 해요"
        default: return nil
        }
    }

    public var tone: ConnectionsTone {
        switch health {
        case .connected: return attentionNote == nil ? .normal : .attention
        case .off, .disconnected: return .off
        case .needsReauth, .needsPermission, .error, .unknown: return .attention
        }
    }

    /// The status line of the row: state, then the account when there is one.
    public var statusLine: String {
        var line = health.label
        if health == .connected, let note = attentionNote { line += " · " + note }
        if let a = accountLabel, !a.isEmpty { line += " · " + a }
        return line
    }
}

// MARK: - words for tool names

/// Turns a tool or capability name (`gmail_search_messages`) into words a person reads ("메시지 검색"). Used only
/// when the server sent no Korean description.
public enum ToolWords {
    static let verbs: [String: String] = [
        "search": "검색", "find": "찾기", "read": "읽기", "get": "보기", "list": "목록 보기", "show": "보기",
        "create": "만들기", "add": "추가", "update": "고치기", "edit": "고치기", "delete": "지우기", "remove": "빼기",
        "send": "보내기", "reply": "답장", "move": "옮기기", "open": "열기", "close": "닫기", "download": "내려받기",
        "upload": "올리기", "set": "설정", "check": "확인", "summarize": "요약", "write": "쓰기", "fetch": "가져오기",
    ]
    static let nouns: [String: String] = [
        "message": "메시지", "messages": "메시지", "mail": "메일", "email": "메일", "emails": "메일", "mails": "메일",
        "event": "일정", "events": "일정", "calendar": "캘린더", "calendars": "캘린더", "file": "파일", "files": "파일",
        "folder": "폴더", "folders": "폴더", "draft": "임시 보관", "drafts": "임시 보관", "label": "라벨", "labels": "라벨",
        "page": "페이지", "pages": "페이지", "task": "할 일", "tasks": "할 일", "note": "메모", "notes": "메모",
        "contact": "연락처", "contacts": "연락처", "document": "문서", "documents": "문서", "doc": "문서", "docs": "문서",
        "issue": "이슈", "issues": "이슈", "comment": "댓글", "comments": "댓글", "web": "웹", "url": "주소",
        "image": "이미지", "images": "이미지", "photo": "사진", "photos": "사진", "thread": "대화", "threads": "대화",
        "channel": "채널", "channels": "채널", "repo": "저장소", "repos": "저장소", "browser": "브라우저", "tool": "도구",
        "tools": "도구", "memory": "기억", "reminder": "알림", "reminders": "알림", "sheet": "시트", "sheets": "시트",
    ]

    /// `search_web` → "웹 검색", `gmail_list_labels` → "gmail 라벨 목록 보기". Words without a translation stay as they are.
    public static func title(_ name: String) -> String {
        let parts = name.lowercased().split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." || $0 == " " }).map(String.init)
        guard !parts.isEmpty else { return name }
        var verb: String?
        var rest: [String] = []
        for p in parts {
            if verb == nil, let v = verbs[p] { verb = v; continue }
            rest.append(nouns[p] ?? p)
        }
        if let v = verb { rest.append(v) }
        return rest.joined(separator: " ")
    }

    /// The first sentence of a description, for one line under a name. Empty when there is none.
    public static func firstSentence(_ text: String, limit: Int = 90) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        var end = t.endIndex
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if c == "\n" { end = i; break }
            if c == ".", t.index(after: i) == t.endIndex || t[t.index(after: i)] == " " || t[t.index(after: i)] == "\n" {
                end = t.index(after: i); break
            }
            i = t.index(after: i)
        }
        var s = String(t[t.startIndex..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit - 1)) + "…" }
        return s
    }

    static func hasHangul(_ s: String) -> Bool { s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
}

extension ToolRow {
    /// What the list calls the tool: its name in words.
    public var title: String { ToolWords.title(name) }

    /// One line about what the tool does (the server's description, first sentence); empty when it has none.
    public var summaryLine: String { ToolWords.firstSentence(description) }
}

// MARK: - Mac actions of a gadget (from the registry)

public struct MacActionRow: Equatable, Identifiable {
    /// The canonical connector name that goes into `GadgetTrust.disabled`.
    public var id: String
    public var gadget: GadgetID
    /// One Korean sentence: what Nacho does.
    public var title: String
    public var permissions: [OSPermission]
    public var isOn: Bool
    public var risk: GadgetToolRisk = .read
}

public enum MacActions {
    /// The connector tools of a gadget, in registry order. Only tools on the connector exit: those are what Nacho does on this Mac.
    public static func rows(for gadget: GadgetID, disabled: Set<String>, tools: [GadgetTool] = GadgetToolRegistry.all) -> [MacActionRow] {
        tools.filter { $0.gadget == gadget && $0.exits.contains(.connector) }.map { t in
            MacActionRow(id: t.connectorName, gadget: gadget, title: ToolWords.firstSentence(t.koreanDescription, limit: 120),
                            permissions: t.permissions.sorted(), isOn: disabled.isDisjoint(with: t.connectorNames), risk: t.risk)
        }
    }

    /// What the user reads under an action: how Nacho asks. nil for read / change (they just run).
    public static func riskText(_ risk: GadgetToolRisk, alwaysAllowed: Bool) -> String? {
        switch risk {
        case .read, .change: return nil
        case .contentOut, .inputInject: return alwaysAllowed ? "이 가젯은 항상 허용이라 묻지 않고 해요" : "보내기 전에 매번 물어봐요"
        case .destructive: return "매번 물어봐요(항상 허용 안 됨)"
        }
    }

    /// The sentence before "always allow" is switched on: what then goes out or gets typed without a question.
    public static func alwaysAllowConfirm(_ gadget: GadgetID, tools: [GadgetTool] = GadgetToolRegistry.all) -> String {
        let own = tools.filter { $0.gadget == gadget && $0.exits.contains(.connector) }
        let out = own.contains { $0.risk == .contentOut }, inject = own.contains { $0.risk == .inputInject }
        let what = out && inject ? "내용을 보내고 입력하는 일을" : (inject ? "키 입력·클릭을" : "\(gadget.koreanName) 내용을 나초에게 보내는 일을")
        return "\(what) 묻지 않고 해요. 되돌릴 수 없는 행동은 계속 매번 물어봐요. 언제든 끌 수 있어요."
    }

    public static func tool(connectorName: String, in tools: [GadgetTool] = GadgetToolRegistry.all) -> GadgetTool? {
        tools.first { $0.exits.contains(.connector) && $0.connectorName == connectorName }
    }

    /// "맥 행동 5개 중 4개 허용"
    public static func summary(_ rows: [MacActionRow]) -> String {
        guard !rows.isEmpty else { return "맥에서 하는 일이 없어요" }
        let on = rows.filter { $0.isOn }.count
        return on == rows.count ? "맥 행동 \(rows.count)개 모두 허용" : "맥 행동 \(rows.count)개 중 \(on)개 허용"
    }
}

// MARK: - gadget switches (the app's own on/off)

public struct GadgetSwitchState: Equatable {
    public enum Phase: Equatable {
        case on, off
        case needsPermission
        case failed
        /// No module of its own (Desktop Tidy): always available.
        case alwaysAvailable
        /// Switched somewhere else (Computer Use has its own page).
        case managedElsewhere
    }

    public var id: GadgetID
    public var phase: Phase
    public init(id: GadgetID, phase: Phase) {
        self.id = id
        self.phase = phase
    }

    /// The gadgets the tab lists: every gadget but Nacho Combo itself (its tools are the plumbing of the others).
    public static var listed: [GadgetID] { GadgetID.allCases.filter { $0 != .combo } }

    /// From the answer of `combo_list_gadgets` (`{moduleRawValue: "on" | "off" | "waiting for permission" | "failed"}`).
    public static func states(from gadgets: [String: String]) -> [GadgetSwitchState] {
        listed.map { id in
            guard let module = id.moduleID else { return GadgetSwitchState(id: id, phase: .alwaysAvailable) }
            if id == .computer { return GadgetSwitchState(id: id, phase: .managedElsewhere) }
            switch gadgets[module.rawValue] {
            case "on"?: return GadgetSwitchState(id: id, phase: .on)
            case "waiting for permission"?: return GadgetSwitchState(id: id, phase: .needsPermission)
            case "failed"?: return GadgetSwitchState(id: id, phase: .failed)
            default: return GadgetSwitchState(id: id, phase: .off)
            }
        }
    }

    public var control: ConnectionsSwitchState {
        switch phase {
        case .on: return .on
        case .off, .needsPermission, .failed: return .off
        case .alwaysAvailable: return .fixed("항상 쓸 수 있어요")
        case .managedElsewhere: return .fixed("설정에서 켜요")
        }
    }
}

// MARK: - the list

public enum ConnectionsListBuilder {
    /// The three sections in their fixed order. `overview` nil = the server list is not loaded (yet): the tool and
    /// connector sections are empty and the gadget section still shows. With a search text, sections with no match are left out.
    public static func sections(overview: ConnectorOverview?, gadgets: [GadgetSwitchState], disabled: Set<String>, query: String = "",
                                tools gadgetTools: [GadgetTool] = GadgetToolRegistry.all) -> [ConnectionsSectionRows] {
        let q = normalize(query)
        var out: [ConnectionsSectionRows] = []
        for section in ConnectionsSection.allCases {
            let all: [ConnectionsRow]
            switch section {
            case .tools: all = toolRows(overview)
            case .connectors: all = connectorRows(overview)
            case .gadgets: all = gadgetRows(gadgets, disabled: disabled, tools: gadgetTools)
            }
            let rows = q.isEmpty ? all : all.filter { matches($0, q, overview: overview) }
            if q.isEmpty || !rows.isEmpty { out.append(ConnectionsSectionRows(section: section, rows: rows)) }
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func matches(_ row: ConnectionsRow, _ q: String, overview: ConnectorOverview?) -> Bool {
        var hay = [row.title, row.status]
        switch row.ref {
        case let .tool(id): if let t = overview?.tools.first(where: { $0.id == id }) { hay += [t.name, t.description] }
        case let .connector(id): if let c = overview?.connections.first(where: { $0.id == id }) { hay += [c.source, c.accountLabel ?? ""] }
        case let .gadget(g): hay += [g.rawValue, g.displayName]
        }
        return hay.contains { $0.lowercased().contains(q) }
    }

    /// Tools that belong to a connected service (`source` set, kind "connection") are listed in that service's detail, not here.
    static func toolRows(_ overview: ConnectorOverview?) -> [ConnectionsRow] {
        (overview?.tools ?? []).filter { $0.kind != "connection" && $0.source == nil }.map { t in
            let control: ConnectionsSwitchState = t.locked ? .locked : (t.userEnabled ? .on : .off)
            var status = t.summaryLine.isEmpty ? t.kindText : t.summaryLine
            if t.locked { status = "기본 도구 · 항상 켜져 있어요" } else if !t.userEnabled { status = "꺼짐" }
            return ConnectionsRow(ref: .tool(t.id), section: .tools, title: t.title, status: status,
                                  tone: t.userEnabled ? .normal : .off, control: control)
        }
    }

    static func connectorRows(_ overview: ConnectorOverview?) -> [ConnectionsRow] {
        (overview?.connections ?? []).map { c in
            ConnectionsRow(ref: .connector(c.id), section: .connectors, title: c.label, status: c.statusLine, tone: c.tone,
                           control: c.enabled && c.health != .disconnected ? .on : .off)
        }
    }

    static func gadgetRows(_ gadgets: [GadgetSwitchState], disabled: Set<String>, tools: [GadgetTool]) -> [ConnectionsRow] {
        gadgets.map { g in
            let actions = MacActions.rows(for: g.id, disabled: disabled, tools: tools)
            var status: String
            var tone = ConnectionsTone.normal
            switch g.phase {
            case .on, .alwaysAvailable: status = actions.isEmpty ? "켜짐" : MacActions.summary(actions)
            case .off: status = "꺼짐"; tone = .off
            case .needsPermission: status = "맥 권한 필요"; tone = .attention
            case .failed: status = "시작하지 못했어요"; tone = .attention
            case .managedElsewhere: status = "컴퓨터 사용 설정 화면에서 켜고 꺼요"; tone = .off
            }
            return ConnectionsRow(ref: .gadget(g.id), section: .gadgets, title: g.id.koreanName, status: status, tone: tone, control: g.control)
        }
    }
}
