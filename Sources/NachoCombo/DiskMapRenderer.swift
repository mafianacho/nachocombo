import AppKit
import NachoComboCore

/// The map's colors. One ramp through the box (maize, habanero, salsa, pickled onion, blue corn, jalapeño, guac): an item
/// takes the part of the ramp its share of the view covers, and goes a little deeper toward the outside. By Last Change
/// colors run from guac (touched today) over the board's brown to salsa (untouched for years).
enum DiskPalette {
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    static let families: [NSColor] = [0xFFC43D, 0xFF9440, 0xF0654A, 0xD86CC6, 0xA98BF0, 0x6F8FF4, 0x35B996, 0x6FC765, 0xB7D65A]
        .map { rgb($0) }
    static let smaller = rgb(0x4A3A2D)
    static let hidden = rgb(0xBFA889)
    static let free = Brand.boardGuac

    static func color(tone: Double, depth: Int) -> NSColor {
        let position = CGFloat(max(0, min(1, tone))) * CGFloat(families.count - 1)
        let index = min(families.count - 2, Int(position))
        let base = families[index].blended(withFraction: position - CGFloat(index), of: families[index + 1]) ?? families[index]
        guard depth > 0, let c = base.usingColorSpace(.sRGB) else { return base }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        c.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let step = CGFloat(min(depth, 5))
        return NSColor(hue: hue, saturation: saturation * (1 - 0.07 * step), brightness: brightness * (1 - 0.055 * step), alpha: 1)
    }

    private static let heatStops: [(NSColor, CGFloat)] = [(rgb(0x2FA45C), 0), (rgb(0x6C8F4A), 0.3), (rgb(0x5A4A3C), 0.55),
                                                          (rgb(0xB0472F), 0.8), (rgb(0xE5432C), 1)]

    static func heat(_ value: Double) -> NSColor {
        let v = CGFloat(max(0, min(1, value)))
        for index in 1..<heatStops.count where v <= heatStops[index].1 {
            let (from, start) = heatStops[index - 1], (to, end) = heatStops[index]
            return from.blended(withFraction: (v - start) / (end - start), of: to) ?? to
        }
        return heatStops[heatStops.count - 1].0
    }

    static func ink(on color: NSColor) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return Brand.boardInk }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.56 ? Brand.onNacho : Brand.boardInk
    }
}

/// One picture of a folder at one size: its layout, its drawing and what is under a point. Used by the window (drawn
/// once into a bitmap, with hover and selection on top) and by the gallery picture.
final class DiskMapRenderer {
    enum Hit: Equatable {
        case hub
        case node(DiskNode)
        /// Items too small to draw, summed up.
        case sum
        case nothing

        static func == (a: Hit, b: Hit) -> Bool {
            switch (a, b) {
            case (.hub, .hub), (.sum, .sum), (.nothing, .nothing): return true
            case (.node(let x), .node(let y)): return x === y
            default: return false
            }
        }
    }

    let focus: DiskNode
    let slices: [DiskNode]
    let style: DiskMapStyle
    let coloring: DiskColoring
    let size: NSSize
    let now: Date

    static let rings = 5
    private static let ringWeights: [CGFloat] = [1, 0.84, 0.7, 0.58, 0.48]
    private static let legendHeight: CGFloat = 26

    private var arcs: [SunburstArc] = []
    private var radii: [(inner: CGFloat, outer: CGFloat)] = []
    private var tiles: [TreemapTile] = []
    private(set) var center = NSPoint.zero
    private(set) var hubRadius: CGFloat = 0

    init(focus: DiskNode, slices: [DiskNode], style: DiskMapStyle, coloring: DiskColoring, size: NSSize, now: Date = Date()) {
        self.focus = focus
        self.slices = slices
        self.style = style
        self.coloring = coloring
        self.size = size
        self.now = now
        switch style {
        case .sunburst: layOutSunburst()
        case .blocks: layOutBlocks()
        }
    }

    // MARK: layout

    private func layOutSunburst() {
        center = NSPoint(x: size.width / 2, y: size.height / 2)
        let outer = max(60, min(size.width, size.height) / 2 - 10)
        hubRadius = outer * 0.21
        let unit = (outer - hubRadius) / DiskMapRenderer.ringWeights.reduce(0, +)
        var inner = hubRadius
        radii = DiskMapRenderer.ringWeights.map { weight in
            defer { inner += weight * unit }
            return (inner, inner + weight * unit)
        }
        // Half a point along the outer edge is the least that still shows.
        arcs = Sunburst.arcs(focus: focus, slices: slices, rings: DiskMapRenderer.rings, smallestAngle: 1.4 / outer)
    }

    private var hasLegend: Bool { coloring == .age }

    private func layOutBlocks() {
        let height = size.height - (hasLegend ? DiskMapRenderer.legendHeight : 0)
        tiles = Treemap.tiles(focus: focus, slices: slices, in: MapRect(x: 0, y: 0, width: Double(size.width), height: Double(height)))
    }

    // MARK: colors

    static func color(of node: DiskNode?, tone: Double, depth: Int, coloring: DiskColoring, now: Date) -> NSColor {
        guard let node = node else { return DiskPalette.smaller }
        switch node.kind {
        case .smaller: return DiskPalette.smaller
        case .hidden: return DiskPalette.hidden
        case .free: return DiskPalette.free
        case .file, .folder: break
        }
        if coloring == .age { return DiskPalette.heat(DiskColoring.ageHeat(modified: node.modified, now: now)) }
        return DiskPalette.color(tone: tone, depth: depth)
    }

    private func color(of node: DiskNode?, tone: Double, depth: Int) -> NSColor {
        DiskMapRenderer.color(of: node, tone: tone, depth: depth, coloring: coloring, now: now)
    }

    // MARK: drawing

    func draw() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch style {
        case .sunburst: drawSunburst(context)
        case .blocks: drawBlocks(context)
        }
        if hasLegend { drawAgeLegend() }
    }

    private func drawAgeLegend() {
        let y = size.height - 12
        Stage.text("TODAY", at: NSPoint(x: 0, y: y), font: Brand.mono(9), color: Brand.boardMute)
        let bar = NSRect(x: 40, y: y - 4, width: 120, height: 8)
        let stops = stride(from: 0.0, through: 1.0, by: 0.1).map { DiskPalette.heat($0) }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).addClip()
        NSGradient(colors: stops)?.draw(in: bar, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        Stage.text("2 YEARS AGO OR MORE", at: NSPoint(x: 168, y: y), font: Brand.mono(9), color: Brand.boardMute)
    }

    private func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    /// A rounded chip between two radii. Angles run clockwise from twelve o'clock in a y-down space.
    private func chip(_ start: Double, _ end: Double, inner: CGFloat, outer: CGFloat, corner: CGFloat, gap: CGFloat) -> CGPath {
        let middle = (inner + outer) / 2
        let inset = Double(gap / 2 / middle)
        var a0 = start + inset, a1 = end - inset
        if a1 <= a0 { a0 = start; a1 = end }
        let thickness = outer - inner - gap
        let top = outer - gap / 2, bottom = inner + gap / 2
        let length = CGFloat(a1 - a0) * bottom
        // Well under half the inner edge: if the corners met, rounding could flip an arc the long way round the wheel.
        let c = min(corner, thickness / 2, length * 0.4)
        let outerStep = Double(c / top), innerStep = Double(c / bottom)
        let path = CGMutablePath()
        func screen(_ angle: Double) -> CGFloat { CGFloat(angle - .pi / 2) }
        guard c >= 0.5, a1 - innerStep > a0 + innerStep, a1 - outerStep > a0 + outerStep else {
            path.addArc(center: center, radius: top, startAngle: screen(a0), endAngle: screen(a1), clockwise: false)
            path.addArc(center: center, radius: bottom, startAngle: screen(a1), endAngle: screen(a0), clockwise: true)
            path.closeSubpath()
            return path
        }
        path.move(to: point(bottom + c, a0))
        path.addLine(to: point(top - c, a0))
        path.addQuadCurve(to: point(top, a0 + outerStep), control: point(top, a0))
        path.addArc(center: center, radius: top, startAngle: screen(a0 + outerStep), endAngle: screen(a1 - outerStep), clockwise: false)
        path.addQuadCurve(to: point(top - c, a1), control: point(top, a1))
        path.addLine(to: point(bottom + c, a1))
        path.addQuadCurve(to: point(bottom, a1 - innerStep), control: point(bottom, a1))
        path.addArc(center: center, radius: bottom, startAngle: screen(a1 - innerStep), endAngle: screen(a0 + innerStep), clockwise: true)
        path.addQuadCurve(to: point(bottom + c, a0), control: point(bottom, a0))
        path.closeSubpath()
        return path
    }

    /// Hidden and free space reach further out than one ring, so what is left is a clear wedge of the wheel.
    private func isWedge(_ arc: SunburstArc) -> Bool { arc.node?.kind == .free || arc.node?.kind == .hidden }

    private func path(of arc: SunburstArc) -> CGPath {
        let ring = radii[arc.ring]
        if isWedge(arc) {
            return chip(arc.start, arc.end, inner: radii[0].inner, outer: radii[2].outer, corner: 8, gap: 2)
        }
        return chip(arc.start, arc.end, inner: ring.inner, outer: ring.outer, corner: CGFloat(6 - min(arc.ring, 3)), gap: 1.6)
    }

    private func drawSunburst(_ context: CGContext) {
        for arc in arcs {
            let shape = path(of: arc)
            let color = self.color(of: arc.node, tone: arc.tone, depth: arc.ring)
            switch arc.node?.kind {
            case .free?:
                DiskMapRenderer.fillOpenSpace(shape, in: context)
            case .hidden?:
                DiskMapRenderer.hatch(shape, color: DiskPalette.hidden, in: context)
            default:
                context.addPath(shape)
                context.setFillColor(color.cgColor)
                context.fillPath()
                drawLabel(of: arc, on: color)
            }
        }
        for arc in arcs where isWedge(arc) { drawWedgeLabel(of: arc) }
        context.setFillColor(Brand.board2.cgColor)
        context.setStrokeColor(Brand.boardLine.cgColor)
        context.setLineWidth(1)
        let hub = CGRect(x: center.x - hubRadius + 3, y: center.y - hubRadius + 3, width: 2 * hubRadius - 6, height: 2 * hubRadius - 6)
        context.fillEllipse(in: hub)
        context.strokeEllipse(in: hub)
    }

    /// The name along the chip, upright on both halves of the wheel. Only when it really fits.
    private func drawLabel(of arc: SunburstArc, on color: NSColor) {
        guard arc.ring <= 2, let node = arc.node, node.isItem, let context = NSGraphicsContext.current?.cgContext else { return }
        let ring = radii[arc.ring]
        let radius = (ring.inner + ring.outer) / 2
        let thickness = ring.outer - ring.inner
        let font = Brand.body(arc.ring == 0 ? 12 : 10.5, weight: .semibold)
        let text = node.name as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: DiskPalette.ink(on: color)]
        let measured = text.size(withAttributes: attributes)
        let width = measured.width
        let room = CGFloat(arc.span) * radius - 12
        guard width <= room else { return }
        // A straight line on a curve: its ends must stay on the chip.
        let halfChord = min(width / 2, radius)
        let sag = radius - sqrt(radius * radius - halfChord * halfChord)
        guard measured.height + 2 * sag + 4 <= thickness else { return }
        let middle = (arc.start + arc.end) / 2
        let upsideDown = middle > .pi / 2 && middle < 3 * .pi / 2
        let position = point(radius, middle)
        context.saveGState()
        context.translateBy(x: position.x, y: position.y)
        context.rotate(by: CGFloat(upsideDown ? middle + .pi : middle))
        text.draw(at: NSPoint(x: -width / 2, y: -measured.height / 2), withAttributes: attributes)
        context.restoreGState()
    }

    private func drawWedgeLabel(of arc: SunburstArc) {
        guard let node = arc.node else { return }
        let free = node.kind == .free
        let inner = radii[0].inner, outer = radii[2].outer
        let radius = (inner + outer) / 2 + 6
        // Small pictures and thin wedges go without: the number at the top of the map says it anyway.
        guard CGFloat(arc.span) * radius >= 74, outer - inner >= 64 else { return }
        let middle = point(radius, (arc.start + arc.end) / 2)
        let tint = free ? DiskPalette.free : Brand.boardInk
        let number = NSAttributedString(string: DiskFormat.size(node.size).uppercased(), attributes: [
            .font: Brand.sign(free ? 22 : 15), .foregroundColor: tint, .kern: 0.4])
        let word = NSAttributedString(string: free ? "FREE" : "HIDDEN", attributes: [
            .font: Brand.mono(free ? 10 : 9), .foregroundColor: tint.withAlphaComponent(0.85), .kern: 1])
        let n = number.size(), w = word.size()
        word.draw(at: NSPoint(x: middle.x - w.width / 2, y: middle.y - (n.height + w.height) / 2))
        number.draw(at: NSPoint(x: middle.x - n.width / 2, y: middle.y - (n.height + w.height) / 2 + w.height))
    }

    /// Free space: open ground, a soft tint and a dashed edge, nothing that reads as "filled".
    static func fillOpenSpace(_ shape: CGPath, in context: CGContext) {
        context.addPath(shape)
        context.setFillColor(DiskPalette.free.withAlphaComponent(0.1).cgColor)
        context.fillPath()
        context.saveGState()
        context.addPath(shape)
        context.setStrokeColor(DiskPalette.free.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1.2)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.strokePath()
        context.restoreGState()
    }

    /// Hidden space: stripes, something is there but it cannot be looked into.
    static func hatch(_ shape: CGPath, color: NSColor, in context: CGContext) {
        context.addPath(shape)
        context.setFillColor(color.withAlphaComponent(0.07).cgColor)
        context.fillPath()
        context.saveGState()
        context.addPath(shape)
        context.clip()
        let box = shape.boundingBoxOfPath
        context.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
        context.setLineWidth(1.4)
        var x = box.minX - box.height
        while x < box.maxX {
            context.move(to: CGPoint(x: x, y: box.maxY))
            context.addLine(to: CGPoint(x: x + box.height, y: box.minY))
            x += 7
        }
        context.strokePath()
        context.restoreGState()
        context.addPath(shape)
        context.setStrokeColor(color.withAlphaComponent(0.45).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    private static func rect(_ r: MapRect) -> NSRect {
        NSRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    private func corner(_ depth: Int) -> CGFloat { CGFloat(max(2, 6 - depth * 2)) }

    private func tilePath(_ tile: TreemapTile) -> CGPath {
        let r = DiskMapRenderer.rect(tile.rect)
        let c = min(corner(tile.depth), r.width / 2, r.height / 2)
        return CGPath(roundedRect: r, cornerWidth: c, cornerHeight: c, transform: nil)
    }

    private func drawBlocks(_ context: CGContext) {
        for tile in tiles {
            let shape = tilePath(tile)
            let color = self.color(of: tile.node, tone: tile.tone, depth: tile.depth)
            switch tile.node?.kind {
            case .free?: DiskMapRenderer.fillOpenSpace(shape, in: context)
            case .hidden?: DiskMapRenderer.hatch(shape, color: DiskPalette.hidden, in: context)
            default:
                if tile.isGroup {
                    context.addPath(shape)
                    context.setFillColor(color.withAlphaComponent(tile.depth == 0 ? 0.2 : 0.16).cgColor)
                    context.fillPath()
                } else {
                    context.addPath(shape)
                    context.setFillColor(color.cgColor)
                    context.fillPath()
                }
            }
            if tile.isGroup { drawGroupTitle(tile, tint: color) } else { drawTileLabel(tile, on: color) }
        }
    }

    private func drawGroupTitle(_ tile: TreemapTile, tint: NSColor) {
        guard let node = tile.node else { return }
        let r = DiskMapRenderer.rect(tile.rect)
        let strip = NSRect(x: r.minX + 6, y: r.minY, width: r.width - 12, height: CGFloat(tile.headerHeight))
        let font = Brand.mono(tile.depth == 0 ? 10 : 8.5)
        let sizeText = DiskFormat.size(node.size)
        let sizeWidth = Draw.width(sizeText, font) + 2
        let ink = tile.depth == 0 ? Brand.boardInk : Brand.boardInk.withAlphaComponent(0.8)
        Draw.text(node.name.uppercased(), in: NSRect(x: strip.minX, y: strip.minY, width: max(0, strip.width - sizeWidth - 6), height: strip.height),
                  font: font, color: ink)
        if strip.width > sizeWidth + 30 {
            Draw.text(sizeText, in: NSRect(x: strip.maxX - sizeWidth, y: strip.minY, width: sizeWidth, height: strip.height),
                      font: font, color: Brand.boardMute, align: .right)
        }
    }

    /// A block reads like a price tag: the name small on top, the size as the big number.
    private func drawTileLabel(_ tile: TreemapTile, on color: NSColor) {
        let full = DiskMapRenderer.rect(tile.rect)
        let r = full.insetBy(dx: full.width < 60 ? 4 : 6, dy: 4)
        guard r.width >= 14, r.height >= 13 else { return }
        var ink: NSColor
        var title: String
        let number: String
        switch tile.node?.kind {
        case .free?: ink = DiskPalette.free; title = "FREE"; number = DiskFormat.size(tile.node?.size ?? 0)
        case .hidden?: ink = Brand.boardInk; title = "HIDDEN"; number = DiskFormat.size(tile.node?.size ?? 0)
        case nil: ink = Brand.boardMute; title = "…"; number = ""
        default:
            ink = DiskPalette.ink(on: color)
            title = tile.node?.name ?? ""
            number = DiskFormat.size(tile.node?.size ?? 0)
        }
        if tile.node?.kind == .smaller { ink = Brand.boardMute; title = "Smaller" }
        let big = max(11, min(46, min(r.width / 4.6, r.height / 2.4)))
        let small = max(9.5, min(13, big * 0.55))
        let titleFont = Brand.body(small, weight: .semibold)
        let titleHeight = ceil(titleFont.ascender - titleFont.descender)
        let bigFont = Brand.sign(big)
        let numberHeight = ceil(bigFont.ascender - bigFont.descender)
        if r.height >= titleHeight + numberHeight * 0.85, r.width >= 34, !number.isEmpty {
            Draw.text(title, in: NSRect(x: r.minX, y: r.minY, width: r.width, height: titleHeight), font: titleFont, color: ink)
            Draw.text(number, in: NSRect(x: r.minX, y: r.minY + titleHeight - 1, width: r.width, height: numberHeight), font: bigFont, color: ink)
        } else {
            Draw.text(title, in: NSRect(x: r.minX, y: r.minY, width: r.width, height: min(r.height, titleHeight)), font: titleFont, color: ink)
        }
    }

    // MARK: asking

    func hit(_ p: NSPoint) -> Hit {
        switch style {
        case .sunburst:
            let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
            let distance = CGFloat((dx * dx + dy * dy).squareRoot())
            if distance < hubRadius { return .hub }
            var angle = atan2(dx, -dy)
            if angle < 0 { angle += 2 * .pi }
            if let wedge = arcs.first(where: { isWedge($0) && angle >= $0.start && angle < $0.end }), distance <= radii[2].outer {
                return wedge.node.map { .node($0) } ?? .nothing
            }
            guard let ring = radii.firstIndex(where: { distance >= $0.inner && distance < $0.outer }),
                  let arc = Sunburst.arc(in: arcs, ring: ring, angle: angle) else { return .nothing }
            return arc.node.map { .node($0) } ?? .sum
        case .blocks:
            guard let tile = Treemap.tile(in: tiles, x: Double(p.x), y: Double(p.y)) else { return .nothing }
            return tile.node.map { .node($0) } ?? .sum
        }
    }

    /// The node's outline in this picture; nil when it is not drawn.
    func outline(of node: DiskNode) -> CGPath? {
        switch style {
        case .sunburst: return arcs.first { $0.node === node }.map { path(of: $0) }
        case .blocks: return tiles.first { $0.node === node }.map { tilePath($0) }
        }
    }

    /// How many pieces the picture has, for the diagnostics.
    var drawnCount: Int { style == .sunburst ? arcs.count : tiles.count }
}
