import Foundation

/// Display strings of the system monitor. Memory, rates and process columns use 1024-based units
/// (like Activity Monitor); disk capacity can use 1000-based units (like Finder).
public enum MonitorFormat {
    /// "0KB", "16.2GB", "2.74TB".
    public static func size(_ bytes: Double, decimal: Bool = false) -> String {
        let base: Double = decimal ? 1000 : 1024
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Swift.max(0, bytes) / base
        var unit = 0
        while value >= base && unit < units.count - 1 { value /= base; unit += 1 }
        if unit == 0 { return String(format: "%.0f", value) + units[0] }
        return String(format: unit >= 3 ? "%.2f" : "%.1f", value) + units[unit]
    }


    /// "48 KB/초", "24.6 MB/초".
    public static func rate(_ bytesPerSecond: Double) -> String {
        let v = Swift.max(0, bytesPerSecond)
        if v < 1_048_576 { return String(format: "%.0f KB/초", v / 1024) }
        if v < 1_073_741_824 { return String(format: "%.1f MB/초", v / 1_048_576) }
        return String(format: "%.2f GB/초", v / 1_073_741_824)
    }

    /// Narrow process column: "9K", "293K", "2.2M"; values below one byte show `zero`.
    public static func compact(_ value: Double, zero: String = "-") -> String {
        guard value >= 1 else { return zero }
        if value < 1_048_576 { return String(format: "%.0fK", Swift.max(1, value / 1024)) }
        if value < 1_073_741_824 { return String(format: "%.1fM", value / 1_048_576) }
        return String(format: "%.1fG", value / 1_073_741_824)
    }

    public static func percent(_ value: Double) -> String { String(format: "%.0f%%", Swift.max(0, value)) }

    /// "11일 5시간", "3시간 12분", "7분".
    public static func uptime(_ seconds: Double) -> String {
        let minutesTotal = Int(Swift.max(0, seconds)) / 60
        let days = minutesTotal / 1440, hours = (minutesTotal % 1440) / 60, minutes = minutesTotal % 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분"
    }

    public static func gigahertz(_ mhz: Double) -> String { String(format: "%.2f GHz", mhz / 1000) }
    public static func temperature(_ celsius: Double) -> String { String(format: "%.0f°", celsius) }

    /// "1,009".
    public static func grouped(_ number: Int) -> String {
        let digits = String(number.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (number < 0 ? "-" : "") + out
    }

    public static func rpm(_ value: Double) -> String { grouped(Int(value.rounded())) + " rpm" }
    public static func watts(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f W", value) : String(format: "%.0f W", value)
    }
    public static func loadAverage(_ values: [Double]) -> String {
        values.map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }
}
