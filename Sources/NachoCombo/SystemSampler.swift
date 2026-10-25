import Foundation
import Darwin
import IOKit
import SystemConfiguration
import NachoComboCore

struct VolumeInfo: Equatable {
    var name: String
    var total: Int64
    /// Free space including purgeable files (what Finder calls "available").
    var available: Int64
    /// Free space without purgeable files.
    var free: Int64
    var usedPercent: Double { total > 0 ? Double(total - available) / Double(total) * 100 : 0 }
    var used: Int64 { max(0, total - available) }
    var purgeable: Int64 { max(0, available - free) }
}

struct InterfaceInfo: Equatable {
    enum Kind { case ethernet, wifi }
    var bsdName: String
    var displayName: String
    var kind: Kind
    var isActive: Bool
    var addresses: [String]
}

struct GPUStats {
    var utilization: Double
    var memoryInUse: UInt64?
    var memoryAllocated: UInt64?
}

/// Thin wrappers over Mach / BSD / IOKit counters (all public APIs, no permission needed).
/// Pure math lives in NachoComboCore.
enum SystemSampler {
    // MARK: CPU

    static func cpuTicks() -> CPUTicks? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
    }

    /// One tick snapshot per logical CPU.
    static func perCoreTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let array = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: array)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: array[cpu * stride + Int(state)])) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    /// true = efficiency core, per logical CPU. Read from the device tree ("cluster-type" E/P);
    /// falls back to "efficiency cores come first" (Apple silicon) or all-performance (Intel).
    static func efficiencyCoreFlags(count: Int) -> [Bool] {
        var flags = [Bool](repeating: false, count: count)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        var found = false
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                var child = IOIteratorNext(iterator)
                while child != 0 {
                    if let type = property(child, "cluster-type") as? Data, let first = type.first,
                       let id = (property(child, "logical-cpu-id") as? NSNumber)?.intValue, id >= 0, id < count {
                        flags[id] = first == UInt8(ascii: "E")
                        found = true
                    }
                    IOObjectRelease(child)
                    child = IOIteratorNext(iterator)
                }
            }
        }
        if !found, let efficiency = sysctlInt("hw.perflevel1.logicalcpu"), sysctlString("hw.perflevel1.name") == "Efficiency" {
            for i in 0..<min(efficiency, count) { flags[i] = true }
        }
        return flags
    }

    static func chipName() -> String { sysctlString("machdep.cpu.brand_string") ?? "" }

    /// Nominal clock (Intel only; Apple silicon has no such sysctl).
    static func nominalCPUMHz() -> Double? { sysctlInt64("hw.cpufrequency").map { Double($0) / 1_000_000 } }

    static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        return getloadavg(&values, 3) == 3 ? values : []
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    // MARK: Memory

    struct MemoryDetail {
        var breakdown: MemoryBreakdown
        var pageins: UInt64
        var pageouts: UInt64
    }

    static func memoryDetail() -> MemoryDetail? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let breakdown = MemoryBreakdown(
            total: ProcessInfo.processInfo.physicalMemory, pageSize: UInt64(getpagesize()),
            internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
            externalPages: UInt64(stats.external_page_count), wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count))
        return MemoryDetail(breakdown: breakdown, pageins: UInt64(stats.pageins), pageouts: UInt64(stats.pageouts))
    }

    /// Memory pressure in percent (100 − kernel "memory free level") and the kernel level (1 normal, 2 warn, 4 critical).
    static func memoryPressure() -> (percent: Double, level: Int)? {
        guard let free = sysctlInt("kern.memorystatus_level") else { return nil }
        let level = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return (Double(max(0, min(100, 100 - free))), level)
    }

    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    // MARK: Disk

    /// Bytes read / written since boot, summed over all block storage drivers.
    static func diskCounters() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        forEachService("IOBlockStorageDriver") { entry in
            guard let stats = property(entry, "Statistics") as? [String: Any] else { return }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    static func volumeInfo() -> VolumeInfo? {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let available = max(free, values.volumeAvailableCapacityForImportantUsage ?? free)
        return VolumeInfo(name: values.volumeName ?? "Macintosh HD", total: Int64(total), available: available, free: free)
    }

    /// SMART log of the first SMART-capable NVMe drive, read through the public IONVMeSMARTInterface
    /// (IOKit/storage/nvme/NVMeSMARTLibExternal.h; no privileges needed).
    static func ssdHealth() -> SMARTHealth? {
        var health: SMARTHealth?
        forEachService("IOBlockStorageDevice") { entry in
            guard health == nil, (property(entry, "NVMe SMART Capable") as? Bool) == true else { return }
            health = NVMeSMART.read(entry)
        }
        return health
    }

    /// Product name of the internal solid-state drive, e.g. "APPLE SSD AP1024R".
    static func internalSSDName() -> String? {
        var name: String?
        forEachService("IOBlockStorageDevice") { entry in
            guard name == nil,
                  let device = property(entry, "Device Characteristics") as? [String: Any],
                  let proto = property(entry, "Protocol Characteristics") as? [String: Any],
                  (device["Medium Type"] as? String) == "Solid State",
                  (proto["Physical Interconnect Location"] as? String) == "Internal",
                  let product = (device["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !product.isEmpty else { return }
            name = product
        }
        return name
    }

    // MARK: GPU

    static func gpuStats() -> GPUStats? {
        var best: GPUStats?
        forEachService("IOAccelerator") { entry in
            guard let stats = property(entry, "PerformanceStatistics") as? [String: Any] else { return }
            guard let util = (stats["Device Utilization %"] as? NSNumber) ?? (stats["GPU Activity(%)"] as? NSNumber) else { return }
            let current = GPUStats(utilization: util.doubleValue,
                                   memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value,
                                   memoryAllocated: (stats["Alloc system memory"] as? NSNumber)?.uint64Value)
            if best == nil || current.utilization > best!.utilization { best = current }
        }
        return best
    }

    // MARK: Network

    static func networkCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var result: [String: (rx: UInt64, tx: UInt64)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = entry.ifa_data,
               (entry.ifa_flags & UInt32(IFF_UP)) != 0, (entry.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                let name = String(cString: entry.ifa_name)
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                result[name] = (UInt64(counters.ifi_ibytes), UInt64(counters.ifi_obytes))
            }
            cursor = entry.ifa_next
        }
        return result
    }

    /// Wi-Fi interfaces (always) and Ethernet interfaces that are up with an IPv4 address.
    static func interfaces() -> [InterfaceInfo] {
        var addresses: [String: [String]] = [:]
        var running = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&head) == 0, let first = head {
            defer { freeifaddrs(head) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let current = cursor {
                let entry = current.pointee
                let name = String(cString: entry.ifa_name)
                let flags = entry.ifa_flags
                if (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_RUNNING)) != 0 { running.insert(name) }
                if let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        addresses[name, default: []].append(String(cString: host))
                    }
                }
                cursor = entry.ifa_next
            }
        }
        var result: [InterfaceInfo] = []
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            let kind: InterfaceInfo.Kind
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = .wifi }
            else if type == (kSCNetworkInterfaceTypeEthernet as String) { kind = .ethernet }
            else { continue }
            let ips = addresses[bsd] ?? []
            let active = running.contains(bsd) && !ips.isEmpty
            if kind == .ethernet && !active { continue }
            let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd
            result.append(InterfaceInfo(bsdName: bsd, displayName: display, kind: kind, isActive: active, addresses: ips))
        }
        return result.sorted { ($0.isActive ? 0 : 1, $0.bsdName) < ($1.isActive ? 0 : 1, $1.bsdName) }
    }

    // MARK: Helpers

    static func forEachService(_ className: String, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Mirrors the head of IONVMeSMARTInterface (IUNKNOWN_C_GUTS, version, revision, SMARTReadData…).
private struct NVMeSMARTInterface {
    var reserved: UnsafeMutableRawPointer?
    var queryInterface: UnsafeMutableRawPointer?
    var addRef: UnsafeMutableRawPointer?
    var release: (@convention(c) (UnsafeMutableRawPointer?) -> UInt32)?
    var version: UInt16
    var revision: UInt16
    var smartReadData: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> kern_return_t)?
}

private enum NVMeSMART {
    // kIONVMeSMARTUserClientTypeID, kIONVMeSMARTInterfaceID and kIOCFPlugInInterfaceID are C macros,
    // which Swift does not import.
    static let userClientType = uuid(0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    static let smartInterface = uuid(0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    static let plugInInterface = uuid(0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)

    private static func uuid(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8, _ b5: UInt8, _ b6: UInt8, _ b7: UInt8,
                             _ b8: UInt8, _ b9: UInt8, _ b10: UInt8, _ b11: UInt8, _ b12: UInt8, _ b13: UInt8, _ b14: UInt8,
                             _ b15: UInt8) -> CFUUID {
        CFUUIDGetConstantUUIDWithBytes(nil, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15)
    }

    static func read(_ device: io_registry_entry_t) -> SMARTHealth? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(device, userClientType, plugInInterface, &plugIn, &score) == KERN_SUCCESS,
              let plugIn = plugIn, let plugInTable = plugIn.pointee else { return nil }
        // Release() alone keeps the (single-open) user client alive, and every later open fails with
        // kIOReturnNoResources; IODestroyPlugInInterface closes it.
        defer { IODestroyPlugInInterface(plugIn) }
        var raw: LPVOID?
        guard plugInTable.pointee.QueryInterface(plugIn, CFUUIDGetUUIDBytes(smartInterface), &raw) == S_OK,
              let interface = raw else { return nil }
        let table = interface.assumingMemoryBound(to: UnsafeMutablePointer<NVMeSMARTInterface>.self).pointee.pointee
        defer { _ = table.release?(interface) }
        var log = [UInt8](repeating: 0, count: 512)
        let result = log.withUnsafeMutableBytes { table.smartReadData?(interface, $0.baseAddress) ?? kIOReturnUnsupported }
        return result == kIOReturnSuccess ? SMARTHealth(log: log) : nil
    }
}
