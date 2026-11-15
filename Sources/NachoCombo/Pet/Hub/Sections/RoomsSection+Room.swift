import AppKit
import NachoComboCore

/// 방 하나: 읽기 전용 기록(`/rooms/{id}/history`), 이름 바꾸기·보관·삭제(B7), 미디어·파일·링크 모아보기(B12).
extension RoomsSection {
    func openRoom(_ id: String) {
        guard let client = ctx.client else { showFailure("로그인이 필요해요."); return }
        state.show(.loading)
        call(client, { HubRoomsAPI.getRequest($0, id: id, bearer: $1) }) { [self] result in
            onMain {
                switch result {
                case let .failure(e): self.showFailure(e.text)
                case let .success(resp):
                    switch HubRoomsAPI.decodeRoom(resp) {
                    case let .failure(e): self.showFailure(e.text)
                    case let .success(room):
                        self.renameVisible = false
                        self.showRoom(room, tab: .history)
                    }
                }
            }
        }
    }

    /// 화면 그리기 + 탭 내용 불러오기.
    func showRoom(_ room: HubRoom, tab: RoomTab) {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        present(screen(header: roomHeader(room, tab: tab), body: body))
        setBody(body, to: emptyNote("불러오는 중…"))
        loadTab(room, tab: tab, host: body, next: nil, olderThan: nil, existing: [])
    }

    func setBody(_ host: NSView, to view: NSView) {
        for v in host.subviews { v.removeFromSuperview() }
        HubKit.pin(view, in: host)
    }

    func roomHeader(_ room: HubRoom, tab: RoomTab) -> [NSView] {
        let back = HubKit.secondaryButton("목록으로", symbol: "chevron.left") { [self] in load() }
        var sub = RoomsSection.kindLabel(room)
        if room.stored { sub += " · 보관한 대화" }
        let title = HubKit.label(room.displayTitle, font: PetTheme.title)
        let info = HubKit.label(sub, font: PetTheme.caption, color: PetTheme.secondary)
        var actions: [NSView] = []
        if room.canRename {
            actions.append(HubKit.secondaryButton("이름 바꾸기", symbol: "pencil") { [self] in
                renameVisible.toggle()
                showRoom(room, tab: tab)
            })
        }
        actions.append(HubKit.secondaryButton(room.stored ? "꺼내기" : "보관", symbol: room.stored ? "tray.and.arrow.up" : "tray.and.arrow.down") { [self] in
            setStored(room, !room.stored)
        })
        if room.canDelete {
            actions.append(HubKit.primaryButton("삭제", symbol: "trash", danger: true) { [self] in confirmDelete(room) })
        }
        // 대화창에서 이어 말하기: 자리만 만든다. 대화창이 여러 방을 다루는 일은 U10이 한다.
        let cont = HubKit.secondaryButton("대화창에서 이어 말하기", symbol: "arrow.up.right.square") { [self] in HubRooms.openInChat(roomID: room.id) }
        cont.isEnabled = HubRooms.continueInChatEnabled
        cont.alphaValue = HubRooms.continueInChatEnabled ? 1 : 0.4
        cont.toolTip = "곧 열려요. 대화창에서 여러 방을 다루는 일은 다음 단계에서 해요."
        actions.append(cont)
        var views: [NSView] = [back, title, info, buttonRow(actions)]
        if renameVisible && room.canRename { views.append(renameForm(room)) }
        views.append(buttonRow([
            tabButton("기록", selected: tab == .history) { [self] in showRoom(room, tab: .history) },
            tabButton("사진·동영상", selected: tab == .photos) { [self] in showRoom(room, tab: .photos) },
            tabButton("파일", selected: tab == .files) { [self] in showRoom(room, tab: .files) },
            tabButton("링크", selected: tab == .links) { [self] in showRoom(room, tab: .links) },
        ]))
        return views
    }

    // MARK: 이름 바꾸기 (B7)

    func renameForm(_ room: HubRoom) -> NSView {
        let form = HubFormField(title: "대화 이름", placeholder: "40자까지", validator: { v in
            if case let .failure(e) = HubRoomsAPI.normalizeTitle(v) { return e.text }
            return nil
        })
        form.field.stringValue = room.title ?? ""
        let save = HubKit.primaryButton("저장") { [self] in
            guard form.validate(), case let .success(t) = HubRoomsAPI.normalizeTitle(form.field.stringValue) else { return }
            rename(room, to: t, form: form)
        }
        form.setContentHuggingPriority(.defaultLow, for: .horizontal)
        save.setContentHuggingPriority(.required, for: .horizontal)
        return HubKit.hstack([form, save])
    }

    func rename(_ room: HubRoom, to title: String, form: HubFormField?) {
        guard let client = ctx.client else { return }
        let toast = ctx.toast
        call(client, { HubRoomsAPI.renameRequest($0, id: room.id, title: title, version: room.version, bearer: $1) }) { [self] result in
            onMain {
                switch result {
                case let .failure(e):
                    toast(e.text, true)
                    if e.isVersionConflict || e.isNotFound { self.openRoom(room.id) } else { form?.showServerError(e.text) }
                case let .success(resp):
                    self.renameVisible = false
                    toast("이름을 바꿨어요.", false)
                    switch HubRoomsAPI.decodeRoom(resp) {
                    case let .success(updated): self.showRoom(updated, tab: .history)
                    case .failure: self.openRoom(room.id)
                    }
                }
            }
        }
    }

    // MARK: 보관 (B7)

    func setStored(_ room: HubRoom, _ stored: Bool) {
        guard let client = ctx.client else { return }
        let toast = ctx.toast
        call(client, { HubRoomsAPI.storeRequest($0, id: room.id, stored: stored, version: room.version, bearer: $1) }) { [self] result in
            onMain {
                switch result {
                case let .failure(e):
                    toast(e.text, true)
                    if e.isVersionConflict || e.isNotFound { self.openRoom(room.id) }
                case .success:
                    toast(stored ? "보관했어요." : "꺼냈어요.", false)
                    self.load()
                }
            }
        }
    }

    // MARK: 삭제 (B7, 이중 확인)

    /// 두 번 거치는 확인창의 문구(시험·캡처가 같은 문구를 쓴다).
    func deleteSteps(_ room: HubRoom) -> [HubConfirmStep] {
        let body: String
        switch room.kind {
        case "group": body = "방장이라 이 방이 모든 사람에게서 지워져요. 되돌릴 수 없어요."
        case "direct": body = "이 대화의 내용이 모두 지워져요. 되돌릴 수 없어요."
        default: body = "이 대화를 목록에서 지워요. 되돌릴 수 없어요."
        }
        return [
            HubConfirmStep(title: "이 대화를 삭제할까요?", message: "‘\(room.displayTitle)’\n\(body)", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 삭제할까요?", message: "한 번 더 확인해요. 지우면 되돌릴 수 없어요.", confirmTitle: "삭제"),
        ]
    }

    func confirmDelete(_ room: HubRoom) {
        ctx.confirm(deleteSteps(room)) { [self] in deleteRoom(room) }
    }

    func deleteRoom(_ room: HubRoom) {
        guard let client = ctx.client else { return }
        let toast = ctx.toast
        call(client, { HubRoomsAPI.deleteRequest($0, id: room.id, bearer: $1) }) { [self] result in
            onMain {
                switch result {
                case let .failure(e):
                    // 이미 지워졌으면(404) 목록을 새로 불러오고, 그 밖의 오류(403·409)는 서버 문구 그대로 알린다.
                    toast(e.isNotFound ? "이미 지워진 대화예요." : e.text, true)
                    if e.isNotFound { self.load() }
                case .success:
                    toast("대화를 지웠어요.", false)
                    self.load()
                }
            }
        }
    }

    // MARK: 탭 내용

    func emptyText(_ tab: RoomTab) -> String {
        switch tab {
        case .history: return "아직 대화가 없어요."
        case .photos: return "아직 사진이나 동영상이 없어요."
        case .files: return "아직 파일이 없어요."
        case .links: return "아직 링크가 없어요."
        }
    }

    func loadTab(_ room: HubRoom, tab: RoomTab, host: NSView, next: [(String, String)]?, olderThan: Int?, existing: [NSView]) {
        guard let client = ctx.client else { return }
        let more: ([NSView], Bool, @escaping () -> Void) -> Void = { [self] rows, hasMore, loadMore in
            let all = existing + rows
            if all.isEmpty { setBody(host, to: emptyNote(emptyText(tab))); return }
            let list = HubListView(frame: .zero)
            list.setRows(all, hasMore: hasMore)
            list.onLoadMore = loadMore
            setBody(host, to: list)
        }
        let fail: (PetAPIError) -> Void = { [self] e in
            if existing.isEmpty { setBody(host, to: emptyNote(e.text)) } else { ctx.toast(e.text, true) }
        }
        switch tab {
        case .history:
            call(client, { HubRoomsAPI.historyRequest($0, id: room.id, beforeSeq: olderThan, limit: HubRoomsAPI.pageSize, bearer: $1) }) { [self] result in
                onMain {
                    switch self.decode(result, HubRoomsAPI.decodeHistory) {
                    case let .failure(e): fail(e)
                    case let .success(h):
                        // 서버는 오래된 것부터 준다. 최근 대화를 위에 두고, 「더 보기」는 더 오래된 쪽을 부른다.
                        let rows: [NSView] = h.messages.reversed().map { self.messageRow($0, room: room) }
                        let oldest = h.messages.first?.seq
                        more(rows, h.hasMore && oldest != nil) {
                            self.loadTab(room, tab: tab, host: host, next: nil, olderThan: oldest, existing: existing + rows)
                        }
                    }
                }
            }
        case .photos, .files:
            let kind: HubRoomMediaKind = tab == .photos ? .photos : .files
            call(client, { HubRoomsAPI.roomMediaRequest($0, id: room.id, kind: kind, next: next, bearer: $1) }) { [self] result in
                onMain {
                    switch self.decode(result, { HubRoomsAPI.decodeMedia($0, kind: kind) }) {
                    case let .failure(e): fail(e)
                    case let .success(p):
                        let rows: [NSView] = p.items.map { self.mediaRow($0, room: room) }
                        more(rows, p.next != nil) {
                            self.loadTab(room, tab: tab, host: host, next: p.next, olderThan: nil, existing: existing + rows)
                        }
                    }
                }
            }
        case .links:
            call(client, { HubRoomsAPI.roomMediaRequest($0, id: room.id, kind: .links, next: next, bearer: $1) }) { [self] result in
                onMain {
                    switch self.decode(result, HubRoomsAPI.decodeLinks) {
                    case let .failure(e): fail(e)
                    case let .success(p):
                        let rows: [NSView] = p.items.map { self.linkRow($0) }
                        more(rows, p.next != nil) {
                            self.loadTab(room, tab: tab, host: host, next: p.next, olderThan: nil, existing: existing + rows)
                        }
                    }
                }
            }
        }
    }

    func decode<T>(_ result: Result<PetHTTPResponse, PetAPIError>, _ f: (PetHTTPResponse) -> Result<T, PetAPIError>) -> Result<T, PetAPIError> {
        switch result {
        case let .failure(e): return .failure(e)
        case let .success(resp): return f(resp)
        }
    }

    func messageRow(_ m: HubMessage, room: HubRoom) -> HubRow {
        let who = m.isMine ? "나" : (m.senderName ?? "나초")
        var lines: [String] = []
        if !m.text.isEmpty { lines.append(m.text) }
        for a in m.attachments { lines.append("첨부: " + (a.deleted ? "지운 파일" : (a.name ?? "파일"))) }
        if let p = m.pageRef { lines.append("문서: \(p.title)") }
        let row = HubRow(title: who, subtitle: lines.joined(separator: "\n"), trailing: HubFormat.date(m.createdAt),
                         symbol: m.isMine ? "person.crop.circle" : "sparkles")
        if let p = m.pageRef {
            row.onClick = { [self] in openPage(p.id, title: p.title, back: { self.showRoom(room, tab: .history) }) }
        } else if let a = m.attachments.first(where: { !$0.deleted }) {
            row.onClick = { [self] in openMedia(a, room: room, tab: .history) }
        }
        return row
    }

    func mediaRow(_ a: HubMediaItem, room: HubRoom) -> HubRow {
        let tab: RoomTab = a.isImage || a.kind == "video" ? .photos : .files
        var sub = [a.mime, RoomsSection.sizeText(a.bytes)].compactMap { $0 }.joined(separator: " · ")
        if sub.isEmpty { sub = a.kind }
        let row = HubRow(title: a.name ?? "이름 없는 파일", subtitle: sub, symbol: tab == .photos ? "photo" : "doc")
        row.onClick = { [self] in openMedia(a, room: room, tab: tab) }
        return row
    }

    func linkRow(_ l: HubLinkItem) -> HubRow {
        let row = HubRow(title: l.url, subtitle: nil, symbol: "link")
        row.onClick = {
            if let u = URL(string: l.url) { NSWorkspace.shared.open(u) }
        }
        return row
    }
}
