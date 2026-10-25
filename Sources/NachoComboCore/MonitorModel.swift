import Foundation

/// Menu bar items of the system monitor. Declaration order = left-to-right order in the menu bar.
public enum MonitorItem: String, Codable, CaseIterable {
    case cpu, memory, disk, network, sensors, battery

    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .sensors: return "Sensors"
        case .battery: return "Battery"
        }
    }

    /// Battery is opt-in (not every Mac has one, and existing menu bars should not grow); the rest show by default.
    public var shownByDefault: Bool { self != .battery }
}

/// Time span shown by a history chart.
public enum ChartRange: Int, CaseIterable {
    case tenMinutes = 600
    case oneHour = 3600
    case threeHours = 10_800
    case oneDay = 86_400

    public static let standard = ChartRange.oneHour
    public var seconds: Double { Double(rawValue) }
    public var label: String {
        switch self {
        case .tenMinutes: return "10 min"
        case .oneHour: return "1 hour"
        case .threeHours: return "3 hours"
        case .oneDay: return "24 hours"
        }
    }
}

/// User choices of the system monitor. Missing keys fall back to defaults so old settings files keep loading.
public struct MonitorSettings: Codable, Equatable {
    /// MonitorItem.rawValue → shown in the menu bar (default: shown).
    public var items: [String: Bool]
    /// Chart key → ChartRange.rawValue.
    public var chartRanges: [String: Int]
    /// Public IP lookup sends a request to an external service, so it is opt-in.
    public var publicIPLookup: Bool

    public static let defaults = MonitorSettings(items: [:], chartRanges: [:], publicIPLookup: false)

    public init(items: [String: Bool], chartRanges: [String: Int], publicIPLookup: Bool) {
        self.items = items
        self.chartRanges = chartRanges
        self.publicIPLookup = publicIPLookup
    }

    private enum CodingKeys: String, CodingKey { case items, chartRanges, publicIPLookup }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([String: Bool].self, forKey: .items)) ?? [:]
        chartRanges = (try? c.decodeIfPresent([String: Int].self, forKey: .chartRanges)) ?? [:]
        publicIPLookup = (try? c.decodeIfPresent(Bool.self, forKey: .publicIPLookup)) ?? false
    }

    public func isShown(_ item: MonitorItem) -> Bool { items[item.rawValue] ?? item.shownByDefault }
    public mutating func setShown(_ item: MonitorItem, _ shown: Bool) { items[item.rawValue] = shown }
    public var shownItems: [MonitorItem] { MonitorItem.allCases.filter { isShown($0) } }

    public func range(for chart: String) -> ChartRange {
        chartRanges[chart].flatMap { ChartRange(rawValue: $0) } ?? .standard
    }
    public mutating func setRange(_ range: ChartRange, for chart: String) { chartRanges[chart] = range.rawValue }
}

/// Activity Monitor style memory categories.
public struct MemoryBreakdown: Equatable {
    public let total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64) {
        self.total = total; self.app = app; self.wired = wired; self.compressed = compressed; self.cached = cached
    }

    /// App = anonymous pages minus purgeable, cached = file-backed + purgeable.
    public init(total: UInt64, pageSize: UInt64, internalPages: UInt64, purgeablePages: UInt64,
                externalPages: UInt64, wiredPages: UInt64, compressorPages: UInt64) {
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        self.init(total: total, app: appPages * pageSize, wired: wiredPages * pageSize,
                  compressed: compressorPages * pageSize, cached: (externalPages + purgeablePages) * pageSize)
    }

    public var used: UInt64 { app + wired + compressed }
    /// Everything not used by app/wired/compressed (cached files count as available, like Activity Monitor).
    public var free: UInt64 { total > used ? total - used : 0 }
    public var usedPercent: Double { SystemMath.memoryPercent(used: used, total: total) }
    public func fraction(_ part: UInt64) -> Double { total == 0 ? 0 : min(1, Double(part) / Double(total)) }
}

/// Summary of an NVMe "SMART / Health Information" log page (log 02h, 512 bytes, little-endian).
public struct SMARTHealth: Equatable {
    public let criticalWarning: UInt8
    /// Composite temperature in °C (nil when the drive reports 0 K).
    public let temperature: Double?
    public let availableSpare: Int
    /// Vendor estimate of the rated endurance used, 0–255 (may exceed 100).
    public let lifeUsedPercent: Int

    public init?(log bytes: [UInt8]) {
        guard bytes.count >= 6 else { return nil }
        criticalWarning = bytes[0]
        let kelvin = Int(bytes[1]) | Int(bytes[2]) << 8
        temperature = kelvin > 0 ? Double(kelvin) - 273.15 : nil
        availableSpare = Int(bytes[3])
        lifeUsedPercent = Int(bytes[5])
    }

    /// 100% for a new drive, 0% once the rated endurance is used up.
    public var healthPercent: Int { Swift.max(0, 100 - lifeUsedPercent) }
}

/// Converts performance-state residency into an average clock.
public enum FrequencyMath {
    /// Decodes a pmgr "voltage-states" property: little-endian (frequency Hz: UInt32, voltage: UInt32) pairs.
    /// Zero-Hz entries (the "off" state) are dropped. Result in MHz, in table order.
    public static func decodeVoltageStates(_ bytes: [UInt8]) -> [Double] {
        var result: [Double] = []
        var i = 0
        while i + 8 <= bytes.count {
            let hz = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            if hz > 0 { result.append(Double(hz) / 1_000_000) }
            i += 8
        }
        return result
    }

    public static func isActiveState(_ name: String) -> Bool {
        !["IDLE", "OFF", "DOWN"].contains(name.uppercased())
    }

    /// Residency-weighted mean of the active states. `residencies[k]` belongs to the k-th active state,
    /// which maps to `table[k]`; states beyond the table are ignored. nil when nothing was active.
    public static func weightedFrequency(residencies: [Double], table: [Double]) -> Double? {
        var weighted = 0.0, total = 0.0
        for (k, r) in residencies.enumerated() where k < table.count && r > 0 {
            weighted += r * table[k]
            total += r
        }
        return total > 0 ? weighted / total : nil
    }
}

/// Per-second rates of monotonically increasing counters, keyed by any identity (pid, disk...).
public final class CounterRateTracker<Key: Hashable> {
    private var previous: [Key: [UInt64]] = [:]
    private var previousTime: Double?
    public init() {}

    public func reset() { previous = [:]; previousTime = nil }

    /// nil on the first call. Keys new in this sample are skipped; counters that went backwards count as 0.
    public func update(_ counters: [Key: [UInt64]], at time: Double) -> [Key: [Double]]? {
        defer { previous = counters; previousTime = time }
        guard let last = previousTime, time > last else { return nil }
        let dt = time - last
        var result: [Key: [Double]] = [:]
        for (key, now) in counters {
            guard let before = previous[key], before.count == now.count else { continue }
            result[key] = zip(before, now).map { b, n in n >= b ? Double(n - b) / dt : 0 }
        }
        return result
    }
}

public struct ProcessUsage: Equatable {
    public var pid: Int32
    public var name: String
    public var path: String
    public var cpuPercent: Double
    public var memory: UInt64
    public var diskRead: Double
    public var diskWrite: Double
    public var netIn: Double
    public var netOut: Double

    public init(pid: Int32, name: String, path: String, cpuPercent: Double = 0, memory: UInt64 = 0,
                diskRead: Double = 0, diskWrite: Double = 0, netIn: Double = 0, netOut: Double = 0) {
        self.pid = pid; self.name = name; self.path = path; self.cpuPercent = cpuPercent; self.memory = memory
        self.diskRead = diskRead; self.diskWrite = diskWrite; self.netIn = netIn; self.netOut = netOut
    }
}

public struct ProcessGroupUsage: Equatable {
    public var key: String
    public var name: String
    public var bundlePath: String?
    /// Executable of the first member (used for an icon when there is no bundle).
    public var path: String
    public var processCount: Int
    public var cpuPercent: Double
    public var memory: UInt64
    public var diskRead: Double
    public var diskWrite: Double
    public var netIn: Double
    public var netOut: Double

    public init(key: String, name: String, bundlePath: String?, path: String, processCount: Int, cpuPercent: Double,
                memory: UInt64, diskRead: Double = 0, diskWrite: Double = 0, netIn: Double = 0, netOut: Double = 0) {
        self.key = key; self.name = name; self.bundlePath = bundlePath; self.path = path
        self.processCount = processCount; self.cpuPercent = cpuPercent; self.memory = memory
        self.diskRead = diskRead; self.diskWrite = diskWrite; self.netIn = netIn; self.netOut = netOut
    }
}

public enum ProcessGrouping {
    /// Outermost app bundle containing an executable, so helpers count toward their app
    /// (".../Google Chrome.app/Contents/Frameworks/.../Helper.app/..." → ".../Google Chrome.app").
    /// Also recognises Chrome's code-signing clone ("…/Google Chrome.app.bundle/Contents/MacOS/…").
    public static func appBundlePath(forExecutable path: String) -> String? {
        let candidates = [".app/", ".app.bundle/"].compactMap { marker -> String? in
            guard let r = path.range(of: marker) else { return nil }
            return String(path[..<r.upperBound].dropLast())
        }
        if let outermost = candidates.min(by: { $0.count < $1.count }) { return outermost }
        return path.hasSuffix(".app") ? path : nil
    }

    public static func bundleDisplayName(_ bundlePath: String) -> String {
        var name = (bundlePath as NSString).lastPathComponent
        if name.hasSuffix(".bundle") { name.removeLast(7) }
        if name.hasSuffix(".app") { name.removeLast(4) }
        return name
    }

    /// Sums processes per app bundle; processes outside bundles are grouped per executable.
    /// `bundleKey` maps a bundle path to a shared identity (the bundle identifier), so copies of the
    /// same app at different paths merge; the copy ending in ".app" provides name and icon.
    public static func group(_ usages: [ProcessUsage], bundleKey: (String) -> String? = { _ in nil }) -> [ProcessGroupUsage] {
        var groups: [String: ProcessGroupUsage] = [:]
        var order: [String] = []
        for u in usages {
            let bundle = appBundlePath(forExecutable: u.path)
            let key = bundle.map { bundleKey($0).map { "id:" + $0 } ?? $0 } ?? (u.path.isEmpty ? "name:" + u.name : u.path)
            if var g = groups[key] {
                if let bundle = bundle, bundle.hasSuffix(".app"), g.bundlePath?.hasSuffix(".app") != true {
                    g.bundlePath = bundle
                    g.name = bundleDisplayName(bundle)
                }
                g.processCount += 1
                g.cpuPercent += u.cpuPercent
                g.memory += u.memory
                g.diskRead += u.diskRead
                g.diskWrite += u.diskWrite
                g.netIn += u.netIn
                g.netOut += u.netOut
                groups[key] = g
            } else {
                let name = bundle.map(bundleDisplayName) ?? (u.path.isEmpty ? u.name : (u.path as NSString).lastPathComponent)
                groups[key] = ProcessGroupUsage(key: key, name: name, bundlePath: bundle, path: u.path, processCount: 1,
                                                cpuPercent: u.cpuPercent, memory: u.memory, diskRead: u.diskRead,
                                                diskWrite: u.diskWrite, netIn: u.netIn, netOut: u.netOut)
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
    }

    /// Highest `count` groups by a metric (zero values dropped, ties by name for a stable order).
    public static func top(_ groups: [ProcessGroupUsage], count: Int,
                           by metric: (ProcessGroupUsage) -> Double) -> [ProcessGroupUsage] {
        let ranked = groups.filter { metric($0) > 0 }.sorted {
            let a = metric($0), b = metric($1)
            return a != b ? a > b : $0.name < $1.name
        }
        return Array(ranked.prefix(count))
    }
}

public struct NetTopRow: Equatable {
    public let pid: Int32
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64
}

/// Parses `nettop -P -L 1 -x -J bytes_in,bytes_out` CSV ("name.pid,in,out,").
public enum NetTopParser {
    public static func parse(_ text: String) -> [NetTopRow] {
        var rows: [Int32: NetTopRow] = [:]
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { continue }
            rows[pid] = NetTopRow(pid: pid, name: String(fields[0][..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
        return rows.values.sorted { $0.pid < $1.pid }
    }
}

public enum PublicIPParser {
    /// Parses a "key=value" trace response (ip=…, loc=KR).
    public static func parseTrace(_ text: String) -> (ip: String, country: String?)? {
        var ip: String?, country: String?
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0] {
            case "ip": ip = value
            case "loc": country = value.isEmpty ? nil : value
            default: break
            }
        }
        guard let address = ip, !address.isEmpty else { return nil }
        return (address, country)
    }

    /// "KR" → 🇰🇷. Anything that is not two ASCII letters yields "".
    public static func flag(forCountryCode code: String) -> String {
        let upper = code.uppercased()
        guard upper.unicodeScalars.count == 2,
              upper.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return "" }
        var result = ""
        for scalar in upper.unicodeScalars {
            if let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 65) { result.unicodeScalars.append(indicator) }
        }
        return result
    }
}

extension SystemMath {
    /// 0% at the fan's minimum speed, 100% at its maximum.
    public static func fanPercent(rpm: Double, minimum: Double, maximum: Double) -> Double {
        guard maximum > minimum else { return 0 }
        return Swift.min(100, Swift.max(0, (rpm - minimum) / (maximum - minimum) * 100))
    }
}
