import AppKit
import NachoComboCore

/// The chat bubble next to the pet, ported from the confirmed web mockup (design/web, `.chat`): header with the one
/// status line, optional banner, the log (PetTranscript items, one view each), pending files, and the composer.
/// A borderless key panel that does not activate the app, so the window the user was working in stays the "front
/// window" that Nacho arranges. Its tail points at the pet.
final class PetChatWindow: NSPanel, NSTextFieldDelegate {
    private typealias S = PetTokens.Size
    private typealias Sp = PetTokens.Space
    static var size: NSSize { NSSize(width: CGFloat(S.chatWidth), height: CGFloat(S.chatHeight + S.chatTail)) }
    private weak var module: NachoPetModule?

    private let background = PetChatBackground()
    private let content = NSView()
    // header (`.chat-head`)
    private let avatar = NSImageView()
    private let name = NSTextField(labelWithString: "나초")
    private let dot = PetBox()
    private let status = NSTextField(labelWithString: "")
    private var tabButtons: [PetPill] = []
    private var tab = 0
    // banner, log, pending, composer
    private let banner = PetBox()
    private let bannerText = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let logStack = NSStackView()
    private let pendingRow = NSStackView()
    private let composer = NSStackView()
    private let fieldBox = PetFieldBox()
    private let input = PetInputField()
    private let wave = PetWave()
    private var attachButton: PetPill!
    private var micButton: PetPill!
    private var sendButton: PetPill!
    private let signInView = NSStackView()
    private var signInButton: PetPill!
    private let signInNote = NSTextField(wrappingLabelWithString: "")

    private var flashText: String?
    private var flashUntil = Date.distantPast
    private var connectionsText: NSAttributedString?
    private var shownItems: [PetChatItem] = []
    private var shownViews: [NSView] = []
    private var tickScheduled = false

    private var logWidth: CGFloat { CGFloat(S.chatWidth - 2 * Sp.m) }

    init(module: NachoPetModule) {
        self.module = module
        super.init(contentRect: NSRect(origin: .zero, size: PetChatWindow.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "나초"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setAccessibilityIdentifier("nacho-pet-chat")
        setAccessibilityRole(.dialog)
        setAccessibilityLabel("나초와 대화")
        build()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { module?.closeChat() }

    override func close() {
        module?.dictation.stop()
        super.close()
    }

    // MARK: layout

    private func build() {
        background.frame = NSRect(origin: .zero, size: PetChatWindow.size)
        background.autoresizingMask = [.width, .height]
        contentView = background
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        contentTop = content.topAnchor.constraint(equalTo: background.topAnchor)
        contentBottom = content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -PetChatBackground.tail)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                                     content.trailingAnchor.constraint(equalTo: background.trailingAnchor), contentTop, contentBottom])

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                                     column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor)])

        column.addArrangedSubview(buildHeader())
        column.addArrangedSubview(buildBanner())
        column.addArrangedSubview(buildLog())
        column.addArrangedSubview(buildSignIn())
        column.addArrangedSubview(buildPending())
        column.addArrangedSubview(buildComposer())
    }

    private var contentTop: NSLayoutConstraint!
    private var contentBottom: NSLayoutConstraint!

    private func buildHeader() -> NSView {
        let head = PetBox()
        head.translatesAutoresizingMaskIntoConstraints = false
        head.heightAnchor.constraint(equalToConstant: CGFloat(S.headerHeight)).isActive = true
        head.widthAnchor.constraint(equalToConstant: CGFloat(S.chatWidth)).isActive = true
        avatar.image = PetArt.image(named: "idle")
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = CGFloat(S.avatar / 2)
        avatar.layer?.masksToBounds = true
        avatar.layer?.backgroundColor = PetTheme.color(\.accentSoft).cgColor
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.widthAnchor.constraint(equalToConstant: CGFloat(S.avatar)).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: CGFloat(S.avatar)).isActive = true
        name.font = PetTheme.title
        name.textColor = PetTheme.text
        dot.radius = CGFloat(S.statusDot / 2)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: CGFloat(S.statusDot)).isActive = true
        dot.heightAnchor.constraint(equalToConstant: CGFloat(S.statusDot)).isActive = true
        status.font = PetTheme.caption
        status.textColor = PetTheme.secondary
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityIdentifier("nacho-pet-status")
        let statusRow = NSStackView(views: [dot, status])
        statusRow.spacing = CGFloat(Sp.xs)
        let who = NSStackView(views: [name, statusRow])
        who.orientation = .vertical
        who.alignment = .leading
        who.spacing = 0
        who.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let seg = PetBox()
        seg.fill = PetTheme.color(\.surface)
        seg.radius = CGFloat(PetTokens.Radius.control)
        seg.translatesAutoresizingMaskIntoConstraints = false
        let segRow = NSStackView()
        segRow.spacing = 0
        segRow.translatesAutoresizingMaskIntoConstraints = false
        for (i, title) in ["대화", "연결"].enumerated() {
            let b = PetPill(title: title, font: PetTheme.caption, color: PetTheme.secondary, height: S.control - 6,
                            radius: PetTokens.Radius.control - 2, padding: Sp.s)
            b.onClick = { [weak self] in self?.select(tab: i) }
            tabButtons.append(b)
            segRow.addArrangedSubview(b)
        }
        seg.addSubview(segRow)
        NSLayoutConstraint.activate([segRow.topAnchor.constraint(equalTo: seg.topAnchor, constant: 2), segRow.bottomAnchor.constraint(equalTo: seg.bottomAnchor, constant: -2),
                                     segRow.leadingAnchor.constraint(equalTo: seg.leadingAnchor, constant: 2), segRow.trailingAnchor.constraint(equalTo: seg.trailingAnchor, constant: -2)])

        let row = NSStackView(views: [avatar, who, seg])
        row.spacing = CGFloat(Sp.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(row)
        let hair = PetBox()
        hair.fill = PetTheme.color(\.separator)
        hair.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(hair)
        NSLayoutConstraint.activate([
            row.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: CGFloat(Sp.m)),
            row.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -CGFloat(Sp.m)),
            hair.leadingAnchor.constraint(equalTo: head.leadingAnchor), hair.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            hair.bottomAnchor.constraint(equalTo: head.bottomAnchor), hair.heightAnchor.constraint(equalToConstant: 1),
        ])
        styleTabs()
        return head
    }

    private func buildBanner() -> NSView {
        banner.fill = PetTheme.color(\.warningSoft)
        banner.radius = CGFloat(PetTokens.Radius.card)
        banner.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: PetTheme.symbol("exclamationmark.triangle", size: S.sendIcon) ?? NSImage())
        icon.contentTintColor = PetTheme.color(\.warning)
        bannerText.font = PetTheme.caption
        bannerText.textColor = PetTheme.color(\.warning)
        bannerText.preferredMaxLayoutWidth = logWidth - CGFloat(2 * Sp.m + S.sendIcon + Sp.s)
        let row = NSStackView(views: [icon, bannerText])
        row.alignment = .top
        row.spacing = CGFloat(Sp.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(row)
        NSLayoutConstraint.activate([
            banner.widthAnchor.constraint(equalToConstant: logWidth),
            row.topAnchor.constraint(equalTo: banner.topAnchor, constant: CGFloat(Sp.s)),
            row.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -CGFloat(Sp.s)),
            row.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: CGFloat(Sp.m)),
            row.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -CGFloat(Sp.m)),
        ])
        let wrap = PetRowInset(banner, top: Sp.s)
        wrap.isHidden = true
        return wrap
    }

    private func buildLog() -> NSView {
        let doc = PetFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        logStack.orientation = .vertical
        logStack.alignment = .leading
        logStack.spacing = CGFloat(Sp.s)
        logStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(logStack)
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityIdentifier("nacho-pet-transcript")
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: CGFloat(S.chatWidth)),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor), doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            // Short logs sit at the bottom, next to the composer (`justify-content: flex-end`).
            logStack.topAnchor.constraint(greaterThanOrEqualTo: doc.topAnchor, constant: CGFloat(Sp.m)),
            logStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -CGFloat(Sp.m)),
            logStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: CGFloat(Sp.m)),
            logStack.widthAnchor.constraint(equalToConstant: logWidth),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return scroll
    }

    private func buildSignIn() -> NSView {
        signInView.orientation = .vertical
        signInView.alignment = .centerX
        signInView.spacing = CGFloat(Sp.m)
        signInView.edgeInsets = NSEdgeInsets(top: CGFloat(Sp.xl), left: CGFloat(Sp.xl), bottom: CGFloat(Sp.xl), right: CGFloat(Sp.xl))
        let art = NSImageView(image: PetArt.image(named: "happy") ?? NSImage())
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: CGFloat(S.signinArt)).isActive = true
        art.heightAnchor.constraint(equalToConstant: CGFloat(S.signinArt)).isActive = true
        let inner = CGFloat(S.chatWidth - 2 * Sp.xl)
        let hi = PetLinkText(PetLinkText.plain("안녕하세요, 나초예요.", font: PetTheme.title, color: PetTheme.text, align: .center), maxWidth: inner)
        let p = PetLinkText(PetLinkText.plain("나초 계정으로 로그인하면 여기서 대화할 수 있어요. 캡처나 선반의 파일을 건네거나, 창 배치나 가젯을 켜고 끄는 일도 부탁할 수 있어요.",
                                              font: PetTheme.body, color: PetTheme.secondary, align: .center), maxWidth: inner)
        signInButton = PetPill(title: "나초 계정으로 로그인", symbol: "person", iconSize: 15, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold),
                               color: PetTheme.color(\.onAccent), fill: PetTheme.accent, height: S.control + 4, padding: Sp.l)
        signInButton.onClick = { [weak self] in self?.module?.signIn() }
        signInButton.setAccessibilityIdentifier("nacho-pet-sign-in")
        let small = PetLinkText(PetLinkText.plain("로그인은 브라우저 창(auth.nachotown.com)에서 해요. 비밀번호는 콤보가 보지 않아요.",
                                                  font: PetTheme.caption, color: PetTheme.tertiary, align: .center), maxWidth: inner)
        for v in [art, hi, p, signInButton!, small] as [NSView] { signInView.addArrangedSubview(v) }
        signInView.isHidden = true
        signInView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return signInView
    }

    private func buildPending() -> NSView {
        pendingRow.orientation = .horizontal
        pendingRow.spacing = CGFloat(Sp.s)
        pendingRow.distribution = .fillEqually
        pendingRow.translatesAutoresizingMaskIntoConstraints = false
        pendingRow.widthAnchor.constraint(equalToConstant: logWidth).isActive = true
        let wrap = PetRowInset(pendingRow, top: 0, bottom: Sp.s)
        wrap.isHidden = true
        return wrap
    }

    private func buildComposer() -> NSView {
        attachButton = PetPill(symbol: "paperclip", color: PetTheme.secondary, height: S.control, radius: S.control / 2, width: S.control)
        attachButton.toolTip = "파일 주기 (그림, PDF, 글, mp4). 나초 위에 끌어다 놓아도 돼요."
        attachButton.onClick = { [weak self] in self?.module?.pickFiles() }
        attachButton.setAccessibilityIdentifier("nacho-pet-attach")
        micButton = PetPill(symbol: "mic", color: PetTheme.secondary, height: S.control, radius: S.control / 2, width: S.control)
        micButton.onClick = { [weak self] in self?.micClicked() }
        micButton.setAccessibilityIdentifier("nacho-pet-mic")
        sendButton = PetPill(symbol: "arrow.up", iconSize: S.sendIcon, color: PetTheme.tertiary, fill: PetTheme.color(\.surface),
                             height: S.sendButton, radius: S.sendButton / 2, width: S.sendButton)
        sendButton.onClick = { [weak self] in self?.sendClicked() }
        sendButton.setAccessibilityIdentifier("nacho-pet-send")

        fieldBox.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.heightAnchor.constraint(equalToConstant: CGFloat(S.composerHeight)).isActive = true
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = PetTheme.body
        input.textColor = PetTheme.text
        input.placeholderAttributedString = NSAttributedString(string: "나초에게 말하기…", attributes: [.font: PetTheme.body, .foregroundColor: PetTheme.tertiary])
        input.delegate = self
        input.target = self
        input.action = #selector(returnPressed)
        input.lineBreakMode = .byTruncatingHead
        input.cell?.usesSingleLineMode = true
        input.setAccessibilityIdentifier("nacho-pet-input")
        input.onFocus = { [weak self] f in self?.fieldBox.focused = f }
        wave.isHidden = true
        let fieldRow = NSStackView(views: [wave, input])
        fieldRow.spacing = CGFloat(Sp.s)
        fieldRow.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.addSubview(fieldRow)
        NSLayoutConstraint.activate([
            fieldRow.centerYAnchor.constraint(equalTo: fieldBox.centerYAnchor),
            fieldRow.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: CGFloat(Sp.m)),
            fieldRow.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -CGFloat(Sp.m)),
        ])
        composer.setViews([attachButton, fieldBox, micButton, sendButton], in: .leading)
        composer.spacing = CGFloat(Sp.xs)
        composer.edgeInsets = NSEdgeInsets(top: CGFloat(Sp.s), left: CGFloat(Sp.m), bottom: CGFloat(Sp.m), right: CGFloat(Sp.m))
        composer.translatesAutoresizingMaskIntoConstraints = false
        composer.widthAnchor.constraint(equalToConstant: CGFloat(S.chatWidth)).isActive = true
        fieldBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return composer
    }

    func focusInput() {
        if !composer.isHidden { makeFirstResponder(input) }
    }

    /// Above the pet with the tail on its head (or below it at the top of the screen), kept on the pet's screen.
    func position(near pet: NSWindow?) {
        guard let pet = pet else { center(); return }
        let screen = (pet.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = frame.size
        let gap = CGFloat(S.chatGapToPet)
        var x = pet.frame.maxX - size.width
        var y = pet.frame.maxY + gap
        let below = y + size.height > screen.maxY
        if below { y = pet.frame.minY - size.height - gap }
        x = min(max(x, screen.minX + CGFloat(Sp.s)), screen.maxX - size.width - CGFloat(Sp.s))
        y = min(max(y, screen.minY + CGFloat(Sp.s)), screen.maxY - size.height - CGFloat(Sp.s))
        setFrameOrigin(NSPoint(x: x, y: y))
        background.tailOnTop = below
        background.tailFromRight = min(max(x + size.width - pet.frame.midX, CGFloat(PetTokens.Radius.window) + PetChatBackground.tail),
                                       size.width - CGFloat(PetTokens.Radius.window) - PetChatBackground.tail)
        contentTop.constant = below ? PetChatBackground.tail : 0
        contentBottom.constant = below ? 0 : -PetChatBackground.tail
        invalidateShadow()
    }

    /// A short message at the end of the log for a few seconds (refused file, nothing to send…).
    func flash(_ text: String) {
        flashText = text
        flashUntil = Date().addingTimeInterval(6)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.render() }
    }

    // MARK: rendering

    func render() {
        guard let module = module else { return }
        let st = module.state
        let signedIn = st.auth == .signedIn
        let head = PetTranscript.headerStatus(st)
        status.stringValue = head.text + (PetTranscript.headerCredits(st).map { " · \($0)" } ?? "")
        switch head.dot {
        case .ok: dot.fill = PetTheme.color(\.success)
        case .busy: dot.fill = PetTheme.accent
        case .wait, .warn: dot.fill = PetTheme.color(\.warning)
        case .off: dot.fill = PetTheme.tertiary
        }
        let service = st.config?.serviceNotice
        bannerText.stringValue = service ?? ""
        banner.superview?.isHidden = service == nil || !signedIn

        scroll.isHidden = !signedIn
        signInView.isHidden = signedIn
        composer.isHidden = !signedIn
        if case .signingIn = st.auth { signInButton.set(title: "브라우저에서 로그인하는 중…"); signInButton.isEnabled = false }
        else { signInButton.set(title: "나초 계정으로 로그인"); signInButton.isEnabled = true }

        let busy = st.chat.isBusy
        let listening = module.dictationState.isListening || module.serverRecorder.isRecording
        let hasText = !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !st.pending.isEmpty
        if busy {
            sendButton.set(symbol: "stop.fill", color: PetTheme.color(\.window), fill: .some(PetTheme.text))
            sendButton.setAccessibilityLabel("답변 멈추기"); sendButton.toolTip = "멈추기"
        } else {
            sendButton.set(symbol: "arrow.up", color: hasText ? PetTheme.color(\.onAccent) : PetTheme.tertiary,
                           fill: .some(hasText ? PetTheme.accent : PetTheme.color(\.surface)))
            sendButton.setAccessibilityLabel("보내기"); sendButton.toolTip = "보내기"
        }
        sendButton.isEnabled = !st.uploading
        micButton.set(symbol: listening ? "mic.fill" : "mic", color: listening ? PetTheme.color(\.onDanger) : PetTheme.secondary,
                      fill: .some(listening ? PetTheme.color(\.danger) : nil))
        micButton.toolTip = listening ? "다 말하면 다시 누르세요" : "받아쓰기 (한국어)"
        micButton.setAccessibilityLabel(listening ? "받아쓰기 멈추기" : "받아쓰기")
        wave.isHidden = !listening
        input.placeholderAttributedString = NSAttributedString(string: listening ? "듣고 있어요" : "나초에게 말하기…",
                                                               attributes: [.font: PetTheme.body, .foregroundColor: listening ? PetTheme.color(\.danger) : PetTheme.tertiary])
        renderPending(st.pending)
        if tab == 0 { renderLog(st) } else { renderConnections() }
    }

    /// Notices that are not part of a turn: flash, dictation problems, uploads, the session's last error.
    private func noticeLine(_ st: PetSessionState) -> PetChatItem? {
        guard let module = module else { return nil }
        var text: String?
        if let f = flashText, Date() < flashUntil { text = f }
        else if case let .denied(d) = module.dictationState.phase { text = d.koreanMessage }
        else if case let .unavailable(m) = module.dictationState.phase { text = m }
        else if st.uploading { text = "파일 올리는 중…" }
        else if st.dictating { text = "받아쓰는 중…" }
        else if let n = st.chat.notice ?? st.notice, n != st.config?.serviceNotice { text = n }
        return text.map { .line(PetChatLine(kind: .notice, symbol: "info.circle", parts: [PetTextPart($0)])) }
    }

    private func renderLog(_ st: PetSessionState) {
        guard st.auth == .signedIn else { return }
        var items = PetTranscript.items(st, undoSecondsLeft: { [weak self] id in self?.undoSecondsLeft(id, st) })
        if let n = noticeLine(st) { items.append(n) }
        guard items != shownItems else { return }
        // Keep the views of the unchanged beginning (streaming only changes the end).
        var keep = 0
        while keep < min(items.count, shownItems.count), items[keep] == shownItems[keep] { keep += 1 }
        for v in shownViews[keep...] { logStack.removeArrangedSubview(v); v.removeFromSuperview() }
        shownViews.removeSubrange(keep...)
        let maker = PetItemViews(width: logWidth, onLink: { [weak self] in self?.open($0) },
                                 onExample: { [weak self] in self?.input.stringValue = $0; self?.focusInput(); self?.render() })
        for item in items[keep...] {
            let v = maker.view(item)
            logStack.addArrangedSubview(v)
            shownViews.append(v)
        }
        shownItems = items
        logStack.layoutSubtreeIfNeeded()
        if let doc = scroll.documentView {
            doc.layoutSubtreeIfNeeded()
            doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height)))
        }
        // The undo countdown ("7초 안에 되돌리기") ticks every second while it lasts.
        if st.chat.memoryNotes.contains(where: { undoSecondsLeft($0.updateID, st) != nil }), !tickScheduled {
            tickScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tickScheduled = false; self?.render() }
        }
    }

    private func undoSecondsLeft(_ updateID: String, _ st: PetSessionState) -> Int? {
        guard let at = st.chat.memoryNotes.first(where: { $0.updateID == updateID })?.forgottenAt,
              module?.canUndoForget(updateID) == true else { return nil }
        let left = Int((PetSession.restoreWindow - Date().timeIntervalSince(at)).rounded(.up))
        return left > 0 ? left : nil
    }

    private func open(_ url: URL) {
        guard url.scheme == "nachopet" else { NSWorkspace.shared.open(url); return }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch url.host {
        case "older": module?.loadOlderHistory()
        case "forget": if let u = q["u"] { module?.forgetMemory(u) }
        case "undo": if let u = q["u"] { module?.undoForget(u) }
        case "memfb": if let t = q["turn"] { module?.askMemoryFeedback(turnID: t) }
        case "card": if let id = q["id"], let a = q["action"] { module?.answerCard(id, action: a, options: q["option"].map { [$0] } ?? []) }
        default: break
        }
    }

    /// `.pending .chip`: thumbnail, name, what Nacho can do with it, remove button.
    private func renderPending(_ pending: [PetPendingFile]) {
        pendingRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pendingRow.superview?.isHidden = pending.isEmpty || composer.isHidden
        for p in pending {
            let chip = PetBox()
            chip.fill = PetTheme.color(\.surface)
            chip.radius = CGFloat(PetTokens.Radius.card)
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: CGFloat(S.thumbnail)).isActive = true
            chip.toolTip = p.file.readability.koreanNote
            let thumb = NSImageView()
            let isImage = p.file.mime.hasPrefix("image/")
            thumb.image = isImage ? NSImage(data: p.file.data) : PetTheme.symbol("doc", size: S.icon)
            thumb.imageScaling = isImage ? .scaleAxesIndependently : .scaleNone
            thumb.contentTintColor = PetTheme.secondary
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = CGFloat(PetTokens.Radius.thumbnail)
            thumb.layer?.masksToBounds = true
            thumb.layer?.backgroundColor = PetTheme.color(\.surfaceRaised).cgColor
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.widthAnchor.constraint(equalToConstant: CGFloat(S.thumbnail - 8)).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: CGFloat(S.thumbnail - 8)).isActive = true
            let title = NSTextField(labelWithString: p.file.name)
            title.font = PetTheme.font(PetTokens.Font.caption, PetTokens.Font.weightMedium)
            title.textColor = PetTheme.text
            title.lineBreakMode = .byTruncatingMiddle
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let note = NSTextField(labelWithString: PetText.pendingNote(p.file))
            note.font = PetTheme.caption
            note.textColor = PetTheme.tertiary
            let names = NSStackView(views: [title, note])
            names.orientation = .vertical
            names.alignment = .leading
            names.spacing = 0
            names.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let id = p.id
            let x = PetPill(symbol: "xmark", iconSize: 10, color: PetTheme.secondary, fill: PetTheme.color(\.surfaceRaised), height: 22, radius: 11, width: 22)
            x.onClick = { [weak self] in self?.module?.removePending(id) }
            x.toolTip = "빼기"
            let row = NSStackView(views: [thumb, names, x])
            row.spacing = CGFloat(Sp.s)
            row.translatesAutoresizingMaskIntoConstraints = false
            chip.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
                row.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: CGFloat(Sp.xs)),
                row.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -CGFloat(Sp.s)),
            ])
            pendingRow.addArrangedSubview(chip)
        }
    }

    private func renderConnections() {
        shownItems = []
        shownViews.forEach { $0.removeFromSuperview() }
        shownViews = []
        let text = connectionsText ?? PetLinkText.plain("불러오는 중…", font: PetTheme.body, color: PetTheme.secondary)
        let v = PetLinkText(text, maxWidth: logWidth)
        logStack.addArrangedSubview(v)
        shownViews = [v]
    }

    private func loadConnections() {
        connectionsText = nil
        render()
        module?.session.loadConnectors { [weak self] result in
            DispatchQueue.main.async {
                self?.connectionsText = PetChatWindow.describe(result, connector: self?.module?.state.connector ?? .off)
                self?.render()
            }
        }
    }

    static func describe(_ result: Result<ConnectorOverview, ConnectorError>, connector: ConnectorPhase) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ s: String, bold: Bool = false, color: NSColor = PetTheme.text) {
            let font = bold ? PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold) : PetTheme.caption
            out.append(NSAttributedString(string: s + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: PetTheme.paragraph(font)]))
        }
        line("이 맥 (나초 콤보)", bold: true)
        line("  창 배치·가젯 켜기/끄기: \(connector.koreanLabel)", color: PetTheme.secondary)
        switch result {
        case let .failure(e):
            line("")
            line(e.koreanMessage, color: PetTheme.color(\.warning))
        case let .success(o):
            line("")
            line("연결된 서비스", bold: true)
            if o.connections.isEmpty { line("  아직 없어요", color: PetTheme.secondary) }
            for c in o.connections {
                line("  \(c.isHealthy ? "●" : "○") \(c.label) — \(c.statusText)\(c.accountLabel.map { " · \($0)" } ?? "")")
                if !c.scopeSummary.isEmpty { line("     \(c.scopeSummary)", color: PetTheme.secondary) }
            }
            line("")
            line("나초가 쓸 수 있는 도구", bold: true)
            for t in o.tools { line("  \(t.enabled ? "●" : "○") \(t.name) · \(t.kindText)", color: t.enabled ? PetTheme.text : PetTheme.secondary) }
            if !o.capabilities.isEmpty {
                line("")
                line("이 맥이 나초에게 준 기능", bold: true)
                for c in o.capabilities { line("  ● \(c.name)", color: PetTheme.secondary) }
            }
        }
        return out
    }

    // MARK: actions

    private func select(tab i: Int) {
        tab = i
        styleTabs()
        if i == 1 { loadConnections() } else { shownItems = []; shownViews.forEach { $0.removeFromSuperview() }; shownViews = []; render() }
    }

    private func styleTabs() {
        for (i, b) in tabButtons.enumerated() {
            b.set(color: i == tab ? PetTheme.text : PetTheme.secondary, fill: .some(i == tab ? PetTheme.color(\.accentSoft) : nil))
        }
    }

    @objc private func returnPressed() { sendClicked() }

    private func sendClicked() {
        guard let module = module else { return }
        if module.state.chat.isBusy { module.stopTurn(); return }
        let text = input.stringValue
        sendButton.isEnabled = false
        module.send(text) { [weak self] refusal in
            guard let self = self else { return }
            self.sendButton.isEnabled = true
            if let r = refusal { self.flash(r) } else { self.input.stringValue = "" }
            if self.tab != 0 { self.select(tab: 0) }
            self.render()
        }
    }

    private func micClicked() {
        module?.toggleDictation(existingText: input.stringValue) { [weak self] text in self?.input.stringValue = text; self?.render() }
        render()
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { module?.closeChat(); return true }
        return false
    }
}

/// The text field inside `.field`; reports focus so the capsule can draw the focus ring.
final class PetInputField: NSTextField {
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus?(false)
    }
}

final class PetFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A view with token insets around one child, full chat width (`margin: var(--space-s) var(--space-m) 0`).
final class PetRowInset: NSView {
    init(_ child: NSView, top: Double = 0, bottom: Double = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CGFloat(PetTokens.Size.chatWidth)),
            child.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(top)),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(bottom)),
            child.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}
