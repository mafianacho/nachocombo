import AppKit
import NachoComboCore

// 친구 섹션: 친구 찾기(G1)·상대 프로필(F5)·초대(G4)·공유(G5).
extension FriendsSection {
    // MARK: 친구 찾기 — 사용자 ID로만(전화번호 검색·연락처는 휴대폰 앱)

    func openAdd() {
        lookupHit = nil
        go(.add)
    }

    func showAdd() {
        let page = HubScreen(title: "친구 찾기", back: { [weak self] in self?.go(.friends) })
        let field = HubFormField(title: "사용자 ID", placeholder: "예: minji_1 (영어 소문자, 숫자, 밑줄 3~20자)", validator: { HubFriendsValidation.handle($0) })
        let search = HubKit.primaryButton("찾기", symbol: "magnifyingglass") { [weak self] in self?.lookup(field) }
        page.add(field)
        page.add(HubKit.hstack([search]), full: false)
        page.note("전화번호나 연락처로 찾는 것은 휴대폰의 나초 앱에서 할 수 있어요.")
        if let hit = lookupHit {
            page.heading("찾은 사람")
            page.add(personCard(hit))
        }
        hubShow(page.view)
    }

    func lookup(_ field: HubFormField) {
        guard field.validate(), let e = ctx.client?.endpoint else { return }
        let handle = HubFriendsValidation.normalizeHandle(field.value)
        write({ HubFriendsAPI.lookup(e, bearer: $0, handle: handle) }, success: nil, then: { [weak self] o in
            guard let self = self else { return }
            guard let hit = o?.obj("hit"), let p = HubPerson(hit) else { field.showServerError("찾을 수 없어요."); return }
            self.lookupHit = p
            self.render()
        }, failure: { err in
            field.showServerError(HubFriendsText.message(err))
        })
    }

    /// 찾은 사람 카드: 관계에 따라 요청·수락·취소 단추.
    func personCard(_ p: HubPerson) -> NSView {
        var buttons: [NSView] = [HubKit.secondaryButton("프로필") { [weak self] in self?.go(.profile(p.userID)) }]
        switch p.relationship {
        case "none": buttons.append(HubKit.primaryButton("친구 요청 보내기") { [weak self] in self?.sendRequest(p, next: .friends) })
        case "incoming_request": buttons.append(HubKit.primaryButton("수락") { [weak self] in self?.answer(p, action: "accept", done: "\(p.displayName)님과 친구가 됐어요.", next: .friends) })
        case "outgoing_request": buttons.append(HubKit.secondaryButton("요청 취소") { [weak self] in self?.answer(p, action: "cancel", done: "요청을 취소했어요.", next: .friends) })
        default: break
        }
        return HubActionRow(title: p.displayName, subtitle: [p.handleText, HubRelationship.label(p.relationship)].compactMap { $0 }.joined(separator: " · "), buttons: buttons)
    }

    // MARK: 상대 프로필 (F5) — 캐릭터 그림은 기존 PetArt(PetCharacterAssets)를 쓴다

    func showProfile(_ id: String) {
        guard let e = ctx.client?.endpoint else { go(.friends); return }
        state.show(.loading)
        let toast = ctx.toast
        hubSend({ HubNachosAPI.userProfile(e, bearer: $0, userID: id) }) { [weak self] result in
            guard let self = self, self.screen == .profile(id) else { return }
            switch result {
            case let .failure(err):
                toast(HubFriendsText.message(err), true)
                self.state.show(.failed(HubFriendsText.message(err)))
            case let .success(resp):
                guard case let .success(o) = HubAPI.object(resp), let p = HubUserProfile(o) else { self.state.show(.failed(PetAPIError.badResponse.text)); return }
                self.drawProfile(p)
            }
        }
    }

    func drawProfile(_ p: HubUserProfile) {
        let page = HubScreen(title: p.displayName, back: { [weak self] in self?.go(.friends) })
        let head = HubKit.hstack([HubArt.character(size: 72), HubKit.vstack([
            HubKit.label(p.displayName, font: PetTheme.title),
            HubKit.label(p.handle.map { "@\($0)" } ?? "", color: PetTheme.secondary),
            HubKit.label(p.relationshipLabel, color: PetTheme.secondary),
        ], spacing: Double(PetTokens.Space.xs))], spacing: Double(PetTokens.Space.l))
        page.add(head, full: false)
        if p.deleted { page.note("탈퇴한 사용자예요.") }
        var fields: [(String, String)] = []
        if let n = p.characterName, !n.isEmpty { fields.append(("대표 나초", n)) }
        if let d = p.friendDays { fields.append(("친구가 된 지", "\(d)일")) }
        if p.mutualCount > 0 { fields.append(("함께 아는 친구", "\(p.mutualCount)명")) }
        for (k, v) in fields {
            page.add(HubKit.vstack([HubKit.label(k, font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(v)], spacing: Double(PetTokens.Space.xxs)))
        }
        var raw: [String: Any] = ["user_id": p.userID, "display_name": p.displayName, "relationship": p.relationship]
        if let h = p.handle { raw["handle"] = h }
        let person = HubPerson(HubObject(raw))!
        var actions: [NSView] = []
        switch p.relationship {
        case "friend":
            actions.append(HubKit.secondaryButton("이 친구에게 당부 적기", symbol: "note.text") { [weak self] in self?.go(.person(p.userID)) })
            actions.append(HubKit.secondaryButton("친구 지우기", symbol: "person.badge.minus") { [weak self] in self?.requestRemoveFriend(person) })
            actions.append(HubKit.primaryButton("차단", symbol: "nosign", danger: true) { [weak self] in self?.requestBlock(person) })
        case "none":
            actions.append(HubKit.primaryButton("친구 요청 보내기") { [weak self] in self?.sendRequest(person, next: .profile(p.userID)) })
            actions.append(HubKit.primaryButton("차단", symbol: "nosign", danger: true) { [weak self] in self?.requestBlock(person) })
        case "incoming_request":
            actions.append(HubKit.primaryButton("수락") { [weak self] in self?.answer(person, action: "accept", done: "\(p.displayName)님과 친구가 됐어요.", next: .profile(p.userID)) })
            actions.append(HubKit.secondaryButton("거절") { [weak self] in self?.answer(person, action: "decline", done: "요청을 거절했어요.", next: .friends) })
        case "outgoing_request":
            actions.append(HubKit.secondaryButton("요청 취소") { [weak self] in self?.answer(person, action: "cancel", done: "요청을 취소했어요.", next: .profile(p.userID)) })
        case "blocked":
            actions.append(HubKit.secondaryButton("차단 풀기") { [weak self] in self?.requestUnblock(person) })
        default: break
        }
        if !actions.isEmpty { page.add(PetFlow.rows(actions, maxWidth: 560, gap: Double(PetTokens.Space.s)), full: false) }
        hubShow(page.view)
    }

    // MARK: 초대 (G4) — 링크는 클립보드 복사만, 문자·메일은 보내지 않는다

    func showInvite() {
        guard let e = ctx.client?.endpoint else { go(.friends); return }
        state.show(.loading)
        let toast = ctx.toast
        hubSend({ HubFriendsAPI.invites(e, bearer: $0) }) { [weak self] result in
            guard let self = self, self.screen == .invite else { return }
            switch result {
            case let .failure(err):
                toast(HubFriendsText.message(err), true)
                self.state.show(.failed(HubFriendsText.message(err)))
            case let .success(resp):
                guard case let .success(o) = HubAPI.object(resp), let info = HubInviteInfo(o) else { self.state.show(.failed(PetAPIError.badResponse.text)); return }
                self.invite = info
                self.drawInvite(info)
            }
        }
    }

    func drawInvite(_ info: HubInviteInfo) {
        let page = HubScreen(title: "친구·공유")
        page.add(tabs(.invite), full: false)
        page.heading("내 초대")
        page.note("초대장이 \(info.remaining)장 남았어요. (\(info.used)/\(info.total)명 가입)")
        if info.inviteOnly, info.remaining == 0 { page.note("남은 초대장이 없어서 지금은 링크와 코드를 나눌 수 없어요.", color: PetTheme.color(\.warning)) }
        else {
            var buttons: [NSView] = []
            if info.copyableURL != nil { buttons.append(HubKit.primaryButton("링크 복사", symbol: "doc.on.doc") { [weak self] in self?.copyInviteLink() }) }
            if !info.code.isEmpty { buttons.append(HubKit.secondaryButton("코드 복사") { [weak self] in self?.copyInviteCode() }) }
            if !info.code.isEmpty { page.add(HubKit.vstack([HubKit.label("초대 코드", font: PetTheme.caption, color: PetTheme.secondary), HubKit.label(info.code, font: PetTheme.title)], spacing: Double(PetTokens.Space.xxs))) }
            if !buttons.isEmpty { page.add(HubKit.hstack(buttons), full: false) }
            page.note("링크는 복사만 해요. 문자나 메일로 직접 보내지 않아요.")
        }
        page.heading("초대 코드 입력")
        let code = HubFormField(title: "받은 초대 코드 (숫자 6자리)", validator: { HubFriendsValidation.inviteCode($0) })
        page.add(code)
        page.add(HubKit.hstack([HubKit.secondaryButton("코드 확인") { [weak self] in self?.redeem(code) }]), full: false)
        if !info.signups.isEmpty {
            page.heading("내 초대로 가입한 사람")
            for s in info.signups where !s.dismissed {
                let hide = HubKit.secondaryButton("숨기기") { [weak self] in self?.dismissSignup(s.person) }
                page.add(HubActionRow(title: s.person.displayName, subtitle: s.person.handleText, buttons: [hide]))
            }
        }
        hubShow(page.view)
    }

    func copyInviteLink() {
        guard let url = invite?.copyableURL else { return }
        copyToClipboard(url)
        ctx.toast("초대 링크를 복사했어요.", false)
    }

    func copyInviteCode() {
        guard let code = invite?.code, !code.isEmpty else { return }
        copyToClipboard(code)
        ctx.toast("초대 코드를 복사했어요.", false)
    }

    func redeem(_ field: HubFormField) {
        guard field.validate(), let e = ctx.client?.endpoint else { return }
        let code = field.value
        write({ HubFriendsAPI.redeem(e, bearer: $0, code: code) }, success: "초대 코드를 확인했어요.", then: { [weak self] _ in self?.go(.invite) },
              failure: { err in field.showServerError(HubFriendsText.message(err)) })
    }

    func dismissSignup(_ p: HubPerson) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubFriendsAPI.dismissInvite(e, bearer: $0, userID: p.userID) }, success: "목록에서 숨겼어요.", then: { [weak self] _ in self?.go(.invite) })
    }

    // MARK: 공유 설정 (G5)

    func showSharing() {
        guard let e = ctx.client?.endpoint else { go(.friends); return }
        state.show(.loading)
        let toast = ctx.toast
        hubSend({ HubFriendsAPI.sharing(e, bearer: $0) }) { [weak self] result in
            guard let self = self, self.screen == .sharing else { return }
            switch result {
            case let .failure(err):
                toast(HubFriendsText.message(err), true)
                self.state.show(.failed(HubFriendsText.message(err)))
            case let .success(resp):
                guard case let .success(o) = HubAPI.object(resp), let s = HubSharing(o) else { self.state.show(.failed(PetAPIError.badResponse.text)); return }
                self.sharing = s
                self.drawSharing(s)
            }
        }
    }

    func drawSharing(_ s: HubSharing) {
        let page = HubScreen(title: "친구·공유")
        page.add(tabs(.sharing), full: false)
        page.note("내 나초가 다른 사람의 나초에게 무엇을 말해도 되는지 정해요.")
        let friends = HubSwitchRow(title: "친구의 나초와 일상 대화까지", detail: "끄면 안부 인사까지만 해요.", isOn: s.shareFriends == "everyday")
        friends.onChange = { [weak self] on in self?.patchSharing(HubSharingPatch(shareFriends: on ? "everyday" : "checkin")) }
        page.add(friends)
        if s.strangerChatEnabled {
            let strangers = HubSwitchRow(title: "처음 보는 사람의 나초에게 소개까지", detail: "끄면 공개 프로필만 말해요.", isOn: s.shareStrangers == "intro")
            strangers.onChange = { [weak self] on in self?.patchSharing(HubSharingPatch(shareStrangers: on ? "intro" : "public_profile")) }
            page.add(strangers)
        }
        let plans = HubSwitchRow(title: "일정은 되는지만 말하기", detail: "켜면 일정 내용 없이 시간이 되는지만 말해요.", isOn: s.plansFreeOnly)
        plans.onChange = { [weak self] on in self?.patchSharing(HubSharingPatch(plansFreeOnly: on)) }
        page.add(plans)
        let birthday = HubSwitchRow(title: "생일은 월·일만 말하기", detail: nil, isOn: s.birthdayMonthDay)
        birthday.onChange = { [weak self] on in self?.patchSharing(HubSharingPatch(birthdayMonthDay: on)) }
        page.add(birthday)

        page.heading("말하지 않을 내용")
        let max = s.exclusionsMax
        let ex = HubFormField(title: "자유롭게 적어요 (최대 \(max)자)", validator: { HubSharingValidation.text($0, max: max, name: "내용") })
        ex.field.stringValue = s.exclusions
        page.add(ex)
        if !s.sensitive.isEmpty { page.note("민감한 내용(\(s.sensitive.joined(separator: ", ")))은 기본으로 말하지 않아요.") }
        page.add(HubKit.hstack([HubKit.secondaryButton("저장") { [weak self] in self?.saveExclusions(ex, version: s.exclusionsVersion) }]), full: false)

        page.heading("친구별 당부")
        if s.people.isEmpty { page.note("친구가 생기면 친구마다 당부를 적을 수 있어요.") }
        for p in s.people {
            let row = HubRow(title: p.displayName, subtitle: p.note, trailing: nil, symbol: "person.crop.circle")
            row.onClick = { [weak self] in self?.go(.person(p.userID)) }
            page.add(row)
        }
        hubShow(page.view)
    }

    func patchSharing(_ patch: HubSharingPatch) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubFriendsAPI.patchSharing(e, bearer: $0, patch: patch) }, success: "저장했어요.", then: { [weak self] o in
            if let o = o, let s = HubSharing(o) { self?.sharing = s }
            self?.go(.sharing)
        }, failure: { [weak self] err in
            self?.ctx.toast(HubFriendsText.message(err), true)
            self?.go(.sharing)
        })
    }

    func saveExclusions(_ field: HubFormField, version: Int) {
        guard field.validate(), let e = ctx.client?.endpoint else { return }
        let text = field.value
        write({ HubFriendsAPI.putExclusions(e, bearer: $0, text: text, version: version) }, success: "저장했어요.", then: { [weak self] _ in self?.go(.sharing) },
              failure: { [weak self] err in
                  self?.ctx.toast(HubFriendsText.message(err), true)
                  if err.isVersionConflict { self?.go(.sharing) }
              })
    }

    // MARK: 사람별 당부 (G5)

    func showPerson(_ id: String) {
        guard let e = ctx.client?.endpoint else { go(.friends); return }
        state.show(.loading)
        let toast = ctx.toast
        hubSend({ HubFriendsAPI.person(e, bearer: $0, userID: id) }) { [weak self] result in
            guard let self = self, self.screen == .person(id) else { return }
            switch result {
            case let .failure(err):
                toast(HubFriendsText.message(err), true)
                self.state.show(.failed(HubFriendsText.message(err)))
            case let .success(resp):
                guard case let .success(o) = HubAPI.object(resp), let n = HubPersonNote(o) else { self.state.show(.failed(PetAPIError.badResponse.text)); return }
                self.drawPerson(n)
            }
        }
    }

    func drawPerson(_ n: HubPersonNote) {
        let page = HubScreen(title: "\(n.displayName)님께 당부", back: { [weak self] in self?.go(.sharing) })
        page.note("이 친구와 이야기할 때 내 나초가 조심했으면 하는 것을 적어요. 친구에게는 보이지 않아요.")
        let max = sharing?.personNoteMax ?? 500
        let field = HubFormField(title: "당부 (최대 \(max)자)", validator: { HubSharingValidation.text($0, max: max, name: "당부") })
        field.field.stringValue = n.note
        page.add(field)
        page.add(HubKit.hstack([HubKit.primaryButton("저장") { [weak self] in self?.savePerson(n, field: field) }]), full: false)
        hubShow(page.view)
    }

    func savePerson(_ n: HubPersonNote, field: HubFormField) {
        guard field.validate(), let e = ctx.client?.endpoint else { return }
        let note = field.value
        write({ HubFriendsAPI.putPerson(e, bearer: $0, userID: n.userID, note: note, version: n.version) }, success: "저장했어요.", then: { [weak self] _ in self?.go(.person(n.userID)) },
              failure: { [weak self] err in
                  self?.ctx.toast(HubFriendsText.message(err), true)
                  if err.isVersionConflict { self?.go(.person(n.userID)) }
              })
    }
}
