import AppKit
import Darwin
import NachoComboCore

/// libproc entry points, resolved at run time because some SDKs do not export libproc to Swift.
enum LibProc {
    private typealias ListAllPids = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    private typealias PidRusage = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Int32
    private typealias PidString = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32

    private static func resolve<T>(_ name: String, _ type: T.Type) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }  // RTLD_DEFAULT
        return unsafeBitCast(pointer, to: type)
    }
    private static let listAllPidsFn = resolve("proc_listallpids", ListAllPids.self)
    private static let rusageFn = resolve("proc_pid_rusage", PidRusage.self)
    private static let pathFn = resolve("proc_pidpath", PidString.self)
    private static let nameFn = resolve("proc_name", PidString.self)

    static var isAvailable: Bool { listAllPidsFn != nil && rusageFn != nil && pathFn != nil }

    static func allPids() -> [Int32] {
        guard let list = listAllPidsFn else { return [] }
        var capacity = 2048
        while capacity <= 65_536 {
            var pids = [Int32](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { list($0.baseAddress, Int32($0.count)) }
            if count < 0 { return [] }
            if Int(count) < capacity { return pids.prefix(Int(count)).filter { $0 > 0 } }
            capacity *= 2
        }
        return []
    }

    /// Fails (nil) for processes of other users: macOS restricts this to the owner or root.
    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        guard let fn = rusageFn else { return nil }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { fn(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0)) }
        return result == 0 ? info : nil
    }

    static func path(_ pid: Int32) -> String? { string(pathFn, pid, capacity: 4096) }
    static func name(_ pid: Int32) -> String? { string(nameFn, pid, capacity: 256) }

    private static func string(_ fn: PidString?, _ pid: Int32, capacity: Int) -> String? {
        guard let fn = fn else { return nil }
        var buffer = [CChar](repeating: 0, count: capacity)
        let length = buffer.withUnsafeMutableBytes { fn(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Per-process CPU, memory and disk I/O for the processes the current user owns.
final class ProcessSampler {
    private struct Key: Hashable { let pid: Int32; let start: UInt64 }
    private var names: [Key: (path: String, name: String)] = [:]
    private let tracker = CounterRateTracker<Key>()
    private let nanosecondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
    }

    func reset() { tracker.reset() }

    /// Rates are 0 on the first call (they need two samples); memory is immediate.
    func sample(at time: Double) -> [ProcessUsage] {
        var counters: [Key: [UInt64]] = [:]
        var memory: [Key: UInt64] = [:]
        var seen: [Key: (path: String, name: String)] = [:]
        for pid in LibProc.allPids() {
            guard let info = LibProc.rusage(pid) else { continue }
            let key = Key(pid: pid, start: info.ri_proc_start_abstime)
            let meta: (path: String, name: String)
            if let cached = names[key] {
                meta = cached
            } else {
                let path = LibProc.path(pid) ?? ""
                meta = (path, LibProc.name(pid) ?? (path as NSString).lastPathComponent)
            }
            seen[key] = meta
            // CPU times are Mach ticks (not ns) on Apple silicon.
            counters[key] = [info.ri_user_time &+ info.ri_system_time, info.ri_diskio_bytesread, info.ri_diskio_byteswritten]
            memory[key] = info.ri_phys_footprint
        }
        names = seen
        let rates = tracker.update(counters, at: time) ?? [:]
        return seen.map { key, meta in
            let rate = rates[key]
            return ProcessUsage(pid: key.pid, name: meta.name, path: meta.path,
                                cpuPercent: (rate?[0] ?? 0) * nanosecondsPerTick / 1_000_000_000 * 100,
                                memory: memory[key] ?? 0, diskRead: rate?[1] ?? 0, diskWrite: rate?[2] ?? 0)
        }
    }
}

/// Localized names and icons for process groups (cached; icons are expensive).
final class ProcessPresentation {
    static let shared = ProcessPresentation()
    private var names: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private var identifiers: [String: String?] = [:]

    /// Bundle identifier of an app bundle path (cached), used to merge copies of one app.
    func bundleIdentifier(_ bundlePath: String) -> String? {
        if let cached = identifiers[bundlePath] { return cached }
        let id = Bundle(path: bundlePath)?.bundleIdentifier
        identifiers[bundlePath] = id
        return id
    }

    func group(_ usages: [ProcessUsage]) -> [ProcessGroupUsage] {
        ProcessGrouping.group(usages) { self.bundleIdentifier($0) }
    }

    func name(for group: ProcessGroupUsage) -> String {
        guard let bundle = group.bundlePath else { return group.name }
        if let cached = names[bundle] { return cached }
        var name = FileManager.default.displayName(atPath: bundle)
        if name.hasSuffix(".app") { name.removeLast(4) }
        names[bundle] = name
        return name
    }

    func icon(for group: ProcessGroupUsage) -> NSImage? {
        let path = group.bundlePath ?? group.path
        guard !path.isEmpty else { return nil }
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        icons[path] = icon
        return icon
    }
}
