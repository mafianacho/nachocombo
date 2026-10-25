import Foundation
import IOKit
import NachoComboCore

/// CPU / GPU clocks from performance-state residency.
///
/// IOReport is a private system library (no public header). It is loaded with dlopen and every symbol is
/// optional: if anything is missing the sampler is simply unavailable and the UI shows "–".
/// Frequency tables come from the pmgr "voltage-states" properties (verified on M1 Pro).
final class IOReportSampler {
    struct Reading {
        var efficiencyMHz: Double?
        var performanceMHz: Double?
        var gpuMHz: Double?
        /// Busiest cluster's active clock, as shown next to "CPU".
        var cpuMHz: Double? { performanceMHz ?? efficiencyMHz }
    }

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateSamplesDelta
    private let channelGroup: ChannelString
    private let channelName: ChannelString
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency
    private let subscription: OpaquePointer
    private let subscribed: CFMutableDictionary
    private var previous: CFDictionary?

    private let efficiencyTable: [Double]
    private let performanceTable: [Double]
    private let gpuTable: [Double]

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let createSubscription = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", CreateSamples.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let channelGroup = symbol("IOReportChannelGetGroup", ChannelString.self),
              let channelName = symbol("IOReportChannelGetChannelName", ChannelString.self),
              let stateCount = symbol("IOReportStateGetCount", StateCount.self),
              let stateName = symbol("IOReportStateGetNameForIndex", StateName.self),
              let stateResidency = symbol("IOReportStateGetResidency", StateResidency.self) else { return nil }

        efficiencyTable = IOReportSampler.frequencyTable("voltage-states1-sram")
        performanceTable = IOReportSampler.frequencyTable("voltage-states5-sram")
        gpuTable = IOReportSampler.frequencyTable("voltage-states9")
        guard !efficiencyTable.isEmpty || !performanceTable.isEmpty else { return nil }

        guard let cpu = copyChannels("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() else { return nil }
        guard let channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, cpu) else { return nil }
        if let gpu = copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            let target = channels as NSMutableDictionary
            let mine = (target["IOReportChannels"] as? [Any]) ?? []
            let extra = ((gpu as NSDictionary)["IOReportChannels"] as? [Any]) ?? []
            target["IOReportChannels"] = mine + extra
        }
        var subscribedOut: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subscribedOut, 0, nil),
              let subscribed = subscribedOut?.takeRetainedValue() else { return nil }
        self.subscription = subscription
        self.subscribed = subscribed
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.channelGroup = channelGroup
        self.channelName = channelName
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
    }

    deinit { Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release() }

    var gpuMaxMHz: Double? { gpuTable.max() }

    /// Clocks averaged since the previous call (nil on the first call).
    func sample() -> Reading? {
        guard let current = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        defer { previous = current }
        guard let previous = previous,
              let delta = createDelta(previous, current, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }

        var eStates: [Double] = [], pStates: [Double] = [], gStates: [Double] = []
        for item in channels {
            let channel = item as CFDictionary
            let group = channelGroup(channel)?.takeUnretainedValue() as String? ?? ""
            let name = channelName(channel)?.takeUnretainedValue() as String? ?? ""
            let residencies = activeResidencies(channel)
            if group == "CPU Stats" && name.hasPrefix("ECPU") {
                IOReportSampler.accumulate(&eStates, residencies)
            } else if group == "CPU Stats" && name.hasPrefix("PCPU") {
                IOReportSampler.accumulate(&pStates, residencies)
            } else if group == "GPU Stats" && name == "GPUPH" {
                IOReportSampler.accumulate(&gStates, residencies)
            }
        }
        var reading = Reading()
        reading.efficiencyMHz = FrequencyMath.weightedFrequency(residencies: eStates, table: efficiencyTable)
        reading.performanceMHz = FrequencyMath.weightedFrequency(residencies: pStates, table: performanceTable)
        if !gpuTable.isEmpty {
            reading.gpuMHz = FrequencyMath.weightedFrequency(residencies: gStates, table: gpuTable) ?? 0
        }
        return reading
    }

    private func activeResidencies(_ channel: CFDictionary) -> [Double] {
        var result: [Double] = []
        let count = stateCount(channel)
        guard count > 0 else { return result }
        for index in 0..<count {
            let name = stateName(channel, index)?.takeUnretainedValue() as String? ?? ""
            guard FrequencyMath.isActiveState(name) else { continue }
            result.append(Double(max(0, stateResidency(channel, index))))
        }
        return result
    }

    private static func accumulate(_ total: inout [Double], _ values: [Double]) {
        if total.count < values.count { total += Array(repeating: 0, count: values.count - total.count) }
        for (i, v) in values.enumerated() { total[i] += v }
    }

    private static func frequencyTable(_ key: String) -> [Double] {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard entry != 0 else { return [] }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { return [] }
        return FrequencyMath.decodeVoltageStates([UInt8](data))
    }
}
