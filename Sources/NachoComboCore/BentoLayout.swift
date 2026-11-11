import Foundation

/// How big a widget is on the bento board: one cell, two cells side by side, or two by two.
public enum BentoSize: String, Codable, CaseIterable, Equatable {
    case small, wide, large

    public var columns: Int { self == .small ? 1 : 2 }
    public var rows: Int { self == .large ? 2 : 1 }

    /// The edit panel's names (작게 / 가로 / 크게).
    public var koreanName: String {
        switch self {
        case .small: return "작게"
        case .wide: return "가로"
        case .large: return "크게"
        }
    }
}

/// One widget on the board, in board order.
public struct BentoItem: Codable, Equatable {
    /// ModuleID.rawValue (a string, so a file from a newer version with more tools still decodes).
    public var id: String
    public var size: BentoSize
    public var hidden: Bool

    public init(id: String, size: BentoSize, hidden: Bool = false) {
        self.id = id
        self.size = size
        self.hidden = hidden
    }

    public var module: ModuleID? { ModuleID(rawValue: id) }

    private enum CodingKeys: String, CodingKey { case id, size, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // An unknown size (a newer version) falls back to one cell instead of dropping the widget.
        size = (try? c.decodeIfPresent(BentoSize.self, forKey: .size)) ?? .small
        hidden = (try? c.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
    }
}

/// The main window's widget board (order, size, hidden). Independent of ON/OFF, of menu bar pins and of shortcuts:
/// moving, resizing or hiding a widget never switches a tool on or off and never asks for a permission.
public struct BentoLayout: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var items: [BentoItem]

    public init(items: [BentoItem], version: Int = BentoLayout.currentVersion) {
        self.version = version
        self.items = items
    }

    /// The board order of the design: Nacho Pet, then the tools in this order.
    public static let designOrder: [ModuleID] = [.nachoPet, .systemMonitor, .computerUse, .windowSnap, .keepAwake, .clipboard,
                                                 .captureFloat, .focusDim, .deviceControl, .calendarClock, .diskMap, .fileShelf,
                                                 .menuBar, .appSwitch, .mouseTune]

    /// The size each tool starts with (what its widget was designed for).
    public static func defaultSize(_ id: ModuleID) -> BentoSize {
        switch id {
        case .nachoPet: return .large
        case .systemMonitor, .computerUse, .clipboard, .deviceControl, .fileShelf: return .wide
        default: return .small
        }
    }

    /// The board for someone who has none yet (first launch, or an update from 0.6 or older): Nacho Pet first, then
    /// the tools that are on, then the rest, each group in the design's order. Nothing is hidden.
    public static func defaults(for settings: AppSettings) -> BentoLayout {
        let order = designOrder + ModuleID.allCases.filter { !designOrder.contains($0) }
        let rest = order.filter { $0 != .nachoPet }
        let on = rest.filter { settings.isEnabled($0) }
        let off = rest.filter { !settings.isEnabled($0) }
        return BentoLayout(items: ([.nachoPet] + on + off).map { BentoItem(id: $0.rawValue, size: defaultSize($0)) })
    }

    /// Every known tool exactly once: unknown ids and duplicates go, tools missing from the file (a version that added
    /// one) are appended with their default size.
    public func normalized() -> BentoLayout {
        var seen = Set<String>()
        var out: [BentoItem] = []
        for item in items where item.module != nil && !seen.contains(item.id) {
            seen.insert(item.id)
            out.append(item)
        }
        for id in BentoLayout.designOrder + ModuleID.allCases where !seen.contains(id.rawValue) {
            seen.insert(id.rawValue)
            out.append(BentoItem(id: id.rawValue, size: BentoLayout.defaultSize(id)))
        }
        return BentoLayout(items: out, version: BentoLayout.currentVersion)
    }

    public var visible: [BentoItem] { items.filter { !$0.hidden } }
    public var hiddenModules: [ModuleID] { items.filter { $0.hidden }.compactMap { $0.module } }

    public func item(_ id: ModuleID) -> BentoItem? { items.first { $0.id == id.rawValue } }

    public mutating func setSize(_ id: ModuleID, _ size: BentoSize) {
        guard let i = items.firstIndex(where: { $0.id == id.rawValue }) else { return }
        items[i].size = size
    }

    public mutating func setHidden(_ id: ModuleID, _ hidden: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id.rawValue }) else { return }
        items[i].hidden = hidden
        // A widget that comes back goes to the end of the board, where "+ 위젯 추가" was.
        if !hidden {
            let item = items.remove(at: i)
            items.append(item)
        }
    }

    /// Moves `id` so it sits just before `target` in board order (nil: to the end).
    public mutating func move(_ id: ModuleID, before target: ModuleID?) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id.rawValue }) else { return }
        let item = items.remove(at: from)
        if let t = target, let to = items.firstIndex(where: { $0.id == t.rawValue }) { items.insert(item, at: to) }
        else { items.append(item) }
    }

    /// Drag and drop in edit mode: dropped on a widget further along it lands after it, on one before it lands before
    /// it (the dropped widget takes the target's place either way).
    public mutating func drop(_ id: ModuleID, onto target: ModuleID) {
        guard id != target, let from = items.firstIndex(where: { $0.id == id.rawValue }),
              let to = items.firstIndex(where: { $0.id == target.rawValue }) else { return }
        let item = items.remove(at: from)
        let at = items.firstIndex(where: { $0.id == target.rawValue }) ?? to
        items.insert(item, at: from < to ? at + 1 : at)
    }

    /// Keyboard move in edit mode: one place earlier (-1) or later (+1) among the visible widgets.
    public mutating func step(_ id: ModuleID, by delta: Int) {
        let shown = visible.compactMap { $0.module }
        guard let i = shown.firstIndex(of: id) else { return }
        let j = i + delta
        guard j >= 0, j < shown.count else { return }
        if delta < 0 { move(id, before: shown[j]) } else { move(id, before: j + 1 < shown.count ? shown[j + 1] : nil) }
    }
}

/// Where a widget lands on a grid of `columns` columns.
public struct BentoPlacement: Equatable {
    public var id: String
    public var column: Int
    public var row: Int
    public var columns: Int
    public var rows: Int

    public init(id: String, column: Int, row: Int, columns: Int, rows: Int) {
        self.id = id; self.column = column; self.row = row; self.columns = columns; self.rows = rows
    }
}

/// Fills the grid row by row in board order: each widget takes the first free place it fits in (later small widgets
/// fill gaps that bigger ones left). A widget wider than the grid is narrowed to it.
public enum BentoPacker {
    public static func pack(_ items: [BentoItem], columns: Int, extra: [String] = []) -> (placements: [BentoPlacement], rows: Int) {
        let cols = max(1, columns)
        var taken: [[Bool]] = []
        func free(_ r: Int, _ c: Int, _ w: Int, _ h: Int) -> Bool {
            guard c + w <= cols else { return false }
            for y in r..<(r + h) {
                guard y < taken.count else { continue }
                for x in c..<(c + w) where taken[y][x] { return false }
            }
            return true
        }
        func take(_ r: Int, _ c: Int, _ w: Int, _ h: Int) {
            while taken.count < r + h { taken.append(Array(repeating: false, count: cols)) }
            for y in r..<(r + h) { for x in c..<(c + w) { taken[y][x] = true } }
        }
        var out: [BentoPlacement] = []
        let all = items.map { ($0.id, min(cols, $0.size.columns), $0.size.rows) } + extra.map { ($0, 1, 1) }
        for (id, w, h) in all {
            var r = 0
            search: while true {
                for c in 0..<cols where free(r, c, w, h) {
                    take(r, c, w, h)
                    out.append(BentoPlacement(id: id, column: c, row: r, columns: w, rows: h))
                    break search
                }
                r += 1
            }
        }
        return (out, taken.count)
    }

    /// Columns that fit `width` points when a cell must be at least `minCell` wide: 6 on a wide window, 4, then 2.
    public static func columns(forWidth width: Double, minCell: Double, gap: Double) -> Int {
        for n in [6, 4, 2] where Double(n) * minCell + Double(n - 1) * gap <= width { return n }
        return 2
    }
}

public extension AppSettings {
    /// The board to show: the saved one (with tools added since), else the default for these settings.
    var bentoLayout: BentoLayout { bento?.normalized() ?? BentoLayout.defaults(for: self) }
}

/// What each size of a widget shows, for the edit panel's three previews (b3).
public enum BentoSizeText {
    public static func describe(_ id: ModuleID, _ size: BentoSize) -> String {
        switch (id, size) {
        case (.nachoPet, .small): return "나초 얼굴과 상태 한 줄"
        case (.nachoPet, .wide): return "나초와 한 줄 안내"
        case (.nachoPet, .large): return "나초, 안내와 로그인·대화 버튼"
        case (.systemMonitor, .small): return "CPU·메모리 원 2개"
        case (.systemMonitor, _): return "CPU·메모리·디스크 원과 네트워크 속도"
        case (.computerUse, .small): return "필요한 권한 수"
        case (.computerUse, _): return "권한 목록과 권한 열기 버튼"
        case (.clipboard, .small): return "최근 1개"
        case (.clipboard, .wide): return "최근 3개"
        case (.clipboard, .large): return "최근 8개"
        case (.fileShelf, .small): return "선반 항목 1개와 끌어놓기 자리"
        case (.fileShelf, _): return "선반 항목과 끌어놓기 자리"
        case (.deviceControl, .small): return "볼륨"
        case (.deviceControl, _): return "볼륨·밝기(외장 화면)·출력 장치"
        case (.calendarClock, .small): return "요일·날짜와 다음 일정"
        case (.calendarClock, _): return "요일·날짜와 다음 일정을 크게"
        case (.diskMap, _): return size == .small ? "사용량 막대" : "사용량 막대와 폴더별 몫(검사한 뒤)"
        case (.keepAwake, _): return "남은 시간 링"
        case (.windowSnap, _): return "배치 모양과 단축키"
        case (.captureFloat, _): return "떠 있는 캡처 수와 단축키"
        case (.focusDim, _): return "어둡게 하는 강도"
        case (.menuBar, _): return "접힘 상태"
        case (.appSwitch, _): return "전환 단축키"
        case (.mouseTune, _): return "스크롤 속도와 반전"
        }
    }
}
