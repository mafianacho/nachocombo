import AppKit
import NachoComboCore

private typealias Sp = PetTokens.Space
private typealias Parts = PetConnectionsParts

/// What the Connections tab needs from the app. `NachoPetModule` is the real one; the capture tests bring a fake.
protocol PetConnectionsHost: AnyObject {
    var trust: GadgetTrust { get }
    /// How the link between Nacho and this Mac stands ("연결됨"…), one short phrase.
    var macLinkText: String { get }
    func connectionsLoad(_ done: @escaping (Result<ConnectorOverview, ConnectorError>) -> Void)
    /// A calls object with a fresh token; nil when signed out. May answer on any thread.
    func connectionsAPI(_ body: @escaping (ConnectionsAPI?) -> Void)
    func gadgetStates() -> [GadgetSwitchState]
    /// Turns a gadget on or off the way the gallery does (a missing macOS permission is explained and asked for then).
    func setGadget(_ id: GadgetID, on: Bool)
    func permissionGranted(_ permission: OSPermission) -> Bool
    func requestPermission(_ permission: OSPermission)
    func openInBrowser(_ url: URL)
}

/// The 「연결」 tab of the pet's chat (NACHO-131 / NACHO-239): search, three sections (도구 / 커넥터 / 가젯), a detail per row,
/// 「서비스 추가」 and the connect flow. All wording comes from `NachoComboCore` (`ConnectionsListBuilder`,
/// `ConnectionsDetailBuilder`); this class only draws it and calls the host and the server.
final class PetConnectionsView: NSStackView, NSSearchFieldDelegate {
    enum Screen: Equatable {
        case list
        case detail(ConnectionsRef)
        case add
        case connect
    }

    /// The service being connected and where it stands.
    struct ConnectFlow {
        var service: CatalogRow
        var progress: ConnectProgress
        var attemptID: String?
        var authorizeURL: URL?
    }

    private let host: PetConnectionsHost
    let contentWidth: CGFloat
    private let head = NSStackView()
    private let body = NSStackView()
    private let searchField = NSSearchField()
    private let addSearchField = NSSearchField()

    var screen: Screen = .list
    var overview: ConnectorOverview?
    var loadError: String?
    var loading = false
    var query = ""
    var gadgets: [GadgetSwitchState] = []
    var detailInfo: [String: ConnectionDetailInfo] = [:]
    var catalog: [CatalogRow]?
    var catalogError: String?
    var connect: ConnectFlow?
    /// A line above the list or detail: what just happened or what failed. Cleared on the next screen.
    var message: (text: String, failed: Bool)?
    var confirmingDisconnect = false

    private var headKey = ""
    private var catalogTimer: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollCount = 0
    private var watchTimer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var emailField: NSTextField?
    private var passwordField: NSSecureTextField?

    init(host: PetConnectionsHost, width: CGFloat) {
        self.host = host
        contentWidth = width
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = CGFloat(Sp.s)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        for stack in [head, body] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = CGFloat(Sp.s)
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        addArrangedSubview(head)
        addArrangedSubview(body)
        for f in [searchField, addSearchField] {
            f.delegate = self
            f.sendsSearchStringImmediately = true
            f.font = PetTheme.body
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        searchField.placeholderString = "도구·커넥터·가젯 검색"
        searchField.setAccessibilityIdentifier("connections-search")
        addSearchField.placeholderString = "서비스 이름으로 찾기"
        addSearchField.setAccessibilityIdentifier("connections-add-search")
        gadgets = host.gadgetStates()
        render()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        pollTimer?.invalidate()
        watchTimer?.invalidate()
        if let o = activeObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: lifecycle

    /// The tab was opened: back to the list and read the server again.
    func open() {
        screen = .list
        query = ""
        searchField.stringValue = ""
        message = nil
        confirmingDisconnect = false
        stopPolling()
        reload()
        startWatching()
    }

    /// The tab was left.
    func close() {
        stopPolling()
        watchTimer?.invalidate()
        watchTimer = nil
    }

    /// Gadget switches change outside this view too (the gallery, Nacho's own command): look again each second while shown.
    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.syncGadgets() }
    }

    func syncGadgets() {
        let now = host.gadgetStates()
        guard now != gadgets else { return }
        gadgets = now
        render()
    }

    func reload() {
        loading = true
        loadError = nil
        render()
        host.connectionsLoad { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                switch result {
                case let .success(o): self.overview = o; self.loadError = nil
                case let .failure(e): self.loadError = e.koreanMessage
                }
                self.render()
            }
        }
    }

    // MARK: render

    func render() {
        let key: String
        switch screen {
        case .list: key = "list"
        case let .detail(ref): key = "detail:\(ref)"
        case .add: key = "add"
        case .connect: key = "connect"
        }
        if key != headKey {
            headKey = key
            renderHead()
        }
        renderBody()
        needsLayout = true
    }

    private func clear(_ stack: NSStackView) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
    }

    private func backBar(_ title: String, to target: @escaping () -> Void) -> NSView {
        let back = Parts.pill(title, symbol: "chevron.left", color: PetTheme.secondary, fill: nil, onClick: target)
        back.setAccessibilityLabel("뒤로 가기: \(title)")
        return back
    }

    private func renderHead() {
        clear(head)
        switch screen {
        case .list:
            head.addArrangedSubview(searchField)
        case .detail:
            head.addArrangedSubview(backBar("연결") { [weak self] in self?.goList() })
        case .add:
            head.addArrangedSubview(backBar("연결") { [weak self] in self?.goList() })
            head.addArrangedSubview(addSearchField)
        case .connect:
            head.addArrangedSubview(backBar("서비스 추가") { [weak self] in self?.leaveConnect() })
        }
    }

    private func renderBody() {
        clear(body)
        emailField = nil
        passwordField = nil
        if let m = message { body.addArrangedSubview(messageBox(m.text, failed: m.failed)) }
        switch screen {
        case .list: renderList()
        case let .detail(ref): renderDetail(ref)
        case .add: renderAdd()
        case .connect: renderConnect()
        }
    }

    private func messageBox(_ text: String, failed: Bool) -> NSView {
        let l = Parts.label(text, font: PetTheme.caption, color: failed ? PetTheme.color(\.danger) : PetTheme.text, width: contentWidth - CGFloat(2 * Sp.m))
        return Parts.card(l, fill: failed ? PetTheme.color(\.dangerSoft) : PetTheme.color(\.accentSoft), width: contentWidth, padding: Sp.s)
    }

    private func sectionHeader(_ title: String, count: Int?, trailing: NSView? = nil) -> NSView {
        let t = Parts.label(title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold), width: 200, lines: 1)
        var views: [NSView] = [t]
        if let c = count {
            views.append(Parts.label("\(c)", font: PetTheme.caption, color: PetTheme.tertiary, width: 40, lines: 1))
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        views.append(spacer)
        if let tr = trailing { views.append(tr) }
        let row = Parts.hstack(views, spacing: Sp.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    // MARK: list

    private func renderList() {
        if let e = loadError { body.addArrangedSubview(messageBox(e, failed: true)) }
        if loading && overview == nil { body.addArrangedSubview(Parts.label("불러오는 중…", color: PetTheme.secondary, width: contentWidth)) }
        if query.isEmpty {
            body.addArrangedSubview(Parts.label("나초와 이 맥의 연결: \(host.macLinkText)", font: PetTheme.caption, color: PetTheme.tertiary, width: contentWidth, lines: 1))
        }
        let sections = ConnectionsListBuilder.sections(overview: overview, gadgets: gadgets, disabled: host.trust.disabled, query: query)
        if sections.isEmpty {
            body.addArrangedSubview(Parts.label("“\(query.trimmingCharacters(in: .whitespacesAndNewlines))”에 맞는 항목이 없어요.",
                                                color: PetTheme.secondary, width: contentWidth))
        }
        for s in sections {
            var trailing: NSView?
            if s.section == .connectors {
                trailing = Parts.pill("서비스 추가", symbol: "plus", color: PetTheme.accent, fill: PetTheme.color(\.accentSoft)) { [weak self] in self?.goAdd() }
            }
            body.addArrangedSubview(sectionHeader(s.section.title, count: s.rows.isEmpty ? nil : s.rows.count, trailing: trailing))
            if s.rows.isEmpty {
                let text = (loading || (overview == nil && loadError == nil)) && s.section != .gadgets ? "" : s.section.emptyText
                if !text.isEmpty { body.addArrangedSubview(Parts.label(text, font: PetTheme.caption, color: PetTheme.tertiary, width: contentWidth)) }
            }
            for row in s.rows { body.addArrangedSubview(rowView(row)) }
        }
    }

    private func rowView(_ row: ConnectionsRow) -> NSView {
        PetConnectionsRowView(row: row, width: contentWidth,
                              onToggle: { [weak self] on in self?.toggle(row.ref, on: on) },
                              onOpen: { [weak self] in self?.goDetail(row.ref) })
    }

    // MARK: navigation

    func goList() {
        screen = .list
        message = nil
        confirmingDisconnect = false
        stopPolling()
        render()
    }

    func goDetail(_ ref: ConnectionsRef) {
        screen = .detail(ref)
        message = nil
        confirmingDisconnect = false
        render()
        if case let .connector(id) = ref, let c = overview?.connections.first(where: { $0.id == id }), detailInfo[c.source] == nil {
            host.connectionsAPI { [weak self] api in
                api?.detail(source: c.source) { result in
                    DispatchQueue.main.async {
                        guard let self = self, case let .success(info) = result else { return }
                        self.detailInfo[c.source] = info
                        if self.screen == .detail(ref) { self.render() }
                    }
                }
            }
        }
    }

    func goAdd() {
        screen = .add
        message = nil
        catalog = nil
        catalogError = nil
        addSearchField.stringValue = ""
        render()
        loadCatalog(query: "")
    }

    private func leaveConnect() {
        if let f = connect, let id = f.attemptID, !f.progress.isFinished {
            host.connectionsAPI { api in api?.cancelAttempt(id: id) { _ in } }
        }
        stopPolling()
        connect = nil
        screen = .add
        message = nil
        render()
        loadCatalog(query: addSearchField.stringValue)
    }

    // MARK: search

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        if field === searchField {
            query = field.stringValue
            renderBody()
        } else if field === addSearchField {
            catalogTimer?.cancel()
            let q = field.stringValue
            let work = DispatchWorkItem { [weak self] in self?.loadCatalog(query: q) }
            catalogTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: switches

    func toggle(_ ref: ConnectionsRef, on: Bool) {
        message = nil
        switch ref {
        case let .tool(id): toggleTool(id, on: on)
        case let .connector(id): toggleConnector(id, on: on)
        case let .gadget(g):
            host.setGadget(g, on: on)
            gadgets = host.gadgetStates()
            render()
        }
    }

    private func toggleTool(_ id: String, on: Bool) {
        guard var o = overview, let i = o.tools.firstIndex(where: { $0.id == id }), !o.tools[i].locked else { render(); return }
        let before = o.tools[i].userEnabled
        o.tools[i].userEnabled = on
        overview = o
        render()
        host.connectionsAPI { [weak self] api in
            guard let api = api else { self?.undoTool(id, to: before, ConnectionsFailure.unauthorized); return }
            api.setToolEnabled(id: id, enabled: on) { result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case let .success(row): self.applyTool(id, row)
                    case let .failure(f): self.undoTool(id, to: before, f)
                    }
                }
            }
        }
    }

    private func applyTool(_ id: String, _ row: ToolRow) {
        guard var o = overview, let i = o.tools.firstIndex(where: { $0.id == id }) else { return }
        o.tools[i].userEnabled = row.userEnabled
        o.tools[i].locked = row.locked
        overview = o
        render()
    }

    /// The call failed: the switch goes back to what it was and the reason is shown.
    private func undoTool(_ id: String, to value: Bool, _ failure: ConnectionsFailure) {
        DispatchQueue.main.async {
            guard var o = self.overview, let i = o.tools.firstIndex(where: { $0.id == id }) else { return }
            o.tools[i].userEnabled = value
            if failure == .locked { o.tools[i].locked = true }
            self.overview = o
            self.message = (failure.koreanMessage, true)
            self.render()
        }
    }

    private func toggleConnector(_ id: String, on: Bool) {
        guard var o = overview, let i = o.connections.firstIndex(where: { $0.id == id }) else { return }
        let before = o.connections[i].enabled
        let version = o.connections[i].version
        o.connections[i].enabled = on
        overview = o
        render()
        host.connectionsAPI { [weak self] api in
            guard let api = api else { self?.undoConnector(id, to: before, .unauthorized); return }
            api.setConnectionEnabled(id: id, enabled: on, version: version) { result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success: self.reload()
                    case let .failure(f): self.undoConnector(id, to: before, f)
                    }
                }
            }
        }
    }

    private func undoConnector(_ id: String, to value: Bool, _ failure: ConnectionsFailure) {
        DispatchQueue.main.async {
            guard var o = self.overview, let i = o.connections.firstIndex(where: { $0.id == id }) else { return }
            o.connections[i].enabled = value
            self.overview = o
            self.message = (failure.koreanMessage, true)
            self.render()
            if case .conflict = failure { self.reload() }
        }
    }

    /// One Mac action of a gadget. Switching on asks for the macOS permissions it needs, only now.
    func toggleAction(_ id: String, on: Bool) {
        guard let tool = MacActions.tool(connectorName: id) else { return }
        host.trust.setActionEnabled(tool, on)
        message = nil
        if on {
            let missing = tool.permissions.sorted().filter { !host.permissionGranted($0) }
            if !missing.isEmpty {
                for p in missing { host.requestPermission(p) }
                message = ("이 행동에는 맥 권한이 필요해요: " + missing.map { $0.koreanName }.joined(separator: ", ")
                           + ". 시스템 설정에서 나초콤보를 켜 주세요.", false)
            }
        }
        render()
    }

    // MARK: detail

    private func detail(for ref: ConnectionsRef) -> ConnectionsDetail? {
        switch ref {
        case let .tool(id):
            return overview?.tools.first { $0.id == id }.map { ConnectionsDetailBuilder.tool($0) }
        case let .connector(id):
            guard let o = overview, let c = o.connections.first(where: { $0.id == id }) else { return nil }
            return ConnectionsDetailBuilder.connector(c, tools: o.tools, info: detailInfo[c.source])
        case let .gadget(g):
            guard let state = gadgets.first(where: { $0.id == g }) else { return nil }
            return ConnectionsDetailBuilder.gadget(state, disabled: host.trust.disabled)
        }
    }

    private func renderDetail(_ ref: ConnectionsRef) {
        guard let d = detail(for: ref) else {
            body.addArrangedSubview(Parts.label("이 항목을 찾지 못했어요. 목록으로 돌아가 새로 불러와 주세요.", color: PetTheme.secondary, width: contentWidth))
            return
        }
        // Title, status, switch.
        let title = Parts.label(d.title, font: PetTheme.title, width: contentWidth - 70, lines: 2)
        let status = Parts.label(d.status, font: PetTheme.caption, color: Parts.toneColor(d.tone), width: contentWidth - 70, lines: 1)
        let titles = Parts.vstack([title, status], spacing: 1)
        titles.setHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        var headViews: [NSView] = [titles]
        switch d.control {
        case .on, .off:
            headViews.append(PetToggle(on: d.control.isOn, label: d.title + " 켜기/끄기") { [weak self] on in self?.toggle(ref, on: on) })
        case .locked:
            let lock = NSImageView(image: PetTheme.symbol("lock.fill", size: PetTokens.Size.icon) ?? NSImage())
            lock.contentTintColor = PetTheme.tertiary
            lock.setAccessibilityLabel("잠김")
            lock.translatesAutoresizingMaskIntoConstraints = false
            headViews.append(lock)
        case let .fixed(reason):
            headViews.append(Parts.label(reason, font: PetTheme.caption, color: PetTheme.tertiary, width: 80, lines: 2))
        }
        let top = Parts.hstack(headViews, spacing: Sp.m)
        top.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        body.addArrangedSubview(top)
        body.addArrangedSubview(Parts.label(d.summary, color: PetTheme.secondary, width: contentWidth))
        if let n = d.notice {
            let attention = d.tone == .attention
            let l = Parts.label(n, font: PetTheme.caption, color: attention ? PetTheme.color(\.warning) : PetTheme.text,
                                width: contentWidth - CGFloat(2 * Sp.m))
            body.addArrangedSubview(Parts.card(l, fill: attention ? PetTheme.color(\.warningSoft) : PetTheme.color(\.surface), width: contentWidth, padding: Sp.m))
        }
        if let reconnect = d.reconnectTitle, case let .connector(id) = ref, let c = overview?.connections.first(where: { $0.id == id }) {
            body.addArrangedSubview(Parts.pill(reconnect, symbol: "arrow.clockwise", color: PetTheme.color(\.onAccent), fill: PetTheme.accent) { [weak self] in
                self?.reconnect(c)
            })
        }
        for f in d.facts { body.addArrangedSubview(factRow(f)) }
        if let scope = d.scope, case let .connector(id) = ref { body.addArrangedSubview(scopeRow(scope, id: id)) }
        if !d.abilitiesTitle.isEmpty {
            body.addArrangedSubview(sectionHeader(d.abilitiesTitle, count: d.abilities.isEmpty ? nil : d.abilities.count))
            if d.abilities.isEmpty { body.addArrangedSubview(Parts.label(d.emptyAbilities, font: PetTheme.caption, color: PetTheme.tertiary, width: contentWidth)) }
            for a in d.abilities { body.addArrangedSubview(abilityRow(a)) }
        }
        if let dis = d.disconnect { body.addArrangedSubview(disconnectArea(dis, ref: ref)) }
    }

    private func factRow(_ f: ConnectionsFact) -> NSView {
        let k = Parts.label(f.label, font: PetTheme.caption, color: PetTheme.tertiary, width: 76, lines: 1)
        let v = Parts.label(f.value, font: PetTheme.body, width: contentWidth - 76 - CGFloat(Sp.s))
        let row = Parts.hstack([k, v], spacing: Sp.s, alignment: .firstBaseline)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func abilityRow(_ a: ConnectionsAbility) -> NSView {
        let reserved: CGFloat = a.isOn == nil ? 0 : 44 + CGFloat(Sp.s)
        let textWidth = contentWidth - CGFloat(2 * Sp.m) - reserved
        var lines: [NSView] = [Parts.label(a.title, width: textWidth)]
        if let n = a.note { lines.append(Parts.label(n, font: PetTheme.caption, color: PetTheme.tertiary, width: textWidth)) }
        let texts = Parts.vstack(lines, spacing: 1)
        texts.setHuggingPriority(NSLayoutConstraint.Priority(200), for: .horizontal)
        var views: [NSView] = [texts]
        if let on = a.isOn {
            views.append(PetToggle(on: on, label: a.title) { [weak self] value in self?.toggleAction(a.id, on: value) })
        }
        let row = Parts.hstack(views, spacing: Sp.s)
        row.widthAnchor.constraint(equalToConstant: contentWidth - CGFloat(2 * Sp.m)).isActive = true
        return Parts.card(row, fill: PetTheme.color(\.surface), width: contentWidth, padding: Sp.m)
    }

    private func scopeRow(_ scope: ConnectionsScopeChoice, id: String) -> NSView {
        let k = Parts.label("권한 범위 바꾸기", font: PetTheme.caption, color: PetTheme.tertiary, width: 100, lines: 1)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = PetTheme.caption
        for l in scope.levels { popup.addItem(withTitle: l.title) }
        if let i = scope.levels.firstIndex(where: { $0.id == scope.selected }) { popup.selectItem(at: i) }
        popup.setAccessibilityLabel("권한 범위")
        let handler = PetScopeHandler(levels: scope.levels.map { $0.id }) { [weak self] level in self?.changeScope(id: id, to: level) }
        popup.target = handler
        popup.action = #selector(PetScopeHandler.picked(_:))
        objc_setAssociatedObject(popup, &PetScopeHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        popup.translatesAutoresizingMaskIntoConstraints = false
        let row = Parts.hstack([k, popup], spacing: Sp.s)
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private func changeScope(id: String, to level: String) {
        guard let c = overview?.connections.first(where: { $0.id == id }), c.scopeLevel != level else { return }
        host.connectionsAPI { [weak self] api in
            guard let api = api else { return }
            api.setScopeLevel(id: id, level: level, version: c.version) { result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success: self.message = ("권한 범위를 바꿨어요.", false); self.reload()
                    case let .failure(f): self.message = (f.koreanMessage, true); self.render()
                    }
                }
            }
        }
    }

    private func disconnectArea(_ dis: ConnectionsDisconnect, ref: ConnectionsRef) -> NSView {
        guard confirmingDisconnect else {
            return Parts.pill(dis.buttonTitle, symbol: "link.badge.plus", color: PetTheme.color(\.danger), fill: PetTheme.color(\.dangerSoft)) { [weak self] in
                self?.confirmingDisconnect = true
                self?.render()
            }
        }
        let width = contentWidth - CGFloat(2 * Sp.m)
        let title = Parts.label(dis.confirmTitle, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold), width: width)
        let text = Parts.label(dis.confirmMessage, font: PetTheme.caption, color: PetTheme.text, width: width)
        let cancel = Parts.pill("취소") { [weak self] in
            self?.confirmingDisconnect = false
            self?.render()
        }
        let ok = Parts.pill(dis.confirmButton, color: PetTheme.color(\.onDanger), fill: PetTheme.color(\.danger)) { [weak self] in self?.disconnect(ref) }
        let buttons = Parts.hstack([cancel, ok], spacing: Sp.s)
        return Parts.card(Parts.vstack([title, text, buttons], spacing: Sp.s), fill: PetTheme.color(\.dangerSoft), width: contentWidth)
    }

    private func disconnect(_ ref: ConnectionsRef) {
        guard case let .connector(id) = ref else { return }
        let name = overview?.connections.first { $0.id == id }?.label ?? "서비스"
        host.connectionsAPI { [weak self] api in
            guard let api = api else {
                DispatchQueue.main.async { self?.message = (ConnectionsFailure.unauthorized.koreanMessage, true); self?.render() }
                return
            }
            api.disconnect(id: id) { result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.confirmingDisconnect = false
                    switch result {
                    case .success:
                        self.screen = .list
                        self.message = ("\(name) 연결을 해제했어요.", false)
                        self.reload()
                    case let .failure(f):
                        self.message = (f.koreanMessage, true)
                        self.render()
                    }
                }
            }
        }
    }

    // MARK: add a service

    func loadCatalog(query q: String) {
        host.connectionsAPI { [weak self] api in
            guard let api = api else {
                DispatchQueue.main.async { self?.catalogError = ConnectionsFailure.unauthorized.koreanMessage; self?.render() }
                return
            }
            api.catalog(query: q) { result in
                DispatchQueue.main.async {
                    guard let self = self, self.screen == .add else { return }
                    switch result {
                    case let .success(rows): self.catalog = rows; self.catalogError = nil
                    case let .failure(f): self.catalogError = f.koreanMessage
                    }
                    self.render()
                }
            }
        }
    }

    private func renderAdd() {
        if let e = catalogError { body.addArrangedSubview(messageBox(e, failed: true)); return }
        guard let rows = catalog else { body.addArrangedSubview(Parts.label("찾는 중…", color: PetTheme.secondary, width: contentWidth)); return }
        if rows.isEmpty {
            body.addArrangedSubview(Parts.label("맞는 서비스가 없어요. 다른 이름으로 찾아 보세요.", color: PetTheme.secondary, width: contentWidth))
            return
        }
        for r in rows {
            var status = r.summary
            var tone = ConnectionsTone.normal
            if r.connected { status = "이미 연결됨"; tone = .off }
            else if case .unsupported = r.plan { status = "맥에서는 안 돼요 · 휴대폰 앱에서 연결"; tone = .off }
            else if status.isEmpty { status = "연결할 수 있어요" }
            let row = ConnectionsRow(ref: .connector(r.source), section: .connectors, title: r.label, status: status, tone: tone,
                                     control: .fixed(r.connected ? "연결됨" : "연결"))
            body.addArrangedSubview(PetConnectionsRowView(row: row, width: contentWidth, onToggle: { _ in }, onOpen: { [weak self] in self?.startConnect(r) }))
        }
    }

    // MARK: connect

    private func reconnect(_ c: ConnectionRow) {
        let row = CatalogRow(source: c.source, label: c.label, summary: "", connectKind: c.connectKind ?? "oauth", supportStatus: "available",
                             supportReason: nil, connected: false)
        startConnect(row)
    }

    func startConnect(_ service: CatalogRow) {
        screen = .connect
        message = nil
        stopPolling()
        switch service.plan {
        case .unsupported:
            connect = ConnectFlow(service: service, progress: .failed(""), attemptID: nil, authorizeURL: nil)
            render()
        case .browser, .appPassword:
            connect = ConnectFlow(service: service, progress: .starting, attemptID: nil, authorizeURL: nil)
            render()
            host.connectionsAPI { [weak self] api in
                guard let api = api else { self?.connectFailed(.unauthorized); return }
                api.begin(source: service.source) { result in
                    DispatchQueue.main.async {
                        guard let self = self, self.screen == .connect, self.connect?.service.source == service.source else { return }
                        switch result {
                        case let .success(info): self.began(info)
                        case let .failure(f): self.connectFailed(f)
                        }
                    }
                }
            }
        }
    }

    private func connectFailed(_ f: ConnectionsFailure) {
        DispatchQueue.main.async {
            self.connect?.progress = .failed(f.koreanMessage)
            self.render()
        }
    }

    private func began(_ info: BeginInfo) {
        guard var flow = connect else { return }
        flow.attemptID = info.attemptID
        flow.authorizeURL = info.authorizeURL
        switch flow.service.plan {
        case .appPassword:
            flow.progress = .needsAppPassword
            connect = flow
        default:
            guard let url = info.authorizeURL else {
                flow.progress = .failed("서비스 동의 주소를 받지 못했어요. 잠시 뒤 다시 시도해 주세요.")
                connect = flow
                render()
                return
            }
            flow.progress = .inBrowser
            connect = flow
            host.openInBrowser(url)
            startPolling()
        }
        render()
    }

    private func startPolling() {
        stopPolling()
        pollCount = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        // Back from the browser: check at once, not at the next tick.
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.poll()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let o = activeObserver { NotificationCenter.default.removeObserver(o); activeObserver = nil }
    }

    /// The completion is what the server says about the attempt, never the fact that the browser was closed.
    func poll() {
        guard screen == .connect, let id = connect?.attemptID, let progress = connect?.progress, !progress.isFinished else { stopPolling(); return }
        pollCount += 1
        if pollCount > 150 {
            connect?.progress = .expired
            stopPolling()
            render()
            return
        }
        host.connectionsAPI { [weak self] api in
            api?.attempt(id: id) { result in
                DispatchQueue.main.async {
                    guard let self = self, self.connect?.attemptID == id, case let .success(info) = result else { return }
                    self.apply(info)
                }
            }
        }
    }

    func apply(_ info: AttemptInfo) {
        let progress = ConnectProgress.from(info)
        // The app password form stays open until the user sends it.
        if connect?.progress == .needsAppPassword, !progress.isFinished, progress != .verifying { return }
        connect?.progress = progress
        if progress.isFinished {
            stopPolling()
            if progress == .done { reload() }
        }
        render()
    }

    private func submitAppPassword() {
        guard let flow = connect, let id = flow.attemptID else { return }
        let email = (emailField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField?.stringValue ?? ""
        guard !email.isEmpty, !password.isEmpty else {
            connect?.progress = .failed("이메일과 앱 비밀번호를 모두 입력해 주세요.")
            render()
            return
        }
        passwordField?.stringValue = ""
        connect?.progress = .verifying
        render()
        host.connectionsAPI { [weak self] api in
            guard let api = api else { self?.connectFailed(.unauthorized); return }
            api.submitAppPassword(attemptID: id, email: email, password: password) { result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success: self.connect?.progress = .done; self.reload()
                    case let .failure(f): self.connect?.progress = .failed(f.koreanMessage)
                    }
                    self.render()
                }
            }
        }
    }

    private func renderConnect() {
        guard let flow = connect else { return }
        let title = Parts.label("\(flow.service.label) 연결", font: PetTheme.title, width: contentWidth, lines: 2)
        body.addArrangedSubview(title)
        if case let .unsupported(reason, alternative) = flow.service.plan {
            let w = contentWidth - CGFloat(2 * Sp.m)
            let heading = Parts.label("이 맥에서는 연결할 수 없어요", font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightSemibold), width: w)
            let why = Parts.label(reason, font: PetTheme.caption, color: PetTheme.text, width: w)
            let alt = Parts.label(alternative, font: PetTheme.body, color: PetTheme.accent, width: w)
            body.addArrangedSubview(Parts.card(Parts.vstack([heading, why, alt], spacing: Sp.s), fill: PetTheme.color(\.warningSoft), width: contentWidth))
            return
        }
        let failed: Bool
        if case .failed = flow.progress { failed = true } else { failed = false }
        let text = flow.progress.text
        if !text.isEmpty {
            body.addArrangedSubview(messageBox(text, failed: failed))
        }
        switch flow.progress {
        case .starting, .verifying:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(spinner)
        case .inBrowser:
            var buttons: [NSView] = []
            if let url = flow.authorizeURL {
                buttons.append(Parts.pill("브라우저 다시 열기", symbol: "safari") { [weak self] in self?.host.openInBrowser(url) })
            }
            buttons.append(Parts.pill("지금 확인") { [weak self] in self?.poll() })
            buttons.append(Parts.pill("취소") { [weak self] in self?.leaveConnect() })
            body.addArrangedSubview(Parts.hstack(buttons, spacing: Sp.s))
        case .needsAppPassword:
            body.addArrangedSubview(appPasswordForm())
        case .done:
            body.addArrangedSubview(Parts.pill("목록으로", color: PetTheme.color(\.onAccent), fill: PetTheme.accent) { [weak self] in self?.goList() })
        case .failed, .canceled, .expired:
            body.addArrangedSubview(Parts.pill("서비스 목록으로") { [weak self] in self?.leaveConnect() })
        }
    }

    private func appPasswordForm() -> NSView {
        let w = contentWidth - CGFloat(2 * Sp.m)
        let help = Parts.label("서비스에서 만든 앱 비밀번호를 입력해 주세요. 입력한 값은 연결을 확인하는 데만 쓰고, 이 앱에 저장하거나 기록에 남기지 않아요.",
                               font: PetTheme.caption, color: PetTheme.secondary, width: w)
        let email = NSTextField()
        email.placeholderString = "이메일 주소"
        email.font = PetTheme.body
        email.setAccessibilityLabel("이메일 주소")
        let password = NSSecureTextField()
        password.placeholderString = "앱 비밀번호"
        password.font = PetTheme.body
        password.setAccessibilityLabel("앱 비밀번호")
        for f in [email, password] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: w).isActive = true
        }
        emailField = email
        passwordField = password
        let send = Parts.pill("연결", color: PetTheme.color(\.onAccent), fill: PetTheme.accent) { [weak self] in self?.submitAppPassword() }
        let cancel = Parts.pill("취소") { [weak self] in self?.leaveConnect() }
        let col = Parts.vstack([help, email, password, Parts.hstack([cancel, send], spacing: Sp.s)], spacing: Sp.s)
        return Parts.card(col, fill: PetTheme.color(\.surface), width: contentWidth)
    }
}

/// Target of the scope popup: tells a closure which level was picked.
final class PetScopeHandler: NSObject {
    static var key: UInt8 = 0
    private let levels: [String]
    private let onPick: (String) -> Void

    init(levels: [String], onPick: @escaping (String) -> Void) {
        self.levels = levels
        self.onPick = onPick
    }

    @objc func picked(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard levels.indices.contains(i) else { return }
        onPick(levels[i])
    }
}
