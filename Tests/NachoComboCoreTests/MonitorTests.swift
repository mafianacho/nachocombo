import XCTest
@testable import NachoComboCore

final class MonitorTests: XCTestCase {
    func testTimeSeriesBucketsAlignAndSkipGaps() {
        let series = TimeSeries(channels: 2, capacity: 100)
        // Samples every 2 s from t=100 to t=118, then a gap, then t=140.
        for i in 0..<10 { series.append(time: 100 + Double(i) * 2, values: [Double(i), 10]) }
        series.append(time: 140, values: [50, nil])
        let buckets = series.buckets(span: 60, count: 6, now: 141)  // width 10: [90,100)...[140,150)
        XCTAssertEqual(buckets.count, 6)
        XCTAssertNil(buckets[0])                                     // 90..100: nothing
        XCTAssertEqual(buckets[1]?[0] ?? -1, 2, accuracy: 1e-6)      // 100..108 → 0,1,2,3,4
        XCTAssertEqual(buckets[2]?[0] ?? -1, 7, accuracy: 1e-6)      // 110..118 → 5...9
        XCTAssertNil(buckets[3])                                     // 120..130 gap
        XCTAssertNil(buckets[4])
        XCTAssertEqual(buckets[5]?[0] ?? -1, 50, accuracy: 1e-6)
        XCTAssertEqual(buckets[5]?[1] ?? -1, 0, accuracy: 1e-6)      // NaN channel → 0 in a non-empty bucket
        let maxes = series.buckets(span: 60, count: 6, now: 141, reduction: .max)
        XCTAssertEqual(maxes[2]?[0] ?? -1, 9, accuracy: 1e-6)
        XCTAssertEqual(series.maximum(channel: 0, since: 105) ?? -1, 50, accuracy: 1e-6)
    }

    func testTimeSeriesPicksChannelsAndAverages() {
        let series = TimeSeries(channels: 3, capacity: 100)
        series.append(time: 100, values: [1, 10, nil])
        series.append(time: 102, values: [3, 20, nil])
        series.append(time: 112, values: [5, nil, 7])
        let picked = series.buckets(span: 20, count: 2, now: 112, channels: [2, 0])  // [100,110), [110,120)
        XCTAssertEqual(picked[0] ?? [], [0, 2])        // asked order; channel 2 missing there → 0
        XCTAssertEqual(picked[1] ?? [], [7, 5])
        let only = series.buckets(span: 20, count: 2, now: 112, channels: [2])
        XCTAssertNil(only[0])                          // a gap of the picked channel stays a gap
        XCTAssertEqual(only[1] ?? [], [7])
        XCTAssertEqual(series.mean(channel: 1, since: 0) ?? -1, 15, accuracy: 1e-6)  // gap at t=112 ignored
        XCTAssertEqual(series.mean(channel: 0, since: 101) ?? -1, 4, accuracy: 1e-6)
        XCTAssertNil(series.mean(channel: 2, since: 113))
    }

    func testSMARTHealthLog() {
        var log = [UInt8](repeating: 0, count: 512)
        log[1] = 0x34; log[2] = 0x01   // 308 K
        log[3] = 100                   // available spare
        log[5] = 6                     // 6% of the rated endurance used
        let health = SMARTHealth(log: log)
        XCTAssertEqual(health?.healthPercent, 94)
        XCTAssertEqual(health?.availableSpare, 100)
        XCTAssertEqual(health?.temperature ?? 0, 34.85, accuracy: 1e-6)
        log[5] = 120; log[1] = 0; log[2] = 0
        XCTAssertEqual(SMARTHealth(log: log)?.healthPercent, 0)
        XCTAssertNil(SMARTHealth(log: log)?.temperature)
        XCTAssertNil(SMARTHealth(log: [1, 2, 3]))
    }

    func testTimeSeriesRingWrapsAndRecent() {
        let series = TimeSeries(channels: 1, capacity: 3)
        for i in 1...5 { series.append(time: Double(i), values: [Double(i)]) }
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.recent(5, channel: 0).compactMap { $0 }, [3, 4, 5])
        XCTAssertEqual(series.latest(channel: 0), 5)
        series.append(time: 1, values: [9])  // clock went backwards → history restarts
        XCTAssertEqual(series.count, 1)
    }

    func testMemoryBreakdownMatchesActivityMonitorCategories() {
        let m = MemoryBreakdown(total: 1000 * 16, pageSize: 16, internalPages: 400, purgeablePages: 50,
                                externalPages: 100, wiredPages: 150, compressorPages: 200)
        XCTAssertEqual(m.app, 350 * 16)
        XCTAssertEqual(m.wired, 150 * 16)
        XCTAssertEqual(m.compressed, 200 * 16)
        XCTAssertEqual(m.cached, 150 * 16)
        XCTAssertEqual(m.used, 700 * 16)
        XCTAssertEqual(m.free, 300 * 16)
        XCTAssertEqual(m.usedPercent, 70, accuracy: 1e-6)
    }

    func testVoltageStatesAndWeightedFrequency() {
        // (0 Hz, 400 mV), (600 MHz, 565 mV), (2064 MHz, 721 mV)
        let bytes: [UInt8] = [0, 0, 0, 0, 0x90, 1, 0, 0,
                              0x00, 0x46, 0xc3, 0x23, 0x35, 2, 0, 0,
                              0x00, 0x24, 0x06, 0x7b, 0xd1, 2, 0, 0]
        let table = FrequencyMath.decodeVoltageStates(bytes)
        XCTAssertEqual(table, [600, 2064])
        XCTAssertEqual(FrequencyMath.weightedFrequency(residencies: [1, 3, 99], table: table) ?? 0, 1698, accuracy: 1e-6)
        XCTAssertNil(FrequencyMath.weightedFrequency(residencies: [0, 0], table: table))
        XCTAssertFalse(FrequencyMath.isActiveState("IDLE"))
        XCTAssertTrue(FrequencyMath.isActiveState("V4P0"))
    }

    func testCounterRateTracker() {
        let tracker = CounterRateTracker<String>()
        XCTAssertNil(tracker.update(["a": [100, 10]], at: 1))
        let rates = tracker.update(["a": [300, 5], "b": [1, 1]], at: 3)!
        XCTAssertEqual(rates["a"], [100, 0])   // second counter went backwards → 0
        XCTAssertNil(rates["b"])               // new key: no delta yet
    }

    func testProcessGroupingSumsHelpersIntoApp() {
        let chrome = "/Applications/Google Chrome.app"
        let usages = [
            ProcessUsage(pid: 1, name: "Google Chrome", path: chrome + "/Contents/MacOS/Google Chrome", cpuPercent: 5, memory: 100),
            ProcessUsage(pid: 2, name: "Google Chrome H", path: chrome + "/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", cpuPercent: 7, memory: 50),
            ProcessUsage(pid: 3, name: "zsh", path: "/bin/zsh", cpuPercent: 1, memory: 5),
            ProcessUsage(pid: 4, name: "zsh", path: "/bin/zsh", cpuPercent: 0, memory: 5),
        ]
        let groups = ProcessGrouping.group(usages)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "Google Chrome")
        XCTAssertEqual(groups[0].bundlePath, chrome)
        XCTAssertEqual(groups[0].processCount, 2)
        XCTAssertEqual(groups[0].cpuPercent, 12, accuracy: 1e-6)
        XCTAssertEqual(groups[0].memory, 150)
        XCTAssertEqual(groups[1].name, "zsh")
        XCTAssertEqual(groups[1].memory, 10)
        let top = ProcessGrouping.top(groups, count: 1) { $0.cpuPercent }
        XCTAssertEqual(top.map { $0.name }, ["Google Chrome"])
        XCTAssertNil(ProcessGrouping.appBundlePath(forExecutable: "/usr/sbin/cfprefsd"))
    }

    func testProcessGroupingMergesCodeSignCloneByBundleIdentifier() {
        let clone = "/private/var/folders/x/X/com.google.Chrome.code_sign_clone/c.1/Google Chrome.app.bundle"
        let app = "/Applications/Google Chrome.app"
        XCTAssertEqual(ProcessGrouping.appBundlePath(forExecutable: clone + "/Contents/MacOS/Google Chrome"), clone)
        XCTAssertEqual(ProcessGrouping.bundleDisplayName(clone), "Google Chrome")
        let usages = [
            ProcessUsage(pid: 1, name: "Google Chrome", path: clone + "/Contents/MacOS/Google Chrome", cpuPercent: 5),
            ProcessUsage(pid: 2, name: "Helper", path: app + "/Contents/Frameworks/F.framework/Helpers/H.app/Contents/MacOS/H", cpuPercent: 7),
        ]
        let ids = [clone: "com.google.Chrome", app: "com.google.Chrome"]
        let groups = ProcessGrouping.group(usages) { ids[$0] }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].bundlePath, app)
        XCTAssertEqual(groups[0].cpuPercent, 12, accuracy: 1e-6)
        XCTAssertEqual(ProcessGrouping.group(usages).count, 2)  // without identities they stay apart
    }

    func testNetTopParser() {
        let text = ",bytes_in,bytes_out,\nlaunchd.1,5904,0,\nGoogle Chrome H.984,1248,496,\nbad line\n"
        let rows = NetTopParser.parse(text)
        XCTAssertEqual(rows, [NetTopRow(pid: 1, name: "launchd", bytesIn: 5904, bytesOut: 0),
                              NetTopRow(pid: 984, name: "Google Chrome H", bytesIn: 1248, bytesOut: 496)])
    }

    func testPublicIPTraceAndFlag() {
        let parsed = PublicIPParser.parseTrace("fl=1\nh=www.cloudflare.com\nip=183.109.105.126\nloc=KR\n")
        XCTAssertEqual(parsed?.ip, "183.109.105.126")
        XCTAssertEqual(parsed?.country, "KR")
        XCTAssertNil(PublicIPParser.parseTrace("nothing here"))
        XCTAssertEqual(PublicIPParser.flag(forCountryCode: "kr"), "🇰🇷")
        XCTAssertEqual(PublicIPParser.flag(forCountryCode: "T1"), "")
    }

    func testSMCDecoding() {
        XCTAssertEqual(SMCDecoder.fourCC("TC0P"), 0x5443_3050)
        XCTAssertEqual(SMCDecoder.string(fromFourCC: 0x5443_3050), "TC0P")
        let f: Float = 47.25
        let b = withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) }
        XCTAssertEqual(SMCDecoder.decode(type: "flt ", bytes: b) ?? 0, 47.25, accuracy: 1e-6)
        XCTAssertEqual(SMCDecoder.decode(type: "sp78", bytes: [0x2f, 0x80]) ?? 0, 47.5, accuracy: 1e-6)
        XCTAssertEqual(SMCDecoder.decode(type: "fpe2", bytes: [0x0f, 0xa0]) ?? 0, 1000, accuracy: 1e-6)
        XCTAssertEqual(SMCDecoder.decode(type: "ui8 ", bytes: [2]), 2)
        XCTAssertNil(SMCDecoder.decode(type: "ioft", bytes: [1, 2, 3]))
    }

    func testSensorCatalogM1ProAndGenericFallback() {
        let keys: Set<String> = ["Tp01", "Tp05", "Tp09", "Tp0T", "Tg05", "Tg0D", "TH0x", "TB0T", "TB1T", "Ts0P", "TaLP", "TaRF"]
        let defs = SensorCatalog.definitions(chip: "Apple M1 Pro", keys: keys, storageName: "APPLE SSD AP1024R")
        XCTAssertEqual(defs.map { $0.label }, ["CPU Performance Core 1", "CPU Performance Core 2", "CPU Efficiency Core 1", "CPU Efficiency Core 2",
                                                "GPU 1", "GPU 2", "APPLE SSD AP1024R", "Battery",
                                                "Palm Rest 1", "Left Airflow 1", "Right Airflow 1"])
        let readings = ["Tp01": 50.0, "Tp05": 60, "Tp09": 40, "Tp0T": 0, "Tg05": 45, "Tg0D": 55, "TB0T": 30, "TB1T": 32]
        XCTAssertNil(SensorCatalog.value(of: defs[3], readings: readings))   // 0 °C is not a reading
        XCTAssertEqual(SensorCatalog.value(of: defs[7], readings: readings), 32)
        XCTAssertEqual(SensorCatalog.summary(defs, readings: readings) { $0.isCPU } ?? 0, 50, accuracy: 1e-6)
        XCTAssertEqual(SensorCatalog.summary(defs, readings: readings) { $0 == .gpu } ?? 0, 50, accuracy: 1e-6)

        let generic = SensorCatalog.definitions(chip: "Apple M3", keys: ["Tp01", "Te05", "Tg0f"], storageName: nil)
        XCTAssertEqual(generic.map { $0.label }, ["CPU Average", "CPU Max", "GPU Average"])
        let g = ["Tp01": 40.0, "Te05": 60]
        XCTAssertEqual(SensorCatalog.summary(generic, readings: g) { $0.isCPU } ?? 0, 50, accuracy: 1e-6)
        XCTAssertEqual(SensorCatalog.value(of: generic[1], readings: g), 60)
    }

    func testFormatting() {
        XCTAssertEqual(MonitorFormat.size(0), "0KB")
        XCTAssertEqual(MonitorFormat.size(16.2 * 1_073_741_824), "16.2GB")
        XCTAssertEqual(MonitorFormat.size(2.74 * 1_099_511_627_776), "2.74TB")
        XCTAssertEqual(MonitorFormat.size(422.6e9, decimal: true), "422.6GB")
        XCTAssertEqual(MonitorFormat.rate(48 * 1024), "48 KB/s")
        XCTAssertEqual(MonitorFormat.rate(24.6 * 1_048_576), "24.6 MB/s")
        XCTAssertEqual(MonitorFormat.compact(0), "-")
        XCTAssertEqual(MonitorFormat.compact(300 * 1024), "300K")
        XCTAssertEqual(MonitorFormat.compact(2.2 * 1_048_576), "2.2M")
        XCTAssertEqual(MonitorFormat.uptime(11 * 86_400 + 5 * 3600 + 59), "11 days, 5 hours")
        XCTAssertEqual(MonitorFormat.uptime(3 * 3600 + 12 * 60), "3 hours, 12 min")
        XCTAssertEqual(MonitorFormat.uptime(86_400 + 3600 + 7 * 60), "1 day, 1 hour")
        XCTAssertEqual(MonitorFormat.uptime(7 * 60 + 30), "7 min")
        XCTAssertEqual(MonitorFormat.grouped(1009), "1,009")
        XCTAssertEqual(MonitorFormat.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(MonitorFormat.rpm(1011.4), "1,011 rpm")
        XCTAssertEqual(MonitorFormat.gigahertz(3228), "3.23 GHz")
        XCTAssertEqual(MonitorFormat.watts(6.44), "6.4 W")
        XCTAssertEqual(MonitorFormat.watts(21.2), "21 W")
        XCTAssertEqual(SystemMath.fanPercent(rpm: 1200, minimum: 1200, maximum: 5800), 0)
        XCTAssertEqual(SystemMath.fanPercent(rpm: 3500, minimum: 1200, maximum: 5800), 50, accuracy: 1e-6)
    }

    func testMonitorSettingsDefaultsAndOldFiles() throws {
        let s = MonitorSettings.defaults
        XCTAssertEqual(s.shownItems, MonitorItem.allCases.filter { $0 != .battery })   // battery is opt-in
        XCTAssertFalse(s.publicIPLookup)
        XCTAssertEqual(s.range(for: "cpu"), .oneHour)
        // Old settings file without the monitor block, and a partial monitor block.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"enabledModules":{},"menuBarCollapsed":false}"#.utf8))
        XCTAssertEqual(old.monitorSettings, .defaults)
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"enabledModules":{},"menuBarCollapsed":false,"monitor":{"items":{"disk":false}}}"#.utf8))
        XCTAssertFalse(partial.monitorSettings.isShown(.disk))
        XCTAssertEqual(partial.monitorSettings.shownItems, [.cpu, .memory, .network, .sensors])
    }

    func testMonitorSettingsPersistThroughManager() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nacho-combo-test-\(UUID().uuidString)").appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        let manager = ModuleManager(store: store, modules: [])
        var changes = 0
        manager.onChange = { changes += 1 }
        var m = manager.settings.monitorSettings
        m.setShown(.sensors, false)
        m.setRange(.tenMinutes, for: "network")
        manager.setMonitorSettings(m)
        manager.setMonitorSettings(m)  // unchanged → no save, no notification
        XCTAssertEqual(changes, 1)
        let loaded = SettingsStore(url: url).load().monitorSettings
        XCTAssertFalse(loaded.isShown(.sensors))
        XCTAssertEqual(loaded.range(for: "network"), .tenMinutes)
    }
}

final class BatteryAlertTests: XCTestCase {
    func testBatteryParsing() throws {
        let source: [String: Any] = ["Type": "InternalBattery", "Current Capacity": 84, "Max Capacity": 100,
                                     "Is Charging": false, "Power Source State": "Battery Power", "Time to Empty": 254,
                                     "BatteryHealthCondition": "Normal"]
        let registry: [String: Any] = ["CycleCount": 212, "DesignCapacity": 6075, "AppleRawMaxCapacity": 5528,
                                       "Temperature": 3012, "Voltage": 12_480, "Amperage": NSNumber(value: UInt64(bitPattern: -1_250)),
                                       "AdapterDetails": ["Watts": 96]]
        let b = try XCTUnwrap(BatteryInfo(powerSource: source, registry: registry))
        XCTAssertEqual(b.percent, 84)
        XCTAssertFalse(b.onAC)
        XCTAssertEqual(b.stateText, "On Battery")
        XCTAssertEqual(b.minutesToEmpty, 254)
        XCTAssertNil(b.minutesToFull)
        XCTAssertEqual(b.cycleCount, 212)
        XCTAssertEqual(b.healthPercent ?? 0, 91, accuracy: 0.1)
        XCTAssertEqual(b.condition, "Normal", "no reported condition means normal")
        var named = source
        named["BatteryHealthCondition"] = "Service Recommended"
        named["BatteryHealth"] = "Check Battery"
        XCTAssertEqual(BatteryInfo(powerSource: named, registry: registry)?.condition, "Service Recommended")
        var nominal = registry
        nominal["NominalChargeCapacity"] = 4_678
        XCTAssertEqual(BatteryInfo(powerSource: source, registry: nominal)?.maxCapacity, 4_678)
        XCTAssertEqual(b.temperature ?? 0, 30.12, accuracy: 0.001)
        XCTAssertEqual(b.amperage ?? 0, -1.25, accuracy: 0.0001)
        XCTAssertEqual(b.power ?? 0, -15.6, accuracy: 0.01)
        XCTAssertNil(b.adapterWatts, "adapter watts only while on power")
        XCTAssertEqual(BatteryInfo.duration(minutes: 254), "4:14")
        XCTAssertEqual(BatteryInfo.duration(minutes: 42), "42 min")
        XCTAssertNil(BatteryInfo(powerSource: ["Type": "UPS", "Current Capacity": 1, "Max Capacity": 2], registry: [:]))
        // Still estimating (-1) is not a time.
        var estimating = source
        estimating["Time to Empty"] = -1
        XCTAssertNil(BatteryInfo(powerSource: estimating, registry: registry)?.minutesToEmpty)
    }

    func testAlertsNeedSustainedValuesAndRearm() {
        var alerts = MonitorAlerts(cpuThreshold: 90)
        func input(cpu: Double = 10, pressure: Int = 1, disk: Double = 50, temp: Double = 50, battery: BatteryInfo? = nil) -> MonitorAlertInput {
            MonitorAlertInput(cpuBusy: cpu, pressureLevel: pressure, diskUsedPercent: disk, cpuTemperature: temp, battery: battery)
        }
        for _ in 0..<(MonitorAlerts.cpuSamples - 1) { XCTAssertEqual(alerts.update(input(cpu: 95)), []) }
        XCTAssertEqual(alerts.update(input(cpu: 95)), [.cpu])
        XCTAssertEqual(alerts.update(input(cpu: 96)), [], "an active alert does not start again")
        XCTAssertTrue(alerts.active.contains(.cpu))
        _ = alerts.update(input(cpu: 88))                  // below the threshold but above the reset level: still active
        XCTAssertTrue(alerts.active.contains(.cpu))
        _ = alerts.update(input(cpu: 40))
        XCTAssertTrue(alerts.active.contains(.cpu), "one calm sample is not enough to end it")
        _ = alerts.update(input(cpu: 40))
        _ = alerts.update(input(cpu: 40))
        XCTAssertFalse(alerts.active.contains(.cpu))
        // A single spike never alerts.
        XCTAssertEqual(alerts.update(input(cpu: 99)), [])
        // Disk and battery start at once.
        XCTAssertEqual(Set(alerts.update(input(disk: 93, battery: BatteryInfo(percent: 8, charging: false, onAC: false)))),
                       [.disk, .battery])
        XCTAssertEqual(alerts.messages.count, 2)
        _ = alerts.update(input(disk: 50, battery: BatteryInfo(percent: 8, charging: true, onAC: true)))
        XCTAssertTrue(alerts.active.isEmpty)
        // Memory pressure that flickers between normal and warning stays one alert, not a new one each time.
        var memory = MonitorAlerts(cpuThreshold: 0)
        var starts = 0
        for i in 0..<60 { starts += memory.update(input(pressure: i < 6 || i % 2 == 0 ? 2 : 1)).count }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(memory.active.contains(.memory))
        for _ in 0..<MonitorAlerts.memoryClearSamples { _ = memory.update(input(pressure: 1)) }
        XCTAssertFalse(memory.active.contains(.memory))
        // CPU alert off.
        var off = MonitorAlerts(cpuThreshold: 0)
        for _ in 0..<40 { XCTAssertFalse(off.update(input(cpu: 100)).contains(.cpu)) }
    }

    func testBatteryItemIsOptIn() {
        XCTAssertFalse(MonitorSettings.defaults.isShown(.battery))
        XCTAssertTrue(MonitorSettings.defaults.isShown(.cpu))
        XCTAssertFalse(MonitorSettings.defaults.shownItems.contains(.battery))
    }
}
