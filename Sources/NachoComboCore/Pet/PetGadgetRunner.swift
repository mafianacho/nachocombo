import Foundation

// Runs a gadget action for Nacho (NACHO-138). The Mac side (`PetGadgetActions` in the app target) answers the small
// `PetGadgetHost` questions; everything the model reads (rows, limits, hints, refusals) is decided here, so it is
// tested with a fake host. Nothing here writes a content value (clipboard text, image, file) to a log.

public enum PetGadgetRunState: Equatable {
    case on
    case off
    /// Switched on by the user, but macOS has not granted what it needs (nil: the permission is not known).
    case needsPermission(GadgetPermission?)
    case failed(String)
}

public struct PetClipboardRow: Equatable {
    public var kind: String
    /// Characters (text, link), paths (files) or bytes (image).
    public var length: Int
    public var date: Date
    public var pinned: Bool
    public init(kind: String, length: Int, date: Date, pinned: Bool) {
        self.kind = kind
        self.length = length
        self.date = date
        self.pinned = pinned
    }
}

public enum PetClipboardContent: Equatable {
    case text(String)
    /// A picture: it goes to the chat as an attachment, not as text.
    case image
}

public struct PetShelfRow: Equatable {
    public var name: String
    public var kind: String
    public var bytes: Int
    public init(name: String, kind: String, bytes: Int) {
        self.name = name
        self.kind = kind
        self.bytes = bytes
    }
}

public struct PetMonitorReading: Equatable {
    public var cpuPercent: Double?
    public var memoryPercent: Double?
    public var memoryUsedBytes: Int64?
    public var memoryTotalBytes: Int64?
    public var networkDownBytesPerSecond: Double?
    public var networkUpBytesPerSecond: Double?
    public var diskUsedPercent: Double?
    public var batteryPercent: Int?
    public var onBattery: Bool?
    public init(cpuPercent: Double? = nil, memoryPercent: Double? = nil, memoryUsedBytes: Int64? = nil, memoryTotalBytes: Int64? = nil,
                networkDownBytesPerSecond: Double? = nil, networkUpBytesPerSecond: Double? = nil, diskUsedPercent: Double? = nil,
                batteryPercent: Int? = nil, onBattery: Bool? = nil) {
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.networkDownBytesPerSecond = networkDownBytesPerSecond
        self.networkUpBytesPerSecond = networkUpBytesPerSecond
        self.diskUsedPercent = diskUsedPercent
        self.batteryPercent = batteryPercent
        self.onBattery = onBattery
    }
}

public struct PetDiskEntry: Equatable {
    public var name: String
    public var path: String
    public var isFolder: Bool
    public var bytes: Int64
    public init(name: String, path: String, isFolder: Bool, bytes: Int64) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
        self.bytes = bytes
    }
}

public enum PetDiskTop: Equatable {
    /// No finished scan: one is running (or was just started).
    case scanning(started: Bool)
    case ready(entries: [PetDiskEntry], scannedAt: Date?)
}

/// What the Mac answers. Called on the main thread. Nothing here deletes, moves or empties a disk item.
public protocol PetGadgetHost: AnyObject {
    func gadgetRunState(_ id: ModuleID) -> PetGadgetRunState
    func clipboardRows() -> [PetClipboardRow]
    func clipboardContent(at index: Int) -> PetClipboardContent?
    /// Puts picture `index` on the next chat message; a Korean refusal, or nil.
    func clipboardGiveImage(at index: Int) -> String?
    func clipboardRecopy(at index: Int) -> Bool
    /// How many (unpinned) items went.
    func clipboardClear() -> Int
    func shelfRows() -> [PetShelfRow]
    /// Puts item `index` on the next chat message; a Korean refusal, or nil.
    func shelfGive(at index: Int) -> String?
    func shelfForget(at index: Int) -> Bool
    /// Asks for a capture and answers once (the user may still be dragging an area).
    func captureAsk(_ mode: PetCaptureMode, done: @escaping (PetCommandOutcome) -> Void)
    func captureCloseAll() -> Int
    func monitorReading() -> PetMonitorReading
    func diskTop(count: Int) -> PetDiskTop
    func keepAwake(on: Bool, minutes: Int) -> PetCommandOutcome
    func focusDim(on: Bool) -> PetCommandOutcome
    func menuBar(hidden: Bool) -> PetCommandOutcome
    func deviceStatus() -> PetCommandOutcome
    func micMute(_ muted: Bool) -> PetCommandOutcome
    func mouseTune(_ change: PetMouseChange) -> PetCommandOutcome
    func appSwitchList() -> PetCommandOutcome
    func clockDisplay(_ change: PetClockChange) -> PetCommandOutcome
}

public enum PetGadgetRunner {
    /// A read of clipboard content is cut at this many characters (and says so).
    public static let maxReadCharacters = 4000

    // MARK: refusals the model can relay

    /// The gadget is off: the model asks with the server's `ask_choice` card and switches it on when the user agrees.
    public static func gadgetOff(_ id: ModuleID) -> PetCommandOutcome {
        PetCommandOutcome(
            ok: false,
            message: "\(id.displayName) is switched off, so this cannot run. Ask the user with ask_choice whether to turn it on; "
                + "if they say yes, call combo_set_gadget with gadget=\(id.rawValue) and on=true, then run this again.",
            details: ["reason": "gadget_off", "gadget": id.rawValue])
    }

    /// The gadget is on but macOS has not granted what it needs: say where the user switches it on.
    public static func permissionNeeded(_ id: ModuleID, _ permission: GadgetPermission?) -> PetCommandOutcome {
        let permission = permission ?? id.info.requiredPermission
        let guidance: String
        if let p = permission {
            guidance = "\(p.displayName) 권한이 필요해요. \(p.location)에서 나초콤보를 켜 주세요."
        } else {
            guidance = "맥 권한이 필요해요. 시스템 설정의 개인정보 보호 및 보안에서 나초콤보를 켜 주세요."
        }
        return PetCommandOutcome(
            ok: false,
            message: "\(id.displayName) is on but macOS has not allowed it yet. The user has to switch it on themselves; "
                + "do not retry. Tell the user in Korean: \(guidance)",
            details: ["reason": "permission_needed", "gadget": id.rawValue, "guidance": guidance]
                .merging(permission.map { ["permission": $0.rawValue] } ?? [:]) { a, _ in a })
    }

    public static func stateProblem(_ id: ModuleID, _ state: PetGadgetRunState) -> PetCommandOutcome? {
        switch state {
        case .on: return nil
        case .off: return gadgetOff(id)
        case let .needsPermission(p): return permissionNeeded(id, p)
        case let .failed(m):
            return PetCommandOutcome(ok: false, message: "\(id.displayName) did not start: \(m)",
                                     details: ["reason": "gadget_failed", "gadget": id.rawValue])
        }
    }

    // MARK: running

    public static func run(_ action: PetGadgetAction, host: PetGadgetHost, done: @escaping (PetCommandOutcome) -> Void) {
        if let problem = stateProblem(action.gadget, host.gadgetRunState(action.gadget)) {
            done(problem)
            return
        }
        switch action {
        case .clipboardList:
            done(clipboardList(host.clipboardRows()))
        case let .clipboardRead(index):
            done(clipboardRead(index, host))
        case let .clipboardRecopy(index):
            done(host.clipboardRecopy(at: index)
                ? PetCommandOutcome(ok: true, message: "Copied clipboard item \(index) again; it is now the newest.")
                : outOfRange("clipboard item", index, host.clipboardRows().count))
        case .clipboardClear:
            let n = host.clipboardClear()
            done(PetCommandOutcome(ok: true, message: "Cleared \(n) clipboard item\(n == 1 ? "" : "s") (pinned items stay). This cannot be undone.",
                                   details: ["cleared": n]))
        case .shelfList:
            done(shelfList(host.shelfRows()))
        case let .shelfGive(index):
            if let refusal = host.shelfGive(at: index) {
                done(PetCommandOutcome(ok: false, message: "Shelf item \(index) was not handed over: \(refusal)",
                                       details: ["reason": "not_attached"]))
            } else {
                done(handedOver("shelf item \(index)"))
            }
        case let .shelfForget(index):
            done(host.shelfForget(at: index)
                ? PetCommandOutcome(ok: true, message: "Took shelf item \(index) off the shelf. The original file is untouched and the shelf can undo it.")
                : outOfRange("shelf item", index, host.shelfRows().count))
        case let .captureAsk(mode):
            host.captureAsk(mode, done: done)
        case .captureCloseAll:
            let n = host.captureCloseAll()
            done(PetCommandOutcome(ok: true, message: n == 0 ? "No pinned captures were open." : "Closed \(n) pinned capture\(n == 1 ? "" : "s").",
                                   details: ["closed": n]))
        case .monitorRead:
            done(monitorRead(host.monitorReading()))
        case let .diskTop(count):
            done(diskTop(host.diskTop(count: count), count: count))
        case let .keepAwake(on, minutes):
            done(host.keepAwake(on: on, minutes: minutes))
        case let .focusDim(on):
            done(host.focusDim(on: on))
        case let .menuBar(hidden):
            done(host.menuBar(hidden: hidden))
        case .deviceStatus:
            done(host.deviceStatus())
        case let .micMute(muted):
            done(host.micMute(muted))
        case let .mouseTune(change):
            done(host.mouseTune(change))
        case .appSwitchList:
            done(host.appSwitchList())
        case let .clockDisplay(change):
            done(host.clockDisplay(change))
        }
    }

    // MARK: formatting

    static func outOfRange(_ what: String, _ index: Int, _ count: Int) -> PetCommandOutcome {
        PetCommandOutcome(ok: false,
                          message: count == 0 ? "There is no \(what) (the list is empty)."
                              : "There is no \(what) number \(index); the list has \(count). List it again to see the current numbers.",
                          details: ["reason": "out_of_range", "count": count])
    }

    static func handedOver(_ what: String) -> PetCommandOutcome {
        PetCommandOutcome(ok: true,
                          message: "Attached \(what) to the user's next chat message. It is sent when the user presses send; "
                              + "tell the user to press send.",
                          details: ["attached": true])
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func clipboardList(_ rows: [PetClipboardRow]) -> PetCommandOutcome {
        let items: [[String: Any]] = rows.enumerated().map { n, r in
            ["index": n + 1, "kind": r.kind, "length": r.length, "copied_at": iso(r.date), "pinned": r.pinned]
        }
        return PetCommandOutcome(ok: true,
                                 message: rows.isEmpty ? "The clipboard history is empty."
                                     : "\(rows.count) clipboard item\(rows.count == 1 ? "" : "s"), newest first. The list has no previews; read one by number.",
                                 details: ["items": items])
    }

    static func clipboardRead(_ index: Int, _ host: PetGadgetHost) -> PetCommandOutcome {
        let count = host.clipboardRows().count
        guard (1...max(count, 1)).contains(index), count > 0 else { return outOfRange("clipboard item", index, count) }
        switch host.clipboardContent(at: index) {
        case nil:
            return outOfRange("clipboard item", index, count)
        case .image?:
            if let refusal = host.clipboardGiveImage(at: index) {
                return PetCommandOutcome(ok: false, message: "Clipboard item \(index) is a picture and could not be attached: \(refusal)",
                                         details: ["reason": "not_attached"])
            }
            return handedOver("the picture in clipboard item \(index)")
        case let .text(text)?:
            let truncated = text.count > maxReadCharacters
            let shown = truncated ? String(text.prefix(maxReadCharacters)) : text
            var details: [String: Any] = ["index": index, "text": shown, "length": text.count, "truncated": truncated]
            if truncated { details["note"] = "Cut at \(maxReadCharacters) characters of \(text.count)." }
            return PetCommandOutcome(ok: true,
                                     message: truncated ? "Clipboard item \(index), cut at \(maxReadCharacters) of \(text.count) characters."
                                         : "Clipboard item \(index).",
                                     details: details)
        }
    }

    static func shelfList(_ rows: [PetShelfRow]) -> PetCommandOutcome {
        let items: [[String: Any]] = rows.enumerated().map { n, r in
            ["index": n + 1, "name": r.name, "kind": r.kind, "bytes": r.bytes]
        }
        return PetCommandOutcome(ok: true,
                                 message: rows.isEmpty ? "The file shelf is empty." : "\(rows.count) item\(rows.count == 1 ? "" : "s") on the file shelf.",
                                 details: ["items": items])
    }

    static func rounded(_ v: Double?) -> Any { v.map { ($0 * 10).rounded() / 10 } ?? NSNull() }

    static func monitorRead(_ r: PetMonitorReading) -> PetCommandOutcome {
        var d: [String: Any] = [
            "cpu_percent": rounded(r.cpuPercent), "memory_percent": rounded(r.memoryPercent),
            "network_down_bytes_per_second": rounded(r.networkDownBytesPerSecond),
            "network_up_bytes_per_second": rounded(r.networkUpBytesPerSecond), "disk_used_percent": rounded(r.diskUsedPercent),
        ]
        if let u = r.memoryUsedBytes { d["memory_used_bytes"] = u }
        if let t = r.memoryTotalBytes { d["memory_total_bytes"] = t }
        d["battery_percent"] = r.batteryPercent.map { $0 as Any } ?? NSNull()
        d["on_battery"] = r.onBattery.map { $0 as Any } ?? NSNull()
        var parts: [String] = []
        if let c = r.cpuPercent { parts.append("CPU \(Int(c.rounded()))%") }
        if let m = r.memoryPercent { parts.append("memory \(Int(m.rounded()))%") }
        if let b = r.batteryPercent { parts.append("battery \(b)%\(r.onBattery == true ? " (on battery)" : "")") }
        return PetCommandOutcome(ok: true, message: parts.isEmpty ? "The monitor has no reading yet; try again in a few seconds."
                                                                   : "Right now: " + parts.joined(separator: ", ") + ".",
                                 details: d)
    }

    static func diskTop(_ top: PetDiskTop, count: Int) -> PetCommandOutcome {
        switch top {
        case let .scanning(started):
            return PetCommandOutcome(ok: true,
                                     message: started ? "There was no finished scan, so Disk Map started scanning the startup disk. Ask again in a minute or two."
                                         : "Disk Map is still scanning. Ask again in a minute.",
                                     details: ["scan": started ? "started" : "running"])
        case let .ready(entries, at):
            let shown = Array(entries.prefix(count))
            let items: [[String: Any]] = shown.enumerated().map { n, e in
                ["rank": n + 1, "name": e.name, "path": e.path, "kind": e.isFolder ? "folder" : "file", "bytes": e.bytes]
            }
            var d: [String: Any] = ["items": items]
            if let at = at { d["scanned_at"] = iso(at) }
            return PetCommandOutcome(ok: true, message: "Top \(shown.count) by size from the last scan. Read only: nothing was deleted or moved.", details: d)
        }
    }
}
