import AppKit
import NachoComboCore

// 나초 섹션: 목소리(F2)·닮은 점(F2)·사진(F3)·한도(F4).
extension NachosSection {
    /// 읽기 요청 한 번. 성공하면 본문을 `then`에, 실패하면 화면에 오류를 보여 준다.
    private func read(_ id: String, title: String, _ build: @escaping (String?) -> PetHTTPRequest, then: @escaping (HubPage?, HubObject?) -> Void) {
        let toast = ctx.toast
        hubSend(build) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .failure(err):
                toast(HubNachosText.message(err), true)
                if err.isNotFound { self.refreshAfterConflict() } else { self.state.show(.failed(HubNachosText.message(err))) }
            case let .success(resp):
                // 배열 본문(목소리·특성)과 객체 본문(사진)을 모두 읽는다.
                then(try? HubAPI.page(resp).get(), try? HubAPI.object(resp).get())
            }
        }
    }

    // MARK: 목소리 (F2) — 미리 듣기는 서버가 준 오디오 주소만 재생한다

    func showVoices(_ id: String) {
        guard let a = agent(id), let e = ctx.client?.endpoint else { go(.list); return }
        state.show(.loading)
        read(id, title: "목소리", { HubNachosAPI.agentVoices(e, bearer: $0, id: id) }) { [weak self] page, _ in
            guard let self = self, self.screen == .voices(id) else { return }
            self.drawVoices(a, (page?.items ?? []).compactMap(HubVoice.init))
        }
    }

    func drawVoices(_ a: HubAgent, _ voices: [HubVoice]) {
        let screen = HubScreen(title: "\(a.name)의 목소리", back: { [weak self] in self?.go(.detail(a.id)) })
        if voices.isEmpty { screen.note("고를 수 있는 목소리가 없어요.") }
        for v in voices {
            var buttons: [NSView] = []
            if let url = v.sampleURL {
                buttons.append(HubKit.secondaryButton("미리 듣기", symbol: "play.fill") { [weak self] in self?.voicePlayer.play(url) })
            }
            let current = v.id == a.voiceID
            if !current { buttons.append(HubKit.primaryButton("이 목소리로") { [weak self] in self?.chooseVoice(a, v) }) }
            screen.add(HubActionRow(title: v.label, subtitle: v.description, badge: current ? "사용 중" : nil, buttons: buttons))
        }
        hubShow(screen.view)
    }

    func chooseVoice(_ a: HubAgent, _ v: HubVoice) {
        guard let e = ctx.client?.endpoint else { return }
        let fresh = agent(a.id) ?? a
        write({ HubNachosAPI.patch(e, bearer: $0, id: a.id, patch: HubAgentPatch(voiceID: v.id), version: fresh.version) },
              success: "목소리를 바꿨어요.", then: { [weak self] _ in self?.go(.voices(a.id)) })
    }

    // MARK: 닮은 점 (F2)

    func showTraits(_ id: String) {
        guard let a = agent(id), let e = ctx.client?.endpoint else { go(.list); return }
        state.show(.loading)
        read(id, title: "닮은 점", { HubNachosAPI.traits(e, bearer: $0, id: id) }) { [weak self] page, _ in
            guard let self = self, self.screen == .traits(id) else { return }
            self.drawTraits(a, (page?.items ?? []).compactMap(HubTrait.init))
        }
    }

    func drawTraits(_ a: HubAgent, _ traits: [HubTrait]) {
        let refresh = HubKit.secondaryButton("다시 뽑기", symbol: "arrow.clockwise") { [weak self] in self?.refreshTraits(a) }
        let screen = HubScreen(title: "닮은 점", back: { [weak self] in self?.go(.detail(a.id)) }, trailing: [refresh])
        screen.note("\(a.name)이(가) 기억을 바탕으로 찾은 나와 닮은 점이에요. 다시 뽑아도 크레딧은 들지 않아요.")
        if traits.isEmpty { screen.note("아직 찾은 닮은 점이 없어요.") }
        for t in traits {
            let hide = HubKit.secondaryButton("숨기기", symbol: "eye.slash") { [weak self] in self?.hideTrait(a, t) }
            screen.add(HubActionRow(title: t.text, subtitle: t.evidence, buttons: [hide]))
        }
        hubShow(screen.view)
    }

    func refreshTraits(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.refreshTraits(e, bearer: $0, id: a.id) }, success: "닮은 점을 다시 뽑았어요.", then: { [weak self] _ in self?.go(.traits(a.id)) })
    }

    /// 숨긴 칩은 다시 만들지 않는다(되돌릴 수 없음) → 확인창 두 번.
    func hideTrait(_ a: HubAgent, _ t: HubTrait) {
        guard let e = ctx.client?.endpoint else { return }
        let steps = [
            HubConfirmStep(title: "이 닮은 점을 숨길까요?", message: "「\(t.text)」", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 숨길까요?", message: "숨기면 다시 만들어지지 않아요. 근거가 된 기억은 그대로 남아요.", confirmTitle: "숨기기"),
        ]
        ctx.confirm(steps) { [weak self] in
            self?.write({ HubNachosAPI.hideTrait(e, bearer: $0, id: a.id, traitID: t.id) }, success: "숨겼어요.", then: { _ in self?.go(.traits(a.id)) })
        }
    }

    // MARK: 사진 (F3) — 만들기는 크레딧을 쓴다

    func showPhotos(_ id: String) {
        guard let a = agent(id), let e = ctx.client?.endpoint else { go(.list); return }
        state.show(.loading)
        read(id, title: "사진", { HubNachosAPI.photos(e, bearer: $0, id: id) }) { [weak self] _, obj in
            guard let self = self, self.screen == .photos(id) else { return }
            guard let o = obj, let photos = HubPhotos(o) else { self.ctx.toast(PetAPIError.badResponse.text, true); return }
            self.photos = photos
            self.drawPhotos(a, photos)
        }
    }

    func drawPhotos(_ a: HubAgent, _ photos: HubPhotos) {
        let screen = HubScreen(title: "사진", back: { [weak self] in self?.go(.detail(a.id)) })
        screen.note("사진을 만들면 \(a.name)의 모습으로 쓸 수 있어요. 오늘 \(photos.remainingToday)장 더 만들 수 있어요.")
        if HubFeatureFlags.agentPhotoCreate, !photos.scenes.isEmpty {
            let scene = HubChoiceField(title: "장면", options: photos.scenes.map { ($0.id, $0.label) }, selected: photos.scenes.first?.id)
            let make = HubKit.primaryButton("사진 만들기", symbol: "camera") { [weak self] in
                guard let s = scene.selectedID else { return }
                self?.requestPhoto(a, sceneID: s)
            }
            make.isEnabled = photos.remainingToday > 0
            screen.add(scene)
            screen.add(HubKit.hstack([make]), full: false)
            if photos.remainingToday <= 0, let next = photos.nextAvailableAt, let t = ErrorText.retryAt(next) { screen.note("오늘은 다 만들었어요. \(t)에 다시 만들 수 있어요.") }
        }
        if photos.photos.isEmpty { screen.note("아직 만든 사진이 없어요.") }
        let label: (String) -> String = { id in photos.scenes.first { $0.id == id }?.label ?? id }
        for p in photos.photos {
            var buttons: [NSView] = []
            if !p.inUse {
                buttons.append(HubKit.secondaryButton("이 사진 쓰기") { [weak self] in self?.selectPhoto(a, p) })
                buttons.append(HubKit.secondaryButton("지우기", symbol: "trash") { [weak self] in self?.requestDeletePhoto(a, p) })
            }
            screen.add(HubActionRow(title: label(p.sceneID), subtitle: "사진", badge: p.inUse ? "쓰는 중" : nil, buttons: buttons))
        }
        if photos.currentKey != nil || a.avatarURL != nil {
            screen.add(HubKit.hstack([HubKit.secondaryButton("기본 모습으로 되돌리기", symbol: "arrow.uturn.backward") { [weak self] in self?.clearAvatar(a) }]), full: false)
        }
        hubShow(screen.view)
    }

    /// 만들기: 크레딧을 쓰니 확인창에 오늘 남은 장수와 크레딧 잔량을 보여 주고, 확인해야만 요청한다(거절하면 요청 0건).
    func requestPhoto(_ a: HubAgent, sceneID: String) {
        guard HubFeatureFlags.agentPhotoCreate, let e = ctx.client?.endpoint else { return }
        let remaining = photos?.remainingToday ?? 0
        let label = photos?.scenes.first { $0.id == sceneID }?.label ?? sceneID
        let confirm = ctx.confirm
        hubSend({ PetServerAPI.usageRequest(e, bearer: $0) }) { [weak self] result in
            var credits: Int?
            if case let .success(resp) = result, let u = PetServerAPI.decodeUsage(resp.body) { credits = u.remaining }
            let step = HubConfirmStep(title: "사진을 만들까요?", message: HubPhotos.creditConfirmMessage(sceneLabel: label, remainingToday: remaining, credits: credits),
                                      confirmTitle: "만들기", destructive: false)
            _ = confirm; self?.takePhoto(a, sceneID: sceneID)   // MUTATION: 확인 건너뜀
        }
    }

    func takePhoto(_ a: HubAgent, sceneID: String) {
        guard let e = ctx.client?.endpoint else { return }
        let key = HubAPI.newIdempotencyKey()
        write({ HubNachosAPI.takePhoto(e, bearer: $0, id: a.id, sceneID: sceneID, idempotencyKey: key) }, success: "사진을 만들었어요.", then: { [weak self] _ in self?.go(.photos(a.id)) })
    }

    func selectPhoto(_ a: HubAgent, _ p: HubPhoto) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.selectPhoto(e, bearer: $0, id: a.id, key: p.key) }, success: "프로필 사진으로 정했어요.", then: { [weak self] _ in self?.go(.photos(a.id)) })
    }

    /// 지우면 되돌릴 수 없다(그날 만든 횟수도 그대로) → 확인창 두 번.
    func requestDeletePhoto(_ a: HubAgent, _ p: HubPhoto) {
        guard let e = ctx.client?.endpoint else { return }
        let steps = [
            HubConfirmStep(title: "이 사진을 지울까요?", message: "지우면 다시 볼 수 없어요.", confirmTitle: "계속"),
            HubConfirmStep(title: "정말 지울까요?", message: "지워도 오늘 만들 수 있는 장수는 늘지 않아요.", confirmTitle: "지우기"),
        ]
        ctx.confirm(steps) { [weak self] in
            self?.write({ HubNachosAPI.deletePhoto(e, bearer: $0, id: a.id, key: p.key) }, success: "사진을 지웠어요.", then: { _ in self?.go(.photos(a.id)) })
        }
    }

    func clearAvatar(_ a: HubAgent) {
        guard let e = ctx.client?.endpoint else { return }
        write({ HubNachosAPI.clearAvatar(e, bearer: $0, id: a.id) }, success: "기본 모습으로 되돌렸어요.", then: { [weak self] _ in self?.go(.photos(a.id)) })
    }

    // MARK: 한도 (F4)

    func showLimits(_ id: String) {
        guard let a = agent(id) else { go(.list); return }
        let screen = HubScreen(title: "한도", back: { [weak self] in self?.go(.detail(id)) })
        screen.note("\(a.name)이(가) 어디까지 볼 수 있는지 정해요. 켜면 이 나초만 쓰는 것이에요.")
        let rows: [(String, String, Bool, (Bool) -> HubLimitsPatch)] = [
            ("기억 읽기를 이 나초만", "끄면 모든 나초가 같이 읽어요.", a.limits.memoryRead == "own_only", { HubLimitsPatch(memoryRead: $0 ? "own_only" : "shared") }),
            ("기억 쓰기를 이 나초만", "끄면 새 기억이 모든 나초에게 공유돼요.", a.limits.memoryWrite == "own_only", { HubLimitsPatch(memoryWrite: $0 ? "own_only" : "shared") }),
            ("문서를 이 나초만", "끄면 모든 나초가 같은 문서를 봐요.", a.limits.documents == "own_only", { HubLimitsPatch(documents: $0 ? "own_only" : "shared") }),
        ]
        for (title, detail, on, make) in rows {
            let row = HubSwitchRow(title: title, detail: detail, isOn: on)
            row.onChange = { [weak self] isOn in self?.changeLimits(a, make(isOn)) }
            screen.add(row)
        }
        screen.note("금고 카드 사용: \(a.limits.vaultCards ? "허용" : "허용 안 함") · 자동 결제: \(a.limits.autoPayment ? "허용" : "허용 안 함")")
        screen.note("연결·금고·결제 한도는 휴대폰의 나초 앱에서만 바꿀 수 있어요.")
        hubShow(screen.view)
    }

    func changeLimits(_ a: HubAgent, _ patch: HubLimitsPatch) {
        guard let e = ctx.client?.endpoint else { return }
        let fresh = agent(a.id) ?? a
        write({ HubNachosAPI.limits(e, bearer: $0, id: a.id, patch: patch, version: fresh.version) }, success: "한도를 바꿨어요.", then: { [weak self] _ in self?.render() },
              failure: { [weak self] err in
                  self?.ctx.toast(HubNachosText.message(err), true)
                  self?.render()
              })
    }
}
