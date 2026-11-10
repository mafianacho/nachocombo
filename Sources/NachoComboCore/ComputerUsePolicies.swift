import Foundation

/// Argument rules that do not depend on macOS, so they are unit-tested on Linux. The macOS backend calls them
/// before it touches the system; a violation becomes a tool error and nothing is executed.
public struct PolicyError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: keyboard

public enum KeyboardMap {
    // CGEventFlags raw values.
    public static let shift: UInt64 = 0x0002_0000
    public static let control: UInt64 = 0x0004_0000
    public static let option: UInt64 = 0x0008_0000
    public static let command: UInt64 = 0x0010_0000
    public static let function: UInt64 = 0x0080_0000

    private static let codes: [String: UInt16] = {
        var m: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101,
            "f10": 109, "f11": 103, "f12": 111,
        ]
        m["arrowleft"] = 123; m["arrowright"] = 124; m["arrowdown"] = 125; m["arrowup"] = 126
        return m
    }()

    public static func keyCode(for name: String) -> UInt16? {
        codes[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    public static func modifierFlags(_ names: [String]) throws -> UInt64 {
        var flags: UInt64 = 0
        for raw in names {
            switch raw.lowercased() {
            case "cmd", "command", "meta", "super": flags |= command
            case "shift": flags |= shift
            case "option", "opt", "alt": flags |= option
            case "control", "ctrl": flags |= control
            case "fn", "function": flags |= function
            default: throw PolicyError("Unknown modifier key: \(raw)")
            }
        }
        return flags
    }
}

// MARK: input / screenshot / shell limits

public enum InputPolicy {
    public static let maxTextLength = 4000
    public static let maxCoordinate = 100_000.0

    public static func validatePoint(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, abs(x) <= maxCoordinate, abs(y) <= maxCoordinate else {
            throw PolicyError("Invalid coordinates")
        }
    }

    public static func validateText(_ text: String) throws {
        guard !text.isEmpty else { throw PolicyError("The text to type is empty") }
        guard text.count <= maxTextLength else { throw PolicyError("Text can be at most \(maxTextLength) characters") }
    }

    public static func validateClickCount(_ count: Int?) throws -> Int {
        let value = count ?? 1
        guard (1...3).contains(value) else { throw PolicyError("clickCount must be 1 to 3") }
        return value
    }
}

public enum ScreenshotPolicy {
    public static let defaultMaxWidth = 1568
    public static let minWidth = 64
    public static let maxWidthLimit = 4096

    public static func clampMaxWidth(_ requested: Int?) -> Int {
        guard let requested = requested else { return defaultMaxWidth }
        return min(max(requested, minWidth), maxWidthLimit)
    }
}

public enum ShellPolicy {
    public static let defaultTimeout = 30
    public static let maxTimeout = 120
    public static let maxOutputBytes = 65_536

    public static func clampTimeout(_ requested: Int?) -> Int {
        guard let requested = requested else { return defaultTimeout }
        return min(max(requested, 1), maxTimeout)
    }
}

// MARK: open

public enum OpenPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    public static func validateURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw PolicyError("Not a valid URL")
        }
        guard allowedSchemes.contains(scheme) else { throw PolicyError("Only http, https and mailto URLs can be opened") }
        if scheme != "mailto", (url.host ?? "").isEmpty { throw PolicyError("The URL has no host") }
        return url
    }

    /// Kinds of file whose default handler runs code or installs something. They are never opened through this tool.
    private static let blockedExtensions: Set<String> = [
        "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "pl", "rb", "app", "pkg", "mpkg", "dmg",
        "scpt", "scptd", "applescript", "workflow", "action", "terminal", "jar", "webloc", "inetloc", "fileloc",
        "prefpane", "saver", "plugin", "kext", "xpc", "osax", "iso",
    ]

    public static func validateFilePath(_ path: String) throws -> String {
        guard !path.isEmpty, path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PolicyError("An absolute path is required")
        }
        let normalized = PathNormalizer.normalize(path)
        let ext = PathNormalizer.pathExtension(normalized)
        if blockedExtensions.contains(ext) { throw PolicyError("Executable and installer items cannot be opened with this tool (.\(ext))") }
        return normalized
    }
}

enum PathNormalizer {
    /// Lexical normalisation: resolves "." and ".." and duplicate slashes without touching the file system.
    /// (The macOS backend additionally resolves symlinks and checks the real path again.)
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(component)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// (parent, last component) of an already normalised path.
    static func split(_ path: String) -> (String, String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let parent = String(path[path.startIndex..<slash])
        return (parent.isEmpty ? "/" : parent, String(path[path.index(after: slash)...]))
    }

    static func pathExtension(_ path: String) -> String {
        let last = split(path).1
        guard let dot = last.lastIndex(of: "."), dot != last.startIndex else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }
}

// MARK: files

public struct FilePolicy {
    public static let maxReadBytes = 262_144
    public static let maxWriteBytes = 1_048_576

    private let home: String
    private let protectedPaths: [String]

    /// - Parameters:
    ///   - home: the user's home directory.
    ///   - protectedPaths: extra paths that can be neither read nor written (the app's own key and settings folder).
    public init(home: String, protectedPaths: [String]) {
        self.home = PathNormalizer.normalize(home)
        self.protectedPaths = protectedPaths.map { PathNormalizer.normalize($0) }
    }

    private static let shellInitFiles: Set<String> = [
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login", ".profile",
    ]

    public func check(path: String, write: Bool) throws {
        guard !path.isEmpty, path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PolicyError("An absolute path is required")
        }
        let normalized = PathNormalizer.normalize(path)
        let lower = normalized.lowercased()   // APFS is case-insensitive by default
        func inside(_ root: String) -> Bool {
            let r = root.lowercased()
            return lower == r || lower.hasPrefix(r == "/" ? "/" : r + "/")
        }
        let neverTouch = [home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/Library/Keychains"] + protectedPaths
        if neverTouch.contains(where: inside) { throw PolicyError("This location is protected") }
        guard write else { return }
        let writableRoots = [home, "/tmp", "/private/tmp"]
        guard writableRoots.contains(where: inside) else { throw PolicyError("Writing is only allowed under the home folder and /tmp") }
        let autoRun = [home + "/Library/LaunchAgents", home + "/Library/LaunchDaemons", home + "/Library/Preferences",
                       home + "/Library/Application Support/com.apple.TCC"]
        if autoRun.contains(where: inside) { throw PolicyError("Cannot write to auto-run or system settings locations") }
        let (parent, last) = PathNormalizer.split(lower)
        if parent == home.lowercased(), FilePolicy.shellInitFiles.contains(last) {
            throw PolicyError("Cannot write to shell startup files")
        }
    }
}

// MARK: processes

public enum ProcessPolicy {
    public static func validateKill(pid: Int, signal: String?, ownPid: Int) throws -> Int32 {
        guard pid > 1, pid != ownPid, pid <= Int(Int32.max) else { throw PolicyError("This process cannot be terminated") }
        guard let name = signal?.uppercased().replacingOccurrences(of: "SIG", with: "") else { return 15 }
        switch name {
        case "TERM": return 15
        case "KILL": return 9
        case "INT": return 2
        case "HUP": return 1
        default: throw PolicyError("Allowed signals are TERM, KILL, INT and HUP")
        }
    }
}
