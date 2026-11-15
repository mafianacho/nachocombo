import AppKit
import NachoComboCore

/// 친구·공유 섹션(NACHO-274 U8: G1·G4·G5, 상대 프로필 F5). 연락처(G2)·전화 인증(G3)은 모바일 전용이라 없다.
/// 초대 링크는 클립보드에 복사만 한다(문자·메일 발송 없음). 모든 요청은 `hubSend`(실행기를 붙잡는다)로 보낸다.
final class FriendsSection: HubSectionBase {
    enum Screen: Equatable {
        case friends, requests, blocked, invite, sharing, add
        case profile(String)   // 상대 프로필(F5)
        case person(String)    // 사람별 당부(G5)
    }

    var screen: Screen = .friends
    private(set) var summary: HubSocialSummary?
    var invite: HubInviteInfo?
    var sharing: HubSharing?
    var lookupHit: HubPerson?
    /// 링크·코드 복사(시험은 가짜를 넣는다).
    var copyToClipboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    init() { super.init(id: .friends) }

    override func load() {
        guard ctx?.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        state.show(.loading)
        fetchSummary { [weak self] error in
            guard let self = self else { return }
            if let e = error { self.state.show(.failed(HubFriendsText.message(e))); return }
            self.screen = .friends
            self.render()
        }
    }

    // MARK: 데이터

    func fetchSummary(_ done: @escaping (PetAPIError?) -> Void) {
        let e = ctx.client!.endpoint
        hubSend({ HubFriendsAPI.summary(e, bearer: $0) }) { [weak self] result in
            switch result {
            case let .failure(err): done(err)
            case let .success(resp):
                switch HubAPI.object(resp) {
                case let .failure(err): done(err)
                case let .success(o):
                    guard let s = HubSocialSummary(o) else { done(.badResponse); return }
                    self?.summary = s
                    done(nil)
                }
            }
        }
    }

    /// 쓰기 요청 한 번. 실패하면 오류 토스트(`failure`가 있으면 그쪽), 성공하면 `then`. 409(낡은 버전)·404면 목록을 새로 받는다.
    func write(_ build: @escaping (String?) -> PetHTTPRequest, success: String?, then: @escaping (HubObject?) -> Void = { _ in },
               failure: ((PetAPIError) -> Void)? = nil) {
        let toast = ctx.toast
        hubSend(build) { [weak self] result in
            switch result {
            case let .failure(err):
                if let f = failure { f(err) } else { toast(HubFriendsText.message(err), true) }
                if err.isVersionConflict { self?.reloadAfterConflict() }
            case let .success(resp):
                if let s = success { toast(s, false) }
                then({ if case let .success(o) = HubAPI.object(resp) { return o }; return nil }())
            }
        }
    }

    func reloadAfterConflict() {
        fetchSummary { [weak self] _ in self?.render() }
    }

    /// 관계가 바뀌었으니 요약을 다시 받고, `screen`으로 간다.
    func refreshSummary(then next: Screen) {
        fetchSummary { [weak self] _ in self?.go(next) }
    }

    // MARK: 화면 전환

    func go(_ s: Screen) {
        screen = s
        render()
    }

    func render() {
        switch screen {
        case .friends: showFriends()
        case .requests: showRequests()
        case .blocked: showBlocked()
        case .invite: showInvite()
        case .sharing: showSharing()
        case .add: showAdd()
        case let .profile(id): showProfile(id)
        case let .person(id): showPerson(id)
        }
    }

    /// 위쪽 탭: 친구·받은 요청·차단·초대·공유.
    func tabs(_ current: Screen) -> NSView {
        let reqCount = summary?.requestsIn.count ?? 0
        let items: [(Screen, String)] = [(.friends, "친구"), (.requests, reqCount > 0 ? "받은 요청 \(reqCount)" : "받은 요청"), (.blocked, "차단"), (.invite, "초대"), (.sharing, "공유")]
        let pills: [NSView] = items.map { item in
            let (s, title) = item
            let tap: () -> Void = { [weak self] in self?.openTab(s) }
            return s == current ? HubKit.primaryButton(title, onClick: tap) : HubKit.secondaryButton(title, onClick: tap)
        }
        return PetFlow.rows(pills, maxWidth: 700, gap: Double(PetTokens.Space.s))
    }

    /// 탭을 누르면 그 탭의 데이터를 새로 받는다.
    func openTab(_ s: Screen) {
        switch s {
        case .invite, .sharing: go(s)
        default: refreshSummary(then: s)
        }
    }

    // MARK: 친구·받은 요청·차단 (G1)

    func showFriends() {
        let add = HubKit.primaryButton("친구 추가", symbol: "person.badge.plus") { [weak self] in self?.openAdd() }
        let page = HubScreen(title: "친구·공유", trailing: [add])
        page.add(tabs(.friends), full: false)
        let friends = summary?.friends ?? []
        if friends.isEmpty { page.note("아직 친구가 없어요. 사용자 ID로 친구를 찾아 보세요.") }
        for p in friends {
            let row = HubRow(title: p.displayName, subtitle: p.handleText, trailing: nil, symbol: "person.crop.circle")
            row.onClick = { [weak self] in self?.go(.profile(p.userID)) }
            row.setAccessibilityIdentifier("friend-row-\(p.userID)")
            page.add(row)
        }
        hubShow(page.view)
    }

    func showRequests() {
        let page = HubScreen(title: "친구·공유")
        page.add(tabs(.requests), full: false)
        let reqs = summary?.requestsIn ?? []
        if reqs.isEmpty { page.note("받은 친구 요청이 없어요.") }
        for p in reqs {
            let accept = HubKit.primaryButton("수락") { [weak self] in self?.answer(p, action: "accept", done: "\(p.displayName)님과 친구가 됐어요.") }
            let decline = HubKit.secondaryButton("거절") { [weak self] in self?.answer(p, action: "decline", done: "요청을 거절했어요.") }
            page.add(HubActionRow(title: p.displayName, subtitle: p.handleText, badge: p.unseen ? "새 요청" : nil, buttons: [decline, accept]))
        }
        hubShow(page.view)
    }

    func showBlocked() {
        let page = HubScreen(title: "친구·공유")
        page.add(tabs(.blocked), full: false)
        let list = summary?.blocked ?? []
        if list.isEmpty { page.note("차단한 사람이 없어요.") }
        for p in list {
            let unblock = HubKit.secondaryButton("차단 풀기") { [weak self] in self?.requestUnblock(p) }
            page.add(HubActionRow(title: p.displayName, subtitle: p.handleText, buttons: [unblock]))
        }
        hubShow(page.view)
    }

    /// 요청 수락·거절·취소 → 요약을 다시 받는다.
    func answer(_ p: HubPerson, action: String, done: String, next: Screen? = nil) {
        guard let e = ctx.client?.endpoint else { return }
        let back = next ?? screen
        write({ HubFriendsAPI.answerRequest(e, bearer: $0, userID: p.userID, action: action) }, success: done, then: { [weak self] _ in self?.refreshSummary(then: back) })
    }

    func sendRequest(_ p: HubPerson, next: Screen) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubFriendsAPI.sendRequest(e, bearer: $0, userID: p.userID) }, success: "친구 요청을 보냈어요.", then: { [weak self] _ in self?.refreshSummary(then: next) })
    }

    // 되돌릴 수 없는 동작(삭제·차단·해제)은 확인창을 두 번 거친다.

    func requestRemoveFriend(_ p: HubPerson) {
        guard let e = ctx.client?.endpoint else { return }
        let steps = [
            HubConfirmStep(title: "\(p.displayName)님을 친구에서 지울까요?", message: "상대에게 알리지 않아요. 이 친구에게 적어 둔 당부도 함께 지워져요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "다시 친구가 되려면 요청을 새로 보내야 해요.", confirmTitle: "지우기"),
        ]
        ctx.confirm(steps) { [weak self] in
            self?.write({ HubFriendsAPI.removeFriend(e, bearer: $0, userID: p.userID) }, success: "친구에서 지웠어요.", then: { _ in self?.refreshSummary(then: .friends) })
        }
    }

    func requestBlock(_ p: HubPerson) {
        guard let e = ctx.client?.endpoint else { return }
        let steps = [
            HubConfirmStep(title: "\(p.displayName)님을 차단할까요?", message: "친구와 대기 중인 요청이 정리되고, 상대에게 알리지 않아요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 차단할까요?", message: "차단한 사람과는 서로 찾을 수도 요청을 보낼 수도 없어요.", confirmTitle: "차단"),
        ]
        ctx.confirm(steps) { [weak self] in
            self?.write({ HubFriendsAPI.block(e, bearer: $0, userID: p.userID) }, success: "차단했어요.", then: { _ in self?.refreshSummary(then: .friends) })
        }
    }

    func requestUnblock(_ p: HubPerson) {
        guard let e = ctx.client?.endpoint else { return }
        let steps = [
            HubConfirmStep(title: "\(p.displayName)님의 차단을 풀까요?", message: "풀어도 친구로 돌아가지는 않아요.", confirmTitle: "계속", destructive: false),
            HubConfirmStep(title: "정말 풀까요?", message: "다시 서로 찾고 요청을 보낼 수 있어요.", confirmTitle: "풀기", destructive: false),
        ]
        ctx.confirm(steps) { [weak self] in
            self?.write({ HubFriendsAPI.unblock(e, bearer: $0, userID: p.userID) }, success: "차단을 풀었어요.", then: { _ in self?.refreshSummary(then: .blocked) })
        }
    }
}
