import Foundation

public enum ToolContent: Equatable {
    case text(String)
    case image(base64: String, mimeType: String)

    var json: JSONValue {
        switch self {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .image(let data, let mime):
            return .object(["type": .string("image"), "data": .string(data), "mimeType": .string(mime)])
        }
    }
}

public struct ToolResult: Equatable {
    public var content: [ToolContent]
    public var isError: Bool

    public init(content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolResult { ToolResult(content: [.text(text)]) }
    public static func error(_ message: String) -> ToolResult { ToolResult(content: [.text(message)], isError: true) }

    var json: JSONValue {
        .object(["content": .array(content.map { $0.json }), "isError": .bool(isError)])
    }
}

/// The platform side of the tools. It is only ever called after the service has checked the key, the emergency
/// stop and the tool group switch; implementations still validate their arguments (see the policies).
public protocol ComputerUseBackend: AnyObject {
    func execute(tool: String, arguments: [String: JSONValue]) -> ToolResult
}

public struct ToolArgumentError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Typed access to the `arguments` object of a tools/call request. Every accessor throws a readable error
/// instead of crashing or silently coercing.
public struct ToolArguments {
    public let values: [String: JSONValue]
    public init(_ values: [String: JSONValue]) { self.values = values }

    public func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw ToolArgumentError("Missing required argument '\(key)'") }
        return value
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard case .string(let s) = value else { throw ToolArgumentError("'\(key)' must be a string") }
        return s
    }

    public func int(_ key: String) throws -> Int {
        guard let value = try optionalInt(key) else { throw ToolArgumentError("Missing required argument '\(key)'") }
        return value
    }

    public func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d) where d.isFinite && d == d.rounded() && abs(d) < 1e15: return Int(d)
        default: throw ToolArgumentError("'\(key)' must be an integer")
        }
    }

    public func double(_ key: String) throws -> Double {
        guard let value = try optionalDouble(key) else { throw ToolArgumentError("Missing required argument '\(key)'") }
        return value
    }

    public func optionalDouble(_ key: String) throws -> Double? {
        guard let value = values[key], value != .null else { return nil }
        switch value {
        case .int(let i): return Double(i)
        case .double(let d) where d.isFinite: return d
        default: throw ToolArgumentError("'\(key)' must be a finite number")
        }
    }

    public func bool(_ key: String) throws -> Bool {
        guard let value = try optionalBool(key) else { throw ToolArgumentError("Missing required argument '\(key)'") }
        return value
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        guard case .bool(let b) = value else { throw ToolArgumentError("'\(key)' must be true or false") }
        return b
    }

    public func stringList(_ key: String) throws -> [String] {
        guard let value = values[key], value != .null else { return [] }
        guard case .array(let items) = value else { throw ToolArgumentError("'\(key)' must be an array of strings") }
        return try items.map {
            guard case .string(let s) = $0 else { throw ToolArgumentError("'\(key)' must be an array of strings") }
            return s
        }
    }
}

public struct ToolDefinition: Equatable {
    /// The NachoCombo MCP name (`computer_screen_capture`).
    public let name: String
    public let description: String
    public let group: ToolGroup
    public let inputSchema: JSONValue
    /// The Computer Use name the backend runs and `tools/call` still accepts (`screen_capture`).
    public let legacyName: String

    public init(name: String, description: String, group: ToolGroup, inputSchema: JSONValue, legacyName: String) {
        self.name = name
        self.description = description
        self.group = group
        self.inputSchema = inputSchema
        self.legacyName = legacyName
    }

    var json: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema])
    }
}

/// The Computer Use tools (gadget `computer`), each under its tool group switch. The definitions live in the gadget
/// registry (`Gadgets/Tools/ComputerTools.swift`); this is the view the service and the settings screen use.
public enum ToolCatalog {
    public static let all: [ToolDefinition] = GadgetToolRegistry.all.compactMap { t in
        guard let group = t.mcpGroup, let legacy = t.legacyMCPName, t.exits.contains(.mcp) else { return nil }
        return ToolDefinition(name: t.mcpName, description: t.englishDescription, group: group, inputSchema: t.inputSchema, legacyName: legacy)
    }

    /// The new name or the old Computer Use name.
    public static func definition(named name: String) -> ToolDefinition? { all.first { $0.name == name || $0.legacyName == name } }
    public static func tools(in group: ToolGroup) -> [ToolDefinition] { all.filter { $0.group == group } }
}
