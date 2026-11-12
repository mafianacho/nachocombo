import AppKit
import ApplicationServices
import Carbon
import NachoComboCore
import NaturalLanguage

// The selection bar on screen (mockup scenes sel-bar, sel-more, sel-ask, sel-secure): the Accessibility read, the
// global event watch that decides when to look, and the bar itself. The rules (where it shows, what is read, the
// limits, what is sent) are in NachoComboCore/Pet/PetSelection.swift and tested on Linux. Nothing here logs text.

private typealias S = PetTokens.Size
private typealias Sp = PetTokens.Space

// MARK: - Accessibility read

enum PetSelectionAX {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's Accessibility prompt. Only called when the user switches the bar on.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Browsers whose web area tells its address (`AXURL`); elsewhere no URL is read.
    static let browsers: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
                                        "company.thebrowser.Browser", "com.microsoft.edgemac", "org.mozilla.firefox",
                                        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    struct Focus {
        let app: NSRunningApplication
        let axApp: AXUIElement
        let element: AXUIElement?
        let probe: PetSelectionProbe
    }

    private static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? { value(el, name) as? String }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    private static func parameterized(_ el: AXUIElement, _ name: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, arg, &v) == .success else { return nil }
        return v
    }

    private static func range(_ v: CFTypeRef?) -> CFRange? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil  // swiftlint:disable:this force_cast
    }

    private static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil  // swiftlint:disable:this force_cast
    }

    private static func axRange(_ location: Int, _ length: Int) -> AXValue? {
        var r = CFRange(location: location, length: length)
        return AXValueCreate(.cfRange, &r)
    }

    /// The front app and its focused element: bundle id, role and subrole, secure input. No text yet.
    static func focus() -> Focus? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        let el = trusted ? element(axApp, kAXFocusedUIElementAttribute) : nil
        let probe = PetSelectionProbe(bundleID: app.bundleIdentifier, role: el.flatMap { string($0, kAXRoleAttribute) },
                                      subrole: el.flatMap { string($0, kAXSubroleAttribute) },
                                      secureInput: IsSecureEventInputEnabled(), accessibilityTrusted: trusted)
        return Focus(app: app, axApp: axApp, element: el, probe: probe)
    }

    /// The selection and what is around it, plus where it is on screen (Cocoa coordinates). Only called after the
    /// gate allowed it (PetSelectionReader).
    static func read(_ f: Focus) -> (PetSelectionCapture, NSRect?)? {
        guard let el = f.element, let text = string(el, kAXSelectedTextAttribute), !text.isEmpty else { return nil }
        var before: String?, after: String?, bounds: NSRect?
        let around = PetSelectionLimits.around
        if let r = range(value(el, kAXSelectedTextRangeAttribute)) {
            if r.location > 0, let v = axRange(max(0, r.location - around), min(around, r.location)) {
                before = parameterized(el, kAXStringForRangeParameterizedAttribute, v) as? String
            }
            let total = (value(el, kAXNumberOfCharactersAttribute) as? Int) ?? (r.location + r.length + around)
            let start = r.location + r.length
            if start < total, let v = axRange(start, min(around, total - start)) {
                after = parameterized(el, kAXStringForRangeParameterizedAttribute, v) as? String
            }
            if let v = axRange(r.location, r.length), let ax = rect(parameterized(el, kAXBoundsForRangeParameterizedAttribute, v)) {
                bounds = cocoa(ax)
            }
        }
        let window = element(f.axApp, kAXFocusedWindowAttribute)
        var url: String?, pageTitle: String?
        if let bundle = f.app.bundleIdentifier, browsers.contains(bundle) {
            var cur: AXUIElement? = el
            for _ in 0..<40 {
                guard let c = cur else { break }
                if string(c, kAXRoleAttribute) == "AXWebArea" {
                    if let u = value(c, "AXURL") { url = (u as? URL)?.absoluteString ?? (u as? String) }
                    pageTitle = string(c, kAXTitleAttribute)
                    break
                }
                cur = element(c, kAXParentAttribute)
            }
            if url == nil, let w = window, let doc = string(w, kAXDocumentAttribute), doc.hasPrefix("http") { url = doc }
        }
        let capture = PetSelectionCapture(text: text, appName: f.app.localizedName ?? "", bundleID: f.app.bundleIdentifier ?? "",
                                          windowTitle: window.flatMap { string($0, kAXTitleAttribute) }, url: url, pageTitle: pageTitle,
                                          before: before, after: after, language: language(text))
        return (capture, bounds)
    }

    static func language(_ text: String) -> String? {
        let sample = String(text.prefix(1000))
        guard sample.count >= 2 else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(sample)
        return r.dominantLanguage.map { $0.rawValue }.flatMap { $0 == "und" ? nil : $0 }
    }

    /// Accessibility uses a top-left origin on the main display; Cocoa a bottom-left one.
    static func cocoa(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

// MARK: - when to look

/// Watches mouse-ups after a drag or double click, and ⇧-arrow selections, in other apps; waits the delay, then asks
/// `onCheck` to look. Clicks, typing and scrolling elsewhere dismiss the bar. Runs only while the bar is on and
/// Accessibility is allowed.
final class PetSelectionWatcher {
    var settings: () -> PetSelectionBarSettings = { PetSelectionBarSettings() }
    var onCheck: () -> Void = {}
    var onOutsideActivity: () -> Void = {}

    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var downAt: NSPoint?

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel, .keyDown, .keyUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) { monitors.append(m) }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        pending?.cancel()
        pending = nil
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .leftMouseDown:
            downAt = NSEvent.mouseLocation
            cancelAndDismiss()
        case .rightMouseDown, .scrollWheel:
            cancelAndDismiss()
        case .keyDown:
            if !(e.modifierFlags.contains(.shift) && PetSelectionWatcher.arrowKeys.contains(e.keyCode)) { cancelAndDismiss() }
        case .leftMouseUp:
            let moved = downAt.map { hypot($0.x - NSEvent.mouseLocation.x, $0.y - NSEvent.mouseLocation.y) > 3 } ?? false
            downAt = nil
            guard moved || e.clickCount >= 2 else { return }
            schedule(command: e.modifierFlags.contains(.command))
        case .keyUp:
            if e.modifierFlags.contains(.shift), PetSelectionWatcher.arrowKeys.contains(e.keyCode) {
                schedule(command: e.modifierFlags.contains(.command))
            }
        default: break
        }
    }

    static let arrowKeys: Set<UInt16> = [123, 124, 125, 126]

    private func cancelAndDismiss() {
        pending?.cancel()
        pending = nil
        onOutsideActivity()
    }

    private func schedule(command: Bool) {
        let s = settings()
        if s.delay == .commandOnly && !command { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onCheck() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + s.delay.seconds, execute: work)
    }
}

// MARK: - the bar (`.selbar`)

/// One button of the bar: icon (secondary) and label, surface fill on hover.
final class PetSelectionButton: PetBox {
    var onClick: (() -> Void)?
    private var tracking: NSTrackingArea?
    var isHot = false { didSet { fill = isHot ? PetTheme.color(\.surface) : nil } }

    init(symbol: String?, image: NSImage? = nil, title: String?, titleColor: NSColor = PetTheme.text, bold: Bool = false,
         imageSize: Double = S.selectBarIcon, tooltip: String) {
        super.init(frame: .zero)
        radius = CGFloat(PetTokens.Radius.selectBar - 3)
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = CGFloat(Sp.xs)
        row.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView()
        icon.image = image ?? symbol.flatMap { PetTheme.symbol($0, size: imageSize) }
        icon.contentTintColor = image == nil ? PetTheme.secondary : nil
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: CGFloat(imageSize)).isActive = true
        icon.heightAnchor.constraint(equalToConstant: CGFloat(imageSize)).isActive = true
        row.addArrangedSubview(icon)
        if let t = title {
            let l = NSTextField(labelWithString: t)
            l.font = PetTheme.font(PetTokens.Font.caption, bold ? PetTokens.Font.weightSemibold : PetTokens.Font.weightRegular)
            l.textColor = titleColor
            row.addArrangedSubview(l)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: CGFloat(S.selectBarHeight - 6)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Sp.s)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Sp.s)),
        ])
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { isHot = true }
    override func mouseExited(with event: NSEvent) { isHot = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.7 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// The bar's content: buttons | 나초에게 묻기 · ⋯ (`compact`: icons only, for the first-use card), or the one-line
/// question (`ask`). Draws its own `window` fill and edge; the panel adds the blur behind it.
final class PetSelectionBarView: PetBox, NSTextFieldDelegate {
    enum Mode: Equatable { case buttons(compact: Bool), ask }

    var onAction: ((PetSelectionAction) -> Void)?
    var onMore: ((NSView) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onEscape: (() -> Void)?
    let field = NSTextField()
    private(set) var moreButton: PetSelectionButton?

    init(mode: Mode, buttons: [PetSelectionAction], question: String = "") {
        super.init(frame: .zero)
        fill = PetTheme.color(\.window)
        stroke = PetTheme.color(\.edge)
        radius = CGFloat(PetTokens.Radius.selectBar)
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        heightAnchor.constraint(equalToConstant: CGFloat(S.selectBarHeight)).isActive = true
        switch mode {
        case let .buttons(compact):
            row.spacing = 1
            for a in buttons {
                let b = PetSelectionButton(symbol: a.symbol, title: compact ? nil : a.title, tooltip: a.title)
                b.onClick = { [weak self] in self?.onAction?(a) }
                row.addArrangedSubview(b)
            }
            let div = PetBox()
            div.fill = PetTheme.color(\.separator)
            div.translatesAutoresizingMaskIntoConstraints = false
            div.widthAnchor.constraint(equalToConstant: 1).isActive = true
            div.heightAnchor.constraint(equalToConstant: 18).isActive = true
            row.addArrangedSubview(div)
            row.setCustomSpacing(CGFloat(Sp.xxs) + 1, after: row.arrangedSubviews[max(0, row.arrangedSubviews.count - 2)])
            row.setCustomSpacing(CGFloat(Sp.xxs) + 1, after: div)
            let nacho = PetSelectionButton(symbol: nil, image: PetArt.image(.idle), title: PetSelectionAction.ask.title,
                                           titleColor: PetTheme.accent, bold: true, imageSize: 18, tooltip: PetSelectionAction.ask.title)
            nacho.onClick = { [weak self] in self?.onAction?(.ask) }
            row.addArrangedSubview(nacho)
            let more = PetSelectionButton(symbol: "ellipsis", title: nil, tooltip: "더 보기")
            more.onClick = { [weak self, weak more] in if let m = more { self?.onMore?(m) } }
            row.addArrangedSubview(more)
            moreButton = more
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Sp.xxs)),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Sp.xxs)),
                row.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        case .ask:
            row.spacing = CGFloat(Sp.xs)
            let art = NSImageView(image: PetArt.image(.idle) ?? NSImage())
            art.imageScaling = .scaleProportionallyUpOrDown
            art.translatesAutoresizingMaskIntoConstraints = false
            art.widthAnchor.constraint(equalToConstant: 20).isActive = true
            art.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let box = PetBox()
            box.fill = PetTheme.color(\.surfaceRaised)
            box.stroke = PetTheme.accent
            box.radius = CGFloat(PetTokens.Radius.selectBar - 3)
            box.translatesAutoresizingMaskIntoConstraints = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = PetTheme.caption
            field.textColor = PetTheme.text
            field.stringValue = question
            field.placeholderAttributedString = NSAttributedString(string: "고른 글에 대해 물어보기…",
                                                                   attributes: [.font: PetTheme.caption, .foregroundColor: PetTheme.tertiary])
            field.delegate = self
            field.cell?.usesSingleLineMode = true
            field.cell?.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setAccessibilityLabel("나초에게 물어볼 말")
            box.addSubview(field)
            let kbd = NSTextField(labelWithString: "↩ 확인 · esc")
            kbd.font = PetTheme.caption
            kbd.textColor = PetTheme.secondary
            kbd.toolTip = "Return: 보낼 내용 확인 · Esc: 닫기"
            kbd.setContentCompressionResistancePriority(.required, for: .horizontal)
            let send = PetSelectionButton(symbol: "arrow.up", title: nil, imageSize: 12, tooltip: "보낼 내용 확인")
            send.onClick = { [weak self] in
                guard let v = self else { return }
                v.onSubmit?(v.field.stringValue)
            }
            for v in [art, box, kbd, send] as [NSView] { row.addArrangedSubview(v) }
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: CGFloat(S.selectAskWidth)),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Sp.xs)),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Sp.xxs)),
                row.centerYAnchor.constraint(equalTo: centerYAnchor),
                box.heightAnchor.constraint(equalToConstant: CGFloat(S.selectBarHeight - 8)),
                field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: CGFloat(Sp.s)),
                field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -CGFloat(Sp.s)),
                field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
                send.widthAnchor.constraint(equalToConstant: 26),
            ])
            box.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(mode == .ask ? "나초에게 묻기" : "고른 글로 하기")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onSubmit?(field.stringValue); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onEscape?(); return true }
        return false
    }
}

/// The floating panel next to the selection. Non-activating: the app the text is in stays in front; it becomes key
/// only for the question field.
final class PetSelectionBarPanel: NSPanel {
    private let blur = NSVisualEffectView()
    private(set) var bar: PetSelectionBarView?
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: CGFloat(S.selectBarHeight)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = CGFloat(PetTokens.Radius.selectBar)
        blur.layer?.masksToBounds = true
        contentView = blur
        setAccessibilityIdentifier("nacho-selection-bar")
    }

    override var canBecomeKey: Bool { bar?.field.superview != nil && bar?.field.window === self }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Shows `view` above `selection` (below when there is no room), inside the screen's visible frame.
    func show(_ view: PetSelectionBarView, near selection: NSRect?, ask: Bool) {
        bar?.removeFromSuperview()
        bar = view
        blur.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: blur.leadingAnchor), view.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            view.topAnchor.constraint(equalTo: blur.topAnchor), view.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        let mouse = NSEvent.mouseLocation
        let anchor = selection ?? NSRect(x: mouse.x, y: mouse.y, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let gap = CGFloat(S.selectBarOffset)
        var y = anchor.maxY + gap
        if y + size.height > vf.maxY { y = anchor.minY - gap - size.height }
        let x = min(max(anchor.minX, vf.minX + gap), vf.maxX - size.width - gap)
        setFrame(NSRect(x: x, y: max(vf.minY, y), width: size.width, height: size.height), display: true)
        if !isVisible {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { c in
                c.duration = PetTheme.ms(PetTokens.Motion.selectBarFade)
                animator().alphaValue = 1
            }
        }
        if ask {
            makeKey()
            makeFirstResponder(view.field)
        }
    }

    func hide() {
        guard isVisible else { return }
        orderOut(nil)
        bar?.removeFromSuperview()
        bar = nil
    }
}
