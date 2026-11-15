import Foundation

// NACHO-149: the runner of the data gadgets (System Monitor, Disk Map, Clipboard History, File Shelf, Capture Float).
// The Mac side (`AppDataGadgetHost` in the app target) answers the small `DataGadgetHost` questions on the main thread;
// everything the model reads (rows, limits, refusals, hints) is decided here, so it is tested with a fake host.
// Nothing here logs a content value (clipboard text, an image, a file, a screen).
//
// Content to Nacho: a connector result is text only (nacho-server `call_connector` turns `result` into a string), so
// files and pictures go to the chat as an attachment of the user's next message (`PetHandoff`), never in the result.

/// An argument check: the value, or the `ok:false` answer (like `Result`, without making the outcome an `Error`).
public enum Checked<T> {
    case success(T)
    case failure(PetCommandOutcome)
}

/// One row of the monitor tool: current numbers, nil when the Mac does not report them.
public struct MonitorStats: Equatable {
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    /// macOS memory pressure, 0…100.
    public var memoryPressurePercent: Double?
    public var swapUsedBytes: UInt64?
    public var networkDownBytesPerSecond: Double?
    public var networkUpBytesPerSecond: Double?
    public var diskUsedPercent: Double?
    public var batteryPercent: Double?
    public var batteryCharging: Bool?
    public var onPowerAdapter: Bool?
    public var cpuTemperatureCelsius: Double?
    public var gpuTemperatureCelsius: Double?
    public var loadAverage: [Double]
    /// Busiest apps, already sampled by the monitor (empty when its CPU/memory panel is closed).
    public var topProcesses: [ProcessGroupUsage]

    public init(cpuPercent: Double? = nil, memoryPercent: Double? = nil, memoryUsedBytes: UInt64? = nil, memoryTotalBytes: UInt64? = nil,
                memoryPressurePercent: Double? = nil, swapUsedBytes: UInt64? = nil, networkDownBytesPerSecond: Double? = nil,
                networkUpBytesPerSecond: Double? = nil, diskUsedPercent: Double? = nil, batteryPercent: Double? = nil,
                batteryCharging: Bool? = nil, onPowerAdapter: Bool? = nil, cpuTemperatureCelsius: Double? = nil,
                gpuTemperatureCelsius: Double? = nil, loadAverage: [Double] = [], topProcesses: [ProcessGroupUsage] = []) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.memoryPressurePercent = memoryPressurePercent
        self.swapUsedBytes = swapUsedBytes
        self.networkDownBytesPerSecond = networkDownBytesPerSecond
        self.networkUpBytesPerSecond = networkUpBytesPerSecond
        self.diskUsedPercent = diskUsedPercent
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.onPowerAdapter = onPowerAdapter
        self.cpuTemperatureCelsius = cpuTemperatureCelsius
        self.gpuTemperatureCelsius = gpuTemperatureCelsius
        self.loadAverage = loadAverage
        self.topProcesses = topProcesses
    }
}

/// What Disk Map knows right now.
public enum DiskMapState {
    /// No scan in memory (never scanned, or dropped a while after its window closed).
    case empty
    case scanning(path: String)
    case ready(root: DiskNode, scannedAt: Date)
}

/// A file shelf row as the tools show it (no content).
public struct ShelfRow: Equatable {
    public var id: UUID
    public var name: String
    public var kind: ShelfItemKind
    /// File size on disk (files, images) or characters (snippets, links); nil when the file is gone.
    public var size: Int64?

    public init(id: UUID, name: String, kind: ShelfItemKind, size: Int64?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
    }

    /// `fileSize` reads the size of a file (nil when it cannot). Snippets and links get a plain name: their shelf
    /// title is the first line of the text or the address, which is content.
    public init(_ item: ShelfItem, fileSize: (URL) -> Int64?) {
        switch item.kind {
        case .file, .image:
            self.init(id: item.id, name: item.title, kind: item.kind, size: item.fileURL.flatMap(fileSize))
        case .text:
            self.init(id: item.id, name: "text snippet", kind: .text, size: Int64((item.text ?? "").count))
        case .link:
            self.init(id: item.id, name: "web link", kind: .link, size: Int64((item.text ?? "").count))
        }
    }
}

public enum CaptureAskMode: String, CaseIterable {
    /// The user drags over an area (or picks a window).
    case area
    /// The whole screen under the pointer.
    case screen
}

/// How a capture for Nacho ended.
public enum CaptureAskResult: Equatable {
    /// The picture is on the user's next chat message.
    case attached
    case cancelled
    /// Korean reason (capture failed, Nacho could not take the file …).
    case failed(String)
}

/// The Mac side of the data gadgets. Every call is made on the main thread.
public protocol DataGadgetHost: AnyObject {
    func monitorStats() -> MonitorStats?

    func diskState() -> DiskMapState
    /// The user's home folder (scans stay inside it).
    var homeDirectory: String { get }
    func isDirectory(_ path: String) -> Bool
    /// Opens Disk Map and scans `path`; false when Disk Map cannot (not running).
    func diskStartScan(path: String) -> Bool

    /// Newest first, pins first — the order of the clipboard panel.
    func clipboardItems() -> [ClipboardItem]
    /// Copies the item again (it becomes the newest). false when it is gone.
    func clipboardCopyAgain(id: UUID) -> Bool
    /// Clears the history except pins; how many items went.
    func clipboardClearUnpinned() -> Int

    func shelfRows() -> [ShelfRow]
    /// Puts the item on the user's next chat message; a Korean refusal, or nil.
    func shelfHandToNacho(id: UUID) -> String?
    /// Takes the item off the shelf (the original file stays; the shelf can undo it). false when it is gone.
    func shelfForget(id: UUID) -> Bool
    /// Empties the shelf; how many items went.
    func shelfClear() -> Int

    /// Captures and attaches the picture to the user's next chat message. `done` once, on the main thread.
    func captureAsk(_ mode: CaptureAskMode, done: @escaping (CaptureAskResult) -> Void)
    /// Pixel sizes of the open pinned captures, front to back.
    func pinnedCaptures() -> [(width: Int, height: Int)]
    /// Closes every pinned capture; how many closed.
    func captureCloseAll() -> Int
}

/// Runs the tools of the five data gadgets. Migrated tools (`shelf_clear`, which still has its old `combo_clear_shelf`
/// path) go to `fallback` when one is given, so the MCP exit keeps the old executor.
public final class DataGadgetRunner: GadgetToolRunning {
    public static let gadgets: [GadgetID] = [.monitor, .disk, .clipboard, .shelf, .capture]

    /// Rows of a list result at most (clipboard history keeps 100 by default; disk top N).
    public static let maxIndex = 200
    public static let maxDiskItems = 50
    public static let defaultDiskItems = 10
    /// Nodes looked at for the disk top list (a scan of a full disk keeps far fewer).
    public static let maxDiskNodesWalked = 300_000
    /// A read of clipboard text is cut here (and says so).
    public static let maxReadCharacters = 4000
    /// An area capture waits this long for the user's drag before answering (nacho-server waits 60 s for a connector).
    public static let areaAnswerSeconds: TimeInterval = 45

    /// Held strongly: the app's host keeps only weak references to the modules.
    private let host: DataGadgetHost
    private let fallback: GadgetToolRunning?
    private let onMain: (@escaping () -> Void) -> Void
    private let after: (TimeInterval, @escaping () -> Void) -> Void
    private let now: () -> Date

    public init(host: DataGadgetHost, fallback: GadgetToolRunning? = nil,
                onMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
                after: @escaping (TimeInterval, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) },
                now: @escaping () -> Date = Date.init) {
        self.host = host
        self.fallback = fallback
        self.onMain = onMain
        self.after = after
        self.now = now
    }

    public func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        if tool.legacyConnectorName != nil, let f = fallback { return f.run(tool, arguments: arguments, done: done) }
        onMain { [weak self] in
            guard let self = self else { return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing")) }
            self.runOnMain(tool, arguments, self.host, done)
        }
    }

    private func runOnMain(_ tool: GadgetTool, _ args: [String: JSONValue], _ host: DataGadgetHost,
                           _ done: @escaping (PetCommandOutcome) -> Void) {
        func check(_ allowed: Set<String>) -> PetCommandOutcome? { DataGadgetRunner.unknownFields(args, allowed) }
        switch (tool.gadget, tool.action) {
        case (.monitor, "stats"):
            if let bad = check([]) { return done(bad) }
            done(DataGadgetRunner.monitorOutcome(host.monitorStats()))

        case (.disk, "top_items"):
            if let bad = check(["count", "kind"]) { return done(bad) }
            let count: Int
            switch DataGadgetRunner.integer(args["count"], "count", 1...DataGadgetRunner.maxDiskItems, default: DataGadgetRunner.defaultDiskItems) {
            case let .failure(p): return done(p)
            case let .success(n): count = n
            }
            let kind: DiskTopKind
            switch DataGadgetRunner.choice(args["kind"], "kind", default: DiskTopKind.both) {
            case let .failure(p): return done(p)
            case let .success(k): kind = k
            }
            done(DataGadgetRunner.diskTopOutcome(host.diskState(), count: count, kind: kind, now: now()))
        case (.disk, "scan"):
            if let bad = check(["path"]) { return done(bad) }
            let raw: String?
            switch args["path"] {
            case nil, .null?: raw = nil
            case let .string(s)?: raw = s
            default: return done(DataGadgetRunner.badParams("path must be a string"))
            }
            switch DataGadgetRunner.scanPath(raw, home: host.homeDirectory, isDirectory: host.isDirectory) {
            case let .failure(p): return done(p)
            case let .success(path):
                guard host.diskStartScan(path: path) else {
                    return done(PetCommandOutcome(ok: false, message: "Disk Map could not start a scan."))
                }
                done(PetCommandOutcome(ok: true, message: "Disk Map started scanning \(path). It can take a few minutes; call disk_top_items afterwards. "
                                                    + "Nothing is deleted or moved.",
                                       details: ["path": path, "scan": "started"]))
            }

        case (.clipboard, "list"):
            if let bad = check([]) { return done(bad) }
            done(DataGadgetRunner.clipboardListOutcome(host.clipboardItems()))
        case (.clipboard, "get_item"):
            if let bad = check(["index", "id"]) { return done(bad) }
            switch DataGadgetRunner.pick(args, in: host.clipboardItems(), id: { $0.id }, what: "clipboard item") {
            case let .failure(p): done(p)
            case let .success((index, item)): done(DataGadgetRunner.clipboardContentOutcome(index, item))
            }
        case (.clipboard, "copy_again"):
            if let bad = check(["index", "id"]) { return done(bad) }
            switch DataGadgetRunner.pick(args, in: host.clipboardItems(), id: { $0.id }, what: "clipboard item") {
            case let .failure(p): done(p)
            case let .success((index, item)):
                done(host.clipboardCopyAgain(id: item.id)
                    ? PetCommandOutcome(ok: true, message: "Copied clipboard item \(index) again; it is now on the clipboard and first in the list (the numbers moved).",
                                        details: ["index": index, "kind": item.kind.rawValue])
                    : DataGadgetRunner.gone("clipboard item", index))
            }
        case (.clipboard, "clear"):
            if let bad = check([]) { return done(bad) }
            let n = host.clipboardClearUnpinned()
            done(PetCommandOutcome(ok: true, message: "Cleared \(n) clipboard item\(n == 1 ? "" : "s"). Pinned items stay. This cannot be undone.",
                                   details: ["cleared": n]))

        case (.shelf, "list"):
            if let bad = check([]) { return done(bad) }
            done(DataGadgetRunner.shelfListOutcome(host.shelfRows()))
        case (.shelf, "give"):
            if let bad = check(["index", "id"]) { return done(bad) }
            switch DataGadgetRunner.pick(args, in: host.shelfRows(), id: { $0.id }, what: "shelf item") {
            case let .failure(p): done(p)
            case let .success((index, row)):
                if let refusal = host.shelfHandToNacho(id: row.id) {
                    return done(PetCommandOutcome(ok: false, message: "Shelf item \(index) was not attached.",
                                                  details: ["reason": "not_attached", "guide_ko": refusal]))
                }
                done(DataGadgetRunner.attached("shelf item \(index) (\(row.kind.rawValue))"))
            }
        case (.shelf, "forget"):
            if let bad = check(["index", "id"]) { return done(bad) }
            switch DataGadgetRunner.pick(args, in: host.shelfRows(), id: { $0.id }, what: "shelf item") {
            case let .failure(p): done(p)
            case let .success((index, row)):
                done(host.shelfForget(id: row.id)
                    ? PetCommandOutcome(ok: true, message: "Took shelf item \(index) off the shelf. The original file is untouched and the shelf can undo it (the numbers moved).",
                                        details: ["index": index])
                    : DataGadgetRunner.gone("shelf item", index))
            }
        case (.shelf, "clear"):
            if let bad = check([]) { return done(bad) }
            let n = host.shelfClear()
            done(PetCommandOutcome(ok: true, message: n == 0 ? "The file shelf was already empty."
                                       : "Emptied the file shelf (\(n) item\(n == 1 ? "" : "s")). Original files are untouched.",
                                   details: ["cleared": n]))

        case (.capture, "ask"):
            if let bad = check(["mode"]) { return done(bad) }
            switch DataGadgetRunner.choice(args["mode"], "mode", default: CaptureAskMode.area) {
            case let .failure(p): done(p)
            case let .success(mode): captureAsk(mode, host, done)
            }
        case (.capture, "list_pinned"):
            if let bad = check([]) { return done(bad) }
            let pins = host.pinnedCaptures()
            let items: [[String: Any]] = pins.enumerated().map { ["index": $0.offset + 1, "width": $0.element.width, "height": $0.element.height] }
            done(PetCommandOutcome(ok: true, message: pins.isEmpty ? "No pinned captures are open." : "\(pins.count) pinned capture\(pins.count == 1 ? "" : "s") open (sizes only, no pictures).",
                                   details: ["items": items]))
        case (.capture, "close_all"):
            if let bad = check([]) { return done(bad) }
            let n = host.captureCloseAll()
            done(PetCommandOutcome(ok: true, message: n == 0 ? "No pinned captures were open." : "Closed \(n) pinned capture\(n == 1 ? "" : "s").",
                                   details: ["closed": n]))

        default:
            done(.unavailable(tool))
        }
    }

    /// Screen: answers when the picture is attached. Area: the user may still be dragging; after `areaAnswerSeconds`
    /// the answer says so and the picture is attached when they finish.
    private func captureAsk(_ mode: CaptureAskMode, _ host: DataGadgetHost, _ done: @escaping (PetCommandOutcome) -> Void) {
        let lock = NSLock()
        var answered = false
        func answer(_ o: PetCommandOutcome) {
            lock.lock(); let first = !answered; answered = true; lock.unlock()
            if first { done(o) }
        }
        host.captureAsk(mode) { result in answer(DataGadgetRunner.captureOutcome(result, mode: mode)) }
        if mode == .area {
            after(DataGadgetRunner.areaAnswerSeconds) {
                answer(PetCommandOutcome(ok: true, message: "The user is still choosing the area. When they finish, the capture is attached to their next chat message; "
                                             + "if they cancel, nothing is attached. Tell the user to drag over the area and press send.",
                                         details: ["attached": false, "pending": true, "delivery": "chat_attachment"]))
            }
        }
    }

    // MARK: arguments (closed lists)

    static func badParams(_ text: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: false, message: "bad parameters: \(text)", details: ["reason": "bad_parameters"])
    }

    static func unknownFields(_ args: [String: JSONValue], _ allowed: Set<String>) -> PetCommandOutcome? {
        let extra = Set(args.keys).subtracting(allowed)
        guard !extra.isEmpty else { return nil }
        return badParams("unknown field \(extra.sorted().map { String($0.prefix(40)) }.joined(separator: ", "))")
    }

    static func integer(_ v: JSONValue?, _ name: String, _ range: ClosedRange<Int>, default d: Int? = nil) -> Checked<Int> {
        let n: Int
        switch v {
        case nil, .null?:
            guard let d = d else { return .failure(badParams("\(name) is required (\(range.lowerBound)…\(range.upperBound))")) }
            return .success(d)
        case let .int(i)?: n = i
        case let .double(x)? where x.rounded() == x && abs(x) < 1e9: n = Int(x)
        default: return .failure(badParams("\(name) must be a whole number \(range.lowerBound)…\(range.upperBound)"))
        }
        guard range.contains(n) else { return .failure(badParams("\(name) must be \(range.lowerBound)…\(range.upperBound)")) }
        return .success(n)
    }

    static func choice<T: RawRepresentable & CaseIterable>(_ v: JSONValue?, _ name: String, default d: T) -> Checked<T>
        where T.RawValue == String {
        let all = T.allCases.map { $0.rawValue }.joined(separator: ", ")
        switch v {
        case nil, .null?: return .success(d)
        case let .string(s)?:
            guard let c = T(rawValue: s) else { return .failure(badParams("\(name) must be one of \(all)")) }
            return .success(c)
        default: return .failure(badParams("\(name) must be one of \(all)"))
        }
    }

    /// Short id of a row: the first 8 hex digits of its UUID. A call may pass it with the number to make sure the list
    /// did not move in between (content tools are approved for one item).
    public static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    /// `index` (1-based, required) and optional `id` (from the list) → the row.
    static func pick<T>(_ args: [String: JSONValue], in rows: [T], id: (T) -> UUID, what: String) -> Checked<(Int, T)> {
        let index: Int
        switch integer(args["index"], "index", 1...maxIndex) {
        case let .failure(p): return .failure(p)
        case let .success(n): index = n
        }
        var wanted: String?
        switch args["id"] {
        case nil, .null?: wanted = nil
        case let .string(s)?:
            guard s.count == 8, s.allSatisfy({ $0.isHexDigit }) else { return .failure(badParams("id must be the 8-character id from the list")) }
            wanted = s.lowercased()
        default: return .failure(badParams("id must be the 8-character id from the list"))
        }
        guard index <= rows.count else { return .failure(outOfRange(what, index, rows.count)) }
        let row = rows[index - 1]
        if let w = wanted, shortID(id(row)) != w {
            return .failure(PetCommandOutcome(ok: false, message: "The list changed: \(what) \(index) is not the one with id \(w). List again and use the new number.",
                                              details: ["reason": "list_changed"]))
        }
        return .success((index, row))
    }

    static func outOfRange(_ what: String, _ index: Int, _ count: Int) -> PetCommandOutcome {
        PetCommandOutcome(ok: false,
                          message: count == 0 ? "There is no \(what) \(index): the list is empty."
                              : "There is no \(what) \(index); the list has \(count). List again to see the current numbers.",
                          details: ["reason": "out_of_range", "count": count])
    }

    static func gone(_ what: String, _ index: Int) -> PetCommandOutcome {
        PetCommandOutcome(ok: false, message: "\(what.capitalized) \(index) is gone. List again.", details: ["reason": "out_of_range"])
    }

    /// The folder a scan may start from: inside the home folder (`~`, `~/…` or an absolute path), an existing folder.
    /// nil = the home folder itself.
    public static func scanPath(_ raw: String?, home: String, isDirectory: (String) -> Bool) -> Checked<String> {
        let homePath = (home as NSString).standardizingPath
        var p = (raw ?? "~").trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "~" }
        guard p.count <= 1024, !p.contains("\0") else { return .failure(badParams("path is too long")) }
        if p == "~" { p = homePath } else if p.hasPrefix("~/") { p = homePath + String(p.dropFirst(1)) }
        guard p.hasPrefix("/") else { return .failure(badParams("path must be ~, ~/… or an absolute path inside the home folder")) }
        let standard = (p as NSString).standardizingPath
        guard standard == homePath || standard.hasPrefix(homePath + "/") else {
            return .failure(PetCommandOutcome(ok: false, message: "Disk Map scans only folders inside the home folder (\(homePath)).",
                                              details: ["reason": "outside_home"]))
        }
        guard isDirectory(standard) else {
            return .failure(PetCommandOutcome(ok: false, message: "There is no folder at \(standard).", details: ["reason": "not_a_folder"]))
        }
        return .success(standard)
    }

    // MARK: results

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func rounded(_ v: Double?) -> Any { v.map { ($0 * 10).rounded() / 10 } ?? NSNull() }
    static func value<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

    public static func monitorOutcome(_ stats: MonitorStats?) -> PetCommandOutcome {
        guard let s = stats else {
            return PetCommandOutcome(ok: false, message: "System Monitor has no reading yet; try again in a few seconds.",
                                     details: ["reason": "no_reading"])
        }
        var d: [String: Any] = [
            "cpu_percent": rounded(s.cpuPercent), "memory_percent": rounded(s.memoryPercent),
            "memory_used_bytes": value(s.memoryUsedBytes), "memory_total_bytes": value(s.memoryTotalBytes),
            "memory_pressure_percent": rounded(s.memoryPressurePercent), "swap_used_bytes": value(s.swapUsedBytes),
            "network_down_bytes_per_second": rounded(s.networkDownBytesPerSecond),
            "network_up_bytes_per_second": rounded(s.networkUpBytesPerSecond), "disk_used_percent": rounded(s.diskUsedPercent),
            "battery_percent": rounded(s.batteryPercent), "battery_charging": value(s.batteryCharging),
            "on_power_adapter": value(s.onPowerAdapter),
            "cpu_temperature_celsius": rounded(s.cpuTemperatureCelsius), "gpu_temperature_celsius": rounded(s.gpuTemperatureCelsius),
            "load_average": s.loadAverage.prefix(3).map { ($0 * 100).rounded() / 100 },
        ]
        if !s.topProcesses.isEmpty {
            d["top_apps"] = s.topProcesses.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5).map {
                ["name": String($0.name.prefix(80)), "cpu_percent": ($0.cpuPercent * 10).rounded() / 10, "memory_bytes": $0.memory] as [String: Any]
            }
        }
        var parts: [String] = []
        if let c = s.cpuPercent { parts.append("CPU \(Int(c.rounded()))%") }
        if let m = s.memoryPercent { parts.append("memory \(Int(m.rounded()))%") }
        if let p = s.memoryPressurePercent { parts.append("memory pressure \(Int(p.rounded()))%") }
        if let t = s.cpuTemperatureCelsius { parts.append("CPU \(Int(t.rounded())) °C") }
        if let b = s.batteryPercent { parts.append("battery \(Int(b.rounded()))%\(s.batteryCharging == true ? " (charging)" : "")") }
        return PetCommandOutcome(ok: true, message: parts.isEmpty ? "System Monitor is running but has no numbers yet."
                                                                   : "Right now: " + parts.joined(separator: ", ") + ".",
                                 details: d)
    }

    public enum DiskTopKind: String, CaseIterable {
        case both, folders, files
    }

    /// The largest items of the last scan. Folders: two levels below the scanned folder (a deeper folder is inside
    /// one of them). Files: anywhere the scan kept. Walks at most `maxDiskNodesWalked` nodes.
    public static func diskTop(_ root: DiskNode, count: Int, kind: DiskTopKind) -> [DiskNode] {
        var folders: [DiskNode] = []
        var files: [DiskNode] = []
        var stack: [(DiskNode, Int)] = [(root, 0)]
        var walked = 0
        while walked < maxDiskNodesWalked, let entry = stack.popLast() {
            let (node, depth) = entry
            walked += 1
            for child in node.children where child.isItem {
                if child.kind == .file { files.append(child) } else {
                    if depth < 2 { folders.append(child) }
                    stack.append((child, depth + 1))
                }
            }
        }
        let n = min(count, maxDiskItems)
        func top(_ list: [DiskNode]) -> [DiskNode] { Array(list.sorted { $0.size > $1.size }.prefix(n)) }
        switch kind {
        case .folders: return top(folders)
        case .files: return top(files)
        case .both: return Array((top(folders) + top(files)).sorted { $0.size > $1.size }.prefix(n))
        }
    }

    public static func diskTopOutcome(_ state: DiskMapState, count: Int, kind: DiskTopKind, now: Date) -> PetCommandOutcome {
        switch state {
        case .empty:
            return PetCommandOutcome(ok: false, message: "Disk Map has no scan in memory. Start one with disk_scan (the home folder by default), then ask again in a few minutes.",
                                     details: ["reason": "no_scan"])
        case let .scanning(path):
            return PetCommandOutcome(ok: false, message: "Disk Map is still scanning \(path). Ask again in a minute.",
                                     details: ["reason": "scanning", "path": path])
        case let .ready(root, at):
            let shown = diskTop(root, count: count, kind: kind)
            let items: [[String: Any]] = shown.enumerated().map { n, e in
                var row: [String: Any] = ["rank": n + 1, "name": String(e.name.prefix(200)), "path": String(e.path.prefix(1024)),
                                          "kind": e.isFolder ? "folder" : "file", "bytes": e.size]
                if e.modified > 0 { row["modified_at"] = iso(Date(timeIntervalSince1970: e.modified)) }
                return row
            }
            let minutes = max(0, Int(now.timeIntervalSince(at) / 60))
            return PetCommandOutcome(ok: true,
                                     message: "Top \(shown.count) by size from the scan of \(root.path), \(minutes) minute\(minutes == 1 ? "" : "s") ago. "
                                         + "Read only: nothing was deleted or moved.",
                                     details: ["items": items, "scanned_at": iso(at), "scanned_path": root.path, "scanned_bytes": root.size])
        }
    }

    /// Length of a clipboard item without its content: characters, files or bytes.
    static func clipboardLength(_ item: ClipboardItem) -> (Int, String) {
        switch item.kind {
        case .text, .link: return (item.text.count, "characters")
        case .files: return (item.text.split(separator: "\n").count, "files")
        case .image: return (item.imagePNG?.count ?? 0, "bytes")
        }
    }

    /// Numbers, kinds, lengths and times only: no previews, no source app.
    public static func clipboardListOutcome(_ items: [ClipboardItem]) -> PetCommandOutcome {
        let shown = items.prefix(maxIndex)
        let rows: [[String: Any]] = shown.enumerated().map { n, item in
            let (length, unit) = clipboardLength(item)
            return ["index": n + 1, "id": shortID(item.id), "kind": item.kind.rawValue, "length": length, "unit": unit,
                    "copied_at": iso(item.date), "pinned": item.pinned]
        }
        return PetCommandOutcome(ok: true,
                                 message: items.isEmpty ? "The clipboard history is empty."
                                     : "\(items.count) clipboard item\(items.count == 1 ? "" : "s"), pins first then newest first. "
                                         + "The list has no previews; read one by number with clipboard_get_item.",
                                 details: ["items": rows])
    }

    public static func clipboardContentOutcome(_ index: Int, _ item: ClipboardItem) -> PetCommandOutcome {
        switch item.kind {
        case .image:
            return PetCommandOutcome(ok: false,
                                     message: "Clipboard item \(index) is a picture; it cannot be read as text. Ask the user to drop it on Nacho or put it on the File Shelf and hand it over with shelf_give.",
                                     details: ["reason": "not_text", "kind": "image"])
        case .text, .link, .files:
            let text = item.text
            let truncated = text.count > maxReadCharacters
            let shown = truncated ? String(text.prefix(maxReadCharacters)) : text
            return PetCommandOutcome(ok: true,
                                     message: truncated ? "Clipboard item \(index), cut at \(maxReadCharacters) of \(text.count) characters." : "Clipboard item \(index).",
                                     details: ["index": index, "kind": item.kind.rawValue, "text": shown, "length": text.count, "truncated": truncated])
        }
    }

    public static func shelfListOutcome(_ rows: [ShelfRow]) -> PetCommandOutcome {
        let shown = rows.prefix(maxIndex)
        let items: [[String: Any]] = shown.enumerated().map { n, r in
            var row: [String: Any] = ["index": n + 1, "id": shortID(r.id), "name": String(r.name.prefix(200)), "kind": r.kind.rawValue]
            switch r.kind {
            case .file, .image: row["bytes"] = value(r.size)
            case .text, .link: row["characters"] = value(r.size)
            }
            return row
        }
        return PetCommandOutcome(ok: true,
                                 message: rows.isEmpty ? "The file shelf is empty." : "\(rows.count) item\(rows.count == 1 ? "" : "s") on the file shelf (names only, no content).",
                                 details: ["items": items])
    }

    static func attached(_ what: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: true,
                          message: "Attached \(what) to the user's next chat message. It goes to you when the user presses send; tell them to press send.",
                          details: ["attached": true, "delivery": "chat_attachment"])
    }

    static func captureOutcome(_ result: CaptureAskResult, mode: CaptureAskMode) -> PetCommandOutcome {
        switch result {
        case .attached: return attached(mode == .area ? "the captured area" : "a capture of the screen")
        case .cancelled:
            return PetCommandOutcome(ok: false, message: "The user cancelled the capture; nothing was attached.", details: ["reason": "cancelled"])
        case let .failed(why):
            return PetCommandOutcome(ok: false, message: "The capture was not attached.", details: ["reason": "not_attached", "guide_ko": why])
        }
    }
}
