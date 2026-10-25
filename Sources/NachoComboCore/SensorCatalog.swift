import Foundation

/// Decoding of System Management Controller values. Key names and encodings are not documented by
/// Apple; these are the encodings the SMC itself reports for each key ("flt ", "sp78", ...).
public enum SMCDecoder {
    public static func fourCC(_ text: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in text.utf8.prefix(4) { value = value << 8 | UInt32(byte) }
        return value
    }

    public static func string(fromFourCC value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func be16() -> UInt16? { bytes.count >= 2 ? UInt16(bytes[0]) << 8 | UInt16(bytes[1]) : nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil
        case "sp78": return be16().map { Double(Int16(bitPattern: $0)) / 256 }
        case "fp88": return be16().map { Double($0) / 256 }
        case "fpe2": return be16().map { Double($0) / 4 }
        case "si16": return be16().map { Double(Int16(bitPattern: $0)) }
        case "ui16": return be16().map { Double($0) }
        case "ui8 ": return bytes.first.map { Double($0) }
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default: return nil
        }
    }
}

public enum SensorGroup: String {
    case cpuPerformance, cpuEfficiency, cpu, gpu, storage, battery, wireless, palmRest, airflow, memory

    public var isCPU: Bool { self == .cpuPerformance || self == .cpuEfficiency || self == .cpu }
}

public struct SensorDefinition: Equatable {
    public enum Combine: Equatable { case first, mean, max }

    public let label: String
    public let group: SensorGroup
    public let keys: [String]
    public let combine: Combine
    /// Counts toward the CPU / GPU summary temperature.
    public let summarized: Bool

    public init(label: String, group: SensorGroup, keys: [String], combine: Combine = .first, summarized: Bool = true) {
        self.label = label; self.group = group; self.keys = keys; self.combine = combine; self.summarized = summarized
    }
}

/// Picks labelled temperature sensors from the SMC keys present on this Mac.
/// Per-core labels are used only where the key layout is known (M1 Pro / M1 Max);
/// other Apple silicon chips get honest averages instead of guessed core names.
public enum SensorCatalog {
    static let m1ProPerformance = ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
    static let m1ProEfficiency = ["Tp09", "Tp0T"]
    static let m1ProGPU = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]

    public static func isPlausible(_ celsius: Double) -> Bool { celsius > 5 && celsius < 130 }

    public static func definitions(chip: String, keys: Set<String>, storageName: String?) -> [SensorDefinition] {
        var defs: [SensorDefinition] = []
        func numbered(_ candidates: [String], _ label: String, _ group: SensorGroup) {
            for (i, key) in candidates.filter({ keys.contains($0) }).enumerated() {
                defs.append(SensorDefinition(label: "\(label) \(i + 1)", group: group, keys: [key]))
            }
        }
        if chip.contains("M1 Pro") || chip.contains("M1 Max") {
            numbered(m1ProPerformance, "CPU Performance Core", .cpuPerformance)
            numbered(m1ProEfficiency, "CPU Efficiency Core", .cpuEfficiency)
            numbered(m1ProGPU, "GPU", .gpu)
        } else if chip.hasPrefix("Apple") {
            let cpu = keys.filter { $0.hasPrefix("Tp") || $0.hasPrefix("Te") }.sorted()
            if !cpu.isEmpty {
                defs.append(SensorDefinition(label: "CPU Average", group: .cpu, keys: cpu, combine: .mean))
                defs.append(SensorDefinition(label: "CPU Max", group: .cpu, keys: cpu, combine: .max, summarized: false))
            }
            let gpu = keys.filter { $0.hasPrefix("Tg") }.sorted()
            if !gpu.isEmpty { defs.append(SensorDefinition(label: "GPU Average", group: .gpu, keys: gpu, combine: .mean)) }
        } else {
            if keys.contains("TC0P") { defs.append(SensorDefinition(label: "CPU Proximity", group: .cpu, keys: ["TC0P"])) }
            let die = ["TC0D", "TC0E", "TC0F"].filter { keys.contains($0) }
            if !die.isEmpty { defs.append(SensorDefinition(label: "CPU Die", group: .cpu, keys: die, combine: .max)) }
            numbered((1...9).map { "TC\($0)C" }, "CPU Core", .cpuPerformance)
            let gpu = ["TG0D", "TG0P"].filter { keys.contains($0) }
            if !gpu.isEmpty { defs.append(SensorDefinition(label: "GPU", group: .gpu, keys: gpu, combine: .max)) }
            if keys.contains("TM0P") { defs.append(SensorDefinition(label: "Memory", group: .memory, keys: ["TM0P"])) }
        }
        let ssd = ["TH0x", "TH0a", "TH0b"].filter { keys.contains($0) }
        if !ssd.isEmpty { defs.append(SensorDefinition(label: storageName ?? "SSD", group: .storage, keys: ssd, combine: .max)) }
        let battery = ["TB0T", "TB1T", "TB2T"].filter { keys.contains($0) }
        if !battery.isEmpty { defs.append(SensorDefinition(label: "Battery", group: .battery, keys: battery, combine: .max)) }
        if keys.contains("TW0P") { defs.append(SensorDefinition(label: "Wireless Module", group: .wireless, keys: ["TW0P"])) }
        numbered(["Ts0P", "Ts1P"], "Palm Rest", .palmRest)
        numbered(["TaLP", "TaLT", "TaLW"], "Left Airflow", .airflow)
        numbered(["TaRF", "TaRT", "TaRW"], "Right Airflow", .airflow)
        return defs
    }

    /// Value of one sensor from raw key readings; implausible readings (0 °C, sentinel values) are ignored.
    public static func value(of def: SensorDefinition, readings: [String: Double]) -> Double? {
        let values = def.keys.compactMap { readings[$0] }.filter { isPlausible($0) }
        guard !values.isEmpty else { return nil }
        switch def.combine {
        case .first: return values[0]
        case .mean: return values.reduce(0, +) / Double(values.count)
        case .max: return values.max()
        }
    }

    public static func summary(_ defs: [SensorDefinition], readings: [String: Double],
                               where include: (SensorGroup) -> Bool) -> Double? {
        let values = defs.filter { $0.summarized && include($0.group) }.compactMap { value(of: $0, readings: readings) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Every SMC key the definitions need, without duplicates.
    public static func keys(of defs: [SensorDefinition]) -> [String] {
        var seen = Set<String>()
        return defs.flatMap { $0.keys }.filter { seen.insert($0).inserted }
    }
}
