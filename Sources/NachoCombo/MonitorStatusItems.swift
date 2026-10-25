import AppKit
import NachoComboCore

/// Content of one monitor status item. Clicks fall through to the status bar button.
final class StatusItemView: NSView {
    let item: MonitorItem
    weak var engine: MonitorEngine?

    init(item: MonitorItem) {
        self.item = item
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { StatusRenderer.draw(item, engine: engine, in: bounds) }
}

/// Compact menu bar renderings. Widths are fixed per item so the menu bar does not jitter.
enum StatusRenderer {
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static let padding: CGFloat = 5
    static let graphBars = 8
    static var graphWidth: CGFloat { CGFloat(graphBars) * 3 - 1 }

    static func width(for item: MonitorItem) -> CGFloat {
        switch item {
        case .cpu: return padding + graphWidth + 4 + Draw.width("100%", valueFont) + padding
        case .memory: return padding + 12 + 4 + Draw.width("100%", valueFont) + padding
        case .disk: return padding + Draw.width("W 999.9M/s", smallFont) + padding
        case .network: return padding + Draw.width("↓ 999.9M/s", smallFont) + padding
        case .sensors: return padding + 9 + 3 + Draw.width("100°", valueFont) + padding
        }
    }

    static func draw(_ item: MonitorItem, engine: MonitorEngine?, in bounds: NSRect) {
        let s = engine?.snapshot
        let midY = bounds.midY
        let text = NSColor.labelColor
        switch item {
        case .cpu:
            let graph = NSRect(x: padding, y: midY - 7, width: graphWidth, height: 14)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: graph, xRadius: 2, yRadius: 2).fill()
            if let engine = engine {
                let user = engine.cpuHistory.recent(graphBars, channel: 0)
                let system = engine.cpuHistory.recent(graphBars, channel: 1)
                for i in 0..<user.count {
                    let x = graph.maxX - CGFloat(user.count - i) * 3 + 1
                    let u = CGFloat((user[i] ?? 0) / 100) * graph.height
                    let sy = CGFloat((system[i] ?? 0) / 100) * graph.height
                    NSColor.systemBlue.setFill()
                    NSRect(x: x, y: graph.maxY - u, width: 2, height: u).fill()
                    NSColor.systemPink.setFill()
                    NSRect(x: x, y: graph.maxY - u - sy, width: 2, height: sy).fill()
                }
            }
            Draw.text(s?.cpu.map { MonitorFormat.percent($0.busy) } ?? "–",
                      in: NSRect(x: graph.maxX + 4, y: 0, width: bounds.width - graph.maxX - 4 - padding, height: bounds.height),
                      font: valueFont, color: text, align: .right)
        case .memory:
            var segments: [(fraction: Double, color: NSColor)] = []
            if let m = s?.memory {
                segments = [(m.fraction(m.app), .systemBlue), (m.fraction(m.wired), .systemPink), (m.fraction(m.compressed), .systemYellow)]
            }
            Draw.ring(center: NSPoint(x: padding + 6, y: midY), radius: 5, lineWidth: 2.5, segments: segments, roundCaps: false)
            Draw.text(s?.memory.map { MonitorFormat.percent($0.usedPercent) } ?? "–",
                      in: NSRect(x: padding + 16, y: 0, width: bounds.width - padding * 2 - 16, height: bounds.height),
                      font: valueFont, color: text, align: .right)
        case .disk:
            twoLines(bounds, top: ("R", .systemPink, s?.diskRead), bottom: ("W", .systemBlue, s?.diskWrite))
        case .network:
            twoLines(bounds, top: ("↑", .systemPink, s?.netUp), bottom: ("↓", .systemBlue, s?.netDown))
        case .sensors:
            if let symbol = NSImage(systemSymbolName: "thermometer", accessibilityDescription: "Temperature") {
                Draw.image(symbol, in: NSRect(x: padding, y: midY - 7, width: 9, height: 14), tint: text)
            }
            Draw.text(s?.cpuTemperature.map { MonitorFormat.temperature($0) } ?? "–°",
                      in: NSRect(x: padding + 12, y: 0, width: bounds.width - padding * 2 - 12, height: bounds.height),
                      font: valueFont, color: text, align: .right)
        }
    }

    private static func twoLines(_ bounds: NSRect, top: (String, NSColor, Double?), bottom: (String, NSColor, Double?)) {
        let midY = bounds.midY
        for (index, line) in [top, bottom].enumerated() {
            let rect = NSRect(x: padding, y: index == 0 ? midY - 10.5 : midY + 0.5, width: bounds.width - padding * 2, height: 10)
            Draw.text(line.0, in: rect, font: smallFont, color: line.1)
            let value = line.2.map { SystemMath.formatRateCompact($0) + "/s" } ?? "–"
            Draw.text(value, in: rect, font: smallFont, color: .labelColor, align: .right)
        }
    }

    /// Debug aid: every item side by side, as the menu bar would show them.
    static func renderStrip(engine: MonitorEngine, items: [MonitorItem], appearance: NSAppearance.Name, to url: URL) -> Bool {
        let height: CGFloat = 24
        let total = items.map { width(for: $0) + 8 }.reduce(0, +)
        let strip = FlippedStrip(frame: NSRect(x: 0, y: 0, width: total, height: height))
        var x: CGFloat = 0
        for item in items {
            let view = StatusItemView(item: item)
            view.engine = engine
            view.frame = NSRect(x: x, y: 0, width: width(for: item), height: height)
            strip.addSubview(view)
            x += width(for: item) + 8
        }
        return MonitorPanelController.renderPNG(strip, size: strip.frame.size, appearance: appearance, to: url)
    }
}

private final class FlippedStrip: NSView {
    override var isFlipped: Bool { true }
}
