import AppKit
import NachoComboCore

// Nacho Pet's selection bar: when to look (watcher), the bar (panel), the preview and answers in the chat, the
// settings. The order of reading and the rules come from NachoComboCore (PetSelectionReader, PetSelectionFlow).
extension NachoPetModule: PetSelectionSending, PetSelectionSettingsHost {
    // MARK: session

    func sendSelection(_ sent: PetSelectionSent, completion: @escaping (String?) -> Void) {
        session.sendSelection(sent) { refusal in DispatchQueue.main.async { completion(refusal) } }
    }

    // MARK: settings host

    var selectionSettings: PetSelectionBarSettings { settings.selectionBar }

    func updateSelection(_ change: (inout PetSelectionBarSettings) -> Void) {
        update { change(&$0.selectionBar) }
    }

    var selectionAccessibilityGranted: Bool { PetSelectionAX.trusted }

    func selectionSwitchedOn() {
        if !PetSelectionAX.trusted { PetSelectionAX.requestTrust() }
        refreshSelectionWatcher()
    }

    // MARK: watcher

    func setUpSelectionBar() {
        selectionWatcher.settings = { [weak self] in self?.settings.selectionBar ?? PetSelectionBarSettings() }
        selectionWatcher.onCheck = { [weak self] in self?.checkSelection() }
        selectionWatcher.onOutsideActivity = { [weak self] in
            guard let self = self, self.selection.phase == .bar || self.selection.phase == .asking else { return }
            self.selection.dismiss()
        }
        selectionBar.onEscape = { [weak self] in self?.selection.dismiss() }
    }

    /// Watches only while the pet runs, the bar is on and Accessibility is allowed. While permission is still missing
    /// it checks every 2 s (no prompt) so the bar starts as soon as the user allows it.
    func refreshSelectionWatcher() {
        let wanted = isRunning && settings.selectionBar.enabled
        if wanted && PetSelectionAX.trusted {
            selectionTrustTimer?.invalidate()
            selectionTrustTimer = nil
            selectionWatcher.start()
            return
        }
        selectionWatcher.stop()
        if selection.phase == .bar || selection.phase == .asking { selection.dismiss() }
        if wanted {
            guard selectionTrustTimer == nil else { return }
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                guard let self = self, PetSelectionAX.trusted else { return }
                self.refreshSelectionWatcher()
                self.onChange?()
            }
            RunLoop.main.add(t, forMode: .common)
            selectionTrustTimer = t
        } else {
            selectionTrustTimer?.invalidate()
            selectionTrustTimer = nil
        }
    }

    /// After a selection ended: probe, read only if allowed, show the bar.
    func checkSelection() {
        guard selection.phase != .sending, let focus = PetSelectionAX.focus() else { return }
        var anchor: NSRect?
        let out = PetSelectionReader.read(focus.probe, settings: settings.selectionBar, now: Date()) {
            guard let read = PetSelectionAX.read(focus) else { return nil }
            anchor = read.1
            return read.0
        }
        guard let capture = out.capture else {
            if selection.phase == .bar || selection.phase == .asking { selection.dismiss() }
            return
        }
        selectionAnchor = anchor
        selection.present(capture)
    }

    // MARK: flow → screen

    func selectionChanged() {
        switch selection.phase {
        case .bar: showSelectionBar(ask: false)
        case .asking: showSelectionBar(ask: true)
        case .preview, .sending:
            selectionBar.hide()
            if chatWindow?.isVisible == true { chatWindow?.render() } else { openChat(focusInput: false) }
        case .idle:
            selectionBar.hide()
        }
        petWindow?.show(face)
        chatWindow?.render()
    }

    private func showSelectionBar(ask: Bool) {
        let view = PetSelectionBarView(mode: ask ? .ask : .buttons(compact: false), buttons: settings.selectionBar.visibleButtons,
                                       question: selection.question)
        view.onAction = { [weak self] a in
            guard let self = self else { return }
            self.selection.choose(a, settings: self.settings.selectionBar)
        }
        view.onMore = { [weak self] anchor in self?.showSelectionMenu(from: anchor) }
        view.onSubmit = { [weak self] q in if self?.selection.submitQuestion(q) == false { NSSound.beep() } }
        view.onEscape = { [weak self] in self?.selection.dismiss() }
        selectionBar.show(view, near: selectionAnchor, ask: ask)
    }

    /// ⋯: never in this app, snooze for an hour, settings.
    private func showSelectionMenu(from view: NSView) {
        let app = selection.context?.appName.isEmpty == false ? selection.context!.appName : "이 앱"
        let bundle = selection.context?.bundleID ?? ""
        let menu = NSMenu()
        let never = ClosureMenuItem(title: "\(app)에서는 띄우지 않기") { [weak self] in
            self?.updateSelection { $0.excludedApps.append(PetExcludedApp(bundleID: bundle, name: app)) }
            self?.selection.dismiss()
        }
        never.isEnabled = !bundle.isEmpty
        menu.autoenablesItems = false
        menu.addItem(never)
        menu.addItem(ClosureMenuItem(title: "잠시 끄기 (1시간)") { [weak self] in
            self?.updateSelection { $0.snoozedUntil = Date().addingTimeInterval(3600) }
            self?.selection.dismiss()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "선택 동작 바 설정…") { [weak self] in
            self?.selection.dismiss()
            self?.openSettings?()
        })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: chat

    var selectionChatState: PetSelectionChatState {
        PetSelectionChatState(preview: selection.preview, intro: settings.selectionBar.showsIntro, expanded: selectionExpanded)
    }

    /// nachopet://sel… links from the chat. False when the link is not the selection bar's.
    func selectionLink(_ host: String, _ q: [String: String]) -> Bool {
        switch host {
        case "selrm":
            if let f = q["f"].flatMap(PetSelectionField.init(rawValue:)) { selection.toggle(f) }
        case "selsend":
            selection.confirm { [weak self] refusal in if let r = refusal { self?.chatWindow?.flash(r) } }
        case "selcancel":
            selection.dismiss()
        case "selfull":
            showFullSelection()
        case "selcopy":
            if let id = q["turn"], let turn = state.chat.turns.first(where: { $0.clientMsgID == id }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.assistantText, forType: .string)
                chatWindow?.flash("답을 복사했어요.")
            }
        case "selagain":
            if let id = q["turn"], let sent = state.selectionTurns[id] {
                selection.again(sent) { [weak self] refusal in if let r = refusal { self?.chatWindow?.flash(r) } }
            }
        case "selshow":
            if let id = q["turn"] {
                if selectionExpanded.contains(id) { selectionExpanded.remove(id) } else { selectionExpanded.insert(id) }
                chatWindow?.render()
            }
        case "selintro":
            if q["a"] == "on" {
                updateSelection { $0.enabled = true; $0.introAnswered = true; $0.snoozedUntil = nil }
                selectionSwitchedOn()
            } else {
                updateSelection { $0.introAnswered = true }
            }
            chatWindow?.render()
        default:
            return false
        }
        return true
    }

    /// 전체 보기: the selected text as it will be sent (after the limit).
    private func showFullSelection() {
        guard let ctx = selection.context else { return }
        let alert = NSAlert()
        alert.messageText = "고른 글 · \(PetText.number(ctx.totalCount))자"
        alert.informativeText = ctx.truncated ? "너무 길어서 앞 \(PetText.number(PetSelectionLimits.selection))자만 보내요." : "보내기를 누르면 이 글이 함께 가요."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.string = ctx.selection
        text.font = PetTheme.body
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: "닫기")
        alert.runModal()
    }
}
