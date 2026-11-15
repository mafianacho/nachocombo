import Foundation

/// 나초 앱 창(허브)의 기능 스위치. 값은 코드 상수다(원격 설정 없음). 다음 이슈들이 이 파일을 고치지 않도록
/// 처음부터 모두 선언해 두었다. 켜려면 PR에서 상수를 바꾸고 코드카포가 확인한다.
public enum HubFeatureFlags {
    /// 계정 삭제(되돌릴 수 없음). 기본 꺼짐.
    public static let accountDelete = false
    /// 기억 전체 삭제(되돌릴 수 없음). 기본 꺼짐.
    public static let memoryDeleteAll = false
    /// 예약을 지금 실행. 기본 켜짐.
    public static let scheduleRunNow = true
    /// 사진으로 나초 만들기. 기본 켜짐.
    public static let agentPhotoCreate = true
}

/// 허브 사이드바 섹션. id와 순서는 고정이다(다음 stage 이슈가 섹션 자리 파일 이름으로 쓴다).
public enum HubSectionID: String, CaseIterable, Equatable {
    case account, notifications, rooms, groups, tasks, schedules, memory, nachos, friends, trust, usage, explore, archive

    public var title: String {
        switch self {
        case .account: return "계정·설정"
        case .notifications: return "알림·활동"
        case .rooms: return "대화"
        case .groups: return "그룹·요청"
        case .tasks: return "작업"
        case .schedules: return "예약"
        case .memory: return "기억"
        case .nachos: return "나초"
        case .friends: return "친구·공유"
        case .trust: return "연결 보안"
        case .usage: return "사용량·요금제"
        case .explore: return "탐색"
        case .archive: return "보관함"
        }
    }

    /// SF Symbols 이름.
    public var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .notifications: return "bell"
        case .rooms: return "bubble.left.and.bubble.right"
        case .groups: return "person.3"
        case .tasks: return "checklist"
        case .schedules: return "clock"
        case .memory: return "brain"
        case .nachos: return "pawprint"
        case .friends: return "person.2"
        case .trust: return "lock.shield"
        case .usage: return "creditcard"
        case .explore: return "safari"
        case .archive: return "archivebox"
        }
    }
}
