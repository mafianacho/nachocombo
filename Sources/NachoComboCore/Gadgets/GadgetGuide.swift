import Foundation

/// How to use one gadget: the MCP resource `nachocombo://gadgets/<id>/guide` and the answer of `combo_gadget_guide`.
/// Both render the same text; only the tool names follow the exit (MCP `window_arrange`, connector `combo_…`).
/// Each gadget lane writes its own guide next to its tools (`Gadgets/Tools/<Gadget>Tools.swift`).
public struct GadgetGuide: Equatable {
    public struct Example: Equatable {
        /// Action of a tool of the same gadget (`arrange`), or a full MCP name of another gadget's tool.
        public let action: String
        public let arguments: JSONValue
        /// Korean: when this call is the right one.
        public let note: String

        public init(_ action: String, _ arguments: JSONValue = .object([:]), note: String) {
            self.action = action
            self.arguments = arguments
            self.note = note
        }
    }

    public let gadget: GadgetID
    /// One or two Korean sentences: what the gadget is for.
    public let summary: String
    /// Korean: the things the tools can do.
    public let canDo: [String]
    /// Korean: the usual order of calls.
    public let steps: [String]
    public let examples: [Example]
    /// Korean: limits, permissions, approval.
    public let limits: [String]

    public init(gadget: GadgetID, summary: String, canDo: [String], steps: [String], examples: [Example], limits: [String]) {
        self.gadget = gadget
        self.summary = summary
        self.canDo = canDo
        self.steps = steps
        self.examples = examples
        self.limits = limits
    }

    public static let mimeType = "text/markdown"

    /// Markdown. `exit` decides the tool names; `tools` is the registry (injectable for tests).
    public func render(for exit: GadgetToolExit, tools: [GadgetTool] = GadgetToolRegistry.all) -> String {
        let own = tools.filter { $0.gadget == gadget && $0.exits.contains(exit) }
        func name(_ t: GadgetTool) -> String { exit == .mcp ? t.mcpName : t.declaredConnectorName }
        func resolve(_ action: String) -> GadgetTool? {
            own.first { $0.action == action } ?? tools.first { $0.mcpName == action && $0.exits.contains(exit) }
        }
        var out = "# \(gadget.koreanName) (\(gadget.displayName)) 사용 가이드\n\n\(summary)\n"
        if !canDo.isEmpty { out += "\n## 할 수 있는 일\n" + canDo.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !own.isEmpty {
            out += "\n## 도구\n"
            for t in own {
                var line = "- `\(name(t))` [\(t.risk.rawValue)] \(t.koreanDescription)"
                if !t.permissions.isEmpty { line += " (권한: \(t.permissions.sorted().map { $0.displayName }.joined(separator: ", ")))" }
                out += line + "\n"
            }
        }
        if !steps.isEmpty {
            out += "\n## 순서\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
        }
        let shown = examples.compactMap { e -> String? in
            guard let t = resolve(e.action) else { return nil }
            let args = String(decoding: JSONRPCCodec.encodeSorted(e.arguments), as: UTF8.self)
            return "- \(e.note)\n  `\(name(t)) \(args)`"
        }
        if !shown.isEmpty { out += "\n## 예시 호출\n" + shown.joined(separator: "\n") + "\n" }
        var notes = limits
        notes.append(GadgetGuide.approvalNote(exit))
        out += "\n## 제약·권한\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n"
        return out
    }

    static func approvalNote(_ exit: GadgetToolExit) -> String {
        switch exit {
        case .connector:
            return "위험도 read·change는 바로 실행돼요. content_out·input_inject는 매번 사용자 승인을 받아요(가젯을 '항상 허용'으로 켠 경우만 제외). destructive는 늘 승인을 받아요."
        case .mcp:
            return "MCP 클라이언트는 API 키와 나초콤보의 도구군·가젯 스위치(기본 꺼짐)로 막아요. 꺼진 가젯의 도구는 목록에 없고 호출도 거절돼요."
        }
    }
}

/// A frequent flow offered as an MCP prompt (`prompts/list`, `prompts/get`).
public struct GadgetPrompt: Equatable {
    public struct Argument: Equatable {
        public let name: String
        public let description: String
        public let required: Bool
        public init(_ name: String, _ description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public let gadget: GadgetID
    /// `[a-z0-9_]`; the prompt name is `<gadget>_<flow>`.
    public let flow: String
    public let description: String
    public let arguments: [Argument]
    /// The user message. `{name}` is replaced by the argument's value (empty when not given).
    public let template: String

    public init(gadget: GadgetID, flow: String, description: String, arguments: [Argument] = [], template: String) {
        self.gadget = gadget
        self.flow = flow
        self.description = description
        self.arguments = arguments
        self.template = template
    }

    public var name: String { "\(gadget.rawValue)_\(flow)" }

    public func render(_ values: [String: String]) -> String {
        var text = template
        for a in arguments { text = text.replacingOccurrences(of: "{\(a.name)}", with: values[a.name] ?? "") }
        return text
    }
}

extension JSONRPCCodec {
    /// Stable key order (guides and logs).
    static func encodeSorted(_ value: JSONValue) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(value)) ?? Data("null".utf8)
    }
}
