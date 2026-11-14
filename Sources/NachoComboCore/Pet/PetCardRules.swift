import Foundation

// How the chat shows and answers a server card (spec/cards.tsp), by kind: an approval (실행 above, 거절 below), one
// choice (numbered rows, a click answers), several choices (check rows + 확정), suggestions (quick-reply chips under
// Nacho's answer) and a rule proposal (the rule's sentence + 적용 / 아니요). Every option carries a number 1…N so the
// user can answer with the number keys or by saying "두 번째". Foundation only, so Linux tests cover the rules.

/// The way a card is drawn and answered.
public enum PetCardStyle: Equatable {
    case approval
    case single
    case multiple
    case suggestions
    case ruleProposal
    /// Login, OTP, security code, payment card, browser, connections: pointed to the phone app (unchanged).
    case elsewhere

    public static func of(_ c: PetCard) -> PetCardStyle {
        switch c.kind {
        case "approval": return .approval
        case "choice": return c.multiple ? .multiple : .single
        case "suggestions": return .suggestions
        case "rule_proposal": return .ruleProposal
        default: return .elsewhere
        }
    }
}

/// One answer to send: the card action, the chosen options, and for ask_choice cards and suggestions the text that
/// goes to the chat as the user's next message (spec/cards.tsp ChoicePayload: "고른 답은 앱이 다음 메시지로 보낸다").
public struct PetCardAnswer: Equatable {
    public var action: String
    public var optionIDs: [String]
    public var followUpText: String?
    /// Approval only: with `approve`, the `rule_options` id to also save as an allow rule (`allow_rule.rule_option_id`).
    public var allowRuleID: String?

    public init(action: String, optionIDs: [String] = [], followUpText: String? = nil, allowRuleID: String? = nil) {
        self.action = action; self.optionIDs = optionIDs; self.followUpText = followUpText; self.allowRuleID = allowRuleID
    }
}

/// What the app keeps per card while the user works with it (memory only): ticked rows of a multiple choice, the
/// row picked with a number key (Enter answers it), the answer on its way, the last failure for 다시 시도.
public struct PetCardLocal: Equatable {
    public var ticked: [String] = []
    public var highlighted: Int?
    public var sending: PetCardAnswer?
    public var failure: String?
    public var lastAnswer: PetCardAnswer?
    public init() {}
}

/// Rows of a card in the order they are numbered.
public struct PetCardRow: Equatable {
    public enum Role: Equatable { case option, primary, quiet }
    public var number: Int
    public var label: String
    public var detail: String?
    public var role: Role
    /// The answer a click (or the number + Enter) sends; for a multiple choice row: nil (it ticks).
    public var answer: PetCardAnswer?
    public var optionID: String?
}

public enum PetCardRules {
    /// Rows of the card, numbered 1…N.
    public static func rows(_ c: PetCard) -> [PetCardRow] {
        let ask = c.kind == "choice" && c.taskID == nil  // ask_choice: the chosen label also goes to the chat
        switch PetCardStyle.of(c) {
        case .approval where !c.ruleOptions.isEmpty:
            // 이번만 실행 first (nothing saved), then one row per rule the server offers, 거절 last. Only a tap or a number
            // + Enter picks a rule: the spoken replies never answer an approval.
            var rows = [PetCardRow(number: 1, label: "이번만 실행", detail: nil, role: .primary, answer: PetCardAnswer(action: "approve"), optionID: nil)]
            for o in c.ruleOptions {
                rows.append(PetCardRow(number: rows.count + 1, label: "실행하고 항상 허용", detail: o.label, role: .option,
                                       answer: PetCardAnswer(action: "approve", allowRuleID: o.id), optionID: o.id))
            }
            rows.append(PetCardRow(number: rows.count + 1, label: "거절", detail: nil, role: .quiet, answer: PetCardAnswer(action: "deny"), optionID: nil))
            return rows
        case .approval:
            return [PetCardRow(number: 1, label: "실행", detail: nil, role: .primary, answer: PetCardAnswer(action: "approve"), optionID: nil),
                    PetCardRow(number: 2, label: "거절", detail: nil, role: .quiet, answer: PetCardAnswer(action: "deny"), optionID: nil)]
        case .single, .suggestions:
            let follow = c.kind == "suggestions" || ask
            return c.options.enumerated().map { i, o in
                PetCardRow(number: i + 1, label: o.label, detail: o.reason, role: .option,
                           answer: PetCardAnswer(action: "choose", optionIDs: [o.id], followUpText: follow ? o.label : nil), optionID: o.id)
            }
        case .multiple:
            return c.options.enumerated().map { i, o in
                PetCardRow(number: i + 1, label: o.label, detail: o.reason, role: .option, answer: nil, optionID: o.id)
            }
        case .ruleProposal:
            if c.options.count == 1, let o = c.options.first {
                return [PetCardRow(number: 1, label: "적용", detail: nil, role: .primary, answer: PetCardAnswer(action: "choose", optionIDs: [o.id]), optionID: o.id),
                        PetCardRow(number: 2, label: "아니요", detail: nil, role: .quiet, answer: PetCardAnswer(action: "dismiss"), optionID: nil)]
            }
            var rows = c.options.enumerated().map { i, o in
                PetCardRow(number: i + 1, label: o.label, detail: nil, role: .option, answer: PetCardAnswer(action: "choose", optionIDs: [o.id]), optionID: o.id)
            }
            rows.append(PetCardRow(number: rows.count + 1, label: "아니요", detail: nil, role: .quiet, answer: PetCardAnswer(action: "dismiss"), optionID: nil))
            return rows
        case .elsewhere:
            return []
        }
    }

    /// The 확정 answer of a multiple choice: the ticked options in the order of the card.
    public static func confirm(_ c: PetCard, ticked: [String]) -> PetCardAnswer? {
        let ids = c.options.map { $0.id }.filter { ticked.contains($0) }
        guard !ids.isEmpty else { return nil }
        let labels = c.options.filter { ids.contains($0.id) }.map { $0.label }
        return PetCardAnswer(action: "choose", optionIDs: ids, followUpText: c.taskID == nil ? labels.joined(separator: ", ") : nil)
    }

    /// The approval's summary lines: what (kind of action), the result (merchant, amount, counterpart) and whether it
    /// can be undone. The title already says what Nacho wants to do.
    public static func approvalSummary(_ c: PetCard) -> [String] {
        var out: [String] = []
        let what: String?
        switch c.actionType {
        case "payment": what = "결제"
        case "booking": what = "예약"
        case "send_message": what = "메시지 보내기"
        case "phone_call": what = "전화 걸기"
        case "publish": what = "외부에 올리기"
        case "change_permission": what = "권한 바꾸기"
        case "delete": what = "지우기"
        case "other": what = "맥에서 하는 일"
        default: what = nil
        }
        if let w = what { out.append("무엇을: \(w)" + (c.detail.map { " · \($0)" } ?? "")) } else if let d = c.detail { out.append(d) }
        let undo: String?
        switch c.reversibility {
        case "can_cancel": undo = "되돌릴 수 있어요"
        case "conditional": undo = "조건에 따라 되돌릴 수 있어요"
        case "cannot_cancel": undo = "되돌릴 수 없어요"
        default: undo = nil
        }
        if let t = c.reversibilityText, !t.isEmpty { out.append("되돌리기: " + t) } else if let u = undo { out.append("되돌리기: " + u) }
        return out
    }

    /// The card's state under the rows: `status` (sending, failed, answered, expired …; nil while it simply waits, the
    /// question already asks) and `hint` (number keys and the expiry time in KST while it waits).
    public static func stateLine(_ c: PetCard, local: PetCardLocal, now: Date) -> (status: String?, hint: String?, waits: Bool, retry: Bool) {
        let style = PetCardStyle.of(c)
        if c.isPending, style != .elsewhere {
            var hint: [String] = []
            if style != .suggestions, !rows(c).isEmpty {
                hint.append(style == .multiple ? "숫자키로 고르고 Enter로 확정" : "숫자키를 누르고 Enter")
            }
            if let e = c.expiresAt, let at = kst(e, now: now) { hint.append("\(at)까지") }
            let h = hint.isEmpty ? nil : hint.joined(separator: " · ")
            if local.sending != nil { return ("보내는 중…", h, true, false) }
            if let f = local.failure { return ("보내지 못했어요. \(f)", h, true, local.lastAnswer != nil) }
            return (nil, h, false, false)
        }
        var text = c.statusText
        if c.kind == "rule_proposal" {
            if c.status == "answered" { text = "규칙을 만들었어요" } else if c.status == "dismissed" { text = "만들지 않았어요" }
        }
        if c.status == "expired", let e = c.expiresAt, let at = kst(e, now: now) { text += " (\(at))" }
        return (text, nil, c.isPending, false)
    }

    /// Which rows the stored answer chose (to mark them after answering).
    public static func chosenNumbers(_ c: PetCard) -> Set<Int> {
        guard c.status == "answered" else { return [] }
        let rs = rows(c)
        switch PetCardStyle.of(c) {
        case .approval where !c.ruleOptions.isEmpty:
            switch c.answeredAction {
            case "approve":
                if let id = c.answeredRuleID, let r = rs.first(where: { $0.optionID == id }) { return [r.number] }
                return [1]
            case "decline", "deny": return [rs.count]
            default: return []
            }
        case .approval:
            switch c.answeredAction { case "approve": return [1]; case "decline", "deny": return [2]; default: return [] }
        case .ruleProposal:
            return Set(rs.filter { r in r.optionID.map { c.answeredOptionIDs.contains($0) } ?? false }.map { $0.number })
        default:
            return Set(rs.filter { r in r.optionID.map { c.answeredOptionIDs.contains($0) } ?? false }.map { $0.number })
        }
    }

    // MARK: time

    private static let seoul = TimeZone(identifier: "Asia/Seoul") ?? TimeZone(secondsFromGMT: 9 * 3600)!

    /// RFC 3339 → "오후 3:20 KST" (today in Seoul) or "11월 14일 오후 3:20 KST".
    public static func kst(_ rfc3339: String, now: Date = Date()) -> String? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = frac.date(from: rfc3339) ?? ISO8601DateFormatter().date(from: rfc3339) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = seoul
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.timeZone = seoul
        f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "a h:mm" : "M월 d일 a h:mm"
        return f.string(from: d) + " KST"
    }
}

/// The number keys, Enter and Esc on the newest card that waits for an answer (only while the input field is empty, so
/// a message can still start with a number: the held digit goes into the field when other text follows).
public enum PetCardKey: Equatable {
    case digit(Int)
    case enter
    case escape
}

public enum PetCardKeyResult: Equatable {
    /// Not for the card: the key does what it did before.
    case pass
    /// Mark row N; Enter sends it.
    case highlight(Int)
    /// A multiple choice row ticked or unticked.
    case toggle(String)
    case answer(PetCardAnswer)
    /// Esc: the mark or the ticks are cleared.
    case clear
}

public enum PetCardKeys {
    public static func handle(_ key: PetCardKey, card c: PetCard, local: PetCardLocal) -> PetCardKeyResult {
        guard c.isPending, c.answerableHere, local.sending == nil else { return .pass }
        let rows = PetCardRules.rows(c)
        let multiple = PetCardStyle.of(c) == .multiple
        switch key {
        case let .digit(n):
            guard n >= 1, n <= rows.count else { return .pass }
            if multiple, let id = rows[n - 1].optionID { return .toggle(id) }
            return .highlight(n)
        case .enter:
            if multiple { return PetCardRules.confirm(c, ticked: local.ticked).map { .answer($0) } ?? .pass }
            guard let n = local.highlighted, n >= 1, n <= rows.count, let a = rows[n - 1].answer else { return .pass }
            return .answer(a)
        case .escape:
            if local.highlighted != nil || !local.ticked.isEmpty { return .clear }
            return .pass
        }
    }
}
