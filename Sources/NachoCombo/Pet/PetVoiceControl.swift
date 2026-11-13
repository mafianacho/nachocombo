import AppKit
import AVFoundation
import NachoComboCore

/// Hold-to-talk and spoken replies for Nacho Pet (rules in Core PetVoice.swift). The recording itself is the
/// existing `PetServerRecorder` (m4a for `POST /api/v1/dictation`); this keeps what one press needs and the voice.
final class PetVoiceController: NSObject {
    var gesture = PetHoldGesture()
    var replies = PetVoiceReplies()
    /// The recorder is running for a hold (not for the composer's mic button).
    var holdRecording = false
    /// The recorder stopped by itself at the server's limit while the pet was still held.
    var limitReached = false
    let speaker = PetSpeaker()
    var ringTimer: Timer?

    func stopRing() {
        ringTimer?.invalidate()
        ringTimer = nil
    }
}

/// Reads one sentence with the Mac's built-in Korean voice (AVSpeechSynthesizer). Never a paid TTS; nothing is sent.
final class PetSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private(set) var lastSpoken: String?
    var isSpeaking: Bool { synth.isSpeaking }

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        lastSpoken = text
        synth.speak(u)
    }

    /// New input or stop: quiet at once.
    func stop() {
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }
}

/// The ring over the pet: fills over `PetVoice.holdSeconds` while the pet is held, then shows the sound level while
/// recording (red). Drawn in the pet's own view, under nothing else.
final class PetHoldRing: CALayer {
    private let track = CAShapeLayer()
    private let fillRing = CAShapeLayer()
    private let level = CAShapeLayer()

    override init() {
        super.init()
        for l in [track, fillRing, level] {
            l.fillColor = NSColor.clear.cgColor
            l.lineCap = .round
            addSublayer(l)
        }
        isHidden = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not used") }

    func layout(in bounds: CGRect) {
        frame = bounds
        let inset = CGFloat(PetTokens.Space.xs) + 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // Starts at the top and runs clockwise (AppKit layers are y-up).
        let path = CGMutablePath()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(center: c, radius: rect.width / 2, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        for l in [track, fillRing, level] { l.frame = bounds; l.path = path }
        track.lineWidth = 4
        fillRing.lineWidth = 4
        level.lineWidth = 6
    }

    /// 0…1 while held; nil = hidden.
    func show(progress: Double?, recordingLevel: Double?, appearance: NSAppearance?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let draw = { [self] in
            track.strokeColor = PetTheme.color(\.separator).cgColor
            fillRing.strokeColor = PetTheme.accent.cgColor
            level.strokeColor = PetTheme.color(\.danger).cgColor
        }
        if let a = appearance { a.performAsCurrentDrawingAppearance(draw) } else { draw() }
        if let p = progress {
            isHidden = false
            track.isHidden = false
            fillRing.isHidden = false
            level.isHidden = true
            fillRing.strokeEnd = CGFloat(max(0, min(1, p)))
        } else if let lv = recordingLevel {
            isHidden = false
            track.isHidden = true
            fillRing.isHidden = true
            level.isHidden = false
            level.strokeEnd = 1
            level.lineWidth = 3 + CGFloat(max(0, min(1, lv))) * 7
            level.opacity = Float(0.55 + 0.45 * max(0, min(1, lv)))
        } else {
            isHidden = true
        }
        CATransaction.commit()
    }
}
