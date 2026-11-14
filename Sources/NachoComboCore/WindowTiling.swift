import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// NACHO-146: pure geometry and argument checks for the Window Snap MCP tools: free placement (any rectangles, any
// count), rows x cols grids over one or several displays, "all windows" tiling, 2/3/4 splits, ratios, display moves
// and undo. Nothing here touches AppKit, so it is tested on Linux. Frames are Cocoa rectangles (origin bottom-left)
// inside a display's visible frame; grid cells are listed in the order windows fill them.

/// One window as a tool caller names it: an app (display name, English name or bundle ID, as in `window_layout`) and the
/// window's order in that app, front to back, from 1. `id` is the same thing as one string, `"<app>#<n>"`.
public struct WindowRef: Equatable {
    public var app: String
    public var window: Int
    public init(app: String, window: Int = 1) { self.app = app; self.window = window }
    public var id: String { "\(app)#\(window)" }
}

public enum WindowSplitDirection: String, CaseIterable {
    /// Side by side: columns, left to right.
    case horizontal
    /// Stacked: rows, top to bottom.
    case vertical
    /// Four cells in two rows: top-left, top-right, bottom-left, bottom-right.
    case quadrant
}

/// Presets of `window_arrange_apps`: how the listed apps share a display.
public enum WindowArrangement: String, CaseIterable {
    case grid, columns, rows, quadrants
}

/// Order in which windows fill grid cells.
public enum WindowFill: String, CaseIterable {
    /// Left to right along the top row first.
    case rowMajor = "row_major"
    /// Top to bottom down the left column first.
    case columnMajor = "column_major"
}

/// How a grid uses several displays.
public enum WindowSpan: String, CaseIterable {
    /// Every display gets its own grid; the windows are shared out between them in order.
    case perDisplay = "per_display"
    /// One grid over the area all chosen displays cover together (cells may sit across a display edge).
    case across
}

public enum WindowCoordinateUnit: String, CaseIterable {
    /// 0...1 of the display's usable area (menu bar and Dock excluded). Origin top-left.
    case ratio
    /// Points from the top-left corner of the usable area.
    case pixel
}

public enum WindowTilingError: Error, Equatable {
    case invalid(String)
    public var message: String {
        switch self { case let .invalid(text): return text }
    }
}

public enum WindowTiling {
    /// Technical limit of one call (payload size), not a layout limit: windows per call.
    public static let maxWindows = 200
    public static let maxApps = 200
    public static let maxRowsOrColumns = 100
    public static let maxRatioParts = 4
    public static let maxRatioWeight = 100
    public static let maxDisplays = 16
    public static let undoSteps = 5
    /// A cell with a shorter side than this still gets placed; the result says it may not fit the app's own minimum.
    public static let comfortableSide: CGFloat = 120

    // MARK: arithmetic

    /// Splits `length` into pieces proportional to `weights`, on whole points: the boundaries are integer fractions of
    /// the length and the last piece ends exactly at `length`, so neighbours never overlap or leave a gap.
    public static func divide(_ length: CGFloat, weights: [Int]) -> [(offset: CGFloat, length: CGFloat)] {
        let sum = weights.reduce(0, +)
        guard sum > 0, !weights.isEmpty else { return [] }
        let whole = Int(length.rounded(.down))
        var result: [(CGFloat, CGFloat)] = []
        var cumulative = 0
        var start: CGFloat = 0
        for (index, weight) in weights.enumerated() {
            cumulative += weight
            let end: CGFloat = index == weights.count - 1 ? length : CGFloat(whole * cumulative / sum)
            result.append((start, end - start))
            start = end
        }
        return result
    }

    /// Cells per row of the automatic grid for `count` windows: `ceil(sqrt(n))` columns, the last row may be shorter
    /// (and then its cells are wider). 1 → [1], 2 → [2], 3 → [2,1], 4 → [2,2], 5 → [3,2], 6 → [3,3], 7 → [3,3,1], 9 → [3,3,3].
    public static func gridRows(_ count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var columns = 1
        while columns * columns < count { columns += 1 }
        var rows: [Int] = []
        var left = count
        while left > 0 { rows.append(min(columns, left)); left -= columns }
        return rows
    }

    /// Rows of cells; `shape[i]` is the number of cells of row i (top to bottom). Cells come out row by row.
    private static func rows(_ shape: [Int], in visible: CGRect, gap: CGFloat) -> [CGRect] {
        let heights = divide(visible.height, weights: shape.map { _ in 1 })
        var cells: [CGRect] = []
        for (row, count) in shape.enumerated() {
            let band = heights[row]
            let y = visible.maxY - band.offset - band.length
            for column in divide(visible.width, weights: Array(repeating: 1, count: count)) {
                cells.append(WindowLayout.applyGap(CGRect(x: visible.minX + column.offset, y: y, width: column.length, height: band.length),
                                                   in: visible, gap: gap))
            }
        }
        return cells
    }

    /// A full `rows` x `cols` matrix over `area`, in fill order (row by row or column by column).
    public static func matrix(rows: Int, cols: Int, in area: CGRect, gap: CGFloat = 0, fill: WindowFill = .rowMajor) -> [CGRect] {
        guard rows > 0, cols > 0 else { return [] }
        let byRow = Self.rows(Array(repeating: cols, count: rows), in: area, gap: gap)
        guard fill == .columnMajor else { return byRow }
        return (0..<cols).flatMap { c in (0..<rows).map { r in byRow[r * cols + c] } }
    }

    // MARK: shapes

    /// Automatic grid for `count` windows (any number): `ceil(sqrt(n))` columns, short last row stretched.
    public static func grid(count: Int, in visible: CGRect, gap: CGFloat = 0) -> Result<[CGRect], WindowTilingError> {
        guard (1...maxWindows).contains(count) else { return .failure(.invalid("A grid needs 1 to \(maxWindows) windows.")) }
        return .success(rows(gridRows(count), in: visible, gap: gap))
    }

    /// Grid of `rows` x `cols` (either may be nil, then it follows from the count) in fill order. Used for one display.
    public static func grid(count: Int, rows: Int?, cols: Int?, fill: WindowFill = .rowMajor, in area: CGRect,
                            gap: CGFloat = 0) -> Result<[CGRect], WindowTilingError> {
        guard (1...maxWindows).contains(count) else { return .failure(.invalid("A grid needs 1 to \(maxWindows) windows.")) }
        if rows == nil, cols == nil, fill == .rowMajor { return grid(count: count, in: area, gap: gap) }
        let r: Int, c: Int
        switch (rows, cols) {
        case let (rows?, cols?): r = rows; c = cols
        case let (rows?, nil): r = rows; c = (count + rows - 1) / rows
        case let (nil, cols?): c = cols; r = (count + cols - 1) / cols
        case (nil, nil):
            var columns = 1
            while columns * columns < count { columns += 1 }
            c = columns; r = (count + columns - 1) / columns
        }
        guard r >= 1, c >= 1, r <= maxRowsOrColumns, c <= maxRowsOrColumns else {
            return .failure(.invalid("rows and cols must be from 1 to \(maxRowsOrColumns)."))
        }
        guard r * c >= count else { return .failure(.invalid("\(r) x \(c) has \(r * c) cells for \(count) windows; use more rows or columns.")) }
        return .success(Array(matrix(rows: r, cols: c, in: area, gap: gap, fill: fill).prefix(count)))
    }

    /// Grid over several displays. `areas` are the usable frames of the chosen displays, in the order given.
    /// `perDisplay`: the windows are shared out in order (a full grid per display when rows and cols are given, otherwise
    /// evenly) and each display gets its own grid. `across`: one grid over the bounding box of all displays.
    public static func tile(count: Int, rows: Int?, cols: Int?, fill: WindowFill, span: WindowSpan, areas: [CGRect],
                            gap: CGFloat = 0) -> Result<[CGRect], WindowTilingError> {
        guard !areas.isEmpty else { return .failure(.invalid("There is no display to place the windows on.")) }
        guard (1...maxWindows).contains(count) else { return .failure(.invalid("A grid needs 1 to \(maxWindows) windows.")) }
        if areas.count == 1 || span == .across {
            let area = areas.dropFirst().reduce(areas[0]) { $0.union($1) }
            var c = cols
            if areas.count > 1, rows == nil, cols == nil {
                // Auto shape over several displays: a whole number of columns per display.
                var root = 1
                while root * root < count { root += 1 }
                c = ((root + areas.count - 1) / areas.count) * areas.count
            }
            return grid(count: count, rows: rows, cols: c, fill: fill, in: area, gap: gap)
        }
        var sizes: [Int] = []
        if let rows = rows, let cols = cols {
            var left = count
            for _ in areas { let take = min(left, rows * cols); sizes.append(take); left -= take }
            guard left == 0 else {
                return .failure(.invalid("\(rows) x \(cols) on \(areas.count) display\(areas.count == 1 ? "" : "s") has \(rows * cols * areas.count) cells for \(count) windows."))
            }
        } else {
            for i in areas.indices { sizes.append(count / areas.count + (i < count % areas.count ? 1 : 0)) }
        }
        var cells: [CGRect] = []
        for (index, size) in sizes.enumerated() where size > 0 {
            switch grid(count: size, rows: rows, cols: cols, fill: fill, in: areas[index], gap: gap) {
            case .success(let part): cells += part
            case .failure(let error): return .failure(error)
            }
        }
        return .success(cells)
    }

    /// 2, 3 or 4 equal parts. `quadrant` needs 4 parts.
    public static func split(parts: Int, direction: WindowSplitDirection, in visible: CGRect,
                             gap: CGFloat = 0) -> Result<[CGRect], WindowTilingError> {
        guard (2...4).contains(parts) else { return .failure(.invalid("parts must be 2, 3 or 4.")) }
        switch direction {
        case .horizontal: return .success(rows([parts], in: visible, gap: gap))
        case .vertical: return .success(rows(Array(repeating: 1, count: parts), in: visible, gap: gap))
        case .quadrant:
            guard parts == 4 else { return .failure(.invalid("quadrant needs parts = 4.")) }
            return .success(rows([2, 2], in: visible, gap: gap))
        }
    }

    /// 2…4 parts in the given proportions (70:30 → weights [70, 30]); only horizontal or vertical.
    public static func ratio(weights: [Int], direction: WindowSplitDirection, in visible: CGRect,
                             gap: CGFloat = 0) -> Result<[CGRect], WindowTilingError> {
        guard (2...maxRatioParts).contains(weights.count) else { return .failure(.invalid("ratios needs 2 to \(maxRatioParts) numbers.")) }
        guard weights.allSatisfy({ (1...maxRatioWeight).contains($0) }) else {
            return .failure(.invalid("every ratio must be a whole number from 1 to \(maxRatioWeight)."))
        }
        guard direction != .quadrant else { return .failure(.invalid("ratios split in one direction: horizontal or vertical.")) }
        if direction == .horizontal {
            return .success(divide(visible.width, weights: weights).map {
                WindowLayout.applyGap(CGRect(x: visible.minX + $0.offset, y: visible.minY, width: $0.length, height: visible.height), in: visible, gap: gap)
            })
        }
        return .success(divide(visible.height, weights: weights).map {
            WindowLayout.applyGap(CGRect(x: visible.minX, y: visible.maxY - $0.offset - $0.length, width: visible.width, height: $0.length), in: visible, gap: gap)
        })
    }

    /// How many cells are shorter than `comfortableSide` on a side (apps may refuse to get that small; the result reports it).
    public static func tightCells(_ cells: [CGRect]) -> Int {
        cells.filter { min($0.width, $0.height) < comfortableSide }.count
    }

    // MARK: display numbers

    /// Visible frame of Nacho's 1-based display number (left to right, then top to bottom), or nil.
    public static func visibleFrame(display number: Int, full: [CGRect], visible: [CGRect]) -> CGRect? {
        guard full.count == visible.count, let index = PetDisplays.index(forNumber: number, screens: full) else { return nil }
        return visible[index]
    }
}

// MARK: - free placement

/// One window of `window_place`: where it goes inside a display's usable area, top-left origin.
public struct WindowPlacementItem: Equatable {
    public var ref: WindowRef
    public var display: Int?
    public var x: Double, y: Double, w: Double, h: Double
    public var z: Int?
    public init(ref: WindowRef, display: Int? = nil, x: Double, y: Double, w: Double, h: Double, z: Int? = nil) {
        self.ref = ref; self.display = display; self.x = x; self.y = y; self.w = w; self.h = h; self.z = z
    }
}

public enum WindowPlacement {
    /// Cocoa frame of an item inside `visible`, clamped so the window stays on that display, on whole points.
    /// `clamped` says that the request reached outside the usable area (or was bigger than it).
    public static func frame(of item: WindowPlacementItem, unit: WindowCoordinateUnit, in visible: CGRect) -> (frame: CGRect, clamped: Bool) {
        let sx = unit == .ratio ? Double(visible.width) : 1, sy = unit == .ratio ? Double(visible.height) : 1
        let w = min(Double(visible.width), max(1, (item.w * sx).rounded()))
        let h = min(Double(visible.height), max(1, (item.h * sy).rounded()))
        let x = min(max((item.x * sx).rounded(), 0), Double(visible.width) - w)
        let y = min(max((item.y * sy).rounded(), 0), Double(visible.height) - h)
        let wanted = (x: (item.x * sx).rounded(), y: (item.y * sy).rounded(), w: (item.w * sx).rounded(), h: (item.h * sy).rounded())
        let clamped = abs(wanted.x - x) > 0.5 || abs(wanted.y - y) > 0.5 || abs(wanted.w - w) > 0.5 || abs(wanted.h - h) > 0.5
        return (CGRect(x: visible.minX + CGFloat(x), y: visible.maxY - CGFloat(y) - CGFloat(h), width: CGFloat(w), height: CGFloat(h)), clamped)
    }

    /// Order in which windows are brought to the front: ascending `z`; items without one keep their list position. The
    /// last one ends up on top.
    public static func raiseOrder(_ items: [WindowPlacementItem]) -> [Int] {
        items.indices.sorted {
            let a = items[$0].z ?? $0, b = items[$1].z ?? $1
            return a != b ? a < b : $0 < $1
        }
    }
}

// MARK: - tool requests

public struct WindowTileSpec: Equatable {
    /// nil = every open window of every app (the "whole checkerboard").
    public var windows: [WindowRef]?
    public var rows: Int?
    public var cols: Int?
    public var displays: [Int]?
    public var span: WindowSpan
    public var fill: WindowFill
    public var gap: Int?
}

public enum WindowToolRequest: Equatable {
    case displays
    case tile(WindowTileSpec)
    case place(items: [WindowPlacementItem], unit: WindowCoordinateUnit)
    case split(parts: Int, direction: WindowSplitDirection, windows: [WindowRef], display: Int?)
    case ratio(weights: [Int], direction: WindowSplitDirection, windows: [WindowRef], display: Int?)
    case moveDisplay(windows: [WindowRef], display: Int)
    case arrangeApps(apps: [String], arrangement: WindowArrangement, display: Int?)
    case undo(steps: Int)

    /// The target cells of a request that fits one display (split, ratio, arrange_apps). Tile and place need the display list
    /// and the window count, so they are computed by the app with `WindowTiling.tile` / `WindowPlacement.frame`.
    public func cells(in visible: CGRect, gap: CGFloat) -> Result<[CGRect], WindowTilingError>? {
        switch self {
        case let .split(parts, direction, _, _): return WindowTiling.split(parts: parts, direction: direction, in: visible, gap: gap)
        case let .ratio(weights, direction, _, _): return WindowTiling.ratio(weights: weights, direction: direction, in: visible, gap: gap)
        case let .arrangeApps(apps, arrangement, _):
            switch arrangement {
            case .grid: return WindowTiling.grid(count: apps.count, in: visible, gap: gap)
            case .columns: return .success(WindowTiling.matrix(rows: 1, cols: apps.count, in: visible, gap: gap))
            case .rows: return .success(WindowTiling.matrix(rows: apps.count, cols: 1, in: visible, gap: gap))
            case .quadrants: return WindowTiling.split(parts: 4, direction: .quadrant, in: visible, gap: gap)
            }
        case .displays, .tile, .place, .moveDisplay, .undo: return nil
        }
    }
}

public struct WindowToolProblem: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = "bad parameters: " + message }
}

public enum WindowToolArguments {
    public static let actions = ["displays", "tile", "place", "split", "ratio", "move_display", "arrange_apps", "undo"]

    /// Checks the arguments of one new window tool against closed lists and ranges.
    public static func parse(action: String, _ args: [String: JSONValue]) -> Result<WindowToolRequest, WindowToolProblem> {
        do { return .success(try build(action, args)) } catch let p as WindowToolProblem { return .failure(p) } catch { return .failure(WindowToolProblem("\(error)")) }
    }

    private static func only(_ args: [String: JSONValue], _ allowed: Set<String>) throws {
        let extra = Set(args.keys).subtracting(allowed)
        if !extra.isEmpty { throw WindowToolProblem("unknown field \(extra.sorted().joined(separator: ", "))") }
    }

    private static func int(_ value: JSONValue?, _ name: String, _ range: ClosedRange<Int>) throws -> Int? {
        guard let value = value else { return nil }
        let number: Int
        switch value {
        case .int(let i): number = i
        case .double(let d) where d == d.rounded() && abs(d) < 1e9: number = Int(d)
        default: throw WindowToolProblem("\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        guard range.contains(number) else { throw WindowToolProblem("\(name) must be from \(range.lowerBound) to \(range.upperBound)") }
        return number
    }

    private static func number(_ value: JSONValue?, _ name: String, _ range: ClosedRange<Double>) throws -> Double {
        let n: Double
        switch value {
        case .int(let i)?: n = Double(i)
        case .double(let d)?: n = d
        default: throw WindowToolProblem("\(name) must be a number")
        }
        guard n.isFinite, range.contains(n) else { throw WindowToolProblem("\(name) must be from \(range.lowerBound) to \(range.upperBound)") }
        return n
    }

    private static func choice<T: RawRepresentable & CaseIterable>(_ value: JSONValue?, _ name: String, _ type: T.Type) throws -> T?
        where T.RawValue == String {
        guard let value = value else { return nil }
        guard case .string(let raw) = value, let found = T(rawValue: raw) else {
            throw WindowToolProblem("\(name) must be one of \(T.allCases.map { $0.rawValue }.joined(separator: ", "))")
        }
        return found
    }

    private static func ref(_ o: [String: JSONValue]) throws -> WindowRef {
        var app: String?
        var order = try int(o["window"], "window", 1...20)
        if case .string(let id)? = o["id"] {
            guard o["app"] == nil, o["window"] == nil else { throw WindowToolProblem("give either id or app (+ window), not both") }
            let pieces = id.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, let n = Int(pieces[1]), (1...20).contains(n) else { throw WindowToolProblem("id must look like Safari#1") }
            app = String(pieces[0]); order = n
        } else if case .string(let raw)? = o["app"] { app = raw }
        guard let name = app?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= PetCommands.maxAppNameLength else {
            throw WindowToolProblem("each window needs an app (or id) of 1 to \(PetCommands.maxAppNameLength) characters")
        }
        return WindowRef(app: name, window: order ?? 1)
    }

    private static func windows(_ value: JSONValue?, max: Int) throws -> [WindowRef] {
        guard case .array(let list)? = value else { throw WindowToolProblem("windows must be a list of {app, window}") }
        guard !list.isEmpty, list.count <= max else { throw WindowToolProblem("windows needs 1 to \(max) items") }
        var seen = Set<String>()
        return try list.map { item in
            guard case .object(let o) = item else { throw WindowToolProblem("each window must be an object {app, window}") }
            try only(o, ["app", "window", "id"])
            let r = try ref(o)
            guard seen.insert(r.id.lowercased()).inserted else { throw WindowToolProblem("the same window is listed twice: \(r.id)") }
            return r
        }
    }

    private static func displayList(_ value: JSONValue?) throws -> [Int]? {
        guard let value = value else { return nil }
        guard case .array(let list) = value, !list.isEmpty, list.count <= WindowTiling.maxDisplays else {
            throw WindowToolProblem("displays must list 1 to \(WindowTiling.maxDisplays) display numbers")
        }
        let numbers = try list.map { try int($0, "each display", 1...WindowTiling.maxDisplays)! }
        guard Set(numbers).count == numbers.count else { throw WindowToolProblem("displays lists a display twice") }
        return numbers
    }

    private static func build(_ action: String, _ a: [String: JSONValue]) throws -> WindowToolRequest {
        let displayRange = 1...WindowTiling.maxDisplays
        switch action {
        case "displays":
            try only(a, [])
            return .displays
        case "tile":
            try only(a, ["windows", "all_windows", "rows", "cols", "display", "displays", "span", "fill", "gap"])
            var all = false
            if let v = a["all_windows"] { guard case .bool(let b) = v else { throw WindowToolProblem("all_windows must be true or false") }; all = b }
            if all, a["windows"] != nil { throw WindowToolProblem("give windows or all_windows, not both") }
            if !all, a["windows"] == nil { throw WindowToolProblem("windows (a list) or all_windows: true is required") }
            if a["display"] != nil, a["displays"] != nil { throw WindowToolProblem("give display or displays, not both") }
            let displays = try displayList(a["displays"]) ?? (try int(a["display"], "display", displayRange)).map { [$0] }
            return .tile(WindowTileSpec(windows: all ? nil : try windows(a["windows"], max: WindowTiling.maxWindows),
                                        rows: try int(a["rows"], "rows", 1...WindowTiling.maxRowsOrColumns),
                                        cols: try int(a["cols"], "cols", 1...WindowTiling.maxRowsOrColumns), displays: displays,
                                        span: try choice(a["span"], "span", WindowSpan.self) ?? .perDisplay,
                                        fill: try choice(a["fill"], "fill", WindowFill.self) ?? .rowMajor,
                                        gap: try int(a["gap"], "gap", 0...100)))
        case "place":
            try only(a, ["items", "unit"])
            guard case .array(let list)? = a["items"], !list.isEmpty, list.count <= WindowTiling.maxWindows else {
                throw WindowToolProblem("items must list 1 to \(WindowTiling.maxWindows) windows")
            }
            let unit = try choice(a["unit"], "unit", WindowCoordinateUnit.self) ?? .ratio
            let range: ClosedRange<Double> = unit == .ratio ? -10...10 : -100_000...100_000
            var seen = Set<String>()
            let items: [WindowPlacementItem] = try list.map { raw in
                guard case .object(let o) = raw else { throw WindowToolProblem("each item must be an object {app, x, y, w, h}") }
                try only(o, ["app", "window", "id", "display", "x", "y", "w", "h", "z"])
                let r = try ref(o)
                guard seen.insert(r.id.lowercased()).inserted else { throw WindowToolProblem("the same window is listed twice: \(r.id)") }
                let w = try number(o["w"], "w", 0...range.upperBound), h = try number(o["h"], "h", 0...range.upperBound)
                guard w > 0, h > 0 else { throw WindowToolProblem("w and h must be above 0") }
                return WindowPlacementItem(ref: r, display: try int(o["display"], "display", displayRange),
                                           x: try number(o["x"], "x", range), y: try number(o["y"], "y", range), w: w, h: h,
                                           z: try int(o["z"], "z", -1000...1000))
            }
            return .place(items: items, unit: unit)
        case "split":
            try only(a, ["parts", "direction", "windows", "display"])
            guard let parts = try int(a["parts"], "parts", 2...4) else { throw WindowToolProblem("parts is required (2, 3 or 4)") }
            guard let direction = try choice(a["direction"], "direction", WindowSplitDirection.self) else { throw WindowToolProblem("direction is required") }
            if direction == .quadrant, parts != 4 { throw WindowToolProblem("quadrant needs parts = 4") }
            let list = try windows(a["windows"], max: parts)
            return .split(parts: parts, direction: direction, windows: list, display: try int(a["display"], "display", displayRange))
        case "ratio":
            try only(a, ["ratios", "direction", "windows", "display"])
            guard case .array(let raw)? = a["ratios"], (2...WindowTiling.maxRatioParts).contains(raw.count) else {
                throw WindowToolProblem("ratios must list 2 to \(WindowTiling.maxRatioParts) whole numbers, e.g. [70, 30]")
            }
            let weights = try raw.map { try int($0, "each ratio", 1...WindowTiling.maxRatioWeight)! }
            let direction = try choice(a["direction"], "direction", WindowSplitDirection.self) ?? .horizontal
            if direction == .quadrant { throw WindowToolProblem("direction must be horizontal or vertical for ratios") }
            return .ratio(weights: weights, direction: direction, windows: try windows(a["windows"], max: weights.count),
                          display: try int(a["display"], "display", displayRange))
        case "move_display":
            try only(a, ["windows", "display"])
            guard let display = try int(a["display"], "display", displayRange) else { throw WindowToolProblem("display is required") }
            return .moveDisplay(windows: try windows(a["windows"], max: WindowTiling.maxWindows), display: display)
        case "arrange_apps":
            try only(a, ["apps", "arrangement", "display"])
            guard case .array(let raw)? = a["apps"], (1...WindowTiling.maxApps).contains(raw.count) else {
                throw WindowToolProblem("apps must list 1 to \(WindowTiling.maxApps) app names")
            }
            var apps: [String] = []
            for item in raw {
                guard case .string(let s) = item, !s.trimmingCharacters(in: .whitespaces).isEmpty, s.count <= PetCommands.maxAppNameLength else {
                    throw WindowToolProblem("each app must be a name of 1 to \(PetCommands.maxAppNameLength) characters")
                }
                let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !apps.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { throw WindowToolProblem("the same app is listed twice: \(name)") }
                apps.append(name)
            }
            let arrangement = try choice(a["arrangement"], "arrangement", WindowArrangement.self) ?? .grid
            if arrangement == .columns || arrangement == .rows, apps.count < 2 { throw WindowToolProblem("\(arrangement.rawValue) needs at least 2 apps") }
            if arrangement == .quadrants, apps.count > 4 { throw WindowToolProblem("quadrants takes at most 4 apps") }
            return .arrangeApps(apps: apps, arrangement: arrangement, display: try int(a["display"], "display", displayRange))
        case "undo":
            try only(a, ["steps"])
            return .undo(steps: try int(a["steps"], "steps", 1...WindowTiling.undoSteps) ?? 1)
        default:
            throw WindowToolProblem("unknown window action \(action)")
        }
    }
}

// MARK: - undo

/// Frames of the windows just before a tool moved them. `W` is whatever identifies a window on the Mac (an
/// accessibility element); the stack only keeps order and capacity.
public struct WindowUndoSnapshot<W> {
    public var items: [(window: W, frame: CGRect)]
    public init(items: [(window: W, frame: CGRect)]) { self.items = items }
}

public final class WindowUndoStack<W> {
    public let capacity: Int
    private var snapshots: [WindowUndoSnapshot<W>] = []
    public init(capacity: Int = 10) { self.capacity = max(1, capacity) }

    public var count: Int { snapshots.count }

    /// Remember one placement. An empty one is ignored. The oldest falls out beyond `capacity`.
    public func push(_ snapshot: WindowUndoSnapshot<W>) {
        guard !snapshot.items.isEmpty else { return }
        snapshots.append(snapshot)
        if snapshots.count > capacity { snapshots.removeFirst(snapshots.count - capacity) }
    }

    /// The newest `steps` snapshots, newest first (apply them in this order so the oldest frame wins), removed from the stack.
    public func pop(steps: Int = 1) -> [WindowUndoSnapshot<W>] {
        var taken: [WindowUndoSnapshot<W>] = []
        for _ in 0..<max(0, steps) { if let last = snapshots.popLast() { taken.append(last) } }
        return taken
    }
}
