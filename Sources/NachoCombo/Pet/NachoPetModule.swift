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
    private(set) var petWindow: PetWindow?
    private(set) var chatWindow: PetChatWindow?
    private var faceTimer: Timer?
    private var nameTag: PetNameTag?
    private var gateObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var displaysAsleep = false
    let dictation = PetDictationController()
    let serverRecorder = PetServerRecorder()
    private(set) var dictationState = DictationState()
    private(set) var commandsRun = 0
    // Selection bar (PetSelection*.swift): the flow, the event watch, the panel, opened "보낸 내용 보기" lists.
    private(set) var selection: PetSelectionFlow!
    let selectionWatcher = PetSelectionWatcher()
    let selectionBar = PetSelectionBarPanel()
    var selectionExpanded: Set<String> = []
    var selectionTrustTimer: Timer?
    var selectionAnchor: NSRect?

    override init() {
        settings = settingsStore.load()
        super.init()
        session = makeSession()
        login.anchor = { [weak self] in self?.chatWindow ?? self?.petWindow }
        selection = PetSelectionFlow(sender: self, copyText: { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }, openURL: { NSWorkspace.shared.open($0) })
        selection.onChange = { [weak self] in self?.selectionChanged() }
        setUpSelectionBar()
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
        observeGate()
        faceTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refreshFace() }
        RunLoop.main.add(t, forMode: .common)
        faceTimer = t
        refreshSelectionWatcher()
        return .running
    }

    func stop() {
        faceTimer?.invalidate()
        faceTimer = nil
        selectionWatcher.stop()
        selectionTrustTimer?.invalidate()
        selectionTrustTimer = nil
        selection.dismiss()
        selectionBar.hide()
        for (center, o) in gateObservers { center.removeObserver(o) }
        gateObservers = []
        nameTag?.orderOut(nil)
        petWindow?.characterView.stop()
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
         "chatOpen": chatWindow?.isVisible == true ? "yes" : "no", "server": settings.endpoint?.base.absoluteString ?? "-",
         // Phase and counts only: never the selected text.
         "selectionBar": settings.selectionBar.enabled ? (selectionWatcher.isRunning ? "on" : "on, waiting for Accessibility") : "off",
         "selection": selection.diagnostics]
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
        refreshSelectionWatcher()
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

    func openChat(focusInput: Bool = true) {
        if chatWindow == nil { chatWindow = PetChatWindow(module: self) }
        chatWindow?.position(near: petWindow)
        chatWindow?.render()
        chatWindow?.makeKeyAndOrderFront(nil)
        if focusInput { chatWindow?.focusInput() }
        nameTag?.orderOut(nil)
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
        if selection?.phase == .preview { return .waiting }
        return PetFace.derive(dictating: dictationState.isListening || state.dictating, chat: state.chat, now: Date(), lastInteraction: state.lastInteraction)
    }

    private func refreshFace() { petWindow?.show(face) }

    // MARK: name tag and when the pet may move

    func showNameTag(_ kind: PetNameTag.Kind?) {
        guard let kind = kind, let pet = petWindow, chatWindow?.isVisible != true || kind == .drop else { nameTag?.orderOut(nil); return }
        if nameTag == nil { nameTag = PetNameTag() }
        switch kind {
        case .hover: nameTag?.show(title: "나초", detail: "\(face.koreanLabel) · 클릭: 대화", above: pet)
        case .drop: nameTag?.show(title: "나초에게 주기", detail: "놓으면 첨부돼요", above: pet)
        }
    }

    /// Frames stop while the pet is covered or off screen, the displays sleep, or a full-screen app is in front.
    private func observeGate() {
        guard gateObservers.isEmpty else { updateGate(); return }
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ object: Any? = nil, _ run: @escaping () -> Void) {
            gateObservers.append((center, center.addObserver(forName: name, object: object, queue: .main) { _ in run() }))
        }
        on(ws, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.displaysAsleep = true; self?.updateGate() }
        on(ws, NSWorkspace.willSleepNotification) { [weak self] in self?.displaysAsleep = true; self?.updateGate() }
        on(ws, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.displaysAsleep = false; self?.updateGate() }
        on(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.displaysAsleep = false; self?.updateGate() }
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.updateGate() }
        on(ws, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.updateGate() }
        on(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification, petWindow) { [weak self] in self?.updateGate() }
        updateGate()
    }

    private func updateGate() {
        guard let pet = petWindow else { return }
        var g = pet.characterView.gate
        g.windowVisible = pet.isVisible && pet.occlusionState.contains(.visible)
        g.displaysAsleep = displaysAsleep
        g.fullScreenAppInFront = NachoPetModule.fullScreenAppInFront(on: pet.screen)
        pet.characterView.gate = g
    }

    /// The front app (not this one) has a window covering the whole screen the pet is on. Window bounds need no
    /// Screen Recording permission (only titles do).
    static func fullScreenAppInFront(on screen: NSScreen?) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let screen = screen ?? NSScreen.main,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let size = screen.frame.size
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier, (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return abs(b.width - size.width) < 1 && abs(b.height - size.height) < 1
        }
    }
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
    static let size = NSSize(width: CGFloat(PetTokens.Size.pet), height: CGFloat(PetTokens.Size.pet))
    private let view: PetCharacterView
    var characterView: PetCharacterView { view }

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
        let margin = CGFloat(PetTokens.Size.petScreenMargin)
        return NSPoint(x: vf.maxX - size.width - margin, y: vf.minY + margin)
    }
}
