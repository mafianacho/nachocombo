import Foundation

// What Nacho may do on this Mac when asked in the chat. Nacho Combo registers these as connector capabilities on
// nacho-server's `/ws/connector` (docs/ws-protocol.md §3): the server offers them to the model as tools and forwards a
// call as `{"type":"request","id","capability","params"}`. Every call is validated here against closed lists before
// the app touches anything; anything outside them is refused with a reason the model can relay.
//
// Contract with nacho-server (fixed by the consigliere; change it there first):
// - names are `combo_*`; descriptions are Korean, at most 200 characters, saying what the tool does and when to use it
//   (the server's tool picker chooses by these descriptions);
// - a risky capability carries `"approval": "required"` in hello and the server shows an approval card before it runs.
//   Until the server does that in production the app does not declare risky capabilities at all
//   (`PetCommands.declaresQuitApp` is off) and refuses such a call if one arrives anyway.

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
    /// A gadget's own function (clipboard, shelf, capture, monitor …): `PetGadgetCommands.swift`.
    case gadget(PetGadgetAction)
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

    /// Off until nacho-server shows an approval card for `"approval": "required"` in production (lane C).
    /// While off, `combo_quit_app` is neither declared nor accepted.
    public static let declaresQuitApp = false

    /// Capabilities that need the user's approval card on the server before they run.
    public static let approvalRequired: Set<String> = [quitApp]

    /// Every capability this build knows, in hello order.
    public static let allNames = [arrangeWindow, layoutWindows, listWindows, listApps, openApp, focusApp, hideApp, quitApp,
                                  setSystem, setGadget, listGadgets, setDimStrength, clearShelf,
                                  saveWorkspace, applyWorkspace, listWorkspaces] + PetGadgetCommands.names

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

    public static let maxLayoutItems = 8
    public static let maxAppNameLength = 100

    /// Gadgets Nacho may switch: the combo gadgets (Computer Use is never one), without the pet itself.
    public static var toggleable: [ModuleID] { ModuleID.comboGadgets.filter { $0 != .nachoPet && $0 != .computerUse } }

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { o["required"] = required }
        return o
    }

    private static let appProperty: [String: Any] = [
        "type": "string", "maxLength": maxAppNameLength,
        "description": "앱 이름(한국어 표시 이름·영문 이름·번들 ID), 예: 사파리, Safari, com.apple.Safari",
    ]

    private static var nameProperty: [String: Any] {
        ["type": "string", "minLength": 1, "maxLength": DesktopWorkspaceStore.maxNameLength, "description": "작업 공간 이름, 예: 업무 모드"]
    }

    /// Korean description (at most 200 characters: what and when) and JSON schema of each capability.
    public static func spec(_ name: String) -> (description: String, schema: [String: Any])? {
        switch name {
        case arrangeWindow:
            return ("맨 앞 창(또는 지정한 실행 중 앱의 창) 하나를 화면 왼쪽 반·오른쪽 반·최대화·네 귀퉁이·3분할 등으로 옮겨요. "
                    + "next-display·previous-display는 옆 디스플레이로 옮겨요. 손쉬운 사용 권한이 필요해요.",
                    object(["position": ["type": "string", "enum": positions.map { $0.rawValue },
                                         "description": "left=왼쪽 반, right=오른쪽 반, maximize=최대화, top-left=왼쪽 위 1/4, first-third=왼쪽 1/3 …"],
                            "app": appProperty], required: ["position"]))
        case layoutWindows:
            return ("여러 앱의 창을 한 번에 배치해요(예: 사파리는 왼쪽 반, 메모는 오른쪽 반, 슬랙은 2번 디스플레이 최대화). "
                    + "항목마다 앱과 위치, 필요하면 디스플레이 번호를 줘요. 최대 8개, 손쉬운 사용 권한이 필요해요.",
                    object(["items": [
                        "type": "array", "minItems": 1, "maxItems": maxLayoutItems,
                        "items": object(["app": appProperty,
                                         "position": ["type": "string", "enum": layoutPositions.map { $0.rawValue }],
                                         "display": ["type": "integer", "minimum": 1, "maximum": 16,
                                                     "description": "디스플레이 번호(combo_list_windows 기준, 왼쪽부터 1). 없으면 창이 있는 화면"],
                                         "window": ["type": "integer", "minimum": 1, "maximum": 20,
                                                    "description": "그 앱의 몇 번째 창인지(앞에서부터 1). 기본 1"]],
                                        required: ["app", "position"]),
                    ] as [String: Any]], required: ["items"]))
        case listWindows:
            return ("맥의 디스플레이 목록(번호·크기)과 앱별 열린 창의 위치·크기·디스플레이 번호를 봐요(창 제목은 보내지 않아요). "
                    + "여러 창을 배치하거나 다른 화면으로 옮기기 전에 지금 상태를 확인할 때 써요. 손쉬운 사용 권한이 필요해요.",
                    object([:]))
        case listApps:
            return ("맥에서 지금 실행 중인 앱 목록(이름·번들 ID·맨 앞인지·숨김인지)을 봐요. installed=true면 설치된 앱 이름도 함께 봐요. "
                    + "앱 이름이 확실하지 않을 때 열거나 전환하기 전에 써요.",
                    object(["installed": ["type": "boolean", "description": "설치된 앱도 포함(기본 false)"]]))
        case openApp:
            return ("맥에 설치된 앱을 열고 맨 앞으로 가져와요(예: \"사파리 열어 줘\", \"메모 켜 줘\"). 이미 실행 중이면 그 앱으로 전환해요. "
                    + "앱 이름은 한국어 표시 이름·영문 이름·번들 ID 모두 돼요.",
                    object(["app": appProperty], required: ["app"]))
        case focusApp:
            return ("이미 실행 중인 앱으로 전환해 맨 앞에 보여 줘요(숨겨져 있으면 다시 보이게). \"크롬으로 바꿔 줘\"처럼 앱 전환을 원할 때 써요. "
                    + "실행 중이 아니면 combo_open_app을 써요.",
                    object(["app": appProperty], required: ["app"]))
        case hideApp:
            return ("실행 중인 앱의 창을 모두 숨겨요(⌘H와 같고 앱은 종료하지 않아요). \"슬랙 잠깐 가려 줘\"처럼 화면에서 치우고 싶을 때 써요. "
                    + "Finder·나초콤보는 숨기지 않아요.",
                    object(["app": appProperty], required: ["app"]))
        case quitApp:
            return ("실행 중인 앱을 종료해요(저장하지 않은 내용은 그 앱이 물어봐요). 사용자가 분명히 종료를 원할 때만 쓰고, "
                    + "실행 전에 사용자 승인이 필요해요. Finder·나초콤보는 종료하지 않아요.",
                    object(["app": appProperty], required: ["app"]))
        case setSystem:
            return ("맥의 소리 크기(0~100), 내장 화면 밝기(0~100), 방해금지 켜기/끄기를 바꿔요. 바꿀 항목만 넣어요. "
                    + "이 맥에서 지원하지 않는 항목(외장 모니터 밝기·방해금지 등)은 이유와 함께 실패로 알려 줘요.",
                    object(["volume": ["type": "integer", "minimum": 0, "maximum": 100, "description": "소리 크기 %"],
                            "brightness": ["type": "integer", "minimum": 0, "maximum": 100, "description": "내장 화면 밝기 %"],
                            "dnd": ["type": "boolean", "description": "방해금지 켜기(true)/끄기(false)"]]))
        case setGadget:
            return ("나초콤보 가젯(창 배치·집중 디밍·잠자기 방지·파일 선반 등) 하나를 켜거나 꺼요. 가젯 이름은 gadget 목록에서 골라요. "
                    + "권한이 더 필요한 가젯은 사용자가 나초콤보에서 직접 켜야 해요.",
                    object(["gadget": ["type": "string", "enum": toggleable.map { $0.rawValue }], "on": ["type": "boolean"]],
                           required: ["gadget", "on"]))
        case listGadgets:
            return ("나초콤보 가젯 목록과 각각 켜져 있는지 봐요. 어떤 가젯이 있는지, 지금 켜져 있는지 확인할 때 써요.", object([:]))
        case setDimStrength:
            return ("집중 디밍(맨 앞 창만 밝게 두고 나머지 화면을 어둡게 하는 가젯)의 어둡기를 10~90%로 바꿔요. "
                    + "\"디밍 더 어둡게\"처럼 요청할 때 써요. 가젯이 꺼져 있으면 강도만 저장돼요.",
                    object(["percent": ["type": "integer", "minimum": 10, "maximum": 90]], required: ["percent"]))
        case clearShelf:
            return ("파일 선반에 올려 둔 항목을 모두 비워요(원본 파일은 지우지 않고, 선반에서 되돌리기 할 수 있어요). "
                    + "\"선반 비워 줘\"처럼 요청할 때 써요.", object([:]))
        case saveWorkspace:
            return ("지금 맥 상태(실행 중인 앱, 창 위치, 가젯 켜짐 상태)를 이름을 붙여 작업 공간으로 저장해요(예: \"업무 모드\"). "
                    + "같은 이름이 있으면 덮어써요. 손쉬운 사용 권한이 필요해요.",
                    object(["name": nameProperty], required: ["name"]))
        case applyWorkspace:
            return ("저장한 작업 공간을 불러와요: 빠진 앱을 열고, 창을 저장한 자리로 옮기고, 가젯을 저장한 대로 켜고 꺼요. "
                    + "이미 열려 있는 다른 앱은 종료하지 않아요. 이름은 combo_workspace_list로 확인해요.",
                    object(["name": nameProperty], required: ["name"]))
        case listWorkspaces:
            return ("저장된 작업 공간 이름과 각각의 앱·창 수, 저장 시각을 봐요. 어떤 작업 공간이 있는지 확인할 때 써요.", object([:]))
        default:
            return PetGadgetCommands.spec(name)
        }
    }

    /// `hello.capabilities` / `capabilities` frame body (names match `^[a-zA-Z0-9_-]{1,64}$`). Follows the app's
    /// "always allow" switches and switched-off actions (`PetGadgetTrust.shared`).
    public static var capabilities: [[String: Any]] {
        capabilities(allowQuit: declaresQuitApp, alwaysAllowed: PetGadgetTrust.shared.alwaysAllowed,
                     disabled: PetGadgetTrust.shared.disabled)
    }

    public static func capabilities(allowQuit: Bool, alwaysAllowed: Set<ModuleID> = [], disabled: Set<String> = []) -> [[String: Any]] {
        names(allowQuit: allowQuit).filter { !disabled.contains($0) }.compactMap { name in
            guard let s = spec(name) else { return nil }
            var c: [String: Any] = ["name": name, "description": s.description, "input_schema": s.schema]
            if requiresApproval(name, alwaysAllowed: alwaysAllowed) { c["approval"] = "required" }
            return c
        }
    }

    /// Declared with `"approval": "required"`: the risky ones, and content sent to the server unless its gadget is
    /// "always allowed".
    public static func requiresApproval(_ name: String, alwaysAllowed: Set<ModuleID>) -> Bool {
        if approvalRequired.contains(name) { return true }
        guard let gadget = PetGadgetCommands.contentSending[name] else { return false }
        return !alwaysAllowed.contains(gadget)
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
    public static func parse(capability: String, params: Any?, allowQuit: Bool) -> Result<PetCommand, PetCommandProblem> {
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
            if let gadget = PetGadgetCommands.parse(capability: capability, params: p) { return gadget.map { .gadget($0) } }
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
