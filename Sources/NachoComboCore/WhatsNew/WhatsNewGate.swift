import Foundation

/// 업데이트 뒤 처음 실행에만 「새로운 기능」을 보여 줄지 판단한다. 버전 비교는 `SemanticVersion`(숫자 단위, 0.9.0 < 0.10.0).
public enum WhatsNewGate {
    /// 마지막으로 본 버전을 담는 UserDefaults 키 하나.
    public static let defaultsKey = "whatsNew.lastSeenVersion"

    public struct Outcome: Equatable {
        public let show: Bool
        /// nil이면 저장 값을 바꾸지 않는다.
        public let store: String?
    }

    /// - 저장 값 없음 + 신규 설치(`freshInstall`, 설정 파일이 없던 첫 실행): 보여 주지 않고 현재 버전을 저장한다(보스 지시는 "업데이트 후"다).
    /// - 저장 값 없음 + 기존 설치: 이 키가 생기기 전 버전(0.10.x 이하)에서 올라온 것이라 업데이트로 본다.
    /// - 저장 값을 읽을 수 없음: 보여 주지 않고 현재 버전을 저장한다.
    /// - 저장 < 현재(업데이트): 파일이 있으면 보여 주고, 어느 쪽이든 현재 버전을 저장한다.
    /// - 같은 버전·다운그레이드: 보여 주지 않고 저장 값은 그대로 둔다.
    /// - 현재 버전을 읽을 수 없으면 아무것도 하지 않는다.
    public static func decide(lastSeen: String?, current: String, hasContent: Bool, freshInstall: Bool = true) -> Outcome {
        guard let now = SemanticVersion(current) else { return Outcome(show: false, store: nil) }
        guard let raw = lastSeen else { return Outcome(show: hasContent && !freshInstall, store: now.description) }
        guard let seen = SemanticVersion(raw) else { return Outcome(show: false, store: now.description) }
        if seen < now { return Outcome(show: hasContent, store: now.description) }
        return Outcome(show: false, store: nil)
    }
}

/// 판단 결과를 UserDefaults에 적용한다.
public final class WhatsNewTracker {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 지금 보여 줄 내용이 있으면 돌려주고(그 전에 현재 버전을 저장한다), 없으면 nil.
    /// `freshInstall`: 이번 실행 전에 설정 파일이 없었는지(앱의 `firstLaunch`).
    public func evaluate(current: String, content: WhatsNewContent?, freshInstall: Bool = true) -> WhatsNewContent? {
        let usable = content.flatMap { SemanticVersion($0.version) == SemanticVersion(current) ? $0 : nil }
        let outcome = WhatsNewGate.decide(lastSeen: defaults.string(forKey: WhatsNewGate.defaultsKey), current: current,
                                          hasContent: usable != nil, freshInstall: freshInstall)
        if let value = outcome.store { defaults.set(value, forKey: WhatsNewGate.defaultsKey) }
        return outcome.show ? usable : nil
    }
}
