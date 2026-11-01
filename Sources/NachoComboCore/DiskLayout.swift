import Foundation

/// A rectangle in the map's own coordinates (y grows downward).
public struct MapRect: Equatable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func inset(_ amount: Double) -> MapRect {
        MapRect(x: x + amount, y: y + amount, width: max(0, width - 2 * amount), height: max(0, height - 2 * amount))
    }

    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
}

/// Colors run along one ramp. Each item gets the stretch of the ramp its share of the view covers and its children divide
/// that stretch, so a big folder is many tones rather than one, and the wheel, the blocks, the list and the disk bar agree.
public enum DiskTone {
    /// The stretch of the ramp each item takes, in order. Hidden and free space are not on the ramp.
    static func stretches(_ items: [DiskNode], from start: Double, to end: Double) -> [(start: Double, end: Double)] {
        let total = items.reduce(0.0) { $0 + (isOnRamp($1) ? Double(max(0, $1.size)) : 0) }
        var at = start
        return items.map { item in
            guard isOnRamp(item), total > 0 else { return (at, at) }
            let width = (end - start) * Double(max(0, item.size)) / total
            defer { at += width }
            return (at, at + width)
        }
    }

    private static func isOnRamp(_ node: DiskNode) -> Bool { node.kind != .hidden && node.kind != .free }

    /// Where each item of a list sits on the ramp, 0 to 1.
    public static func tones(of items: [DiskNode]) -> [Double] {
        stretches(items, from: 0, to: 1).map { ($0.start + $0.end) / 2 }
    }
}

/// Largest first, with sums after the real items, then hidden space, then free space.
func mapOrder(_ items: [DiskNode]) -> [DiskNode] {
    func rank(_ node: DiskNode) -> Int {
        switch node.kind {
        case .folder, .file: return 0
        case .smaller: return 1
        case .hidden: return 2
        case .free: return 3
        }
    }
    return items.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.size > $1.size }
}

/// One chip of the wheel. Angles are radians, clockwise from twelve o'clock.
public struct SunburstArc {
    /// nil: items too small to draw, summed up.
    public let node: DiskNode?
    /// 0 is the innermost ring.
    public let ring: Int
    public let start, end: Double
    /// Its place on the color ramp, 0 to 1.
    public let tone: Double

    public var span: Double { end - start }
}

public enum Sunburst {
    /// The wheel of `focus`, `rings` deep. `slices` are extra top-level items (hidden and free space): with them the
    /// whole circle is the whole disk, so what is left shows in the picture itself.
    public static func arcs(focus: DiskNode, slices: [DiskNode] = [], rings: Int, smallestAngle: Double) -> [SunburstArc] {
        var arcs: [SunburstArc] = []
        let top = mapOrder(focus.children + slices)
        let total = top.reduce(0.0) { $0 + Double(max(0, $1.size)) }
        guard total > 0 else { return [] }
        let stretches = DiskTone.stretches(top, from: 0, to: 1)
        var angle = 0.0
        var rest = 0.0
        for (item, stretch) in zip(top, stretches) {
            let span = 2 * Double.pi * Double(max(0, item.size)) / total
            guard span >= smallestAngle else { rest += span; continue }
            arcs.append(SunburstArc(node: item, ring: 0, start: angle, end: angle + span, tone: (stretch.start + stretch.end) / 2))
            if item.isFolder, rings > 1 {
                place(item, from: angle, span: span, ring: 1, rings: rings, stretch: stretch, smallest: smallestAngle, into: &arcs)
            }
            angle += span
        }
        if rest > 0 { arcs.append(SunburstArc(node: nil, ring: 0, start: angle, end: angle + rest, tone: 1)) }
        return arcs
    }

    private static func place(_ folder: DiskNode, from start: Double, span: Double, ring: Int, rings: Int,
                              stretch: (start: Double, end: Double), smallest: Double, into arcs: inout [SunburstArc]) {
        guard folder.size > 0 else { return }
        var angle = start
        var rest = 0.0
        let items = mapOrder(folder.children)
        for (item, tones) in zip(items, DiskTone.stretches(items, from: stretch.start, to: stretch.end)) {
            let itemSpan = span * Double(max(0, item.size)) / Double(folder.size)
            guard itemSpan >= smallest else { rest += itemSpan; continue }
            arcs.append(SunburstArc(node: item, ring: ring, start: angle, end: angle + itemSpan, tone: (tones.start + tones.end) / 2))
            if item.isFolder, ring + 1 < rings {
                place(item, from: angle, span: itemSpan, ring: ring + 1, rings: rings, stretch: tones, smallest: smallest, into: &arcs)
            }
            angle += itemSpan
        }
        if rest > 0 { arcs.append(SunburstArc(node: nil, ring: ring, start: angle, end: angle + rest, tone: stretch.end)) }
    }

    /// The arc under a point given by its distance from the center (in rings, fractional) and its angle.
    public static func arc(in arcs: [SunburstArc], ring: Int, angle: Double) -> SunburstArc? {
        arcs.first { $0.ring == ring && angle >= $0.start && angle < $0.end }
    }
}

/// One block of the map.
public struct TreemapTile {
    /// nil: items too small to draw, summed up.
    public let node: DiskNode?
    public let rect: MapRect
    /// 0 for the items of the shown folder, deeper inside them from there.
    public let depth: Int
    /// A folder drawn as a frame with its items inside, under `headerHeight` of title.
    public let isGroup: Bool
    public let headerHeight: Double
    /// Its place on the color ramp, 0 to 1.
    public let tone: Double
}

public enum Treemap {
    public struct Options {
        public var depth = 3
        public var gap = 1.5
        public var smallestSide = 3.0
        /// Title strips above the groups, per depth.
        public var headers: [Double] = [18, 14]

        public init() {}
    }

    /// `slices` are extra top-level items, as in the wheel: the whole rectangle is then the whole disk.
    public static func tiles(focus: DiskNode, slices: [DiskNode] = [], in rect: MapRect, options: Options = Options()) -> [TreemapTile] {
        var tiles: [TreemapTile] = []
        layOut(focus.children + slices, in: rect, depth: 0, stretch: (0, 1), options: options, into: &tiles)
        return tiles
    }

    private static func layOut(_ items: [DiskNode], in rect: MapRect, depth: Int, stretch: (start: Double, end: Double), options: Options,
                               into tiles: inout [TreemapTile]) {
        let sorted = mapOrder(items.filter { $0.size > 0 })
        let total = sorted.reduce(0.0) { $0 + Double($1.size) }
        guard total > 0, rect.area > 0 else { return }
        let tones = DiskTone.stretches(sorted, from: stretch.start, to: stretch.end)
        // What would come out thinner than `smallestSide` is summed up into one last block.
        let unit = rect.area / total
        let smallestArea = options.smallestSide * options.smallestSide * 4
        let shown = sorted.indices.filter { Double(sorted[$0].size) * unit >= smallestArea }
        let restBytes = sorted.filter { Double($0.size) * unit < smallestArea }.reduce(0.0) { $0 + Double($1.size) }
        var weights = shown.map { Double(sorted[$0].size) * unit }
        if restBytes > 0 { weights.append(restBytes * unit) }
        let rects = squarify(weights, in: rect)
        for (index, frame) in rects.enumerated() {
            guard index < shown.count else {
                tiles.append(TreemapTile(node: nil, rect: frame.inset(options.gap / 2), depth: depth, isGroup: false, headerHeight: 0,
                                         tone: stretch.end))
                continue
            }
            let item = sorted[shown[index]]
            let band = tones[shown[index]]
            let tone = (band.start + band.end) / 2
            let inner = frame.inset(options.gap / 2)
            let header = depth < options.headers.count ? options.headers[depth] : 0
            let contents = contentsFolder(of: item)
            // A group too small for a readable title says more as one block with its name and size.
            let canOpen = item.isFolder && depth + 1 < options.depth && !contents.children.isEmpty
                && inner.width >= 88 && inner.height >= header + 40
            guard canOpen else {
                tiles.append(TreemapTile(node: item, rect: inner, depth: depth, isGroup: false, headerHeight: 0, tone: tone))
                continue
            }
            tiles.append(TreemapTile(node: item, rect: inner, depth: depth, isGroup: true, headerHeight: header, tone: tone))
            let body = MapRect(x: inner.x + 1, y: inner.y + header, width: max(0, inner.width - 2),
                               height: max(0, inner.height - header - 1))
            layOut(contents.children, in: body, depth: depth + 1, stretch: band, options: options, into: &tiles)
        }
    }

    /// A folder that holds next to nothing but one other folder (every app's `Contents`) would use up a level of the map
    /// to say nothing: the blocks show what is inside that folder instead.
    private static func contentsFolder(of folder: DiskNode) -> DiskNode {
        var current = folder
        while true {
            let items = current.children.filter { $0.isItem }
            guard items.count == 1, let only = items.first, only.isFolder, !only.children.isEmpty,
                  Double(only.size) >= Double(current.size) * 0.98 else { return current }
            current = only
        }
    }

    /// Squarified treemap (Bruls, Huizing, van Wijk): `weights` are areas summing to the rectangle's, largest first;
    /// the result is one rectangle per weight, as close to square as the order allows.
    public static func squarify(_ weights: [Double], in rect: MapRect) -> [MapRect] {
        var result: [MapRect] = []
        var remaining = rect
        var index = 0
        while index < weights.count {
            let short = min(remaining.width, remaining.height)
            guard short > 0 else {
                result.append(contentsOf: Array(repeating: MapRect(x: remaining.x, y: remaining.y, width: 0, height: 0),
                                                count: weights.count - index))
                break
            }
            var row: [Double] = [weights[index]]
            var sum = weights[index]
            var next = index + 1
            while next < weights.count {
                let grown = sum + weights[next]
                if worst(row + [weights[next]], sum: grown, side: short) > worst(row, sum: sum, side: short) { break }
                row.append(weights[next])
                sum = grown
                next += 1
            }
            // The row lies along the short side of what is left.
            if remaining.width >= remaining.height {
                let thickness = sum / remaining.height
                var y = remaining.y
                for weight in row {
                    let height = weight / thickness
                    result.append(MapRect(x: remaining.x, y: y, width: thickness, height: height))
                    y += height
                }
                remaining = MapRect(x: remaining.x + thickness, y: remaining.y, width: max(0, remaining.width - thickness),
                                    height: remaining.height)
            } else {
                let thickness = sum / remaining.width
                var x = remaining.x
                for weight in row {
                    let width = weight / thickness
                    result.append(MapRect(x: x, y: remaining.y, width: width, height: thickness))
                    x += width
                }
                remaining = MapRect(x: remaining.x, y: remaining.y + thickness, width: remaining.width,
                                    height: max(0, remaining.height - thickness))
            }
            index = next
        }
        return result
    }

    private static func worst(_ row: [Double], sum: Double, side: Double) -> Double {
        guard let largest = row.max(), let smallest = row.min(), sum > 0, smallest > 0 else { return .infinity }
        let squared = sum * sum, sideSquared = side * side
        return max(sideSquared * largest / squared, squared / (sideSquared * smallest))
    }

    /// The deepest tile under a point; a group's title strip answers for the group.
    public static func tile(in tiles: [TreemapTile], x: Double, y: Double) -> TreemapTile? {
        tiles.last { $0.rect.contains(x: x, y: y) }
    }
}
