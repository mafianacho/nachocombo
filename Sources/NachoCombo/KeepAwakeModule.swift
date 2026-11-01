import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import NachoComboCore

/// Keeps the Mac (and, if chosen, the display) awake with a power assertion, the same request a video player makes:
/// by hand from the cup in the menu bar, for a while, or while chosen apps run. The battery guard lets go when the
/// battery runs low. Owns one status item; `stop()` releases it and the assertion.
final class KeepAwakeModule: NSObject, FeatureModule, NSMenuDelegate {
    let id = ModuleID.keepAwake
    var optionsProvider: () -> GadgetOptions = { .defaults }
    var onChange: (() -> Void)?
    var openSettings: (() -> Void)?
    /// Options changed from the cup's menu (display on / off).
    var setOptions: ((GadgetOptions) -> Void)?

    private var item: NSStatusItem?
    private var assertion: IOPMAssertionID = 0
    private var assertionKeepsDisplay = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var running = false
    private(set) var manual = false
    private(set) var until: Date?
    private(set) var decision: KeepAwakeDecision = .sleepAllowed

    var holding: Bool { assertion != 0 }

    func start() -> ModuleState {
        guard !running else { return .running }
        running = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        _ = item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        self.item = item
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.evaluate() })
        }
        // Timed holds, the battery guard and the minutes in the menu bar follow this light tick.
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.evaluate() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        evaluate()
        return .running
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        release()
        if let item = item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        manual = false
        until = nil
        decision = .sleepAllowed
        running = false
    }

    /// The cup: on for the chosen time, or off again.
    func toggle() {
        guard running else { return }
        if manual { letSleep() } else { hold(minutes: optionsProvider().keepAwakeMinutes) }
        onChange?()
    }

    func hold(minutes: Int) {
        guard running else { return }
        manual = true
        until = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        evaluate()
    }

    func letSleep() {
        manual = false
        until = nil
        evaluate()
    }

    func applyOptions() { evaluate() }

    func evaluate() {
        guard running else { return }
        let options = optionsProvider()
        let now = Date()
        if let end = until, now >= end { manual = false; until = nil }
        let power = KeepAwakeModule.powerState()
        let before = decision
        decision = KeepAwakePolicy.decide(manual: manual, until: until, now: now, runningApp: runningChosenApp(options),
                                          onBattery: power.onBattery, batteryPercent: power.percent, options: options)
        if decision.holds { acquire(keepDisplay: options.keepAwakeDisplay) } else { release() }
        refreshItem()
        if decision != before { onChange?() }
    }

    // MARK: power assertion

    private func acquire(keepDisplay: Bool) {
        if assertion != 0 && assertionKeepsDisplay == keepDisplay { return }
        release()
        let type = keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        var newID: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "Nacho Combo Keep Awake" as CFString, &newID) == kIOReturnSuccess {
            assertion = newID
            assertionKeepsDisplay = keepDisplay
        }
    }

    private func release() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    /// Whether the Mac runs on its battery now, and the charge (nil without a battery).
    static func powerState() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (onBattery, current * 100 / maximum)
        }
        return (onBattery, nil)
    }

    private func runningChosenApp(_ options: GadgetOptions) -> String? {
        guard !options.keepAwakeApps.isEmpty else { return nil }
        let wanted = Set(options.keepAwakeApps)
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier.map(wanted.contains) ?? false }?.localizedName
    }

    // MARK: status item

    private func refreshItem() {
        guard let button = item?.button else { return }
        let on = decision.holds
        let symbol = on ? "cup.and.saucer.fill" : "cup.and.saucer"
        if let image = UI.symbol(symbol, size: 14, description: "Keep Awake") {
            image.isTemplate = true
            button.image = image
        }
        var title = ""
        if on, manual, let end = until { title = " " + KeepAwakePolicy.remainingText(until: end, now: Date()) }
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        button.appearsDisabled = !on
        button.toolTip = "Keep Awake — \(decision.text)"
        button.setAccessibilityLabel("Keep Awake")
        button.setAccessibilityValue(decision.text)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        toggle()
    }

    private func showMenu() {
        guard let item = item else { return }
        let menu = NSMenu()
        menu.delegate = self
        let state = NSMenuItem(title: decision.text, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let header = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for minutes in GadgetOptions.keepAwakeChoices {
            let entry = ClosureMenuItem(title: KeepAwakePolicy.durationName(minutes)) { [weak self] in self?.hold(minutes: minutes) }
            entry.indentationLevel = 1
            menu.addItem(entry)
        }
        if manual {
            menu.addItem(ClosureMenuItem(title: "Let the Mac Sleep") { [weak self] in self?.letSleep() })
        }
        menu.addItem(.separator())
        let display = ClosureMenuItem(title: "Keep the Display On") { [weak self] in
            guard let self = self else { return }
            var options = self.optionsProvider()
            options.keepAwakeDisplay.toggle()
            self.setOptions?(options)
        }
        display.state = optionsProvider().keepAwakeDisplay ? .on : .off
        menu.addItem(display)
        menu.addItem(ClosureMenuItem(title: "Keep Awake Settings…") { [weak self] in self?.openSettings?() })
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) { item?.menu = nil }

    var diagnostics: [String: String] {
        [
            "running": "\(running)",
            "statusItem": "\(item != nil)",
            "manual": "\(manual)",
            "until": until.map { ISO8601DateFormatter().string(from: $0) } ?? "-",
            "assertion": "\(assertion != 0)",
            "keepsDisplay": "\(assertion != 0 && assertionKeepsDisplay)",
            "decision": decision.text,
        ]
    }
}
