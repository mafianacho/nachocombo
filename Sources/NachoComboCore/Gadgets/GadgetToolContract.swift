import Foundation

// NachoCombo MCP shared contract (NACHO-144 / NACHO-145). One registry of gadget tools feeds two exits:
//  (a) the NachoCombo MCP server (`ComputerUseService`: tools, resources = gadget guides, prompts) for external MCP
//      clients holding an API key, and
//  (b) nacho-server's connector (`PetConnectorClient`: `combo_*` capabilities) for Nacho in the chat.
// docs/NACHOCOMBO-MCP.md has the naming rules, the risk/approval table, the rename table and the lane checklist.
// Gadget lanes add entries to their own `Gadgets/Tools/<Gadget>Tools.swift` only (append-only); this file, the
// registry, the MCP server and the connector bridge belong to the contract lane.

/// Short gadget ids used in tool names, guide URIs and the per-gadget switches. `combo` is Nacho Combo itself
/// (gadget list, workspaces, guides): its tools are named `combo_<action>` on both exits.
public enum GadgetID: String, CaseIterable, Codable {
    case combo
    case window
    case menubar
    case monitor
    case disk
    case clipboard
    case shelf
    case capture
    case dim
    case awake
    case device
    case mouse
    case appswitch
    case calendar
    case computer

    /// The module behind the gadget (nil for `combo`, which is the app itself).
    public var moduleID: ModuleID? {
        switch self {
        case .combo: return nil
        case .window: return .windowSnap
        case .menubar: return .menuBar
        case .monitor: return .systemMonitor
        case .disk: return .diskMap
        case .clipboard: return .clipboard
        case .shelf: return .fileShelf
        case .capture: return .captureFloat
        case .dim: return .focusDim
        case .awake: return .keepAwake
        case .device: return .deviceControl
        case .mouse: return .mouseTune
        case .appswitch: return .appSwitch
        case .calendar: return .calendarClock
        case .computer: return .computerUse
        }
    }

    public init?(module: ModuleID) {
        guard let found = GadgetID.allCases.first(where: { $0.moduleID == module }) else { return nil }
        self = found
    }

    /// Accepts the short id (`window`), the module raw value (`windowSnap`) or its display name (`Window Snap`).
    public init?(named raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = GadgetID(rawValue: s.lowercased()) { self = id; return }
        guard let module = PetCommands.gadget(named: s), let id = GadgetID(module: module) else { return nil }
        self = id
    }

    public var koreanName: String {
        switch self {
        case .combo: return "나초콤보"
        case .window: return "창 배치"
        case .menubar: return "메뉴 막대 정리"
        case .monitor: return "시스템 모니터"
        case .disk: return "디스크 지도"
        case .clipboard: return "클립보드 기록"
        case .shelf: return "파일 선반"
        case .capture: return "캡처 플로트"
        case .dim: return "집중 디밍"
        case .awake: return "잠자기 방지"
        case .device: return "기기 제어"
        case .mouse: return "마우스 조정"
        case .appswitch: return "앱 전환"
        case .calendar: return "달력 시계"
        case .computer: return "컴퓨터 사용"
        }
    }

    public var displayName: String { moduleID?.displayName ?? "Nacho Combo" }

    /// MCP resource with this gadget's guide.
    public var guideURI: String { "nachocombo://gadgets/\(rawValue)/guide" }
}

/// How much a tool can do. Decides the approval on the connector path (`GadgetTool.connectorApproval`).
public enum GadgetToolRisk: String, CaseIterable, Codable {
    /// Looks at state or lists (numbers, kinds, lengths, names). Runs at once.
    case read
    /// Changes the Mac in a way the user can see and undo. Runs at once.
    case change
    /// Sends content off the Mac (clipboard text, a capture image, a file itself). Approval every time unless the
    /// gadget is "always allowed".
    case contentOut = "content_out"
    /// Types, clicks or presses keys for the user. Approval every time unless the gadget is "always allowed".
    case inputInject = "input_inject"
    /// Cannot be undone (quit an app, kill a process, overwrite a file, run a script). Approval every time, always.
    case destructive

    /// The kinds that "always allow" (per gadget) may lift.
    public var isTrustable: Bool { self == .contentOut || self == .inputInject }
}

/// Where a tool is offered.
public enum GadgetToolExit: String, CaseIterable, Codable {
    case mcp
    case connector
}

/// One tool of one gadget. See docs/NACHOCOMBO-MCP.md for every field's rule; `GadgetToolRegistry.problems` checks them.
public struct GadgetTool: Equatable {
    public let gadget: GadgetID
    /// Lower-case `[a-z0-9_]`, e.g. `arrange`, `layout`, `screen_capture`.
    public let action: String
    /// Korean, at most 200 characters: what the tool does and when to use it (Nacho's tool picker reads this).
    public let koreanDescription: String
    /// English, for MCP clients.
    public let englishDescription: String
    /// JSON schema, `type: object` with a closed `properties` list (`additionalProperties: false`).
    public let inputSchema: JSONValue
    /// Short English line about the result (`{ok, message, windows:[…]}`), shown in guides.
    public let output: String
    public let risk: GadgetToolRisk
    /// macOS permissions the tool needs to work.
    public let permissions: Set<OSPermission>
    public let exits: Set<GadgetToolExit>
    /// Old names still accepted on calls (the 16 `combo_*` capabilities and the Computer Use MCP tool names).
    public let aliases: [String]
    /// The connector name nacho-server already knows for a migrated capability (kept as the declared name while
    /// `GadgetToolRegistry.declaresCanonicalConnectorNames` is off; saved allow rules on the server use it).
    public let legacyConnectorName: String?
    /// The Computer Use MCP tool name the existing backend executes (`ComputerUseBackend.execute(tool:)`).
    public let legacyMCPName: String?
    /// The Computer Use tool group switch the tool sits under on the MCP exit. nil = the gadget's own switch.
    public let mcpGroup: ToolGroup?
    /// The dispatcher answers `gadget_off` while the gadget's module is off. Migrated tools keep their old behaviour
    /// (false); new tools default to true.
    public let requiresGadgetOn: Bool

    public init(gadget: GadgetID, action: String, korean: String, english: String, input: JSONValue = GadgetSchema.object(),
                output: String, risk: GadgetToolRisk, permissions: Set<OSPermission> = [],
                exits: Set<GadgetToolExit> = [.mcp, .connector], aliases: [String] = [],
                legacyConnectorName: String? = nil, legacyMCPName: String? = nil, mcpGroup: ToolGroup? = nil,
                requiresGadgetOn: Bool = true) {
        self.gadget = gadget
        self.action = action
        self.koreanDescription = korean
        self.englishDescription = english
        self.inputSchema = input
        self.output = output
        self.risk = risk
        self.permissions = permissions
        self.exits = exits
        self.aliases = aliases
        self.legacyConnectorName = legacyConnectorName
        self.legacyMCPName = legacyMCPName
        self.mcpGroup = mcpGroup
        self.requiresGadgetOn = requiresGadgetOn
    }

    /// `<gadget>_<action>` (`combo_<action>` for Nacho Combo itself). No dots: Claude-family clients only accept
    /// `^[a-zA-Z0-9_-]{1,64}$`.
    public var mcpName: String { "\(gadget.rawValue)_\(action)" }

    /// `combo_<gadget>_<action>` (`combo_<action>` for Nacho Combo itself).
    public var connectorName: String { gadget == .combo ? "combo_\(action)" : "combo_\(gadget.rawValue)_\(action)" }

    /// The name the connector declares in hello / `capabilities`.
    public var declaredConnectorName: String {
        GadgetToolRegistry.declaresCanonicalConnectorNames ? connectorName : (legacyConnectorName ?? connectorName)
    }

    /// Every name a connector request may use for this tool.
    public var connectorNames: Set<String> {
        var s: Set<String> = [connectorName]
        if let l = legacyConnectorName { s.insert(l) }
        for a in aliases where a.hasPrefix("combo_") { s.insert(a) }
        return s
    }

    /// Every name an MCP `tools/call` may use for this tool.
    public var mcpNames: Set<String> {
        var s: Set<String> = [mcpName]
        if let l = legacyMCPName { s.insert(l) }
        for a in aliases where !a.hasPrefix("combo_") { s.insert(a) }
        return s
    }

    /// Whether the connector declares the tool with `"approval": "required"`:
    /// read/change never; content_out/input_inject unless the gadget is always allowed; destructive always.
    public func connectorApproval(alwaysAllowed: Bool) -> Bool {
        switch risk {
        case .read, .change: return false
        case .contentOut, .inputInject: return !alwaysAllowed
        case .destructive: return true
        }
    }
}

/// Small builders for the JSON schemas of the registry (closed property lists).
public enum GadgetSchema {
    public static func object(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false)]
        if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
        return .object(o)
    }

    public static func string(_ description: String, minLength: Int? = nil, maxLength: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "description": .string(description)]
        if let m = minLength { o["minLength"] = .int(m) }
        if let m = maxLength { o["maxLength"] = .int(m) }
        return .object(o)
    }

    public static func choice(_ values: [String], _ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("string"), "enum": .array(values.map { .string($0) })]
        if let d = description { o["description"] = .string(d) }
        return .object(o)
    }

    public static func integer(_ description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("integer")]
        if let d = description { o["description"] = .string(d) }
        if let m = minimum { o["minimum"] = .int(m) }
        if let m = maximum { o["maximum"] = .int(m) }
        return .object(o)
    }

    public static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    public static func boolean(_ description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string("boolean")]
        if let d = description { o["description"] = .string(d) }
        return .object(o)
    }

    public static func stringList(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }
}

extension JSONValue {
    /// Foundation form (what `JSONSerialization` produces), for the connector frames.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundationValue }
        case .object(let o): return o.mapValues { $0.foundationValue }
        }
    }

    /// Parsed back through JSON text, so booleans and numbers come out exactly as from a server frame.
    public var jsonObject: Any? {
        try? JSONSerialization.jsonObject(with: JSONRPCCodec.encode(self), options: [.fragmentsAllowed])
    }

    /// From a `JSONSerialization` value (nil for anything JSON cannot hold).
    public init?(jsonObject: Any) {
        // Wrapped in an array: `isValidJSONObject` only takes containers, and an invalid value would raise, not throw.
        let wrapped: [Any] = [jsonObject]
        guard JSONSerialization.isValidJSONObject(wrapped), let data = try? JSONSerialization.data(withJSONObject: wrapped),
              let v = try? JSONDecoder().decode([JSONValue].self, from: data), let first = v.first else { return nil }
        self = first
    }
}
