import Foundation

// 「연결」 탭의 상세 화면 (NACHO-239). One generic shape for tool, connector and gadget: what it does, what Nacho can do with
// it (a list of abilities, each may have its own switch), facts (account, scope), and the way out (disconnect).
// Rows of abilities are a list on purpose: later steps (NACHO-151: risk, "always allow") add fields per ability.

public struct ConnectionsAbility: Equatable, Identifiable {
    public var id: String
    public var title: String
    /// Under the title: a macOS permission it needs, or why it is off.
    public var note: String?
    /// nil = no switch of its own (it follows the service).
    public var isOn: Bool?
    public var permissions: [OSPermission] = []
    /// NACHO-151: how Nacho asks before doing it (nil = it just runs). Shown under the title.
    public var risk: GadgetToolRisk?
    public var riskText: String?
}

/// NACHO-151: the "이 가젯은 항상 허용" switch of a gadget that has content_out / input_inject actions.
public struct ConnectionsAlwaysAllow: Equatable {
    public var gadget: GadgetID
    public var title: String
    public var note: String
    public var isOn: Bool
    /// Shown before it is switched on. Switching off needs no question.
    public var confirmText: String
    public var confirmButton: String
}

public struct ConnectionsFact: Equatable {
    public var label: String
    public var value: String
}

public struct ConnectionsDisconnect: Equatable {
    public var buttonTitle: String
    public var confirmTitle: String
    public var confirmMessage: String
    public var confirmButton: String
}

/// The scope choices of a connector: 읽기만 / 읽기와 쓰기. nil when the server did not say what is granted.
public struct ConnectionsScopeChoice: Equatable {
    public var levels: [(id: String, title: String)]
    public var selected: String

    public static func == (a: ConnectionsScopeChoice, b: ConnectionsScopeChoice) -> Bool {
        a.selected == b.selected && a.levels.map { $0.id } == b.levels.map { $0.id }
    }
}

public struct ConnectionsDetail: Equatable {
    public var ref: ConnectionsRef
    public var title: String
    public var status: String
    public var tone: ConnectionsTone
    public var control: ConnectionsSwitchState
    /// What it does.
    public var summary: String
    public var abilitiesTitle: String
    public var abilities: [ConnectionsAbility]
    public var emptyAbilities: String
    public var facts: [ConnectionsFact]
    /// A sentence the user must read (sign in again, locked, permission).
    public var notice: String?
    public var scope: ConnectionsScopeChoice?
    public var alwaysAllow: ConnectionsAlwaysAllow?
    /// "다시 연결": sign in again or connect again.
    public var reconnectTitle: String?
    public var disconnect: ConnectionsDisconnect?
}

/// What `GET /api/v1/connections/{source}` adds to the list row (what the service does, what Nacho can do, accounts).
public struct ConnectionDetailInfo: Equatable {
    public var summary: String = ""
    public var canDo: [String] = []
    public var cannotDo: [String] = []
    public var askFirst: [String] = []
    public var accounts: [String] = []

    public init() {}

    public static func decode(_ data: Data) -> ConnectionDetailInfo? {
        guard let any = try? JSONSerialization.jsonObject(with: data), let o = any as? [String: Any] else { return nil }
        var info = ConnectionDetailInfo()
        let service = o["service"] as? [String: Any]
        info.summary = (service?["summary"] as? String) ?? ""
        let notice = o["notice"] as? [String: Any]
        info.canDo = (notice?["can_do"] as? [String]) ?? []
        info.cannotDo = (notice?["cannot_do"] as? [String]) ?? []
        info.askFirst = (o["ask_first"] as? [String]) ?? []
        info.accounts = ((o["accounts"] as? [[String: Any]]) ?? []).compactMap { $0["account_label"] as? String }
        return info
    }
}

public enum ConnectionsDetailBuilder {
    // MARK: tool

    public static func tool(_ t: ToolRow) -> ConnectionsDetail {
        let control: ConnectionsSwitchState = t.locked ? .locked : (t.userEnabled ? .on : .off)
        let status = t.locked ? "항상 켜짐 · 기본 도구" : (t.userEnabled ? "켜짐" : "꺼짐")
        var facts = [ConnectionsFact(label: "종류", value: t.kindText)]
        if let s = t.source { facts.append(ConnectionsFact(label: "서비스", value: s)) }
        return ConnectionsDetail(
            ref: .tool(t.id), title: t.title, status: status, tone: t.userEnabled ? .normal : .off, control: control,
            summary: t.description.isEmpty ? "나초가 대화 중에 고르는 도구예요." : ToolWords.firstSentence(t.description, limit: 240),
            abilitiesTitle: "", abilities: [], emptyAbilities: "", facts: facts,
            notice: t.locked ? "나초가 대화하는 데 꼭 필요한 기본 도구라서 끌 수 없어요." : (t.userEnabled ? nil : "꺼 두면 나초가 이 도구를 고르지 않아요."),
            scope: nil, alwaysAllow: nil, reconnectTitle: nil, disconnect: nil)
    }

    // MARK: connector

    public static func connector(_ c: ConnectionRow, tools: [ToolRow], info: ConnectionDetailInfo? = nil) -> ConnectionsDetail {
        let own = tools.filter { $0.source == c.source }
        var abilities: [ConnectionsAbility] = own.map { t in
            ConnectionsAbility(id: t.id, title: t.title, note: t.summaryLine.isEmpty ? nil : t.summaryLine, isOn: nil)
        }
        if abilities.isEmpty, let info = info {
            abilities = info.canDo.enumerated().map { ConnectionsAbility(id: "can:\($0.offset)", title: $0.element, note: nil, isOn: nil) }
        }
        var facts: [ConnectionsFact] = []
        if let a = c.accountLabel, !a.isEmpty { facts.append(ConnectionsFact(label: "계정", value: a)) }
        if !c.scopeSummary.isEmpty { facts.append(ConnectionsFact(label: "권한 범위", value: c.scopeSummary)) }
        if let info = info, !info.askFirst.isEmpty { facts.append(ConnectionsFact(label: "늘 먼저 물어요", value: info.askFirst.joined(separator: " · "))) }
        var notice: String?
        var reconnect: String?
        switch c.health {
        case .needsReauth:
            notice = "로그인이 만료됐어요. 다시 로그인하면 나초가 이 서비스를 다시 쓸 수 있어요."; reconnect = "다시 로그인"
        case .needsPermission:
            notice = "이 서비스에 필요한 권한이 아직 없어요. 다시 연결해서 권한을 허용해 주세요."; reconnect = "다시 연결"
        case .disconnected:
            notice = "연결이 끊겼어요. 다시 쓰려면 새로 연결해야 해요."; reconnect = "다시 연결"
        case .error:
            notice = "연결에 문제가 있어요. 다시 연결하면 나아질 수 있어요."; reconnect = "다시 연결"
        case .off:
            notice = "꺼 두면 나초가 이 서비스를 쓰지 않아요. 연결은 그대로 남아 있어요."
        case .connected, .unknown:
            notice = c.attentionNote
        }
        var scope: ConnectionsScopeChoice?
        if let level = c.scopeLevel, ["read", "read_write"].contains(level), c.health != .disconnected {
            scope = ConnectionsScopeChoice(levels: [("read", "읽기만"), ("read_write", "읽기와 쓰기")], selected: level)
        }
        let summary = (info?.summary.isEmpty == false ? info?.summary : nil) ?? "나초가 \(c.label) 서비스를 대신 쓸 수 있게 해 줘요."
        return ConnectionsDetail(
            ref: .connector(c.id), title: c.label, status: c.statusLine, tone: c.tone,
            control: c.enabled && c.health != .disconnected ? .on : .off,
            summary: summary, abilitiesTitle: "나초가 쓸 수 있는 기능", abilities: abilities,
            emptyAbilities: "아직 알려진 기능이 없어요.", facts: facts, notice: notice, scope: scope, alwaysAllow: nil, reconnectTitle: reconnect,
            disconnect: c.health == .disconnected ? nil : ConnectionsDisconnect(
                buttonTitle: "연결 해제", confirmTitle: "\(c.label) 연결을 끊을까요?",
                confirmMessage: "나초가 \(c.label) 서비스를 더 이상 쓸 수 없어요. 되돌릴 수 없어요. 다시 쓰려면 처음부터 다시 연결해야 해요.",
                confirmButton: "연결 해제"))
    }

    // MARK: gadget

    public static func gadget(_ g: GadgetSwitchState, disabled: Set<String>, alwaysAllowed: Set<GadgetID> = [],
                              tools: [GadgetTool] = GadgetToolRegistry.all) -> ConnectionsDetail {
        let actions = MacActions.rows(for: g.id, disabled: disabled, tools: tools)
        let abilities = actions.map { a in
            ConnectionsAbility(id: a.id, title: a.title, note: a.permissions.isEmpty ? nil : "맥 권한: " + a.permissions.map { $0.koreanName }.joined(separator: ", "),
                               isOn: a.isOn, permissions: a.permissions, risk: a.risk,
                               riskText: MacActions.riskText(a.risk, alwaysAllowed: alwaysAllowed.contains(g.id)))
        }
        var alwaysAllow: ConnectionsAlwaysAllow?
        if GadgetToolRegistry.trustableGadgets(in: tools).contains(g.id) {
            let on = alwaysAllowed.contains(g.id)
            alwaysAllow = ConnectionsAlwaysAllow(
                gadget: g.id, title: "이 가젯은 항상 허용",
                note: on ? "내용 전송·입력 행동을 묻지 않고 해요. 끄면 다시 매번 물어봐요." : "꺼 두면 내용을 보내거나 입력하기 전에 매번 물어봐요.",
                isOn: on, confirmText: MacActions.alwaysAllowConfirm(g.id, tools: tools), confirmButton: "항상 허용")
        }
        var status: String
        var tone = ConnectionsTone.normal
        var notice: String?
        switch g.phase {
        case .on: status = "켜짐"
        case .off: status = "꺼짐"; tone = .off; notice = "켜면 아래 일을 나초가 이 맥에서 할 수 있어요. 필요한 맥 권한은 켤 때 물어봐요."
        case .needsPermission:
            status = "맥 권한 필요"; tone = .attention; notice = "켜려면 맥 권한이 필요해요. 스위치를 누르면 허용할 곳을 알려 줘요."
        case .failed: status = "시작하지 못했어요"; tone = .attention
        case .alwaysAvailable: status = "항상 쓸 수 있어요"
        case .managedElsewhere: status = "컴퓨터 사용 설정 화면에서 켜고 꺼요"; tone = .off
        }
        let summary = GadgetToolRegistry.guide(for: g.id).map { ToolWords.firstSentence($0.summary, limit: 140) } ?? "나초콤보의 \(g.id.koreanName) 가젯이에요."
        return ConnectionsDetail(
            ref: .gadget(g.id), title: g.id.koreanName, status: status, tone: tone, control: g.control, summary: summary,
            abilitiesTitle: "이 맥에서 나초가 하는 일", abilities: abilities, emptyAbilities: "나초가 이 가젯으로 하는 일이 없어요.",
            facts: [ConnectionsFact(label: "맥 행동", value: MacActions.summary(actions))], notice: notice, scope: nil,
            alwaysAllow: alwaysAllow, reconnectTitle: nil, disconnect: nil)
    }
}

// MARK: - connecting a service

/// How a service can be connected from this Mac.
public enum MacConnectPlan: Equatable {
    /// OAuth: the default browser opens the provider's consent page.
    case browser
    /// The service gives an app password: typed in the app.
    case appPassword
    /// Not from this Mac: the reason and where to do it instead.
    case unsupported(reason: String, alternative: String)

    public static let phoneAlternative = "휴대폰의 나초 앱에서 연결해 주세요."

    public static func plan(connectKind: String, supportStatus: String? = nil, supportReason: String? = nil) -> MacConnectPlan {
        if supportStatus == "unsupported" || supportStatus == "degraded" {
            let why = (supportReason?.isEmpty == false ? supportReason : nil) ?? "지금은 이 서비스를 연결할 수 없어요."
            return .unsupported(reason: why, alternative: "잠시 뒤 다시 시도해 주세요.")
        }
        switch connectKind {
        case "oauth": return .browser
        case "app_password": return .appPassword
        case "qr": return .unsupported(reason: "이 서비스는 휴대폰으로 QR을 승인해야 연결돼요. 맥 앱에서는 아직 그 과정을 지원하지 않아요.", alternative: phoneAlternative)
        case "site": return .unsupported(reason: "이 서비스는 나초가 사이트에 대신 로그인하는 방식이에요. 맥 앱에서는 아직 지원하지 않아요.", alternative: phoneAlternative)
        case "device": return .unsupported(reason: "기기 권한으로 쓰는 서비스예요. 이 맥의 가젯 섹션에서 켜 주세요.", alternative: "가젯 섹션에서 해당 가젯을 켜 주세요.")
        default: return .unsupported(reason: "맥 앱에서는 이 방식으로 연결할 수 없어요.", alternative: phoneAlternative)
        }
    }
}

/// The steps the user sees while a service connects.
public enum ConnectProgress: Equatable {
    case starting
    case inBrowser
    case needsAppPassword
    case verifying
    case done
    case failed(String)
    case canceled
    case expired

    public var text: String {
        switch self {
        case .starting: return "연결을 준비하고 있어요…"
        case .inBrowser: return "브라우저에서 동의를 마쳐 주세요. 끝나면 이 창으로 돌아와요."
        case .needsAppPassword: return "앱 비밀번호를 입력해 주세요."
        case .verifying: return "연결을 확인하고 있어요…"
        case .done: return "연결됐어요."
        case let .failed(m): return m
        case .canceled: return "연결을 취소했어요."
        case .expired: return "시간이 지났어요. 처음부터 다시 연결해 주세요."
        }
    }

    public var isFinished: Bool {
        switch self {
        case .done, .failed, .canceled, .expired: return true
        default: return false
        }
    }

    /// From a server attempt (`GET /connections/attempts/{id}`). Completed counts only when the server says so.
    public static func from(_ a: AttemptInfo) -> ConnectProgress {
        switch a.state {
        case "completed": return .done
        case "canceled": return .canceled
        case "expired": return .expired
        case "failed": return .failed(AttemptFailureText.text(a.failure))
        case "verifying": return .verifying
        case "preparing": return .starting
        default: return .inBrowser
        }
    }
}

public enum AttemptFailureText {
    public static func text(_ code: String?) -> String {
        switch code {
        case "access_denied"?, "declined"?: return "동의하지 않아서 연결하지 않았어요."
        case "scopes_declined"?: return "필요한 권한을 허용하지 않아서 연결하지 못했어요."
        case "canceled"?: return "연결을 취소했어요."
        case "wrong_account"?: return "다른 계정으로 로그인됐어요. 맞는 계정으로 다시 시도해 주세요."
        case "authentication_failed"?: return "로그인에 실패했어요. 입력한 내용을 확인해 주세요."
        case "account_suspended"?: return "이 계정은 지금 쓸 수 없어요."
        case "qr_expired"?: return "QR 시간이 지났어요. 다시 시도해 주세요."
        case "transport"?, "program_unavailable"?, "program_timeout"?, "identity_unavailable"?:
            return "서비스와 통신하지 못했어요. 잠시 뒤 다시 시도해 주세요."
        default: return "연결하지 못했어요. 다시 시도해 주세요."
        }
    }
}
