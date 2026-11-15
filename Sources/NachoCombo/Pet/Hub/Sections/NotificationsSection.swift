import AppKit
import NachoComboCore

/// 알림·활동 섹션(NACHO-268 U2, 표 행 A7): 알림 목록·읽음, 활동 피드, 알림 설정. 규칙은 docs/HUB.md.
///   알림: GET /me/notifications · POST /me/notifications/{id}/read  — 누르면 관련 섹션으로(`onNavigate`), 갈 곳이 없으면 읽음 처리만
///   활동: GET /activity · POST /activity/seen  — 활동 탭을 열면 본 것으로 표시
///   설정: GET·PATCH /me/notification-settings  — 푸시 전체·나초별 끄기는 「휴대폰 알림 설정」으로 읽기만
/// 창이 `onNavigate`·`onBadgeChange`를 이어 주면 섹션 이동과 사이드바 배지가 된다(공용 변경 요청 — PR 본문).
final class NotificationsSection: HubSectionBase {
    enum Tab: Int, CaseIterable {
        case notifications, activity, settings
        var title: String {
            switch self {
            case .notifications: return "알림"
            case .activity: return "활동"
            case .settings: return "설정"
            }
        }
    }

    /// 알림·활동 줄을 누르면 갈 섹션. 창이 이어 준다(없으면 이동 없이 읽음 처리만).
    var onNavigate: ((HubSectionID) -> Void)?
    /// 사이드바 배지 수가 바뀔 때(알림·활동을 불러올 때마다).
    var onBadgeChange: ((Int) -> Void)?

    private(set) var tab: Tab = .notifications
    private(set) var notifications: [HubNotification] = []
    private(set) var nextBefore: String?
    private(set) var activity: HubActivityFeed?
    private(set) var settings: HubNotificationSettings?
    private(set) var badge = 0

    /// 쓰기 요청 중에 다른 섹션으로 옮겨도 결과가 버려지지 않게 요청 실행기를 섹션이 직접 쥔다(`HubClient`는 자기를 약하게 잡는다).
    private var client: HubClient?
    private let tabs = NSSegmentedControl(labels: Tab.allCases.map { $0.title }, trackingMode: .selectOne, target: nil, action: nil)
    private let bodyHost = NSView()
    private var settingRows: [String: HubSwitchRow] = [:]

    init() {
        super.init(id: .notifications)
        buildFrame()
    }

    private func buildFrame() {
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        let host = state.contentHost
        host.addSubview(tabs)
        host.addSubview(bodyHost)
        let m = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: host.topAnchor, constant: m),
            tabs.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            bodyHost.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: CGFloat(PetTokens.Space.s)),
            bodyHost.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bodyHost.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bodyHost.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    // MARK: 불러오기

    override func load() {
        guard let client = ctx.client else { state.show(.failed("로그인이 필요해요.")); return }
        self.client = client
        state.show(.loading)
        fetchNotifications(client, before: nil, append: false)
    }

    private func fetchNotifications(_ client: HubClient, before: String?, append: Bool) {
        let e = client.endpoint
        client.send({ HubNotificationsAPI.listRequest(e, before: before, bearer: $0) }) { [self] result in
            onMain {
                switch result {
                case let .failure(err):
                    if append { self.ctx.toast(err.text, true) } else { self.state.show(.failed(err.text)) }
                case let .success(resp):
                    switch HubNotificationsAPI.parseList(resp) {
                    case let .failure(err):
                        if append { self.ctx.toast(err.text, true) } else { self.state.show(.failed(err.text)) }
                    case let .success(page):
                        self.showNotifications(page, append: append)
                        if !append { self.fetchActivity(client, markSeen: false) }
                    }
                }
            }
        }
    }

    private func fetchActivity(_ client: HubClient, markSeen: Bool) {
        let e = client.endpoint
        client.send({ HubActivityAPI.feedRequest(e, bearer: $0) }) { [self] result in
            onMain {
                switch result {
                case let .failure(err):
                    if markSeen { self.ctx.toast(err.text, true) }
                case let .success(resp):
                    switch HubActivityAPI.parseFeed(resp) {
                    case let .failure(err): if markSeen { self.ctx.toast(err.text, true) }
                    case let .success(feed):
                        self.showActivity(feed)
                        if markSeen && feed.unreadCount > 0 { self.sendSeen(client) }
                    }
                }
            }
        }
    }

    private func sendSeen(_ client: HubClient) {
        let e = client.endpoint
        client.send({ HubActivityAPI.seenRequest(e, bearer: $0) }) { [self] result in
            onMain {
                guard case let .success(resp) = result, case let .success(count) = HubActivityAPI.parseSeen(resp) else { return }
                self.activity?.unreadCount = count
                self.updateBadge()
                if self.tab == .activity { self.render() }
            }
        }
    }

    private func fetchSettings(_ client: HubClient) {
        let e = client.endpoint
        client.send({ HubNotificationSettingsAPI.getRequest(e, bearer: $0) }) { [self] result in
            onMain {
                switch result {
                case let .failure(err): self.ctx.toast(err.text, true)
                case let .success(resp):
                    switch HubNotificationSettingsAPI.parse(resp) {
                    case let .failure(err): self.ctx.toast(err.text, true)
                    case let .success(s): self.showSettings(s)
                    }
                }
            }
        }
    }

    // MARK: 화면 그리기만(시험·캡처가 직접 부른다)

    func showNotifications(_ page: HubNotificationPage, append: Bool) {
        let shown = page.items.filter { HubNotificationsAPI.isInboxKind($0.kind) }
        notifications = append ? notifications + shown : shown
        nextBefore = page.nextBefore
        state.show(.content)
        updateBadge()
        if tab == .notifications { render() }
    }

    func showActivity(_ feed: HubActivityFeed) {
        activity = feed
        state.show(.content)
        updateBadge()
        if tab == .activity { render() }
    }

    func showSettings(_ s: HubNotificationSettings) {
        settings = s
        state.show(.content)
        if tab == .settings { render() }
    }

    func select(_ t: Tab) {
        tab = t
        tabs.selectedSegment = t.rawValue
        state.show(.content)
        render()
        guard let client = client ?? ctx?.client else { return }
        self.client = client
        if t == .activity { fetchActivity(client, markSeen: true) }
        if t == .settings { fetchSettings(client) }
    }

    @objc private func tabChanged() {
        select(Tab(rawValue: tabs.selectedSegment) ?? .notifications)
    }

    /// 사이드바 배지 수 = 안 읽은 알림 + 활동의 안 읽은 수(불러올 때마다 갱신).
    private func updateBadge() {
        badge = HubNotificationsAPI.badgeCount(notifications: notifications, activityUnread: activity?.unreadCount ?? 0)
        let n = notifications.filter { $0.isUnread }.count
        let a = activity?.unreadCount ?? 0
        tabs.setLabel(n > 0 ? "알림 \(n)" : "알림", forSegment: Tab.notifications.rawValue)
        tabs.setLabel(a > 0 ? "활동 \(a)" : "활동", forSegment: Tab.activity.rawValue)
        onBadgeChange?(badge)
    }

    private func render() {
        for v in bodyHost.subviews { v.removeFromSuperview() }
        settingRows = [:]
        switch tab {
        case .notifications: HubKit.pin(notificationsView(), in: bodyHost)
        case .activity: HubKit.pin(activityView(), in: bodyHost)
        case .settings: HubKit.pin(settingsView(), in: bodyHost)
        }
    }

    private func emptyView(_ text: String) -> NSView {
        let v = NSView()
        let l = HubKit.label(text, color: PetTheme.secondary)
        l.alignment = .center
        v.addSubview(l)
        NSLayoutConstraint.activate([
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        return v
    }

    // MARK: 알림 탭

    private func notificationsView() -> NSView {
        if notifications.isEmpty { return emptyView("알림이 없어요.") }
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.s))
        let unread = notifications.filter { $0.isUnread }.count
        let head = HubKit.hstack([
            HubKit.label(unread > 0 ? "안 읽은 알림 \(unread)개" : "모두 읽었어요", font: PetTheme.caption, color: PetTheme.secondary, wrap: false),
            HubKit.secondaryButton("새로고침", symbol: "arrow.clockwise") { [weak self] in self?.reload() },
        ], spacing: Double(PetTokens.Space.m))
        parts.stack.addArrangedSubview(head)
        for n in notifications {
            let row = HubRow(title: n.title, subtitle: HubNotificationsAPI.shownBody(n), trailing: HubFormat.date(n.createdAt),
                             symbol: n.isUnread ? "bell.badge" : "bell")
            row.onClick = { [weak self] in self?.open(n) }
            row.setAccessibilityLabel((n.isUnread ? "안 읽음, " : "") + n.title)
            row.setAccessibilityIdentifier("hub-notification-\(n.id)")
            parts.stack.addArrangedSubview(row)
            HubKit.fill(parts.stack, [row])
        }
        if nextBefore != nil {
            parts.stack.addArrangedSubview(HubKit.secondaryButton("더 보기") { [weak self] in self?.loadMore() })
        }
        return parts.scroll
    }

    private func loadMore() {
        guard let client = client, let before = nextBefore else { return }
        fetchNotifications(client, before: before, append: true)
    }

    /// 눌렀을 때: 안 읽은 알림이면 읽음 요청(바로 화면에 반영, 실패하면 되돌림), 갈 곳이 있으면 그 섹션으로.
    func open(_ n: HubNotification) {
        if n.isUnread { markRead(n) }
        if let dest = HubNotificationsAPI.destination(n) { onNavigate?(dest) }
    }

    private func markRead(_ n: HubNotification) {
        guard let client = client ?? ctx?.client, let i = notifications.firstIndex(where: { $0.id == n.id }) else { return }
        self.client = client
        notifications[i].readAt = ISO8601DateFormatter().string(from: Date())
        updateBadge()
        if tab == .notifications { render() }
        let e = client.endpoint
        client.send({ HubNotificationsAPI.markReadRequest(e, id: n.id, bearer: $0) }) { [self] result in
            onMain {
                guard case let .failure(err) = result else { return }
                if let j = self.notifications.firstIndex(where: { $0.id == n.id }) { self.notifications[j].readAt = nil }
                self.updateBadge()
                if self.tab == .notifications { self.render() }
                self.ctx.toast(err.text, true)
            }
        }
    }

    // MARK: 활동 탭

    private func activityView() -> NSView {
        guard let feed = activity else { return emptyView("불러오는 중…") }
        if feed.isEmpty { return emptyView("아직 소식이 없어요.\n친구가 생기면 나초가 소식을 전해 줘요.") }
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.s))
        for section in feed.sections {
            let h = HubKit.label(section.dateLabel, font: PetTheme.caption, color: PetTheme.secondary)
            parts.stack.addArrangedSubview(h)
            for item in section.items {
                let trailing = item.unread ? "새 소식 · \(item.timeLabel)" : item.timeLabel
                let row = HubRow(title: item.sentence, subtitle: item.bodyText, trailing: trailing, symbol: item.unread ? "circle.fill" : "circle")
                row.onClick = { [weak self] in if let d = item.destination { self?.onNavigate?(d) } }
                row.setAccessibilityIdentifier("hub-activity-\(item.id)")
                parts.stack.addArrangedSubview(row)
                HubKit.fill(parts.stack, [row])
            }
        }
        return parts.scroll
    }

    // MARK: 설정 탭

    private func settingsView() -> NSView {
        guard let s = settings else { return emptyView("불러오는 중…") }
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        let stack = parts.stack
        let phone = HubKit.vstack([
            HubKit.label("휴대폰 알림 설정", font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium)),
            HubKit.label("푸시는 휴대폰에서 받아요. 맥에서는 아래 두 가지를 읽기만 해요.", font: PetTheme.caption, color: PetTheme.secondary),
            HubKit.label("전체 푸시: " + (s.allEnabled ? "켜짐" : "꺼짐"), color: PetTheme.text),
            HubKit.label("푸시를 받지 않는 나초: \(s.mutedAgentIDs.count)마리", color: PetTheme.text),
        ], spacing: Double(PetTokens.Space.xs))
        stack.addArrangedSubview(phone)
        HubKit.fill(stack, [phone])
        for g in HubNotificationCatalog.groups {
            let h = HubKit.label(g.title, font: PetTheme.caption, color: PetTheme.secondary)
            stack.addArrangedSubview(h)
            for item in g.items {
                var detail: String?
                if !HubNotificationCatalog.canTurnOff(item.id) { detail = "끌 수 없어요." }
                else if HubNotificationCatalog.needsWarning(item.id) { detail = "끄면 답이 필요한 일이 멈춰 있을 수 있어요." }
                let row = HubSwitchRow(title: item.label, detail: detail, isOn: s.isOn(item.id))
                row.toggle.isEnabled = HubNotificationCatalog.canTurnOff(item.id)
                row.onChange = { [weak self] on in self?.setItem(item.id, on) }
                row.setAccessibilityIdentifier("hub-notification-setting-\(item.id)")
                settingRows[item.id] = row
                stack.addArrangedSubview(row)
                HubKit.fill(stack, [row])
            }
        }
        return parts.scroll
    }

    /// 한 항목을 바꾼다: 바로 반영하고 PATCH, 실패하면 되돌리고 한국어 문구를 토스트로.
    func setItem(_ id: String, _ on: Bool) {
        guard let client = client ?? ctx?.client, var s = settings else { return }
        self.client = client
        let e = client.endpoint
        guard HubNotificationSettingsAPI.patchItemRequest(e, id: id, on: on, bearer: nil) != nil else {
            ctx.toast("이 알림은 끌 수 없어요.", true)
            render()
            return
        }
        let before = s
        s.items[id] = on
        settings = s
        client.send({ HubNotificationSettingsAPI.patchItemRequest(e, id: id, on: on, bearer: $0)! }) { [self] result in
            onMain {
                switch result {
                case let .failure(err):
                    self.settings = before
                    if self.tab == .settings { self.render() }
                    self.ctx.toast(err.text, true)
                case let .success(resp):
                    switch HubNotificationSettingsAPI.parse(resp) {
                    case let .success(fresh): self.settings = fresh
                    case .failure: break
                    }
                    if self.tab == .settings { self.render() }
                    self.ctx.toast("알림 설정을 바꿨어요.", false)
                }
            }
        }
    }
}
