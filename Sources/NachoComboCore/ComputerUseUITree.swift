import Foundation

// Computer Use: the accessibility tree (NACHO-147). `computer_ui_tree` reads the front window (or a whole app) as a
// bounded list of elements, `computer_find_element` searches it by role and title, `computer_click_element` clicks an
// element of a recent answer by its id. Everything that decides what is read and sent lives here (Foundation only, so
// it is tested on Linux); the macOS side (`MacUIElementAccess`) only reads attributes and children of AXUIElements.
//
// What leaves the Mac is bounded three ways: depth, number of elements, and the length of every text. A secure text
// field never has its value read out. The tree is screen content, so the tools are `content_out` on Nacho's path.

/// Bounds of one read. Every value is clamped to its range; nothing unbounded reaches the model.
public struct UITreeLimits: Equatable {
    public static let depthRange = 1...25
    public static let nodeRange = 1...500
    public static let textRange = 10...200
    public static let defaultDepth = 8
    public static let defaultNodes = 200
    public static let defaultText = 80
    /// `computer_find_element` looks at more elements than it sends (it only sends the matches).
    public static let searchNodes = 1_500
    public static let searchDepth = 25
    public static let resultRange = 1...30
    public static let defaultResults = 10

    public var maxDepth: Int
    public var maxNodes: Int
    public var maxTextLength: Int

    public init(maxDepth: Int? = nil, maxNodes: Int? = nil, maxTextLength: Int? = nil) {
        func clamp(_ v: Int?, _ r: ClosedRange<Int>, _ d: Int) -> Int { min(max(v ?? d, r.lowerBound), r.upperBound) }
        self.maxDepth = clamp(maxDepth, UITreeLimits.depthRange, UITreeLimits.defaultDepth)
        self.maxNodes = clamp(maxNodes, UITreeLimits.nodeRange, UITreeLimits.defaultNodes)
        self.maxTextLength = clamp(maxTextLength, UITreeLimits.textRange, UITreeLimits.defaultText)
    }

    static let search = UITreeLimits(raw: searchDepth, searchNodes, defaultText)

    /// Unclamped (the search budget is larger than what a tree answer may send).
    private init(raw depth: Int, _ nodes: Int, _ text: Int) {
        maxDepth = depth
        maxNodes = nodes
        maxTextLength = text
    }
}

/// A rectangle in screen points (top-left origin, the same coordinates `computer_mouse_click` takes).
public struct UIRect: Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var center: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
    public var isUsable: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite } && width >= 1 && height >= 1
    }

    var json: JSONValue {
        func r(_ v: Double) -> JSONValue { .double((v * 10).rounded() / 10) }
        return .object(["x": r(x), "y": r(y), "width": r(width), "height": r(height)])
    }
}

/// The attributes the platform reads from one element (raw: not cut yet).
public struct UIElementInfo: Equatable {
    public var role: String
    public var subrole: String?
    public var title: String?
    /// The element's value as text (a number or a checkbox state becomes text). Never sent for a secure field.
    public var value: String?
    /// The accessibility description (the label of an icon button, for example).
    public var label: String?
    public var frame: UIRect?
    public var enabled: Bool?
    public var focused: Bool?

    public init(role: String, subrole: String? = nil, title: String? = nil, value: String? = nil, label: String? = nil,
                frame: UIRect? = nil, enabled: Bool? = nil, focused: Bool? = nil) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.value = value
        self.label = label
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
    }

    /// Password fields: the value is never read out, whatever the caller asks.
    public var isSecure: Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

/// What the tree tools look at: the front window of an app (default) or the whole app (menu bar and every window).
public enum UITreeScope: String, CaseIterable {
    case window
    case app
}

/// Which app: by process id, by name or bundle id, or (neither) the frontmost app.
public struct UITreeTarget: Equatable {
    public var pid: Int?
    public var app: String?
    public var scope: UITreeScope
    public init(pid: Int? = nil, app: String? = nil, scope: UITreeScope = .window) {
        self.pid = pid
        self.app = app
        self.scope = scope
    }
}

/// The app a tree belongs to.
public struct UITreeApp: Equatable {
    public var name: String
    public var pid: Int
    public var bundleID: String?
    public init(name: String, pid: Int, bundleID: String?) {
        self.name = name
        self.pid = pid
        self.bundleID = bundleID
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(String(name.prefix(100))), "pid": .int(pid)]
        if let b = bundleID { o["bundleId"] = .string(String(b.prefix(200))) }
        return .object(o)
    }
}

/// Element access of the platform. `AnyObject` handles: the macOS side wraps AXUIElements; tests use plain objects.
public protocol UIElementAccess: AnyObject {
    /// The root of the target (front window or app element). Throws `PolicyError` (app or window not found).
    func root(of target: UITreeTarget) throws -> (element: AnyObject, app: UITreeApp)
    /// nil when the element is gone (closed window, removed control).
    func info(of element: AnyObject) -> UIElementInfo?
    func children(of element: AnyObject) -> [AnyObject]
    /// The element's default action (AXPress). false when it has none or the app refused.
    func press(_ element: AnyObject) -> Bool
}

/// One element of an answer, already cut to the limits.
public struct UITreeNode: Equatable {
    /// `t<read>.<n>`: valid for `computer_click_element` while the read is among the last few.
    public let id: String
    public let depth: Int
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let label: String?
    public let frame: UIRect?
    public let enabled: Bool?
    public let focused: Bool?
    public let secure: Bool
    /// How many children the element really has (some may be left out by the limits).
    public let childCount: Int

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "depth": .int(depth), "role": .string(role)]
        if let s = subrole { o["subrole"] = .string(s) }
        if let t = title { o["title"] = .string(t) }
        if let v = value { o["value"] = .string(v) }
        if let l = label { o["label"] = .string(l) }
        if let f = frame { o["frame"] = f.json }
        if enabled == false { o["enabled"] = .bool(false) }
        if focused == true { o["focused"] = .bool(true) }
        if secure { o["secure"] = .bool(true) }
        if childCount > 0 { o["children"] = .int(childCount) }
        return .object(o)
    }
}

/// One bounded read.
public struct UITreeSnapshot {
    public let read: Int
    public let app: UITreeApp
    public let scope: UITreeScope
    /// In tree order (parents before their children, siblings in screen order).
    public let nodes: [UITreeNode]
    /// Elements that exist but were left out (depth or count).
    public let leftOutByDepth: Int
    public let leftOutByCount: Int
    public let limits: UITreeLimits

    public var truncated: Bool { leftOutByDepth > 0 || leftOutByCount > 0 }
}

/// Cuts texts the way the tree answers do: one line, at most `limit` characters (an ellipsis marks a cut).
public enum UITreeText {
    public static func clip(_ raw: String?, _ limit: Int) -> String? {
        guard let raw = raw else { return nil }
        let oneLine = raw.unicodeScalars.map { CharacterSet.newlines.contains($0) || $0 == "\t" ? " " : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        guard !oneLine.isEmpty else { return nil }
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit - 1)) + "…"
    }

    /// `button`, `Button`, `AXButton`, `text_field`, `text field` all read as the same role key.
    public static func roleKey(_ raw: String) -> String {
        var s = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        if s.hasPrefix("ax") { s.removeFirst(2) }
        return s
    }
}

/// Reads bounded trees, remembers the last few reads (for clicks by id) and searches them.
/// Thread-safe; the runner calls it from its own queue.
public final class UITreeReader {
    /// How many reads stay valid for `computer_click_element`.
    public static let keptReads = 5

    private let access: UIElementAccess
    private let lock = NSLock()
    private var counter = 0
    private var kept: [(read: Int, elements: [Int: (element: AnyObject, role: String, title: String?)])] = []

    public init(access: UIElementAccess) { self.access = access }

    /// Breadth first, so a small budget still shows the top of the window (toolbar, main areas) before the depths of
    /// one list. The answer is then put in tree order.
    public func read(_ target: UITreeTarget, limits: UITreeLimits) throws -> UITreeSnapshot {
        let root = try access.root(of: target)
        return walk(root.element, app: root.app, scope: target.scope, limits: limits, keep: { _ in true })
    }

    /// The elements whose role and/or title match (title, label or value contain `title`, ignoring case), at most
    /// `maxResults`, from a search over up to `UITreeLimits.searchNodes` elements.
    public func find(_ target: UITreeTarget, role: String?, title: String?, maxResults: Int,
                     textLimit: Int = UITreeLimits.defaultText) throws -> (snapshot: UITreeSnapshot, scanned: Int) {
        let root = try access.root(of: target)
        let roleKey = role.map(UITreeText.roleKey)
        let needle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var found = 0
        var scanned = 0
        var limits = UITreeLimits.search
        limits.maxTextLength = min(max(textLimit, UITreeLimits.textRange.lowerBound), UITreeLimits.textRange.upperBound)
        let snapshot = walk(root.element, app: root.app, scope: target.scope, limits: limits) { info in
            scanned += 1
            guard found < maxResults, UITreeReader.matches(info, roleKey: roleKey, title: needle) else { return false }
            found += 1
            return true
        }
        return (snapshot, scanned)
    }

    static func matches(_ info: UIElementInfo, roleKey: String?, title: String?) -> Bool {
        if let key = roleKey, !key.isEmpty {
            let own = [info.role, info.subrole].compactMap { $0 }.map(UITreeText.roleKey)
            guard own.contains(key) else { return false }
        }
        if let needle = title, !needle.isEmpty {
            let texts = [info.title, info.label, info.isSecure ? nil : info.value].compactMap { $0 }
            guard texts.contains(where: { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { return false }
        }
        return true
    }

    private struct Pending {
        let element: AnyObject
        let path: [Int]
        let depth: Int
    }

    /// `keep` decides which visited elements go into the answer (all for a tree, the matches for a search). The walk
    /// visits at most `limits.maxNodes` elements for a tree and `searchNodes` for a search.
    private func walk(_ root: AnyObject, app: UITreeApp, scope: UITreeScope, limits: UITreeLimits,
                      keep: (UIElementInfo) -> Bool) -> UITreeSnapshot {
        lock.lock()
        counter += 1
        let read = counter
        lock.unlock()

        var queue: [Pending] = [Pending(element: root, path: [], depth: 0)]
        var head = 0
        var visited: [(path: [Int], depth: Int, element: AnyObject, info: UIElementInfo, children: Int)] = []
        var byDepth = 0
        var byCount = 0
        while head < queue.count {
            let item = queue[head]
            head += 1
            if visited.count >= limits.maxNodes {
                byCount += 1
                continue
            }
            guard let info = access.info(of: item.element) else { continue }
            let children = access.children(of: item.element)
            visited.append((item.path, item.depth, item.element, info, children.count))
            if item.depth + 1 > limits.maxDepth {
                byDepth += children.count
                continue
            }
            for (i, child) in children.enumerated() {
                // Enough queued to fill the budget: the rest is only counted (a list of 10 000 rows stays cheap).
                if visited.count + (queue.count - head) >= limits.maxNodes {
                    byCount += children.count - i
                    break
                }
                queue.append(Pending(element: child, path: item.path + [i], depth: item.depth + 1))
            }
        }

        // Tree order: parents first, siblings in their order.
        let ordered = visited.sorted { $0.path.lexicographicallyPrecedes($1.path) }
        var nodes: [UITreeNode] = []
        var elements: [Int: (element: AnyObject, role: String, title: String?)] = [:]
        let cut = limits.maxTextLength
        for v in ordered where keep(v.info) {
            let n = nodes.count + 1
            let info = v.info
            nodes.append(UITreeNode(id: "t\(read).\(n)", depth: v.depth, role: UITreeText.clip(info.role, 60) ?? "AXUnknown",
                                    subrole: UITreeText.clip(info.subrole, 60), title: UITreeText.clip(info.title, cut),
                                    value: info.isSecure ? nil : UITreeText.clip(info.value, cut),
                                    label: UITreeText.clip(info.label, cut), frame: info.frame, enabled: info.enabled,
                                    focused: info.focused, secure: info.isSecure, childCount: v.children))
            elements[n] = (v.element, info.role, info.title)
        }
        lock.lock()
        kept.append((read, elements))
        if kept.count > UITreeReader.keptReads { kept.removeFirst(kept.count - UITreeReader.keptReads) }
        lock.unlock()
        return UITreeSnapshot(read: read, app: app, scope: scope, nodes: nodes, leftOutByDepth: byDepth, leftOutByCount: byCount,
                              limits: limits)
    }

    /// Why an id cannot be used, as text for the model.
    public enum Lookup {
        case element(AnyObject, UIElementInfo)
        case problem(String)
    }

    /// The live element behind an id of a recent read, only when it still has the role and title it had then.
    public func element(id raw: String) -> Lookup {
        let id = raw.trimmingCharacters(in: .whitespaces)
        let parts = id.split(separator: ".")
        guard parts.count == 2, parts[0].hasPrefix("t"), let read = Int(parts[0].dropFirst()), let n = Int(parts[1]) else {
            return .problem("id must look like t3.12 (an id from computer_ui_tree or computer_find_element)")
        }
        lock.lock()
        let entry = kept.first { $0.read == read }?.elements[n]
        let known = kept.contains { $0.read == read }
        lock.unlock()
        guard known else { return .problem("id \(id.prefix(20)) is from an older read; read the tree again") }
        guard let e = entry else { return .problem("there is no element \(id.prefix(20)) in that read") }
        guard let live = access.info(of: e.element) else { return .problem("element \(id.prefix(20)) is gone; read the tree again") }
        guard live.role == e.role, live.title == e.title else {
            return .problem("element \(id.prefix(20)) changed since it was read; read the tree again")
        }
        return .element(e.element, live)
    }

    public func press(_ element: AnyObject) -> Bool { access.press(element) }
}

extension UITreeSnapshot {
    /// The answer of `computer_ui_tree` / `computer_find_element` (details of the outcome).
    public func details(scanned: Int? = nil) -> [String: Any] {
        var o: [String: JSONValue] = [
            "app": app.json, "scope": .string(scope.rawValue), "read": .int(read),
            "nodes": .array(nodes.map { $0.json }), "count": .int(nodes.count),
            "truncated": .bool(truncated),
            "limits": .object(["maxDepth": .int(limits.maxDepth), "maxNodes": .int(limits.maxNodes),
                               "maxTextLength": .int(limits.maxTextLength)]),
        ]
        if truncated {
            o["left_out"] = .object(["by_depth": .int(leftOutByDepth), "by_count": .int(leftOutByCount)])
        }
        if let s = scanned { o["scanned"] = .int(s); o.removeValue(forKey: "limits") }
        return (JSONValue.object(o).jsonObject as? [String: Any]) ?? [:]
    }
}
