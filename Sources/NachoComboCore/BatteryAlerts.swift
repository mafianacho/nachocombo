import Foundation

/// The internal battery, from the power source list (public IOKit power sources API) and the battery's registry entry.
public struct BatteryInfo: Equatable {
    public var percent: Double
    public var charging: Bool
    public var onAC: Bool
    public var charged: Bool
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var cycleCount: Int?
    /// Capacities in mAh.
    public var designCapacity: Int?
    public var maxCapacity: Int?
    /// "Normal", "Service Recommended"...
    public var condition: String?
    public var temperature: Double?
    public var voltage: Double?
    /// Amps, negative while discharging.
    public var amperage: Double?
    public var adapterWatts: Int?

    public init(percent: Double, charging: Bool, onAC: Bool, charged: Bool = false) {
        self.percent = percent
        self.charging = charging
        self.onAC = onAC
        self.charged = charged
    }

    /// `powerSource`: one IOPSGetPowerSourceDescription dictionary; `registry`: AppleSmartBattery properties.
    /// Returns nil when there is no internal battery.
    public init?(powerSource: [String: Any], registry: [String: Any]) {
        guard (powerSource["Type"] as? String) == "InternalBattery" || powerSource["Type"] == nil,
              let current = powerSource["Current Capacity"] as? Int,
              let max = powerSource["Max Capacity"] as? Int, max > 0 else { return nil }
        percent = Double(current) / Double(max) * 100
        charging = (powerSource["Is Charging"] as? Bool) ?? false
        onAC = (powerSource["Power Source State"] as? String) == "AC Power"
        charged = (powerSource["Is Charged"] as? Bool) ?? (registry["FullyCharged"] as? Bool) ?? false
        // The power source API reports -1 while it is still estimating.
        if let empty = powerSource["Time to Empty"] as? Int, empty >= 0, !onAC { minutesToEmpty = empty }
        if let full = powerSource["Time to Full Charge"] as? Int, full >= 0, charging { minutesToFull = full }
        cycleCount = registry["CycleCount"] as? Int
        designCapacity = registry["DesignCapacity"] as? Int
        // Full charge capacity as the gauge reports it (closest to "Maximum Capacity" in System Settings).
        maxCapacity = (registry["NominalChargeCapacity"] as? Int) ?? (registry["AppleRawMaxCapacity"] as? Int)
        // Only a real condition ("Service Recommended"...) is named; none means normal. The older "BatteryHealth"
        // key is not used: on Apple silicon it can say "Check Battery" while System Information says Normal.
        let reported = (powerSource["BatteryHealthCondition"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        condition = reported.isEmpty ? "Normal" : reported
        if let t = registry["Temperature"] as? Int { temperature = Double(t) / 100 }
        if let v = registry["Voltage"] as? Int { voltage = Double(v) / 1000 }
        // The registry may hold a negative current as its unsigned 64-bit pattern.
        if let a = registry["Amperage"] as? Int {
            amperage = Double(a) / 1000
        } else if let n = registry["Amperage"] as? NSNumber {
            amperage = Double(Int64(bitPattern: n.uint64Value)) / 1000
        }
        if let adapter = registry["AdapterDetails"] as? [String: Any], let watts = adapter["Watts"] as? Int, onAC {
            adapterWatts = watts
        }
    }

    /// Maximum capacity against the design capacity, like "Maximum Capacity" in System Settings.
    public var healthPercent: Double? {
        guard let design = designCapacity, let max = maxCapacity, design > 0 else { return nil }
        return Swift.min(100, Double(max) / Double(design) * 100)
    }

    /// Watts flowing in (+) or out (-) of the battery.
    public var power: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    public var stateText: String {
        if charged && onAC { return "Charged" }
        if charging { return "Charging" }
        return onAC ? "Not Charging" : "On Battery"
    }

    public static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60):\(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
}

/// What the monitor watches for: sustained high CPU, memory pressure, a nearly full startup disk, a hot CPU and a low
/// battery. Each alert starts after its condition held for a few samples (so a spike does not count) and is armed
/// again once the value is back below its reset level.
public enum MonitorAlertKind: String, CaseIterable {
    case cpu, memory, disk, temperature, battery
}

public struct MonitorAlertInput {
    public var cpuBusy: Double?
    /// kern.memorystatus pressure level: 1 normal, 2 warning, 4 critical.
    public var pressureLevel: Int
    public var diskUsedPercent: Double?
    public var cpuTemperature: Double?
    public var battery: BatteryInfo?

    public init(cpuBusy: Double?, pressureLevel: Int, diskUsedPercent: Double?, cpuTemperature: Double?, battery: BatteryInfo?) {
        self.cpuBusy = cpuBusy
        self.pressureLevel = pressureLevel
        self.diskUsedPercent = diskUsedPercent
        self.cpuTemperature = cpuTemperature
        self.battery = battery
    }
}

public struct MonitorAlerts {
    /// CPU busy percentage that counts as high (0 = no CPU alert).
    public var cpuThreshold: Double
    public static let cpuSamples = 15          // 30 s at the 2 s sample interval
    public static let memorySamples = 5        // 10 s
    public static let memoryClearSamples = 15  // 30 s of normal pressure before the alert ends
    public static let temperatureSamples = 10  // 20 s
    public static let diskPercent = 90.0
    public static let temperatureLimit = 95.0
    public static let batteryPercent = 10.0

    public private(set) var active: Set<MonitorAlertKind> = []
    private var streaks: [MonitorAlertKind: Int] = [:]
    private var clearStreaks: [MonitorAlertKind: Int] = [:]
    private var last = MonitorAlertInput(cpuBusy: nil, pressureLevel: 1, diskUsedPercent: nil, cpuTemperature: nil, battery: nil)

    public init(cpuThreshold: Double) { self.cpuThreshold = cpuThreshold }

    /// Feeds one sample; returns the alerts that started with it.
    public mutating func update(_ input: MonitorAlertInput) -> [MonitorAlertKind] {
        last = input
        var started: [MonitorAlertKind] = []
        // An alert also needs `clear` calm samples in a row to end, so a value hovering at the edge does not flap.
        func track(_ kind: MonitorAlertKind, over: Bool, reset: Bool, samples: Int, clear: Int = 1) {
            if over {
                streaks[kind, default: 0] += 1
                clearStreaks[kind] = 0
                if streaks[kind, default: 0] >= samples, !active.contains(kind) {
                    active.insert(kind)
                    started.append(kind)
                }
            } else {
                streaks[kind] = 0
                clearStreaks[kind] = reset ? clearStreaks[kind, default: 0] + 1 : 0
                if clearStreaks[kind, default: 0] >= clear { active.remove(kind) }
            }
        }
        let cpu = input.cpuBusy ?? 0
        track(.cpu, over: cpuThreshold > 0 && cpu >= cpuThreshold, reset: cpuThreshold <= 0 || cpu < cpuThreshold - 5,
              samples: MonitorAlerts.cpuSamples, clear: cpuThreshold <= 0 ? 1 : 3)
        track(.memory, over: input.pressureLevel >= 2, reset: input.pressureLevel <= 1, samples: MonitorAlerts.memorySamples,
              clear: MonitorAlerts.memoryClearSamples)
        let disk = input.diskUsedPercent ?? 0
        track(.disk, over: disk >= MonitorAlerts.diskPercent, reset: disk < MonitorAlerts.diskPercent - 2, samples: 1)
        let temperature = input.cpuTemperature ?? 0
        track(.temperature, over: temperature >= MonitorAlerts.temperatureLimit,
              reset: temperature < MonitorAlerts.temperatureLimit - 5, samples: MonitorAlerts.temperatureSamples, clear: 5)
        let battery = input.battery
        let low = battery.map { !$0.onAC && $0.percent <= MonitorAlerts.batteryPercent } ?? false
        let recovered = battery.map { $0.onAC || $0.percent > MonitorAlerts.batteryPercent + 2 } ?? true
        track(.battery, over: low, reset: recovered, samples: 1)
        return started
    }

    /// Words for an alert, with the latest value.
    public func message(_ kind: MonitorAlertKind) -> String {
        switch kind {
        case .cpu:
            return "CPU has been above \(Int(cpuThreshold))% for 30 seconds (\(MonitorFormat.percent(last.cpuBusy ?? 0)) now)"
        case .memory:
            return last.pressureLevel >= 4 ? "Memory pressure is critical" : "Memory pressure is high"
        case .disk:
            return "The startup disk is \(MonitorFormat.percent(last.diskUsedPercent ?? 0)) full"
        case .temperature:
            return "The CPU is at \(MonitorFormat.temperature(last.cpuTemperature ?? 0))C"
        case .battery:
            return "Battery at \(MonitorFormat.percent(last.battery?.percent ?? 0)); connect power soon"
        }
    }

    public var messages: [String] {
        MonitorAlertKind.allCases.filter { active.contains($0) }.map(message)
    }
}
