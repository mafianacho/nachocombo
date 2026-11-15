import AppKit
import NachoComboCore

/// 「대화창에서 이어 말하기」 자리. 대화창이 여러 방을 다루는 일은 U10(다음 stage)이 한다.
/// 지금은 꺼 둔다: 단추는 비활성이고 `openInChat`은 아무것도 하지 않는다. U10이 `chatOpener`를 채우고 `continueInChatEnabled`를 켠다.
enum HubRooms {
    static let continueInChatEnabled = false
    static var chatOpener: ((String) -> Void)?

    static func openInChat(roomID: String) {
        guard continueInChatEnabled else { return }
        chatOpener?(roomID)
    }
}

/// 대화 섹션(NACHO-269 U3): 방 목록·보관한 대화(B6), 이름·보관·삭제(B7), 메시지 검색(B8), 방별 미디어·파일·링크(B12), 문서 페이지·받은 파일(B11).
/// 요청은 모두 `HubRoomsAPI`(Core)가 만든다. 서버가 주는 오류는 한국어로 보여 준다.
/// 쓰기 중에 사용자가 다른 섹션으로 옮겨도 결과(토스트·목록 갱신)가 사라지지 않는다: 완료 콜백이 섹션과 클라이언트를 직접 붙들고,
/// 토스트는 시작할 때의 `ctx.toast`로 보낸다.
final class RoomsSection: HubSectionBase {
    enum ListTab { case active, stored }
    enum RoomTab { case history, photos, files, links }

    var listTab: ListTab = .active
    var rooms: [HubRoom] = []
    var listNext: [(String, String)]?
    var searchTerm = ""
    var searchItems: [HubSearchItem] = []
    var searchNext: [(String, String)]?
    var historyOldest: Int?
    var renameVisible = false

    let searchForm = HubFormField(title: "메시지 검색", placeholder: "찾을 말을 적어 주세요", validator: RoomsSection.queryProblem)

    init() {
        super.init(id: .rooms)
        searchForm.field.target = self
        searchForm.field.action = #selector(searchSubmitted)
    }

    static func queryProblem(_ v: String) -> String? {
        if case let .failure(e) = HubRoomsAPI.normalizeQuery(v) { return e.text }
        return nil
    }

    // MARK: 공통

    /// 요청을 보내고 결과를 돌려 준다. 완료 콜백이 `client`를 붙들어, 보내는 동안 섹션이 바뀌어도 응답이 버려지지 않는다.
    func call(_ client: HubClient, _ make: @escaping (ServerEndpoint, String?) -> PetHTTPRequest,
              _ done: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        let endpoint = client.endpoint
        client.send({ make(endpoint, $0) }) { result in
            withExtendedLifetime(client) { done(result) }
        }
    }

    /// 화면 하나를 내용 자리에 붙인다.
    func present(_ view: NSView) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        HubKit.pin(view, in: host)
        state.show(.content)
    }

    /// 위쪽 머리(여러 줄) + 아래쪽 본문.
    func screen(header: [NSView], body: NSView) -> NSView {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        let top = HubKit.vstack(header, spacing: Double(PetTokens.Space.s))
        root.addSubview(top)
        root.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        let inset = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            body.topAnchor.constraint(equalTo: top.bottomAnchor, constant: CGFloat(PetTokens.Space.s)),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        HubKit.fill(top, header)
        return root
    }

    func emptyNote(_ text: String) -> NSView {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        let l = HubKit.label(text, color: PetTheme.secondary)
        host.addSubview(l)
        let p = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: host.topAnchor, constant: p),
            l.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: p),
            l.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -p),
        ])
        return host
    }

    func showFailure(_ text: String) { state.show(.failed(text)) }

    static func kindLabel(_ r: HubRoom) -> String {
        switch r.kind {
        case "character": return "나초와 1:1"
        case "direct": return "자유 대화"
        case "group": return "단톡방"
        case "agent_group": return "나초 단톡"
        case "character_pair": return "나초끼리"
        case "character_direct": return "나초와 대화"
        default: return "대화"
        }
    }

    static func sizeText(_ bytes: Int?) -> String? {
        guard let b = bytes else { return nil }
        if b >= 1_048_576 { return String(format: "%.1fMB", Double(b) / 1_048_576) }
        if b >= 1024 { return "\(b / 1024)KB" }
        return "\(b)B"
    }

    // MARK: 목록 (B6)

    override func load() {
        guard let client = ctx.client else { showFailure("로그인이 필요해요."); return }
        renameVisible = false
        state.show(.loading)
        switch listTab {
        case .active:
            call(client, { HubRoomsAPI.syncRequest($0, bearer: $1) }) { [self] result in
                onMain {
                    switch result {
                    case let .failure(e): self.showFailure(e.text)
                    case let .success(resp):
                        switch HubRoomsAPI.decodeSync(resp) {
                        case let .failure(e): self.showFailure(e.text)
                        case let .success(sync): self.showRooms(sync.rooms, next: nil)
                        }
                    }
                }
            }
        case .stored:
            call(client, { HubRoomsAPI.listRequest($0, stored: true, limit: HubRoomsAPI.pageSize, next: nil, bearer: $1) }) { [self] result in
                onMain {
                    switch self.roomsPage(result) {
                    case let .failure(e): self.showFailure(e.text)
                    case let .success(p): self.showRooms(p.rooms, next: p.next)
                    }
                }
            }
        }
    }

    func roomsPage(_ result: Result<PetHTTPResponse, PetAPIError>) -> Result<HubRoomsPage, PetAPIError> {
        switch result {
        case let .failure(e): return .failure(e)
        case let .success(resp): return HubRoomsAPI.decodeRooms(resp)
        }
    }

    func roomRow(_ r: HubRoom) -> HubRow {
        var sub = RoomsSection.kindLabel(r)
        if let n = r.memberCount, r.isGroup { sub += " · \(n)명" }
        if r.unread > 0 { sub += " · 안 읽음 \(r.unread)" }
        let row = HubRow(title: r.displayTitle, subtitle: sub, trailing: HubFormat.date(r.updatedAt),
                         symbol: r.isGroup ? "person.3" : "bubble.left.and.bubble.right")
        row.onClick = { [self] in openRoom(r.id) }
        return row
    }

    func tabButton(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> PetPill {
        selected ? HubKit.primaryButton(title, onClick: action) : HubKit.secondaryButton(title, onClick: action)
    }

    func listHeader() -> [NSView] {
        let title = HubKit.label("대화", font: PetTheme.title)
        let tabs = HubKit.hstack([
            tabButton("대화", selected: listTab == .active) { [self] in listTab = .active; load() },
            tabButton("보관한 대화", selected: listTab == .stored) { [self] in listTab = .stored; load() },
        ])
        let go = HubKit.primaryButton("검색", symbol: "magnifyingglass") { [self] in searchSubmitted() }
        let search = HubKit.hstack([searchForm, go])
        searchForm.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return [title, tabs, search]
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다).
    func showRooms(_ rooms: [HubRoom], next: [(String, String)]?) {
        self.rooms = rooms
        listNext = next
        let body: NSView
        if rooms.isEmpty {
            body = emptyNote(listTab == .stored ? "넣어둔 대화가 없어요. 대화에서 ‘보관’을 고르면 여기에 모여요." : "아직 대화가 없어요.")
        } else {
            let list = HubListView()
            list.setRows(rooms.map(roomRow), hasMore: next != nil)
            list.onLoadMore = { [self] in loadMoreRooms() }
            body = list
        }
        present(screen(header: listHeader(), body: body))
    }

    func loadMoreRooms() {
        guard let client = ctx.client, let next = listNext else { return }
        call(client, { HubRoomsAPI.listRequest($0, stored: true, limit: HubRoomsAPI.pageSize, next: next, bearer: $1) }) { [self] result in
            onMain {
                switch self.roomsPage(result) {
                case let .failure(e): self.ctx.toast(e.text, true)
                case let .success(p): self.showRooms(self.rooms + p.rooms, next: p.next)
                }
            }
        }
    }

    // MARK: 검색 (B8)

    @objc func searchSubmitted() {
        guard searchForm.validate() else { return }
        guard case let .success(q) = HubRoomsAPI.normalizeQuery(searchForm.field.stringValue) else { return }
        runSearch(q)
    }

    func runSearch(_ q: String) {
        guard let client = ctx.client else { showFailure("로그인이 필요해요."); return }
        searchTerm = q
        state.show(.loading)
        call(client, { HubRoomsAPI.searchRequest($0, query: q, roomID: nil, limit: HubRoomsAPI.pageSize, next: nil, bearer: $1) }) { [self] result in
            onMain {
                switch self.searchPage(result) {
                case let .failure(e):
                    // 목록으로 돌아가 검색 칸 아래에 서버 문구를 보여 준다.
                    self.showRooms(self.rooms, next: self.listNext)
                    self.searchForm.showServerError(e.text)
                case let .success(p): self.showSearch(p.items, next: p.next)
                }
            }
        }
    }

    func searchPage(_ result: Result<PetHTTPResponse, PetAPIError>) -> Result<HubSearchPage, PetAPIError> {
        switch result {
        case let .failure(e): return .failure(e)
        case let .success(resp): return HubRoomsAPI.decodeSearch(resp)
        }
    }

    func searchRow(_ it: HubSearchItem) -> HubRow {
        let row = HubRow(title: it.label.isEmpty ? "대화" : it.label, subtitle: it.plainText.isEmpty ? "(통화 자막)" : it.plainText,
                         trailing: it.dateLabel, symbol: it.kind == "phone" ? "phone" : "text.bubble")
        if let rid = it.roomID { row.onClick = { [self] in openRoom(rid) } }
        return row
    }

    func showSearch(_ items: [HubSearchItem], next: [(String, String)]?) {
        searchItems = items
        searchNext = next
        let back = HubKit.secondaryButton("목록으로", symbol: "chevron.left") { [self] in load() }
        let title = HubKit.label("‘\(searchTerm)’ 검색 결과", font: PetTheme.title)
        let body: NSView
        if items.isEmpty {
            body = emptyNote("찾는 말이 없어요.")
        } else {
            let list = HubListView()
            list.setRows(items.map(searchRow), hasMore: next != nil)
            list.onLoadMore = { [self] in loadMoreSearch() }
            body = list
        }
        present(screen(header: [back, title], body: body))
    }

    func loadMoreSearch() {
        guard let client = ctx.client, let next = searchNext else { return }
        let q = searchTerm
        call(client, { HubRoomsAPI.searchRequest($0, query: q, roomID: nil, limit: HubRoomsAPI.pageSize, next: next, bearer: $1) }) { [self] result in
            onMain {
                switch self.searchPage(result) {
                case let .failure(e): self.ctx.toast(e.text, true)
                case let .success(p): self.showSearch(self.searchItems + p.items, next: p.next)
                }
            }
        }
    }
}
