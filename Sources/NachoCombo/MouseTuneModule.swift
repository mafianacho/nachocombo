import AppKit
import Carbon.HIToolbox
import NachoComboCore

/// Wheel mice made pleasant: their own scroll direction (trackpads keep natural scrolling), smooth scrolling, scroll
/// speed, back / forward on the side buttons and an optional Mission Control middle button. An event tap changes the
/// mouse's scroll and button events as they happen; trackpads and Magic Mouse send continuous scrolls and are left
/// alone. Keystrokes are never read.
final class MouseTuneModule: NSObject, FeatureModule, PermissionPrompting {
    var allowPermissionPrompt = false
    let id = ModuleID.mouseTune
    static let permissionMessage = "To change your mouse's scrolling and buttons, allow Nacho Combo in "
        + "\(GadgetPermission.accessibility.location)."
    /// Marks the scroll events this gadget posts, so its own tap lets them through.
    static let marker: Int64 = 0x4E43_4D54   // 'NCMT'

    var optionsProvider: () -> GadgetOptions = { .defaults }
    var onPermissionLost: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var promptedSinceEnabled = false
    private var options = GadgetOptions.defaults
    private var vertical = SmoothScroller()
    private var horizontal = SmoothScroller()
    private var remainder = (x: 0.0, y: 0.0)
    private var glide: Timer?
    private var lastStep = Date()
    private(set) var running = false
    private(set) var wheelEvents = 0
    private(set) var buttonEvents = 0

    var tapActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> ModuleState {
        let shouldPrompt = allowPermissionPrompt && !promptedSinceEnabled
        if allowPermissionPrompt { promptedSinceEnabled = true }
        guard WindowSnapModule.isTrusted(prompt: shouldPrompt) else { return .needsPermission(MouseTuneModule.permissionMessage) }
        options = optionsProvider()
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info = info else { return Unmanaged.passUnretained(event) }
            let module = Unmanaged<MouseTuneModule>.fromOpaque(info).takeUnretainedValue()
            return module.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return .failed("macOS refused the mouse event tap. Check Accessibility.")
        }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        running = true
        return .running
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        stopGlide()
        running = false
        promptedSinceEnabled = false
    }

    /// The tap reads options on every event; they are copied here instead of asking for them each time.
    func applyOptions() {
        options = optionsProvider()
        if !options.mouseSmooth { stopGlide() }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if !AXIsProcessTrusted() { DispatchQueue.main.async { [weak self] in self?.onPermissionLost?() } }
            return Unmanaged.passUnretained(event)
        case .scrollWheel:
            return scroll(event)
        case .otherMouseDown, .otherMouseUp:
            return button(event, down: type == .otherMouseDown)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: scrolling

    private func scroll(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        guard event.getIntegerValueField(.eventSourceUserData) != MouseTuneModule.marker,
              event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return Unmanaged.passUnretained(event) }
        let reverse = options.mouseReverse, speed = options.mouseSpeed
        guard reverse || speed != 1 || options.mouseSmooth else { return Unmanaged.passUnretained(event) }
        wheelEvents += 1
        let lineY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let lineX = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        if options.mouseSmooth {
            // The notch becomes a glide of pixel scrolls; the original line scroll is dropped.
            let pointY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let pointX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            let y = pointY != 0 ? pointY : lineY * ScrollTuning.pointsPerLine
            let x = pointX != 0 ? pointX : lineX * ScrollTuning.pointsPerLine
            if y != 0 { vertical.add(ScrollTuning.adjusted(y, reverse: reverse, speed: speed)) }
            if x != 0 { horizontal.add(ScrollTuning.adjusted(x, reverse: reverse, speed: speed)) }
            startGlide()
            return nil
        }
        for (line, fixed, point) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1,
                                      CGEventField.scrollWheelEventPointDeltaAxis1),
                                     (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2,
                                      .scrollWheelEventPointDeltaAxis2)] {
            let lines = Double(event.getIntegerValueField(line))
            guard lines != 0 else { continue }
            var adjusted = ScrollTuning.adjusted(lines, reverse: reverse, speed: speed).rounded()
            if adjusted == 0 { adjusted = (reverse ? -lines : lines).sign == .minus ? -1 : 1 }
            event.setIntegerValueField(line, value: Int64(adjusted))
            event.setDoubleValueField(fixed, value: ScrollTuning.adjusted(event.getDoubleValueField(fixed), reverse: reverse,
                                                                          speed: speed))
            event.setDoubleValueField(point, value: ScrollTuning.adjusted(event.getDoubleValueField(point), reverse: reverse,
                                                                          speed: speed))
        }
        return Unmanaged.passUnretained(event)
    }

    private func startGlide() {
        guard glide == nil else { return }
        lastStep = Date()
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.glideStep() }
        RunLoop.main.add(t, forMode: .common)
        glide = t
    }

    private func stopGlide() {
        glide?.invalidate()
        glide = nil
        vertical.reset()
        horizontal.reset()
        remainder = (0, 0)
    }

    private func glideStep() {
        let now = Date()
        let dt = min(0.05, now.timeIntervalSince(lastStep))
        lastStep = now
        let y = vertical.step(dt: dt) + remainder.y
        let x = horizontal.step(dt: dt) + remainder.x
        let whole = (x: x.rounded(.towardZero), y: y.rounded(.towardZero))
        remainder = (x - whole.x, y - whole.y)
        if whole.x != 0 || whole.y != 0,
           let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(whole.y),
                               wheel2: Int32(whole.x), wheel3: 0) {
            event.setIntegerValueField(.eventSourceUserData, value: MouseTuneModule.marker)
            event.post(tap: .cgSessionEventTap)
        }
        if vertical.isIdle && horizontal.isIdle {
            glide?.invalidate()
            glide = nil
            remainder = (0, 0)
        }
    }

    // MARK: buttons

    private func button(_ event: CGEvent, down: Bool) -> Unmanaged<CGEvent>? {
        let number = event.getIntegerValueField(.mouseEventButtonNumber)
        switch number {
        case 3 where options.mouseSideButtons, 4 where options.mouseSideButtons:
            buttonEvents += 1
            // Back and forward are ⌘[ and ⌘] in browsers, Finder and most document apps.
            if down { MouseTuneModule.press(number == 3 ? kVK_ANSI_LeftBracket : kVK_ANSI_RightBracket, flags: .maskCommand) }
            return nil
        case 2 where options.mouseMiddle == .missionControl:
            buttonEvents += 1
            if down {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
                }
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    static func press(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    var diagnostics: [String: String] {
        [
            "running": "\(running)",
            "tapActive": "\(tapActive)",
            "gliding": "\(glide != nil)",
            "wheelEvents": "\(wheelEvents)",
            "buttonEvents": "\(buttonEvents)",
            "reverse": "\(options.mouseReverse)",
            "smooth": "\(options.mouseSmooth)",
            "speed": String(format: "%.2f", options.mouseSpeed),
        ]
    }
}
