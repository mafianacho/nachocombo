import Foundation
import NachoComboCore

struct CoreLoad: Equatable {
    var busy: Double
    var efficiency: Bool
}

struct SensorValue: Equatable {
    var label: String
    var group: SensorGroup
    var value: Double?
}

struct FanReading: Equatable {
    var label: String
    var rpm: Double
    var percent: Double
}

enum PublicIPState: Equatable {
    case idle
    case loading
    case value(ip: String, country: String?)
    case failed(String)
}

/// Latest values of every metric. Optional = not available on this Mac (or not sampled yet).
struct MonitorSnapshot {
    // CPU
    var cpu: CPUUsage?
    var cores: [CoreLoad] = []
    var efficiencyAverage: Double?
    var performanceAverage: Double?
    var cpuMHz: Double?
    var loadAverage: [Double] = []
    var uptime: TimeInterval?
    // GPU
    var gpuUtilization: Double?
    var gpuMemoryInUse: UInt64?
    var gpuMemoryAllocated: UInt64?
    var gpuMHz: Double?
    var gpuMemoryPercent: Double? {
        guard let used = gpuMemoryInUse, let allocated = gpuMemoryAllocated, allocated > 0 else { return nil }
        return Double(used) / Double(allocated) * 100
    }
    // Memory
    var memory: MemoryBreakdown?
    var pressure: Double?
    var pressureLevel = 1
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pageInRate: Double = 0
    var pageOutRate: Double = 0
    // Disk
    var diskRead: Double?
    var diskWrite: Double?
    var diskReadTotal: UInt64 = 0
    var diskWriteTotal: UInt64 = 0
    var volume: VolumeInfo?
    var ssd: SMARTHealth?
    // Network
    var netUp: Double?
    var netDown: Double?
    var netUpTotal: UInt64 = 0
    var netDownTotal: UInt64 = 0
    var interfaces: [InterfaceInfo] = []
    var publicIP: PublicIPState = .idle
    // Sensors
    var smcAvailable = true
    var sensorsReady = false
    var sensors: [SensorValue] = []
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var fans: [FanReading] = []
    var power: Double?
    // Battery (nil on Macs without one)
    var battery: BatteryInfo?
    // Processes (only while a panel that shows them is open)
    var processes: [ProcessGroupUsage] = []
    var processesSampled = false
    var networkProcesses: [ProcessGroupUsage] = []
    var networkProcessesSampled = false
}

/// Samples every metric on a 2 s timer and keeps 24 h of history for the charts.
/// Expensive extras (per-process stats, nettop, interface list, public IP) run only while the
/// matching panel is open (`focus`).
final class MonitorEngine {
    static let interval: TimeInterval = 2
    static let historyCapacity = 43_200  // 24 h at 2 s
    static let publicIPEndpoint = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    let cpuHistory = TimeSeries(channels: 2, capacity: historyCapacity)       // user, system %
    let coreHistory = TimeSeries(channels: 2, capacity: historyCapacity)      // performance, efficiency core average %
    let loadHistory = TimeSeries(channels: 3, capacity: historyCapacity)      // 1, 5, 15 min load average
    let gpuHistory = TimeSeries(channels: 3, capacity: historyCapacity)       // utilization %, memory %, MHz
    let memoryHistory = TimeSeries(channels: 5, capacity: historyCapacity)    // used, pressure, app, wired, compressed %
    let swapHistory = TimeSeries(channels: 1, capacity: historyCapacity)      // used bytes
    let pagingHistory = TimeSeries(channels: 2, capacity: historyCapacity)    // page in, page out B/s
    let diskHistory = TimeSeries(channels: 2, capacity: historyCapacity)      // read, write B/s
    let networkHistory = TimeSeries(channels: 2, capacity: historyCapacity)   // up, down B/s
    let powerHistory = TimeSeries(channels: 1, capacity: historyCapacity)     // W
    let temperatureHistory = TimeSeries(channels: 2, capacity: historyCapacity) // CPU, GPU °C
    let fanHistory = TimeSeries(channels: 1, capacity: historyCapacity)       // mean rpm
    let batteryHistory = TimeSeries(channels: 1, capacity: historyCapacity)   // charge %

    private(set) var snapshot = MonitorSnapshot()
    private(set) var sampleCount = 0
    var onSample: (() -> Void)?
    var publicIPAutoLookup = false

    /// The open panel; drives the on-demand samplers.
    var focus: MonitorItem? {
        didSet { if focus != oldValue { focusChanged(from: oldValue) } }
    }

    let chipName = SystemSampler.chipName()
    private(set) var ioReportAvailable = false
    private(set) var gpuMaxMHz: Double?
    private var timer: Timer?
    private var generation = 0
    private var lastCPU: CPUTicks?
    private var lastCores: [CPUTicks] = []
    private var efficiencyFlags: [Bool] = []
    private let network = NetworkRateTracker()
    private let diskTracker = CounterRateTracker<String>()
    private let pagingTracker = CounterRateTracker<String>()
    private var smc: SMCConnection?
    private var sensorDefinitions: [SensorDefinition] = []
    private var fanLimits: [(min: Double, max: Double)] = []
    private var ioReport: IOReportSampler?
    private let nominalMHz = SystemSampler.nominalCPUMHz()
    private let processSampler = ProcessSampler()
    private let netProcessTracker = CounterRateTracker<Int32>()
    private var netTopRunning = false
    private var bootTime: Date?
    private var publicIPFetchedAt: Date?
    private var ticks = 0

    var isTimerActive: Bool { timer?.isValid ?? false }

    func start() {
        guard timer == nil else { return }
        generation += 1
        bootTime = SystemSampler.bootTime()
        let cores = SystemSampler.perCoreTicks()
        efficiencyFlags = SystemSampler.efficiencyCoreFlags(count: cores.count)
        lastCores = cores
        lastCPU = SystemSampler.cpuTicks()
        _ = network.update(counters: SystemSampler.networkCounters(), at: Date().timeIntervalSince1970)
        let disk = SystemSampler.diskCounters()
        _ = diskTracker.update(["disk": [disk.read, disk.write]], at: Date().timeIntervalSince1970)
        ioReport = IOReportSampler()
        ioReportAvailable = ioReport != nil
        gpuMaxMHz = ioReport?.gpuMaxMHz
        _ = ioReport?.sample()
        smc = SMCConnection()
        snapshot.smcAvailable = smc != nil
        if let smc = smc {
            let count = Int(smc.read("FNum") ?? 0)
            fanLimits = (0..<max(0, min(count, 8))).map { i in
                (smc.read("F\(i)Mn") ?? 0, smc.read("F\(i)Mx") ?? 0)
            }
            discoverSensors()
        }
        snapshot.volume = SystemSampler.volumeInfo()
        snapshot.battery = SystemSampler.battery()

        let t = Timer(timeInterval: MonitorEngine.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while a popup menu tracks
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self, self.timer != nil else { return }
            self.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1  // drops results of background work still in flight
        focus = nil
        smc = nil
        ioReport = nil
        lastCPU = nil
        lastCores = []
        netTopRunning = false
    }

    // MARK: Sampling

    private func tick() {
        guard timer != nil else { return }
        let now = Date().timeIntervalSince1970
        sampleCount += 1
        ticks += 1
        var s = snapshot

        // CPU
        if let current = SystemSampler.cpuTicks() {
            if let previous = lastCPU { s.cpu = SystemMath.cpuUsage(previous: previous, current: current) }
            lastCPU = current
        }
        let cores = SystemSampler.perCoreTicks()
        if cores.count == lastCores.count && !cores.isEmpty {
            s.cores = cores.indices.map { i in
                CoreLoad(busy: SystemMath.cpuUsage(previous: lastCores[i], current: cores[i])?.busy ?? 0,
                         efficiency: i < efficiencyFlags.count ? efficiencyFlags[i] : false)
            }
            let e = s.cores.filter { $0.efficiency }.map { $0.busy }
            let p = s.cores.filter { !$0.efficiency }.map { $0.busy }
            s.efficiencyAverage = e.isEmpty ? nil : e.reduce(0, +) / Double(e.count)
            s.performanceAverage = p.isEmpty ? nil : p.reduce(0, +) / Double(p.count)
        }
        lastCores = cores
        s.loadAverage = SystemSampler.loadAverage()
        if let boot = bootTime { s.uptime = Date().timeIntervalSince(boot) }
        if let reading = ioReport?.sample() {
            s.cpuMHz = reading.cpuMHz
            s.gpuMHz = reading.gpuMHz
        } else if ioReport == nil {
            s.cpuMHz = nominalMHz
        }

        // GPU
        if let gpu = SystemSampler.gpuStats() {
            s.gpuUtilization = gpu.utilization
            s.gpuMemoryInUse = gpu.memoryInUse
            s.gpuMemoryAllocated = gpu.memoryAllocated
        }

        // Memory
        if let detail = SystemSampler.memoryDetail() {
            s.memory = detail.breakdown
            let page = Double(getpagesize())
            if let rates = pagingTracker.update(["paging": [detail.pageins, detail.pageouts]], at: now)?["paging"] {
                s.pageInRate = rates[0] * page
                s.pageOutRate = rates[1] * page
            }
        }
        if let pressure = SystemSampler.memoryPressure() {
            s.pressure = pressure.percent
            s.pressureLevel = pressure.level
        }
        if let swap = SystemSampler.swapUsage() { s.swapUsed = swap.used; s.swapTotal = swap.total }

        // Disk
        let disk = SystemSampler.diskCounters()
        s.diskReadTotal = disk.read
        s.diskWriteTotal = disk.write
        if let rates = diskTracker.update(["disk": [disk.read, disk.write]], at: now)?["disk"] {
            s.diskRead = rates[0]
            s.diskWrite = rates[1]
        }
        if ticks % (focus == .disk ? 5 : 30) == 0 { s.volume = SystemSampler.volumeInfo() }
        if focus == .disk && ticks % 30 == 0 { s.ssd = SystemSampler.ssdHealth() }

        // Network
        let counters = SystemSampler.networkCounters()
        if let rate = network.update(counters: counters, at: now) {
            s.netDown = rate.rx
            s.netUp = rate.tx
        }
        var rxTotal: UInt64 = 0, txTotal: UInt64 = 0
        for (name, c) in counters where SystemMath.isCountedInterface(name) { rxTotal &+= c.rx; txTotal &+= c.tx }
        s.netDownTotal = rxTotal
        s.netUpTotal = txTotal
        if focus == .network { s.interfaces = SystemSampler.interfaces() }

        // Sensors
        readSensors(into: &s, full: focus == .sensors)

        // Battery: every 10 s, every tick while its panel is open.
        if focus == .battery || ticks % 5 == 0 { s.battery = SystemSampler.battery() }

        // Processes
        if focus == .cpu || focus == .memory || focus == .disk {
            s.processes = ProcessPresentation.shared.group(processSampler.sample(at: now))
            s.processesSampled = true
        }

        snapshot = s
        if focus == .network {
            sampleNetworkProcesses()
            if publicIPAutoLookup, publicIPFetchedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                lookupPublicIP()
            }
        }

        cpuHistory.append(time: now, values: [s.cpu?.user, s.cpu?.system])
        coreHistory.append(time: now, values: [s.performanceAverage, s.efficiencyAverage])
        loadHistory.append(time: now, values: s.loadAverage.map { $0 })
        gpuHistory.append(time: now, values: [s.gpuUtilization, s.gpuMemoryPercent, s.gpuMHz])
        let m = s.memory
        memoryHistory.append(time: now, values: [m?.usedPercent, s.pressure, m.map { $0.fraction($0.app) * 100 },
                                                 m.map { $0.fraction($0.wired) * 100 }, m.map { $0.fraction($0.compressed) * 100 }])
        swapHistory.append(time: now, values: [Double(s.swapUsed)])
        pagingHistory.append(time: now, values: [s.pageInRate, s.pageOutRate])
        diskHistory.append(time: now, values: [s.diskRead, s.diskWrite])
        networkHistory.append(time: now, values: [s.netUp, s.netDown])
        powerHistory.append(time: now, values: [s.power])
        temperatureHistory.append(time: now, values: [s.cpuTemperature, s.gpuTemperature])
        fanHistory.append(time: now, values: [s.fans.isEmpty ? nil : s.fans.map { $0.rpm }.reduce(0, +) / Double(s.fans.count)])
        batteryHistory.append(time: now, values: [s.battery?.percent])
        onSample?()
    }

    /// `full` reads every sensor (sensors panel open); otherwise only the CPU / GPU keys the menu bar
    /// and the history need, which keeps SMC traffic per tick low.
    private func readSensors(into s: inout MonitorSnapshot, full: Bool) {
        guard let smc = smc else { return }
        if s.sensorsReady {
            let needed = full ? sensorDefinitions : sensorDefinitions.filter { $0.group.isCPU || $0.group == .gpu }
            var readings: [String: Double] = [:]
            for key in SensorCatalog.keys(of: needed) { readings[key] = smc.read(key) }
            if full {
                s.sensors = sensorDefinitions.map {
                    SensorValue(label: $0.label, group: $0.group, value: SensorCatalog.value(of: $0, readings: readings))
                }
            }
            s.cpuTemperature = SensorCatalog.summary(sensorDefinitions, readings: readings) { $0.isCPU }
            s.gpuTemperature = SensorCatalog.summary(sensorDefinitions, readings: readings) { $0 == .gpu }
        }
        s.fans = fanLimits.enumerated().compactMap { i, limits in
            guard let rpm = smc.read("F\(i)Ac") else { return nil }
            return FanReading(label: "Fan \(i + 1)", rpm: max(0, rpm),
                              percent: SystemMath.fanPercent(rpm: rpm, minimum: limits.min, maximum: limits.max))
        }
        s.power = smc.read("PSTR").flatMap { $0 > 0 && $0 < 2000 ? $0 : nil }
    }

    /// Key enumeration takes ~0.5 s, so it runs once in the background on its own connection.
    private func discoverSensors() {
        let chip = chipName
        let token = generation
        DispatchQueue.global(qos: .utility).async {
            let keys = SMCConnection()?.keys(withPrefix: "T") ?? []
            let storage = SystemSampler.internalSSDName()
            let defs = SensorCatalog.definitions(chip: chip, keys: Set(keys), storageName: storage)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == token, self.timer != nil else { return }
                self.sensorDefinitions = defs
                self.snapshot.sensorsReady = true
                self.readSensors(into: &self.snapshot, full: true)
                self.onSample?()
            }
        }
    }

    // MARK: On-demand samplers

    private func focusChanged(from old: MonitorItem?) {
        let wantsProcesses = focus == .cpu || focus == .memory || focus == .disk
        if !wantsProcesses {
            snapshot.processes = []
            snapshot.processesSampled = false
            processSampler.reset()
        }
        if focus != .network {
            snapshot.networkProcesses = []
            snapshot.networkProcessesSampled = false
            netProcessTracker.reset()
        }
        guard timer != nil else { return }
        if wantsProcesses && !(old == .cpu || old == .memory || old == .disk) {
            // Baseline now (memory is immediate), first rates one second later instead of waiting a full tick.
            snapshot.processes = ProcessPresentation.shared.group(processSampler.sample(at: Date().timeIntervalSince1970))
            snapshot.processesSampled = true
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self, self.generation == token, self.timer != nil,
                      self.focus == .cpu || self.focus == .memory || self.focus == .disk else { return }
                self.snapshot.processes = ProcessPresentation.shared.group(self.processSampler.sample(at: Date().timeIntervalSince1970))
                self.onSample?()
            }
        }
        if focus == .disk {
            snapshot.volume = SystemSampler.volumeInfo()
            snapshot.ssd = SystemSampler.ssdHealth()
        }
        if focus == .sensors { readSensors(into: &snapshot, full: true) }
        if focus == .battery { snapshot.battery = SystemSampler.battery() }
        if focus == .network {
            snapshot.interfaces = SystemSampler.interfaces()
            sampleNetworkProcesses()
            if publicIPAutoLookup { lookupPublicIP() }
        }
    }

    /// nettop is the only unprivileged per-process byte counter. A single snapshot costs ~25 ms
    /// (its own sampling loop is far more expensive), so we take snapshots and diff them ourselves.
    private func sampleNetworkProcesses() {
        guard !netTopRunning else { return }
        netTopRunning = true
        let token = generation
        DispatchQueue.global(qos: .utility).async {
            let rows = NetTopParser.parse(MonitorEngine.runNetTop() ?? "")
            var paths: [Int32: String] = [:]
            for row in rows { paths[row.pid] = LibProc.path(row.pid) ?? "" }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == token else { return }
                self.netTopRunning = false
                guard self.focus == .network else { return }
                var counters: [Int32: [UInt64]] = [:]
                for row in rows { counters[row.pid] = [row.bytesIn, row.bytesOut] }
                guard let rates = self.netProcessTracker.update(counters, at: Date().timeIntervalSince1970) else { return }
                let usages = rows.map { row -> ProcessUsage in
                    let r = rates[row.pid]
                    return ProcessUsage(pid: row.pid, name: row.name, path: paths[row.pid] ?? "",
                                        netIn: r?[0] ?? 0, netOut: r?[1] ?? 0)
                }
                self.snapshot.networkProcesses = ProcessPresentation.shared.group(usages)
                self.snapshot.networkProcessesSampled = true
                self.onSample?()
            }
        }
    }

    private static func runNetTop() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out", "-t", "external"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// One HTTPS request to Cloudflare's trace endpoint (returns the caller's IP and country).
    /// Only on explicit request or with the opt-in auto lookup.
    func lookupPublicIP() {
        if case .loading = snapshot.publicIP { return }
        snapshot.publicIP = .loading
        publicIPFetchedAt = Date()
        onSample?()
        let token = generation
        let request = URLRequest(url: MonitorEngine.publicIPEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, _, error in
            let parsed = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { PublicIPParser.parseTrace($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == token else { return }
                if let parsed = parsed {
                    self.snapshot.publicIP = .value(ip: parsed.ip, country: parsed.country)
                } else {
                    self.snapshot.publicIP = .failed(error?.localizedDescription ?? "Could not read the response")
                }
                self.onSample?()
            }
        }.resume()
        session.finishTasksAndInvalidate()
    }
}

// MARK: - Sample data (gadget gallery preview while the monitor is off)

extension MonitorEngine {
    /// An engine filled with 70 minutes of made-up but plausible history, so the gallery can show the real panel
    /// views while the monitor is switched off. Never sampled, never started.
    static func sample() -> MonitorEngine {
        let engine = MonitorEngine()
        engine.loadSampleData()
        return engine
    }

    private func loadSampleData() {
        let now = Date().timeIntervalSince1970
        let count = 2_100
        // Smooth, repeatable wobble: a few sines at unrelated periods.
        func wave(_ i: Int, _ base: Double, _ amp: Double, _ seed: Double) -> Double {
            let t = Double(i)
            return max(0, base + amp * (0.55 * sin(t / 23 + seed) + 0.3 * sin(t / 7.3 + seed * 2) + 0.15 * sin(t / 2.1 + seed * 3)))
        }
        for i in 0..<count {
            let time = now - Double(count - i) * MonitorEngine.interval
            let user = wave(i, 16, 10, 0.4), system = wave(i, 8, 4, 1.7)
            cpuHistory.append(time: time, values: [user, system])
            coreHistory.append(time: time, values: [wave(i, 22, 14, 0.9), wave(i, 34, 12, 2.2)])
            loadHistory.append(time: time, values: [wave(i, 2.6, 1.2, 0.3), wave(i, 2.4, 0.6, 0.5), wave(i, 2.2, 0.3, 0.7)])
            gpuHistory.append(time: time, values: [wave(i, 9, 7, 1.1), wave(i, 18, 3, 0.2), wave(i, 420, 180, 2.9)])
            memoryHistory.append(time: time, values: [wave(i, 72, 4, 0.6), wave(i, 38, 6, 1.4), wave(i, 46, 3, 2.5),
                                                      wave(i, 17, 1, 0.1), wave(i, 9, 2, 1.9)])
            swapHistory.append(time: time, values: [1.2e9])
            pagingHistory.append(time: time, values: [wave(i, 2e5, 2e5, 0.8), wave(i, 0, 4e4, 2.1)])
            diskHistory.append(time: time, values: [wave(i, 3e6, 4e6, 1.3), wave(i, 1.5e6, 2e6, 0.4)])
            networkHistory.append(time: time, values: [wave(i, 9e4, 8e4, 2.6), wave(i, 6e5, 5e5, 0.2)])
            powerHistory.append(time: time, values: [wave(i, 9, 5, 1.6)])
            temperatureHistory.append(time: time, values: [wave(i, 48, 6, 0.5), wave(i, 44, 4, 1.2)])
            fanHistory.append(time: time, values: [0])
            batteryHistory.append(time: time, values: [max(20, 93 - Double(i) * 0.015)])
        }
        var s = MonitorSnapshot()
        s.cpu = CPUUsage(user: 18.4, system: 8.7, idle: 72.9)
        let coreBusy: [Double] = [12, 9, 41, 33, 26, 18, 52, 14, 8, 21]
        s.cores = coreBusy.indices.map { CoreLoad(busy: coreBusy[$0], efficiency: $0 < 2) }
        s.efficiencyAverage = 10.5
        s.performanceAverage = 26.6
        s.cpuMHz = 2_890
        s.loadAverage = [2.71, 2.43, 2.18]
        s.uptime = 274_320   // 3 days 4 h 12 min
        s.gpuUtilization = 11
        s.gpuMemoryInUse = 1_200_000_000
        s.gpuMemoryAllocated = 6_400_000_000
        s.gpuMHz = 389
        let gib: UInt64 = 1 << 30
        s.memory = MemoryBreakdown(total: 16 * gib, app: 7 * gib + gib / 2, wired: 2 * gib + gib / 2, compressed: gib + gib / 4,
                                   cached: 3 * gib)
        s.pressure = 38
        s.swapUsed = 1_200_000_000
        s.swapTotal = 2 * gib
        s.diskRead = 3_400_000
        s.diskWrite = 1_100_000
        s.netUp = 84_000
        s.netDown = 612_000
        s.cpuTemperature = 48.2
        s.gpuTemperature = 44.6
        s.power = 9.4
        var battery = BatteryInfo(percent: 62, charging: false, onAC: false)
        battery.minutesToEmpty = 254
        battery.cycleCount = 212
        battery.designCapacity = 6075
        battery.maxCapacity = 5528
        battery.condition = "Normal"
        battery.temperature = 30.1
        battery.voltage = 12.48
        battery.amperage = -0.75
        s.battery = battery
        s.processesSampled = true
        let names = ["Safari", "Xcode", "Music", "Mail", "Finder"]
        let cpu: [Double] = [21.4, 14.8, 6.2, 3.1, 1.4]
        let memory: [UInt64] = [1_900_000_000, 3_100_000_000, 420_000_000, 380_000_000, 160_000_000]
        s.processes = names.indices.map { i in
            ProcessGroupUsage(key: "sample-\(i)", name: names[i], bundlePath: nil, path: "", processCount: 1,
                              cpuPercent: cpu[i], memory: memory[i])
        }
        snapshot = s
        sampleCount = count
    }
}
