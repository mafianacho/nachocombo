import AppKit
import NachoComboCore

/// The chat bubble next to the pet, ported from the confirmed web mockup (design/web, `.chat`): header with the one
/// status line, optional banner, the log (PetTranscript items, one view each), pending files, and the composer.
/// A borderless key panel that does not activate the app, so the window the user was working in stays the "front
/// window" that Nacho arranges. Its tail points at the pet, and it follows the pet when the pet is dragged.
/// The user can drag its free edges (left, the side away from the pet, their corner) to resize it; everything inside
/// follows the window's width (PetChatLayout has the rules).
final class PetChatWindow: NSPanel, NSTextFieldDelegate {
    private typealias S = PetTokens.Size
    private typealias Sp = PetTokens.Space
    private weak var module: NachoPetModule?
    /// The size the user chose (or the default). Shown clamped to the pet's screen.
    private(set) var bodySize: PetChatSize
    /// The width the log, banner and sign-in texts are laid out for.
    private var laidOutWidth = CGFloat(S.chatWidth)
    private var handles: [PetChatResizeHandle] = []
    private var resizeStart: (size: PetChatSize, limit: PetChatSize)?

    private let background = PetChatBackground()
    private let content = NSView()
    // header (`.chat-head`)
    private let avatar = NSImageView()
    private let name = NSTextField(labelWithString: "나초")
    /// Back to the Nacho's own room; shown only while a room from the hub is open.
    private var roomBack: PetPill!
    private var roomHeader: PetTranscript.RoomHeader?
    /// Erasing a message of mine: which one and which of the two questions is on screen (nil = none).
    /// The room is the one the question was asked in: a room switch drops the question (seqs repeat across rooms).
    private var redactAsk: (room: String?, seq: Int, step: Int)?
    private let dot = PetBox()
    let status = NSTextField(labelWithString: "")
    private var tabButtons: [PetPill] = []
    private var selectedTab = 0
    // banner, log, pending, composer
    private let banner = PetBox()
    private let bannerText = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let logStack = NSStackView()
    private let pendingRow = NSStackView()
    private let composer = NSStackView()
    private let fieldBox = PetFieldBox()
    /// Internal (not private) so the off-screen capture tests can show typed text.
    let input = PetInputField()
    private let wave = PetWave()
    private var attachButton: PetPill!
    private var micButton: PetPill!
    private var sendButton: PetPill!
    private let signInView = NSStackView()
    private var signInButton: PetPill!
    private let signInNote = NSTextField(wrappingLabelWithString: "")

    private var flashText: String?
    private var flashParts: [PetTextPart]?
    private var flashUntil = Date.distantPast
    /// The newest card waiting for an answer here (number keys, Enter and Esc go to it while the input is empty).
    private(set) var activeCardID: String?
    /// A number key that marked a card row; if more text follows, it was the start of a message and goes back in.
    private var heldDigit: (n: Int, card: String)?
    private var connectionsView: PetConnectionsView?
    private var shownItems: [PetChatItem] = []
    private var shownViews: [NSView] = []
    private var tickScheduled = false

    private var logWidth: CGFloat { laidOutWidth - CGFloat(2 * Sp.m) }

    /// `size` defaults to the one saved in the settings (nil there = the design's default).
    init(module: NachoPetModule?, size: PetChatSize? = nil) {
        self.module = module
        let body = PetChatLayout.clamp(size ?? module?.settings.chatSize, screen: nil)
        bodySize = body
        laidOutWidth = CGFloat(body.width)
        let window = PetChatLayout.windowSize(body)
        super.init(contentRect: NSRect(x: 0, y: 0, width: window.width, height: window.height), styleMask: [.borderless, .nonactivatingPanel],
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
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel("나초와 대화")
        build()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { escapePressed() }

    /// Esc: cancels a recording, then clears a card's mark or ticks, then closes the chat.
    private func escapePressed() {
        guard let module = module else { return }
        if module.holdEscape() { return }
        if input.stringValue.isEmpty, module.cardKey(.escape, cardID: activeCardID) { heldDigit = nil; return }
        module.closeChat()
    }

    override func close() {
        module?.dictation.stop()
        super.close()
    }

    // MARK: layout

    private func build() {
        background.frame = NSRect(origin: .zero, size: frame.size)
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

        // Every row is as wide as the window, so they all grow and shrink with it.
        for row in [buildHeader(), buildBanner(), buildLog(), buildSignIn(), buildPending(), buildComposer()] {
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        for edge in PetChatEdge.allCases {
            let h = PetChatResizeHandle(edge: edge)
            h.onBegin = { [weak self] in self?.beginResize() }
            h.onDrag = { [weak self] e, dx, dy in self?.resize(edge: e, dx: dx, dy: dy) }
            h.onEnd = { [weak self] in self?.endResize() }
            background.addSubview(h)
            handles.append(h)
        }
        layoutHandles()
    }

    private var contentTop: NSLayoutConstraint!
    private var contentBottom: NSLayoutConstraint!

    private func buildHeader() -> NSView {
        let head = PetBox()
        head.translatesAutoresizingMaskIntoConstraints = false
        head.heightAnchor.constraint(equalToConstant: CGFloat(S.headerHeight)).isActive = true
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
        // Extra width goes to the name/status column; the tabs keep their own size at the right. (Stack views take
        // `setHuggingPriority`, not the content hugging of views with an intrinsic size.)
        who.setHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)

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

        segRow.setHuggingPriority(.required, for: .horizontal)
        roomBack = PetPill(symbol: "chevron.left", iconSize: S.lineIcon, color: PetTheme.secondary, fill: PetTheme.color(\.surface),
                           height: S.control - 6, radius: PetTokens.Radius.control - 2, width: S.control - 6)
        roomBack.onClick = { [weak self] in self?.module?.returnToDefaultRoom() }
        roomBack.isHidden = true
        let row = NSStackView(views: [roomBack, avatar, who, seg])
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
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor), doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            // Short logs sit at the bottom, next to the composer (`justify-content: flex-end`).
            logStack.topAnchor.constraint(greaterThanOrEqualTo: doc.topAnchor, constant: CGFloat(Sp.m)),
            logStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -CGFloat(Sp.m)),
            logStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: CGFloat(Sp.m)),
            logStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -CGFloat(Sp.m)),
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
        signInButton = PetPill(title: "나초 계정으로 로그인", symbol: "person", iconSize: 15, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold),
                               color: PetTheme.color(\.onAccent), fill: PetTheme.accent, height: S.control + 4, padding: Sp.l)
        signInButton.onClick = { [weak self] in self?.module?.signIn() }
        signInButton.setAccessibilityIdentifier("nacho-pet-sign-in")
        fillSignIn()
        signInView.isHidden = true
        signInView.setContentHuggingPriority(.defaultLow, for: .vertical)
        return signInView
    }

    /// The sign-in texts wrap at the window's width, so they are made again when it changes.
    private func fillSignIn() {
        signInView.arrangedSubviews.forEach { signInView.removeArrangedSubview($0); $0.removeFromSuperview() }
        let art = NSImageView(image: PetArt.image(named: "happy") ?? NSImage())
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: CGFloat(S.signinArt)).isActive = true
        art.heightAnchor.constraint(equalToConstant: CGFloat(S.signinArt)).isActive = true
        let inner = laidOutWidth - CGFloat(2 * Sp.xl)
        let hi = PetLinkText(PetLinkText.plain("안녕하세요, 나초예요.", font: PetTheme.title, color: PetTheme.text, align: .center), maxWidth: inner)
        let p = PetLinkText(PetLinkText.plain("나초 계정으로 로그인하면 여기서 대화할 수 있어요. 캡처나 선반의 파일을 건네거나, 창 배치나 가젯을 켜고 끄는 일도 부탁할 수 있어요.",
                                              font: PetTheme.body, color: PetTheme.secondary, align: .center), maxWidth: inner)
        let small = PetLinkText(PetLinkText.plain("로그인은 브라우저 창(auth.mafianacho.com)에서 해요. 비밀번호는 콤보가 보지 않아요.",
                                                  font: PetTheme.caption, color: PetTheme.tertiary, align: .center), maxWidth: inner)
        for v in [art, hi, p, signInButton!, small] as [NSView] { signInView.addArrangedSubview(v) }
    }

    private func buildPending() -> NSView {
        pendingRow.orientation = .horizontal
        pendingRow.spacing = CGFloat(Sp.s)
        pendingRow.distribution = .fillEqually
        pendingRow.translatesAutoresizingMaskIntoConstraints = false
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
        fieldBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return composer
    }

    func focusInput() {
        if !composer.isHidden { makeFirstResponder(input) }
    }

    /// Above the pet with the tail on its head (or below it at the top of the screen), kept on the pet's screen.
    /// Called when the chat opens, on every drag event of the pet, when it is dropped, and while resizing. Only the
    /// frame changes: the typed text, the focus and a streaming answer stay as they are.
    func position(near pet: NSWindow?) {
        guard let pet = pet else {
            let body = PetChatLayout.clamp(bodySize, screen: nil)
            apply(body: body, origin: frame.origin)
            center()
            return
        }
        let screen = (pet.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        place(petFrame: pet.frame, screen: screen)
    }

    /// The same rule for a pet frame and a screen's visible frame (also used by the off-screen capture tests).
    func place(petFrame: NSRect, screen: NSRect) {
        let screenRect = PetRect(screen)
        let body = PetChatLayout.clamp(bodySize, screen: screenRect)
        let at = PetChatLayout.place(body: body, pet: PetRect(petFrame), screen: screenRect)
        background.tailOnTop = at.tailOnTop
        background.tailFromRight = CGFloat(at.tailFromRight)
        contentTop.constant = at.tailOnTop ? PetChatBackground.tail : 0
        contentBottom.constant = at.tailOnTop ? 0 : -PetChatBackground.tail
        apply(body: PetChatSize(width: body.width, height: at.bodyHeight), origin: NSPoint(x: at.x, y: at.y))
    }

    private func apply(body: PetChatSize, origin: NSPoint) {
        let size = PetChatLayout.windowSize(body)
        let rect = NSRect(x: origin.x, y: origin.y, width: CGFloat(size.width), height: CGFloat(size.height))
        // Fixed-width rows are rebuilt before the window narrows and after it widens, so they always fit the log.
        let width = CGFloat(body.width)
        if width < laidOutWidth { widthChanged(width) }
        if rect != frame { setFrame(rect, display: true) }
        if width > laidOutWidth { widthChanged(width) }
        layoutHandles()
        invalidateShadow()
    }

    /// Lays out what is built for a fixed width again (log items, banner, sign-in texts).
    private func widthChanged(_ width: CGFloat) {
        guard abs(width - laidOutWidth) >= 0.5 else { return }
        laidOutWidth = width
        bannerText.preferredMaxLayoutWidth = logWidth - CGFloat(2 * Sp.m + S.sendIcon + Sp.s)
        fillSignIn()
        let items = shownItems
        shownItems = []
        shownViews.forEach { logStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        shownViews = []
        if selectedTab == 0 { show(items: items) }
        render()
    }

    // MARK: resizing

    /// The size the user chose; the window keeps following the pet with it.
    func setBodySize(_ size: PetChatSize?) {
        bodySize = PetChatLayout.clamp(size, screen: nil)
        position(near: module?.petWindow)
    }

    /// The drag handles on the free edges (not the tail side, not the right edge lined up with the pet).
    private func layoutHandles() {
        let body = background.bodyRect
        let t: CGFloat = 6, c = CGFloat(PetTokens.Radius.window)
        let free = Set(PetChatLayout.resizableEdges(tailOnTop: background.tailOnTop))
        for h in handles {
            h.isHidden = !free.contains(h.edge)
            switch h.edge {
            case .left: h.frame = NSRect(x: body.minX, y: body.minY + c, width: t, height: max(0, body.height - 2 * c))
            case .top: h.frame = NSRect(x: body.minX + c, y: body.maxY - t, width: max(0, body.width - 2 * c), height: t)
            case .bottom: h.frame = NSRect(x: body.minX + c, y: body.minY, width: max(0, body.width - 2 * c), height: t)
            case .topLeft: h.frame = NSRect(x: body.minX, y: body.maxY - c, width: c, height: c)
            case .bottomLeft: h.frame = NSRect(x: body.minX, y: body.minY, width: c, height: c)
            }
        }
        invalidateCursorRects(for: background)
    }

    private var petAndScreen: (pet: PetRect, screen: PetRect)? {
        guard let pet = module?.petWindow else { return nil }
        let screen = (pet.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return (PetRect(pet.frame), PetRect(screen))
    }

    private func beginResize() {
        let shown = PetChatSize(width: Double(frame.width), height: Double(frame.height) - PetTokens.Size.chatTail)
        let limit = petAndScreen.map { PetChatLayout.dragLimit(pet: $0.pet, screen: $0.screen, tailOnTop: background.tailOnTop) }
            ?? PetChatLayout.maximumSize(screen: PetRect((screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)))
        resizeStart = (shown, limit)
    }

    private func resize(edge: PetChatEdge, dx: CGFloat, dy: CGFloat) {
        guard let start = resizeStart else { return }
        let next = PetChatLayout.resized(start.size, edge: edge, dx: Double(dx), dy: Double(dy), limit: start.limit)
        guard next != bodySize else { return }
        bodySize = next
        if let pet = module?.petWindow { position(near: pet) } else { apply(body: next, origin: frame.origin) }
    }

    private func endResize() {
        guard resizeStart != nil else { return }
        resizeStart = nil
        module?.chatResized(to: bodySize)
    }

    /// A short message at the end of the log for a few seconds (refused file, nothing to send…).
    func flash(_ text: String) {
        flashText = text
        flashParts = nil
        flashUntil = Date().addingTimeInterval(6)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) { [weak self] in self?.render() }
    }

    /// The same with links ("설정 열기"), kept a little longer so the link can be clicked.
    func flash(parts: [PetTextPart]) {
        flashText = parts.map { $0.text }.joined()
        flashParts = parts
        flashUntil = Date().addingTimeInterval(10)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.1) { [weak self] in self?.render() }
    }

    // MARK: rendering

    /// The waiting text that could not be sent, already moved back into the input (so one render does it once).
    private var takenBackText: String?

    func render() {
        guard let module = module else { return }
        let st = module.state
        if let back = st.returnedText {
            if takenBackText != back {
                takenBackText = back
                let typed = input.stringValue
                input.stringValue = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? back : back + "\n" + typed
                module.clearReturned()
                flash("대기하던 글을 보내지 못했어요. 입력창에 돌려놨어요.")
                return
            }
        } else { takenBackText = nil }
        let signedIn = st.auth == .signedIn
        let selection = module.selectionChatState
        let head = PetTranscript.headerStatus(st, selection: selection)
        applyRoomHeader(PetTranscript.roomHeader(st.chat))
        status.stringValue = (roomHeader.map { $0.subtitle + " · " } ?? "") + PetTranscript.headerLine(st, selection: selection)
        status.toolTip = status.stringValue  // a truncated line can be read in full
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
        applySendButton(busy: busy, hasText: hasText)
        sendButton.isEnabled = !st.uploading
        micButton.set(symbol: listening ? "mic.fill" : "mic", color: listening ? PetTheme.color(\.onDanger) : PetTheme.secondary,
                      fill: .some(listening ? PetTheme.color(\.danger) : nil))
        micButton.toolTip = listening ? "다 말하면 다시 누르세요" : "받아쓰기 (한국어)"
        micButton.setAccessibilityLabel(listening ? "받아쓰기 멈추기" : "받아쓰기")
        wave.isHidden = !listening
        input.placeholderAttributedString = NSAttributedString(string: listening ? "듣고 있어요" : PetTranscript.inputPlaceholder(st.chat),
                                                               attributes: [.font: PetTheme.body, .foregroundColor: listening ? PetTheme.color(\.danger) : PetTheme.tertiary])
        renderPending(st.pending)
        if selectedTab == 0 { renderLog(st) } else { renderConnections() }
    }

    /// The header while a room from the hub is open: its name, a way back, and a room icon in place of the Nacho's face.
    /// Internal so the off-screen capture tests can show it without a server.
    func applyRoomHeader(_ h: PetTranscript.RoomHeader?) {
        guard h != roomHeader || roomBack.isHidden == (h != nil) else { return }
        roomHeader = h
        name.stringValue = h?.title ?? "나초"
        name.toolTip = h?.title
        roomBack.isHidden = h == nil
        roomBack.toolTip = h.map { "\($0.backLabel)로 돌아가기" }
        roomBack.setAccessibilityLabel(h.map { "\($0.backLabel)로 돌아가기" } ?? "")
        if h != nil {
            avatar.image = PetTheme.symbol("person.2.fill", size: S.avatar * 0.5, weight: .medium)
            avatar.contentTintColor = PetTheme.accent
            avatar.imageScaling = .scaleNone
        } else {
            avatar.image = PetArt.image(named: "idle")
            avatar.contentTintColor = nil
            avatar.imageScaling = .scaleProportionallyUpOrDown
        }
    }

    /// The round button: stop while Nacho answers and nothing is typed, else send (typed text waits for the answer's end).
    func applySendButton(busy: Bool, hasText: Bool) {
        if busy, !hasText {
            sendButton.set(symbol: "stop.fill", color: PetTheme.color(\.window), fill: .some(PetTheme.text))
            sendButton.setAccessibilityLabel("답변 멈추기"); sendButton.toolTip = "멈추기"
        } else {
            sendButton.set(symbol: "arrow.up", color: hasText ? PetTheme.color(\.onAccent) : PetTheme.tertiary,
                           fill: .some(hasText ? PetTheme.accent : PetTheme.color(\.surface)))
            sendButton.setAccessibilityLabel("보내기"); sendButton.toolTip = busy ? "보내기 (답이 끝나면 보내요)" : "보내기"
        }
    }

    /// Notices that are not part of a turn: flash, dictation problems, uploads, the session's last error.
    private func noticeLine(_ st: PetSessionState) -> PetChatItem? {
        guard let module = module else { return nil }
        var text: String?
        if let parts = flashParts, Date() < flashUntil {
            return .line(PetChatLine(kind: .notice, symbol: "info.circle", parts: parts))
        }
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
        var items = PetTranscript.items(st, undoSecondsLeft: { [weak self] id in self?.undoSecondsLeft(id, st) },
                                        selection: module?.selectionChatState ?? PetSelectionChatState(),
                                        cards: module?.cardLocal ?? [:], redactable: true)
        activeCardID = PetTranscript.activeCardID(items)
        if let ask = redactAsk {
            // The message must still be there to ask about (a room switch or a reload may have taken it away).
            if ask.room == st.chat.roomID, items.contains(.redactable(seq: ask.seq)) { items.append(.line(PetTranscript.redactConfirm(step: ask.step))) } else { redactAsk = nil }
        }
        if let n = noticeLine(st) { items.append(n) }
        guard show(items: items) else { return }
        // The undo countdown ("7초 안에 되돌리기") ticks every second while it lasts.
        if st.chat.memoryNotes.contains(where: { undoSecondsLeft($0.updateID, st) != nil }), !tickScheduled {
            tickScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tickScheduled = false; self?.render() }
        }
    }

    /// Lays the log out for these items at the current width and scrolls to the end; false when nothing changed.
    /// Internal so the off-screen capture tests can show a conversation without a server.
    @discardableResult
    func show(items: [PetChatItem]) -> Bool {
        guard items != shownItems else { return false }
        // Keep the views of the unchanged beginning (streaming only changes the end).
        var keep = 0
        while keep < min(items.count, shownItems.count), items[keep] == shownItems[keep] { keep += 1 }
        for v in shownViews[keep...] { logStack.removeArrangedSubview(v); v.removeFromSuperview() }
        shownViews.removeSubrange(keep...)
        var maker = PetItemViews(width: logWidth, onLink: { [weak self] in self?.open($0) },
                                 onExample: { [weak self] in self?.input.stringValue = $0; self?.focusInput(); self?.render() },
                                 onRedact: { [weak self] seq in self?.askRedact(seq) })
        // The seq a `.redactable` mark announces belongs to the bubble right after it.
        if keep > 0, case let .redactable(seq) = items[keep - 1] { maker.redactSeq = seq }
        for item in items[keep...] {
            let v = maker.view(item)
            if case let .redactable(seq) = item { maker.redactSeq = seq } else { maker.redactSeq = nil }
            logStack.addArrangedSubview(v)
            shownViews.append(v)
        }
        shownItems = items
        logStack.layoutSubtreeIfNeeded()
        if let doc = scroll.documentView {
            doc.layoutSubtreeIfNeeded()
            doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - scroll.contentView.bounds.height)))
        }
        return true
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
        case "cancelqueued": module?.cancelQueued()
        case "forget": if let u = q["u"] { module?.forgetMemory(u) }
        case "undo": if let u = q["u"] { module?.undoForget(u) }
        case "memfb": if let t = q["turn"] { module?.askMemoryFeedback(turnID: t) }
        case "card": if let id = q["id"], let a = q["action"] { module?.answerCard(id, action: a, options: q["option"].map { [$0] } ?? []) }
        case "task": if let id = q["id"], let a = q["action"] { module?.taskAction(id, action: a) }
        case "cardrow": if let id = q["id"], let n = q["n"].flatMap(Int.init) { module?.cardRow(id, number: n) }
        case "cardconfirm": if let id = q["id"] { module?.cardConfirm(id) }
        case "cardretry": if let id = q["id"] { module?.cardRetry(id) }
        case "micsettings": module?.openMicrophoneSettings()
        case "redactnext": if let a = redactAsk { redactAsk = (a.room, a.seq, 2); render() }
        case "redactcancel": redactAsk = nil; render()
        case "redactgo": redactNow()
        default: _ = module?.selectionLink(url.host ?? "", q)
        }
    }

    // MARK: erasing a message of mine (two questions, then the server call)

    func askRedact(_ seq: Int) {
        redactAsk = (module?.state.chat.roomID, seq, 1)
        render()
    }

    private func redactNow() {
        guard let ask = redactAsk else { return }
        redactAsk = nil
        module?.redactMessage(seq: ask.seq, roomID: ask.room) { [weak self] refusal in
            self?.flash(refusal ?? "메시지를 지웠어요.")
            self?.render()
        }
        render()
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
        guard let module = module else { return }
        shownItems = []
        let view: PetConnectionsView
        if let v = connectionsView, abs(v.contentWidth - logWidth) < 1 { view = v } else {
            if let old = connectionsView {  // the chat was resized: draw the tab again at the new width
                old.close()
                logStack.removeArrangedSubview(old)
                old.removeFromSuperview()
            }
            view = PetConnectionsView(host: module, width: logWidth)
            connectionsView = view
        }
        if view.superview !== logStack {
            shownViews.forEach { logStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            logStack.addArrangedSubview(view)
            shownViews = [view]
            view.open()
        }
    }

    // MARK: actions

    private func select(tab i: Int) {
        selectedTab = i
        styleTabs()
        if i != 1 { connectionsView?.close() }
        shownItems = []
        shownViews.forEach { logStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        shownViews = []
        render()
    }

    private func styleTabs() {
        for (i, b) in tabButtons.enumerated() {
            b.set(color: i == selectedTab ? PetTheme.text : PetTheme.secondary, fill: .some(i == selectedTab ? PetTheme.color(\.accentSoft) : nil))
        }
    }

    @objc private func returnPressed() { sendClicked(fromReturn: true) }

    private func sendClicked(fromReturn: Bool = false) {
        guard let module = module else { return }
        let text = input.stringValue
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !module.state.pending.isEmpty
        if module.state.chat.isBusy {
            // Stopping is the stop button (empty field) and Esc; Enter with text never stops the answer.
            if !hasText { if !fromReturn { module.stopTurn() }; return }
            sendButton.isEnabled = false
            module.queueSend(text) { [weak self] refusal in
                guard let self = self else { return }
                self.sendButton.isEnabled = true
                if let r = refusal { self.flash(r) } else { self.input.stringValue = "" }
                if self.selectedTab != 0 { self.select(tab: 0) }
                self.render()
            }
            return
        }
        sendButton.isEnabled = false
        module.send(text) { [weak self] refusal in
            guard let self = self else { return }
            self.sendButton.isEnabled = true
            if let r = refusal { self.flash(r) } else { self.input.stringValue = "" }
            if self.selectedTab != 0 { self.select(tab: 0) }
            self.render()
        }
    }

    private func micClicked() {
        module?.toggleDictation(existingText: input.stringValue) { [weak self] text in self?.input.stringValue = text; self?.render() }
        render()
    }

    func controlTextDidChange(_ obj: Notification) {
        module?.voiceInputStarted()
        cardDigit()
        render()
    }

    /// A single number typed into the empty field marks (or ticks) that row of the newest waiting card instead. When
    /// more text follows, the number was the start of a message: it goes back in front and the mark goes away.
    private func cardDigit() {
        guard let module = module else { return }
        let text = input.stringValue
        if let held = heldDigit {
            heldDigit = nil
            if text.isEmpty { return }
            if text.count == 1, let n = Int(text), n >= 1, module.cardKey(.digit(n), cardID: activeCardID) {
                // Another number: another row (one choice) or one more tick (several).
                heldDigit = (n, held.card)
                input.stringValue = ""
                return
            }
            module.cardKeyUndo(held.n, cardID: held.card)
            input.stringValue = "\(held.n)" + text
            input.currentEditor()?.selectedRange = NSRange(location: (input.stringValue as NSString).length, length: 0)
            return
        }
        guard text.count == 1, let n = Int(text), n >= 1, let card = activeCardID, module.cardKey(.digit(n), cardID: card) else { return }
        heldDigit = (n, card)
        input.stringValue = ""
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { escapePressed(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), input.stringValue.isEmpty,
           module?.cardKey(.enter, cardID: activeCardID) == true {
            heldDigit = nil
            return true
        }
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

/// A view with token insets around one child, full chat width (`margin: var(--space-s) var(--space-m) 0`). The
/// row's width comes from the chat window; the child fills it less the side margins.
final class PetRowInset: NSView {
    init(_ child: NSView, top: Double = 0, bottom: Double = 0) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(top)),
            child.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(bottom)),
            child.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(PetTokens.Space.m)),
            child.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(PetTokens.Space.m)),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A thin invisible strip on a free edge (or corner) of the chat; dragging it resizes the chat.
final class PetChatResizeHandle: NSView {
    let edge: PetChatEdge
    var onBegin: (() -> Void)?
    var onDrag: ((PetChatEdge, CGFloat, CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var start: NSPoint?

    init(edge: PetChatEdge) {
        self.edge = edge
        super.init(frame: .zero)
        setAccessibilityElement(false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor {
        switch edge {
        case .left: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomLeft:
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) {
                return NSCursor.frameResize(position: edge == .topLeft ? .topLeft : .bottomLeft, directions: .all)
            }
            #endif
            return .crosshair
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let m = NSEvent.mouseLocation
        onDrag?(edge, m.x - s.x, m.y - s.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        onEnd?()
    }
}

extension PetRect {
    init(_ r: NSRect) { self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height)) }
}
