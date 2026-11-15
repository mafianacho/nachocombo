import AppKit
import NachoComboCore

/// 섹션이 쓰는 것들. 창이 만들어 `activate`로 넘긴다.
struct HubContext {
    /// 로그인이 되어 있고 서버 주소가 있을 때만 있다.
    var client: HubClient?
    /// 아래쪽 토스트(오류면 isError).
    var toast: (String, Bool) -> Void
    /// 되돌릴 수 없는 동작: 단계마다 확인창을 한 번씩 거친 뒤에만 `onConfirmed`가 불린다.
    var confirm: ([HubConfirmStep], @escaping () -> Void) -> Void
}

/// 섹션의 공통 바탕. 섹션 이슈는 자기 `<Id>Section.swift`의 `load()`만 채운다.
/// 규칙은 docs/HUB.md. 콜백은 임의의 큐에서 오니 화면은 `onMain`으로 바꾼다.
class HubSectionBase: NSObject {
    let id: HubSectionID
    /// 이 섹션의 뿌리 뷰(불러오는 중·빈 상태·오류·내용을 바꿔 보여 준다).
    let state = HubStateView()
    private(set) var ctx: HubContext!

    init(id: HubSectionID) {
        self.id = id
        super.init()
        state.onRetry = { [weak self] in self?.load() }
    }

    var view: NSView { state }

    /// 섹션이 보일 때마다 불린다.
    func activate(_ ctx: HubContext) {
        self.ctx = ctx
        load()
    }

    /// 서버에서 불러와 `state.show`로 그린다. 처음 오기·다시 시도·`reload()`에서 불린다.
    func load() { showPlaceholder() }

    func reload() { load() }

    func showPlaceholder() { state.show(.empty("준비 중이에요.")) }

    func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}

/// 사이드바 순서대로 한 줄씩 등록한다(id는 `HubSectionID`). 새 섹션은 여기 한 줄 + 자리 파일 하나.
enum HubSections {
    static let factories: [(HubSectionID, () -> HubSectionBase)] = [
        (.account, { AccountSection() }),
        (.notifications, { NotificationsSection() }),
        (.rooms, { RoomsSection() }),
        (.groups, { GroupsSection() }),
        (.tasks, { TasksSection() }),
        (.schedules, { SchedulesSection() }),
        (.memory, { MemorySection() }),
        (.nachos, { NachosSection() }),
        (.friends, { FriendsSection() }),
        (.trust, { TrustSection() }),
        (.usage, { UsageSection() }),
        (.explore, { ExploreSection() }),
        (.archive, { ArchiveSection() }),
    ]

    static func make(_ id: HubSectionID) -> HubSectionBase {
        factories.first { $0.0 == id }!.1()
    }
}
