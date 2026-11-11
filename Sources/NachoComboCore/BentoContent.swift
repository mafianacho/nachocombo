import Foundation

/// What one widget's body shows, built from what the tool's module really has right now (never sample values).
/// When a tool cannot give the numbers its widget was drawn for, its body is `.basic`: a one-line description.
public enum BentoBody: Equatable {
    /// Icon, name, state and one line (the header carries the state): tools without data of their own.
    case basic(line: String)
    /// Nacho Pet: the character, one sentence, an optional action ("나초 계정으로 로그인").
    case pet(line: String, action: String?, signedIn: Bool)
    /// Rings (fraction 0…1 or nil when unknown) and a side column of label/value lines (System Monitor).
    case gauges(rings: [BentoRing], side: [BentoLine])
    /// Permission rows and an optional button for the first missing one (Computer Use).
    case checklist(rows: [BentoCheck], action: String?)
    /// Snap layout pictures and a caption (Window Snap).
    case layouts([BentoSnapShape], caption: String?)
    /// A countdown: fraction left (nil: no end), big text, caption (Keep Awake).
    case timer(fraction: Double?, big: String, caption: String)
    /// Recent items, newest first, each with a kind and an age; `empty` when there are none.
    case list(rows: [BentoRow], empty: String)
    /// Floating captures: count and a caption (Capture Float).
    case stack(count: Int, caption: String)
    /// One level between two words, and a caption (Focus Dim).
    case level(fraction: Double, low: String, high: String, caption: String)
    /// Slider-like rows (fraction 0…1) and plain rows (Device Control, Mouse Tune).
    case sliders([BentoSlider], rows: [BentoLine])
    /// Weekday, day of month, the next event if allowed (Calendar Clock).
    case calendar(weekday: String, day: String, event: BentoLine?, note: String?)
    /// Used of total in bytes with category segments (Disk Map).
    case usage(big: String, caption: String, segments: [BentoSegment])
    /// Drop slots with item names (File Shelf).
    case slots([BentoRow], drop: String)
    /// A strip of icons and a caption (Menu Bar).
    case strip(count: Int?, caption: String)
}

public struct BentoRing: Equatable {
    public enum Tone: String, Equatable { case green, blue, orange }
    public var label: String
    public var fraction: Double?
    public var tone: Tone
    public init(label: String, fraction: Double?, tone: Tone) { self.label = label; self.fraction = fraction; self.tone = tone }
    /// "37%", or "—" when unknown.
    public var text: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
}

public struct BentoLine: Equatable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct BentoCheck: Equatable {
    public var name: String
    public var granted: Bool?
    public init(name: String, granted: Bool?) { self.name = name; self.granted = granted }
    public var stateText: String {
        switch granted {
        case true?: return "허용됨"
        case false?: return "필요"
        case nil: return "확인 중"
        }
    }
}

public struct BentoSnapShape: Equatable {
    /// The filled part in unit coordinates (x, y from top-left, width, height).
    public var x: Double, y: Double, w: Double, h: Double
    public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct BentoRow: Equatable {
    public enum Kind: String, Equatable { case text, link, image, file }
    public var kind: Kind
    public var text: String
    public var detail: String?
    public init(kind: Kind, text: String, detail: String? = nil) { self.kind = kind; self.text = text; self.detail = detail }
}

public struct BentoSlider: Equatable {
    public var symbol: String
    public var label: String
    public var fraction: Double?
    public var value: String
    public init(symbol: String, label: String, fraction: Double?, value: String) {
        self.symbol = symbol; self.label = label; self.fraction = fraction; self.value = value
    }
}

public struct BentoSegment: Equatable {
    public var label: String
    public var fraction: Double
    public init(label: String, fraction: Double) { self.label = label; self.fraction = fraction }
}

/// One widget as the board and the menu bar mini board draw it.
public struct BentoWidget: Equatable {
    public var id: ModuleID
    public var status: ToolStatusPresentation
    public var enabled: Bool
    public var pinned: Bool
    /// The tool's open shortcut ("⇧⌘V"), if one is set.
    public var shortcut: String?
    public var body: BentoBody

    public init(id: ModuleID, status: ToolStatusPresentation, enabled: Bool, pinned: Bool, shortcut: String?, body: BentoBody) {
        self.id = id; self.status = status; self.enabled = enabled; self.pinned = pinned; self.shortcut = shortcut; self.body = body
    }

    /// Whether the body has the tool's own data (false: the basic widget).
    public var isSpecial: Bool { if case .basic = body { return false }; return true }
}

/// The three-state dot of a widget's header: off gray, on green, on but more setup needed = green with a half yellow
/// behind it. An error is red. The words (`status.stateText`) always go with it: in the tooltip and accessibility name.
public enum BentoDot: String, Equatable {
    case off, on, setup, error

    public init(_ kind: StatusDotKind) {
        switch kind {
        case .off: self = .off
        case .on: self = .on
        case .onNeedsSetup: self = .setup
        case .onError: self = .error
        }
    }

    /// Korean words for the tooltip and VoiceOver, never color alone.
    public var koreanText: String {
        switch self {
        case .off: return "꺼짐"
        case .on: return "켜짐"
        case .setup: return "켜짐 · 추가 설정 필요"
        case .error: return "켜짐 · 오류"
        }
    }
}

/// Number and time text of the widgets.
public enum BentoFormat {
    /// The widget header's name: the tool's name, shortened where the cell is narrow ("Menu Bar").
    public static func name(_ id: ModuleID) -> String {
        id == .menuBar ? "Menu Bar" : id.displayName
    }

    /// Decimal units like Finder and Activity Monitor: 1_200_000 → "1.2MB/s", 84_000 → "84KB/s", 0 → "0B/s".
    public static func rate(_ bytesPerSecond: Double) -> String { size(bytesPerSecond) + "/s" }

    /// Bytes in 1000 steps, one decimal below 10 ("1.2MB", "84KB", "612GB", "1TB").
    public static func size(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(0, bytes)
        var i = 0
        while v >= 999.5, i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(Int(v))B" }
        if v < 10 {
            let r = (v * 10).rounded() / 10
            return (r == r.rounded() ? "\(Int(r))" : String(format: "%.1f", r)) + units[i]
        }
        return "\(Int(v.rounded()))" + units[i]
    }

    /// Seconds left → "1:14" (h:mm) from an hour on, else "14분", "45초".
    public static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 3600 { return String(format: "%d:%02d", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return "\((s + 59) / 60)분" }
        return "\(s)초"
    }

    /// A duration in words: "2시간", "1시간 30분", "45분".
    public static func duration(_ seconds: TimeInterval) -> String {
        let m = max(0, Int((seconds / 60).rounded()))
        if m >= 60 { return m % 60 == 0 ? "\(m / 60)시간" : "\(m / 60)시간 \(m % 60)분" }
        return "\(m)분"
    }

    /// How long ago: "방금" (under a minute), "3분", "2시간", "어제", "5일".
    public static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "방금" }
        if s < 3600 { return "\(Int(s / 60))분" }
        if s < 86400 { return "\(Int(s / 3600))시간" }
        if s < 2 * 86400 { return "어제" }
        return "\(Int(s / 86400))일"
    }

    /// 0…1 → "64".
    public static func percentNumber(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))" }

    /// Monday-first Korean weekday name for Calendar's weekday number (1 = Sunday).
    public static func weekday(_ calendarWeekday: Int) -> String {
        ["일요일", "월요일", "화요일", "수요일", "목요일", "금요일", "토요일"][(max(1, min(7, calendarWeekday)) - 1)]
    }

    /// One line of text for a list row: newlines and runs of spaces folded, at most `limit` characters.
    public static func oneLine(_ text: String, limit: Int = 120) -> String {
        let folded = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return folded.count > limit ? String(folded.prefix(limit)) + "…" : folded
    }
}
