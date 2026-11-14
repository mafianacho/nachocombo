import AppKit
import AVFoundation
import NachoComboCore

// Nacho Pet: answering cards here (numbers, keys, sending, retry) and hold-to-talk with spoken replies.
// Rules: Core PetCardRules.swift and PetVoice.swift.

extension NachoPetModule {
    // MARK: cards

    /// A row of a card was clicked (or its number + Enter): an answer, or a tick on a multiple choice.
    func cardRow(_ id: String, number n: Int) {
        guard let card = state.chat.cards.first(where: { $0.id == id }), card.isPending else { return }
        let rows = PetCardRules.rows(card)
        guard n >= 1, n <= rows.count else { return }
        let row = rows[n - 1]
        if PetCardStyle.of(card) == .multiple, let o = row.optionID {
            toggleTick(id, option: o)
            return
        }
        if let a = row.answer { answer(card, a) }
    }

    func cardConfirm(_ id: String) {
        guard let card = state.chat.cards.first(where: { $0.id == id }),
              let a = PetCardRules.confirm(card, ticked: cardLocal[id]?.ticked ?? []) else { return }
        answer(card, a)
    }

    func cardRetry(_ id: String) {
        guard let card = state.chat.cards.first(where: { $0.id == id }), let a = cardLocal[id]?.lastAnswer else { return }
        answer(card, a)
    }

    private func toggleTick(_ id: String, option: String) {
        var l = cardLocal[id] ?? PetCardLocal()
        if let i = l.ticked.firstIndex(of: option) { l.ticked.remove(at: i) } else { l.ticked.append(option) }
        l.failure = nil
        cardLocal[id] = l
        chatWindow?.render()
    }

    /// Sends the answer once (no double click while it is on its way); a failure keeps it for 다시 시도. Choices that
    /// came from `ask_choice` and suggestions then send the chosen text as the user's next message.
    func answer(_ card: PetCard, _ a: PetCardAnswer) {
        var l = cardLocal[card.id] ?? PetCardLocal()
        guard l.sending == nil else { return }
        l.sending = a
        l.lastAnswer = a
        l.failure = nil
        l.highlighted = nil
        cardLocal[card.id] = l
        chatWindow?.render()
        session.answerCard(id: card.id, action: a.action, optionIDs: a.optionIDs, allowRuleID: a.allowRuleID) { [weak self] refusal in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var l = self.cardLocal[card.id] ?? PetCardLocal()
                l.sending = nil
                if let r = refusal {
                    l.failure = r
                    self.cardLocal[card.id] = l
                } else {
                    self.cardLocal[card.id] = nil
                    if let t = a.followUpText { self.sendWhenReady(t, voice: false) }
                }
                self.chatWindow?.render()
            }
        }
    }

    /// A number key, Enter or Esc while the input field is empty: handled for the newest card waiting here.
    /// Returns false when the key is not for a card.
    func cardKey(_ key: PetCardKey, cardID: String?) -> Bool {
        guard let id = cardID, let card = state.chat.cards.first(where: { $0.id == id }) else { return false }
        let local = cardLocal[id] ?? PetCardLocal()
        switch PetCardKeys.handle(key, card: card, local: local) {
        case .pass: return false
        case let .highlight(n):
            var l = local
            l.highlighted = n
            cardLocal[id] = l
        case let .toggle(o):
            toggleTick(id, option: o)
            return true
        case let .answer(a):
            answer(card, a)
            return true
        case .clear:
            var l = local
            l.highlighted = nil
            l.ticked = []
            cardLocal[id] = l
        }
        chatWindow?.render()
        return true
    }

    /// Undoes a number key that turned out to be the start of a message ("2시에…"): the mark or tick goes away.
    func cardKeyUndo(_ n: Int, cardID: String) {
        guard var l = cardLocal[cardID], let card = state.chat.cards.first(where: { $0.id == cardID }) else { return }
        if PetCardStyle.of(card) == .multiple {
            let rows = PetCardRules.rows(card)
            if n >= 1, n <= rows.count, let o = rows[n - 1].optionID, let i = l.ticked.firstIndex(of: o) { l.ticked.remove(at: i) }
        } else if l.highlighted == n {
            l.highlighted = nil
        }
        cardLocal[cardID] = l
        chatWindow?.render()
    }

    // MARK: hold the pet to talk

    /// Signed in: a long press records. Otherwise a long press stays a click.
    var canHoldToTalk: Bool { state.auth == .signedIn && !serverRecorder.isRecording && !dictationState.isListening }

    func holdDown(at t: Double, x: Double, y: Double) {
        voiceInputStarted()
        voice.gesture.down(at: t, x: x, y: y, talk: canHoldToTalk)
    }

    func holdTick(at t: Double) -> PetHoldGesture.Event {
        let e = voice.gesture.tick(at: t)
        if e == .startRecording { beginHoldRecording() }
        return e
    }

    func holdMove(at t: Double, x: Double, y: Double, insidePet: Bool) -> PetHoldGesture.Event {
        let e = voice.gesture.move(at: t, x: x, y: y, insidePet: insidePet)
        switch e {
        case .startRecording: beginHoldRecording()
        case .cancelRecording: cancelHoldRecording(PetVoiceText.canceled)
        default: break
        }
        return e
    }

    func holdUp(at t: Double) -> PetHoldGesture.Event {
        let e = voice.gesture.up(at: t)
        if case let .finishRecording(s) = e { finishHoldRecording(seconds: s) }
        return e
    }

    /// Esc while recording: thrown away.
    @discardableResult
    func holdEscape() -> Bool {
        guard voice.holdRecording || voice.gesture.isRecording else { return false }
        _ = voice.gesture.escape()
        cancelHoldRecording(PetVoiceText.canceled)
        return true
    }

    /// The ring is full: the microphone (asked for the first time here), the listening face, the chat opens.
    private func beginHoldRecording() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // The system asks now; the press ends here (the dialog takes the mouse). The next hold records.
            _ = voice.gesture.escape()
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.voiceNotice([PetTextPart("마이크를 쓸 수 있어요. 다시 나초를 길게 눌러 말해 주세요.")]) } else { self.micDenied() }
                }
            }
            return
        default:
            _ = voice.gesture.escape()
            micDenied()
            return
        }
        serverRecorder.cancel()
        dictation.stop()
        dictationState = DictationState()
        dictationState.start(existingText: "")
        dictationState.permissionGranted()
        voice.holdRecording = true
        voice.limitReached = false
        openChat(focusInput: true)
        let maxSec = state.config?.dictationMaxSec ?? PetClientConfig.fallback.dictationMaxSec
        serverRecorder.start(maxSec: maxSec, granted: { [weak self] ok in
            guard let self = self, !ok else { return }
            self.voice.holdRecording = false
            _ = self.voice.gesture.escape()
            self.dictationState.permissionDenied(.microphone)
            self.micDenied()
        }, finished: { [weak self] data, seconds in
            DispatchQueue.main.async { self?.holdAudioReady(data, seconds: seconds, maxSec: maxSec) }
        })
        refreshVoiceFace()
    }

    private func finishHoldRecording(seconds: Double) {
        guard voice.holdRecording else { return }  // stopped by itself at the limit, already sent
        if seconds < PetVoice.minimumSeconds { cancelHoldRecording(PetVoiceText.tooShort); return }
        serverRecorder.stop()  // hands the audio over (holdAudioReady)
    }

    func cancelHoldRecording(_ message: String) {
        guard voice.holdRecording else { return }
        voice.holdRecording = false
        serverRecorder.cancel()
        dictationState.stop()
        voiceNotice([PetTextPart(message)])
        refreshVoiceFace()
    }

    /// The recording ended (let go, or the server's length limit): server dictation, then the text is sent by itself.
    private func holdAudioReady(_ data: Data?, seconds: Double, maxSec: Int) {
        guard voice.holdRecording else { return }
        voice.holdRecording = false
        if voice.gesture.isRecording {
            // Still held: the limit stopped it. Sent as it is; letting go later does nothing.
            voice.limitReached = true
            _ = voice.gesture.escape()
        }
        dictationState.stop()
        refreshVoiceFace()
        guard let data = data, !data.isEmpty else { voiceNotice([PetTextPart(PetVoiceText.silence)]); return }
        session.dictate(audio: data, mime: "audio/mp4", fileName: "dictation.m4a", durationSec: min(seconds, Double(maxSec))) { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case let .success(text):
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { self.voiceNotice([PetTextPart(PetVoiceText.silence)]) } else { self.sendWhenReady(t, voice: true) }
                    if self.voice.limitReached, !t.isEmpty {
                        self.voiceNotice([PetTextPart("\(maxSec)초까지 들었어요. 거기까지 보냈어요.")])
                    }
                case let .failure(e):
                    let text = e.code == "refused" ? e.text : PetVoiceText.dictationFailure(code: e.code, reason: nil, maxSec: maxSec)
                    self.voiceNotice([PetTextPart(text)])
                }
                self.refreshVoiceFace()
            }
        }
    }

    /// Sends `text` as the user's message once the chat is connected and Nacho is free (about 30 seconds at most).
    /// When it still cannot go, the text waits in the input field so nothing said is lost.
    func sendWhenReady(_ text: String, voice spoken: Bool, attempt: Int = 0) {
        session.send(text: text, voice: spoken) { [weak self] refusal in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let r = refusal else { self.chatWindow?.render(); return }
                let retry = r == SendRefusal.notConnected.koreanMessage || r == SendRefusal.busy.koreanMessage
                if retry, attempt < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.sendWhenReady(text, voice: spoken, attempt: attempt + 1) }
                    return
                }
                self.openChat()
                self.chatWindow?.input.stringValue = text
                self.chatWindow?.flash(r)
            }
        }
    }

    // MARK: notices

    func micDenied() {
        voiceNotice([PetTextPart(PetVoiceText.micDenied), PetTextPart(" · ", style: .secondary),
                     PetTextPart(PetVoiceText.openSettings, link: PetLinks.url("micsettings"))])
    }

    func voiceNotice(_ parts: [PetTextPart]) {
        openChat(focusInput: false)
        chatWindow?.flash(parts: parts)
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }

    private func refreshVoiceFace() {
        petWindow?.show(face)
        chatWindow?.render()
    }

    // MARK: spoken replies

    /// New input (typing, sending, stop, a new hold): the voice stops and nothing pending is read.
    func voiceInputStarted() {
        voice.speaker.stop()
        voice.replies.silenceAll()
    }

    /// After every session change: the first sentence of a spoken turn's answer, once.
    func voiceSessionChanged() {
        for id in state.voiceTurns { voice.replies.began(id) }
        if let next = voice.replies.next(state.chat.turns, enabled: settings.speakVoiceReplies) {
            voice.speaker.speak(next.text)
        }
        if !settings.speakVoiceReplies { voice.speaker.stop() }
    }
}
