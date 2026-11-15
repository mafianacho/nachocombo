import AppKit
import NachoComboCore

/// 그룹·요청 섹션의 화면들: 만들기 · 설정(구성원·삭제) · 친구 초대 · 받은 초대 · 대화 요청 · 요청 보내기.
extension GroupsSection {
    /// 나초 고르기 줄(켜면 구성원).
    private func agentRows(_ agents: [HubAgentChoice], selected: Set<String>) -> [(HubAgentChoice, HubSwitchRow)] {
        agents.filter { $0.isActive }.map { a in (a, HubSwitchRow(title: a.name, isOn: selected.contains(a.id))) }
    }

    private func managerPopup(_ agents: [HubAgentChoice], current: String?) -> (NSPopUpButton, [String?]) {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.translatesAutoresizingMaskIntoConstraints = false
        var ids: [String?] = [nil]
        pop.addItem(withTitle: "정하지 않음")
        for a in agents where a.isActive {
            pop.addItem(withTitle: a.name)
            ids.append(a.id)
        }
        if let c = current, let i = ids.firstIndex(where: { $0 == c }) { pop.selectItem(at: i) }
        return (pop, ids)
    }

    // MARK: 만들기 (B17)

    func showCreate() {
        state.show(.loading)
        createKey = HubAPI.newIdempotencyKey()
        call({ HubGroups.agents($0, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.object($0) }) {
            case let .failure(e): self.state.show(.failed(HubGroups.errorText(e)))
            case let .success(o): self.drawCreate(HubGroups.agents(o), max: HubGroups.maxGroupMembers(o))
            }
        }
    }

    func drawCreate(_ agents: [HubAgentChoice], max: Int?) {
        let title = HubFormField(title: "그룹 이름", placeholder: "비우면 나초 이름을 이어 붙여요 (40자까지)", validator: { HubGroups.validateTitle($0, required: false) })
        let rows = agentRows(agents, selected: [])
        let (pop, popIDs) = managerPopup(agents, current: nil)
        let err = errorLabel()
        present(page("그룹 만들기", back: true) { stack in
            stack.addArrangedSubview(title)
            HubKit.fill(stack, [title])
            let h = sectionLabel(max.map { "함께할 나초 (2~\($0)명)" } ?? "함께할 나초 (2명 이상)")
            stack.addArrangedSubview(h)
            HubKit.fill(stack, [h])
            if rows.isEmpty {
                let l = HubKit.label("쓸 수 있는 나초가 없어요. 나초가 쉬고 있는지 확인해 주세요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
            }
            for (_, r) in rows { stack.addArrangedSubview(r); HubKit.fill(stack, [r]) }
            let mh = HubKit.label("진행을 맡을 나초 (고른 나초 중)", font: PetTheme.caption, color: PetTheme.secondary)
            stack.addArrangedSubview(mh)
            stack.addArrangedSubview(pop)
            stack.addArrangedSubview(err)
            HubKit.fill(stack, [mh, err])
            stack.addArrangedSubview(HubKit.primaryButton("만들기", symbol: "checkmark") { [weak self] in
                guard let self = self else { return }
                let picked = rows.filter { $0.1.toggle.state == .on }.map { $0.0.id }
                let manager = popIDs[pop.indexOfSelectedItem]
                var problem: String? = HubGroups.validateMemberCount(picked.count, max: max)
                if problem == nil, let m = manager, !picked.contains(m) { problem = "진행을 맡을 나초는 고른 나초 중에서 골라 주세요." }
                let titleOK = title.validate()
                self.setError(err, problem)
                guard titleOK, problem == nil else { return }
                let key = self.createKey
                let name = title.value
                self.call({ HubGroups.createGroup($0, title: name, memberAgentIDs: picked, managerAgentID: manager, idempotencyKey: key, bearer: $1) }) { r in
                    switch r.flatMap({ HubAPI.empty($0) }) {
                    case let .failure(e):
                        self.setError(err, HubGroups.errorText(e))
                        self.ctx.toast(HubGroups.errorText(e), true)
                    case .success:
                        self.ctx.toast("그룹을 만들었어요.", false)
                        self.showHome()
                    }
                }
            })
        })
    }

    // MARK: 설정·구성원·삭제 (B17)

    func showSettings(_ g: HubGroupRoom) {
        guard g.isAgentGroup else { drawMixedSettings(g); return }
        state.show(.loading)
        var room: Result<HubGroupRoom, PetAPIError>?
        var agentList: Result<HubObject, PetAPIError>?
        let wait = DispatchGroup()
        wait.enter()
        call({ HubGroups.getGroup($0, g.id, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.object($0) }) {
            case let .failure(e): room = .failure(e)
            case let .success(o):
                if let parsed = HubGroups.group(o) { room = .success(parsed) } else { room = .failure(PetAPIError.badResponse) }
            }
            wait.leave()
        }
        wait.enter()
        call({ HubGroups.agents($0, bearer: $1) }) { r in agentList = r.flatMap { HubAPI.object($0) }; wait.leave() }
        wait.notify(queue: .main) {
            switch (room, agentList) {
            case let (.failure(e)?, _), let (_, .failure(e)?):
                self.state.show(.failed(HubGroups.errorText(e)))
                self.ctx.toast(HubGroups.errorText(e), true)
            case let (.success(fresh)?, .success(list)?):
                self.drawSettings(fresh, agents: HubGroups.agents(list), max: HubGroups.maxGroupMembers(list))
            default:
                self.state.show(.failed(PetAPIError.badResponse.text))
            }
        }
    }

    func drawSettings(_ g: HubGroupRoom, agents: [HubAgentChoice], max: Int?) {
        let title = HubFormField(title: "그룹 이름", placeholder: "1~40자", validator: { HubGroups.validateTitle($0, required: true) })
        title.field.stringValue = g.title
        let rows = agentRows(agents, selected: Set(g.memberAgentIDs))
        let (pop, popIDs) = managerPopup(agents, current: g.managerAgentID)
        let mute = HubSwitchRow(title: "알림 끄기", detail: "이 그룹의 새 소식을 조용히 받아요.", isOn: g.muted)
        let err = errorLabel()
        present(page(g.title.isEmpty ? "그룹 설정" : g.title, back: true) { stack in
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(mute)
            HubKit.fill(stack, [title, mute])
            let h = sectionLabel("구성원 나초")
            stack.addArrangedSubview(h)
            HubKit.fill(stack, [h])
            if g.hasActiveRun {
                let l = HubKit.label("진행 중인 단톡 일이 있어 구성원과 진행 맡기는 바꿀 수 없어요. 일이 끝난 뒤에 바꿔 주세요.", font: PetTheme.caption, color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
                for (_, r) in rows { r.toggle.isEnabled = false }
                pop.isEnabled = false
            }
            for (_, r) in rows { stack.addArrangedSubview(r); HubKit.fill(stack, [r]) }
            let mh = HubKit.label("진행을 맡을 나초", font: PetTheme.caption, color: PetTheme.secondary)
            stack.addArrangedSubview(mh)
            stack.addArrangedSubview(pop)
            stack.addArrangedSubview(err)
            HubKit.fill(stack, [mh, err])
            let save = HubKit.primaryButton("저장", symbol: "checkmark") { [weak self] in
                guard let self = self else { return }
                let picked = rows.filter { $0.1.toggle.state == .on }.map { $0.0.id }
                let manager = popIDs[pop.indexOfSelectedItem]
                let membersChanged = Set(picked) != Set(g.memberAgentIDs)
                let managerChanged = manager != g.managerAgentID
                let titleChanged = title.value != g.title
                let muteChanged = (mute.toggle.state == .on) != g.muted
                var problem: String?
                if membersChanged { problem = HubGroups.validateMemberCount(picked.count, max: max) }
                if problem == nil, let m = manager, !picked.contains(m) { problem = "진행을 맡을 나초는 구성원 중에서 골라 주세요." }
                let titleOK = title.validate()
                self.setError(err, problem)
                guard titleOK, problem == nil else { return }
                guard titleChanged || membersChanged || managerChanged || muteChanged else { self.ctx.toast("바뀐 게 없어요.", false); return }
                let muted = mute.toggle.state == .on
                self.call({ HubGroups.updateGroup($0, g.id, title: titleChanged ? title.value : nil, memberAgentIDs: membersChanged ? picked : nil,
                                                  managerAgentID: managerChanged ? manager : nil, clearManager: managerChanged && manager == nil,
                                                  muted: muteChanged ? muted : nil, expectedVersion: g.version, bearer: $1) }) { r in
                    switch r.flatMap({ HubAPI.empty($0) }) {
                    case let .failure(e): self.fail(e, reload: { self.showSettings(g) })
                    case .success:
                        self.ctx.toast("저장했어요.", false)
                        self.showHome()
                    }
                }
            }
            let del = HubKit.secondaryButton("그룹 지우기", symbol: "trash") { [weak self] in self?.confirmDelete(g) }
            del.isEnabled = !g.hasActiveRun
            stack.addArrangedSubview(HubKit.hstack([save, del]))
        })
    }

    /// 되돌릴 수 없는 동작: 확인창을 두 번 거친다.
    func confirmDelete(_ g: HubGroupRoom) {
        if g.hasActiveRun { ctx.toast("진행 중인 단톡 일을 먼저 끝내 주세요.", true); return }
        ctx.confirm([
            HubConfirmStep(title: "이 그룹을 지울까요?", message: "「\(g.title)」 방이 사라져요. 방에서 나눈 대화는 다시 볼 수 없고, 나초의 기억과 문서는 남아요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "한 번 더 확인해요. 지운 그룹은 되돌릴 수 없어요.", confirmTitle: "지우기"),
        ]) {
            self.call({ HubGroups.deleteGroup($0, g.id, bearer: $1) }) { r in
                switch r.flatMap({ HubAPI.empty($0) }) {
                case let .failure(e): self.fail(e)
                case .success:
                    self.ctx.toast("그룹을 지웠어요.", false)
                    self.showHome()
                }
            }
        }
    }

    // MARK: 사람+나초 방 관리 · 친구 초대 (B17)

    func drawMixedSettings(_ g: HubGroupRoom) {
        present(page(g.title.isEmpty ? "그룹" : g.title, back: true) { stack in
            let l = HubKit.label("사람과 나초가 함께 있는 방이에요. 친구는 초대를 수락해야 들어오고, 내 나초는 바로 더할 수 있어요.", color: PetTheme.secondary)
            stack.addArrangedSubview(l)
            HubKit.fill(stack, [l])
            stack.addArrangedSubview(HubKit.hstack([
                HubKit.primaryButton("친구 초대", symbol: "person.badge.plus") { [weak self] in self?.showInvite(g) },
                HubKit.secondaryButton("내 나초 더하기", symbol: "plus") { [weak self] in self?.showAddAgent(g) },
            ]))
        })
    }

    func showInvite(_ g: HubGroupRoom) {
        state.show(.loading)
        inviteKey = HubAPI.newIdempotencyKey()
        call({ HubGroups.friends($0, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.object($0) }) {
            case let .failure(e): self.state.show(.failed(HubGroups.errorText(e)))
            case let .success(o): self.drawInvite(g, friends: HubGroups.friends(o))
            }
        }
    }

    func drawInvite(_ g: HubGroupRoom, friends: [HubFriend]) {
        let rows = friends.map { ($0, HubSwitchRow(title: $0.name, isOn: false)) }
        let err = errorLabel()
        present(page("친구 초대 · \(g.title)", back: true) { stack in
            let h = sectionLabel("초대할 친구 (1~\(HubGroups.inviteMax)명)")
            stack.addArrangedSubview(h)
            HubKit.fill(stack, [h])
            if rows.isEmpty {
                let l = HubKit.label("초대할 수 있는 친구가 없어요. 친구가 먼저 있어야 해요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
            }
            for (_, r) in rows { stack.addArrangedSubview(r); HubKit.fill(stack, [r]) }
            stack.addArrangedSubview(err)
            HubKit.fill(stack, [err])
            stack.addArrangedSubview(HubKit.primaryButton("초대 보내기", symbol: "paperplane") { [weak self] in
                guard let self = self else { return }
                let ids = rows.filter { $0.1.toggle.state == .on }.map { $0.0.userID }
                let problem = HubGroups.validateInviteCount(ids.count)
                self.setError(err, problem)
                guard problem == nil else { return }
                let key = self.inviteKey
                self.call({ HubGroups.invite($0, g.id, userIDs: ids, idempotencyKey: key, bearer: $1) }) { r in
                    switch r.flatMap({ HubAPI.empty($0) }) {
                    case let .failure(e):
                        self.setError(err, HubGroups.errorText(e))
                        self.ctx.toast(HubGroups.errorText(e), true)
                    case .success:
                        self.ctx.toast("\(ids.count)명에게 초대를 보냈어요.", false)
                        self.showHome()
                    }
                }
            })
        })
    }

    func showAddAgent(_ g: HubGroupRoom) {
        state.show(.loading)
        call({ HubGroups.agents($0, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.object($0) }) {
            case let .failure(e): self.state.show(.failed(HubGroups.errorText(e)))
            case let .success(o): self.drawAddAgent(g, agents: HubGroups.agents(o).filter { $0.isActive })
            }
        }
    }

    func drawAddAgent(_ g: HubGroupRoom, agents: [HubAgentChoice]) {
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.translatesAutoresizingMaskIntoConstraints = false
        for a in agents { pop.addItem(withTitle: a.name) }
        present(page("내 나초 더하기 · \(g.title)", back: true) { stack in
            if agents.isEmpty {
                let l = HubKit.label("쓸 수 있는 나초가 없어요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
                return
            }
            stack.addArrangedSubview(pop)
            stack.addArrangedSubview(HubKit.primaryButton("더하기", symbol: "plus") { [weak self] in
                guard let self = self, pop.indexOfSelectedItem >= 0, pop.indexOfSelectedItem < agents.count else { return }
                let id = agents[pop.indexOfSelectedItem].id
                self.call({ HubGroups.addMember($0, g.id, agentID: id, bearer: $1) }) { r in
                    switch r.flatMap({ HubAPI.empty($0) }) {
                    case let .failure(e): self.fail(e)
                    case .success:
                        self.ctx.toast("나초를 더했어요.", false)
                        self.showHome()
                    }
                }
            })
        })
    }

    // MARK: 받은 초대 (B17)

    func showInvitations() { drawInvitations() }

    func drawInvitations() {
        present(page("받은 초대", back: true) { stack in
            if invitations.isEmpty {
                let l = HubKit.label("받은 초대가 없어요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
            }
            for inv in invitations {
                var lines = ["\(inv.inviterName)님의 초대"]
                if !inv.memberNames.isEmpty { lines.append("구성원: " + inv.memberNames.joined(separator: ", ")) }
                if inv.userCount + inv.agentCount > 0 { lines.append("사람 \(inv.userCount) · 나초 \(inv.agentCount)") }
                if let d = HubFormat.date(inv.expiresAt) { lines.append("\(d)까지") }
                lines.append(inv.statusText)
                var buttons: [NSView] = []
                if inv.canAnswer {
                    buttons.append(HubKit.primaryButton("수락") { [weak self] in self?.acceptInvitation(inv) })
                    buttons.append(HubKit.secondaryButton("거절") { [weak self] in self?.declineInvitation(inv, block: false) })
                    buttons.append(HubKit.secondaryButton("거절하고 차단") { [weak self] in self?.declineInvitation(inv, block: true) })
                }
                let c = card(title: inv.roomTitle.isEmpty ? "이름 없는 방" : inv.roomTitle, lines: lines, buttons: buttons)
                stack.addArrangedSubview(c)
                HubKit.fill(stack, [c])
            }
            if let next = invitationsNext {
                stack.addArrangedSubview(HubKit.secondaryButton("더 보기") { [weak self] in self?.moreInvitations(next) })
            }
        })
    }

    func moreInvitations(_ q: [(String, String)]) {
        call({ HubGroups.listInvitations($0, query: q, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.page($0) }) {
            case let .failure(e): self.fail(e)
            case let .success(p):
                self.invitations += HubGroups.invitations(p.items)
                self.invitationsNext = p.nextQuery
                self.drawInvitations()
            }
        }
    }

    /// 수락 → 받은 목록에서 빠진다. 열린 방은 U3(`openInChat`)가 들어온 뒤 연결한다.
    func acceptInvitation(_ inv: HubInvitation) {
        call({ HubGroups.acceptInvitation($0, inv.id, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.empty($0) }) {
            case let .failure(e):
                self.fail(e)
                if e.isNotFound || ["room_full", "invite_expired", "invite_cancelled", "invite_handled", "room_deleted", "conflict"].contains(e.code ?? "") { self.refreshInvitationsAfterFailure() }
            case .success:
                self.invitations = HubGroups.removing(invitationID: inv.id, from: self.invitations)
                self.ctx.toast("초대를 수락했어요. 「\(inv.roomTitle)」에 들어왔어요.", false)
                self.drawInvitations()
            }
        }
    }

    /// 거절(멱등). 「거절하고 차단」은 차단까지 하므로 확인창을 두 번 거친다.
    func declineInvitation(_ inv: HubInvitation, block: Bool) {
        let run: () -> Void = {
            self.call({ HubGroups.declineInvitation($0, inv.id, block: block, bearer: $1) }) { r in
                switch r.flatMap({ HubAPI.empty($0) }) {
                case let .failure(e): self.fail(e)
                case .success:
                    self.invitations = HubGroups.removing(invitationID: inv.id, from: self.invitations)
                    self.ctx.toast(block ? "거절하고 \(inv.inviterName)님을 차단했어요." : "초대를 거절했어요.", false)
                    self.drawInvitations()
                }
            }
        }
        if block {
            ctx.confirm([
                HubConfirmStep(title: "거절하고 차단할까요?", message: "\(inv.inviterName)님의 초대를 거절하고 이 사람을 차단해요. 서로 연락할 수 없게 돼요.", confirmTitle: "계속"),
                HubConfirmStep(title: "정말 차단할까요?", message: "한 번 더 확인해요. 차단은 친구 목록에서 풀 수 있어요.", confirmTitle: "거절하고 차단"),
            ], run)
        } else {
            run()
        }
    }

    private func refreshInvitationsAfterFailure() {
        call({ HubGroups.listInvitations($0, query: [], bearer: $1) }) { r in
            if case let .success(p) = r.flatMap({ HubAPI.page($0) }) {
                self.invitations = HubGroups.invitations(p.items)
                self.invitationsNext = p.nextQuery
                self.drawInvitations()
            }
        }
    }

    // MARK: 대화 요청 (B18)

    func showRequests() { drawRequests() }

    func drawRequests() {
        present(page("대화 요청", back: true) { stack in
            let note = HubKit.label("모르는 사람이 보낸 대화 요청이에요. 수락하면 서로 대화할 수 있어요.", font: PetTheme.caption, color: PetTheme.secondary)
            stack.addArrangedSubview(note)
            HubKit.fill(stack, [note])
            if requests.isEmpty {
                let l = HubKit.label("답할 대화 요청이 없어요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
            }
            for req in requests {
                let c = card(title: req.peerName, lines: ["대화를 요청했어요."], buttons: [
                    HubKit.primaryButton("수락") { [weak self] in self?.acceptRequest(req) },
                    HubKit.secondaryButton("거절") { [weak self] in self?.declineRequest(req) },
                ])
                stack.addArrangedSubview(c)
                HubKit.fill(stack, [c])
            }
            if let next = requestsNext {
                stack.addArrangedSubview(HubKit.secondaryButton("더 보기") { [weak self] in self?.moreRequests(next) })
            }
        })
    }

    func moreRequests(_ q: [(String, String)]) {
        call({ HubGroups.listRequestRooms($0, query: q, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.page($0) }) {
            case let .failure(e): self.fail(e)
            case let .success(p):
                self.requests += HubGroups.incomingRequests(p.items)
                self.requestsNext = p.nextQuery
                self.drawRequests()
            }
        }
    }

    func acceptRequest(_ req: HubIncomingRequest) {
        call({ HubGroups.acceptRequest($0, req.roomID, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.empty($0) }) {
            case let .failure(e):
                self.fail(e)
                if e.code == "conflict" || e.isNotFound { self.requests.removeAll { $0.roomID == req.roomID }; self.drawRequests() }
            case .success:
                self.requests.removeAll { $0.roomID == req.roomID }
                self.ctx.toast("\(req.peerName)님의 대화 요청을 수락했어요.", false)
                self.drawRequests()
            }
        }
    }

    /// 거절하면 내 쪽 방이 지워진다(상대에게는 알리지 않는다). 되돌릴 수 없어 확인창을 두 번 거친다.
    func declineRequest(_ req: HubIncomingRequest) {
        ctx.confirm([
            HubConfirmStep(title: "대화 요청을 거절할까요?", message: "\(req.peerName)님의 요청과 보낸 메시지가 내 쪽에서 사라져요. 상대에게는 알리지 않아요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 거절할까요?", message: "한 번 더 확인해요. 거절하면 되돌릴 수 없어요.", confirmTitle: "거절"),
        ]) {
            self.call({ HubGroups.declineRequest($0, req.roomID, bearer: $1) }) { r in
                switch r.flatMap({ HubAPI.empty($0) }) {
                case let .failure(e): self.fail(e)
                case .success:
                    self.requests.removeAll { $0.roomID == req.roomID }
                    self.ctx.toast("대화 요청을 거절했어요.", false)
                    self.drawRequests()
                }
            }
        }
    }

    // MARK: 요청 보내기 (B18)

    func showSendRequest() {
        state.show(.loading)
        requestKey = HubAPI.newIdempotencyKey()
        call({ HubGroups.friends($0, bearer: $1) }) { r in
            switch r.flatMap({ HubAPI.object($0) }) {
            case let .failure(e): self.state.show(.failed(HubGroups.errorText(e)))
            case let .success(o): self.drawSendRequest(HubGroups.suggestions(o))
            }
        }
    }

    func drawSendRequest(_ people: [HubFriend]) {
        let text = HubFormField(title: "첫 메시지", placeholder: "1000자까지", validator: { HubGroups.validateRequestText($0) })
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.translatesAutoresizingMaskIntoConstraints = false
        for p in people { pop.addItem(withTitle: p.name) }
        let err = errorLabel()
        present(page("대화 요청 보내기", back: true) { stack in
            if people.isEmpty {
                let l = HubKit.label("요청을 보낼 만한 사람이 아직 없어요. 친구는 요청 없이 바로 대화할 수 있어요.", color: PetTheme.secondary)
                stack.addArrangedSubview(l)
                HubKit.fill(stack, [l])
                return
            }
            let h = HubKit.label("받는 사람", font: PetTheme.caption, color: PetTheme.secondary)
            stack.addArrangedSubview(h)
            stack.addArrangedSubview(pop)
            stack.addArrangedSubview(text)
            stack.addArrangedSubview(err)
            HubKit.fill(stack, [h, text, err])
            stack.addArrangedSubview(HubKit.primaryButton("요청 보내기", symbol: "paperplane") { [weak self] in
                guard let self = self, pop.indexOfSelectedItem >= 0, pop.indexOfSelectedItem < people.count else { return }
                guard text.validate() else { return }
                let target = people[pop.indexOfSelectedItem]
                let body = text.value
                let key = self.requestKey
                self.call({ HubGroups.sendRequest($0, userID: target.userID, text: body, idempotencyKey: key, bearer: $1) }) { r in
                    switch r.flatMap({ HubAPI.empty($0) }) {
                    case let .failure(e):
                        self.setError(err, HubGroups.errorText(e))
                        self.ctx.toast(HubGroups.errorText(e), true)
                    case .success:
                        self.ctx.toast("\(target.name)님에게 대화 요청을 보냈어요.", false)
                        self.showHome()
                    }
                }
            })
        })
    }
}
