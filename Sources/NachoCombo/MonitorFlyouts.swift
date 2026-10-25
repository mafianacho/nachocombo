import AppKit
import NachoComboCore

typealias FlyoutFactory = (PanelContext) -> FlyoutContent

/// A panel card that opens a detail flyout beside the panel while the pointer rests on it.
struct HoverTarget {
    let card: StackElement
    let make: FlyoutFactory
}

/// Detail view shown beside the panel (iStat-style hover window).
class FlyoutContent: MonitorContent {
    /// Main section: the flyout itself is the background, so no card fill and slim insets.
    static func main(_ items: [PanelElement]) -> StackElement {
        StackElement(items, spacing: 6, insets: MonitorStyle.flyoutInsets, card: false)
    }
}

/// Large history chart with its own range menu. Alternative metrics sit behind a title menu.
final class ChartFlyout: FlyoutContent {
    enum Legend {
        case hidden
        /// Period average per channel: "● 사용자 평균 12%".
        case averages([String])
        /// Period peak per channel: "● 최고 읽기 13.0 MB/초".
        case peaks([String])
        /// One channel: period average and peak.
        case averageAndPeak
    }

    struct Metric {
        var title: String
        var series: (MonitorEngine) -> TimeSeries
        var channels: [Int]
        var colors: () -> [NSColor] = { [MonitorStyle.blue] }
        /// Top of the scale; nil scales to the data (at least `minimumScale`).
        var fixedMax: (MonitorEngine) -> Double? = { _ in nil }
        var minimumScale: Double = 1
        var format: (Double) -> String
        var legend: Legend = .averageAndPeak
    }

    /// Metric picked per chart, kept for this app session.
    private static var chosen: [String: Int] = [:]

    private let chartKey: String
    private let metrics: [Metric]
    private var metric: Metric
    private let chart: ChartElement
    private let legend = PairElement()
    private let refreshFooter: ((MonitorEngine) -> Void)?

    init(context: PanelContext, chart key: String, style: ChartElement.Style = .stacked, height: CGFloat = 140,
         metrics: [Metric], footer: [PanelElement] = [], refreshFooter: ((MonitorEngine) -> Void)? = nil) {
        let index = min(ChartFlyout.chosen[key] ?? 0, metrics.count - 1)
        chartKey = key
        self.metrics = metrics
        metric = metrics[index]
        chart = ChartElement(style: style, height: height, width: MonitorStyle.flyoutContentWidth,
                             minimumScale: metric.minimumScale, colors: metric.colors)
        self.refreshFooter = refreshFooter
        super.init(context: context)
        let header = rangeHeader(metric.title, chart: key)
        if metrics.count > 1 {
            header.setOptions(metrics.map { $0.title }, selected: index) { [weak self] in self?.select($0) }
        }
        setCards([FlyoutContent.main([header, chart, legend])] + footer, width: MonitorStyle.flyoutWidth)
    }

    private func select(_ index: Int) {
        ChartFlyout.chosen[chartKey] = index
        metric = metrics[index]
        chart.colors = metric.colors
        chart.minimumScale = metric.minimumScale
        if let engine = engine { refresh(engine) }
    }

    override func refresh(_ engine: MonitorEngine) {
        let m = metric
        let series = m.series(engine)
        chart.fixedMax = m.fixedMax(engine)
        plot(chart, series, chart: chartKey, channels: m.channels)

        let start = since(chartKey)
        let colors = m.colors()
        let mean = { series.mean(channel: $0, since: start) }
        let peak = { series.maximum(channel: $0, since: start) }
        /// Legend entry of the index-th charted channel.
        func item(_ index: Int, _ label: String, dot: Bool = true, _ reduce: (Int) -> Double?) -> PairElement.Item? {
            guard index < m.channels.count else { return nil }
            return .init(color: dot && index < colors.count ? colors[index] : nil, label: label,
                         value: reduce(m.channels[index]).map(m.format) ?? "–")
        }
        switch m.legend {
        case .hidden:
            break
        case .averages(let labels):
            legend.left = labels.first.flatMap { item(0, $0 + " 평균", mean) }
            legend.right = labels.dropFirst().first.flatMap { item(1, $0 + " 평균", mean) }
        case .peaks(let labels):
            legend.left = labels.first.flatMap { item(0, "최고 " + $0, peak) }
            legend.right = labels.dropFirst().first.flatMap { item(1, "최고 " + $0, peak) }
        case .averageAndPeak:
            legend.left = item(0, "평균", dot: false, mean)
            legend.right = item(0, "최고", dot: false, peak)
        }
        if case .hidden = m.legend { setHidden(legend, true) } else { setHidden(legend, false) }
        refreshFooter?(engine)
    }
}

/// Startup volume as a large ring (used / purgeable / free) plus SSD health from the NVMe SMART log.
final class VolumeFlyout: FlyoutContent {
    private let donut = DonutElement()
    private let health = RowElement("SSD 건강")
    private let temperature = RowElement("온도")
    private var footer: StackElement!

    override init(context: PanelContext) {
        super.init(context: context)
        donut.icon = NSWorkspace.shared.icon(forFile: "/")
        footer = StackElement([health, temperature], spacing: 2)
        setCards([FlyoutContent.main([donut]), footer], width: 220)
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        if let v = s.volume, v.total > 0 {
            let total = Double(v.total)
            func size(_ bytes: Int64) -> String { MonitorFormat.size(Double(bytes), decimal: true) }
            donut.parts = [
                .init(label: "사용됨", value: size(v.used), fraction: Double(v.used) / total, color: { MonitorStyle.blue }),
                .init(label: "제거 가능", value: size(v.purgeable), fraction: Double(v.purgeable) / total, color: { MonitorStyle.pink }),
                .init(label: "여유", value: size(v.free), fraction: Double(v.free) / total, color: { MonitorStyle.gray }, arc: false),
            ]
        }
        health.value = s.ssd.map { "\($0.healthPercent)%" } ?? "–"
        temperature.value = MonitorContent.temperature(s.ssd?.temperature)
        setHidden(footer, s.ssd == nil)
    }
}

/// Flyouts of the panel cards. Each chart keeps its own range ("flyout.*" keys in the settings).
enum Flyouts {
    typealias Metric = ChartFlyout.Metric

    private static let percent: (Double) -> String = { MonitorFormat.percent($0) }
    private static let hundred: (MonitorEngine) -> Double? = { _ in 100 }
    private static let temperature: (Double) -> String = { MonitorFormat.temperature($0) }
    private static let fanSpeed = Metric(title: "팬 속도", series: { $0.fanHistory }, channels: [0], minimumScale: 1000,
                                         format: { MonitorFormat.rpm($0) })

    // CPU panel

    static func cpu(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.cpu", metrics: [
            Metric(title: "CPU", series: { $0.cpuHistory }, channels: [0, 1], colors: { [MonitorStyle.blue, MonitorStyle.pink] },
                   fixedMax: hundred, format: percent, legend: .averages(["사용자", "시스템"])),
        ])
    }

    static func cores(_ context: PanelContext, efficiency: Bool) -> FlyoutContent {
        var metrics = [Metric(title: efficiency ? "성능 코어" : "코어 평균", series: { $0.coreHistory }, channels: [0],
                              fixedMax: hundred, format: percent)]
        if efficiency {
            metrics.append(Metric(title: "효율 코어", series: { $0.coreHistory }, channels: [1], colors: { [MonitorStyle.pink] },
                                  fixedMax: hundred, format: percent))
        }
        return ChartFlyout(context: context, chart: "flyout.cores", metrics: metrics)
    }

    static func gpu(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.gpu", metrics: [
            Metric(title: "프로세서", series: { $0.gpuHistory }, channels: [0], fixedMax: hundred, format: percent),
            Metric(title: "메모리", series: { $0.gpuHistory }, channels: [1], fixedMax: hundred, format: percent),
            Metric(title: "온도", series: { $0.temperatureHistory }, channels: [1], minimumScale: 100, format: temperature),
            Metric(title: "클럭", series: { $0.gpuHistory }, channels: [2], fixedMax: { $0.gpuMaxMHz }, minimumScale: 1000,
                   format: { MonitorFormat.gigahertz($0) }),
        ])
    }

    static func load(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.load", metrics: [("1분", 0), ("5분", 1), ("15분", 2)].map { name, channel in
            Metric(title: "\(name) 평균 부하", series: { $0.loadHistory }, channels: [channel], format: { String(format: "%.2f", $0) })
        })
    }

    // Memory panel

    static func memoryPressure(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.memoryPressure", metrics: [
            Metric(title: "메모리 압력", series: { $0.memoryHistory }, channels: [1], fixedMax: hundred, format: percent),
            Metric(title: "메모리 사용량", series: { $0.memoryHistory }, channels: [0], fixedMax: hundred, format: percent),
        ])
    }

    static func memory(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.memory", metrics: [
            Metric(title: "메모리", series: { $0.memoryHistory }, channels: [2, 3, 4],
                   colors: { [MonitorStyle.blue, MonitorStyle.pink, MonitorStyle.yellow] }, fixedMax: hundred, format: percent,
                   legend: .hidden),
        ])
    }

    static func paging(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.paging", style: .mirrored, metrics: [
            Metric(title: "페이지 입출력", series: { $0.pagingHistory }, channels: [0, 1],
                   colors: { [MonitorStyle.pink, MonitorStyle.blue] }, minimumScale: 64 * 1024,
                   format: { MonitorFormat.rate($0) }, legend: .peaks(["입력", "출력"])),
        ])
    }

    static func swap(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.swap", metrics: [
            Metric(title: "사용된 스왑 공간", series: { $0.swapHistory }, channels: [0],
                   fixedMax: { $0.snapshot.swapTotal > 0 ? Double($0.snapshot.swapTotal) : nil }, minimumScale: 1_048_576,
                   format: { MonitorFormat.size($0) }),
        ])
    }

    // Disk panel

    static func diskActivity(_ context: PanelContext) -> FlyoutContent {
        let totals = PairElement()
        return ChartFlyout(context: context, chart: "flyout.disk", style: .mirrored, metrics: [
            Metric(title: "디스크 활성 상태", series: { $0.diskHistory }, channels: [0, 1],
                   colors: { [MonitorStyle.pink, MonitorStyle.blue] }, minimumScale: 256 * 1024,
                   format: { MonitorFormat.rate($0) }, legend: .peaks(["읽기", "쓰기"])),
        ], footer: [StackElement([totals])]) { engine in
            totals.left = .init(color: nil, label: "데이터 읽기", value: MonitorFormat.size(Double(engine.snapshot.diskReadTotal)))
            totals.right = .init(color: nil, label: "데이터 쓰기", value: MonitorFormat.size(Double(engine.snapshot.diskWriteTotal)))
        }
    }

    // Network panel

    static func network(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.network", style: .mirrored, height: 110, metrics: [
            Metric(title: "네트워크", series: { $0.networkHistory }, channels: [0, 1],
                   colors: { [MonitorStyle.pink, MonitorStyle.blue] }, minimumScale: 16 * 1024,
                   format: { MonitorFormat.rate($0) }, legend: .peaks(["업로드", "다운로드"])),
        ])
    }

    // Sensors panel

    static func temperatures(_ context: PanelContext, fans: Bool) -> FlyoutContent {
        var metrics = [
            Metric(title: "CPU 온도", series: { $0.temperatureHistory }, channels: [0], minimumScale: 100, format: temperature),
            Metric(title: "GPU 온도", series: { $0.temperatureHistory }, channels: [1], minimumScale: 100, format: temperature),
        ]
        if fans { metrics.append(fanSpeed) }
        return ChartFlyout(context: context, chart: "flyout.sensors", metrics: metrics)
    }

    static func power(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.power", metrics: [
            Metric(title: "전원", series: { $0.powerHistory }, channels: [0], minimumScale: 5, format: { MonitorFormat.watts($0) }),
        ])
    }

    static func fans(_ context: PanelContext) -> FlyoutContent {
        ChartFlyout(context: context, chart: "flyout.fans", metrics: [fanSpeed])
    }
}
