import AppKit
import NachoComboCore

/// 그룹·요청(NACHO-270 U4, B17·B18): 나초 그룹방 만들기·설정·삭제, 사람 단톡방 초대, 받은 초대 수락·거절, 모르는 사람의 대화 요청 수락·거절·보내기.
/// 그룹방에서 실제로 대화하는 것은 U10(다음 stage)이고, 방 열기(`HubRooms.openInChat`)는 U3가 들어온 뒤 연결한다(지금은 만들기·관리·초대까지).
/// 외부 발송(문자·공유)은 없다. 초대는 서버의 앱 내 초대만 쓴다. 쓰기 결과(토스트·목록 갱신)는 사용자가 다른 섹션으로 옮겨도 남도록
/// 요청 클라이언트와 섹션을 강하게 잡는다(섹션은 창이 계속 들고 있다).
final class GroupsSection: HubSectionBase {
    init() { super.init(id: .groups) }

    /// `HubClient`는 내부에서 `[weak self]`라서 우리가 들고 있어야 결과가 버려지지 않는다.
    var held: HubClient?
    var groups: [HubGroupRoom] = []
    var invitations: [HubInvitation] = []
    var invitationsNext: [(String, String)]?
    var requests: [HubIncomingRequest] = []
    var requestsNext: [(String, String)]?
    var homeNote: String?
    /// 같은 화면을 다시 눌러도 방이 둘 생기지 않게 화면마다 한 번만 만든다.
    var createKey = HubAPI.newIdempotencyKey()
    var inviteKey = HubAPI.newIdempotencyKey()
    var requestKey = HubAPI.newIdempotencyKey()

    override func load() { showHome() }

    // MARK: 공통

    /// 요청 한 번. 로그인이 안 되어 있으면 안내만 띄운다. 완료는 항상 메인에서 불린다.
    func call(_ build: @escaping (ServerEndpoint, String?) -> PetHTTPRequest, _ done: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        guard let client = ctx.client ?? held else { state.show(.failed("로그인이 필요해요.")); return }
        held = client
        let e = client.endpoint
        client.send({ build(e, $0) }) { r in self.onMain { done(r) } }
    }

    /// 화면 하나를 내용 자리에 붙인다.
    func present(_ v: NSView) {
        let host = state.contentHost
        for s in host.subviews { s.removeFromSuperview() }
        HubKit.pin(v, in: host)
        state.show(.content)
    }

    /// 제목 + (뒤로) 가 있는 스크롤 화면. `build`가 스택에 내용을 쌓는다.
    func page(_ title: String, back: Bool, _ build: (NSStackView) -> Void) -> NSView {
        let parts = HubKit.scrollingStack()
        let stack = parts.stack
        if back {
            stack.addArrangedSubview(HubKit.secondaryButton("목록으로", symbol: "chevron.left") { [weak self] in self?.showHome() })
        }
        let t = HubKit.label(title, font: PetTheme.title)
        stack.addArrangedSubview(t)
        HubKit.fill(stack, [t])
        build(stack)
        return parts.scroll
    }

    func errorLabel() -> NSTextField {
        let l = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.danger))
        l.isHidden = true
        return l
    }

    func setError(_ l: NSTextField, _ text: String?) {
        l.stringValue = text ?? ""
        l.isHidden = text == nil
    }

    /// 제목 + 보조 글 + 단추가 든 카드.
    func card(title: String, lines: [String], buttons: [NSView] = []) -> NSView {
        let box = PetBox(frame: .zero)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.fill = PetTheme.color(\.surface)
        box.stroke = PetTheme.color(\.edge)
        box.radius = CGFloat(PetTokens.Radius.card)
        var views: [NSView] = [HubKit.label(title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium))]
        for l in lines where !l.isEmpty { views.append(HubKit.label(l, font: PetTheme.caption, color: PetTheme.secondary)) }
        if !buttons.isEmpty { views.append(HubKit.hstack(buttons)) }
        let v = HubKit.vstack(views, spacing: PetTokens.Space.xs)
        box.addSubview(v)
        let p = CGFloat(PetTokens.Space.m)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: p),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -p),
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: p),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -p),
        ])
        HubKit.fill(v, [views[0]])
        return box
    }

    func sectionLabel(_ text: String) -> NSTextField {
        HubKit.label(text, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium), color: PetTheme.secondary)
    }

    /// 쓰기 실패: 한국어 토스트. 낡은 버전이면 새로 불러온다.
    func fail(_ e: PetAPIError, reload: (() -> Void)? = nil) {
        ctx.toast(HubGroups.errorText(e), true)
        if e.isVersionConflict { reload?() }
    }

    // MARK: 처음 화면

    func showHome() {
        state.show(.loading)
        var gotGroups: Result<HubPage, PetAPIError>?
        var gotInv: Result<HubPage, PetAPIError>?
        var gotReq: Result<HubPage, PetAPIError>?
        let wait = DispatchGroup()
        wait.enter()
        call({ HubGroups.listGroupRooms($0, query: [], bearer: $1) }) { r in gotGroups = r.flatMap { HubAPI.page($0) }; wait.leave() }
        wait.enter()
        call({ HubGroups.listInvitations($0, query: [], bearer: $1) }) { r in gotInv = r.flatMap { HubAPI.page($0) }; wait.leave() }
        wait.enter()
        call({ HubGroups.listRequestRooms($0, query: [], bearer: $1) }) { r in gotReq = r.flatMap { HubAPI.page($0) }; wait.leave() }
        wait.notify(queue: .main) {
            guard case let .success(gp)? = gotGroups else {
                if case let .failure(e)? = gotGroups { self.state.show(.failed(HubGroups.errorText(e))) } else { self.state.show(.failed(PetAPIError.badResponse.text)) }
                return
            }
            self.groups = HubGroups.groups(gp.items)
            var notes: [String] = []
            if case let .success(p)? = gotInv {
                self.invitations = HubGroups.invitations(p.items)
                self.invitationsNext = p.nextQuery
            } else {
                self.invitations = []
                self.invitationsNext = nil
                notes.append("받은 초대를 불러오지 못했어요.")
            }
            if case let .success(p)? = gotReq {
                self.requests = HubGroups.incomingRequests(p.items)
                self.requestsNext = p.nextQuery
            } else {
                self.requests = []
                self.requestsNext = nil
                notes.append("대화 요청을 불러오지 못했어요.")
            }
            self.homeNote = notes.isEmpty ? nil : notes.joined(separator: " ")
            self.drawHome()
        }
    }

    func drawHome() {
        let answerable = invitations.filter { $0.canAnswer }.count
        present(page("그룹·요청", back: false) { stack in
            let invTitle = answerable > 0 ? "받은 초대 \(answerable)" : "받은 초대"
            let reqTitle = requests.isEmpty ? "대화 요청" : "대화 요청 \(requests.count)"
            let actions = HubKit.hstack([
                HubKit.primaryButton("그룹 만들기", symbol: "plus") { [weak self] in self?.showCreate() },
                HubKit.secondaryButton(invTitle, symbol: "envelope") { [weak self] in self?.showInvitations() },
                HubKit.secondaryButton(reqTitle, symbol: "bubble.left.and.bubble.right") { [weak self] in self?.showRequests() },
                HubKit.secondaryButton("요청 보내기", symbol: "paperplane") { [weak self] in self?.showSendRequest() },
            ])
            stack.addArrangedSubview(actions)
            if let n = homeNote {
                let l = HubKit.label(n, font: PetTheme.caption, color: PetTheme.color(\.danger))
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
            }
            let h = sectionLabel("내 그룹")
            stack.addArrangedSubview(h)
            if groups.isEmpty {
                let l = HubKit.label("아직 그룹이 없어요. 「그룹 만들기」로 나초들을 한 방에 모아 보세요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [h, l])
            } else {
                HubKit.fill(stack, [h])
                for g in groups {
                    let people = g.isAgentGroup ? "나초 \(g.memberAgentIDs.count)명" : "사람과 나초의 방"
                    var sub = people
                    if g.hasActiveRun { sub += " · 일하는 중" }
                    if g.muted { sub += " · 알림 끔" }
                    let row = HubRow(title: g.title.isEmpty ? "이름 없는 그룹" : g.title, subtitle: sub, symbol: g.isAgentGroup ? "person.3" : "person.2")
                    row.onClick = { [weak self] in self?.showSettings(g) }
                    stack.addArrangedSubview(row)
                    HubKit.fill(stack, [row])
                }
            }
        })
    }
}
