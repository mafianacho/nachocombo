import AppKit
import NachoComboCore

/// The chat bubble next to the pet: transcript, attachments, text/dictation input, send/stop, sign in, and the
/// connections view (what Nacho is connected to). Korean like Nacho; a key panel that does not activate the app, so the
/// window the user was working in stays the "front window" that Nacho arranges.
final class PetChatWindow: NSPanel, NSTextFieldDelegate {
    static let size = NSSize(width: 360, height: 480)
    private weak var module: NachoPetModule?

    private let header = NSTextField(labelWithString: "나초")
    private let status = NSTextField(labelWithString: "")
    private let tabs = NSSegmentedControl(labels: ["대화", "연결"], trackingMode: .selectOne, target: nil, action: nil)
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let pendingRow = NSStackView()
    private let input = NSTextField()
    private let micButton = NSButton()
    private let attachButton = NSButton()
    private let sendButton = NSButton(title: "보내기", target: nil, action: nil)
    private let signInButton = NSButton(title: "나초 계정으로 로그인", target: nil, action: nil)
    private let inputRow = NSStackView()
    private var flashText: String?
    private var flashUntil = Date.distantPast
    private var connectionsText: NSAttributedString?
    private var lastSignature = ""

    init(module: NachoPetModule) {
        self.module = module
        super.init(contentRect: NSRect(origin: .zero, size: PetChatWindow.size),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "나초"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setAccessibilityIdentifier("nacho-pet-chat")
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
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 30, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        contentView = content
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        let inner = PetChatWindow.size.width - 28

        header.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("nacho-pet-status")
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.controlSize = .small
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [header, status, spacer, tabs])
        top.spacing = 8
        top.widthAnchor.constraint(equalToConstant: inner).isActive = true

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 4, height: 6)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.setAccessibilityIdentifier("nacho-pet-transcript")
        scroll.documentView = transcript
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.6)
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: inner).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        notice.font = NSFont.systemFont(ofSize: 11)
        notice.textColor = .systemOrange
        notice.preferredMaxLayoutWidth = inner
        notice.widthAnchor.constraint(equalToConstant: inner).isActive = true
        notice.isHidden = true
        notice.setAccessibilityIdentifier("nacho-pet-notice")

        pendingRow.orientation = .horizontal
        pendingRow.spacing = 6
        pendingRow.isHidden = true

        input.placeholderString = "나초에게 말하기… (Return: 보내기)"
        input.delegate = self
        input.target = self
        input.action = #selector(sendClicked)
        input.lineBreakMode = .byTruncatingHead
        input.setAccessibilityIdentifier("nacho-pet-input")
        micButton.bezelStyle = .rounded
        micButton.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "받아쓰기")
        micButton.target = self
        micButton.action = #selector(micClicked)
        micButton.toolTip = "받아쓰기 (한국어). 다시 누르면 멈춰요."
        micButton.setAccessibilityIdentifier("nacho-pet-mic")
        attachButton.bezelStyle = .rounded
        attachButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "파일 주기")
        attachButton.target = self
        attachButton.action = #selector(attachClicked)
        attachButton.toolTip = "파일 주기 (그림, PDF, 글, mp4). 나초 위에 끌어다 놓아도 돼요."
        attachButton.setAccessibilityIdentifier("nacho-pet-attach")
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.setAccessibilityIdentifier("nacho-pet-send")
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputRow.setViews([attachButton, input, micButton, sendButton], in: .leading)
        inputRow.spacing = 6
        inputRow.widthAnchor.constraint(equalToConstant: inner).isActive = true

        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.target = self
        signInButton.action = #selector(signInClicked)
        signInButton.setAccessibilityIdentifier("nacho-pet-sign-in")

        for v in [top, scroll, notice, pendingRow, inputRow, signInButton] as [NSView] { root.addArrangedSubview(v) }
    }

    func focusInput() {
        if !inputRow.isHidden { makeFirstResponder(input) }
    }

    /// Above the pet (or below it at the top of the screen), kept on the pet's screen.
    func position(near pet: NSWindow?) {
        guard let pet = pet else { center(); return }
        let screen = (pet.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = frame.size
        var x = pet.frame.maxX - size.width
        var y = pet.frame.maxY + 8
        if y + size.height > screen.maxY { y = pet.frame.minY - size.height - 8 }
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        y = min(max(y, screen.minY + 8), screen.maxY - size.height - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// A short message under the transcript for a few seconds (refused file, nothing to send…).
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
        status.stringValue = statusLine(st)
        inputRow.isHidden = !signedIn
        signInButton.isHidden = signedIn
        switch st.auth {
        case .signingIn: signInButton.title = "브라우저에서 로그인하는 중…"; signInButton.isEnabled = false
        default: signInButton.title = "나초 계정으로 로그인"; signInButton.isEnabled = true
        }
        let busy = st.chat.isBusy
        sendButton.title = busy ? "멈추기" : "보내기"
        sendButton.setAccessibilityLabel(busy ? "답변 멈추기" : "보내기")
        sendButton.isEnabled = !st.uploading
        let listening = module.dictationState.isListening
        micButton.image = NSImage(systemSymbolName: listening ? "mic.fill" : "mic",
                                  accessibilityDescription: listening ? "받아쓰기 멈추기" : "받아쓰기")
        micButton.contentTintColor = listening ? .systemRed : nil

        var noticeText: String?
        if let f = flashText, Date() < flashUntil { noticeText = f }
        else if case let .denied(d) = module.dictationState.phase { noticeText = d.koreanMessage }
        else if case let .unavailable(m) = module.dictationState.phase { noticeText = m }
        else if st.uploading { noticeText = "파일 올리는 중…" }
        else if let n = st.chat.notice ?? st.notice { noticeText = n }
        notice.stringValue = noticeText ?? ""
        notice.isHidden = noticeText == nil

        renderPending(st.pending)
        if tabs.selectedSegment == 0 { renderTranscript(st, signedIn: signedIn) } else { renderConnections() }
    }

    private func statusLine(_ st: PetSessionState) -> String {
        switch st.auth {
        case .signedOut: return "로그인 전"
        case .signingIn: return "로그인 중"
        case let .failed(m): return m
        case .signedIn: break
        }
        var parts: [String] = []
        switch st.chat.phase {
        case .connected: parts.append(st.chat.isBusy ? activityText(st.chat) : "연결됨")
        case .connecting: parts.append("연결 중")
        case .reconnecting(let n): parts.append("다시 연결 중 (\(n))")
        case .authFailed: parts.append("다시 로그인해 주세요")
        case .disconnected: parts.append("쉬는 중")
        }
        if st.connector != .off { parts.append("콤보 조작 \(st.connector.koreanLabel)") }
        return parts.joined(separator: " · ")
    }

    private func activityText(_ chat: ChatState) -> String {
        switch chat.activity {
        case .thinking: return "생각 중"
        case .typing: return "답변 중"
        case .tool: return "도구 쓰는 중\(chat.activeTool.map { " (\($0))" } ?? "")"
        case .retrying: return "다시 시도 중"
        case .idle: return "답변 중"
        }
    }

    private func renderTranscript(_ st: PetSessionState, signedIn: Bool) {
        let signature = "\(st.chat.turns)|\(signedIn)|\(st.chat.agentName)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let small = NSFont.systemFont(ofSize: 11)
        func add(_ text: String, font: NSFont = body, color: NSColor = .labelColor, align: NSTextAlignment = .left) {
            let p = NSMutableParagraphStyle()
            p.alignment = align
            p.paragraphSpacing = 6
            out.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
        if !signedIn {
            add("안녕하세요, 나초예요.", font: NSFont.systemFont(ofSize: 13, weight: .semibold))
            add("나초 계정으로 로그인하면 여기서 대화할 수 있어요. 캡처나 선반의 파일을 건네거나, 창 배치와 가젯 켜기·끄기도 부탁할 수 있어요.",
                color: .secondaryLabelColor)
            add("로그인은 브라우저 창(auth.nachotown.com)에서 해요. 비밀번호는 콤보가 보지 않아요.", font: small, color: .tertiaryLabelColor)
        } else if st.chat.turns.isEmpty {
            add("무엇을 도와드릴까요?", font: NSFont.systemFont(ofSize: 13, weight: .semibold))
            add("예: \"창 왼쪽으로 붙여 줘\", \"킵 어웨이크 켜 줘\", 캡처 위에서 우클릭 ▸ 나초에게 묻기", font: small, color: .secondaryLabelColor)
        }
        for turn in st.chat.turns {
            var mine = turn.userText
            if !turn.attachmentNames.isEmpty { mine += (mine.isEmpty ? "" : "\n") + "📎 " + turn.attachmentNames.joined(separator: ", ") }
            add(mine, color: NSColor.controlAccentColor, align: .right)
            var answer = turn.assistantText
            switch turn.status {
            case .sending: if answer.isEmpty { answer = "…" }
            case .streaming: answer += " ▍"
            case .done: break
            case .stopped: answer += answer.isEmpty ? "(멈췄어요)" : " (멈춤)"
            case let .failed(m): answer += (answer.isEmpty ? "" : "\n") + "⚠︎ " + m
            case .interrupted: answer += (answer.isEmpty ? "" : "\n") + "⚠︎ 연결이 끊겨 답이 끝나지 않았어요."
            }
            add(answer)
        }
        transcript.textStorage?.setAttributedString(out)
        transcript.scrollToEndOfDocument(nil)
    }

    private func renderPending(_ pending: [PetPendingFile]) {
        pendingRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pendingRow.isHidden = pending.isEmpty
        for p in pending {
            let chip = NSButton(title: "📎 \(p.file.name)  ✕", target: self, action: #selector(removePendingClicked(_:)))
            chip.bezelStyle = .inline
            chip.controlSize = .small
            chip.tag = p.id
            chip.toolTip = "\(p.file.readability.koreanNote) — 누르면 빼요"
            chip.lineBreakMode = .byTruncatingMiddle
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
            pendingRow.addArrangedSubview(chip)
        }
    }

    private func renderConnections() {
        lastSignature = ""
        guard let text = connectionsText else {
            transcript.textStorage?.setAttributedString(NSAttributedString(string: "불러오는 중…",
                                                                           attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            return
        }
        transcript.textStorage?.setAttributedString(text)
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
        func line(_ s: String, bold: Bool = false, color: NSColor = .labelColor) {
            out.append(NSAttributedString(string: s + "\n", attributes: [
                .font: bold ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.systemFont(ofSize: 12), .foregroundColor: color]))
        }
        line("이 맥 (나초 콤보)", bold: true)
        line("  창 배치·가젯 켜기/끄기: \(connector.koreanLabel)", color: .secondaryLabelColor)
        switch result {
        case let .failure(e):
            line("")
            line(e.koreanMessage, color: .systemOrange)
        case let .success(o):
            line("")
            line("연결된 서비스", bold: true)
            if o.connections.isEmpty { line("  아직 없어요", color: .secondaryLabelColor) }
            for c in o.connections {
                line("  \(c.isHealthy ? "●" : "○") \(c.label) — \(c.statusText)\(c.accountLabel.map { " · \($0)" } ?? "")")
                if !c.scopeSummary.isEmpty { line("     \(c.scopeSummary)", color: .secondaryLabelColor) }
            }
            line("")
            line("나초가 쓸 수 있는 도구", bold: true)
            for t in o.tools { line("  \(t.enabled ? "●" : "○") \(t.name) · \(t.kindText)", color: t.enabled ? .labelColor : .secondaryLabelColor) }
            if !o.capabilities.isEmpty {
                line("")
                line("이 맥이 나초에게 준 기능", bold: true)
                for c in o.capabilities { line("  ● \(c.name)", color: .secondaryLabelColor) }
            }
        }
        return out
    }

    // MARK: actions

    @objc private func tabChanged() {
        if tabs.selectedSegment == 1 { loadConnections() } else { lastSignature = ""; render() }
    }

    @objc private func sendClicked() {
        guard let module = module else { return }
        if module.state.chat.isBusy { module.stopTurn(); return }
        let text = input.stringValue
        sendButton.isEnabled = false
        module.send(text) { [weak self] refusal in
            guard let self = self else { return }
            self.sendButton.isEnabled = true
            if let r = refusal { self.flash(r) } else { self.input.stringValue = "" }
            if self.tabs.selectedSegment != 0 { self.tabs.selectedSegment = 0; self.lastSignature = "" }
            self.render()
        }
    }

    @objc private func micClicked() {
        module?.toggleDictation(existingText: input.stringValue) { [weak self] text in self?.input.stringValue = text }
    }

    @objc private func attachClicked() { module?.pickFiles() }
    @objc private func signInClicked() { module?.signIn() }
    @objc private func removePendingClicked(_ sender: NSButton) { module?.removePending(sender.tag) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { module?.closeChat(); return true }
        return false
    }
}
