import AppKit
import NachoComboCore
import QuartzCore

/// The Nacho character on screen (`.pet` in the web mockup): two picture layers for the crossfade, moved by
/// `PetMotion` (the same model as design/web/motion.js), a state badge, hover lift with a name tag, press, drag tilt,
/// landing, and the drop ring for files. Frames run on a timer only while `PetAnimationGate` allows it.
final class PetCharacterView: NSView {
    private typealias S = PetTokens.Size
    weak var module: NachoPetModule?

    private let figure = CALayer()
    private let previousLayer = CALayer()
    private let currentLayer = CALayer()
    private let badge = PetBox()
    private let badgeIcon = NSImageView()
    private var motion: PetMotion
    private var timer: Timer?
    private var hovered = false
    private var hoverAmount = 0.0
    private var lastTick = 0.0
    var gate = PetAnimationGate() { didSet { if gate != oldValue { kick() } } }

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var lastDrag: (x: CGFloat, t: Double)?
    private var dragged = false
    private var dropTargeted = false {
        didSet {
            needsDisplay = true
            let kind: PetNameTag.Kind? = dropTargeted ? .drop : (hovered ? .hover : nil)
            module?.showNameTag(kind)
        }
    }
    private var tracking: NSTrackingArea?

    var face: PetFace = .idle {
        didSet {
            guard face != oldValue else { return }
            motion.setFace(face, at: PetCharacterView.now)
            toolTip = nil  // the name tag says it
            setAccessibilityLabel("나초 펫, \(face.koreanLabel)")
            updateBadge()
            if hovered { module?.showNameTag(.hover) }
            kick()
        }
    }

    static var now: Double { CACurrentMediaTime() * 1000 }
    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(frame: NSRect, module: NachoPetModule) {
        self.module = module
        motion = PetMotion(face: .idle, at: PetCharacterView.now, reduceMotion: PetCharacterView.reduceMotion,
                           seed: UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970)))
        super.init(frame: frame)
        wantsLayer = true
        let inset = CGFloat(S.petArtInset)
        let art = bounds.insetBy(dx: inset, dy: inset)
        figure.anchorPoint = CGPoint(x: 0.5, y: 0)
        figure.bounds = CGRect(origin: .zero, size: art.size)
        figure.position = CGPoint(x: art.midX, y: art.minY)
        figure.shadowColor = NSColor.black.cgColor
        figure.shadowOpacity = Float(PetTokens.Shadow.petOpacity)
        figure.shadowRadius = CGFloat(PetTokens.Shadow.petBlur / 2)
        figure.shadowOffset = CGSize(width: 0, height: -CGFloat(PetTokens.Shadow.petY))
        for l in [previousLayer, currentLayer] {
            l.frame = figure.bounds
            l.contentsGravity = .resizeAspect
            figure.addSublayer(l)
        }
        layer?.addSublayer(figure)
        buildBadge()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("나초 펫, \(face.koreanLabel)")
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        currentLayer.contents = PetArt.image(named: PetFace.idle.assetName)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        kick()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [figure, previousLayer, currentLayer] { l.contentsScale = scale }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { module?.toggleChat(); return true }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func displayOptionsChanged() {
        motion.reduceMotion = PetCharacterView.reduceMotion
        kick()
    }

    // MARK: frames

    /// Draws now and keeps the timer running while frames are needed.
    private func kick() {
        tick()
        let t = PetCharacterView.now
        let needs = gate.needsFrames(motion, at: t) || (gate.allowsMotion && abs(hoverAmount - (hovered ? 1 : 0)) > 0.01)
        if needs, timer == nil {
            let interval = PetTokens.Motion.frameInterval / 1000
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.step() }
            timer.tolerance = interval / 4
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needs {
            stop()
        }
    }

    private func step() {
        tick()
        let t = PetCharacterView.now
        let hoverSettled = abs(hoverAmount - (hovered ? 1 : 0)) < 0.01
        if !gate.needsFrames(motion, at: t) && hoverSettled { stop() }
    }

    private func tick() {
        let t = PetCharacterView.now
        let dt = lastTick == 0 ? 0 : min(100, t - lastTick)
        lastTick = t
        let target = hovered && !dragged ? 1.0 : 0.0
        if motion.reduceMotion || !gate.allowsMotion { hoverAmount = target }
        else { hoverAmount += (target - hoverAmount) * min(1, dt / PetTokens.Motion.fast) }
        // Not allowed to move (hidden, asleep, full screen): hold the resting picture of the state.
        var pose = gate.allowsMotion ? motion.pose(at: t) : PetPose(asset: face.assetName, previous: nil)
        pose.dy += PetTokens.Size.petHoverLift * hoverAmount
        apply(pose)
    }

    private func apply(_ p: PetPose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let image = PetArt.image(named: p.asset) ?? PetArt.image(named: face.assetName)
        if (currentLayer.contents as? NSImage) !== image { currentLayer.contents = image }
        if let prev = p.previous {
            let pi = PetArt.image(named: prev)
            if (previousLayer.contents as? NSImage) !== pi { previousLayer.contents = pi }
            previousLayer.opacity = Float(1 - p.mix)
        } else {
            previousLayer.opacity = 0
        }
        currentLayer.opacity = Float(p.mix)
        // AppKit layers are y-up: +dy lifts; a clockwise (web) rotation is a negative angle here.
        var tr = CATransform3DMakeTranslation(CGFloat(p.dx), CGFloat(p.dy), 0)
        tr = CATransform3DRotate(tr, -CGFloat(p.rotation) * .pi / 180, 0, 0, 1)
        tr = CATransform3DScale(tr, CGFloat(p.scaleX), CGFloat(p.scaleY), 1)
        figure.transform = tr
        CATransaction.commit()
    }

    // MARK: badge (`.pet .badge`)

    private func buildBadge() {
        badge.fill = PetTheme.color(\.accentSoft)
        badge.stroke = PetTheme.color(\.edge)
        badge.radius = CGFloat(S.badge / 2)
        badge.frame = NSRect(x: CGFloat(S.petArtInset), y: bounds.height - CGFloat(PetTokens.Space.s + S.badge), width: CGFloat(S.badge), height: CGFloat(S.badge))
        badgeIcon.frame = badge.bounds.insetBy(dx: CGFloat((S.badge - S.badgeIcon) / 2), dy: CGFloat((S.badge - S.badgeIcon) / 2))
        badge.addSubview(badgeIcon)
        addSubview(badge)
        updateBadge()
    }

    /// A badge only where the face alone cannot say it: dictating (red mic, only while really dictating), thinking,
    /// dozing. No badge while answering: the chat header already says so. Each badge says its meaning as a tooltip and
    /// to VoiceOver.
    private func updateBadge() {
        let symbol: String?
        let meaning: String?
        switch face {
        case .listening: symbol = "mic.fill"; meaning = "받아쓰는 중"
        case .thinking: symbol = "ellipsis"; meaning = "생각하는 중"
        case .sleeping: symbol = "zzz"; meaning = "조는 중"
        default: symbol = nil; meaning = nil
        }
        badge.isHidden = symbol == nil
        badge.toolTip = meaning
        badge.setAccessibilityElement(meaning != nil)
        badge.setAccessibilityLabel(meaning)
        let rec = face == .listening
        badge.fill = rec ? PetTheme.color(\.danger) : PetTheme.color(\.accentSoft)
        badgeIcon.contentTintColor = rec ? PetTheme.color(\.onDanger) : PetTheme.accent
        badgeIcon.image = symbol.flatMap { PetTheme.symbol($0, size: S.badgeIcon, weight: .semibold) }
    }

    // MARK: drawing (drop ring, art-less fallback)

    override func draw(_ dirtyRect: NSRect) {
        if dropTargeted {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: CGFloat(PetTokens.Space.xs), dy: CGFloat(PetTokens.Space.xs)))
            PetTheme.color(\.accentSoft).withAlphaComponent(0.6).setFill()
            ring.fill()
            PetTheme.accent.setStroke()
            ring.lineWidth = 2
            ring.setLineDash([6, 4], count: 2, phase: 0)
            ring.stroke()
        }
        if PetArt.image(named: "idle") == nil {
            // A build without the character art (forks remove Resources/Nacho): a plain chat bubble.
            PetTheme.accent.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 20, dy: 20)).fill()
            NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)?.draw(in: bounds.insetBy(dx: 38, dy: 38))
        }
    }

    // MARK: hover, press, drag

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        module?.showNameTag(.hover)
        kick()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        module?.showNameTag(nil)
        kick()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        lastDrag = (NSEvent.mouseLocation.x, PetCharacterView.now)
        dragged = false
        motion.press(at: PetCharacterView.now)
        gate.interacting = true
        kick()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m0 = dragStartMouse, let o0 = dragStartOrigin, let w = window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - m0.x, dy = m.y - m0.y
        if !dragged && abs(dx) < 3 && abs(dy) < 3 { return }
        if !dragged { module?.showNameTag(nil) }
        dragged = true
        w.setFrameOrigin(NSPoint(x: o0.x + dx, y: o0.y + dy))
        let t = PetCharacterView.now
        if let last = lastDrag, t > last.t {
            motion.drag(velocityX: Double(m.x - last.x) / (t - last.t) * 1000, at: t)
        }
        lastDrag = (m.x, t)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartMouse = nil; dragStartOrigin = nil; lastDrag = nil }
        let t = PetCharacterView.now
        if dragged { motion.drop(at: t) }
        motion.release(at: t)
        if dragged {
            if let o = window?.frame.origin { module?.petMoved(to: o) }
        } else {
            module?.toggleChat()
        }
        dragged = false
        // Let the release and landing play out before the gate drops back to the face's own needs.
        let settle = (PetTokens.Motion.press * 2 + PetTokens.Motion.land) / 1000
        gate.interacting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in self?.gate.interacting = false }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let module = module else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "나초와 대화") { module.openChat() })
        menu.addItem(ClosureMenuItem(title: "파일 주기…") { module.pickFiles() })
        menu.addItem(.separator())
        if module.state.auth == .signedIn {
            menu.addItem(ClosureMenuItem(title: "로그아웃") { module.signOut() })
        } else {
            menu.addItem(ClosureMenuItem(title: "나초 계정으로 로그인") { module.openChat(); module.signIn() })
        }
        menu.addItem(ClosureMenuItem(title: "오른쪽 아래로 돌려놓기") { module.resetPosition() })
        menu.addItem(ClosureMenuItem(title: "Nacho Pet 설정…") { module.openSettings?() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "나초 숨기기 (Nacho Pet 끄기)") { module.turnOff?() })
        return menu
    }

    // MARK: drop files, pictures or text on Nacho

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropTargeted = false
        guard let module = module else { return false }
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls.prefix(PetMedia.maxAttachments) { module.attach(fileURL: url) }
            return true
        }
        if let png = pb.data(forType: .png) { module.attach(name: "그림.png", data: png, mime: "image/png"); return true }
        if let tiff = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            module.attach(name: "그림.png", data: png, mime: "image/png")
            return true
        }
        if let text = pb.string(forType: .string), !text.isEmpty { module.attachText(text, title: "text"); return true }
        return false
    }
}

/// The small tag above the pet (`.nametag`): name and state while hovering, "나초에게 주기" while a file is over it.
final class PetNameTag: NSPanel {
    enum Kind: Equatable { case hover, drop }
    private let box = PetBox()
    private let label = NSTextField(labelWithString: "")

    init(height: Double = PetTokens.Size.petNameTagHeight) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: height), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        box.fill = PetTheme.color(\.tooltip)
        box.radius = CGFloat(PetTokens.Size.petNameTagHeight / 2)
        label.textColor = PetTheme.color(\.onTooltip)
        box.addSubview(label)
        contentView = box
    }

    /// Shows the tag centred above `pet`.
    func show(title: String, detail: String, above pet: NSWindow) {
        let text = NSMutableAttributedString(string: title, attributes: [.font: PetTheme.font(PetTokens.Font.caption, PetTokens.Font.weightSemibold),
                                                                         .foregroundColor: PetTheme.color(\.onTooltip)])
        text.append(NSAttributedString(string: " · " + detail, attributes: [.font: PetTheme.caption,
                                                                            .foregroundColor: PetTheme.color(\.onTooltip).withAlphaComponent(0.85)]))
        label.attributedStringValue = text
        label.sizeToFit()
        let h = CGFloat(PetTokens.Size.petNameTagHeight), pad = CGFloat(PetTokens.Space.s)
        let size = NSSize(width: ceil(label.frame.width) + 2 * pad, height: h)
        label.frame.origin = NSPoint(x: pad, y: (h - label.frame.height) / 2)
        let origin = NSPoint(x: pet.frame.midX - size.width / 2, y: pet.frame.maxY + CGFloat(PetTokens.Space.xs))
        setFrame(NSRect(origin: origin, size: size), display: true)
        orderFrontRegardless()
    }
}
