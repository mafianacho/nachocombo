import Foundation

/// Runs the tools of one or more gadgets. Gadget lanes implement it (app side, usually hopping to the main thread)
/// and register it on `GadgetToolDispatcher.shared`. Arguments are the JSON object of the call; validate them against
/// closed lists before touching anything. `done` must be called exactly once, on any thread.
public protocol GadgetToolRunning: AnyObject {
    func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void)
}

/// Why a gadget tool did not run, as shared `reason` values in `ok:false` results.
public enum GadgetToolRefusal: String, Equatable {
    /// The gadget is switched off in Nacho Combo. Nacho asks the user (ask_choice) and calls combo_set_gadget.
    case gadgetOff = "gadget_off"
    /// A macOS permission is missing.
    case permissionNeeded = "permission_needed"
    /// "Always allow" was switched off and the server had not read the new declaration yet: no approval card ran.
    case approvalRevoked = "approval_revoked"
    /// The user switched this action off (NACHO-131 Connections tab).
    case actionDisabled = "action_disabled"
    /// Nothing in this build runs the tool (its gadget lane has not landed, or the app is closing).
    case unavailable
}

extension PetCommandOutcome {
    /// `ok:false` with a shared `reason`, an English `hint` for the model and Korean `guide_ko` for the user.
    public static func refused(_ reason: GadgetToolRefusal, message: String, hint: String, koreanGuide: String,
                               extra: [String: Any] = [:]) -> PetCommandOutcome {
        var details: [String: Any] = ["reason": reason.rawValue, "hint": hint, "guide_ko": koreanGuide]
        for (k, v) in extra { details[k] = v }
        return PetCommandOutcome(ok: false, message: message, details: details)
    }

    public static func gadgetOff(_ gadget: GadgetID) -> PetCommandOutcome {
        refused(.gadgetOff, message: "\(gadget.displayName) is switched off in Nacho Combo.",
                hint: "ask the user with ask_choice, then call combo_set_gadget",
                koreanGuide: "\(gadget.koreanName) 가젯이 꺼져 있어요. 켜 드릴까요?",
                extra: ["gadget": gadget.rawValue])
    }

    public static func permissionNeeded(_ gadget: GadgetID, _ permission: OSPermission) -> PetCommandOutcome {
        refused(.permissionNeeded, message: "Nacho Combo has no \(permission.displayName) permission.",
                hint: "tell the user how to allow it (guide_ko); the app cannot grant it itself",
                koreanGuide: "시스템 설정 > 개인정보 보호 및 보안 > \(permission.koreanName)에서 Nacho Combo를 켜 주세요.",
                extra: ["gadget": gadget.rawValue, "permission": permission.rawValue])
    }

    public static func approvalRevoked(_ gadget: GadgetID) -> PetCommandOutcome {
        refused(.approvalRevoked,
                message: "The user just turned off 'always allow' for \(gadget.displayName), so no approval card ran for this call.",
                hint: "call the tool again; the user will be asked to approve it",
                koreanGuide: "\(gadget.koreanName)의 '항상 허용'이 꺼졌어요. 다시 요청하면 승인 카드가 떠요.",
                extra: ["gadget": gadget.rawValue])
    }

    public static func actionDisabled(_ name: String) -> PetCommandOutcome {
        refused(.actionDisabled, message: "This action is switched off in Nacho Combo by the user.",
                hint: "do not retry; tell the user it is switched off in Nacho Combo",
                koreanGuide: "나초콤보 연결 설정에서 이 행동을 꺼 두었어요.", extra: ["action": String(name.prefix(64))])
    }

    public static func unavailable(_ tool: GadgetTool) -> PetCommandOutcome {
        refused(.unavailable, message: "\(tool.mcpName) is not available in this Nacho Combo build.",
                hint: "do not retry; tell the user this action is not available yet",
                koreanGuide: "이 버전의 나초콤보에서는 아직 쓸 수 없는 기능이에요.")
    }
}

extension OSPermission {
    public var koreanName: String {
        switch self {
        case .screenRecording: return "화면 기록"
        case .accessibility: return "손쉬운 사용"
        case .automation: return "자동화"
        }
    }
}

/// Registry name → gadget runner. Shared by both exits: the MCP server and the connector bridge call `run`.
/// Built-in tools (`combo_gadget_guide`) are answered here without a runner.
public final class GadgetToolDispatcher {
    public static let shared = GadgetToolDispatcher()

    private let lock = NSLock()
    private var runners: [GadgetID: GadgetToolRunning] = [:]
    private var isOn: (GadgetID) -> Bool
    private var granted: (OSPermission) -> Bool
    private let tools: [GadgetTool]

    /// `gadgetIsOn` / `permissionGranted` default to true (Linux tests, CLI); the app sets the real ones at launch.
    public init(tools: [GadgetTool] = GadgetToolRegistry.all, gadgetIsOn: @escaping (GadgetID) -> Bool = { _ in true },
                permissionGranted: @escaping (OSPermission) -> Bool = { _ in true }) {
        self.tools = tools
        self.isOn = gadgetIsOn
        self.granted = permissionGranted
    }

    public func register(_ runner: GadgetToolRunning, for gadgets: [GadgetID]) {
        lock.lock(); defer { lock.unlock() }
        for g in gadgets { runners[g] = runner }
    }

    public func setState(gadgetIsOn: @escaping (GadgetID) -> Bool, permissionGranted: @escaping (OSPermission) -> Bool) {
        lock.lock(); defer { lock.unlock() }
        isOn = gadgetIsOn
        granted = permissionGranted
    }

    public func runner(for gadget: GadgetID) -> GadgetToolRunning? {
        lock.lock(); defer { lock.unlock() }
        return runners[gadget]
    }

    /// Checks (gadget on, permissions) then runs. `done` is called exactly once.
    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], exit: GadgetToolExit,
                    done: @escaping (PetCommandOutcome) -> Void) {
        if let answer = builtIn(tool, arguments: arguments, exit: exit) { return done(answer) }
        lock.lock()
        let on = isOn
        let allowed = granted
        let runner = runners[tool.gadget]
        lock.unlock()
        if tool.requiresGadgetOn, !on(tool.gadget) { return done(.gadgetOff(tool.gadget)) }
        if tool.requiresGadgetOn, let missing = tool.permissions.sorted().first(where: { !allowed($0) }) {
            return done(.permissionNeeded(tool.gadget, missing))
        }
        guard let r = runner else { return done(.unavailable(tool)) }
        r.run(tool, arguments: arguments, done: done)
    }

    /// Waits for the result (MCP server threads only, never the main thread).
    public func runAndWait(_ tool: GadgetTool, arguments: [String: JSONValue], exit: GadgetToolExit,
                           timeout: TimeInterval = 60) -> PetCommandOutcome {
        let sem = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        run(tool, arguments: arguments, exit: exit) { box.set($0); sem.signal() }
        guard sem.wait(timeout: .now() + timeout) == .success, let outcome = box.value else {
            return PetCommandOutcome(ok: false, message: "\(tool.mcpName) did not answer in \(Int(timeout)) seconds.")
        }
        return outcome
    }

    private final class OutcomeBox {
        private let lock = NSLock()
        private var stored: PetCommandOutcome?
        func set(_ o: PetCommandOutcome) { lock.lock(); if stored == nil { stored = o }; lock.unlock() }
        var value: PetCommandOutcome? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    // MARK: built-in

    public static let guideAction = "gadget_guide"

    private func builtIn(_ tool: GadgetTool, arguments: [String: JSONValue], exit: GadgetToolExit) -> PetCommandOutcome? {
        guard tool.gadget == .combo, tool.action == GadgetToolDispatcher.guideAction else { return nil }
        let extra = Set(arguments.keys).subtracting(["gadget"])
        guard extra.isEmpty else {
            return PetCommandOutcome(ok: false, message: "bad parameters: unknown field \(extra.sorted().joined(separator: ", "))")
        }
        guard case .string(let raw)? = arguments["gadget"], let gadget = GadgetID(named: raw) else {
            return PetCommandOutcome(ok: false, message: "bad parameters: gadget must be one of \(GadgetID.allCases.map { $0.rawValue }.joined(separator: ", "))")
        }
        guard let guide = GadgetToolRegistry.guide(for: gadget) else {
            let names = tools.filter { $0.gadget == gadget && $0.exits.contains(exit) }
                .map { exit == .mcp ? $0.mcpName : $0.declaredConnectorName }
            return PetCommandOutcome(ok: true, message: "\(gadget.displayName) has no written guide yet.",
                                     details: ["gadget": gadget.rawValue, "tools": names])
        }
        return PetCommandOutcome(ok: true, message: "Guide of \(gadget.displayName).",
                                 details: ["gadget": gadget.rawValue, "guide": guide.render(for: exit, tools: tools)])
    }
}

/// Runs the migrated `combo_*` capabilities (window, apps, device, dim, shelf, workspaces, gadgets) through the old
/// checks (`PetCommands.parse` under the legacy name) and the pet's executor. The app registers it for
/// `PetCommandToolRunner.gadgets`; the MCP exit uses it, the connector keeps its direct path.
public final class PetCommandToolRunner: GadgetToolRunning {
    public static let gadgets: [GadgetID] = [.combo, .window, .appswitch, .device, .dim, .shelf]

    private weak var executor: PetCommandExecuting?
    private let allowQuit: Bool

    public init(executor: PetCommandExecuting, allowQuit: Bool = PetCommands.declaresQuitApp) {
        self.executor = executor
        self.allowQuit = allowQuit
    }

    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        guard let legacy = tool.legacyConnectorName else { return done(.unavailable(tool)) }
        switch PetCommands.parse(capability: legacy, params: JSONValue.object(arguments).jsonObject, allowQuit: allowQuit) {
        case let .failure(problem):
            done(PetCommandOutcome(ok: false, message: problem.message))
        case let .success(command):
            guard let ex = executor else { return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing")) }
            ex.execute(command, done: done)
        }
    }
}
