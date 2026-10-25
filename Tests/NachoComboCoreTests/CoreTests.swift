import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NachoComboCore

final class FakeModule: FeatureModule {
    let id: ModuleID
    var result: ModuleState = .running
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var active = false
    init(_ id: ModuleID) { self.id = id }
    func start() -> ModuleState {
        startCount += 1
        if result == .running { active = true }
        return result
    }
    func stop() { stopCount += 1; active = false }
    var diagnostics: [String: String] { ["active": "\(active)"] }
}

final class CoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nacho-combo-test-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    func testDefaultsAreAllOff() {
        let s = SettingsStore(url: tempURL()).load()
        for id in ModuleID.allCases { XCTAssertFalse(s.isEnabled(id)) }
        XCTAssertFalse(s.menuBarCollapsed)
    }

    func testSettingsRoundTrip() throws {
        let store = SettingsStore(url: tempURL())
        var s = AppSettings.defaults
        s.setEnabled(.systemMonitor, true)
        s.menuBarCollapsed = true
        try store.save(s)
        let loaded = SettingsStore(url: store.url).load()
        XCTAssertEqual(loaded, s)
        XCTAssertTrue(loaded.isEnabled(.systemMonitor))
        XCTAssertFalse(loaded.isEnabled(.windowSnap))
    }

    func testCorruptSettingsFallBackToDefaultsAndKeepCopy() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = SettingsStore(url: url)
        XCTAssertEqual(store.load(), .defaults)
        XCTAssertNotNil(store.lastLoadProblem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    func testUnknownModuleKeysAreTolerated() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"enabledModules":{"menuBar":true,"future":true},"menuBarCollapsed":false}"#.utf8).write(to: url)
        let s = SettingsStore(url: url).load()
        XCTAssertTrue(s.isEnabled(.menuBar))
    }

    func testOffStopsModuleAndPersists() {
        let store = SettingsStore(url: tempURL())
        let monitor = FakeModule(.systemMonitor)
        let manager = ModuleManager(store: store, modules: [monitor])
        XCTAssertEqual(manager.setEnabled(.systemMonitor, true), .running)
        XCTAssertTrue(monitor.active)
        XCTAssertEqual(manager.setEnabled(.systemMonitor, false), .off)
        XCTAssertFalse(monitor.active)
        XCTAssertEqual(monitor.stopCount, 1)
        XCTAssertFalse(SettingsStore(url: store.url).load().isEnabled(.systemMonitor))
    }

    func testBootstrapStartsOnlyEnabledModules() throws {
        let store = SettingsStore(url: tempURL())
        var s = AppSettings.defaults
        s.setEnabled(.menuBar, true)
        try store.save(s)
        let a = FakeModule(.menuBar), b = FakeModule(.systemMonitor), c = FakeModule(.windowSnap)
        let manager = ModuleManager(store: store, modules: [a, b, c])
        manager.bootstrap()
        XCTAssertEqual(a.startCount, 1)
        XCTAssertEqual(b.startCount, 0)
        XCTAssertEqual(c.startCount, 0)
        XCTAssertEqual(manager.states[.menuBar], .running)
    }

    func testPermissionDeniedKeepsIntentAndRetryStarts() {
        let store = SettingsStore(url: tempURL())
        let snap = FakeModule(.windowSnap)
        snap.result = .needsPermission("Accessibility")
        let manager = ModuleManager(store: store, modules: [snap])
        XCTAssertEqual(manager.setEnabled(.windowSnap, true), .needsPermission("Accessibility"))
        XCTAssertTrue(manager.settings.isEnabled(.windowSnap))
        XCTAssertFalse(snap.active)
        snap.result = .running
        manager.retry(.windowSnap)
        XCTAssertEqual(manager.states[.windowSnap], .running)
        XCTAssertTrue(snap.active)
    }

    func testWindowLayoutHalvesCoverVisibleFrameWithoutGap() {
        let visible = CGRect(x: 0, y: 25, width: 1281, height: 700)
        let l = WindowLayout.target(for: .left, in: visible)
        let r = WindowLayout.target(for: .right, in: visible)
        XCTAssertEqual(l.maxX, r.minX)
        XCTAssertEqual(l.width + r.width, visible.width)
        XCTAssertEqual(l.height, visible.height)
        XCTAssertEqual(WindowLayout.target(for: .maximize, in: visible), visible)
    }

    func testAccessibilityCoordinateConversionRoundTrip() {
        let cocoa = CGRect(x: 100, y: 50, width: 400, height: 300)
        let origin = WindowLayout.accessibilityOrigin(forCocoa: cocoa, primaryScreenHeight: 800)
        XCTAssertEqual(origin, CGPoint(x: 100, y: 450))
        let back = WindowLayout.cocoaRect(fromAccessibilityOrigin: origin, size: cocoa.size, primaryScreenHeight: 800)
        XCTAssertEqual(back, cocoa)
    }

    func testScreenSelectionPrefersLargestOverlap() {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(WindowLayout.screenIndex(for: CGRect(x: 900, y: 100, width: 400, height: 300), screens: screens), 1)
        XCTAssertEqual(WindowLayout.screenIndex(for: CGRect(x: 100, y: 100, width: 400, height: 300), screens: screens), 0)
        XCTAssertEqual(WindowLayout.screenIndex(for: CGRect(x: 5000, y: 100, width: 10, height: 10), screens: screens), 1)
        XCTAssertNil(WindowLayout.screenIndex(for: .zero, screens: []))
    }

    func testCPUUsage() {
        let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let b = CPUTicks(user: 150, system: 80, idle: 880, nice: 50)
        let u = SystemMath.cpuUsage(previous: a, current: b)!
        XCTAssertEqual(u.user, 31.25, accuracy: 0.001)
        XCTAssertEqual(u.system, 18.75, accuracy: 0.001)
        XCTAssertEqual(u.idle, 50, accuracy: 0.001)
        XCTAssertNil(SystemMath.cpuUsage(previous: b, current: a))
        XCTAssertNil(SystemMath.cpuUsage(previous: a, current: a))
    }

    func testCounterWrapAndNetworkRates() {
        XCTAssertEqual(SystemMath.counterDelta(previous: 4_294_967_000, current: 100), 396)
        XCTAssertEqual(SystemMath.counterDelta(previous: 10, current: 25), 15)
        let tracker = NetworkRateTracker()
        XCTAssertNil(tracker.update(counters: ["en0": (1000, 500), "lo0": (9, 9)], at: 10))
        let rate = tracker.update(counters: ["en0": (3000, 1500), "utun1": (99999, 99999), "lo0": (50, 50)], at: 12)!
        XCTAssertEqual(rate.rx, 1000, accuracy: 0.001)
        XCTAssertEqual(rate.tx, 500, accuracy: 0.001)
    }

    func testFormatting() {
        XCTAssertEqual(SystemMath.formatRateCompact(0), "0B")
        XCTAssertEqual(SystemMath.formatRateCompact(2048), "2K")
        XCTAssertEqual(SystemMath.formatRateCompact(1_572_864), "1.5M")
        XCTAssertEqual(SystemMath.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(SystemMath.memoryPercent(used: 50, total: 200), 25, accuracy: 0.001)
        XCTAssertEqual(SystemMath.memoryPercent(used: 5, total: 0), 0)
    }
}
