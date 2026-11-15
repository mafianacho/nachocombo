import Foundation

// Computer Use for Nacho (NACHO-147). The gadget runner of `computer`: the connector path (Nacho in the chat) runs the
// screenshot, display list, mouse, key and typing tools and the accessibility tree tools through it; the MCP path runs
// the tree tools through it (the old tools keep going straight to `ComputerUseBackend`, under their group switches).
//
// Order of checks here: emergency stop -> the tool is one of Nacho's (never AppleScript, shell, files, processes) ->
// arguments against the tool's closed schema -> (on the runner's queue) emergency stop again -> run.
// The approval (card every time unless "always allow") happened on nacho-server before the request arrived; the
// connector already refused a call that came under a revoked "always allow" (`approval_revoked`).
//
// Screenshots: nacho-server turns a connector result into text for the model (`call_connector` → `Value::to_string`,
// docs/ws-protocol.md §3 has no image result), so a PNG cannot be handed over in the result. The picture is attached
// to the chat instead (the pending files of the next message, the same path as "capture → Nacho"); the result says so.

/// A screenshot to put into the chat.
public struct ComputerImageAttachment: Equatable {
    public let name: String
    public let mime: String
    public let data: Data
    public init(name: String, mime: String, data: Data) {
        self.name = name
        self.mime = mime
        self.data = data
    }
}

/// Checks a call's arguments against a registry schema (`GadgetSchema`): only listed keys, every required key, and
/// each value of its type (string length and choices, integer bounds, finite numbers, booleans, string lists).
public enum GadgetArgumentCheck {
    /// nil when the arguments fit; else "bad parameters: …" for the model.
    public static func problem(_ arguments: [String: JSONValue], schema: JSONValue) -> String? {
        guard case .object(let s) = schema, case .object(let props)? = s["properties"] else { return nil }
        let extra = Set(arguments.keys).subtracting(props.keys)
        if !extra.isEmpty { return bad("unknown field \(extra.sorted().map { String($0.prefix(40)) }.joined(separator: ", "))") }
        if case .array(let req)? = s["required"] {
            for case .string(let key) in req where arguments[key] == nil || arguments[key] == .null {
                return bad("\(key) is required")
            }
        }
        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) where value != .null {
            guard case .object(let p)? = props[key] else { continue }
            if let why = valueProblem(value, p) { return bad("\(key) \(why)") }
        }
        return nil
    }

    private static func bad(_ why: String) -> String { PetCommandProblem.badParams(why).message }

    private static func valueProblem(_ v: JSONValue, _ p: [String: JSONValue]) -> String? {
        if case .array(let choices)? = p["enum"] {
            guard choices.contains(v) else {
                return "must be one of \(choices.compactMap { $0.stringValue }.joined(separator: ", "))"
            }
            return nil
        }
        switch p["type"]?.stringValue {
        case "string":
            guard case .string(let s) = v else { return "must be a string" }
            if case .int(let m)? = p["minLength"], s.count < m { return "must have at least \(m) characters" }
            if case .int(let m)? = p["maxLength"], s.count > m { return "must have at most \(m) characters" }
        case "integer":
            let i: Int
            switch v {
            case .int(let x): i = x
            case .double(let d) where d.isFinite && d == d.rounded() && abs(d) < 1e15: i = Int(d)
            default: return "must be an integer"
            }
            if case .int(let m)? = p["minimum"], i < m { return "must be at least \(m)" }
            if case .int(let m)? = p["maximum"], i > m { return "must be at most \(m)" }
        case "number":
            switch v {
            case .int: break
            case .double(let d) where d.isFinite: break
            default: return "must be a finite number"
            }
        case "boolean":
            guard case .bool = v else { return "must be true or false" }
        case "array":
            guard case .array(let items) = v else { return "must be an array" }
            if case .object(let it)? = p["items"], it["type"]?.stringValue == "string" {
                guard items.allSatisfy({ $0.stringValue != nil }) else { return "must be an array of strings" }
            }
            if items.count > 32 { return "has too many items" }
        default:
            break
        }
        return nil
    }
}

/// Keeps Nacho's input away from Nacho Combo's own windows: a click on the chat could press an approval card or
/// "send", keys typed into it would write (or send) a message as the user.
public protocol ComputerSelfGuard: AnyObject {
    /// A Nacho Combo window (chat, approval cards, pet, panels) takes mouse input at this point (screen points).
    func ownsPoint(x: Double, y: Double) -> Bool
    /// If a Nacho Combo window has the keyboard, hands it to the front app. false when the keyboard stayed with us.
    func releaseKeyboard() -> Bool
}

extension PetCommandOutcome {
    /// Nacho's click or keys would land in Nacho Combo itself.
    public static func computerOwnWindow(keyboard: Bool) -> PetCommandOutcome {
        PetCommandOutcome(
            ok: false,
            message: keyboard ? "Nacho Combo's own window has the keyboard, so nothing was typed."
                : "That point is on a Nacho Combo window (the chat or its cards), so it was not clicked.",
            details: ["reason": "own_window",
                      "hint": keyboard ? "click into the target app's field first (computer_click_element), then type again"
                          : "never click Nacho Combo's own windows; read the tree of the target app and click there",
                      "guide_ko": keyboard ? "나초콤보 대화 창에 입력 초점이 있어서 입력하지 않았어요. 입력할 앱의 칸을 먼저 눌러 주세요."
                          : "나초콤보 창(대화·카드) 위는 누르지 않아요.",
                      "gadget": GadgetID.computer.rawValue])
    }

    /// Computer Use is stopped by its emergency stop (⌃⌥⌘.): nothing runs until the user turns it on again.
    public static let computerEmergencyStopped = PetCommandOutcome(
        ok: false, message: "Emergency stop is active: Computer Use is stopped on this Mac.",
        details: ["reason": "emergency_stop",
                  "hint": "do not retry; the user stopped Computer Use with the emergency stop and must turn it on again in Nacho Combo",
                  "guide_ko": "비상정지(⌃⌥⌘.)로 컴퓨터 사용을 멈췄어요. 다시 쓰려면 나초콤보에서 컴퓨터 사용을 켜 주세요.",
                  "gadget": GadgetID.computer.rawValue])
}

/// Runs the `computer` gadget's tools that do not go straight to the backend (see the file comment).
public final class ComputerGadgetRunner: GadgetToolRunning {
    public static let treeAction = "ui_tree"
    public static let findAction = "find_element"
    public static let clickAction = "click_element"

    private let backend: ComputerUseBackend
    private let tree: UITreeReader?
    private let emergencyStopped: () -> Bool
    private let attach: ((ComputerImageAttachment) -> String?)?
    private let selfGuard: ComputerSelfGuard?
    private let queue: DispatchQueue
    private let nachoLegacy: Set<String>
    private let now: () -> Date

    /// `attach` puts a picture into the chat and answers a Korean refusal or nil (the app: the pet's pending files).
    /// Without it screenshots are refused on this path. `elements` nil: the tree tools answer `unavailable`.
    public init(backend: ComputerUseBackend, elements: UIElementAccess?, emergencyStopped: @escaping () -> Bool,
                attach: ((ComputerImageAttachment) -> String?)?, selfGuard: ComputerSelfGuard? = nil,
                tools: [GadgetTool] = GadgetToolRegistry.all,
                queue: DispatchQueue = DispatchQueue(label: "nacho.combo.computer.runner"), now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.tree = elements.map { UITreeReader(access: $0) }
        self.emergencyStopped = emergencyStopped
        self.attach = attach
        self.selfGuard = selfGuard
        self.queue = queue
        self.now = now
        // The old Computer Use tools that are declared to Nacho: only these may run through here.
        nachoLegacy = Set(tools.filter { $0.gadget == .computer && $0.exits.contains(.connector) }.compactMap { $0.legacyMCPName })
    }

    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        if let refused = check(tool, arguments) { return done(refused) }
        queue.async { [self] in
            // Calls wait here one at a time; the emergency stop also stops the ones that were waiting.
            if emergencyStopped() { return done(.computerEmergencyStopped) }
            done(execute(tool, arguments))
        }
    }

    /// The checks that need no queue (also used by tests).
    func check(_ tool: GadgetTool, _ arguments: [String: JSONValue]) -> PetCommandOutcome? {
        guard tool.gadget == .computer else { return .unavailable(tool) }
        if emergencyStopped() { return .computerEmergencyStopped }
        if let legacy = tool.legacyMCPName, !nachoLegacy.contains(legacy) {
            return PetCommandOutcome(ok: false, message: PetCommandProblem.notAllowed("\(tool.mcpName) is not offered to Nacho").message)
        }
        if let why = GadgetArgumentCheck.problem(arguments, schema: tool.inputSchema) { return PetCommandOutcome(ok: false, message: why) }
        return nil
    }

    private func execute(_ tool: GadgetTool, _ arguments: [String: JSONValue]) -> PetCommandOutcome {
        if let legacy = tool.legacyMCPName {
            if let refused = guardInput(legacy, arguments) { return refused }
            return outcome(backend.execute(tool: legacy, arguments: arguments), tool: legacy)
        }
        guard let tree = tree else { return .unavailable(tool) }
        let args = ToolArguments(arguments)
        do {
            switch tool.action {
            case ComputerGadgetRunner.treeAction:
                let limits = UITreeLimits(maxDepth: try args.optionalInt("maxDepth"), maxNodes: try args.optionalInt("maxNodes"),
                                          maxTextLength: try args.optionalInt("maxTextLength"))
                let snapshot = try tree.read(try target(args), limits: limits)
                let message = "Accessibility tree of \(snapshot.app.name.prefix(60)): \(snapshot.nodes.count) elements"
                    + (snapshot.truncated ? " (more left out by the limits)." : ".")
                return PetCommandOutcome(ok: true, message: message, details: snapshot.details())
            case ComputerGadgetRunner.findAction:
                let role = try args.optionalString("role")?.trimmingCharacters(in: .whitespaces)
                let title = try args.optionalString("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !(role ?? "").isEmpty || !(title ?? "").isEmpty else {
                    return PetCommandOutcome(ok: false, message: PetCommandProblem.badParams("give role, title or both").message)
                }
                let max = min(Swift.max(try args.optionalInt("maxResults") ?? UITreeLimits.defaultResults, UITreeLimits.resultRange.lowerBound),
                              UITreeLimits.resultRange.upperBound)
                let found = try tree.find(try target(args), role: role, title: title, maxResults: max)
                let message = found.snapshot.nodes.isEmpty
                    ? "No element matches in \(found.snapshot.app.name.prefix(60)) (\(found.scanned) elements looked at)."
                    : "\(found.snapshot.nodes.count) matching elements in \(found.snapshot.app.name.prefix(60))."
                return PetCommandOutcome(ok: true, message: message, details: found.snapshot.details(scanned: found.scanned))
            case ComputerGadgetRunner.clickAction:
                return try click(args, tree)
            default:
                return .unavailable(tool)
            }
        } catch let e as ToolArgumentError {
            return PetCommandOutcome(ok: false, message: PetCommandProblem.badParams(e.message).message)
        } catch let e as PolicyError {
            return PetCommandOutcome(ok: false, message: e.message)
        } catch {
            return PetCommandOutcome(ok: false, message: "Could not read the screen elements.")
        }
    }

    /// Clicks, drags and keys that would land in Nacho Combo itself are refused (see `ComputerSelfGuard`).
    private func guardInput(_ legacy: String, _ arguments: [String: JSONValue]) -> PetCommandOutcome? {
        guard let g = selfGuard else { return nil }
        let args = ToolArguments(arguments)
        func point(_ xk: String, _ yk: String) -> (Double, Double)? {
            guard let x = try? args.optionalDouble(xk), let y = try? args.optionalDouble(yk) else { return nil }
            return (x, y)
        }
        switch legacy {
        case "mouse_click", "mouse_scroll":
            if let p = point("x", "y"), g.ownsPoint(x: p.0, y: p.1) { return .computerOwnWindow(keyboard: false) }
        case "mouse_drag":
            for (xk, yk) in [("fromX", "fromY"), ("toX", "toY")] {
                if let p = point(xk, yk), g.ownsPoint(x: p.0, y: p.1) { return .computerOwnWindow(keyboard: false) }
            }
        case "key_press", "type_text":
            if !g.releaseKeyboard() { return .computerOwnWindow(keyboard: true) }
        default:
            break
        }
        return nil
    }

    private func target(_ args: ToolArguments) throws -> UITreeTarget {
        let scope = try args.optionalString("scope").map { raw -> UITreeScope in
            guard let s = UITreeScope(rawValue: raw) else { throw ToolArgumentError("scope must be window or app") }
            return s
        } ?? .window
        let app = try args.optionalString("app")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = app, a.isEmpty || a.count > PetCommands.maxAppNameLength { throw ToolArgumentError("app must be 1 to \(PetCommands.maxAppNameLength) characters") }
        let pid = try args.optionalInt("pid")
        if let p = pid, p <= 0 { throw ToolArgumentError("pid must be positive") }
        if pid != nil, app != nil { throw ToolArgumentError("give pid or app, not both") }
        return UITreeTarget(pid: pid, app: app, scope: scope)
    }

    /// By id (an element of a recent read: its middle is clicked, or its default action runs with `press`), or by x/y.
    private func click(_ args: ToolArguments, _ tree: UITreeReader) throws -> PetCommandOutcome {
        let id = try args.optionalString("id")
        let x = try args.optionalDouble("x"), y = try args.optionalDouble("y")
        let press = try args.optionalBool("press") ?? false
        var click: [String: JSONValue] = [:]
        if let b = try args.optionalString("button") { click["button"] = .string(b) }
        if let c = try args.optionalInt("clickCount") { click["clickCount"] = .int(c) }
        switch (id, x, y) {
        case let (nil, x?, y?):
            if press { throw ToolArgumentError("press needs an id") }
            try InputPolicy.validatePoint(x: x, y: y)
            if selfGuard?.ownsPoint(x: x, y: y) == true { return .computerOwnWindow(keyboard: false) }
            click["x"] = .double(x); click["y"] = .double(y)
            return outcome(backend.execute(tool: "mouse_click", arguments: click), tool: "mouse_click",
                           extra: ["clicked": ["x": x, "y": y]])
        case let (id?, nil, nil):
            switch tree.element(id: id) {
            case let .problem(why):
                return PetCommandOutcome(ok: false, message: why, details: ["reason": "stale_element"])
            case let .element(element, info):
                if emergencyStopped() { return .computerEmergencyStopped }
                if info.enabled == false { return PetCommandOutcome(ok: false, message: "That element is disabled.") }
                if press {
                    return tree.press(element)
                        ? PetCommandOutcome(ok: true, message: "Pressed \(info.role).", details: ["id": id])
                        : PetCommandOutcome(ok: false, message: "That element has no default action; click it without press.")
                }
                guard let frame = info.frame, frame.isUsable else {
                    return PetCommandOutcome(ok: false, message: "That element has no place on the screen; try press.")
                }
                let c = frame.center
                try InputPolicy.validatePoint(x: c.x, y: c.y)
                if selfGuard?.ownsPoint(x: c.x, y: c.y) == true { return .computerOwnWindow(keyboard: false) }
                click["x"] = .double(c.x); click["y"] = .double(c.y)
                return outcome(backend.execute(tool: "mouse_click", arguments: click), tool: "mouse_click",
                               extra: ["id": id, "clicked": ["x": (c.x * 10).rounded() / 10, "y": (c.y * 10).rounded() / 10]])
            }
        default:
            throw ToolArgumentError("give either id, or both x and y")
        }
    }

    /// A backend result as a connector outcome. JSON text is merged into the details; an image goes to the chat.
    func outcome(_ result: ToolResult, tool: String, extra: [String: Any] = [:]) -> PetCommandOutcome {
        var texts: [String] = []
        var images: [Data] = []
        for c in result.content {
            switch c {
            case .text(let t): texts.append(t)
            case .image(let b64, _): if let d = Data(base64Encoded: b64) { images.append(d) }
            }
        }
        if result.isError { return PetCommandOutcome(ok: false, message: texts.joined(separator: " ")) }
        var details = extra
        var message = texts.joined(separator: " ")
        if texts.count == 1, let data = texts[0].data(using: .utf8),
           let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (k, v) in o where details[k] == nil && k != "ok" && k != "message" { details[k] = v }
            message = "Done."
        }
        if let png = images.first {
            guard let attach = attach else {
                return PetCommandOutcome(ok: false, message: "Screenshots cannot be delivered on this path.")
            }
            let stamp = ComputerGadgetRunner.stamp(now())
            if let refusal = attach(ComputerImageAttachment(name: "screen-\(stamp).png", mime: "image/png", data: png)) {
                return PetCommandOutcome(ok: false, message: "The screenshot could not be attached to the chat.",
                                         details: ["reason": "attach_failed", "guide_ko": refusal])
            }
            details["delivered"] = "chat_attachment"
            details["size"] = texts.first ?? ""
            message = "The screenshot is attached to the chat as a file waiting to be sent; you cannot see it yet. "
                + "It reaches you with the user's next message: ask the user to send it, then look at it. "
                + "To read the screen as text right now, use the accessibility tree (ui_tree)."
            details["guide_ko"] = "화면을 찍어 대화 입력 칸에 붙였어요. 보내기를 누르면 나초가 볼 수 있어요."
        }
        return PetCommandOutcome(ok: true, message: message, details: details.isEmpty ? nil : details)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
