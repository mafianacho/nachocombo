import Foundation

/// OS permissions the module may need. They are requested only when a tool group that needs them is switched on.
public enum OSPermission: String, Codable, CaseIterable, Comparable {
    case screenRecording
    case accessibility
    case automation

    public var displayName: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .automation: return "Automation (Apple Events)"
        }
    }

    public static func < (lhs: OSPermission, rhs: OSPermission) -> Bool {
        let order = OSPermission.allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Every tool belongs to exactly one group, and every group has its own switch (all OFF by default).
public enum ToolGroup: String, Codable, CaseIterable {
    case screen
    case appsWindows
    case input
    case clipboard
    case openItems
    case systemInfo
    // High risk: separate switches, never enabled by default.
    case appleScript
    case shell
    case fileAccess
    case processControl

    public var displayName: String {
        switch self {
        case .screen: return "Screen"
        case .appsWindows: return "Apps & Windows"
        case .input: return "Input"
        case .clipboard: return "Clipboard"
        case .openItems: return "Open"
        case .systemInfo: return "System Info"
        case .appleScript: return "Run AppleScript"
        case .shell: return "Run Shell Commands"
        case .fileAccess: return "Read & Write Files"
        case .processControl: return "Force Quit Processes"
        }
    }

    public var detail: String {
        switch self {
        case .screen: return "Screenshots (display, window, region) and the display list"
        case .appsWindows: return "List, open, switch to and quit apps; list, move, resize and minimize windows"
        case .input: return "Mouse move, click, drag and scroll; key presses; typing text"
        case .clipboard: return "Read and write clipboard text"
        case .openItems: return "Open URLs (http, https, mailto) and files"
        case .systemInfo: return "OS, model, battery, volume, displays, and the process list"
        case .appleScript: return "Run AppleScript"
        case .shell: return "Run /bin/zsh commands (time and output limits)"
        case .fileAccess: return "Read and write text files (secret keys, keychains and this app's folder excluded)"
        case .processControl: return "Send termination signals to processes"
        }
    }

    public var isHighRisk: Bool {
        switch self {
        case .appleScript, .shell, .fileAccess, .processControl: return true
        default: return false
        }
    }

    /// Short consequence line shown next to a high-risk switch.
    public var riskNote: String? {
        switch self {
        case .appleScript: return "Whoever holds a key can control apps freely and can also run shell commands with do shell script (this can bypass the shell and file limits)."
        case .shell: return "Whoever holds a key can run commands on this Mac with your user permissions (this can bypass the file limits)."
        case .fileAccess: return "Whoever holds a key can read and write any file you can access (secret keys and the login items folder excluded)."
        case .processControl: return "Whoever holds a key can force-quit running processes."
        default: return nil
        }
    }

    public var requiredPermissions: Set<OSPermission> {
        switch self {
        case .screen: return [.screenRecording]
        case .appsWindows, .input: return [.accessibility]
        case .appleScript: return [.automation]
        case .clipboard, .openItems, .systemInfo, .shell, .fileAccess, .processControl: return []
        }
    }
}

/// Who may connect. `localOnly` (default): this computer only, plain HTTP on loopback. `lan`: other computers of the
/// same local network too; the app then serves TLS only (self-signed certificate, fingerprint pinned by the client).
/// Any value other than "lan" found in a settings file means `localOnly`.
public enum ComputerUseListenMode: String, Codable, CaseIterable {
    case localOnly
    case lan
}

/// Settings of the Computer Use module. Stored inside the normal settings file; API keys are NOT here (hashes live in
/// their own 0600 file).
public struct ComputerUseSettings: Codable, Equatable {
    public static let defaultPort = 47653
    public static let loopbackAddresses = ["127.0.0.1", "::1"]

    public var port: Int
    /// Always a loopback address. Anything else found in a settings file is replaced by 127.0.0.1.
    public private(set) var bindAddress: String
    public var enabledGroups: [String: Bool]
    /// Extra Host header names accepted besides localhost/127.0.0.1/[::1] (for example a tunnel hostname).
    public var allowedHosts: [String]
    /// Default `localOnly`. Files written before LAN mode existed, and unknown values, load as `localOnly`.
    public var listenMode: ComputerUseListenMode

    /// Address the server binds to in LAN mode (every interface; the peer address check keeps public peers out).
    public static let lanBindAddress = "0.0.0.0"

    /// What the server socket must bind to right now. `bindAddress` itself stays a loopback address.
    public var effectiveBindAddress: String { listenMode == .lan ? ComputerUseSettings.lanBindAddress : bindAddress }

    /// LAN mode is never served in plain text.
    public var requiresTLS: Bool { listenMode == .lan }

    public init(port: Int = ComputerUseSettings.defaultPort, enabledGroups: [String: Bool] = [:], allowedHosts: [String] = [],
                listenMode: ComputerUseListenMode = .localOnly) {
        self.listenMode = listenMode
        self.port = ComputerUseSettings.isValidPort(port) ? port : ComputerUseSettings.defaultPort
        self.bindAddress = "127.0.0.1"
        self.enabledGroups = enabledGroups
        self.allowedHosts = allowedHosts
    }

    private enum CodingKeys: String, CodingKey { case port, bindAddress, enabledGroups, allowedHosts, listenMode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawPort = try c.decodeIfPresent(Int.self, forKey: .port) ?? ComputerUseSettings.defaultPort
        port = ComputerUseSettings.isValidPort(rawPort) ? rawPort : ComputerUseSettings.defaultPort
        let rawAddress = try c.decodeIfPresent(String.self, forKey: .bindAddress) ?? "127.0.0.1"
        bindAddress = ComputerUseSettings.isLoopback(rawAddress) ? rawAddress : "127.0.0.1"
        enabledGroups = try c.decodeIfPresent([String: Bool].self, forKey: .enabledGroups) ?? [:]
        allowedHosts = try c.decodeIfPresent([String].self, forKey: .allowedHosts) ?? []
        // Missing, null or any unknown / wrongly typed value: stay local. Never fail the whole settings file over it.
        listenMode = (try? c.decodeIfPresent(ComputerUseListenMode.self, forKey: .listenMode)) ?? .localOnly
    }

    public static func isValidPort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    public static func isLoopback(_ address: String) -> Bool { loopbackAddresses.contains(address) }

    public func isEnabled(_ group: ToolGroup) -> Bool { enabledGroups[group.rawValue] ?? false }

    public mutating func setEnabled(_ group: ToolGroup, _ enabled: Bool) {
        enabledGroups[group.rawValue] = enabled
    }

    public var enabledToolGroups: [ToolGroup] { ToolGroup.allCases.filter { isEnabled($0) } }

    /// OS permissions needed by the groups that are switched on right now (and only those).
    public var requiredPermissions: [OSPermission] {
        var needed = Set<OSPermission>()
        for group in enabledToolGroups { needed.formUnion(group.requiredPermissions) }
        return needed.sorted()
    }
}
