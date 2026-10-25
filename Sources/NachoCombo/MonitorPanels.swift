import AppKit
import NachoComboCore

enum PanelAction {
    case activityMonitor, systemInformation, terminal, diskUtility, networkSettings, settings

    var tooltip: String {
        switch self {
        case .activityMonitor: return "Open Activity Monitor"
        case .systemInformation: return "Open System Information"
        case .terminal: return "Open Terminal"
        case .diskUtility: return "Open Disk Utility"
        case .networkSettings: return "Open Network Settings"
        case .settings: return "Nacho Combo Settings"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .activityMonitor: return "com.apple.ActivityMonitor"
        case .systemInformation: return "com.apple.SystemProfiler"
        case .terminal: return "com.apple.Terminal"
        case .diskUtility: return "com.apple.DiskUtility"
        case .networkSettings: return "com.apple.systempreferences"
        case .settings: return nil
        }
    }

    var image: NSImage? {
        if let id = bundleIdentifier {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 22, height: 22)
            return icon
        }
        let symbol = NSImage(systemSymbolName: "gearshape", accessibilityDescription: tooltip)
        symbol?.isTemplate = true
        return symbol
    }
}

/// Hooks a panel needs from its owner.
struct PanelContext {
    var settings: () -> MonitorSettings
    var setRange: (String, ChartRange) -> Void
    var relayout: () -> Void
    var perform: (PanelAction) -> Void
    var lookupPublicIP: () -> Void
}

/// Element tree of a dropdown panel or a hover flyout. Built once when shown, refreshed on every sample.
class MonitorContent {
    let context: PanelContext
    private(set) var root: MonitorRootView!
    weak var engine: MonitorEngine?
    private var needsRelayout = false

    init(context: PanelContext) {
        self.context = context
    }

    func setCards(_ cards: [PanelElement], width: CGFloat = MonitorStyle.panelWidth) {
        root = MonitorRootView(cards: cards, width: width)
    }

    func update(_ engine: MonitorEngine) {
        self.engine = engine
        refresh(engine)
        if needsRelayout {
            needsRelayout = false
            context.relayout()
        }
    }

    /// Subclasses fill their elements from the engine here.
    func refresh(_ engine: MonitorEngine) {}

    func setHidden(_ element: PanelElement, _ hidden: Bool) {
        guard element.isHidden != hidden else { return }
        element.isHidden = hidden
        needsRelayout = true
    }

    func setItems(_ stack: StackElement, _ items: [PanelElement]) {
        stack.setItems(items)
        needsRelayout = true
    }

    func rangeHeader(_ title: String, chart: String) -> HeaderElement {
        HeaderElement(title, range: context.settings().range(for: chart)) { [weak self] range in
            guard let self = self else { return }
            self.context.setRange(chart, range)
            if let engine = self.engine { self.refresh(engine) }
        }
    }

    /// Fills `element` with the chart's selected range of `series` (`channels`: subset, default all).
    func plot(_ element: ChartElement, _ series: TimeSeries, chart: String, channels: [Int]? = nil) {
        element.buckets = series.buckets(span: context.settings().range(for: chart).seconds, count: element.barCount,
                                         now: Date().timeIntervalSince1970, channels: channels)
    }

    func since(_ chart: String) -> Double { Date().timeIntervalSince1970 - context.settings().range(for: chart).seconds }

    func peak(_ series: TimeSeries, channel: Int, chart: String) -> Double {
        series.maximum(channel: channel, since: since(chart)) ?? 0
    }

    static func percent(_ value: Double?) -> String { value.map { MonitorFormat.percent($0) } ?? "–" }
    static func temperature(_ value: Double?) -> String { value.map { MonitorFormat.temperature($0) } ?? "–" }
}

/// Content of one dropdown panel.
class PanelContent: MonitorContent {
    static let processFootnote = "macOS limits this list to your own processes"

    let item: MonitorItem
    /// Cards that open a detail flyout while the pointer rests on them, top to bottom.
    private(set) var hoverTargets: [HoverTarget] = []

    init(item: MonitorItem, context: PanelContext) {
        self.item = item
        super.init(context: context)
    }

    static func make(_ item: MonitorItem, context: PanelContext) -> PanelContent {
        switch item {
        case .cpu: return CPUPanelContent(context: context)
        case .memory: return MemoryPanelContent(context: context)
        case .disk: return DiskPanelContent(context: context)
        case .network: return NetworkPanelContent(context: context)
        case .sensors: return SensorsPanelContent(context: context)
        }
    }

    /// Registers `card` as a hover target and returns it (for use inside `setCards`).
    func hover(_ card: StackElement, _ make: @escaping FlyoutFactory) -> StackElement {
        hoverTargets.append(HoverTarget(card: card, make: make))
        return card
    }

    func toolbar(_ actions: [PanelAction]) -> StackElement {
        let buttons = actions.compactMap { action -> ButtonBarElement.Action? in
            guard let image = action.image else { return nil }
            return ButtonBarElement.Action(image: image, tooltip: action.tooltip) { [weak self] in self?.context.perform(action) }
        }
        return StackElement([ButtonBarElement(actions: buttons)], insets: NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6))
    }

    func processRows(_ groups: [ProcessGroupUsage], values: (ProcessGroupUsage) -> [String]) -> [ProcessListElement.Row] {
        groups.map {
            ProcessListElement.Row(icon: ProcessPresentation.shared.icon(for: $0),
                                   name: ProcessPresentation.shared.name(for: $0), values: values($0))
        }
    }

    func processPlaceholder(_ sampled: Bool) -> String { sampled ? "No active processes" : "Collecting…" }
}

// MARK: - CPU

final class CPUPanelContent: PanelContent {
    private var header: HeaderElement!
    private let chart = ChartElement(style: .stacked, fixedMax: 100) { [MonitorStyle.blue, MonitorStyle.pink] }
    private let legend = PairElement()
    private let cores = CoreGridElement()
    private let efficiencyRow = RowElement("Efficiency Cores", dot: { MonitorStyle.pink })
    private let performanceRow = RowElement("Performance Cores", dot: { MonitorStyle.blue })
    private let processes = ProcessListElement(columns: [], footnote: PanelContent.processFootnote)
    private let gpuHeader = HeaderElement("GPU")
    private let gpuRings = RingsElement(diameter: 56, lineWidth: 5, centerSize: 12)
    private let gpuMemory = RowElement("GPU Memory Used")
    private var gpuCard: StackElement!
    private let load = HeaderElement("Load Average")
    private let uptime = HeaderElement("Uptime")

    init(context: PanelContext) {
        super.init(item: .cpu, context: context)
        header = rangeHeader("CPU", chart: "cpu")
        gpuCard = StackElement([gpuHeader, gpuRings, gpuMemory])
        setCards([
            hover(StackElement([header, chart, legend]), Flyouts.cpu),
            hover(StackElement([cores, efficiencyRow, performanceRow], spacing: 6)) { [weak self] context in
                Flyouts.cores(context, efficiency: self?.engine?.snapshot.efficiencyAverage != nil)
            },
            StackElement([processes]),
            hover(gpuCard, Flyouts.gpu),
            hover(StackElement([load], insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)), Flyouts.load),
            StackElement([uptime], insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)),
            toolbar([.activityMonitor, .systemInformation, .terminal, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        header.detail = [s.cpuMHz.map { MonitorFormat.gigahertz($0) }, s.cpuTemperature.map { MonitorFormat.temperature($0) }]
            .compactMap { $0 }.joined(separator: ", ")
        plot(chart, engine.cpuHistory, chart: "cpu")
        legend.left = .init(color: MonitorStyle.blue, label: "User", value: PanelContent.percent(s.cpu?.user))
        legend.right = .init(color: MonitorStyle.pink, label: "System", value: PanelContent.percent(s.cpu?.system))
        cores.cores = s.cores
        efficiencyRow.value = PanelContent.percent(s.efficiencyAverage)
        setHidden(efficiencyRow, s.efficiencyAverage == nil)
        performanceRow.label = s.efficiencyAverage == nil ? "Core Average" : "Performance Cores"
        performanceRow.value = PanelContent.percent(s.performanceAverage)

        let top = ProcessGrouping.top(s.processes, count: processes.maxRows) { $0.cpuPercent }
        processes.rows = processRows(top) { [String(format: "%.1f%%", $0.cpuPercent)] }
        processes.placeholder = processPlaceholder(s.processesSampled)

        setHidden(gpuCard, s.gpuUtilization == nil)
        if let utilization = s.gpuUtilization {
            var memoryFraction: Double?
            if let used = s.gpuMemoryInUse, let allocated = s.gpuMemoryAllocated, allocated > 0 {
                memoryFraction = Double(used) / Double(allocated)
            }
            let mhz = s.gpuMHz
            gpuRings.rings = [
                .init(segments: [(utilization / 100, MonitorStyle.blue)], center: MonitorFormat.percent(utilization), bottom: "GPU"),
                .init(segments: [(memoryFraction ?? 0, MonitorStyle.blue)], center: PanelContent.percent(memoryFraction.map { $0 * 100 }), bottom: "Memory"),
                .init(segments: [((s.gpuTemperature ?? 0) / 100, MonitorStyle.blue)], center: PanelContent.temperature(s.gpuTemperature), bottom: "Temp"),
                .init(segments: [((mhz ?? 0) / max(1, engine.gpuMaxMHz ?? 1300), MonitorStyle.blue)],
                      center: mhz.map { String(format: "%.2f", $0 / 1000) } ?? "–", bottom: "GHz"),
            ]
            if let used = s.gpuMemoryInUse {
                gpuMemory.value = MonitorFormat.size(Double(used)) + (s.gpuMemoryAllocated.map { " / " + MonitorFormat.size(Double($0)) } ?? "")
            }
            setHidden(gpuMemory, s.gpuMemoryInUse == nil)
        }
        load.trailing = s.loadAverage.isEmpty ? "–" : MonitorFormat.loadAverage(s.loadAverage)
        uptime.trailing = s.uptime.map { MonitorFormat.uptime($0) } ?? "–"
    }
}

// MARK: - Memory

final class MemoryPanelContent: PanelContent {
    private let rings = RingsElement(diameter: 96, lineWidth: 9, centerSize: 21)
    private let appRow = RowElement("App", dot: { MonitorStyle.blue })
    private let wiredRow = RowElement("Wired", dot: { MonitorStyle.pink })
    private let compressedRow = RowElement("Compressed", dot: { MonitorStyle.yellow })
    private let freeRow = RowElement("Free", dot: { MonitorStyle.gray })
    private let processes = ProcessListElement(columns: [], footnote: PanelContent.processFootnote)
    private let pageIn = RowElement("Page Ins")
    private let pageOut = RowElement("Page Outs")
    private let swapHeader = HeaderElement("Swap Used")
    private let swapBar = ProgressElement()

    init(context: PanelContext) {
        super.init(item: .memory, context: context)
        setCards([
            hover(StackElement([rings], insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)), Flyouts.memoryPressure),
            hover(StackElement([appRow, wiredRow, compressedRow, freeRow], spacing: 2), Flyouts.memory),
            StackElement([processes]),
            hover(StackElement([pageIn, pageOut], spacing: 2), Flyouts.paging),
            hover(StackElement([swapHeader, swapBar], spacing: 6), Flyouts.swap),
            toolbar([.activityMonitor, .systemInformation, .terminal, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        if let m = s.memory {
            rings.rings = [
                .init(segments: [((s.pressure ?? 0) / 100, MonitorStyle.pressureColor(level: s.pressureLevel))],
                      center: PanelContent.percent(s.pressure), bottom: "Pressure"),
                .init(segments: [(m.fraction(m.app), MonitorStyle.blue), (m.fraction(m.wired), MonitorStyle.pink),
                                 (m.fraction(m.compressed), MonitorStyle.yellow)],
                      center: MonitorFormat.percent(m.usedPercent), bottom: "Memory", roundCaps: false),
            ]
            appRow.value = MonitorFormat.size(Double(m.app))
            wiredRow.value = MonitorFormat.size(Double(m.wired))
            compressedRow.value = MonitorFormat.size(Double(m.compressed))
            freeRow.value = MonitorFormat.size(Double(m.free))
        }
        let top = ProcessGrouping.top(s.processes, count: processes.maxRows) { Double($0.memory) }
        processes.rows = processRows(top) { [MonitorFormat.size(Double($0.memory))] }
        processes.placeholder = processPlaceholder(s.processesSampled)
        pageIn.value = MonitorFormat.rate(s.pageInRate)
        pageOut.value = MonitorFormat.rate(s.pageOutRate)
        swapHeader.trailing = MonitorFormat.size(Double(s.swapUsed)) + "/" + MonitorFormat.size(Double(s.swapTotal))
        swapBar.fraction = s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) : 0
    }
}

// MARK: - Disk

final class DiskPanelContent: PanelContent {
    private let volume = VolumeElement()
    private var header: HeaderElement!
    private let big = BigValuesElement(left: .init(value: "–", label: "Read", color: { MonitorStyle.pink }),
                                       right: .init(value: "–", label: "Write", color: { MonitorStyle.blue }))
    private let chart = ChartElement(style: .mirrored, minimumScale: 256 * 1024) { [MonitorStyle.pink, MonitorStyle.blue] }
    private let peaks = PairElement()
    private let totals = PairElement()
    private let processes = ProcessListElement(columns: ["R", "W"], footnote: PanelContent.processFootnote)

    init(context: PanelContext) {
        super.init(item: .disk, context: context)
        header = rangeHeader("Disk Activity", chart: "disk")
        setCards([
            hover(StackElement([volume], insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10))) { VolumeFlyout(context: $0) },
            hover(StackElement([header, big, chart, peaks, totals]), Flyouts.diskActivity),
            StackElement([processes]),
            toolbar([.activityMonitor, .systemInformation, .terminal, .diskUtility, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        if let v = s.volume {
            volume.name = v.name
            volume.percent = v.usedPercent
            volume.subtitle = MonitorFormat.size(Double(v.available), decimal: true) + " available of "
                + MonitorFormat.size(Double(v.total), decimal: true)
        }
        big.left.value = s.diskRead.map { MonitorFormat.rate($0) } ?? "–"
        big.right.value = s.diskWrite.map { MonitorFormat.rate($0) } ?? "–"
        plot(chart, engine.diskHistory, chart: "disk")
        peaks.left = .init(color: nil, label: "Peak Read", value: MonitorFormat.rate(peak(engine.diskHistory, channel: 0, chart: "disk")))
        peaks.right = .init(color: nil, label: "Peak Write", value: MonitorFormat.rate(peak(engine.diskHistory, channel: 1, chart: "disk")))
        totals.left = .init(color: nil, label: "Data Read", value: MonitorFormat.size(Double(s.diskReadTotal)))
        totals.right = .init(color: nil, label: "Data Written", value: MonitorFormat.size(Double(s.diskWriteTotal)))
        let top = ProcessGrouping.top(s.processes, count: processes.maxRows) { $0.diskRead + $0.diskWrite }
        processes.rows = processRows(top) { [MonitorFormat.compact($0.diskRead), MonitorFormat.compact($0.diskWrite)] }
        processes.placeholder = processPlaceholder(s.processesSampled)
    }
}

// MARK: - Network

final class NetworkPanelContent: PanelContent {
    private var header: HeaderElement!
    private let big = BigValuesElement(left: .init(value: "–", label: "Upload", color: { MonitorStyle.pink }),
                                       right: .init(value: "–", label: "Download", color: { MonitorStyle.blue }))
    private let chart = ChartElement(style: .mirrored, minimumScale: 16 * 1024) { [MonitorStyle.pink, MonitorStyle.blue] }
    private let peaks = PairElement()
    private let totals = PairElement()
    private let interfacesCard = StackElement([], spacing: 2)
    private let publicHeader = HeaderElement("Public IP Address")
    private let publicRow = ActionRowElement()
    private let addressCard = StackElement([], spacing: 2)
    private let processes = ProcessListElement(columns: ["↑", "↓"])
    private var interfaceSignature: [String] = ["-"]

    init(context: PanelContext) {
        super.init(item: .network, context: context)
        header = rangeHeader("Network", chart: "network")
        publicRow.onPress = context.lookupPublicIP
        setCards([
            hover(StackElement([header, big, chart, peaks, totals]), Flyouts.network),
            interfacesCard,
            StackElement([publicHeader, publicRow], spacing: 3),
            addressCard,
            StackElement([processes]),
            toolbar([.activityMonitor, .systemInformation, .terminal, .networkSettings, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        big.left.value = s.netUp.map { MonitorFormat.rate($0) } ?? "–"
        big.right.value = s.netDown.map { MonitorFormat.rate($0) } ?? "–"
        plot(chart, engine.networkHistory, chart: "network")
        peaks.left = .init(color: nil, label: "Peak Up", value: MonitorFormat.rate(peak(engine.networkHistory, channel: 0, chart: "network")))
        peaks.right = .init(color: nil, label: "Peak Down", value: MonitorFormat.rate(peak(engine.networkHistory, channel: 1, chart: "network")))
        totals.left = .init(color: nil, label: "Uploaded", value: MonitorFormat.size(Double(s.netUpTotal)))
        totals.right = .init(color: nil, label: "Downloaded", value: MonitorFormat.size(Double(s.netDownTotal)))

        let signature = s.interfaces.map { "\($0.bsdName)|\($0.isActive)|\($0.displayName)|\($0.addresses.joined(separator: ","))" }
        if signature != interfaceSignature {
            interfaceSignature = signature
            rebuildInterfaces(s.interfaces)
        }

        switch s.publicIP {
        case .idle:
            publicRow.text = context.settings().publicIPLookup ? "Waiting to look up" : "Auto lookup off (cloudflare.com)"
            publicRow.bold = false
            setButton("Look Up")
            publicHeader.trailing = ""
        case .loading:
            publicRow.text = "Looking up…"
            publicRow.bold = false
            setButton(nil)
        case let .value(ip, country):
            publicRow.text = ip
            publicRow.bold = true
            setButton("Refresh")
            publicHeader.trailing = country.map { PublicIPParser.flag(forCountryCode: $0) } ?? ""
        case .failed:
            publicRow.text = "Lookup failed"
            publicRow.bold = false
            setButton("Retry")
        }

        let top = ProcessGrouping.top(s.networkProcesses, count: processes.maxRows) { $0.netIn + $0.netOut }
        processes.rows = processRows(top) { [MonitorFormat.compact($0.netOut, zero: "0K"), MonitorFormat.compact($0.netIn, zero: "0K")] }
        processes.placeholder = processPlaceholder(s.networkProcessesSampled)
    }

    private func setButton(_ title: String?) {
        if publicRow.buttonTitle != title { publicRow.buttonTitle = title }
    }

    private func rebuildInterfaces(_ interfaces: [InterfaceInfo]) {
        var rows: [PanelElement] = interfaces.map { interface in
            let row = RowElement(interface.displayName, value: interface.isActive ? "Connected" : "Not connected")
            row.icon = NSImage(systemSymbolName: interface.kind == .wifi ? "wifi" : "network", accessibilityDescription: nil)
            row.tintIcon = true
            row.dimmed = !interface.isActive
            return row
        }
        if rows.isEmpty { rows = [NoteElement("No network interfaces")] }
        setItems(interfacesCard, rows)

        var addressRows: [PanelElement] = [HeaderElement("IP Addresses")]
        for interface in interfaces where interface.isActive {
            for address in interface.addresses {
                let row = RowElement(address, value: interface.bsdName)
                row.dimmed = false
                addressRows.append(row)
            }
        }
        if addressRows.count == 1 { addressRows.append(NoteElement("No IPv4 address")) }
        setItems(addressCard, addressRows)
    }
}

// MARK: - Sensors

final class SensorsPanelContent: PanelContent {
    private let rings = RingsElement(diameter: 80, lineWidth: 7, centerSize: 17)
    private let note = NoteElement("")
    private let temperatureHeader = HeaderElement("Temperatures")
    private let temperatureCard = StackElement([], spacing: 1)
    private var temperatureRows: [RowElement] = []
    private var powerHeader: HeaderElement!
    private let powerChart = ChartElement(style: .stacked, height: 54, minimumScale: 5) { [MonitorStyle.blue] }
    private let powerRow = RowElement("Total Power")
    private var powerCard: StackElement!
    private let fanCard = StackElement([], spacing: 1)
    private var fanRows: [RowElement] = []

    init(context: PanelContext) {
        super.init(item: .sensors, context: context)
        powerHeader = rangeHeader("Power", chart: "power")
        powerCard = StackElement([powerHeader, powerChart, powerRow])
        note.isHidden = true
        temperatureCard.setItems([temperatureHeader])
        setCards([
            hover(StackElement([rings, note], insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))) { [weak self] context in
                Flyouts.temperatures(context, fans: !(self?.engine?.snapshot.fans.isEmpty ?? true))
            },
            temperatureCard,
            hover(powerCard, Flyouts.power),
            hover(fanCard, Flyouts.fans),
            toolbar([.activityMonitor, .systemInformation, .terminal, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        let fanAverage = s.fans.isEmpty ? nil : s.fans.map { $0.percent }.reduce(0, +) / Double(s.fans.count)
        let rpmAverage = s.fans.isEmpty ? nil : s.fans.map { $0.rpm }.reduce(0, +) / Double(s.fans.count)
        rings.rings = [
            .init(segments: [((s.cpuTemperature ?? 0) / 100, MonitorStyle.blue)], center: PanelContent.temperature(s.cpuTemperature),
                  top: "CPU", bottom: s.cpuMHz.map { String(format: "%.2fGHz", $0 / 1000) } ?? " "),
            .init(segments: [((s.gpuTemperature ?? 0) / 100, MonitorStyle.blue)], center: PanelContent.temperature(s.gpuTemperature),
                  top: "GPU", bottom: s.gpuMHz.map { String(format: "%.2fGHz", $0 / 1000) } ?? " "),
            .init(segments: [((fanAverage ?? 0) / 100, MonitorStyle.blue)], center: PanelContent.percent(fanAverage),
                  top: "Fans", bottom: rpmAverage.map { MonitorFormat.grouped(Int($0.rounded())) } ?? "None"),
        ]
        if !s.smcAvailable {
            note.text = "Sensors unavailable: no access to the SMC"
        } else if !s.sensorsReady {
            note.text = "Finding sensors…"
        }
        setHidden(note, s.smcAvailable && s.sensorsReady)

        if temperatureRows.count != s.sensors.count {
            temperatureRows = s.sensors.map { RowElement($0.label) }
            setItems(temperatureCard, [temperatureHeader] + temperatureRows)
        }
        for (row, sensor) in zip(temperatureRows, s.sensors) {
            row.label = sensor.label
            row.value = PanelContent.temperature(sensor.value)
            row.gauge = (sensor.value ?? 0) / 100
        }
        setHidden(temperatureCard, s.sensors.isEmpty)

        plot(powerChart, engine.powerHistory, chart: "power")
        powerRow.value = s.power.map { MonitorFormat.watts($0) } ?? "–"
        setHidden(powerCard, s.power == nil && engine.powerHistory.latest(channel: 0) == nil)

        if fanRows.count != s.fans.count {
            fanRows = s.fans.map { RowElement($0.label) }
            setItems(fanCard, [HeaderElement("Fans")] + fanRows)
        }
        for (row, fan) in zip(fanRows, s.fans) {
            row.value = MonitorFormat.rpm(fan.rpm)
            row.gauge = fan.percent / 100
        }
        setHidden(fanCard, s.fans.isEmpty)
    }
}
