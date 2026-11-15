import Foundation

// What Nacho may do on this Mac when asked in the chat. Nacho Combo registers these as connector capabilities on
// nacho-server's `/ws/connector` (docs/ws-protocol.md §3): the server offers them to the model as tools and forwards a
// call as `{"type":"request","id","capability","params"}`. Every call is validated here against closed lists before
// the app touches anything; anything outside them is refused with a reason the model can relay.
//
// Contract with nacho-server (fixed by the consigliere; change it there first):
// - names are `combo_*`; descriptions are Korean, at most 200 characters, saying what the tool does and when to use it
//   (the server's tool picker chooses by these descriptions);
// - a risky capability carries `"approval": "required"` in hello and the server shows an approval card before it runs
//   (nacho-server production cf88369, #57). `combo_quit_app` is declared with it (`PetCommands.declaresQuitApp`);
//   with the switch off the app would neither declare nor accept such a call.

public enum PetCommand: Equatable {
    /// Snap the front window (or the front window of the named running app) to a position.
    case arrangeWindow(SnapAction, app: String?)
    /// Switch a gadget on or off. Never Computer Use or the pet itself.
    case setGadget(ModuleID, on: Bool)
    case listGadgets
    /// Running apps (and, when asked, installed ones).
    case listApps(installed: Bool)
    case openApp(String)
    case focusApp(String)
    case hideApp(String)
    /// Risky: only when declared (approval card on the server).
    case quitApp(String)
    case listWindows
    case layoutWindows([PetWindowPlacement])
    case setSystem(PetSystemChange)
    /// Focus Dim strength in percent (10...90).
    case setDimStrength(Int)
    /// Empties the File Shelf (undoable in the shelf; original files are never touched).
    case clearShelf
    case saveWorkspace(String)
    case applyWorkspace(String)
    case listWorkspaces
}

public enum PetCommandProblem: Error, Equatable {
    case unknownCapability(String)
    case badParams(String)
    case notAllowed(String)

    /// English for the model (tool results are read by the model, not shown to the user directly).
    public var message: String {
        switch self {
        case let .unknownCapability(name): return "unknown capability \(name)"
        case let .badParams(why): return "bad parameters: \(why)"
        case let .notAllowed(why): return "not allowed: \(why)"
        }
    }
}

/// What the app answers. `ok == false` is still a normal answer (the model tells the user what went wrong).
public struct PetCommandOutcome: Equatable {
    public var ok: Bool
    public var message: String
    public var gadgets: [String: String]?
    /// Structured extras (apps, windows, workspaces …); JSON-serializable values only.
    public var details: [String: Any]?

    public init(ok: Bool, message: String, gadgets: [String: String]? = nil, details: [String: Any]? = nil) {
        self.ok = ok
        self.message = message
        self.gadgets = gadgets
        self.details = details
    }

    public var resultJSON: [String: Any] {
        var o: [String: Any] = ["ok": ok, "message": message]
        if let g = gadgets { o["gadgets"] = g }
        if let d = details, JSONSerialization.isValidJSONObject(d) { for (k, v) in d where o[k] == nil { o[k] = v } }
        return o
    }

    public static func == (a: PetCommandOutcome, b: PetCommandOutcome) -> Bool {
        func json(_ d: [String: Any]?) -> Data? {
            d.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        }
        return a.ok == b.ok && a.message == b.message && a.gadgets == b.gadgets && json(a.details) == json(b.details)
    }
}

public enum PetCommands {
    public static let arrangeWindow = "combo_arrange_window"
    public static let setGadget = "combo_set_gadget"
    public static let listGadgets = "combo_list_gadgets"
    public static let listApps = "combo_list_apps"
    public static let openApp = "combo_open_app"
    public static let focusApp = "combo_focus_app"
    public static let hideApp = "combo_hide_app"
    public static let quitApp = "combo_quit_app"
    public static let listWindows = "combo_list_windows"
    public static let layoutWindows = "combo_layout_windows"
    public static let setSystem = "combo_set_system"
    public static let setDimStrength = "combo_set_dim_strength"
    public static let clearShelf = "combo_clear_shelf"
    public static let saveWorkspace = "combo_workspace_save"
    public static let applyWorkspace = "combo_workspace_apply"
    public static let listWorkspaces = "combo_workspace_list"

    /// On: nacho-server production (cf88369, #57) shows an approval card for `"approval": "required"` before a call runs.
    /// While off, `combo_quit_app` is neither declared nor accepted.
    public static let declaresQuitApp = true

    /// Capabilities that need the user's approval card on the server before they run (no gadget always allowed).
    public static var approvalRequired: Set<String> {
        Set(GadgetToolRegistry.tools(on: .connector).filter { $0.connectorApproval(alwaysAllowed: false) }.map { $0.declaredConnectorName })
    }

    /// The 16 capabilities of the first connector contract, in their hello order. Frozen: the registry keeps them as
    /// the declared names (`GadgetToolRegistry.declaresCanonicalConnectorNames`) and declares them first.
    public static let legacyNames = [arrangeWindow, layoutWindows, listWindows, listApps, openApp, focusApp, hideApp, quitApp,
                                     setSystem, setGadget, listGadgets, setDimStrength, clearShelf,
                                     saveWorkspace, applyWorkspace, listWorkspaces]

    /// Every capability this build knows (the registry's connector tools), in hello order.
    public static var allNames: [String] { GadgetToolRegistry.tools(on: .connector).map { $0.declaredConnectorName } }

    /// What hello declares with the default switches.
    public static var names: [String] { names(allowQuit: declaresQuitApp) }

    public static func names(allowQuit: Bool) -> [String] { allNames.filter { $0 != quitApp || allowQuit } }

    /// Every window position Window Snap offers.
    public static var positions: [SnapAction] { SnapAction.allCases }

    /// Positions for one window of a multi-window layout (display moves are the `display` field there; restore and
    /// smaller / larger depend on history and make no sense in a layout).
    public static var layoutPositions: [SnapAction] {
        SnapAction.allCases.filter { ![.restore, .nextDisplay, .previousDisplay, .smaller, .larger].contains($0) }
    }

    public static let maxLayoutItems = WindowTiling.maxWindows   // technical limit of one call, not a layout limit (NACHO-146)
    public static let maxAppNameLength = 100

    /// Gadgets Nacho may switch: the combo gadgets (Computer Use is never one), without the pet itself.
    public static var toggleable: [ModuleID] { ModuleID.comboGadgets.filter { $0 != .nachoPet && $0 != .computerUse } }

    /// Korean description (at most 200 characters: what and when) and JSON schema of each capability, from the registry.
    /// Accepts the declared name and the aliases.
    public static func spec(_ name: String) -> (description: String, schema: [String: Any])? {
        guard let t = GadgetToolRegistry.connectorTool(named: name), let schema = t.inputSchema.foundationValue as? [String: Any]
        else { return nil }
        return (t.koreanDescription, schema)
    }

    /// `hello.capabilities` / `capabilities` frame body (names match `^[a-zA-Z0-9_-]{1,64}$`).
    public static var capabilities: [[String: Any]] { capabilities(allowQuit: declaresQuitApp) }

    public static func capabilities(allowQuit: Bool) -> [[String: Any]] {
        capabilities(allowQuit: allowQuit, alwaysAllowed: [], disabled: [])
    }

    /// The declaration from the registry: risk → approval (`GadgetTool.connectorApproval`), gadgets in `alwaysAllowed`
    /// lift the approval of their content_out / input_inject tools, names in `disabled` are left out.
    public static func capabilities(allowQuit: Bool, alwaysAllowed: Set<GadgetID>, disabled: Set<String>,
                                    tools: [GadgetTool] = GadgetToolRegistry.all) -> [[String: Any]] {
        GadgetToolRegistry.tools(on: .connector, in: tools).compactMap { t in
            let name = t.declaredConnectorName
            if t.legacyConnectorName == quitApp && !allowQuit { return nil }
            if !disabled.isDisjoint(with: t.connectorNames) { return nil }
            guard let schema = t.inputSchema.foundationValue as? [String: Any] else { return nil }
            var c: [String: Any] = ["name": name, "description": t.koreanDescription, "input_schema": schema]
            if t.connectorApproval(alwaysAllowed: alwaysAllowed.contains(t.gadget)) { c["approval"] = "required" }
            return c
        }
    }

    /// Accepts the raw value (`windowSnap`) or the display name (`Window Snap`, any case).
    public static func gadget(named raw: String) -> ModuleID? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = ModuleID(rawValue: s) { return id }
        let folded = s.lowercased().replacingOccurrences(of: " ", with: "")
        return ModuleID.allCases.first {
            $0.rawValue.lowercased() == folded || $0.displayName.lowercased().replacingOccurrences(of: " ", with: "") == folded
        }
    }

    // MARK: parameter readers

    /// A JSON boolean (never a number in disguise: `1` is not `true`).
    static func bool(_ v: Any?) -> Bool? {
        guard let v = v else { return nil }
        #if canImport(ObjectiveC)
        if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? n.boolValue : nil }
        return nil
        #else
        // swift-corelibs: a JSON boolean is `__NSCFBoolean`; a JSON number bridges to Bool too, so the type decides.
        if type(of: v) == Bool.self { return v as? Bool }
        if let n = v as? NSNumber, String(describing: type(of: n)).contains("Boolean") { return n.boolValue }
        return nil
        #endif
    }

    /// A whole JSON number (5 or 5.0; not 5.5, not a boolean, not a string).
    static func integer(_ v: Any?) -> Int? {
        guard let v = v, bool(v) == nil, !(v is String) else { return nil }
        #if !canImport(ObjectiveC)
        if type(of: v) == Bool.self { return nil }
        #endif
        let d: Double
        if let n = v as? NSNumber { d = n.doubleValue } else if let i = v as? Int { d = Double(i) } else if let x = v as? Double { d = x } else { return nil }
        guard d.isFinite, d.rounded() == d, abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    /// Trimmed app name, 1...100 printable characters on one line.
    static func appName(_ v: Any?, field: String = "app") -> Result<String, PetCommandProblem> {
        guard let s = v as? String else { return .failure(.badParams("\(field) must be a string")) }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.badParams("\(field) must not be empty")) }
        guard t.count <= maxAppNameLength, t.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
        else { return .failure(.badParams("\(field) must be at most \(maxAppNameLength) printable characters")) }
        return .success(t)
    }

    private static func unknownKeys(_ p: [String: Any], allowed: Set<String>) -> String? {
        let extra = Set(p.keys).subtracting(allowed)
        guard !extra.isEmpty else { return nil }
        return "unknown field\(extra.count == 1 ? "" : "s") \(extra.sorted().joined(separator: ", "))"
    }

    private static func present(_ v: Any?) -> Bool { v != nil && !(v is NSNull) }

    private static func workspaceName(_ p: [String: Any]) -> Result<String, PetCommandProblem> {
        if let why = unknownKeys(p, allowed: ["name"]) { return .failure(.badParams(why)) }
        guard let raw = p["name"] as? String else { return .failure(.badParams("name must be a string")) }
        switch DesktopWorkspaceStore.validName(raw) {
        case let .success(name): return .success(name)
        case let .failure(problem): return .failure(.badParams(problem.message))
        }
    }

    private static func singleApp(_ p: [String: Any], _ make: (String) -> PetCommand) -> Result<PetCommand, PetCommandProblem> {
        if let why = unknownKeys(p, allowed: ["app"]) { return .failure(.badParams(why)) }
        return appName(p["app"]).map(make)
    }

    private static func noParams(_ p: [String: Any], _ command: PetCommand) -> Result<PetCommand, PetCommandProblem> {
        if let why = unknownKeys(p, allowed: []) { return .failure(.badParams(why)) }
        return .success(command)
    }

    public static func parse(capability: String, params: Any?) -> Result<PetCommand, PetCommandProblem> {
        parse(capability: capability, params: params, allowQuit: declaresQuitApp)
    }

    /// The three first capabilities keep their original, lenient parameter reading; the newer ones refuse unknown fields.
    public static func parse(capability rawName: String, params: Any?, allowQuit: Bool) -> Result<PetCommand, PetCommandProblem> {
        // New registry names (`combo_window_arrange`) are aliases of the migrated capabilities.
        var capability = rawName
        if !legacyNames.contains(rawName), let legacy = GadgetToolRegistry.connectorTool(named: rawName)?.legacyConnectorName {
            capability = legacy
        }
        if present(params), !(params is [String: Any]) { return .failure(.badParams("parameters must be an object")) }
        let p = (params as? [String: Any]) ?? [:]
        switch capability {
        case arrangeWindow:
            guard let raw = p["position"] as? String, let action = SnapAction(rawValue: raw.trimmingCharacters(in: .whitespaces))
            else { return .failure(.badParams("position must be one of \(positions.map { $0.rawValue }.joined(separator: ", "))")) }
            var app: String?
            if let a = p["app"] {
                guard let s = a as? String else { return .failure(.badParams("app must be a string")) }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard t.count <= 100, t.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
                else { return .failure(.badParams("app name must be at most 100 printable characters")) }
                app = t.isEmpty ? nil : t
            }
            return .success(.arrangeWindow(action, app: app))
        case setGadget:
            guard let raw = p["gadget"] as? String, let id = gadget(named: raw)
            else { return .failure(.badParams("gadget must be one of \(toggleable.map { $0.rawValue }.joined(separator: ", "))")) }
            guard toggleable.contains(id) else {
                return .failure(.notAllowed("\(id.displayName) can only be switched by the user in Nacho Combo"))
            }
            guard let on = p["on"] as? Bool else { return .failure(.badParams("on must be true or false")) }
            return .success(.setGadget(id, on: on))
        case listGadgets:
            return .success(.listGadgets)
        case listApps:
            if let why = unknownKeys(p, allowed: ["installed"]) { return .failure(.badParams(why)) }
            guard present(p["installed"]) else { return .success(.listApps(installed: false)) }
            guard let installed = bool(p["installed"]) else { return .failure(.badParams("installed must be true or false")) }
            return .success(.listApps(installed: installed))
        case openApp: return singleApp(p) { .openApp($0) }
        case focusApp: return singleApp(p) { .focusApp($0) }
        case hideApp: return singleApp(p) { .hideApp($0) }
        case quitApp:
            guard allowQuit else {
                return .failure(.notAllowed("quitting apps is switched off in this Nacho Combo until the server asks the user to approve it"))
            }
            return singleApp(p) { .quitApp($0) }
        case listWindows: return noParams(p, .listWindows)
        case layoutWindows: return parseLayout(p)
        case setSystem:
            if let why = unknownKeys(p, allowed: ["volume", "brightness", "dnd"]) { return .failure(.badParams(why)) }
            var change = PetSystemChange()
            for key in ["volume", "brightness"] where present(p[key]) {
                guard let v = integer(p[key]), (0...100).contains(v) else {
                    return .failure(.badParams("\(key) must be a whole number from 0 to 100"))
                }
                if key == "volume" { change.volume = v } else { change.brightness = v }
            }
            if present(p["dnd"]) {
                guard let on = bool(p["dnd"]) else { return .failure(.badParams("dnd must be true or false")) }
                change.doNotDisturb = on
            }
            guard !change.isEmpty else { return .failure(.badParams("give at least one of volume, brightness, dnd")) }
            return .success(.setSystem(change))
        case setDimStrength:
            if let why = unknownKeys(p, allowed: ["percent"]) { return .failure(.badParams(why)) }
            guard let v = integer(p["percent"]), (10...90).contains(v) else {
                return .failure(.badParams("percent must be a whole number from 10 to 90"))
            }
            return .success(.setDimStrength(v))
        case clearShelf: return noParams(p, .clearShelf)
        case saveWorkspace: return workspaceName(p).map { .saveWorkspace($0) }
        case applyWorkspace: return workspaceName(p).map { .applyWorkspace($0) }
        case listWorkspaces: return noParams(p, .listWorkspaces)
        default:
            return .failure(.unknownCapability(String(capability.prefix(64))))
        }
    }

    private static func parseLayout(_ p: [String: Any]) -> Result<PetCommand, PetCommandProblem> {
        if let why = unknownKeys(p, allowed: ["items"]) { return .failure(.badParams(why)) }
        guard let items = p["items"] as? [Any], !items.isEmpty else { return .failure(.badParams("items must be a non-empty list")) }
        guard items.count <= maxLayoutItems else { return .failure(.badParams("at most \(maxLayoutItems) items")) }
        var result: [PetWindowPlacement] = []
        for (n, raw) in items.enumerated() {
            let label = "items[\(n)]"
            guard let item = raw as? [String: Any] else { return .failure(.badParams("\(label) must be an object")) }
            if let why = unknownKeys(item, allowed: ["app", "position", "display", "window"]) {
                return .failure(.badParams("\(label): \(why)"))
            }
            let app: String
            switch appName(item["app"], field: "\(label).app") {
            case let .success(a): app = a
            case let .failure(e): return .failure(e)
            }
            guard let rawPos = item["position"] as? String,
                  let position = SnapAction(rawValue: rawPos.trimmingCharacters(in: .whitespaces)),
                  layoutPositions.contains(position)
            else {
                return .failure(.badParams("\(label).position must be one of \(layoutPositions.map { $0.rawValue }.joined(separator: ", "))"))
            }
            var display: Int?
            if present(item["display"]) {
                guard let d = integer(item["display"]), (1...16).contains(d) else {
                    return .failure(.badParams("\(label).display must be a whole number from 1 to 16"))
                }
                display = d
            }
            var window = 1
            if present(item["window"]) {
                guard let w = integer(item["window"]), (1...20).contains(w) else {
                    return .failure(.badParams("\(label).window must be a whole number from 1 to 20"))
                }
                window = w
            }
            if result.contains(where: { PetAppMatcher.fold($0.app) == PetAppMatcher.fold(app) && $0.window == window }) {
                return .failure(.badParams("\(label) places the same window of \(app) twice"))
            }
            result.append(PetWindowPlacement(app: app, position: position, display: display, window: window))
        }
        return .success(.layoutWindows(result))
    }
}
