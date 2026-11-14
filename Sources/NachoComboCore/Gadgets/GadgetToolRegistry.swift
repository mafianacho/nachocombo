import Foundation

/// What one gadget registers: its tools, its guide and its prompts. One `enum <Gadget>Tools: GadgetToolProvider` per
/// gadget in `Gadgets/Tools/` so the gadget lanes never edit the same file.
public protocol GadgetToolProvider {
    static var gadget: GadgetID { get }
    static var tools: [GadgetTool] { get }
    static var guide: GadgetGuide? { get }
    static var prompts: [GadgetPrompt] { get }
}

/// The single registry. Order matters: the connector declares the tools in this order (the 16 migrated
/// capabilities first, in their old hello order), and MCP `tools/list` lists them in it.
public enum GadgetToolRegistry {
    /// Off: migrated connector capabilities keep the names nacho-server already knows (`combo_arrange_window`;
    /// allow rules saved on the server use them) and the new `combo_<gadget>_<action>` names are accepted as aliases.
    /// Turn on together with the server (then the old names become the aliases).
    public static let declaresCanonicalConnectorNames = false

    /// Every provider. The contract lane owns this list; it already holds an (empty) provider for every gadget.
    public static let providers: [GadgetToolProvider.Type] = [
        ComboTools.self, WindowTools.self, AppSwitchTools.self, DeviceTools.self, DimTools.self, ShelfTools.self,
        MenuBarTools.self, MonitorTools.self, DiskTools.self, ClipboardTools.self, CaptureTools.self, AwakeTools.self,
        MouseTools.self, CalendarTools.self, ComputerTools.self,
    ]

    /// Migrated connector capabilities first (old hello order), then everything else in provider order.
    public static let all: [GadgetTool] = {
        let tools = providers.flatMap { $0.tools }
        let legacyOrder = PetCommands.legacyNames
        let legacy = legacyOrder.compactMap { name in tools.first { $0.legacyConnectorName == name } }
        return legacy + tools.filter { $0.legacyConnectorName == nil || !legacyOrder.contains($0.legacyConnectorName!) }
    }()

    public static var guides: [GadgetGuide] { providers.compactMap { $0.guide } }
    public static var prompts: [GadgetPrompt] { providers.flatMap { $0.prompts } }

    public static func guide(for gadget: GadgetID) -> GadgetGuide? { guides.first { $0.gadget == gadget } }

    public static func tools(on exit: GadgetToolExit, in list: [GadgetTool] = all) -> [GadgetTool] {
        list.filter { $0.exits.contains(exit) }
    }

    /// A connector request name: the declared name, the canonical `combo_<gadget>_<action>` or an old alias.
    public static func connectorTool(named name: String, in list: [GadgetTool] = all) -> GadgetTool? {
        list.first { $0.exits.contains(.connector) && $0.connectorNames.contains(name) }
    }

    /// An MCP `tools/call` name: `<gadget>_<action>` or an old Computer Use name.
    public static func mcpTool(named name: String, in list: [GadgetTool] = all) -> GadgetTool? {
        list.first { $0.exits.contains(.mcp) && $0.mcpNames.contains(name) }
    }

    /// Gadgets with at least one tool that "always allow" can lift on the connector path.
    public static func trustableGadgets(in list: [GadgetTool] = all) -> Set<GadgetID> {
        Set(list.filter { $0.exits.contains(.connector) && $0.risk.isTrustable }.map { $0.gadget })
    }

    // MARK: integrity

    /// Words nacho-server's `classify_name` reads as payment, deletion or messaging (approval kinds).
    public static let forbiddenConnectorWords = ["pay", "purchase", "checkout", "buy", "call", "delete", "remove",
                                                 "publish", "book", "reserve", "send", "post"]
    public static let maxNameLength = 64
    public static let maxKoreanDescription = 200
    public static let maxEnglishDescription = 400

    static let namePattern = "^[a-zA-Z0-9_-]{1,64}$"
    static let actionPattern = "^[a-z0-9]+(_[a-z0-9]+)*$"

    /// Empty when the registry keeps the contract. Each entry names the tool and the broken rule.
    public static func problems(in list: [GadgetTool] = all, prompts: [GadgetPrompt] = prompts,
                                guides: [GadgetGuide] = guides) -> [String] {
        var out: [String] = []
        var mcpSeen: [String: (index: Int, id: String)] = [:]
        var connectorSeen: [String: (index: Int, id: String)] = [:]
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }
        for (index, t) in list.enumerated() {
            let id = t.mcpName
            if !matches(t.action, actionPattern) { out.append("\(id): action must be lower-case words joined by _") }
            for n in t.mcpNames.union(t.connectorNames) {
                if n.count > maxNameLength || !matches(n, namePattern) { out.append("\(id): name \(n) breaks ^[a-zA-Z0-9_-]{1,64}$") }
            }
            for n in t.mcpNames {
                if let other = mcpSeen[n], other.index != index { out.append("\(id): MCP name \(n) also used by \(other.id)") }
                mcpSeen[n] = (index, id)
            }
            for n in t.connectorNames {
                if let other = connectorSeen[n], other.index != index { out.append("\(id): connector name \(n) also used by \(other.id)") }
                connectorSeen[n] = (index, id)
            }
            // Old names are frozen; only new names must avoid the server's approval words.
            for word in forbiddenConnectorWords where t.connectorName.lowercased().contains(word) {
                out.append("\(id): connector name \(t.connectorName) contains '\(word)' (nacho-server would classify it)")
            }
            let ko = t.koreanDescription
            if ko.count > maxKoreanDescription { out.append("\(id): Korean description is \(ko.count) characters (max \(maxKoreanDescription))") }
            if ko.count < 20 { out.append("\(id): Korean description too short to choose by") }
            let hangul = ko.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
            let letters = ko.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            if hangul * 2 <= letters { out.append("\(id): Korean description is not mostly Korean") }
            if t.englishDescription.isEmpty || t.englishDescription.count > maxEnglishDescription {
                out.append("\(id): English description must be 1...\(maxEnglishDescription) characters")
            }
            if t.output.isEmpty { out.append("\(id): output shape missing") }
            out += schemaProblems(t.inputSchema, id)
            if t.exits.isEmpty { out.append("\(id): no exit") }
            if t.gadget == .computer, t.exits.contains(.mcp), t.legacyMCPName != nil, t.mcpGroup == nil {
                out.append("\(id): a Computer Use tool must sit under one of the tool group switches")
            }
        }
        var promptSeen = Set<String>()
        for p in prompts {
            if !matches(p.name, namePattern) || !matches(p.flow, actionPattern) { out.append("prompt \(p.name): bad name") }
            if !promptSeen.insert(p.name).inserted { out.append("prompt \(p.name): duplicate") }
            if p.description.isEmpty || p.template.isEmpty { out.append("prompt \(p.name): description and template are required") }
        }
        var guideSeen = Set<GadgetID>()
        for g in guides {
            if !guideSeen.insert(g.gadget).inserted { out.append("guide \(g.gadget.rawValue): duplicate") }
            if g.summary.isEmpty { out.append("guide \(g.gadget.rawValue): summary missing") }
            let own = list.filter { $0.gadget == g.gadget }
            for e in g.examples where !own.contains(where: { $0.action == e.action }) && !list.contains(where: { $0.mcpName == e.action }) {
                out.append("guide \(g.gadget.rawValue): example uses unknown action \(e.action)")
            }
        }
        return out
    }

    /// A closed object schema: `type: object`, `properties` object, `additionalProperties: false`, and every
    /// `required` key among the properties. Nested objects (array items) follow the same rule.
    static func schemaProblems(_ schema: JSONValue, _ id: String) -> [String] {
        guard case .object(let o) = schema else { return ["\(id): schema is not an object"] }
        var out: [String] = []
        if o["type"] != .string("object") { out.append("\(id): schema type must be object") }
        guard case .object(let props)? = o["properties"] else { return out + ["\(id): schema needs properties"] }
        if o["additionalProperties"] != .bool(false) { out.append("\(id): schema must set additionalProperties false") }
        if case .array(let req)? = o["required"] {
            for r in req {
                guard case .string(let key) = r, props[key] != nil else { out.append("\(id): required \(r) is not a property"); continue }
            }
        }
        for (key, p) in props {
            guard case .object(let po) = p, po["type"] != nil || po["enum"] != nil else {
                out.append("\(id): property \(key) has no type"); continue
            }
            if case .object(let items)? = po["items"], items["type"] == .string("object") {
                out += schemaProblems(.object(items), "\(id).\(key)[]")
            }
        }
        return out
    }
}
