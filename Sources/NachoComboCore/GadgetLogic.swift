import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Keep Awake

/// Whether Keep Awake holds the Mac awake right now, and why (or why not).
public enum KeepAwakeDecision: Equatable {
    case sleepAllowed
    case awake(String)
    /// Wanted, but the battery guard lets the Mac sleep.
    case heldBack(String)

    public var holds: Bool { if case .awake = self { return true } else { return false } }

    public var text: String {
        switch self {
        case .sleepAllowed: return "The Mac sleeps as usual"
        case .awake(let reason), .heldBack(let reason): return reason
        }
    }
}

public enum KeepAwakePolicy {
    /// - Parameters:
    ///   - manual: the user switched it on from the cup (or a shortcut).
    ///   - until: when a timed hold ends (nil: until turned off).
    ///   - runningApp: the name of a chosen app that runs now (nil: none).
    ///   - batteryPercent: nil on a Mac without a battery.
    public static func decide(manual: Bool, until: Date?, now: Date, runningApp: String?, onBattery: Bool,
                              batteryPercent: Int?, options: GadgetOptions) -> KeepAwakeDecision {
        let timedOut = until.map { now >= $0 } ?? false
        let byHand = manual && !timedOut
        guard byHand || runningApp != nil else { return .sleepAllowed }
        if options.keepAwakePowerOnly && onBattery { return .heldBack("Waiting for the power adapter") }
        if onBattery, options.keepAwakeBatteryFloor > 0, let percent = batteryPercent, percent <= options.keepAwakeBatteryFloor {
            return .heldBack("Battery at \(percent)%: sleeping as usual")
        }
        if byHand, let until = until { return .awake("Awake for \(remainingText(until: until, now: now)) more") }
        if byHand { return .awake("Awake until you turn it off") }
        return .awake("Awake while \(runningApp ?? "an app") runs")
    }

    /// "45m", "1:05" (hours:minutes) — short enough for the menu bar.
    public static func remainingText(until: Date, now: Date) -> String {
        let minutes = max(0, Int(ceil(until.timeIntervalSince(now) / 60)))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    public static func durationName(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Until Turned Off"
        case let m where m < 60: return "\(m) Minutes"
        case 60: return "1 Hour"
        case let m where m % 60 == 0: return "\(m / 60) Hours"
        default: return "\(minutes / 60) h \(minutes % 60) min"
        }
    }
}

// MARK: - Clipboard History

public enum ClipboardKind: String, Codable, CaseIterable {
    case text, link, image, files

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .files: return "Files"
        }
    }
}

/// One copy. Text keeps its formatting (RTF) as well, so a normal paste looks like the original.
public struct ClipboardItem: Codable, Equatable {
    public let id: UUID
    public var kind: ClipboardKind
    /// The text, the link, or file paths one per line.
    public var text: String
    public var rtf: Data?
    public var imagePNG: Data?
    public var sourceApp: String?
    public var date: Date
    public var pinned: Bool

    public init(id: UUID = UUID(), kind: ClipboardKind, text: String, rtf: Data? = nil, imagePNG: Data? = nil,
                sourceApp: String? = nil, date: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.rtf = rtf
        self.imagePNG = imagePNG
        self.sourceApp = sourceApp
        self.date = date
        self.pinned = pinned
    }

    /// One line for the list: the first non-empty line, or the file names.
    public var title: String {
        switch kind {
        case .image: return "Image"
        case .files:
            let names = text.split(separator: "\n").map { ($0 as Substring).split(separator: "/").last.map(String.init) ?? "" }
            return names.count == 1 ? names[0] : "\(names.count) files: " + names.prefix(3).joined(separator: ", ")
        case .text, .link:
            let line = text.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return String((line ?? "").trimmingCharacters(in: .whitespaces).prefix(200))
        }
    }

    /// Same content, wherever and whenever it was copied.
    public var signature: String {
        switch kind {
        case .image: return "image:\(imagePNG?.count ?? 0):\(ClipboardHistory.fnv1a(imagePNG ?? Data()))"
        default: return "\(kind.rawValue):\(text)"
        }
    }
}

public struct ClipboardHistory: Equatable {
    /// Newest first; pins keep their place in time but are listed first.
    public private(set) var items: [ClipboardItem] = []
    public var limit: Int { didSet { trim() } }
    public static let maxImageBytes = 8 * 1024 * 1024

    public init(limit: Int = 100, pins: [ClipboardItem] = []) {
        self.limit = max(1, limit)
        items = pins.map { var p = $0; p.pinned = true; return p }
    }

    /// Adds a copy at the top. Copying the same thing again moves it up instead of adding a second one (a pin stays
    /// pinned). Returns false when nothing was added.
    @discardableResult
    public mutating func add(_ item: ClipboardItem) -> Bool {
        guard !item.text.isEmpty || item.imagePNG != nil else { return false }
        if let png = item.imagePNG, png.count > ClipboardHistory.maxImageBytes { return false }
        var new = item
        if let index = items.firstIndex(where: { $0.signature == item.signature }) {
            new.pinned = items[index].pinned
            items.remove(at: index)
        }
        items.insert(new, at: 0)
        trim()
        return true
    }

    public mutating func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].pinned.toggle()
        trim()
    }

    public mutating func remove(_ id: UUID) { items.removeAll { $0.id == id } }

    public mutating func clearUnpinned() { items.removeAll { !$0.pinned } }

    public var pins: [ClipboardItem] { items.filter { $0.pinned } }

    public func item(_ id: UUID) -> ClipboardItem? { items.first { $0.id == id } }

    /// Pins first, then the rest, newest first; `query` matches the text, the kind ("image", "link") or the app.
    public func search(_ query: String) -> [ClipboardItem] {
        let ordered = pins + items.filter { !$0.pinned }
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ordered }
        return ordered.filter { item in
            let haystack = (item.text + " " + item.kind.rawValue + " " + (item.sourceApp ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private mutating func trim() {
        var unpinned = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinned += 1
            return unpinned <= limit
        }
    }

    static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

// MARK: - Meeting links

public enum MeetingLinks {
    /// Hosts of video call services; a link to one of them (or a subdomain) is a meeting link.
    static let hosts = ["zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                        "whereby.com", "meet.jit.si", "chime.aws", "gotomeeting.com", "gotomeet.me", "bluejeans.com",
                        "facetime.apple.com", "around.co", "meet.lync.com", "join.skype.com"]

    /// The first meeting link in the given texts (an event's URL, location and notes, in that order).
    public static func detect(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) {
            for candidate in links(in: text) {
                guard let url = URL(string: candidate), let host = url.host?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    static func links(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let range = rest.range(of: "https://") ?? rest.range(of: "http://") {
            let tail = rest[range.lowerBound...]
            let end = tail.firstIndex { $0.isWhitespace || "<>\"'".contains($0) } ?? tail.endIndex
            var link = String(tail[..<end])
            while let last = link.last, ".,;:)]".contains(last) { link.removeLast() }
            found.append(link)
            rest = tail[end...]
        }
        return found
    }
}

// MARK: - Calendar Clock

public enum WorldClock {
    /// "America/New_York" → "New York".
    public static func city(_ identifier: String) -> String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// How far `zone` is from `local` at `date`: "+9h", "−3h 30m", "Same time".
    public static func offset(_ zone: TimeZone, from local: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)
        guard seconds != 0 else { return "Same time" }
        let sign = seconds > 0 ? "+" : "−"
        let minutes = abs(seconds) / 60
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(sign)\(h)h" : "\(sign)\(h)h \(m)m"
    }

    /// Cities offered in the picker, west to east.
    public static let suggestions = [
        "Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Chicago",
        "America/New_York", "America/Toronto", "America/Mexico_City", "America/Sao_Paulo", "Atlantic/Reykjavik",
        "Europe/London", "Europe/Lisbon", "Europe/Paris", "Europe/Berlin", "Europe/Amsterdam", "Europe/Stockholm",
        "Africa/Lagos", "Africa/Johannesburg", "Europe/Athens", "Africa/Cairo", "Europe/Istanbul", "Europe/Moscow",
        "Asia/Dubai", "Asia/Karachi", "Asia/Kolkata", "Asia/Dhaka", "Asia/Bangkok", "Asia/Jakarta", "Asia/Singapore",
        "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Taipei", "Asia/Seoul", "Asia/Tokyo", "Australia/Perth",
        "Australia/Sydney", "Pacific/Auckland", "UTC",
    ]
}

public enum ClockFormat {
    /// A date format template for the menu bar clock; `DateFormatter.dateFormat(fromTemplate:)` puts it in the order of
    /// the user's language.
    public static func template(date: Bool, weekday: Bool, seconds: Bool, hours: ClockHours) -> String {
        var template = ""
        if weekday { template += "EEE" }
        if date { template += "dMMM" }
        switch hours {
        case .system: template += "j"
        case .twelve: template += "h"
        case .twentyFour: template += "H"
        }
        template += "mm"
        if seconds { template += "ss" }
        return template
    }

    /// "in 5 min", "now", "in 1 h 20 min" before an event; nil once it has started more than 5 minutes ago.
    public static func countdown(to start: Date, now: Date) -> String? {
        let minutes = Int(ceil(start.timeIntervalSince(now) / 60))
        if minutes < -5 { return nil }
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Mouse Tune

public enum ScrollTuning {
    /// Points a wheel notch scrolls with smooth scrolling (macOS jumps about this far per line on its own).
    public static let pointsPerLine = 40.0

    /// A wheel delta after the direction and speed options.
    public static func adjusted(_ delta: Double, reverse: Bool, speed: Double) -> Double {
        (reverse ? -delta : delta) * speed
    }
}

/// Turns wheel notches into a glide: each notch adds distance, and every frame delivers a share of what is left.
public struct SmoothScroller: Equatable {
    public private(set) var pending: Double = 0
    /// Seconds for about two thirds of the distance.
    public var tau: Double

    public init(tau: Double = 0.07) { self.tau = tau }

    public mutating func add(_ points: Double) {
        // Turning the wheel the other way stops the glide at once instead of fighting it.
        if pending != 0 && (pending > 0) != (points > 0) { pending = 0 }
        pending += points
    }

    /// The points to scroll in this frame.
    public mutating func step(dt: Double) -> Double {
        guard pending != 0 else { return 0 }
        var amount = pending * (1 - exp(-dt / tau))
        if abs(pending - amount) < 0.5 { amount = pending }
        pending -= amount
        return amount
    }

    public var isIdle: Bool { pending == 0 }
    public mutating func reset() { pending = 0 }
}

// MARK: - Window Snap layouts

public struct SavedWindow: Codable, Equatable {
    public var bundleID: String
    public var appName: String
    /// Cocoa coordinates (bottom-left origin of the primary display).
    public var x: Double, y: Double, width: Double, height: Double
    /// Which of the app's windows it was, front to back.
    public var order: Int

    public init(bundleID: String, appName: String, frame: CGRect, order: Int) {
        self.bundleID = bundleID
        self.appName = appName
        x = Double(frame.minX); y = Double(frame.minY); width = Double(frame.width); height = Double(frame.height)
        self.order = order
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

public struct SavedWindowLayout: Codable, Equatable {
    /// The displays it was saved on (`DisplaySignature`).
    public var displays: String
    public var displayCount: Int
    public var savedAt: Date
    public var windows: [SavedWindow]

    public init(displays: String, displayCount: Int, savedAt: Date, windows: [SavedWindow]) {
        self.displays = displays
        self.displayCount = displayCount
        self.savedAt = savedAt
        self.windows = windows
    }

    public var appCount: Int { Set(windows.map { $0.bundleID }).count }
}

public enum DisplaySignature {
    /// The same set of displays in the same arrangement gives the same text: "1512x982+0+0,1920x1080+1512+0".
    public static func make(_ frames: [CGRect]) -> String {
        frames.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
            .map { "\(Int($0.width))x\(Int($0.height))+\(Int($0.minX))+\(Int($0.minY))" }
            .joined(separator: ",")
    }
}

/// One saved layout per arrangement of displays (the newest few), kept in a file of its own.
public struct WindowLayoutStore: Codable, Equatable {
    public private(set) var layouts: [SavedWindowLayout] = []
    public static let maxLayouts = 8

    public init(layouts: [SavedWindowLayout] = []) { self.layouts = layouts }

    public mutating func save(_ layout: SavedWindowLayout) {
        layouts.removeAll { $0.displays == layout.displays }
        layouts.insert(layout, at: 0)
        if layouts.count > WindowLayoutStore.maxLayouts { layouts.removeLast(layouts.count - WindowLayoutStore.maxLayouts) }
    }

    /// The layout saved on exactly these displays.
    public func layout(for displays: String) -> SavedWindowLayout? { layouts.first { $0.displays == displays } }

    public var latest: SavedWindowLayout? { layouts.first }

    public mutating func remove(_ displays: String) { layouts.removeAll { $0.displays == displays } }

    public static func load(from url: URL) -> WindowLayoutStore {
        guard let data = try? Data(contentsOf: url) else { return WindowLayoutStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WindowLayoutStore.self, from: data)) ?? WindowLayoutStore()
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum LayoutMatching {
    /// Which saved frame each open window gets: an app's windows, front to back, take its saved frames in order.
    /// Windows without a saved frame (and saved frames without a window) are left alone.
    /// - Returns: index into `current` → frame.
    public static func assign(saved: [SavedWindow], current: [(bundleID: String, order: Int)]) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        var byApp: [String: [SavedWindow]] = [:]
        for window in saved { byApp[window.bundleID, default: []].append(window) }
        for key in byApp.keys { byApp[key]?.sort { $0.order < $1.order } }
        for (index, window) in current.enumerated() {
            guard let frames = byApp[window.bundleID], !frames.isEmpty else { continue }
            let position = current[..<index].filter { $0.bundleID == window.bundleID }.count
            if position < frames.count { result[index] = frames[position].frame }
        }
        return result
    }
}

// MARK: - Focus sessions

/// A focus timer: focus for a while, then an optional break, then back to idle.
public struct FocusSession: Equatable {
    public enum Phase: String { case idle, focus, rest }
    public enum Event: Equatable { case focusEnded, restEnded }

    public private(set) var phase: Phase = .idle
    public private(set) var endsAt: Date?
    /// Focus periods finished today (since the app started).
    public private(set) var completed = 0

    public init() {}

    public var isActive: Bool { phase != .idle }

    public mutating func start(now: Date, minutes: Int) {
        phase = .focus
        endsAt = now.addingTimeInterval(TimeInterval(max(1, minutes) * 60))
    }

    public mutating func stop() {
        phase = .idle
        endsAt = nil
    }

    /// Moves on when the time is up; returns what just ended.
    public mutating func tick(now: Date, breakMinutes: Int) -> Event? {
        guard let end = endsAt, now >= end else { return nil }
        switch phase {
        case .focus:
            completed += 1
            if breakMinutes > 0 {
                phase = .rest
                endsAt = end.addingTimeInterval(TimeInterval(breakMinutes * 60))
                if now >= endsAt! { stop() }
            } else {
                stop()
            }
            return .focusEnded
        case .rest:
            stop()
            return .restEnded
        case .idle:
            return nil
        }
    }

    public func remaining(now: Date) -> TimeInterval { max(0, (endsAt ?? now).timeIntervalSince(now)) }

    /// "24:59" (minutes:seconds).
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(ceil(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
