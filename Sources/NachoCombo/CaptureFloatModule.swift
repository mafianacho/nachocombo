import AppKit
import CoreGraphics
import NachoComboCore

/// ScreenFloat-style capture pinning: select a screen region, keep the picture on top of other windows.
/// Needs the Screen Recording permission (checked, never bypassed). No recording, OCR or cloud features.
final class CaptureFloatModule: NSObject, FeatureModule, PermissionPrompting {
    var allowPermissionPrompt = false
    let id = ModuleID.captureFloat
    static let hotKeyLabel = "⌃⌥C"
    static let permissionMessage =
        "화면을 캡처하려면 시스템 환경설정 ▸ 보안 및 개인 정보 보호 ▸ 화면 기록에서 Nacho Combo를 허용해야 합니다. 허용한 뒤 앱을 다시 실행해야 적용될 수 있습니다."

    private let hotKeys = HotKeyCenter(signature: 0x4E43_4350)   // 'NCCP'
    private(set) var floats: [FloatingCaptureWindow] = []
    private var selection: RegionSelectionController?
    private var promptedSinceEnabled = false
    private(set) var captureCount = 0
    private(set) var lastResult = "-"
    private(set) var running = false
    var onPermissionLost: (() -> Void)?

    static func hasAccess() -> Bool { CGPreflightScreenCaptureAccess() }

    func start() -> ModuleState {
        guard !running else { return .running }
        // The OS dialog is shown once per explicit opt-in; later re-checks stay silent.
        let shouldPrompt = allowPermissionPrompt && !promptedSinceEnabled
        if allowPermissionPrompt { promptedSinceEnabled = true }
        guard CaptureFloatModule.hasAccess() else {
            if shouldPrompt { _ = CGRequestScreenCaptureAccess() }
            return .needsPermission(CaptureFloatModule.permissionMessage)
        }
        running = true
        _ = hotKeys.register(id: 1, keyCode: 8, modifiers: HotKeySpec.controlKey | HotKeySpec.optionKey) { [weak self] in
            DispatchQueue.main.async { self?.beginSelection() }
        }
        return .running
    }

    func stop() {
        running = false
        promptedSinceEnabled = false
        hotKeys.unregisterAll()
        selection?.cancel()
        selection = nil
        for window in floats { window.onClosed = nil; window.orderOut(nil); window.close() }
        floats.removeAll()
    }

    // MARK: selection and capture

    func beginSelection() {
        guard running, selection == nil else { return }
        guard CaptureFloatModule.hasAccess() else { permissionLost(); return }
        let controller = RegionSelectionController()
        controller.onFinish = { [weak self] rect in
            self?.selection = nil
            if let rect = rect { self?.capture(cocoaRect: rect) } else { self?.lastResult = "cancelled" }
        }
        selection = controller
        controller.begin()
    }

    /// Captures a Cocoa-coordinate screen rectangle (after the selection UI has been closed).
    func capture(cocoaRect: CGRect) {
        guard running else { return }
        guard CaptureFloatModule.hasAccess() else { permissionLost(); return }
        // Give the window server a moment to drop the selection overlay before reading pixels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.finishCapture(cocoaRect: cocoaRect)
        }
    }

    private func finishCapture(cocoaRect: CGRect) {
        guard running, let primary = NSScreen.screens.first else { return }
        let cgRect = RegionSelection.captureRect(fromCocoa: cocoaRect, primaryScreenHeight: primary.frame.height)
        guard let image = CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            lastResult = "error:capture-failed"
            return
        }
        captureCount += 1
        lastResult = "ok:\(Int(cocoaRect.width))x\(Int(cocoaRect.height)) px:\(image.width)x\(image.height)"
        let window = FloatingCaptureWindow(cgImage: image, pointSize: cocoaRect.size, at: cocoaRect.origin)
        window.onClosed = { [weak self, weak window] in
            guard let self = self, let window = window else { return }
            self.floats.removeAll { $0 === window }
        }
        floats.append(window)
        window.orderFrontRegardless()
    }

    /// Debug/automation entry: capture a global (top-left origin) display rectangle without the selection UI.
    func captureGlobal(x: Double, y: Double, width: Double, height: Double) {
        guard let primary = NSScreen.screens.first else { return }
        let cocoa = CGRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
        capture(cocoaRect: cocoa)
    }

    private func permissionLost() {
        lastResult = "error:permission"
        hotKeys.unregisterAll()
        onPermissionLost?()
    }

    func window(at index: Int) -> FloatingCaptureWindow? {
        floats.indices.contains(index) ? floats[index] : nil
    }

    var diagnostics: [String: String] {
        [
            "hotkeysRegistered": "\(hotKeys.registeredCount)",
            "screenCaptureAccess": "\(CaptureFloatModule.hasAccess())",
            "selectionActive": "\(selection != nil)",
            "captureCount": "\(captureCount)",
            "floatCount": "\(floats.count)",
            "floats": floats.enumerated().map { index, w in
                let f = w.frame
                return "#\(index) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) pinned=\(w.pinned)"
            }.joined(separator: " | "),
            "lastResult": lastResult,
        ]
    }
}

// MARK: - Region selection

final class RegionSelectionController {
    var onFinish: ((CGRect?) -> Void)?
    private var windows: [SelectionPanel] = []
    private var finished = false

    func begin() {
        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen)
            panel.selectionView.onDone = { [weak self] rect in self?.finish(rect) }
            windows.append(panel)
            panel.orderFrontRegardless()
        }
        windows.first?.makeKey()
        NSCursor.crosshair.push()
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        for panel in windows { panel.orderOut(nil); panel.close() }
        windows.removeAll()
        onFinish?(rect)
    }
}

final class SelectionPanel: NSPanel {
    let selectionView = SelectionView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
        selectionView.autoresizingMask = [.width, .height]
        contentView = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var onDone: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let s = start else { return }
        let c = convert(event.locationInWindow, from: nil)
        let local = RegionSelection.clamp(RegionSelection.rect(from: s, to: c), to: bounds)
        start = nil
        current = nil
        guard RegionSelection.isCapturable(local), let window = window else { onDone?(nil); return }
        let inWindow = convert(local, to: nil)
        onDone?(window.convertToScreen(inWindow))
    }
    override func rightMouseDown(with event: NSEvent) { onDone?(nil) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) } else { super.keyDown(with: event) }   // Esc
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        guard let s = start, let c = current else { return }
        let rect = RegionSelection.rect(from: s, to: c)
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        label.draw(at: NSPoint(x: rect.minX + 4, y: max(rect.minY - 16, 2)), withAttributes: attrs)
    }
}

// MARK: - Floating capture window

final class FloatingCaptureWindow: NSPanel {
    let cgImage: CGImage
    let originalSize: CGSize
    private(set) var pinned = true
    var onClosed: (() -> Void)?
    private let canvas: CaptureCanvasView
    private let pinButton = NSButton()

    init(cgImage: CGImage, pointSize: CGSize, at origin: CGPoint) {
        self.cgImage = cgImage
        self.originalSize = pointSize
        canvas = CaptureCanvasView(image: NSImage(cgImage: cgImage, size: pointSize))
        super.init(contentRect: NSRect(origin: origin, size: pointSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        canvas.owner = self
        contentView = canvas
        canvas.buildControls(pinButton: pinButton)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        let handler = onClosed
        onClosed = nil
        super.close()
        handler?()
    }

    // MARK: actions

    func setPinned(_ value: Bool) {
        pinned = value
        isFloatingPanel = value
        level = value ? .floating : .normal
        pinButton.title = value ? "📌" : "◻︎"
        pinButton.toolTip = value ? "고정 해제" : "다시 고정"
        orderFrontRegardless()
    }

    func togglePin() { setPinned(!pinned) }

    func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: cgImage, size: originalSize)])
    }

    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    @discardableResult
    func save(to url: URL) -> Bool {
        guard let data = pngData() else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["png"]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "캡처 \(formatter.string(from: Date())).png"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { save(to: url) }
    }

    /// Resize keeping the aspect ratio, anchored at the top-left corner.
    func resize(toWidth width: CGFloat) {
        let maxSize = (screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 4000, height: 4000)
        let size = FloatSizing.resized(original: originalSize, proposedWidth: width, max: maxSize)
        let old = frame
        setFrame(NSRect(x: old.minX, y: old.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func resize(percent: Double) {
        resize(toWidth: FloatSizing.scaled(originalSize, percent: percent).width)
    }

    // Keyboard: ⌘C copy, ⌘S save, ⌘W / Esc close.
    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers ?? "", command) {
        case ("c", true): copyToPasteboard()
        case ("s", true): saveWithPanel()
        case ("w", true): close()
        default:
            if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
        }
    }
}

final class CaptureCanvasView: NSView {
    weak var owner: FloatingCaptureWindow?
    private let image: NSImage

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    func buildControls(pinButton: NSButton) {
        let close = Self.smallButton("✕", tip: "닫기", id: "float-close", action: #selector(closeTapped))
        close.target = self
        pinButton.title = "📌"
        pinButton.toolTip = "고정 해제"
        Self.style(pinButton)
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.setAccessibilityIdentifier("float-pin")
        pinButton.setAccessibilityLabel("고정 해제")
        let grip = ResizeGripView()
        grip.owner = owner
        grip.toolTip = "끌어서 크기 조절"
        for control in [close, pinButton] { addSubview(control) }
        addSubview(grip)
        close.frame = NSRect(x: 4, y: bounds.height - 22, width: 20, height: 18)
        pinButton.frame = NSRect(x: 26, y: bounds.height - 22, width: 22, height: 18)
        close.autoresizingMask = [.minYMargin]
        pinButton.autoresizingMask = [.minYMargin]
        grip.frame = NSRect(x: bounds.width - 18, y: 0, width: 18, height: 18)
        grip.autoresizingMask = [.minXMargin]
    }

    private static func style(_ button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = 4
        button.font = NSFont.systemFont(ofSize: 10, weight: .bold)
        button.setButtonType(.momentaryChange)
    }

    private static func smallButton(_ title: String, tip: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        style(button)
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 10, weight: .bold)])
        button.toolTip = tip
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(tip)
        return button
    }

    @objc private func closeTapped() { owner?.close() }
    @objc private func pinTapped() { owner?.togglePin() }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner = owner else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            menu.addItem(item)
        }
        add("복사") { owner.copyToPasteboard() }
        add("저장…") { owner.saveWithPanel() }
        menu.addItem(.separator())
        add(owner.pinned ? "고정 해제" : "다시 고정") { owner.togglePin() }
        add("원본 크기 (100%)") { owner.resize(percent: 100) }
        add("50%") { owner.resize(percent: 50) }
        add("200%") { owner.resize(percent: 200) }
        menu.addItem(.separator())
        add("닫기") { owner.close() }
        return menu
    }

    override func magnify(with event: NSEvent) {
        guard let owner = owner else { return }
        owner.resize(toWidth: owner.frame.width * (1 + event.magnification))
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func run() { handler() }
}

final class ResizeGripView: NSView {
    weak var owner: FloatingCaptureWindow?
    private var startMouse = NSPoint.zero
    private var startWidth: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        NSColor.white.setStroke()
        for offset in stride(from: CGFloat(5), through: 13, by: 4) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + offset))
            line.line(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 3))
            line.lineWidth = 1
            line.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startWidth = owner?.frame.width ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        owner?.resize(toWidth: startWidth + (now.x - startMouse.x))
    }
}
