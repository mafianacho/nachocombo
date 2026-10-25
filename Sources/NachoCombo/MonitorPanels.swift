import AppKit
import NachoComboCore

enum PanelAction {
    case activityMonitor, systemInformation, terminal, diskUtility, networkSettings, settings

    var tooltip: String {
        switch self {
        case .activityMonitor: return "활성 상태 보기 열기"
        case .systemInformation: return "시스템 정보 열기"
        case .terminal: return "터미널 열기"
        case .diskUtility: return "디스크 유틸리티 열기"
        case .networkSettings: return "네트워크 설정 열기"
        case .settings: return "Nacho Combo 설정"
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

/// Content of one dropdown panel. Built once when the panel opens, refreshed on every sample.
class PanelContent {
    static let processFootnote = "macOS 권한상 내 계정의 프로세스만 집계됩니다"

    let item: MonitorItem
    let context: PanelContext
    private(set) var root: PanelRootView!
    weak var engine: MonitorEngine?
    private var needsRelayout = false

    init(item: MonitorItem, context: PanelContext) {
        self.item = item
        self.context = context
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

    func setCards(_ cards: [PanelElement]) { root = PanelRootView(cards: cards) }

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

    func buckets(_ series: TimeSeries, chart: String) -> [[Double]?] {
        series.buckets(span: context.settings().range(for: chart).seconds, count: ChartElement.barCount,
                       now: Date().timeIntervalSince1970)
    }

    func peak(_ series: TimeSeries, channel: Int, chart: String) -> Double {
        series.maximum(channel: channel, since: Date().timeIntervalSince1970 - context.settings().range(for: chart).seconds) ?? 0
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

    func processPlaceholder(_ sampled: Bool) -> String { sampled ? "활동 중인 프로세스가 없습니다" : "수집 중…" }

    static func percent(_ value: Double?) -> String { value.map { MonitorFormat.percent($0) } ?? "–" }
    static func temperature(_ value: Double?) -> String { value.map { MonitorFormat.temperature($0) } ?? "–" }
}

// MARK: - CPU

final class CPUPanelContent: PanelContent {
    private var header: HeaderElement!
    private let chart = ChartElement(style: .stacked, fixedMax: 100) { [MonitorStyle.blue, MonitorStyle.pink] }
    private let legend = PairElement()
    private let cores = CoreGridElement()
    private let efficiencyRow = RowElement("효율 코어", dot: { MonitorStyle.pink })
    private let performanceRow = RowElement("성능 코어", dot: { MonitorStyle.blue })
    private let processes = ProcessListElement(columns: [], footnote: PanelContent.processFootnote)
    private let gpuHeader = HeaderElement("GPU")
    private let gpuRings = RingsElement(diameter: 56, lineWidth: 5, centerSize: 12)
    private let gpuMemory = RowElement("GPU 메모리 사용")
    private var gpuCard: StackElement!
    private let load = HeaderElement("평균 부하")
    private let uptime = HeaderElement("컴퓨터 가동시간")

    init(context: PanelContext) {
        super.init(item: .cpu, context: context)
        header = rangeHeader("CPU", chart: "cpu")
        gpuCard = StackElement([gpuHeader, gpuRings, gpuMemory])
        setCards([
            StackElement([header, chart, legend]),
            StackElement([cores, efficiencyRow, performanceRow], spacing: 6),
            StackElement([processes]),
            gpuCard,
            StackElement([load], insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)),
            StackElement([uptime], insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)),
            toolbar([.activityMonitor, .systemInformation, .terminal, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        header.detail = [s.cpuMHz.map { MonitorFormat.gigahertz($0) }, s.cpuTemperature.map { MonitorFormat.temperature($0) }]
            .compactMap { $0 }.joined(separator: ", ")
        chart.buckets = buckets(engine.cpuHistory, chart: "cpu")
        legend.left = .init(color: MonitorStyle.blue, label: "사용자", value: PanelContent.percent(s.cpu?.user))
        legend.right = .init(color: MonitorStyle.pink, label: "시스템", value: PanelContent.percent(s.cpu?.system))
        cores.cores = s.cores
        efficiencyRow.value = PanelContent.percent(s.efficiencyAverage)
        setHidden(efficiencyRow, s.efficiencyAverage == nil)
        performanceRow.label = s.efficiencyAverage == nil ? "코어 평균" : "성능 코어"
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
                .init(segments: [(memoryFraction ?? 0, MonitorStyle.blue)], center: PanelContent.percent(memoryFraction.map { $0 * 100 }), bottom: "메모리"),
                .init(segments: [((s.gpuTemperature ?? 0) / 100, MonitorStyle.blue)], center: PanelContent.temperature(s.gpuTemperature), bottom: "온도"),
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
    private let appRow = RowElement("앱", dot: { MonitorStyle.blue })
    private let wiredRow = RowElement("와이어드", dot: { MonitorStyle.pink })
    private let compressedRow = RowElement("압축됨", dot: { MonitorStyle.yellow })
    private let freeRow = RowElement("여유", dot: { MonitorStyle.gray })
    private let processes = ProcessListElement(columns: [], footnote: PanelContent.processFootnote)
    private let pageIn = RowElement("페이지 입력")
    private let pageOut = RowElement("페이지 출력")
    private let swapHeader = HeaderElement("사용된 스왑 공간")
    private let swapBar = ProgressElement()

    init(context: PanelContext) {
        super.init(item: .memory, context: context)
        setCards([
            StackElement([rings], insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)),
            StackElement([appRow, wiredRow, compressedRow, freeRow], spacing: 2),
            StackElement([processes]),
            StackElement([pageIn, pageOut], spacing: 2),
            StackElement([swapHeader, swapBar], spacing: 6),
            toolbar([.activityMonitor, .systemInformation, .terminal, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        if let m = s.memory {
            rings.rings = [
                .init(segments: [((s.pressure ?? 0) / 100, MonitorStyle.pressureColor(level: s.pressureLevel))],
                      center: PanelContent.percent(s.pressure), bottom: "압력"),
                .init(segments: [(m.fraction(m.app), MonitorStyle.blue), (m.fraction(m.wired), MonitorStyle.pink),
                                 (m.fraction(m.compressed), MonitorStyle.yellow)],
                      center: MonitorFormat.percent(m.usedPercent), bottom: "메모리", roundCaps: false),
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
    private let big = BigValuesElement(left: .init(value: "–", label: "읽기", color: { MonitorStyle.pink }),
                                       right: .init(value: "–", label: "쓰기", color: { MonitorStyle.blue }))
    private let chart = ChartElement(style: .mirrored, minimumScale: 256 * 1024) { [MonitorStyle.pink, MonitorStyle.blue] }
    private let peaks = PairElement()
    private let totals = PairElement()
    private let processes = ProcessListElement(columns: ["R", "W"], footnote: PanelContent.processFootnote)

    init(context: PanelContext) {
        super.init(item: .disk, context: context)
        header = rangeHeader("디스크 활성 상태", chart: "disk")
        setCards([
            StackElement([volume], insets: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)),
            StackElement([header, big, chart, peaks, totals]),
            StackElement([processes]),
            toolbar([.activityMonitor, .systemInformation, .terminal, .diskUtility, .settings]),
        ])
    }

    override func refresh(_ engine: MonitorEngine) {
        let s = engine.snapshot
        if let v = s.volume {
            volume.name = v.name
            volume.percent = v.usedPercent
            volume.subtitle = MonitorFormat.size(Double(v.available), decimal: true) + " 사용 가능 / "
                + MonitorFormat.size(Double(v.total), decimal: true)
        }
        big.left.value = s.diskRead.map { MonitorFormat.rate($0) } ?? "–"
        big.right.value = s.diskWrite.map { MonitorFormat.rate($0) } ?? "–"
        chart.buckets = buckets(engine.diskHistory, chart: "disk")
        peaks.left = .init(color: nil, label: "최고 읽기", value: MonitorFormat.rate(peak(engine.diskHistory, channel: 0, chart: "disk")))
        peaks.right = .init(color: nil, label: "최고 쓰기", value: MonitorFormat.rate(peak(engine.diskHistory, channel: 1, chart: "disk")))
        totals.left = .init(color: nil, label: "데이터 읽기", value: MonitorFormat.size(Double(s.diskReadTotal)))
        totals.right = .init(color: nil, label: "데이터 쓰기", value: MonitorFormat.size(Double(s.diskWriteTotal)))
        let top = ProcessGrouping.top(s.processes, count: processes.maxRows) { $0.diskRead + $0.diskWrite }
        processes.rows = processRows(top) { [MonitorFormat.compact($0.diskRead), MonitorFormat.compact($0.diskWrite)] }
        processes.placeholder = processPlaceholder(s.processesSampled)
    }
}

// MARK: - Network

final class NetworkPanelContent: PanelContent {
    private var header: HeaderElement!
    private let big = BigValuesElement(left: .init(value: "–", label: "업로드", color: { MonitorStyle.pink }),
                                       right: .init(value: "–", label: "다운로드", color: { MonitorStyle.blue }))
    private let chart = ChartElement(style: .mirrored, minimumScale: 16 * 1024) { [MonitorStyle.pink, MonitorStyle.blue] }
    private let peaks = PairElement()
    private let totals = PairElement()
    private let interfacesCard = StackElement([], spacing: 2)
    private let publicHeader = HeaderElement("공용 IP 주소")
    private let publicRow = ActionRowElement()
    private let addressCard = StackElement([], spacing: 2)
    private let processes = ProcessListElement(columns: ["↑", "↓"])
    private var interfaceSignature: [String] = ["-"]

    init(context: PanelContext) {
        super.init(item: .network, context: context)
        header = rangeHeader("네트워크", chart: "network")
        publicRow.onPress = context.lookupPublicIP
        setCards([
            StackElement([header, big, chart, peaks, totals]),
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
        chart.buckets = buckets(engine.networkHistory, chart: "network")
        peaks.left = .init(color: nil, label: "최고 업로드", value: MonitorFormat.rate(peak(engine.networkHistory, channel: 0, chart: "network")))
        peaks.right = .init(color: nil, label: "최고 다운로드", value: MonitorFormat.rate(peak(engine.networkHistory, channel: 1, chart: "network")))
        totals.left = .init(color: nil, label: "부팅 후 ↑", value: MonitorFormat.size(Double(s.netUpTotal)))
        totals.right = .init(color: nil, label: "부팅 후 ↓", value: MonitorFormat.size(Double(s.netDownTotal)))

        let signature = s.interfaces.map { "\($0.bsdName)|\($0.isActive)|\($0.displayName)|\($0.addresses.joined(separator: ","))" }
        if signature != interfaceSignature {
            interfaceSignature = signature
            rebuildInterfaces(s.interfaces)
        }

        switch s.publicIP {
        case .idle:
            publicRow.text = context.settings().publicIPLookup ? "확인 대기 중" : "자동 조회 꺼짐 (cloudflare.com에 요청)"
            publicRow.bold = false
            setButton("확인")
            publicHeader.trailing = ""
        case .loading:
            publicRow.text = "확인 중…"
            publicRow.bold = false
            setButton(nil)
        case let .value(ip, country):
            publicRow.text = ip
            publicRow.bold = true
            setButton("다시 확인")
            publicHeader.trailing = country.map { PublicIPParser.flag(forCountryCode: $0) } ?? ""
        case .failed:
            publicRow.text = "확인하지 못했습니다"
            publicRow.bold = false
            setButton("다시 시도")
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
            let row = RowElement(interface.displayName, value: interface.isActive ? "연결됨" : "연결 안 됨")
            row.icon = NSImage(systemSymbolName: interface.kind == .wifi ? "wifi" : "network", accessibilityDescription: nil)
            row.tintIcon = true
            row.dimmed = !interface.isActive
            return row
        }
        if rows.isEmpty { rows = [NoteElement("연결된 네트워크 인터페이스가 없습니다")] }
        setItems(interfacesCard, rows)

        var addressRows: [PanelElement] = [HeaderElement("IP 주소")]
        for interface in interfaces where interface.isActive {
            for address in interface.addresses {
                let row = RowElement(address, value: interface.bsdName)
                row.dimmed = false
                addressRows.append(row)
            }
        }
        if addressRows.count == 1 { addressRows.append(NoteElement("IPv4 주소 없음")) }
        setItems(addressCard, addressRows)
    }
}

// MARK: - Sensors

final class SensorsPanelContent: PanelContent {
    private let rings = RingsElement(diameter: 80, lineWidth: 7, centerSize: 17)
    private let note = NoteElement("")
    private let temperatureHeader = HeaderElement("온도")
    private let temperatureCard = StackElement([], spacing: 1)
    private var temperatureRows: [RowElement] = []
    private var powerHeader: HeaderElement!
    private let powerChart = ChartElement(style: .stacked, height: 54, minimumScale: 5) { [MonitorStyle.blue] }
    private let powerRow = RowElement("총 전력")
    private var powerCard: StackElement!
    private let fanCard = StackElement([], spacing: 1)
    private var fanRows: [RowElement] = []

    init(context: PanelContext) {
        super.init(item: .sensors, context: context)
        powerHeader = rangeHeader("전원", chart: "power")
        powerCard = StackElement([powerHeader, powerChart, powerRow])
        note.isHidden = true
        temperatureCard.setItems([temperatureHeader])
        setCards([
            StackElement([rings, note], insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)),
            temperatureCard,
            powerCard,
            fanCard,
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
                  top: "팬", bottom: rpmAverage.map { MonitorFormat.grouped(Int($0.rounded())) } ?? "없음"),
        ]
        if !s.smcAvailable {
            note.text = "SMC에 접근할 수 없어 센서를 표시하지 못합니다"
        } else if !s.sensorsReady {
            note.text = "센서를 찾는 중…"
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

        powerChart.buckets = buckets(engine.powerHistory, chart: "power")
        powerRow.value = s.power.map { MonitorFormat.watts($0) } ?? "–"
        setHidden(powerCard, s.power == nil && engine.powerHistory.latest(channel: 0) == nil)

        if fanRows.count != s.fans.count {
            fanRows = s.fans.map { RowElement($0.label) }
            setItems(fanCard, [HeaderElement("팬")] + fanRows)
        }
        for (row, fan) in zip(fanRows, s.fans) {
            row.value = MonitorFormat.rpm(fan.rpm)
            row.gauge = fan.percent / 100
        }
        setHidden(fanCard, s.fans.isEmpty)
    }
}
