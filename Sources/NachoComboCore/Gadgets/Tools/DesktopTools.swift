import Foundation

/// Desktop tidy-up and window arrangement proposals (`desktop`, NACHO-38). Nacho looks, proposes (plan), and runs only what
/// the user approved: `desktop_tidy_apply` and `desktop_arrange_apply` are `change` tools that the connector declares with
/// `approval: "required"` every time (`alwaysRequiresApproval`). Moved files are journaled for one-step undo. Nothing is
/// ever deleted or overwritten. apply and undo are connector only: an external MCP client has no approval card.
/// Runner: `DesktopToolRunner` (Core, tested with a temporary desktop and a fake window host).
public enum DesktopTools: GadgetToolProvider {
    public static let gadget = GadgetID.desktop

    static let planID = GadgetSchema.string("계획 번호(plan_id). 계획을 만든 답에 들어 있어요", minLength: 1, maxLength: 32)

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .desktop, action: "tidy_plan",
                   korean: "바탕화면의 파일을 훑어 스크린샷·이미지·문서·압축·설치 파일·기타로 나눈 이동 계획을 만들어요. plan_id와 분류별 개수, 파일 이름(최대 50개)을 줘요. 아무것도 옮기지 않아요.",
                   english: "Looks at the plain files directly on the desktop and plans where each would go (~/Desktop/정리됨/<category>/): plan_id, counts per category, up to 50 file names. Moves nothing. The plan is valid for 10 minutes.",
                   output: "{ok, message, plan_id, expires_in_seconds, total, skipped, categories:[{category, folder, count}], files:[{name, category}], more}",
                   risk: .read),
        GadgetTool(gadget: .desktop, action: "tidy_apply",
                   korean: "승인받은 정리 계획(plan_id)을 실행해 바탕화면 파일을 정리됨 폴더로 옮겨요. 사용자 승인을 매번 받아요. 지우거나 덮어쓰지 않고, tidy_undo로 되돌릴 수 있어요.",
                   english: "Runs a tidy plan: moves the desktop files into ~/Desktop/정리됨/<category>/. The user approves every run. Files changed since the plan are skipped and reported; a plan older than 10 minutes is refused (plan_stale). Nothing is deleted or overwritten.",
                   input: GadgetSchema.object(["plan_id": planID], required: ["plan_id"]),
                   output: "{ok, message, tidy_id, moved, categories, skipped:[{name, reason}], skipped_count}",
                   risk: .change, exits: [.connector], alwaysRequiresApproval: true),
        GadgetTool(gadget: .desktop, action: "tidy_undo",
                   korean: "가장 최근 바탕화면 정리(또는 tidy_id)를 원래 자리로 되돌려요. 원래 자리에 다른 파일이 있으면 덮어쓰지 않고 \"되돌리지 못함\"으로 알려요.",
                   english: "Puts the files of the latest desktop tidy (or tidy_id) back where they were. A file whose old place is taken stays and is reported; nothing is overwritten.",
                   input: GadgetSchema.object(["tidy_id": GadgetSchema.string("되돌릴 정리 번호(기본: 가장 최근)", minLength: 1, maxLength: 32)]),
                   output: "{ok, message, tidy_id, restored, not_restored:[{name, reason, label_ko}], complete}",
                   risk: .change, exits: [.connector]),
        GadgetTool(gadget: .desktop, action: "tidy_history",
                   korean: "30일 안의 바탕화면 정리 기록(일시, 옮긴 개수, 되돌렸는지)을 봐요. 파일 이름은 담지 않아요.",
                   english: "Desktop tidies of the last 30 days: tidy_id, time, number of files, whether undone. No file names.",
                   output: "{ok, message, entries:[{tidy_id, at, count, undone, pending_restore}]}", risk: .read),
        GadgetTool(gadget: .desktop, action: "arrange_suggest",
                   korean: "열린 창(앱 이름만, 창 제목은 안 봐요)으로 배치안과 plan_id를 만들어요. 아무것도 옮기지 않아요. 권한: 손쉬운 사용.",
                   english: "Proposes a window arrangement for the apps with open windows (app names only, never window titles): plan_id and the window_arrange_apps arguments. Moves nothing. Valid for 10 minutes.",
                   output: "{ok, message, plan_id, expires_in_seconds, arrangement, apps, window_arguments:{apps, arrangement}}",
                   risk: .read, permissions: [.accessibility]),
        GadgetTool(gadget: .desktop, action: "arrange_apply",
                   korean: "승인받은 배치안(plan_id)을 기존 창 배치(WindowTiling)로 적용해요. 사용자 승인을 매번 받아요. 되돌리기는 window_undo를 써요. 권한: 손쉬운 사용.",
                   english: "Applies an arrangement proposal through Window Snap's arrange_apps. The user approves every run. Undo with window_undo (combo_window_undo).",
                   input: GadgetSchema.object(["plan_id": planID], required: ["plan_id"]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing, undo_with}",
                   risk: .change, permissions: [.accessibility], exits: [.connector], alwaysRequiresApproval: true),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .desktop,
        summary: "바탕화면의 흩어진 파일을 분류해 정리됨 폴더로 옮기고, 열린 창을 보기 좋게 배치하는 걸 도와요. 먼저 계획을 보여 주고, 사용자가 승인한 것만 실행해요.",
        canDo: ["바탕화면 파일을 스크린샷·이미지·문서·압축·설치 파일·기타로 나눈 이동 계획 보기",
                "승인받은 계획으로 파일 옮기기(지우기·덮어쓰기 없음)와 한 번에 되돌리기",
                "30일 안의 정리 기록 보기",
                "열린 창으로 배치안 만들기와 승인받은 배치 적용(되돌리기는 window_undo)"],
        steps: ["tidy_plan으로 계획을 만들고 분류별 개수와 파일 이름을 사용자에게 보여 줘요. 이때는 아무것도 옮기지 않아요.",
                "사용자가 정리를 원하면 같은 plan_id로 tidy_apply를 불러요. 승인 카드가 먼저 떠요. 계획은 10분 안에만 써요(plan_stale이면 다시 계획을 만들어요).",
                "결과의 skipped(계획 뒤에 바뀐 파일)를 알려 주고, 마음에 안 들면 tidy_undo로 되돌려요.",
                "창 배치는 arrange_suggest로 안을 만들어 보여 주고, 사용자가 원하면 arrange_apply를 불러요. 되돌리기는 window_undo예요."],
        examples: [
            .init("tidy_plan", note: "바탕화면을 정리하기 전에 계획부터 보여 줄 때"),
            .init("tidy_apply", .object(["plan_id": .string("a1b2c3d4")]), note: "사용자가 계획대로 정리하라고 했을 때(승인 카드가 떠요)"),
            .init("tidy_undo", note: "방금 정리를 취소하고 싶을 때"),
            .init("arrange_suggest", note: "열린 창을 배치할 안을 만들 때"),
        ],
        limits: ["바탕화면 바로 아래의 일반 파일만 옮겨요. 폴더·앱·바로가기(심볼릭 링크)·숨김 파일·정리됨 폴더·받는 중인 파일(.download .crdownload .part)·최근 2분 안에 바뀐 파일은 건너뛰어요.",
                 "파일은 ~/Desktop/정리됨/<분류>/로만 옮기고, 이름이 겹치면 \"이름 2.ext\"처럼 번호를 붙여요. 지우거나 덮어쓰지 않아요.",
                 "정리 기록은 30일 보관하고, 기록만 지워요(파일은 건드리지 않아요).",
                 "되돌릴 때 원래 자리에 다른 파일이 있으면 그대로 두고 \"되돌리지 못함\"으로, 옮긴 파일이 없으면 \"찾지 못함\"으로 알려요.",
                 "tidy_apply·arrange_apply는 사용자 승인을 매번 받아요('항상 허용'이 없어요). 승인 카드가 없는 MCP 클라이언트에는 apply·undo를 열지 않아요.",
                 "처음 쓸 때 macOS가 바탕화면 폴더 접근을 물을 수 있어요. 창 배치는 손쉬운 사용 권한과 창 배치 가젯이 필요해요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .desktop, flow: "tidy_preview",
                     description: "Preview how the desktop files would be tidied (counts and names per category). Nothing is moved.",
                     template: "Read nachocombo://gadgets/desktop/guide. Call desktop_tidy_plan and show the user, in Korean, how many files would go "
                         + "to each category and the file names. Do not move anything; tell the user the tidy-up itself runs in the Nacho chat after approval."),
    ]
}

// MARK: runner

/// The window side of the arrangement tools (the app answers on the main thread).
public protocol DesktopTidyHost: AnyObject {
    /// Names of the apps with open windows; nil when the Mac does not let the app look (Accessibility off).
    func windowApps(done: @escaping ([String]?) -> Void)
    /// Applies `window_arrange_apps` with the arrangement of the approved proposal (its result is the window tool's result).
    func arrange(apps: [String], arrangement: String, done: @escaping (PetCommandOutcome) -> Void)
}

public final class DesktopToolRunner: GadgetToolRunning {
    public static let gadgets: [GadgetID] = [.desktop]
    public static let maxArrangeApps = 9
    public static let arrangeLifetime: TimeInterval = DesktopTidyEngine.planLifetime

    private struct ArrangePlan {
        let id: String
        let apps: [String]
        let arrangement: String
        let expiresAt: Date
    }

    private let engine: DesktopTidyEngine
    private let host: DesktopTidyHost?
    private let now: () -> Date
    private let lock = NSLock()
    private var arrangePlans: [String: ArrangePlan] = [:]

    public init(engine: DesktopTidyEngine = DesktopTidyEngine(), host: DesktopTidyHost? = nil, now: @escaping () -> Date = { Date() }) {
        self.engine = engine
        self.host = host
        self.now = now
        engine.pruneJournal()
    }

    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        switch DesktopToolRunner.check(action: tool.action, arguments) {
        case let .failure(outcome): done(outcome)
        case let .success(args):
            switch tool.action {
            case "arrange_suggest": suggest(done: done)
            case "arrange_apply": arrange(planID: args.planID ?? "", done: done)
            default:
                DispatchQueue.global(qos: .userInitiated).async { [engine] in
                    done(DesktopToolRunner.runTidy(tool.action, args, engine: engine))
                }
            }
        }
    }

    // MARK: arguments

    struct Arguments {
        var planID: String?
        var tidyID: String?
    }

    static func check(action: String, _ arguments: [String: JSONValue]) -> Checked<Arguments> {
        func bad(_ text: String) -> Checked<Arguments> { .failure(PetCommandOutcome(ok: false, message: "bad parameters: \(text)")) }
        let allowed: Set<String>
        switch action {
        case "tidy_apply", "arrange_apply": allowed = ["plan_id"]
        case "tidy_undo": allowed = ["tidy_id"]
        default: allowed = []
        }
        let extra = Set(arguments.keys).subtracting(allowed)
        guard extra.isEmpty else { return bad("unknown field \(extra.sorted().joined(separator: ", "))") }
        var out = Arguments()
        func text(_ key: String) -> Checked<String?> {
            guard let value = arguments[key] else { return .success(nil) }
            guard case .string(let raw) = value else { return .failure(PetCommandOutcome(ok: false, message: "bad parameters: \(key) must be a string")) }
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...32).contains(s.count) else { return .failure(PetCommandOutcome(ok: false, message: "bad parameters: \(key) must be 1-32 characters")) }
            return .success(s)
        }
        switch text("plan_id") {
        case .failure(let o): return .failure(o)
        case .success(let v): out.planID = v
        }
        switch text("tidy_id") {
        case .failure(let o): return .failure(o)
        case .success(let v): out.tidyID = v
        }
        if (action == "tidy_apply" || action == "arrange_apply") && out.planID == nil { return bad("plan_id is required") }
        return .success(out)
    }

    // MARK: tidy

    static func runTidy(_ action: String, _ args: Arguments, engine: DesktopTidyEngine) -> PetCommandOutcome {
        switch action {
        case "tidy_plan": return planOutcome(engine.plan())
        case "tidy_apply": return applyOutcome(engine.apply(planID: args.planID ?? ""))
        case "tidy_undo": return undoOutcome(engine.undo(tidyID: args.tidyID))
        case "tidy_history": return historyOutcome(engine.history())
        default: return PetCommandOutcome(ok: false, message: "unknown desktop action \(action)")
        }
    }

    static func failure(_ error: DesktopTidyError) -> PetCommandOutcome {
        switch error {
        case .desktopUnreadable:
            return reason("desktop_unreadable", "Nacho Combo cannot read the Desktop folder.",
                          hint: "tell the user to allow Desktop folder access for Nacho Combo (System Settings > Privacy & Security > Files and Folders)",
                          ko: "시스템 설정 > 개인정보 보호 및 보안 > 파일 및 폴더에서 Nacho Combo의 바탕화면 폴더 접근을 켜 주세요.")
        case .planNotFound:
            return reason("plan_not_found", "No such plan (already used, or the app restarted).", hint: "call tidy_plan again and show the plan to the user",
                          ko: "그 계획이 없어요. 계획을 다시 만들게요.")
        case .planStale:
            return reason("plan_stale", "The plan is older than 10 minutes.", hint: "call tidy_plan again, show the new plan and ask the user again",
                          ko: "계획이 10분이 지나 만료됐어요. 다시 만들어 보여 드릴게요.")
        case .tidyNotFound:
            return reason("tidy_not_found", "No such tidy in the last 30 days.", hint: "call tidy_history for the list", ko: "그 정리 기록이 없어요.")
        case .alreadyUndone:
            return reason("already_undone", "That tidy was already undone.", hint: "do not retry", ko: "이미 되돌린 정리예요.")
        case .nothingToUndo:
            return reason("nothing_to_undo", "There is no tidy to undo in the last 30 days.", hint: "do not retry", ko: "되돌릴 정리가 없어요.")
        }
    }

    static func reason(_ code: String, _ message: String, hint: String, ko: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: false, message: message, details: ["reason": code, "hint": hint, "guide_ko": ko])
    }

    static func planOutcome(_ result: Result<DesktopTidyPlan, DesktopTidyError>) -> PetCommandOutcome {
        switch result {
        case .failure(let e): return failure(e)
        case .success(let plan):
            var details: [String: Any] = ["total": plan.total, "skipped": plan.skippedCount,
                                          "destination": "~/Desktop/\(DesktopTidyEngine.folderName)/<category>/"]
            let counts = plan.counts
            details["categories"] = DesktopCategory.allCases.compactMap { c -> [String: Any]? in
                guard let n = counts[c], n > 0 else { return nil }
                return ["category": c.rawValue, "folder": c.folderName, "count": n]
            }
            details["files"] = plan.candidates.prefix(DesktopTidyEngine.maxListedNames).map { ["name": String($0.name.prefix(200)), "category": $0.category.rawValue] }
            details["more"] = max(0, plan.total - DesktopTidyEngine.maxListedNames)
            guard plan.total > 0 else {
                return PetCommandOutcome(ok: true, message: "There is nothing to tidy on the desktop.", details: details)
            }
            details["plan_id"] = plan.id
            details["expires_in_seconds"] = Int(DesktopTidyEngine.planLifetime)
            return PetCommandOutcome(ok: true, message: "\(plan.total) desktop files could be tidied. Nothing was moved.", details: details)
        }
    }

    static func applyOutcome(_ result: Result<DesktopTidyApplied, DesktopTidyError>) -> PetCommandOutcome {
        switch result {
        case .failure(let e): return failure(e)
        case .success(let done):
            var details: [String: Any] = ["moved": done.moves.count, "skipped_count": done.skipped.count,
                                          "skipped": done.skipped.prefix(DesktopTidyEngine.maxListedNames).map { ["name": String($0.name.prefix(200)), "reason": $0.reason] }]
            details["categories"] = DesktopCategory.allCases.compactMap { c -> [String: Any]? in
                guard let n = done.counts[c], n > 0 else { return nil }
                return ["category": c.rawValue, "folder": c.folderName, "count": n]
            }
            guard let id = done.tidyID else {
                return PetCommandOutcome(ok: true, message: "Nothing was moved: every file changed or is in use since the plan.", details: details)
            }
            details["tidy_id"] = id
            details["undo_with"] = "desktop_tidy_undo"
            if !done.journalSaved {
                details["journal_saved"] = false
                return PetCommandOutcome(ok: true, message: "Moved \(done.moves.count) files, but the undo record could not be saved: tell the user undo is not available.", details: details)
            }
            return PetCommandOutcome(ok: true, message: "Moved \(done.moves.count) files into \(DesktopTidyEngine.folderName). Undo with desktop_tidy_undo.", details: details)
        }
    }

    static func undoOutcome(_ result: Result<DesktopTidyUndone, DesktopTidyError>) -> PetCommandOutcome {
        switch result {
        case .failure(let e): return failure(e)
        case .success(let undone):
            func label(_ reason: String) -> String {
                switch reason {
                case "conflict": return "되돌리지 못함 (원래 자리에 다른 파일이 있어요)"
                case "not_found": return "찾지 못함 (옮긴 파일이 없어요)"
                default: return "되돌리지 못함"
                }
            }
            let details: [String: Any] = [
                "tidy_id": undone.tidyID, "restored": undone.restored, "complete": undone.complete,
                "not_restored": undone.notRestored.prefix(DesktopTidyEngine.maxListedNames).map {
                    ["name": String($0.name.prefix(200)), "reason": $0.reason, "label_ko": label($0.reason)]
                },
            ]
            let tail = undone.notRestored.isEmpty ? "" : " \(undone.notRestored.count) files were not restored (see not_restored)."
            return PetCommandOutcome(ok: true, message: "Restored \(undone.restored) files to the desktop.\(tail)", details: details)
        }
    }

    static func historyOutcome(_ rows: [DesktopTidyHistoryRow]) -> PetCommandOutcome {
        let formatter = ISO8601DateFormatter()
        let entries: [[String: Any]] = rows.map {
            ["tidy_id": $0.tidyID, "at": formatter.string(from: $0.at), "count": $0.count, "undone": $0.undone, "pending_restore": $0.pendingRestore]
        }
        return PetCommandOutcome(ok: true, message: rows.isEmpty ? "No desktop tidy in the last 30 days." : "\(rows.count) desktop tidies in the last 30 days.",
                                 details: ["entries": entries])
    }

    // MARK: arrange

    /// Two or three apps side by side, four in quadrants, more in a grid.
    static func arrangement(forCount count: Int) -> String {
        switch count {
        case ...3: return WindowArrangement.columns.rawValue
        case 4: return WindowArrangement.quadrants.rawValue
        default: return WindowArrangement.grid.rawValue
        }
    }

    private func suggest(done: @escaping (PetCommandOutcome) -> Void) {
        guard let host = host else { return done(.unavailable(DesktopTools.tools[4])) }
        host.windowApps { [weak self] names in
            guard let self = self else { return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing")) }
            guard let names = names else { return done(.permissionNeeded(.desktop, .accessibility)) }
            var seen = Set<String>()
            let apps = names.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(DesktopToolRunner.maxArrangeApps).map { String($0.prefix(200)) }
            guard apps.count >= 2 else {
                return done(PetCommandOutcome(ok: true, message: "Fewer than two apps have open windows, so there is nothing to arrange.",
                                              details: ["apps": apps]))
            }
            let moment = self.now()
            let plan = ArrangePlan(id: DesktopTidyEngine.newID(), apps: apps, arrangement: DesktopToolRunner.arrangement(forCount: apps.count),
                                   expiresAt: moment.addingTimeInterval(DesktopToolRunner.arrangeLifetime))
            self.lock.lock()
            self.arrangePlans = self.arrangePlans.filter { $0.value.expiresAt > moment }
            if self.arrangePlans.count >= DesktopTidyEngine.maxStoredPlans, let oldest = self.arrangePlans.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
                self.arrangePlans[oldest.key] = nil
            }
            self.arrangePlans[plan.id] = plan
            self.lock.unlock()
            done(PetCommandOutcome(ok: true, message: "Proposed \(plan.arrangement) for \(apps.count) apps. Nothing was moved.",
                                   details: ["plan_id": plan.id, "expires_in_seconds": Int(DesktopToolRunner.arrangeLifetime),
                                             "arrangement": plan.arrangement, "apps": apps,
                                             "window_arguments": ["apps": apps, "arrangement": plan.arrangement]]))
        }
    }

    private func arrange(planID: String, done: @escaping (PetCommandOutcome) -> Void) {
        let moment = now()
        lock.lock()
        let plan = arrangePlans[planID]
        if plan != nil { arrangePlans[planID] = nil }
        lock.unlock()
        guard let found = plan else { return done(DesktopToolRunner.failure(.planNotFound)) }
        guard found.expiresAt > moment else { return done(DesktopToolRunner.failure(.planStale)) }
        guard let host = host else { return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing")) }
        host.arrange(apps: found.apps, arrangement: found.arrangement) { outcome in
            var details = outcome.details ?? [:]
            details["undo_with"] = "window_undo"
            done(PetCommandOutcome(ok: outcome.ok, message: outcome.message, gadgets: outcome.gadgets, details: details))
        }
    }
}
