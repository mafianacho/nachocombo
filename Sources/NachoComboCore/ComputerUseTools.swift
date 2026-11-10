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
    public let name: String
    public let description: String
    public let group: ToolGroup
    public let inputSchema: JSONValue

    var json: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": inputSchema])
    }
}

/// All tools the server can offer. What a client actually sees is filtered by the group switches at call time.
public enum ToolCatalog {
    private static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties),
                                           "additionalProperties": .bool(false)]
        if !required.isEmpty { object["required"] = .array(required.map { JSONValue.string($0) }) }
        return .object(object)
    }
    private static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }
    private static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }
    private static func choice(_ values: [String], _ description: String) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map { JSONValue.string($0) }),
                 "description": .string(description)])
    }
    private static func list(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                 "description": .string(description)])
    }

    private static let windowTarget: [String: JSONValue] = [
        "pid": integer("Process ID of the app that owns the window (from app_list/window_list)"),
        "windowIndex": integer("Window number within that app (starts at 0, the index from window_list)"),
    ]

    public static let all: [ToolDefinition] = [
        // screen
        ToolDefinition(name: "screen_list_displays", description: "Returns the connected displays (ID, size, scale, whether it is the main display).",
                       group: .screen, inputSchema: schema()),
        ToolDefinition(name: "screen_capture",
                       description: "Returns a screenshot as PNG. target: display (whole display, displayId optional), window (needs windowId), region (needs x, y, width, height in screen points).",
                       group: .screen,
                       inputSchema: schema([
                           "target": choice(["display", "window", "region"], "What to capture"),
                           "displayId": integer("Display ID (main display if omitted)"),
                           "windowId": integer("Window ID (windowId from window_list)"),
                           "x": number("Region top-left x"), "y": number("Region top-left y"),
                           "width": number("Region width"), "height": number("Region height"),
                           "maxWidth": integer("Wider images are scaled down keeping the aspect ratio (default \(ScreenshotPolicy.defaultMaxWidth))"),
                       ], required: ["target"])),
        // apps and windows
        ToolDefinition(name: "app_list", description: "Running regular apps (name, bundleId, pid, whether active).", group: .appsWindows, inputSchema: schema()),
        ToolDefinition(name: "app_open", description: "Launches an app. Give either bundleId or name.", group: .appsWindows,
                       inputSchema: schema(["bundleId": string("e.g. com.apple.Safari"), "name": string("App name")])),
        ToolDefinition(name: "app_activate", description: "Brings an app to the front. Give either pid or bundleId.", group: .appsWindows,
                       inputSchema: schema(["pid": integer("Process ID"), "bundleId": string("bundleId")])),
        ToolDefinition(name: "app_quit", description: "Asks an app to quit normally (the app handles save prompts and so on). For a forced quit use process_kill.", group: .appsWindows,
                       inputSchema: schema(["pid": integer("Process ID"), "bundleId": string("bundleId")])),
        ToolDefinition(name: "window_list", description: "Visible windows (windowId, pid, app name, title, position and size, index).", group: .appsWindows, inputSchema: schema()),
        ToolDefinition(name: "window_set_frame", description: "Changes a window's position and size. Only the given values among x, y, width, height are changed.", group: .appsWindows,
                       inputSchema: schema(windowTarget.merging([
                           "x": number("New x"), "y": number("New y"), "width": number("New width"), "height": number("New height"),
                       ]) { a, _ in a }, required: ["pid", "windowIndex"])),
        ToolDefinition(name: "window_minimize", description: "Minimizes a window or restores it.", group: .appsWindows,
                       inputSchema: schema(windowTarget.merging(["minimized": boolean("true = minimize, false = restore (default true)")]) { a, _ in a },
                                           required: ["pid", "windowIndex"])),
        // input
        ToolDefinition(name: "mouse_move", description: "Moves the mouse pointer to screen coordinates (in points).", group: .input,
                       inputSchema: schema(["x": number("x"), "y": number("y")], required: ["x", "y"])),
        ToolDefinition(name: "mouse_click", description: "Clicks at the given coordinates.", group: .input,
                       inputSchema: schema(["x": number("x"), "y": number("y"),
                                            "button": choice(["left", "right", "middle"], "Default left"),
                                            "clickCount": integer("1 to 3, default 1")], required: ["x", "y"])),
        ToolDefinition(name: "mouse_drag", description: "Drags from one point to another.", group: .input,
                       inputSchema: schema(["fromX": number("Start x"), "fromY": number("Start y"),
                                            "toX": number("End x"), "toY": number("End y")],
                                           required: ["fromX", "fromY", "toX", "toY"])),
        ToolDefinition(name: "mouse_scroll", description: "Scrolls (in pixels). If x and y are given, the pointer moves there first.", group: .input,
                       inputSchema: schema(["deltaX": integer("Horizontal"), "deltaY": integer("Vertical (positive = up)"),
                                            "x": number("x"), "y": number("y")])),
        ToolDefinition(name: "key_press", description: "One key press (plus modifier keys). Example: key=\"c\", modifiers=[\"cmd\"]. Key names: a-z, 0-9, return, tab, space, delete, escape, arrow keys (left/right/up/down), f1-f12 and so on.", group: .input,
                       inputSchema: schema(["key": string("Key name"),
                                            "modifiers": list("cmd, shift, option(alt), control(ctrl), fn")], required: ["key"])),
        ToolDefinition(name: "type_text", description: "Types text into the focused field (up to \(InputPolicy.maxTextLength) characters).", group: .input,
                       inputSchema: schema(["text": string("Text to type")], required: ["text"])),
        // clipboard
        ToolDefinition(name: "clipboard_read", description: "Reads the text on the clipboard.", group: .clipboard, inputSchema: schema()),
        ToolDefinition(name: "clipboard_write", description: "Writes text to the clipboard.", group: .clipboard,
                       inputSchema: schema(["text": string("Text to copy")], required: ["text"])),
        // open
        ToolDefinition(name: "open_url", description: "Opens a URL in the default app (http, https and mailto only).", group: .openItems,
                       inputSchema: schema(["url": string("URL")], required: ["url"])),
        ToolDefinition(name: "open_file", description: "Opens a file in the default app (absolute path; executable file types are refused).", group: .openItems,
                       inputSchema: schema(["path": string("Absolute path")], required: ["path"])),
        // system
        ToolDefinition(name: "system_info", description: "Summary of macOS version, model, uptime, battery, volume and displays.", group: .systemInfo, inputSchema: schema()),
        ToolDefinition(name: "process_list", description: "Running processes (pid, name). Command-line arguments are not included.", group: .systemInfo, inputSchema: schema()),
        // high risk
        ToolDefinition(name: "applescript_run", description: "[High risk] Runs AppleScript and returns the result.", group: .appleScript,
                       inputSchema: schema(["script": string("AppleScript source")], required: ["script"])),
        ToolDefinition(name: "shell_run", description: "[High risk] Runs a command with /bin/zsh -c (time and output size limits).", group: .shell,
                       inputSchema: schema(["command": string("Command"), "cwd": string("Working directory (absolute path, optional)"),
                                            "timeoutSeconds": integer("1 to \(ShellPolicy.maxTimeout), default \(ShellPolicy.defaultTimeout)")],
                                           required: ["command"])),
        ToolDefinition(name: "file_read", description: "[High risk] Reads a text file (up to \(FilePolicy.maxReadBytes) bytes).", group: .fileAccess,
                       inputSchema: schema(["path": string("Absolute path")], required: ["path"])),
        ToolDefinition(name: "file_write", description: "[High risk] Writes a text file (append=true appends).", group: .fileAccess,
                       inputSchema: schema(["path": string("Absolute path"), "content": string("Content"),
                                            "append": boolean("Whether to append")], required: ["path", "content"])),
        ToolDefinition(name: "process_kill", description: "[High risk] Sends a signal to a process (TERM by default; KILL/INT/HUP also allowed).", group: .processControl,
                       inputSchema: schema(["pid": integer("Process ID"), "signal": choice(["TERM", "KILL", "INT", "HUP"], "Default TERM")],
                                           required: ["pid"])),
    ]

    public static func definition(named name: String) -> ToolDefinition? { all.first { $0.name == name } }
    public static func tools(in group: ToolGroup) -> [ToolDefinition] { all.filter { $0.group == group } }
}
