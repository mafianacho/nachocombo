import Foundation

// 길게 눌러 말하기 (나초파더 1570802313768083457): press the pet and keep still → a ring fills over about 2 seconds →
// recording (listening face, sound level) → let go → server dictation (`POST /api/v1/dictation`) → sent as a message
// by itself, shown as the user's bubble. Let go before the ring is full = the old click (open/close the chat); move
// more than 3 px = the old drag. Esc or dragging out of the pet while recording = cancel. Then Nacho's answer to a
// spoken turn: its first sentence is read with the Mac's built-in voice (AVSpeechSynthesizer, Korean), never a paid TTS.

public enum PetVoice {
    /// How long the pet is held before recording starts (the one setting for it).
    public static let holdSeconds: Double = 2.0
    /// Movement that turns a press into the old drag.
    public static let dragSlop: Double = 3
    /// Shorter recordings are not sent (a tap that slipped past the ring).
    public static let minimumSeconds: Double = 0.5
}

/// The pet's press: click, drag, or hold-to-talk. Times in seconds, positions in screen points.
public struct PetHoldGesture: Equatable {
    public enum Phase: Equatable {
        case idle
        /// Pressed and still: the ring fills while `talk` is allowed.
        case pressing(start: Double, x: Double, y: Double, talk: Bool)
        case dragging
        case recording(since: Double)
    }

    public enum Event: Equatable {
        case none
        /// The ring is full: start recording.
        case startRecording
        /// Let go before the ring was full: the old click.
        case click
        /// Moved more than 3 px: the old drag (the window follows from now on).
        case dragStarted
        case dragEnded
        /// Let go while recording: hand the audio to the server.
        case finishRecording(seconds: Double)
        /// Esc, or dragged out of the pet while recording: throw the audio away.
        case cancelRecording
    }

    public private(set) var phase: Phase = .idle
    public let holdSeconds: Double

    public init(holdSeconds: Double = PetVoice.holdSeconds) { self.holdSeconds = holdSeconds }

    /// `talk`: hold-to-talk is possible now (signed in). Without it a long press is still a click.
    public mutating func down(at t: Double, x: Double, y: Double, talk: Bool) {
        phase = .pressing(start: t, x: x, y: y, talk: talk)
    }

    /// 0…1 while the ring fills (0 when it does not).
    public func progress(at t: Double) -> Double {
        guard case let .pressing(start, _, _, talk) = phase, talk, holdSeconds > 0 else { return 0 }
        return min(1, max(0, (t - start) / holdSeconds))
    }

    public var isRecording: Bool { if case .recording = phase { return true }; return false }
    public var isFilling: Bool { if case let .pressing(_, _, _, talk) = phase { return talk }; return false }

    /// Called on a timer while pressing: the ring is full → recording.
    public mutating func tick(at t: Double) -> Event {
        guard case let .pressing(start, _, _, talk) = phase, talk, t - start >= holdSeconds else { return .none }
        phase = .recording(since: t)
        return .startRecording
    }

    /// The mouse moved (screen points). `insidePet`: still over the pet.
    public mutating func move(at t: Double, x: Double, y: Double, insidePet: Bool) -> Event {
        switch phase {
        case let .pressing(_, x0, y0, _):
            // A press that already reached the ring's end is recording; the timer may lag a little behind the clock.
            if tick(at: t) == .startRecording { return insidePet ? .startRecording : cancelNow() }
            guard abs(x - x0) >= PetVoice.dragSlop || abs(y - y0) >= PetVoice.dragSlop else { return .none }
            phase = .dragging
            return .dragStarted
        case .recording:
            return insidePet ? .none : cancelNow()
        case .idle, .dragging:
            return .none
        }
    }

    public mutating func up(at t: Double) -> Event {
        let was = phase
        phase = .idle
        switch was {
        case let .pressing(start, _, _, talk):
            // Let go just as the ring filled (its timer had not fired yet): nothing was recorded and it was no click.
            if talk, t - start >= holdSeconds { return .none }
            return .click
        case .dragging:
            return .dragEnded
        case let .recording(since):
            return .finishRecording(seconds: max(0, t - since))
        case .idle:
            return .none
        }
    }

    /// Esc while recording (or while the ring fills).
    public mutating func escape() -> Event {
        switch phase {
        case .recording: return cancelNow()
        case .pressing: phase = .idle; return .none
        default: return .none
        }
    }

    private mutating func cancelNow() -> Event {
        phase = .idle
        return .cancelRecording
    }
}

/// Korean messages for the voice path (server error codes from docs/error-codes.md, spec/dictation.tsp).
public enum PetVoiceText {
    public static let tooShort = "너무 짧았어요. 나초를 누른 채로 말하고, 다 말하면 손을 떼 주세요."
    public static let silence = "말소리가 들리지 않았어요. 다시 길게 눌러 말해 주세요."
    public static let canceled = "녹음을 취소했어요."
    public static let micDenied = "마이크 권한이 꺼져 있어 들을 수 없어요. 시스템 설정 ▸ 개인정보 보호 및 보안 ▸ 마이크에서 Nacho Combo를 켜 주세요."
    public static let openSettings = "설정 열기"
    public static let unavailable = "이 서버는 받아쓰기를 지원하지 않아요."

    /// A dictation failure (code from the server's error body) in Korean.
    public static func dictationFailure(code: String?, reason: String?, maxSec: Int) -> String {
        switch code {
        case "payload_too_large": return "말이 너무 길어요. \(maxSec)초 안으로 말해 주세요."
        case "invalid_input": return "녹음을 받지 못했어요. \(maxSec)초 안으로 다시 말해 주세요."
        case "too_many_requests":
            return "잠시 뒤에 다시 말해 주세요." + (reason.flatMap(ErrorText.retryAt).map { " (\($0)부터 돼요)" } ?? "")
        case "not_implemented", "refused_disabled": return unavailable
        case "unsupported_media_type": return ErrorText.userMessage(code: "unsupported_media_type", reason: nil, fallback: "")
        case "upstream_error": return "받아쓰기 서버가 답하지 않았어요. 잠시 뒤 다시 말해 주세요."
        case "unauthorized": return "로그인이 필요해요."
        default: return "받아 적지 못했어요. 다시 말해 주세요."
        }
    }
}

/// Which turns were started by voice and which of their answers were read aloud.
public struct PetVoiceReplies: Equatable {
    public private(set) var voiceTurns: Set<String> = []
    public private(set) var spoken: Set<String> = []

    public init() {}

    /// The user spoke this turn (its client message id).
    public mutating func began(_ turnID: String) { voiceTurns.insert(turnID) }

    /// New input, stop, or the setting turned off: nothing pending is read any more.
    public mutating func silenceAll() { spoken.formUnion(voiceTurns) }

    /// The next sentence to read: the first sentence of a spoken turn's answer, once it is complete (or the answer
    /// finished), once per turn. Typed turns are never read.
    public mutating func next(_ turns: [ChatTurn], enabled: Bool) -> (turnID: String, text: String)? {
        guard enabled else { silenceAll(); return nil }
        for t in turns where voiceTurns.contains(t.clientMsgID) && !spoken.contains(t.clientMsgID) {
            switch t.status {
            case .failed, .stopped, .interrupted:
                spoken.insert(t.clientMsgID)
                continue
            case .sending, .streaming, .done:
                break
            }
            guard let s = PetSpeech.firstSentence(t.assistantText, final: t.status == .done) else {
                if t.status == .done { spoken.insert(t.clientMsgID) }  // nothing to read (a card, a task)
                continue
            }
            spoken.insert(t.clientMsgID)
            return (t.clientMsgID, s)
        }
        return nil
    }
}

public enum PetSpeech {
    /// The first sentence of `text` for reading aloud, or nil while it is not complete yet (`final` = the answer
    /// ended). Markdown marks, links and emoji are left out; a very long sentence is cut at a pause.
    public static func firstSentence(_ text: String, final: Bool, maxChars: Int = 140) -> String? {
        let clean = speakable(text)
        guard !clean.isEmpty else { return nil }
        let enders: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]
        var out = ""
        var ended = false
        let it = Array(clean)
        var i = 0
        while i < it.count {
            let ch = it[i]
            if ch == "\n" { ended = !out.trimmingCharacters(in: .whitespaces).isEmpty; if ended { break } else { i += 1; continue } }
            out.append(ch)
            if enders.contains(ch) {
                // "1.5" or "3.14" is not an end; an end is followed by a space, a line break or the end of the text.
                let nextIsSpace = i + 1 >= it.count ? final : (it[i + 1] == " " || it[i + 1] == "\n" || it[i + 1] == "\"" || it[i + 1] == "”")
                if nextIsSpace {
                    // Keep closing marks: "요." "요!" "?" followed by a quote.
                    while i + 1 < it.count, enders.contains(it[i + 1]) && it[i + 1] != "\n" { i += 1; out.append(it[i]) }
                    ended = true
                    break
                }
            }
            i += 1
        }
        if !ended && !final { return nil }
        var s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > maxChars {
            let cut = s.prefix(maxChars)
            if let pause = cut.lastIndex(where: { $0 == "," || $0 == " " }), cut.distance(from: cut.startIndex, to: pause) > maxChars / 2 {
                s = String(cut[..<pause])
            } else {
                s = String(cut)
            }
        }
        return s.isEmpty ? nil : s
    }

    /// Text without markdown marks, links and symbols that a voice would read out literally.
    static func speakable(_ text: String) -> String {
        var s = text
        // [label](url) → label; bare URLs out.
        if let re = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        }
        if let re = try? NSRegularExpression(pattern: #"https?://\S+"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while let f = l.first, "#>-*".contains(f) { l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces) }
            return l
        }
        s = lines.joined(separator: "\n")
        s = String(s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) })
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
