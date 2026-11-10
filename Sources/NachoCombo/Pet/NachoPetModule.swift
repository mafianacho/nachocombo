import AppKit
import NachoComboCore
import UniformTypeIdentifiers

/// Nacho Pet: the Nacho character in a corner of the screen (bottom right on first launch) with a chat bubble.
/// On by default; it needs no permission and makes no network connection until the chat is opened.
/// Ported from nacho-gadget-app (PR #1 @1d685fa) AppModel/PetPanel/BubbleView, rebuilt in AppKit on `PetSession`.
final class NachoPetModule: NSObject, FeatureModule, PetCommandExecuting {
    let id = ModuleID.nachoPet

    /// Runs a command Nacho asked for on the Mac (window arrangement, gadget switches). Set by the app delegate;
    /// called on the main thread.
    var perform: ((PetCommand) -> PetCommandOutcome)?
    /// Opens Nacho Pet's page in the settings window.
    var openSettings: (() -> Void)?
    /// Switches the gadget off (the pet's "Hide Nacho").
    var turnOff: (() -> Void)?
    var onChange: (() -> Void)?

    private let settingsStore = PetSettingsStore(url: PetSettingsStore.defaultURL())
    private(set) var settings: PetSettings
    private let secrets = KeychainSecretStore()
    private let login = PetWebLogin()
    private(set) var session: PetSession!
    private(set) var state = PetSessionState()
    private var petWindow: PetWindow?
    private var chatWindow: PetChatWindow?
    private var faceTimer: Timer?
    let dictation = PetDictationController()
    let serverRecorder = PetServerRecorder()
    private(set) var dictationState = DictationState()
    private(set) var commandsRun = 0

    override init() {
        settings = settingsStore.load()
        super.init()
        session = makeSession()
        login.anchor = { [weak self] in self?.chatWindow ?? self?.petWindow }
    }

    private func makeSession() -> PetSession {
        let s = PetSession(settings: settings, http: URLSessionPetHTTP(), secrets: secrets, browser: login,
                           makeTransport: { URLSessionTransport() }, executor: self)
        s.onChange = { [weak self] st in
            DispatchQueue.main.async { self?.sessionChanged(st) }
        }
        return s
    }

    var isRunning: Bool { petWindow != nil }

    func start() -> ModuleState {
        if petWindow == nil {
            let w = PetWindow(module: self)
            w.setFrameOrigin(PetWindow.initialOrigin(saved: settings.petPosition))
            petWindow = w
        }
        petWindow?.orderFrontRegardless()
        PetHandoff.module = self
        state = session.snapshot
        refreshFace()
        faceTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshFace() }
        RunLoop.main.add(t, forMode: .common)
        faceTimer = t
        return .running
    }

    func stop() {
        faceTimer?.invalidate()
        faceTimer = nil
        serverRecorder.cancel()
        dictation.stop()
        dictationState.stop()
        login.cancel()
        chatWindow?.close()
        chatWindow = nil
        petWindow?.close()
        petWindow = nil
        if PetHandoff.module === self { PetHandoff.module = nil }
        // Close the sockets; the session (Keychain) stays for the next time the pet is on.
        session.shutdown()
    }

    var diagnostics: [String: String] {
        ["auth": "\(state.auth)", "chat": "\(state.chat.phase)", "connector": "\(state.connector)",
         "turns": "\(state.chat.turns.count)", "pending": "\(state.pending.count)", "commands": "\(commandsRun)",
         "chatOpen": chatWindow?.isVisible == true ? "yes" : "no", "server": settings.endpoint?.base.absoluteString ?? "-"]
    }

    /// One line for the gadget tile.
    var statusText: String {
        switch state.auth {
        case .signedOut: return "Click Nacho to sign in"
        case .signingIn: return "Signing in…"
        case .failed: return "Sign-in failed"
        case .signedIn:
            var text: String
            switch state.chat.phase {
            case .connected: text = "Connected"
            case .connecting, .reconnecting: text = "Connecting…"
            case .authFailed: text = "Sign in again"
            case .disconnected: text = "Signed in"
            }
            if state.connector == .ready { text += " · can arrange windows" }
            return text
        }
    }

    // MARK: settings

    func update(_ change: (inout PetSettings) -> Void) {
        var next = settings
        change(&next)
        next = PetSettingsStore.sanitized(next)
        guard next != settings else { return }
        let serverChanged = next.accountScope != settings.accountScope
        settings = next
        try? settingsStore.save(next)
        if serverChanged {
            session.shutdown()
            session = makeSession()
            state = session.snapshot
            chatWindow?.render()
        } else {
            session.apply(settings: next)
        }
        onChange?()
    }

    func petMoved(to origin: NSPoint) {
        update { $0.petPosition = PetPosition(x: Double(origin.x), y: Double(origin.y)) }
    }

    func resetPosition() {
        update { $0.petPosition = nil }
        petWindow?.setFrameOrigin(PetWindow.initialOrigin(saved: nil))
        chatWindow?.position(near: petWindow)
    }

    // MARK: chat

    func toggleChat() {
        if let w = chatWindow, w.isVisible { closeChat(); return }
        openChat()
    }

    func openChat() {
        if chatWindow == nil { chatWindow = PetChatWindow(module: self) }
        chatWindow?.position(near: petWindow)
        chatWindow?.render()
        chatWindow?.makeKeyAndOrderFront(nil)
        chatWindow?.focusInput()
        session.touch()
        session.open()
    }

    func closeChat() {
        serverRecorder.cancel()
        dictation.stop()
        dictationState.stop()
        chatWindow?.orderOut(nil)
    }

    func signIn() { session.signIn() }
    func signOut() { session.signOut() }

    func send(_ text: String, completion: @escaping (String?) -> Void) {
        serverRecorder.cancel()
        dictation.stop()
        dictationState.stop()
        session.send(text: text) { refusal in DispatchQueue.main.async { completion(refusal) } }
    }

    func stopTurn() { session.stop() }

    /// The server's dictation (ADR 0014) when it offers it (`/client/config` dictation.enabled), else on-device Speech.
    var usesServerDictation: Bool { state.config?.dictationEnabled == true && state.auth == .signedIn }

    func toggleDictation(existingText: String, update: @escaping (String) -> Void) {
        if serverRecorder.isRecording { serverRecorder.stop(); return }  // hands the audio to the server
        if dictationState.isListening || dictationState.phase == .requestingPermission {
            dictation.stop()
            dictationState.stop()
            chatWindow?.render()
            return
        }
        if usesServerDictation { serverDictation(existingText: existingText, update: update); return }
        dictationState = DictationState()
        dictationState.start(existingText: existingText)
        chatWindow?.render()
        dictation.start { [weak self] event in
            guard let self = self else { return }
            switch event {
            case .permissionGranted: self.dictationState.permissionGranted()
            case let .denied(d): self.dictationState.permissionDenied(d)
            case let .unavailable(m): self.dictationState.unavailable(m)
            case let .hypothesis(t, final): self.dictationState.hypothesis(t, isFinal: final); update(self.dictationState.text)
            case .ended: self.dictationState.stop()
            }
            self.refreshFace()
            self.chatWindow?.render()
        }
    }

    private func serverDictation(existingText: String, update: @escaping (String) -> Void) {
        dictationState = DictationState()
        dictationState.start(existingText: existingText)
        chatWindow?.render()
        let maxSec = state.config?.dictationMaxSec ?? 60
        serverRecorder.start(maxSec: maxSec, granted: { [weak self] ok in
            guard let self = self else { return }
            if ok { self.dictationState.permissionGranted() } else { self.dictationState.permissionDenied(.microphone) }
            self.refreshFace()
            self.chatWindow?.render()
        }, finished: { [weak self] data, seconds in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let data = data, !data.isEmpty else { self.dictationState.stop(); self.chatWindow?.render(); return }
                self.session.dictate(audio: data, mime: "audio/mp4", fileName: "dictation.m4a", durationSec: min(seconds, Double(maxSec))) { r in
                    DispatchQueue.main.async {
                        switch r {
                        case let .success(text):
                            // Into the input field only; never sent by itself (spec/dictation.tsp).
                            if text.isEmpty { self.dictationState.stop() } else { self.dictationState.hypothesis(text, isFinal: true); update(self.dictationState.text) }
                        case let .failure(e):
                            self.dictationState.stop()
                            self.chatWindow?.flash(e.text)
                        }
                        self.refreshFace()
                        self.chatWindow?.render()
                    }
                }
            }
        })
    }

    // MARK: server features (record, memory, cards)

    func loadOlderHistory() { session.loadOlderHistory() }
    func forgetMemory(_ updateID: String) { session.forgetMemory(updateID: updateID) }
    func undoForget(_ updateID: String) { session.undoForget(updateID: updateID) }
    func canUndoForget(_ updateID: String) -> Bool { session.canUndoForget(updateID: updateID) }

    func answerCard(_ id: String, action: String, options: [String]) {
        session.answerCard(id: id, action: action, optionIDs: options) { [weak self] refusal in
            DispatchQueue.main.async { if let r = refusal { self?.chatWindow?.flash(r) } }
        }
    }

    /// "기억이 틀렸어요": asks what is wrong, then sends it as memory feedback for that answer.
    func askMemoryFeedback(turnID: String) {
        let alert = NSAlert()
        alert.messageText = "나초가 잘못 기억한 게 있나요?"
        alert.informativeText = "바르게 알려 주면 나초가 기억을 고쳐요."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "예: 이제 매운 음식은 못 먹어"
        alert.accessoryView = field
        alert.addButton(withTitle: "알려 주기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.sendMemoryFeedback(turnID: turnID, text: field.stringValue) { [weak self] refusal in
            DispatchQueue.main.async { self?.chatWindow?.flash(refusal ?? "알려 줘서 고마워요. 기억을 고칠게요.") }
        }
    }

    // MARK: attachments (capture → pet, shelf → pet, drop on the pet)

    /// Adds a file to the next message and opens the chat. Returns a Korean refusal, or nil.
    @discardableResult
    func attach(name: String, data: Data, mime: String? = nil) -> String? {
        var data = data
        var name = name
        var mime = mime
        let guessed = mime ?? PetMedia.mime(forFileName: name) ?? ""
        if PetMedia.shouldShrinkForNacho(mime: guessed, bytes: data.count), let jpeg = NachoPetModule.shrink(data) {
            data = jpeg
            name = (name as NSString).deletingPathExtension + ".jpg"
            mime = "image/jpeg"
        }
        switch PetMedia.prepare(name: name, data: data, mime: mime) {
        case let .failure(p):
            openChat()
            chatWindow?.flash(p.koreanMessage)
            return p.koreanMessage
        case let .success(file):
            let refusal = session.attach(file)
            openChat()
            if let r = refusal { chatWindow?.flash(r) }
            return refusal
        }
    }

    @discardableResult
    func attach(fileURL url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            return attachRefused("폴더는 보낼 수 없어요. 파일을 골라 주세요.")
        }
        if (values.fileSize ?? 0) > PetMedia.maxUploadBytes * 3 { return attachRefused(MediaProblem.tooLarge.koreanMessage) }
        guard let data = try? Data(contentsOf: url) else { return attachRefused("파일을 읽지 못했어요.") }
        return attach(name: url.lastPathComponent, data: data)
    }

    func attachText(_ text: String, title: String) {
        let name = PetMedia.sanitizedName(String(title.prefix(40))).replacingOccurrences(of: "/", with: "-")
        attach(name: (name.isEmpty ? "snippet" : name) + ".txt", data: Data(text.utf8), mime: "text/plain")
    }

    private func attachRefused(_ message: String) -> String {
        openChat()
        chatWindow?.flash(message)
        return message
    }

    func removePending(_ id: Int) { session.removePending(id: id) }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PetMedia.mimeByExtension.keys.compactMap { UTType(filenameExtension: $0) }
        panel.message = "나초에게 보낼 파일을 고르세요 (그림, PDF, 글, mp4)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls.prefix(PetMedia.maxAttachments) { attach(fileURL: url) }
    }

    /// Pictures larger than Nacho can look at (5 MB) become a JPEG of at most 2048 px on the long side.
    static func shrink(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let long = max(rep.pixelsWide, rep.pixelsHigh)
        let scale = min(1, 2048 / CGFloat(long))
        let w = max(1, Int(CGFloat(rep.pixelsWide) * scale)), h = max(1, Int(CGFloat(rep.pixelsHigh) * scale))
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        rep.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = out.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpeg.count <= PetMedia.maxSeenImageBytes { return jpeg }
        }
        return nil
    }

    // MARK: connector commands

    func execute(_ command: PetCommand, done: @escaping (PetCommandOutcome) -> Void) {
        DispatchQueue.main.async {
            self.commandsRun += 1
            let outcome = self.perform?(command) ?? PetCommandOutcome(ok: false, message: "Nacho Combo is not ready.")
            done(outcome)
        }
    }

    // MARK: state

    private func sessionChanged(_ st: PetSessionState) {
        state = st
        refreshFace()
        chatWindow?.render()
        onChange?()
    }

    var face: PetFace {
        PetFace.derive(dictating: dictationState.isListening || state.dictating, chat: state.chat, now: Date(), lastInteraction: state.lastInteraction)
    }

    private func refreshFace() { petWindow?.show(face) }
}

/// Lets Capture Float and File Shelf hand things to the pet without knowing about it. Nil while the pet is off, so
/// their "Ask Nacho" menu items only appear when Nacho is there.
enum PetHandoff {
    static weak var module: NachoPetModule?

    static var available: Bool { module?.isRunning == true }

    static func askAbout(png: Data, name: String) {
        module?.attach(name: name, data: png, mime: "image/png")
    }

    static func give(_ item: ShelfItem) {
        guard let module = module else { return }
        switch item.kind {
        case .file, .image: if let url = item.fileURL { module.attach(fileURL: url) }
        case .text: module.attachText(item.text ?? "", title: item.title)
        case .link: module.attachText(item.text ?? "", title: "link")
        }
    }
}

// MARK: - The pet on screen

final class PetWindow: NSPanel {
    static let size = NSSize(width: 112, height: 112)
    private let view: PetCharacterView

    init(module: NachoPetModule) {
        view = PetCharacterView(frame: NSRect(origin: .zero, size: PetWindow.size), module: module)
        super.init(contentRect: NSRect(origin: .zero, size: PetWindow.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = view
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        setAccessibilityIdentifier("nacho-pet")
    }

    func show(_ face: PetFace) { view.face = face }

    /// The saved place if it is still on a connected screen, otherwise the bottom-right corner of the main screen.
    static func initialOrigin(saved: PetPosition?) -> NSPoint {
        if let p = saved {
            let rect = NSRect(origin: NSPoint(x: p.x, y: p.y), size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) {
                return rect.origin
            }
        }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: vf.maxX - size.width - 24, y: vf.minY + 24)
    }
}

final class PetCharacterView: NSView {
    weak var module: NachoPetModule?
    private let imageView = NSImageView()
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragged = false
    private var dropTargeted = false { didSet { needsDisplay = true } }

    var face: PetFace = .idle {
        didSet {
            guard face != oldValue || imageView.image == nil else { return }
            imageView.image = PetArt.image(face) ?? PetArt.image(named: "idle")
            toolTip = "나초 · \(face.koreanLabel) — 클릭: 대화, 끌기: 옮기기, 파일 놓기: 나초에게 주기"
            setAccessibilityLabel("나초 펫, \(face.koreanLabel)")
            animate()
        }
    }

    init(frame: NSRect, module: NachoPetModule) {
        self.module = module
        super.init(frame: frame)
        wantsLayer = true
        imageView.frame = bounds.insetBy(dx: 6, dy: 6)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        addSubview(imageView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
        face = .idle
        imageView.image = PetArt.image(named: "idle")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { module?.toggleChat(); return true }

    private func animate() {
        guard let layer = imageView.layer else { return }
        layer.removeAnimation(forKey: "bob")
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        switch face {
        case .idle, .happy: bob.fromValue = 0; bob.toValue = 3; bob.duration = face == .happy ? 0.35 : 1.4
        case .thinking, .speaking, .listening: bob.fromValue = 0; bob.toValue = 1.5; bob.duration = 0.5
        default: return
        }
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "bob")
    }

    override func draw(_ dirtyRect: NSRect) {
        if dropTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
        }
        if imageView.image == nil {
            // A build without the character art (forks remove Resources/Nacho): a plain chat bubble.
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 20, dy: 20)).fill()
            let symbol = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: nil)
            symbol?.draw(in: bounds.insetBy(dx: 38, dy: 38))
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let m0 = dragStartMouse, let o0 = dragStartOrigin, let w = window else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - m0.x, dy = m.y - m0.y
        if !dragged && abs(dx) < 3 && abs(dy) < 3 { return }
        dragged = true
        w.setFrameOrigin(NSPoint(x: o0.x + dx, y: o0.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartMouse = nil; dragStartOrigin = nil }
        if dragged {
            if let o = window?.frame.origin { module?.petMoved(to: o) }
        } else {
            module?.toggleChat()
        }
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
