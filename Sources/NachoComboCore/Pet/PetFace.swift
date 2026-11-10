import Foundation

/// Which Nacho picture the pet shows (art: nacho-app `assets/nacho/original`, all rights reserved — see
/// Resources/Nacho/LICENSE). Mapping decided by the owners: idle = idle, listening = calling, thinking = thinking,
/// answering = working, finished = happy, a long wait = tired, then eyes-closed. `waiting` is used while connecting.
public enum PetFace: String, CaseIterable, Equatable {
    case idle, listening, thinking, speaking, happy, waiting, tired, sleeping

    /// File name in Resources/Nacho (png).
    public var assetName: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "calling"
        case .thinking: return "thinking"
        case .speaking: return "working"
        case .happy: return "happy"
        case .waiting: return "waiting"
        case .tired: return "tired"
        case .sleeping: return "eyes-closed"
        }
    }

    public var koreanLabel: String {
        switch self {
        case .idle: return "대기"
        case .listening: return "듣는 중"
        case .thinking: return "생각 중"
        case .speaking: return "답변 중"
        case .happy: return "다 했어요"
        case .waiting: return "연결 중"
        case .tired: return "심심해요"
        case .sleeping: return "조는 중"
        }
    }

    public static let happyFor: TimeInterval = 4
    public static let tiredAfter: TimeInterval = 10 * 60
    public static let sleepAfter: TimeInterval = 30 * 60

    /// - Parameter lastInteraction: the last click, drop, message or answer.
    public static func derive(dictating: Bool, chat: ChatState, now: Date, lastInteraction: Date) -> PetFace {
        if dictating { return .listening }
        if let i = chat.activeTurnIndex {
            let t = chat.turns[i]
            if chat.activity == .typing || !t.assistantText.isEmpty { return .speaking }
            return .thinking
        }
        switch chat.activity {
        case .thinking, .tool, .retrying: return .thinking
        case .typing: return .speaking
        case .idle: break
        }
        if let done = chat.lastFinishedAt, now.timeIntervalSince(done) >= 0, now.timeIntervalSince(done) < happyFor {
            return .happy
        }
        switch chat.phase {
        case .connecting, .reconnecting: return .waiting
        default: break
        }
        let quiet = now.timeIntervalSince(lastInteraction)
        if quiet >= sleepAfter { return .sleeping }
        if quiet >= tiredAfter { return .tired }
        return .idle
    }
}
