import Foundation

public struct CPUTicks: Equatable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
    public var total: UInt64 { user &+ system &+ idle &+ nice }
}

public struct CPUUsage: Equatable {
    public let user: Double, system: Double, idle: Double
    public var busy: Double { user + system }

    public init(user: Double, system: Double, idle: Double) {
        self.user = user; self.system = system; self.idle = idle
    }
}

public enum SystemMath {
    /// Percent shares between two tick snapshots. nil when no time elapsed or counters went backwards.
    public static func cpuUsage(previous: CPUTicks, current: CPUTicks) -> CPUUsage? {
        guard current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
        let total = current.total - previous.total
        guard total > 0 else { return nil }
        let t = Double(total)
        let user = Double((current.user - previous.user) + (current.nice - previous.nice)) / t * 100
        let system = Double(current.system - previous.system) / t * 100
        let idle = Double(current.idle - previous.idle) / t * 100
        return CPUUsage(user: user, system: system, idle: idle)
    }

    /// Difference of a monotonically increasing counter that may wrap at `bits` (BSD if_data is 32-bit).
    public static func counterDelta(previous: UInt64, current: UInt64, bits: Int = 32) -> UInt64 {
        if current >= previous { return current - previous }
        let modulus: UInt64 = bits >= 64 ? 0 : (UInt64(1) << UInt64(bits))
        if modulus == 0 { return 0 }
        return modulus - previous + current
    }

    /// Only physical Ethernet / Wi-Fi style interfaces (en*) are counted to avoid double counting
    /// bridges, tunnels and loopback.
    public static func isCountedInterface(_ name: String) -> Bool { name.hasPrefix("en") }

    public static func memoryPercent(used: UInt64, total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(100, Double(used) / Double(total) * 100)
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(bytes) B" : String(format: "%.1f", value) + " " + units[unit]
    }

    /// Compact rate for the menu bar, e.g. "1.2M", "340K", "0B".
    public static func formatRateCompact(_ bytesPerSecond: Double) -> String {
        let v = max(0, bytesPerSecond)
        if v >= 1024 * 1024 { return String(format: "%.1fM", v / (1024 * 1024)) }
        if v >= 1024 { return String(format: "%.0fK", v / 1024) }
        return String(format: "%.0fB", v)
    }
}

/// Tracks per-interface counters across samples and yields bytes/second.
public final class NetworkRateTracker {
    private var previous: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var previousTime: TimeInterval?
    public init() {}

    public func update(counters: [String: (rx: UInt64, tx: UInt64)], at time: TimeInterval)
        -> (rx: Double, tx: Double)? {
        defer { previous = counters; previousTime = time }
        guard let last = previousTime, time > last else { return nil }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for (name, now) in counters where SystemMath.isCountedInterface(name) {
            guard let before = previous[name] else { continue }
            rx &+= SystemMath.counterDelta(previous: before.rx, current: now.rx)
            tx &+= SystemMath.counterDelta(previous: before.tx, current: now.tx)
        }
        let dt = time - last
        return (Double(rx) / dt, Double(tx) / dt)
    }
}
