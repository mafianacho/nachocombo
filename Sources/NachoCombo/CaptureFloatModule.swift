import AppKit
import CoreGraphics
import Vision
import NachoComboCore

/// Screen capture that stays on screen: select an area (or a window, or the whole screen) and the picture floats above
/// other windows, where it can be moved, resized, faded, locked click-through, marked up, copied, saved, dragged out
/// and read as text. A window can also float live, an area can be recorded to a movie on the Desktop, and any pixel's
/// color can be picked. Needs the Screen Recording permission (checked, never bypassed). Nothing leaves the Mac.
final class CaptureFloatModule: NSObject, FeatureModule, PermissionPrompting {
    enum Purpose { case float, copyText, live, record }

    var allowPermissionPrompt = false
    let id = ModuleID.captureFloat
    static let permissionMessage = "To capture the screen, allow Nacho Combo in "
        + "\(GadgetPermission.screenRecording.location). macOS may need Nacho Combo to restart before it applies."

    var optionsProvider: () -> GadgetOptions = { .defaults }
    private(set) var floats: [FloatingCaptureWindow] = []
    private var selection: RegionSelectionController?
    private var promptedSinceEnabled = false
    private(set) var captureCount = 0
    private(set) var lastResult = "-"
    private(set) var running = false
    /// Last captured area (Cocoa coordinates), for "Capture Previous Area".
    private(set) var lastArea: CGRect?
    private(set) var locked = false
    private(set) var hidden = false
    var onPermissionLost: (() -> Void)?
    var onChange: (() -> Void)?
    /// The recording item appeared in the menu bar: the divider is re-created so it is not hidden.
    var onStatusItemsChanged: (() -> Void)?
    private var recorder: AnyObject?
    private var recordItem: NSStatusItem?
    private var recordTimer: Timer?
    private(set) var lastRecording = "-"

    var recording: Bool { recorder != nil }

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
        return .running
    }

    func stop() {
        stopRecording()
        running = false
        promptedSinceEnabled = false
        selection?.cancel()
        selection = nil
        closeAll()
        locked = false
        hidden = false
        FloatingCaptureWindow.removeDragFiles()
    }

    // MARK: selection and capture

    func beginSelection(purpose: Purpose = .float, windowMode: Bool = false) {
        guard running, selection == nil else { return }
        guard CaptureFloatModule.hasAccess() else { permissionLost(); return }
        let hint: String
        switch purpose {
        case .copyText: hint = "Drag over text to copy it · Esc: cancel"
        case .live: hint = "Click a window to float it live · Space: an area instead · Esc: cancel"
        case .record: hint = "Drag over the area to record · Space: pick a window · Esc: cancel"
        case .float: hint = "Drag to capture an area · Space: pick a window · Esc: cancel"
        }
        let controller = RegionSelectionController(windowMode: windowMode || purpose == .live, hint: hint)
        controller.onFinish = { [weak self] result in
            guard let self = self else { return }
            self.selection = nil
            switch (result, purpose) {
            case (.area(let rect)?, .record), (.window(_, let rect)?, .record): self.startRecording(cocoa: rect)
            case (.area(let rect)?, .live): self.capture(cocoaRect: rect, purpose: .float)
            case (.area(let rect)?, _): self.capture(cocoaRect: rect, purpose: purpose)
            case (.window(let number, let frame)?, _): self.captureWindow(number, frame: frame, purpose: purpose)
            case (nil, _): self.lastResult = "cancelled"
            }
        }
        selection = controller
        controller.begin()
    }

    func capturePrevious() {
        guard let area = lastArea else { beginSelection(); return }
        capture(cocoaRect: area, purpose: .float)
    }

    /// The whole screen under the pointer, shown at half size.
    func captureScreen() {
        guard running else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        capture(cocoaRect: screen.frame, purpose: .float, scale: 0.5)
    }

    /// Captures a Cocoa-coordinate screen rectangle (after the selection UI has been closed).
    func capture(cocoaRect: CGRect, purpose: Purpose = .float, scale: CGFloat = 1) {
        guard running else { return }
        guard CaptureFloatModule.hasAccess() else { permissionLost(); return }
        // Give the window server a moment to drop the selection overlay before reading pixels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.finishCapture(cocoaRect: cocoaRect, purpose: purpose, scale: scale)
        }
    }

    private func finishCapture(cocoaRect: CGRect, purpose: Purpose, scale: CGFloat) {
        guard running, let primary = NSScreen.screens.first else { return }
        let cgRect = RegionSelection.captureRect(fromCocoa: cocoaRect, primaryScreenHeight: primary.frame.height)
        guard let image = CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]) else {
            lastResult = "error:capture-failed"
            return
        }
        if scale == 1 { lastArea = cocoaRect }
        deliver(image, frame: cocoaRect, purpose: purpose, scale: scale)
    }

    private func captureWindow(_ number: CGWindowID, frame: CGRect, purpose: Purpose) {
        guard running else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.running else { return }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number,
                                                      [.boundsIgnoreFraming, .bestResolution]) else {
                self.lastResult = "error:window-capture-failed"
                return
            }
            self.deliver(image, frame: frame, purpose: purpose, scale: 1, liveWindow: purpose == .live ? number : nil)
        }
    }

    private func deliver(_ image: CGImage, frame: CGRect, purpose: Purpose, scale: CGFloat, liveWindow: CGWindowID? = nil) {
        captureCount += 1
        lastResult = "ok:\(Int(frame.width))x\(Int(frame.height)) px:\(image.width)x\(image.height)"
        switch purpose {
        case .copyText:
            TextRecognizer.copyText(in: image, near: NSPoint(x: frame.midX, y: frame.midY))
        case .float, .live, .record:
            let size = CGSize(width: (frame.width * scale).rounded(), height: (frame.height * scale).rounded())
            var origin = frame.origin
            if scale != 1 { origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2) }
            let window = FloatingCaptureWindow(cgImage: image, pointSize: size, at: origin,
                                               rounded: optionsProvider().captureRoundedCorners)
            window.onClosed = { [weak self, weak window] in
                guard let self = self, let window = window else { return }
                self.floats.removeAll { $0 === window }
                self.onChange?()
            }
            window.onCloseAll = { [weak self] in self?.closeAll() }
            window.setLocked(locked)
            if let number = liveWindow { window.startLive(number) }
            floats.append(window)
            if hidden { hidden = false; floats.forEach { $0.orderFrontRegardless() } }
            window.orderFrontRegardless()
        }
        onChange?()
    }

    /// Debug/automation entry: capture a global (top-left origin) display rectangle without the selection UI.
    func captureGlobal(x: Double, y: Double, width: Double, height: Double) {
        guard let primary = NSScreen.screens.first else { return }
        let cocoa = CGRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
        capture(cocoaRect: cocoa)
    }

    // MARK: recording, color, live

    /// Starts by picking the area; while a recording runs, stops it.
    func toggleRecording() {
        guard running else { return }
        if recording { stopRecording() } else { beginSelection(purpose: .record) }
    }

    private func startRecording(cocoa rect: CGRect) {
        guard #available(macOS 12.3, *) else {
            Toast.show("Recording needs macOS 12.3 or later", near: NSEvent.mouseLocation)
            return
        }
        guard RegionSelection.isCapturable(rect) else { return }
        let recorder = ScreenRecorder(url: RecordingFiles.movieURL())
        recorder.onStop = { [weak self] url in self?.recordingEnded(url) }
        self.recorder = recorder
        lastRecording = "starting"
        recorder.start(cocoa: rect) { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.recorder = nil
                self.lastRecording = "error:\(error)"
                Toast.show("Recording did not start: \(error)", near: NSEvent.mouseLocation)
                self.onChange?()
                return
            }
            self.lastRecording = "recording"
            self.showRecordItem()
            self.onChange?()
        }
        onChange?()
    }

    func stopRecording() {
        guard let recorder = recorder else { return }
        if #available(macOS 12.3, *) { (recorder as? ScreenRecorder)?.stop() }
        self.recorder = nil
        removeRecordItem()
        onChange?()
    }

    private func recordingEnded(_ url: URL?) {
        guard let url = url else {
            lastRecording = "error:empty"
            Toast.show("Nothing was recorded", near: NSEvent.mouseLocation)
            return
        }
        lastRecording = "saved:\(url.lastPathComponent)"
        guard optionsProvider().recordGIF else {
            Toast.show("Saved “\(url.lastPathComponent)” to the Desktop", near: NSEvent.mouseLocation)
            return
        }
        Toast.show("Saved the movie; making the GIF…", near: NSEvent.mouseLocation)
        RecordingFiles.makeGIF(from: url) { [weak self] gif in
            self?.lastRecording = gif.map { "saved:\($0.lastPathComponent)" } ?? "error:gif"
            Toast.show(gif == nil ? "The GIF could not be made" : "Saved the movie and a GIF to the Desktop",
                       near: NSEvent.mouseLocation)
        }
    }

    private func showRecordItem() {
        guard recordItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = UI.symbol("record.circle.fill", size: 14, weight: .semibold, description: "Recording")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(recordItemClicked)
        item.button?.toolTip = "Recording — click to stop"
        item.button?.setAccessibilityLabel("Stop recording")
        recordItem = item
        let started = Date()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            let seconds = Int(Date().timeIntervalSince(started))
            self?.recordItem?.button?.attributedTitle = NSAttributedString(
                string: String(format: " %d:%02d", seconds / 60, seconds % 60),
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        }
        RunLoop.main.add(t, forMode: .common)
        t.fire()
        recordTimer = t
        onStatusItemsChanged?()
    }

    private func removeRecordItem() {
        recordTimer?.invalidate()
        recordTimer = nil
        if let item = recordItem { NSStatusBar.system.removeStatusItem(item) }
        recordItem = nil
    }

    @objc private func recordItemClicked() { stopRecording() }

    func pickColor() {
        guard running else { return }
        ColorPicker.pick { hex in
            guard let hex = hex else { return }
            Toast.show("Copied \(hex)", near: NSEvent.mouseLocation)
        }
    }

    /// Picks a window that keeps updating in its float.
    func beginLiveWindow() { beginSelection(purpose: .live, windowMode: true) }

    // MARK: all floats

    /// Click-through on / off for every float (a locked float cannot be clicked, so unlocking comes from here).
    func toggleLock() {
        locked.toggle()
        floats.forEach { $0.setLocked(locked) }
        onChange?()
    }

    func toggleHidden() {
        guard !floats.isEmpty else { hidden = false; return }
        hidden.toggle()
        floats.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
        onChange?()
    }

    func closeAll() {
        for window in floats { window.onClosed = nil; window.orderOut(nil); window.close() }
        floats.removeAll()
        hidden = false
        onChange?()
    }

    func applyOptions() {
        let rounded = optionsProvider().captureRoundedCorners
        floats.forEach { $0.setRounded(rounded) }
    }

    private func permissionLost() {
        lastResult = "error:permission"
        onPermissionLost?()
    }

    func window(at index: Int) -> FloatingCaptureWindow? {
        floats.indices.contains(index) ? floats[index] : nil
    }

    var diagnostics: [String: String] {
        [
            "screenCaptureAccess": "\(CaptureFloatModule.hasAccess())",
            "selectionActive": "\(selection != nil)",
            "captureCount": "\(captureCount)",
            "floatCount": "\(floats.count)",
            "locked": "\(locked)",
            "hidden": "\(hidden)",
            "previousArea": lastArea.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-",
            "floats": floats.enumerated().map { index, w in
                let f = w.frame
                return "#\(index) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) pinned=\(w.pinned) alpha=\(String(format: "%.2f", w.alphaValue))"
            }.joined(separator: " | "),
            "lastResult": lastResult,
            "recording": "\(recording)",
            "recordItem": "\(recordItem != nil)",
            "lastRecording": lastRecording,
            "liveFloats": "\(floats.filter { $0.isLive }.count)",
            "markedUp": "\(floats.filter { $0.annotationCount > 0 }.count)",
        ]
    }
}

// MARK: - Text recognition

/// On-device text and QR code recognition (Vision); results go to the clipboard with a short confirmation.
enum TextRecognizer {
    static func copyText(in image: CGImage, near point: NSPoint) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = recognize(image)
            DispatchQueue.main.async {
                guard !text.isEmpty else { Toast.show("No text found", near: point); return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                let lines = text.split(whereSeparator: \.isNewline).count
                Toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text", near: point)
            }
        }
    }

    /// QR payloads first (exact), then recognised text lines top to bottom.
    static func recognize(_ image: CGImage) -> String {
        var codes: [String] = []
        let barcodes = VNDetectBarcodesRequest { request, _ in
            codes = (request.results as? [VNBarcodeObservation])?.compactMap { $0.payloadStringValue } ?? []
        }
        var lines: [String] = []
        let text = VNRecognizeTextRequest { request, _ in
            lines = (request.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { text.automaticallyDetectsLanguage = true }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([barcodes, text])
        return (codes + lines).joined(separator: "\n")
    }
}

/// A small rounded message that fades away by itself.
enum Toast {
    private static var current: NSPanel?

    static func show(_ message: String, near point: NSPoint) {
        current?.orderOut(nil)
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let width = ceil((message as NSString).size(withAttributes: [.font: font]).width) + 32
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 34),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        let label = NSTextField(labelWithString: message)
        label.font = font
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: width, height: 18)
        effect.addSubview(label)
        panel.contentView = effect
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(x: min(max(point.x - width / 2, visible.minX + 8), visible.maxX - width - 8),
                             y: min(max(point.y - 17, visible.minY + 8), visible.maxY - 42))
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        current = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard current === panel else { return }
            if UI.reduceMotion { panel.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }
}

// MARK: - Region selection

enum SelectionResult {
    case area(CGRect)
    case window(CGWindowID, CGRect)
}

/// A window a click can pick (front to back), in Cocoa coordinates.
struct PickableWindow {
    let number: CGWindowID
    let frame: CGRect

    static func onScreen() -> [PickableWindow] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]], let primary = NSScreen.screens.first else { return [] }
        let own = getpid()
        return raw.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int, pid != own,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 40, frame.height >= 40 else { return nil }
            return PickableWindow(number: CGWindowID(number),
                                  frame: CGRect(x: frame.minX, y: primary.frame.height - frame.maxY,
                                                width: frame.width, height: frame.height))
        }
    }
}

final class RegionSelectionController {
    var onFinish: ((SelectionResult?) -> Void)?
    private var windows: [SelectionPanel] = []
    private var finished = false
    private let startInWindowMode: Bool
    private let hint: String

    init(windowMode: Bool = false, hint: String = "") {
        startInWindowMode = windowMode
        self.hint = hint
    }

    func begin() {
        let pickable = PickableWindow.onScreen()
        for screen in NSScreen.screens {
            let panel = SelectionPanel(screen: screen)
            panel.selectionView.pickable = pickable
            panel.selectionView.hint = hint
            panel.selectionView.windowMode = startInWindowMode
            panel.selectionView.onDone = { [weak self] result in self?.finish(result) }
            panel.selectionView.onModeChange = { [weak self] mode in
                self?.windows.forEach { $0.selectionView.windowMode = mode }
            }
            windows.append(panel)
            panel.orderFrontRegardless()
        }
        // Non-activating panels take Esc / Space without bringing the app (and its other windows) to the front.
        (windows.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()
    }

    func cancel() { finish(nil) }

    private func finish(_ result: SelectionResult?) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        for panel in windows { panel.orderOut(nil); panel.close() }
        windows.removeAll()
        onFinish?(result)
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
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        selectionView.frame = NSRect(origin: .zero, size: screen.frame.size)
        selectionView.autoresizingMask = [.width, .height]
        contentView = selectionView
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var onDone: ((SelectionResult?) -> Void)?
    var onModeChange: ((Bool) -> Void)?
    var pickable: [PickableWindow] = []
    var hint = ""
    var windowMode = false { didSet { hovered = nil; updateHover(); needsDisplay = true } }
    private var start: CGPoint?
    private var current: CGPoint?
    private var hovered: PickableWindow? { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: windowMode ? .pointingHand : .crosshair) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { updateHover() }

    private func updateHover() {
        guard windowMode else { if hovered != nil { hovered = nil }; return }
        let point = NSEvent.mouseLocation
        let hit = pickable.first { $0.frame.contains(point) }
        if hit?.number != hovered?.number { hovered = hit }
    }

    override func mouseDown(with event: NSEvent) {
        guard !windowMode else { return }
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !windowMode else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if windowMode {
            updateHover()
            if let window = hovered { onDone?(.window(window.number, window.frame)) }
            return
        }
        guard let s = start else { return }
        let c = convert(event.locationInWindow, from: nil)
        let local = RegionSelection.clamp(RegionSelection.rect(from: s, to: c), to: bounds)
        start = nil
        current = nil
        guard RegionSelection.isCapturable(local), let window = window else { onDone?(nil); return }
        let inWindow = convert(local, to: nil)
        onDone?(.area(window.convertToScreen(inWindow)))
    }
    override func rightMouseDown(with event: NSEvent) { onDone?(nil) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onDone?(nil)                                       // Esc
        case 49 where start == nil:                                 // Space: area <-> window
            onModeChange?(!windowMode)
            window?.invalidateCursorRects(for: self)
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if windowMode, let hovered = hovered, let window = window {
            let local = convert(window.convertFromScreen(hovered.frame), from: nil)
            NSColor.clear.setFill()
            local.fill(using: .copy)
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            local.fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }
        if let s = start, let c = current {
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
        if !hint.isEmpty {
            let text = (windowMode ? "Click a window to capture it · Space: back to area · Esc: cancel" : hint) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                        .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            let pill = NSRect(x: bounds.midX - size.width / 2 - 14, y: bounds.maxY - 72, width: size.width + 28, height: 30)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 15, yRadius: 15).fill()
            text.draw(at: NSPoint(x: pill.minX + 14, y: pill.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Floating capture window

final class FloatingCaptureWindow: NSPanel {
    private(set) var cgImage: CGImage
    let originalSize: CGSize
    private var liveTimer: Timer?
    private(set) var liveEnded = false
    var isLive: Bool { liveTimer != nil }
    var annotationCount: Int { canvas.annotations.count }
    private(set) var pinned = true
    private(set) var locked = false
    var onClosed: (() -> Void)?
    var onCloseAll: (() -> Void)?
    private let canvas: CaptureCanvasView
    private let pinButton = NSButton()
    private let markupButton = NSButton()

    init(cgImage: CGImage, pointSize: CGSize, at origin: CGPoint, rounded: Bool = true) {
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
        canvas.buildControls(pinButton: pinButton, markupButton: markupButton)
        setRounded(rounded)
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        liveTimer?.invalidate()
        liveTimer = nil
        let handler = onClosed
        onClosed = nil
        super.close()
        handler?()
    }

    // MARK: live and mark-up

    /// Keeps the picture following the window (three times a second); stops when the window goes away.
    func startLive(_ number: CGWindowID) {
        liveTimer?.invalidate()
        let t = Timer(timeInterval: 0.33, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number,
                                                      [.boundsIgnoreFraming, .bestResolution]),
                  image.width > 1, image.height > 1 else {
                self.liveTimer?.invalidate()
                self.liveTimer = nil
                self.liveEnded = true
                self.canvas.live = false
                return
            }
            self.updateImage(image)
        }
        RunLoop.main.add(t, forMode: .common)
        liveTimer = t
        canvas.live = true
    }

    func updateImage(_ image: CGImage) {
        cgImage = image
        canvas.image = NSImage(cgImage: image, size: originalSize)
    }

    /// Pen on: drags draw arrows (⌥: boxes) instead of moving the float.
    func setMarkup(_ on: Bool) {
        canvas.drawing = on
        isMovableByWindowBackground = !on
        markupButton.state = on ? .on : .off
        markupButton.layer?.backgroundColor = (on ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.55)).cgColor
    }

    func toggleMarkup() { setMarkup(!canvas.drawing) }

    func clearMarkup() { canvas.annotations.removeAll() }

    /// The picture with its mark-up, at full resolution: what copy, save and drag hand out.
    func renderedImage() -> CGImage {
        guard !canvas.annotations.isEmpty,
              let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cgImage }
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let scale = size.width / max(1, originalSize.width)
        for annotation in canvas.annotations { annotation.draw(in: size, lineWidth: 3 * scale) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage() ?? cgImage
    }

    // MARK: actions

    func setPinned(_ value: Bool) {
        pinned = value
        isFloatingPanel = value
        level = value ? .floating : .normal
        pinButton.title = value ? "📌" : "◻︎"
        pinButton.toolTip = value ? "Unpin" : "Pin Again"
        orderFrontRegardless()
    }

    func togglePin() { setPinned(!pinned) }

    /// Click-through: the float stays visible but every click reaches the window underneath.
    func setLocked(_ value: Bool) {
        locked = value
        ignoresMouseEvents = value
        canvas.locked = value
    }

    func setRounded(_ value: Bool) {
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = value ? 8 : 0
        canvas.layer?.masksToBounds = value
        invalidateShadow()
    }

    func setOpacity(_ value: CGFloat) { alphaValue = min(1, max(0.15, value)) }

    func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: renderedImage(), size: originalSize)])
    }

    func copyText() {
        TextRecognizer.copyText(in: cgImage, near: NSPoint(x: frame.midX, y: frame.midY))
    }

    func pngData() -> Data? {
        NSBitmapImageRep(cgImage: renderedImage()).representation(using: .png, properties: [:])
    }

    @discardableResult
    func save(to url: URL) -> Bool {
        guard let data = pngData() else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    static var fileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Capture \(formatter.string(from: Date())).png"
    }

    func saveWithPanel() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["png"]
        panel.nameFieldStringValue = FloatingCaptureWindow.fileName
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { save(to: url) }
    }

    /// Files written for drag-out live in a folder of their own and are removed when the gadget stops.
    static var dragDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NachoCombo", isDirectory: true).appendingPathComponent("Captures", isDirectory: true)
    }

    static func removeDragFiles() { try? FileManager.default.removeItem(at: dragDirectory) }

    func dragFile() -> URL? {
        try? FileManager.default.createDirectory(at: FloatingCaptureWindow.dragDirectory, withIntermediateDirectories: true)
        let url = FloatingCaptureWindow.dragDirectory.appendingPathComponent(FloatingCaptureWindow.fileName)
        return save(to: url) ? url : nil
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

    // Keyboard: ⌘C copy, ⌘S save, ⌘W / Esc close, ⌘+ / ⌘- / ⌘0 size, ⌘[ / ⌘] opacity, arrows nudge (⇧: 10 pt).
    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch (event.charactersIgnoringModifiers ?? "", command) {
        case ("c", true): copyToPasteboard()
        case ("s", true): saveWithPanel()
        case ("w", true): close()
        case ("z", true): if !canvas.annotations.isEmpty { canvas.annotations.removeLast() }
        case ("=", true), ("+", true): resize(toWidth: frame.width * 1.1)
        case ("-", true): resize(toWidth: frame.width / 1.1)
        case ("0", true): resize(percent: 100)
        case ("[", true): setOpacity(alphaValue - 0.1)
        case ("]", true): setOpacity(alphaValue + 0.1)
        default:
            switch event.keyCode {
            case 53: close()
            case 123: setFrameOrigin(NSPoint(x: frame.minX - step, y: frame.minY))
            case 124: setFrameOrigin(NSPoint(x: frame.minX + step, y: frame.minY))
            case 125: setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - step))
            case 126: setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + step))
            default: super.keyDown(with: event)
            }
        }
    }
}

final class CaptureCanvasView: NSView, NSDraggingSource {
    weak var owner: FloatingCaptureWindow?
    var image: NSImage { didSet { needsDisplay = true } }
    var locked = false { didSet { needsDisplay = true } }
    var live = false { didSet { needsDisplay = true } }
    var drawing = false { didSet { window?.invalidateCursorRects(for: self) } }
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }
    private var sketch: Annotation? { didSet { needsDisplay = true } }

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { !drawing }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { if drawing { addCursorRect(bounds, cursor: .crosshair) } }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        for annotation in annotations + (sketch.map { [$0] } ?? []) { annotation.draw(in: bounds.size, lineWidth: 3) }
        if live {
            let badge = NSRect(x: bounds.maxX - 44, y: bounds.maxY - 20, width: 38, height: 16)
            NSColor.systemRed.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            let text = "LIVE" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                                                             .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
        }
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        if locked, let symbol = UI.symbol("lock.fill", size: 10, weight: .bold) {
            let badge = NSRect(x: bounds.maxX - 22, y: bounds.maxY - 20, width: 18, height: 16)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            let tinted = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? symbol
            let s = tinted.size
            tinted.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    func buildControls(pinButton: NSButton, markupButton: NSButton) {
        let close = Self.smallButton("✕", tip: "Close", id: "float-close", action: #selector(closeTapped))
        close.target = self
        pinButton.title = "📌"
        pinButton.toolTip = "Unpin"
        Self.style(pinButton)
        pinButton.target = self
        pinButton.action = #selector(pinTapped)
        pinButton.setAccessibilityIdentifier("float-pin")
        pinButton.setAccessibilityLabel("Unpin")
        let drag = FloatDragHandle()
        drag.owner = self
        drag.toolTip = "Drag into another app or a folder"
        drag.setAccessibilityLabel("Drag the picture out")
        let grip = ResizeGripView()
        grip.owner = owner
        grip.toolTip = "Drag to resize"
        markupButton.title = "✎"
        markupButton.toolTip = "Mark up: drag for an arrow, ⌥-drag for a box, ⌘Z to undo"
        Self.style(markupButton)
        markupButton.attributedTitle = NSAttributedString(string: "✎", attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
        markupButton.target = self
        markupButton.action = #selector(markupTapped)
        markupButton.setAccessibilityIdentifier("float-markup")
        markupButton.setAccessibilityLabel("Mark up")
        for control in [close, pinButton, markupButton] { addSubview(control) }
        addSubview(drag)
        addSubview(grip)
        close.frame = NSRect(x: 4, y: bounds.height - 22, width: 20, height: 18)
        pinButton.frame = NSRect(x: 26, y: bounds.height - 22, width: 22, height: 18)
        drag.frame = NSRect(x: 50, y: bounds.height - 22, width: 22, height: 18)
        markupButton.frame = NSRect(x: 74, y: bounds.height - 22, width: 22, height: 18)
        markupButton.autoresizingMask = [.minYMargin]
        close.autoresizingMask = [.minYMargin]
        pinButton.autoresizingMask = [.minYMargin]
        drag.autoresizingMask = [.minYMargin]
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
    @objc private func markupTapped() { owner?.toggleMarkup() }

    override func mouseDown(with event: NSEvent) {
        if drawing {
            let point = normalized(convert(event.locationInWindow, from: nil))
            sketch = Annotation(box: event.modifierFlags.contains(.option), start: point, end: point)
            return
        }
        if event.clickCount == 2 { owner?.close(); return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawing, var current = sketch else { super.mouseDragged(with: event); return }
        current.end = normalized(convert(event.locationInWindow, from: nil))
        sketch = current
    }

    override func mouseUp(with event: NSEvent) {
        guard drawing, let current = sketch else { super.mouseUp(with: event); return }
        sketch = nil
        if hypot((current.end.x - current.start.x) * bounds.width, (current.end.y - current.start.y) * bounds.height) > 4 {
            annotations.append(current)
        }
    }

    private func normalized(_ point: NSPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, bounds.width))), y: min(1, max(0, point.y / max(1, bounds.height))))
    }

    /// Scroll fades the float; ⌘-scroll resizes it.
    override func scrollWheel(with event: NSEvent) {
        guard let owner = owner else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        if event.modifierFlags.contains(.command) {
            owner.resize(toWidth: owner.frame.width * (1 + delta))
        } else {
            owner.setOpacity(owner.alphaValue + delta)
        }
    }

    // MARK: context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner = owner else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, handler: action))
        }
        add("Copy") { owner.copyToPasteboard() }
        add("Copy Text") { owner.copyText() }
        add("Save…") { owner.saveWithPanel() }
        menu.addItem(.separator())
        add(owner.pinned ? "Unpin" : "Pin Again") { owner.togglePin() }
        add(drawing ? "Stop Marking Up" : "Mark Up") { owner.toggleMarkup() }
        if !annotations.isEmpty { add("Clear Mark-Up") { owner.clearMarkup() } }
        add("Lock (Click Through)") { owner.setLocked(true) }
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = ClosureMenuItem(title: "\(percent)%") { owner.setOpacity(CGFloat(percent) / 100) }
            item.state = abs(owner.alphaValue - CGFloat(percent) / 100) < 0.05 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        add("Actual Size (100%)") { owner.resize(percent: 100) }
        add("50%") { owner.resize(percent: 50) }
        add("200%") { owner.resize(percent: 200) }
        menu.addItem(.separator())
        add("Close") { owner.close() }
        add("Close All Floats") { owner.onCloseAll?() }
        return menu
    }

    override func magnify(with event: NSEvent) {
        guard let owner = owner else { return }
        owner.resize(toWidth: owner.frame.width * (1 + event.magnification))
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Small handle on a float: dragging it hands the picture to another app (as a PNG file) instead of moving the float.
final class FloatDragHandle: NSView {
    weak var owner: CaptureCanvasView?
    private var downPoint: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        if let symbol = UI.symbol("square.and.arrow.up", size: 9, weight: .bold) {
            let tinted = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white])) ?? symbol
            let s = tinted.size
            tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
        }
    }

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let canvas = owner, let window = canvas.owner else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
        downPoint = nil
        guard let url = window.dragFile() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: window.renderedImage(), size: NSSize(width: 96, height: 96 * window.originalSize.height
                                                                     / max(1, window.originalSize.width)))
        item.setDraggingFrame(NSRect(origin: convert(now, from: nil), size: preview.size), contents: preview)
        canvas.beginDraggingSession(with: [item], event: event, source: canvas)
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

/// An arrow or a box drawn on a float, in coordinates relative to the float (0…1), so it follows resizing.
struct Annotation {
    var box: Bool
    var start: CGPoint
    var end: CGPoint

    func draw(in size: CGSize, lineWidth: CGFloat) {
        let a = CGPoint(x: start.x * size.width, y: start.y * size.height)
        let b = CGPoint(x: end.x * size.width, y: end.y * size.height)
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if box {
            path.appendRect(NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        } else {
            path.move(to: a)
            path.line(to: b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(10, lineWidth * 4)
            for side in [-1.0, 1.0] {
                let wing = angle + .pi + CGFloat(side) * 0.45
                path.move(to: b)
                path.line(to: CGPoint(x: b.x + cos(wing) * head, y: b.y + sin(wing) * head))
            }
        }
        path.stroke()
    }
}
