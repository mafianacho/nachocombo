import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Nacho's desktop actions beyond one window: apps, several windows at once, system controls and saved workspaces.
// Everything here is plain data and rules (testable on Linux); the app target does the AppKit / Accessibility work.

// MARK: - Apps

/// One app Nacho may name: running now and/or installed in an Applications folder.
public struct PetAppEntry: Equatable {
    public var bundleID: String
    /// Names the user may say: the Finder's (localized, e.g. "계산기"), CFBundleDisplayName, CFBundleName, file name.
    public var names: [String]
    public var running: Bool

    public init(bundleID: String, names: [String], running: Bool) {
        self.bundleID = bundleID
        self.names = names
        self.running = running
    }

    public var displayName: String { names.first ?? bundleID }
}

public enum PetAppMatch: Equatable {
    case found(PetAppEntry)
    case ambiguous([PetAppEntry])
    case none(suggestions: [String])
}

public enum PetAppMatcher {
    /// "Google Chrome.app" → "googlechrome": case, spaces, dots before "app" and punctuation do not matter.
    public static func fold(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix(".app") { t = String(t.dropLast(4)) }
        return String(t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Exact match on a name or the bundle ID first (running apps win a tie), then a single partial match
    /// (2+ characters). Several partial matches are ambiguous; nothing gives up to five suggestions.
    public static func match(_ query: String, in entries: [PetAppEntry]) -> PetAppMatch {
        let q = fold(query)
        let rawQ = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return .none(suggestions: []) }
        let unique = dedupe(entries)
        let exact = unique.filter { e in e.bundleID.lowercased() == rawQ || e.names.contains { fold($0) == q } }
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 {
            let running = exact.filter { $0.running }
            if running.count == 1 { return .found(running[0]) }
            return .ambiguous(exact)
        }
        guard q.count >= 2 else { return .none(suggestions: []) }
        let partial = unique.filter { e in e.names.contains { fold($0).contains(q) } }
        if partial.count == 1 { return .found(partial[0]) }
        if partial.count > 1 {
            let running = partial.filter { $0.running }
            if running.count == 1 { return .found(running[0]) }
            return .ambiguous(Array(partial.prefix(8)))
        }
        // A word in common (e.g. "chrome canary" vs "Google Chrome Canary") still helps the model ask back.
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map { fold(String($0)) }.filter { $0.count >= 2 }
        let near = unique.filter { e in words.contains { w in e.names.contains { fold($0).contains(w) } } }
        return .none(suggestions: Array(near.prefix(5).map { $0.displayName }))
    }

    /// One entry per bundle ID: names merged, running if any copy runs.
    public static func dedupe(_ entries: [PetAppEntry]) -> [PetAppEntry] {
        var order: [String] = []
        var byID: [String: PetAppEntry] = [:]
        for e in entries {
            let key = e.bundleID.lowercased()
            if var existing = byID[key] {
                for n in e.names where !existing.names.contains(n) { existing.names.append(n) }
                existing.running = existing.running || e.running
                byID[key] = existing
            } else {
                order.append(key)
                byID[key] = e
            }
        }
        return order.compactMap { byID[$0] }
    }

    /// Apps Nacho never hides or quits: this app and the parts of macOS that keep the desktop working.
    public static let protectedBundleIDs: Set<String> = [
        "com.mafianacho.nachocombo", "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
    ]

    public static func isProtected(_ bundleID: String) -> Bool {
        protectedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

// MARK: - Several windows

/// One window Nacho places in a multi-window layout. `display` is 1-based in left-to-right order
/// (as `combo_list_windows` lists them); `window` is 1-based front to back among the app's windows.
public struct PetWindowPlacement: Equatable {
    public var app: String
    public var position: SnapAction
    public var display: Int?
    public var window: Int

    public init(app: String, position: SnapAction, display: Int? = nil, window: Int = 1) {
        self.app = app
        self.position = position
        self.display = display
        self.window = window
    }
}

public enum PetDisplays {
    /// Screens in the order Nacho numbers them: left to right, then top to bottom (same as next / previous display).
    public static func ordered(_ screens: [CGRect]) -> [Int] {
        screens.indices.sorted {
            screens[$0].minX != screens[$1].minX ? screens[$0].minX < screens[$1].minX : screens[$0].maxY > screens[$1].maxY
        }
    }

    /// Index into `screens` for Nacho's 1-based display number, or nil when there is no such display.
    public static func index(forNumber number: Int, screens: [CGRect]) -> Int? {
        let order = ordered(screens)
        guard number >= 1, number <= order.count else { return nil }
        return order[number - 1]
    }

    /// Nacho's 1-based number for a screen index.
    public static func number(forIndex index: Int, screens: [CGRect]) -> Int? {
        ordered(screens).firstIndex(of: index).map { $0 + 1 }
    }
}

// MARK: - System controls

public struct PetSystemChange: Equatable {
    /// 0...100 each; nil = leave as it is.
    public var volume: Int?
    public var brightness: Int?
    public var doNotDisturb: Bool?

    public init(volume: Int? = nil, brightness: Int? = nil, doNotDisturb: Bool? = nil) {
        self.volume = volume
        self.brightness = brightness
        self.doNotDisturb = doNotDisturb
    }

    public var isEmpty: Bool { volume == nil && brightness == nil && doNotDisturb == nil }
}

/// Result of one part of a system change: the model hears each part (a Mac may set the volume but not the brightness).
public struct PetPartResult: Equatable {
    public var name: String
    public var ok: Bool
    public var message: String

    public init(name: String, ok: Bool, message: String) {
        self.name = name
        self.ok = ok
        self.message = message
    }

    public static func summary(_ parts: [PetPartResult]) -> PetCommandOutcome {
        let ok = !parts.isEmpty && parts.allSatisfy { $0.ok }
        let text = parts.map { "\($0.name): \($0.ok ? "done" : "not done") — \($0.message)" }.joined(separator: " ")
        var o = PetCommandOutcome(ok: ok, message: text)
        o.details = ["results": parts.map { ["name": $0.name, "ok": $0.ok, "message": $0.message] as [String: Any] }]
        return o
    }
}

// MARK: - Workspaces

/// A named desktop: which apps run, where their windows are, which gadgets are on. Saved by Nacho on request and put
/// back later; putting it back opens missing apps but never quits anything.
public struct DesktopWorkspace: Codable, Equatable {
    public struct App: Codable, Equatable {
        public var bundleID: String
        public var name: String
        public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
    }

    public var name: String
    public var savedAt: Date
    /// `DisplaySignature` of the displays it was saved on (frames on a missing display are pulled onto one that is there).
    public var displays: String
    public var apps: [App]
    public var windows: [SavedWindow]
    /// Gadget raw value → on. Only gadgets Nacho may switch are kept.
    public var gadgets: [String: Bool]

    public init(name: String, savedAt: Date, displays: String, apps: [App], windows: [SavedWindow], gadgets: [String: Bool]) {
        self.name = name
        self.savedAt = savedAt
        self.displays = displays
        self.apps = apps
        self.windows = windows
        self.gadgets = gadgets
    }

    /// Lenient: a field this version does not know is ignored, a missing list is empty (files written by later versions).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        savedAt = (try? c.decode(Date.self, forKey: .savedAt)) ?? Date(timeIntervalSince1970: 0)
        displays = (try? c.decode(String.self, forKey: .displays)) ?? ""
        apps = (try? c.decode([App].self, forKey: .apps)) ?? []
        windows = (try? c.decode([SavedWindow].self, forKey: .windows)) ?? []
        gadgets = (try? c.decode([String: Bool].self, forKey: .gadgets)) ?? [:]
    }

    /// Gadgets with a known id that Nacho may switch (a renamed or removed gadget in an old file is skipped).
    public var gadgetSwitches: [(ModuleID, Bool)] {
        gadgets.compactMap { key, on in ModuleID(rawValue: key).flatMap { PetCommands.toggleable.contains($0) ? ($0, on) : nil } }
            .sorted { $0.0.rawValue < $1.0.rawValue }
    }

    public var summary: String {
        "\(apps.count) app\(apps.count == 1 ? "" : "s"), \(windows.count) window\(windows.count == 1 ? "" : "s"), "
            + "\(gadgets.values.filter { $0 }.count) gadget\(gadgets.values.filter { $0 }.count == 1 ? "" : "s") on"
    }

    public var koreanSummary: String { "앱 \(apps.count)개 · 창 \(windows.count)개 · 가젯 \(gadgets.values.filter { $0 }.count)개 켜짐" }
}

public enum WorkspaceNameProblem: Error, Equatable {
    case empty, tooLong, badCharacters
    public var message: String {
        switch self {
        case .empty: return "name must not be empty"
        case .tooLong: return "name must be at most \(DesktopWorkspaceStore.maxNameLength) characters"
        case .badCharacters: return "name must be printable text on one line"
        }
    }
}

public struct DesktopWorkspaceStore: Codable, Equatable {
    public static let maxWorkspaces = 20
    public static let maxNameLength = 40
    public static let fileVersion = 1

    public private(set) var workspaces: [DesktopWorkspace] = []

    public init(workspaces: [DesktopWorkspace] = []) { self.workspaces = workspaces }

    private enum CodingKeys: String, CodingKey { case version, workspaces }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Entries that fail to decode (hand-edited, truncated) are dropped one by one, not the whole file.
        var list = try c.nestedUnkeyedContainer(forKey: .workspaces)
        var result: [DesktopWorkspace] = []
        while !list.isAtEnd {
            if let w = try? list.decode(DesktopWorkspace.self) { result.append(w) } else { _ = try? list.decode(Skip.self) }
        }
        workspaces = result
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(DesktopWorkspaceStore.fileVersion, forKey: .version)
        try c.encode(workspaces, forKey: .workspaces)
    }

    private struct Skip: Decodable {}

    /// Trimmed, 1...40 characters, no control characters or line breaks.
    public static func validName(_ raw: String) -> Result<String, WorkspaceNameProblem> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.empty) }
        guard t.count <= maxNameLength else { return .failure(.tooLong) }
        guard t.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f && !(0x80...0x9f).contains($0.value)
            && $0.value != 0x2028 && $0.value != 0x2029 })
        else { return .failure(.badCharacters) }
        return .success(t)
    }

    /// Names compare without case and spacing: "업무 모드" and "업무모드" are the same workspace.
    public static func key(_ name: String) -> String {
        name.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    public func workspace(named name: String) -> DesktopWorkspace? {
        let k = DesktopWorkspaceStore.key(name)
        return workspaces.first { DesktopWorkspaceStore.key($0.name) == k }
    }

    public enum SaveResult: Equatable { case added, replaced, full }

    /// Same name replaces (newest first); a new name when the list is full is refused, never evicting one silently.
    public mutating func save(_ workspace: DesktopWorkspace) -> SaveResult {
        let k = DesktopWorkspaceStore.key(workspace.name)
        if let i = workspaces.firstIndex(where: { DesktopWorkspaceStore.key($0.name) == k }) {
            workspaces.remove(at: i)
            workspaces.insert(workspace, at: 0)
            return .replaced
        }
        guard workspaces.count < DesktopWorkspaceStore.maxWorkspaces else { return .full }
        workspaces.insert(workspace, at: 0)
        return .added
    }

    @discardableResult
    public mutating func remove(named name: String) -> Bool {
        let k = DesktopWorkspaceStore.key(name)
        let before = workspaces.count
        workspaces.removeAll { DesktopWorkspaceStore.key($0.name) == k }
        return workspaces.count != before
    }

    public static func decode(_ data: Data) -> DesktopWorkspaceStore? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(DesktopWorkspaceStore.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    public static func load(from url: URL) -> DesktopWorkspaceStore {
        guard let data = try? Data(contentsOf: url) else { return DesktopWorkspaceStore() }
        return decode(data) ?? DesktopWorkspaceStore()
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

/// How the parts of applying a workspace went, in one message for the model.
public struct WorkspaceApplyReport: Equatable {
    public var name: String
    public var openedApps: [String] = []
    public var missingApps: [String] = []
    public var failedApps: [String] = []
    public var placedWindows = 0
    public var savedWindows = 0
    /// Windows were skipped because Nacho Combo has no Accessibility permission.
    public var windowsNeedPermission = false
    public var gadgetsChanged: [String] = []
    public var gadgetsRefused: [String] = []

    public init(name: String) { self.name = name }

    public var ok: Bool { missingApps.isEmpty && failedApps.isEmpty && !windowsNeedPermission && gadgetsRefused.isEmpty }

    public var outcome: PetCommandOutcome {
        var parts = ["Workspace \"\(name)\":"]
        parts.append(openedApps.isEmpty ? "no app had to be opened (apps already open were left running)."
                     : "opened \(openedApps.joined(separator: ", ")) (apps already open were left running).")
        if !missingApps.isEmpty { parts.append("Not installed on this Mac: \(missingApps.joined(separator: ", ")).") }
        if !failedApps.isEmpty { parts.append("Could not open: \(failedApps.joined(separator: ", ")).") }
        if windowsNeedPermission {
            parts.append("Windows were not moved: \(PetPermissionHelp.accessibility)")
        } else {
            parts.append("Placed \(placedWindows) of \(savedWindows) saved windows.")
        }
        if !gadgetsChanged.isEmpty { parts.append("Gadgets: \(gadgetsChanged.joined(separator: ", ")).") }
        if !gadgetsRefused.isEmpty { parts.append("Not switched: \(gadgetsRefused.joined(separator: "; ")).") }
        var o = PetCommandOutcome(ok: ok, message: parts.joined(separator: " "))
        o.details = ["opened": openedApps, "missing": missingApps, "placed": placedWindows, "saved_windows": savedWindows]
        return o
    }
}

/// How to grant what is missing, said to the model so it can tell the user (Monterey "System Preferences",
/// Ventura and later "System Settings").
public enum PetPermissionHelp {
    public static let accessibility = "Nacho Combo has no Accessibility permission. To allow it: open System Settings "
        + "(System Preferences on macOS 12) > Privacy & Security > Accessibility and switch on Nacho Combo, "
        + "or switch on the Window Snap gadget in Nacho Combo, which asks for it. "
        + "(손쉬운 사용 권한: 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Nacho Combo를 켜 주세요.)"
}
