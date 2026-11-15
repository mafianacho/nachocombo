import AppKit
import NachoComboCore

/// 나초 섹션(NACHO-274 U8: F2·F3·F4·F5): 목록·만들기·프로필·목소리·특성·사진·한도·대표·휴식·삭제·복구.
/// 화면은 `NachosSection+*.swift`에 나뉘어 있고, 이 파일은 상태와 요청을 맡는다.
/// 모든 요청은 `hubSend`(실행기를 붙잡는다)로 보내 사용자가 다른 섹션으로 옮겨도 결과가 버려지지 않는다.
final class NachosSection: HubSectionBase {
    enum Screen: Equatable {
        case list, create, detail(String), edit(String), voices(String), traits(String), photos(String), limits(String)
    }

    var screen: Screen = .list
    private(set) var list: HubAgentList?
    var templates: [HubAgentTemplate] = []
    /// 사진 화면이 마지막으로 받은 값(확인창에 오늘 남은 장수를 보여 줄 때 쓴다).
    var photos: HubPhotos?
    let voicePlayer = HubVoicePlayer()
    /// 만들기 화면을 열 때마다 새로 만든다(같은 키로 다시 보내면 서버가 첫 응답을 돌려준다).
    var createKey = HubAPI.newIdempotencyKey()

    init() { super.init(id: .nachos) }

    override func load() {
        guard ctx?.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        voicePlayer.stop()
        state.show(.loading)
        fetchList { [weak self] error in
            guard let self = self else { return }
            if let e = error { self.state.show(.failed(HubNachosText.message(e))); return }
            self.screen = .list
            self.render()
        }
    }

    // MARK: 데이터

    /// `GET /agents`. 성공하면 `list`가 바뀌고 `nil`, 실패하면 오류.
    func fetchList(_ done: @escaping (PetAPIError?) -> Void) {
        let e = ctx.client!.endpoint
        hubSend({ HubNachosAPI.list(e, bearer: $0) }) { [weak self] result in
            switch result {
            case let .failure(err): done(err)
            case let .success(resp):
                switch HubAPI.object(resp) {
                case let .failure(err): done(err)
                case let .success(o):
                    guard let l = HubAgentList(o) else { done(.badResponse); return }
                    self?.list = l
                    done(nil)
                }
            }
        }
    }

    func agent(_ id: String) -> HubAgent? { list?.agents.first { $0.id == id } }

    /// 서버가 준 나초(또는 `{agent:…}`)로 목록 안의 같은 나초를 바꾼다. 대표가 바뀌면 나머지의 대표 표시를 내린다.
    func apply(_ o: HubObject) {
        guard var l = list, let a = HubAgent(o.obj("agent") ?? o) else { return }
        if let i = l.agents.firstIndex(where: { $0.id == a.id }) { l.agents[i] = a } else { l.agents.append(a) }
        if a.isDefault { for i in l.agents.indices where l.agents[i].id != a.id { l.agents[i].isDefault = false } }
        list = l
    }

    /// 쓰기 요청 한 번. 실패하면 오류 토스트(409 `version_conflict`면 새로 불러온다), 성공하면 `then`.
    func write(_ build: @escaping (String?) -> PetHTTPRequest, success: String?, then: @escaping (HubObject?) -> Void = { _ in },
               failure: ((PetAPIError) -> Void)? = nil) {
        let toast = ctx.toast
        hubSend(build) { [weak self] result in
            switch result {
            case let .failure(err):
                if let f = failure { f(err) } else { toast(HubNachosText.message(err), true) }
                if err.isVersionConflict || err.isNotFound { self?.refreshAfterConflict() }
            case let .success(resp):
                let obj: HubObject? = { if case let .success(o) = HubAPI.object(resp) { return o }; return nil }()
                if let o = obj { self?.apply(o) }
                if let s = success { toast(s, false) }
                then(obj)
            }
        }
    }

    /// 낡은 버전이거나 사라진 나초: 목록을 새로 받아 지금 화면을 다시 그린다.
    func refreshAfterConflict() {
        fetchList { [weak self] error in
            guard let self = self, error == nil else { return }
            if case let .detail(id) = self.screen, self.agent(id) == nil { self.screen = .list }
            self.render()
        }
    }

    // MARK: 화면 전환

    func go(_ s: Screen) {
        voicePlayer.stop()
        screen = s
        render()
    }

    func render() {
        switch screen {
        case .list: showList()
        case .create: showCreate()
        case let .detail(id): showDetail(id)
        case let .edit(id): showEdit(id)
        case let .voices(id): showVoices(id)
        case let .traits(id): showTraits(id)
        case let .photos(id): showPhotos(id)
        case let .limits(id): showLimits(id)
        }
    }

    // MARK: 목록

    func showList() {
        let l = list ?? HubAgentList(HubObject(["agents": [Any]()]))!
        let canCreate = l.canCreate
        let create = HubKit.primaryButton("새 나초 만들기", symbol: "plus") { [weak self] in self?.openCreate() }
        create.isEnabled = canCreate
        let page = HubScreen(title: "나초", trailing: [create])
        if !canCreate { page.note("만들 수 있는 나초 수에 닿았어요. (\(l.used)/\(l.maxAgents))") }
        else if l.maxAgents > 0 { page.note("\(l.used)/\(l.maxAgents)마리와 함께하고 있어요.") }
        if l.agents.isEmpty { page.note("아직 나초가 없어요. 새 나초를 만들어 보세요.") }
        for a in l.agents {
            let row = HubRow(title: a.name + (a.isDefault ? "  · 대표" : ""),
                             subtitle: [a.statusLabel, a.speech.label, a.roleNote].filter { !$0.isEmpty }.joined(separator: " · "),
                             trailing: a.unread > 0 ? "안 읽음 \(a.unread)" : nil, symbol: a.isDefault ? "star.fill" : "pawprint")
            row.onClick = { [weak self] in self?.go(.detail(a.id)) }
            row.setAccessibilityIdentifier("nacho-row-\(a.id)")
            page.add(row)
        }
        hubShow(page.view)
    }
}
