import AppKit
import NachoComboCore

final class SystemMonitorModule: NSObject, FeatureModule {
    let id = ModuleID.systemMonitor
    private let interval: TimeInterval = 2

    private var item: NSStatusItem?
    private var timer: Timer?
    private var cpuLine, memLine, netLine, netTotalLine: NSMenuItem?
    private var lastCPU: CPUTicks?
    private let network = NetworkRateTracker()
    private(set) var sampleCount = 0

    /// Latest numbers, shared by the menu bar text and the quick panel.
    struct Reading {
        var cpuBusy: Double?
        var memPercent: Double?
        var memUsed: UInt64 = 0
        var memTotal: UInt64 = 0
        var rx: Double?
        var tx: Double?
    }
    private(set) var latest = Reading()
    private var lastRxRate = 0.0, lastTxRate = 0.0

    var isRunning: Bool { item != nil }

    func start() -> ModuleState {
        guard item == nil else { return .running }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem.button?.title = "CPU – MEM – ↓– ↑–"
        let menu = NSMenu()
        cpuLine = menu.addItem(withTitle: "CPU: …", action: nil, keyEquivalent: "")
        memLine = menu.addItem(withTitle: "메모리: …", action: nil, keyEquivalent: "")
        netLine = menu.addItem(withTitle: "네트워크: …", action: nil, keyEquivalent: "")
        netTotalLine = menu.addItem(withTitle: "누적: …", action: nil, keyEquivalent: "")
        statusItem.menu = menu
        item = statusItem

        // Baselines so the first visible reading is a real delta, not a since-boot average.
        lastCPU = SystemSampler.cpuTicks()
        _ = network.update(counters: SystemSampler.networkCounters(), at: Date.timeIntervalSinceReferenceDate)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)  // keeps ticking while the menu is open
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sample() }
        return .running
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let item = item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        cpuLine = nil; memLine = nil; netLine = nil; netTotalLine = nil
        lastCPU = nil
        lastRxRate = 0; lastTxRate = 0
        latest = Reading()
    }

    private func sample() {
        guard item != nil else { return }
        sampleCount += 1
        var cpuText = "–", memText = "–", down = "–", up = "–"

        if let now = SystemSampler.cpuTicks() {
            if let prev = lastCPU, let usage = SystemMath.cpuUsage(previous: prev, current: now) {
                latest.cpuBusy = usage.busy
                cpuText = String(format: "%.0f%%", usage.busy)
                cpuLine?.title = String(format: "CPU: 사용자 %.1f%%  시스템 %.1f%%  유휴 %.1f%%",
                                        usage.user, usage.system, usage.idle)
            }
            lastCPU = now
        }
        if let mem = SystemSampler.memory() {
            let percent = SystemMath.memoryPercent(used: mem.used, total: mem.total)
            latest.memPercent = percent; latest.memUsed = mem.used; latest.memTotal = mem.total
            memText = String(format: "%.0f%%", percent)
            memLine?.title = "메모리: \(SystemMath.formatBytes(mem.used)) / \(SystemMath.formatBytes(mem.total)) (" + String(format: "%.0f%%)", percent)
        }
        let counters = SystemSampler.networkCounters()
        if let rate = network.update(counters: counters, at: Date.timeIntervalSinceReferenceDate) {
            lastRxRate = rate.rx; lastTxRate = rate.tx
            latest.rx = rate.rx; latest.tx = rate.tx
            down = SystemMath.formatRateCompact(rate.rx)
            up = SystemMath.formatRateCompact(rate.tx)
            netLine?.title = "네트워크: ↓ \(down)/s  ↑ \(up)/s"
        }
        var rxTotal: UInt64 = 0, txTotal: UInt64 = 0
        for (name, c) in counters where SystemMath.isCountedInterface(name) { rxTotal &+= c.rx; txTotal &+= c.tx }
        netTotalLine?.title = "누적(부팅 후, en*): ↓ \(SystemMath.formatBytes(rxTotal))  ↑ \(SystemMath.formatBytes(txTotal))"
        item?.button?.title = "CPU \(cpuText) MEM \(memText) ↓\(down) ↑\(up)"
    }

    var diagnostics: [String: String] {
        [
            "statusItems": item == nil ? "0" : "1",
            "timerActive": "\(timer?.isValid ?? false)",
            "sampleCount": "\(sampleCount)",
            "lastRxBytesPerSec": String(format: "%.0f", lastRxRate),
            "lastTxBytesPerSec": String(format: "%.0f", lastTxRate),
        ]
    }
}
