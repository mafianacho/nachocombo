import Foundation

// What Nacho may do on this Mac when asked in the chat. Nacho Combo registers these as connector capabilities on
// nacho-server's `/ws/connector` (docs/ws-protocol.md §3): the server offers them to the model as tools and forwards a
// call as `{"type":"request","id","capability","params"}`. Every call is validated here against closed lists before
// the app touches anything; anything outside them is refused with a reason the model can relay.

public enum PetCommand: Equatable {
    /// Snap the front window (or the front window of the named running app) to a position.
    case arrangeWindow(SnapAction, app: String?)
    /// Switch a gadget on or off. Never Computer Use or the pet itself.
    case setGadget(ModuleID, on: Bool)
    case listGadgets
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

    public init(ok: Bool, message: String, gadgets: [String: String]? = nil) {
        self.ok = ok
        self.message = message
        self.gadgets = gadgets
    }

    public var resultJSON: [String: Any] {
        var o: [String: Any] = ["ok": ok, "message": message]
        if let g = gadgets { o["gadgets"] = g }
        return o
    }
}

public enum PetCommands {
    public static let arrangeWindow = "combo_arrange_window"
    public static let setGadget = "combo_set_gadget"
    public static let listGadgets = "combo_list_gadgets"
    public static let names = [arrangeWindow, setGadget, listGadgets]

    /// Every window position Window Snap offers.
    public static var positions: [SnapAction] { SnapAction.allCases }

    /// Gadgets Nacho may switch: the combo gadgets (Computer Use is never one), without the pet itself.
    public static var toggleable: [ModuleID] { ModuleID.comboGadgets.filter { $0 != .nachoPet && $0 != .computerUse } }

    /// `hello.capabilities` / `capabilities` frame body (names match `^[a-zA-Z0-9_-]{1,64}$`).
    public static var capabilities: [[String: Any]] {
        let gadgetList = toggleable.map { "\($0.rawValue) (\($0.displayName))" }.joined(separator: ", ")
        return [
            [
                "name": arrangeWindow,
                "description": "Nacho Combo on the user's Mac: move and resize the front window (or the front window of a running app) "
                    + "to a screen position, like Window Snap. Needs the Window Snap gadget on. 맥의 창 배치.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "position": ["type": "string", "enum": positions.map { $0.rawValue },
                                     "description": "left = left half, right = right half, maximize, top-left quarter, first-third ..."],
                        "app": ["type": "string", "description": "Optional name of a running app, e.g. Safari. Default: the front app."],
                    ],
                    "required": ["position"],
                ] as [String: Any],
            ],
            [
                "name": setGadget,
                "description": "Nacho Combo on the user's Mac: switch one gadget on or off. Gadgets: \(gadgetList). 가젯 켜기/끄기.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "gadget": ["type": "string", "enum": toggleable.map { $0.rawValue }],
                        "on": ["type": "boolean"],
                    ],
                    "required": ["gadget", "on"],
                ] as [String: Any],
            ],
            [
                "name": listGadgets,
                "description": "Nacho Combo on the user's Mac: list the gadgets and whether each is on.",
                "input_schema": ["type": "object", "properties": [String: Any]()] as [String: Any],
            ],
        ]
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

    public static func parse(capability: String, params: Any?) -> Result<PetCommand, PetCommandProblem> {
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
        default:
            return .failure(.unknownCapability(String(capability.prefix(64))))
        }
    }
}
