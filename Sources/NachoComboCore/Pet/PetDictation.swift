import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).

/// Pure state for 받아쓰기 (macOS built-in speech recognition, ko-KR). The AppKit layer feeds recognizer callbacks in;
/// the transcript goes into the input field, the user presses send (dictation never sends by itself).
public struct DictationState: Equatable {
    public enum Phase: Equatable {
        case idle
        case requestingPermission
        case listening
        case denied(DictationDenial)
        case unavailable(String)  // Korean reason, e.g. no recognizer for ko-KR
    }

    public var phase: Phase = .idle
    /// Text already in the field when dictation started (kept as prefix).
    public private(set) var base: String = ""
    public private(set) var partial: String = ""

    public init() {}

    public var isListening: Bool { phase == .listening }
    public var text: String { DictationState.join(base, partial) }

    public mutating func start(existingText: String) {
        base = existingText
        partial = ""
        phase = .requestingPermission
    }
    public mutating func permissionGranted() { if phase == .requestingPermission { phase = .listening } }
    public mutating func permissionDenied(_ d: DictationDenial) { phase = .denied(d); partial = "" }
    public mutating func unavailable(_ reason: String) { phase = .unavailable(reason); partial = "" }

    /// Recognizer hypotheses replace the previous partial; a final result also ends the session.
    public mutating func hypothesis(_ t: String, isFinal: Bool) {
        guard phase == .listening else { return }
        partial = t
        if isFinal { stop() }
    }

    public mutating func stop() {
        if phase == .listening || phase == .requestingPermission {
            base = text
            partial = ""
            phase = .idle
        }
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let sep = a.hasSuffix(" ") || a.hasSuffix("\n") ? "" : " "
        return a + sep + b
    }
}

public enum DictationDenial: Equatable {
    case microphone, speech

    public var koreanMessage: String {
        switch self {
        case .microphone: return "마이크 권한이 꺼져 있어요. 시스템 설정 ▸ 개인정보 보호 ▸ 마이크에서 허용해 주세요."
        case .speech: return "음성 인식 권한이 꺼져 있어요. 시스템 설정 ▸ 개인정보 보호 ▸ 음성 인식에서 허용해 주세요."
        }
    }
}
