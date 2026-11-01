import Foundation

/// One thing on the disk map. A scan keeps every folder big enough to see and the largest files of each folder; what is
/// too small to draw is summed up, so a whole disk fits in memory (a Mac easily holds ten million files).
public final class DiskNode {
    public enum Kind: Equatable {
        case folder, file
        /// The small items of a folder, summed up.
        case smaller
        /// Used on the disk but not seen by the scan (only ever a slice of the top level).
        case hidden
        /// Free space (only ever a slice of the top level).
        case free
    }

    public let name: String
    public let kind: Kind
    /// Absolute path of the folder a scan started from; nil everywhere else.
    public let basePath: String?
    /// Bytes on disk, everything inside included.
    public internal(set) var size: Int64
    /// Files inside (1 for a file).
    public internal(set) var fileCount: Int
    /// The newest change anywhere inside, seconds since 1970 (0: unknown).
    public internal(set) var modified: Double
    /// Largest first; `.smaller` always last.
    public internal(set) var children: [DiskNode] = []
    public internal(set) weak var parent: DiskNode?
    /// Its contents were dropped after the scan to save memory; opening the folder scans it again.
    public internal(set) var isCollapsed = false
    /// macOS did not let the scan read this folder.
    public internal(set) var isUnreadable = false
    /// Subfolders still being scanned (only touched under the scanner's lock).
    var pending = 0

    public init(name: String, kind: Kind, size: Int64 = 0, fileCount: Int = 0, modified: Double = 0, basePath: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.basePath = basePath
    }

    public var isFolder: Bool { kind == .folder }

    /// A real file or folder, as opposed to a sum or a slice of the disk.
    public var isItem: Bool { kind == .folder || kind == .file }

    public var root: DiskNode {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    /// From the top of the tree down to this node.
    public var ancestry: [DiskNode] {
        var list: [DiskNode] = [self]
        while let parent = list[0].parent { list.insert(parent, at: 0) }
        return list
    }

    /// The node's place on the disk; a sum stands for the folder it is in.
    public var path: String {
        if let base = basePath { return base }
        guard let parent = parent else { return name }
        guard isItem else { return parent.path }
        let folder = parent.path
        return folder.hasSuffix("/") ? folder + name : folder + "/" + name
    }

    public func isInside(_ other: DiskNode) -> Bool {
        var node = parent
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    /// The node at `path` below this one, as far as the tree goes.
    public func descendant(at target: String) -> DiskNode? {
        let own = path
        if target == own { return self }
        let prefix = own.hasSuffix("/") ? own : own + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let first = target.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        return children.first { $0.isItem && $0.name == first }?.descendant(at: target)
    }

    public func add(_ child: DiskNode) {
        child.parent = self
        children.append(child)
    }

    /// Sorts the children and sums up what is too small to matter here: the first few always stay, after that only
    /// items of at least `share` of the folder, `limit` at most. Nothing is lost: the sum carries the rest.
    func trim(keep: Int = DiskNode.alwaysKept, limit: Int = DiskNode.mostKept, share: Double = DiskNode.smallestShare) {
        children.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        if children.count > keep {
            let smallest = Int64(Double(size) * share)
            var kept = Array(children.prefix(keep))
            var summedBytes: Int64 = 0, summedItems = 0, newest = 0.0
            for child in children.dropFirst(keep) {
                if kept.count < limit, child.size >= smallest, child.size > 0 {
                    kept.append(child)
                } else {
                    summedBytes += child.size
                    summedItems += max(1, child.fileCount)
                    newest = max(newest, child.modified)
                }
            }
            children = kept
            if summedBytes > 0 || summedItems > 0 { addSmaller(bytes: summedBytes, items: summedItems, modified: newest) }
        }
        if let index = children.firstIndex(where: { $0.kind == .smaller }), index != children.count - 1 {
            children.append(children.remove(at: index))
        }
    }

    /// Adds the sum of the small items, or adds to the one already there.
    func addSmaller(bytes: Int64, items: Int, modified: Double) {
        if let index = children.firstIndex(where: { $0.kind == .smaller }) {
            let old = children.remove(at: index)
            add(DiskNode(name: DiskNode.smallerName(old.fileCount + items), kind: .smaller, size: old.size + bytes,
                         fileCount: old.fileCount + items, modified: max(old.modified, modified)))
        } else {
            add(DiskNode(name: DiskNode.smallerName(items), kind: .smaller, size: bytes, fileCount: items, modified: modified))
        }
    }

    static func smallerName(_ items: Int) -> String {
        items == 1 ? "1 smaller item" : "\(DiskFormat.count(items)) smaller items"
    }

    static let alwaysKept = 8
    static let mostKept = 64
    /// About half a degree of a wheel: anything less cannot be seen in this folder's own view.
    static let smallestShare = 1.0 / 800

    /// Takes this node out of the tree; the folders above shrink by what it held.
    public func detach() {
        guard let parent = parent else { return }
        parent.children.removeAll { $0 === self }
        for folder in parent.ancestry {
            folder.size = max(0, folder.size - size)
            folder.fileCount = max(0, folder.fileCount - fileCount)
        }
        self.parent = nil
    }

    /// Puts what a new scan of this folder found in place of what the tree held.
    public func adopt(contentsOf scan: DiskNode) {
        let sizeChange = scan.size - size, countChange = scan.fileCount - fileCount
        for folder in ancestry.dropLast() {
            folder.size = max(0, folder.size + sizeChange)
            folder.fileCount = max(0, folder.fileCount + countChange)
        }
        size = scan.size
        fileCount = scan.fileCount
        modified = scan.modified
        isCollapsed = false
        isUnreadable = scan.isUnreadable
        children = scan.children
        for child in children { child.parent = self }
    }

    /// Nodes in the tree, for the diagnostics.
    public var nodeCount: Int { children.reduce(1) { $0 + $1.nodeCount } }
}

/// How a disk's space is divided, as the volume reports it.
public struct DiskSpace: Equatable {
    public let total: Int64
    /// Really free right now.
    public let free: Int64
    /// Free plus what macOS would clear by itself when needed (local snapshots, caches, iCloud copies).
    public let available: Int64

    public init(total: Int64, free: Int64, available: Int64) {
        self.total = max(0, total)
        self.free = min(max(0, free), self.total)
        self.available = min(max(self.free, available), self.total)
    }

    public var used: Int64 { total - free }
    public var purgeable: Int64 { available - free }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var freeFraction: Double { total > 0 ? Double(free) / Double(total) : 0 }

    /// Used space a scan did not find: other users' and protected folders, local snapshots, swap, other APFS volumes.
    /// Zero when a scan found more than is used, which happens because clones share their space.
    public func hidden(scanned: Int64) -> Int64 { max(0, used - scanned) }
}

public enum DiskFormat {
    /// Finder's units: "582 GB", "77.1 GB", "1.24 TB", "812 MB", "96 KB".
    public static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 KB" }
        var value = Double(bytes) / 1000
        var unit = 0
        let units = ["KB", "MB", "GB", "TB", "PB"]
        while value >= 999.5 && unit < units.count - 1 { value /= 1000; unit += 1 }
        if value >= 99.5 || unit == 0 { return String(format: "%.0f ", value) + units[unit] }
        if value >= 9.95 { return String(format: "%.1f ", value) + units[unit] }
        return String(format: unit >= 3 ? "%.2f " : "%.1f ", value) + units[unit]
    }

    /// "1,204,331".
    public static func count(_ number: Int) -> String { MonitorFormat.grouped(number) }

    /// "1 file", "2,301 files".
    public static func files(_ number: Int) -> String { number == 1 ? "1 file" : "\(count(number)) files" }

    /// "today", "3 days ago", "5 months ago", "2 years ago"; nil when the date is not known.
    public static func age(_ modified: Double, now: Date) -> String? {
        guard modified > 0 else { return nil }
        let days = Int((now.timeIntervalSince1970 - modified) / 86_400)
        if days < 1 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 60 { return "\(days) days ago" }
        if days < 730 { return "\(days / 30) months ago" }
        return "\(days / 365) years ago"
    }
}

/// How the map colors its blocks.
public enum DiskColoring: String, Codable, CaseIterable {
    /// Each top-level folder has its color, inherited by everything inside.
    case folder
    /// By the last change inside: fresh is green, long untouched is red, so what could go stands out.
    case age

    public var displayName: String {
        switch self {
        case .folder: return "By Folder"
        case .age: return "By Last Change"
        }
    }

    /// 0 for something changed today, 1 for something untouched for two years or more (on a log scale: the difference
    /// between a week and a month matters more than the one between one and two years).
    public static func ageHeat(modified: Double, now: Date) -> Double {
        guard modified > 0 else { return 0.5 }
        let days = max(0, (now.timeIntervalSince1970 - modified) / 86_400)
        return min(1, log(1 + days) / log(731))
    }
}

/// The two pictures of a disk.
public enum DiskMapStyle: String, Codable, CaseIterable {
    case sunburst, blocks

    public var displayName: String {
        switch self {
        case .sunburst: return "Sunburst"
        case .blocks: return "Blocks"
        }
    }
}

/// What may be taken off the disk from the map. Nothing is removed without the user's approval; this says what the
/// approval sheet may offer at all and what it has to warn about.
public enum DiskRemovalVerdict: Equatable {
    case allowed
    /// Allowed, and the sheet says this.
    case caution(String)
    /// Not offered, for this reason.
    case blocked(String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }

    public var cautionText: String? {
        if case .caution(let text) = self { return text }
        return nil
    }
}

public enum DiskRemovalPolicy {
    private static let system = "macOS needs this."
    private static let top = "This is a folder macOS keeps. Open it and remove what is inside instead."

    /// macOS itself: nothing here is offered.
    private static let systemTrees = ["/System", "/bin", "/sbin", "/usr", "/dev", "/private/etc", "/private/var/db",
                                      "/private/var/root", "/private/var/vm", "/private/var/folders", "/Library/Apple"]
    /// Inside `systemTrees`, but the user's own.
    private static let systemTreeExceptions = ["/usr/local"]
    /// Folders that must stay, though what is inside them may go.
    private static let keptFolders = ["/", "/Applications", "/Library", "/Users", "/Volumes", "/private", "/private/var",
                                      "/private/tmp", "/opt", "/usr/local", "/cores", "/Network", "/Applications/Utilities"]
    private static let keptInHome = ["Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures",
                                     "Public", ".Trash"]

    public static func verdict(path: String, home: String) -> DiskRemovalVerdict {
        let path = normalized(path), home = normalized(home)
        func isUnder(_ folder: String) -> Bool { path.hasPrefix(folder == "/" ? "/" : folder + "/") }
        func isAt(_ folder: String) -> Bool { path == folder }

        let usersRoot = home.split(separator: "/").dropLast().reduce("") { $0 + "/" + $1 }
        if keptFolders.contains(path) { return .blocked(top) }
        if isAt(home) { return .blocked("This is your home folder.") }
        if keptInHome.contains(where: { isAt(home + "/" + $0) }) { return .blocked(top) }
        if isAt(usersRoot) { return .blocked(top) }
        if isUnder(usersRoot), !isUnder(home), !isUnder(usersRoot + "/Shared") {
            return .blocked("This is in another account's home folder.")
        }
        let exempt = systemTreeExceptions.contains { isUnder($0) }
        if !exempt, systemTrees.contains(where: { isAt($0) || isUnder($0) }) { return .blocked(system) }

        let name = path.split(separator: "/").last.map(String.init) ?? ""
        let library = home + "/Library"
        for cloud in ["Mobile Documents", "CloudStorage"] where isUnder(library + "/" + cloud) || isAt(library + "/" + cloud) {
            return .caution("This folder syncs. Removing it also removes it from your cloud storage and your other devices.")
        }
        if name.hasSuffix(".photoslibrary") { return .caution("This is a whole photo library.") }
        if name == ".git" { return .caution("This folder holds the project's whole history.") }
        if isUnder(library) { return .caution("Apps keep their settings and data in Library. Removing this can reset or break an app.") }
        if isUnder("/Library") || isUnder("/private") || isUnder("/opt") {
            return .caution("This belongs to the system or to an app installed for every account.")
        }
        if name.hasSuffix(".app") { return .caution("This removes the app. What it saved in Library stays.") }
        return .allowed
    }

    private static func normalized(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

/// Items picked for removal. A folder takes the place of anything picked inside it, so nothing counts twice.
public struct DiskCollection {
    public private(set) var items: [DiskNode] = []

    public init() {}

    public var bytes: Int64 { items.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { items.isEmpty }

    public func contains(_ node: DiskNode) -> Bool {
        items.contains { $0 === node || node.isInside($0) }
    }

    /// False when it is already in the list, itself or through a folder.
    @discardableResult
    public mutating func add(_ node: DiskNode) -> Bool {
        guard node.isItem, !contains(node) else { return false }
        items.removeAll { $0.isInside(node) }
        items.append(node)
        return true
    }

    public mutating func remove(_ node: DiskNode) { items.removeAll { $0 === node } }

    public mutating func removeAll() { items = [] }

    /// Forgets items that left the tree (removed, or replaced by a new scan of a folder).
    public mutating func keep(in root: DiskNode?) {
        items.removeAll { $0.root !== root }
    }
}

/// A made-up disk for the gallery picture and the documentation: nothing from this Mac.
public enum DiskSample {
    private static func file(_ name: String, _ gigabytes: Double, days: Double, now: Date) -> DiskNode {
        DiskNode(name: name, kind: .file, size: Int64(gigabytes * 1e9), fileCount: 1, modified: now.timeIntervalSince1970 - days * 86_400)
    }

    private static func folder(_ name: String, _ items: [DiskNode], basePath: String? = nil) -> DiskNode {
        let node = DiskNode(name: name, kind: .folder, basePath: basePath)
        for item in items {
            node.add(item)
            node.size += item.size
            node.fileCount += item.fileCount
            node.modified = max(node.modified, item.modified)
        }
        node.trim()
        return node
    }

    /// Splits `gigabytes` over `names`, so the sample looks like a real folder without listing every byte.
    private static func spread(_ names: [String], _ gigabytes: Double, days: Double, now: Date) -> [DiskNode] {
        var left = gigabytes
        var items: [DiskNode] = []
        for (index, name) in names.enumerated() {
            let share = index == names.count - 1 ? left : left * 0.42
            left -= share
            items.append(file(name, share, days: days * Double(index + 1), now: now))
        }
        return items
    }

    public static func tree(now: Date = Date()) -> (root: DiskNode, space: DiskSpace) {
        let clips = ["Launch Film.mov", "Interview A.mov", "Interview B.mov", "B-Roll.mov", "Drone.mov", "Trailer.mov"]
        let projects = folder("Projects", [
            folder("studio-site", [folder("node_modules", spread(["webpack", "next", "typescript", "sass", "eslint"], 2.4, days: 12, now: now)),
                                   folder("dist", spread(["assets", "chunks", "maps"], 0.9, days: 3, now: now)),
                                   folder(".git", spread(["objects", "lfs"], 1.4, days: 1, now: now))]),
            folder("mobile-app", [folder("build", spread(["outputs", "intermediates", "tmp"], 6.8, days: 40, now: now)),
                                  folder("Pods", spread(["Firebase", "Realm", "Lottie"], 2.2, days: 90, now: now))]),
            folder("archive-2023", spread(["photoshoot.zip", "client-handoff.zip", "old-site.tar", "renders.zip"], 31, days: 430, now: now)),
        ])
        let movies = folder("Movies", [folder("Final Cut", spread(clips, 86, days: 200, now: now)),
                                       folder("Screen Recordings", spread(["Demo 12.mov", "Demo 11.mov", "Demo 10.mov"], 14, days: 25, now: now))])
        let library = folder("Library", [
            folder("Application Support", [folder("Adobe", spread(["Common", "Lightroom", "Fonts"], 18, days: 30, now: now)),
                                           folder("Steam", spread(["steamapps", "appcache"], 41, days: 300, now: now)),
                                           folder("Slack", spread(["Cache", "Service Worker"], 3.4, days: 1, now: now))]),
            folder("Caches", spread(["com.spotify.client", "Homebrew", "Google", "pip", "Yarn"], 16, days: 2, now: now)),
            folder("Developer", [folder("Xcode", spread(["DerivedData", "iOS DeviceSupport", "Archives"], 38, days: 60, now: now)),
                                 folder("CoreSimulator", spread(["Devices", "Caches"], 22, days: 120, now: now))]),
            folder("Containers", spread(["com.docker.docker", "com.apple.mail", "com.apple.Safari"], 52, days: 6, now: now)),
        ])
        let home = folder("sam", [
            library, movies, projects,
            folder("Downloads", spread(["Installer.dmg", "Dataset.zip", "Backup.tar", "Slides.key", "Photos.zip"], 44, days: 150, now: now)),
            folder("Pictures", [folder("Photos Library.photoslibrary", spread(["originals", "derivatives", "database"], 68, days: 4, now: now))]),
            folder("Music", spread(["Music Library", "Podcasts", "GarageBand"], 19, days: 500, now: now)),
            folder("Documents", spread(["Contracts", "Taxes", "Invoices", "Notes"], 9, days: 18, now: now)),
        ])
        let root = folder("Macintosh HD", [
            folder("Users", [home, folder("Shared", spread(["Adobe", "Pro Tools"], 6, days: 700, now: now))]),
            folder("System", spread(["Library", "Applications", "iOSSupport", "DriverKit"], 28, days: 240, now: now)),
            folder("Applications", spread(["Xcode.app", "Final Cut Pro.app", "Logic Pro.app", "Figma.app", "Slack.app", "Docker.app"], 74, days: 33, now: now)),
            folder("Library", spread(["Application Support", "Developer", "Audio", "Fonts"], 16, days: 80, now: now)),
            folder("private", spread(["var", "tmp"], 12, days: 2, now: now)),
            folder("opt", spread(["homebrew"], 8, days: 9, now: now)),
            folder("usr", spread(["share", "lib", "libexec"], 5, days: 240, now: now)),
        ], basePath: "/")
        // The sample's used space is what the tree holds plus some hidden space.
        let used = root.size + Int64(19e9)
        return (root, DiskSpace(total: Int64(994.7e9), free: Int64(994.7e9) - used, available: Int64(994.7e9) - used + Int64(58e9)))
    }
}
