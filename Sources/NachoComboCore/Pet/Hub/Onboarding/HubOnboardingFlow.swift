import Foundation

/// 가입 단계 전환 상태 기계(NACHO-277 U11). 나초 앱 `use-onboarding-flow.ts`와 같은 규칙이다:
///   - 그리는 단계는 언제나 서버의 `step`이다. 입력을 보내면 서버가 받은 뒤 다시 읽어서 다음 단계를 그린다.
///   - 서버가 거절하면(200 + rejection) 단계는 그대로고 이유만 한국어로 보여 준다. 단계가 달라졌거나 계정이 막혔으면 다시 읽는다.
///   - 서버의 `guide_privacy` 단계는 입력이 없어서 클라이언트가 대신 지나간다(앞으로도 뒤로도).
///   - 같은 때에 요청은 하나만 나간다. 전화번호 인증 단계는 맥에서 하지 않고 휴대폰 안내만 보여 준다.
/// 상태는 락으로 지키고 `onChange`는 락 밖에서(요청이 끝난 큐에서) 불린다. 화면은 메인으로 옮긴다.
public final class HubOnboardingFlow {
    public enum Phase: Equatable {
        case loading
        /// 읽지 못함(다시 시도).
        case failed
        /// 서버 단계를 그린다.
        case step
        /// 이 앱이 못 하는 단계(전화번호 인증 등): 휴대폰 안내 + 다시 확인.
        case phoneOnPhone
        /// 가입은 끝났고 약관이 바뀌어 다시 동의가 필요하다.
        case reconsent
        case suspended
        case regionClosed
        /// 가입 끝: 대화를 시작해도 된다.
        case finished
    }

    public enum FlowError: Equatable {
        case network
        case unknown
        case rejected(String)
        case server(String)
        case joinFailed
    }

    public struct Snapshot: Equatable {
        public var state: HubOnboardingState?
        public var phase: Phase = .loading
        public var busy = false
        public var error: FlowError?

        public var notice: String? {
            switch phase {
            case .phoneOnPhone: return HubOnboardingRules.phoneNotice
            case .suspended: return HubOnboardingRules.rejectionText(step: .login, code: "suspended")
            case .regionClosed: return HubOnboardingRules.rejectionText(step: .login, code: "region_closed")
            default: return nil
            }
        }

        public var errorText: String? {
            guard let e = error else { return nil }
            switch e {
            case .network: return HubOnboardingRules.networkText
            case .unknown: return HubOnboardingRules.rejectionText(step: .login, code: "")
            case let .rejected(code): return HubOnboardingRules.rejectionText(step: state?.step ?? .login, code: code)
            case let .server(text): return text
            case .joinFailed: return HubOnboardingRules.joinFailedText
            }
        }
    }

    public var onChange: ((Snapshot) -> Void)?
    private let client: HubClient
    private let lock = NSLock()
    private var snap = Snapshot()
    /// 요청이 나가 있는 동안 true(같은 칸을 두 번 눌러도 한 번만 나간다).
    private var inFlight = false
    private var generation = 0

    public init(client: HubClient) { self.client = client }

    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return snap }

    // MARK: state helpers

    private func update(_ body: (inout Snapshot) -> Void) {
        lock.lock()
        body(&snap)
        let s = snap
        lock.unlock()
        onChange?(s)
    }

    /// 요청 하나를 시작한다. 이미 나가 있으면 false.
    private func begin(showBusy: Bool) -> Bool {
        lock.lock()
        if inFlight { lock.unlock(); return false }
        inFlight = true
        snap.error = nil
        snap.busy = showBusy
        let s = snap
        lock.unlock()
        onChange?(s)
        return true
    }

    private func end(_ body: (inout Snapshot) -> Void = { _ in }) {
        lock.lock()
        inFlight = false
        snap.busy = false
        body(&snap)
        let s = snap
        lock.unlock()
        onChange?(s)
    }

    private func error(for e: PetAPIError) -> FlowError { e.status == 0 ? .network : .server(e.text) }

    static func phase(for s: HubOnboardingState) -> Phase {
        switch s.accountStatus {
        case .suspended: return .suspended
        case .regionClosed: return .regionClosed
        default: break
        }
        switch s.step {
        case .done: return HubOnboardingGate.needsReconsent(s) ? .reconsent : .finished
        case .login: return .failed
        case .phone, .unknown: return .phoneOnPhone
        // 값 없이는 답할 수 없는 단계(약관 문서 버전, 고를 목소리)는 읽지 못한 것으로 친다.
        case .consent where (s.consentVersion ?? "").isEmpty: return .failed
        case .characterVoice where s.voices.isEmpty: return .failed
        default: return .step
        }
    }

    // MARK: reads

    private func fetch(_ done: @escaping (Result<HubOnboardingState, PetAPIError>) -> Void) {
        let e = client.endpoint
        client.send({ HubOnboardingAPI.state(e, bearer: $0) }) { r in
            switch r {
            case let .failure(err): done(.failure(err))
            case let .success(resp): done(HubOnboardingAPI.parseState(resp))
            }
        }
    }

    /// 읽고(필요하면 개인정보 안내 단계를 지나가고) 그린다. 읽기에 실패하면 옛 화면을 두지 않고 다시 시도 화면으로 간다.
    private func reread(_ then: @escaping (inout Snapshot) -> Void = { _ in }) {
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        let finish: (Result<HubOnboardingState, PetAPIError>) -> Void = { [weak self] r in
            guard let self = self else { return }
            self.lock.lock(); let stale = mine != self.generation; self.lock.unlock()
            if stale { return }
            switch r {
            case let .failure(err):
                self.end { $0.state = nil; $0.phase = .failed; $0.error = self.error(for: err) }
            case let .success(s):
                self.end { $0.state = s; $0.phase = HubOnboardingFlow.phase(for: s); then(&$0) }
            }
        }
        fetch { [weak self] r in
            guard let self = self else { return }
            if case let .success(s) = r, s.step == .guidePrivacy {
                self.passPrivacy { passed in
                    if passed { self.fetch(finish) } else { finish(.failure(.badResponse)) }
                }
            } else {
                finish(r)
            }
        }
    }

    private func passPrivacy(_ done: @escaping (Bool) -> Void) {
        let e = client.endpoint
        client.send({ HubOnboardingAPI.submit(e, bearer: $0, step: .guidePrivacy, value: nil) }) { r in
            if case let .success(resp) = r, case .success = HubOnboardingAPI.parseSubmit(resp) { done(true) } else { done(false) }
        }
    }

    /// 처음 읽기·다시 시도.
    public func load() {
        lock.lock()
        if inFlight { lock.unlock(); return }
        inFlight = true
        if snap.state == nil { snap.phase = .loading }
        snap.error = nil
        let s = snap
        lock.unlock()
        onChange?(s)
        reread()
    }

    /// 휴대폰에서 마친 뒤 다시 확인한다(단추에 진행 표시).
    public func recheck() {
        guard begin(showBusy: true) else { return }
        reread()
    }

    // MARK: writes

    public func submit(_ step: HubOnboardingStep, value: Any?) {
        // 맥에서는 전화번호 인증(SMS)을 하지 않는다: 어떤 쓰기도 보내지 않는다.
        if step.isPhoneAppOnly { return }
        guard begin(showBusy: true) else { return }
        let e = client.endpoint
        client.send({ HubOnboardingAPI.submit(e, bearer: $0, step: step, value: value) }) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case let .failure(err): self.end { $0.error = self.error(for: err) }
            case let .success(resp):
                guard case let .success(result) = HubOnboardingAPI.parseSubmit(resp) else { self.end { $0.error = .unknown }; return }
                guard let code = result.rejection else { self.reread(); return }
                // 막힌 계정이거나 단계가 달라졌으면 서버 화면을 다시 읽는다. 그 뒤에도 이유는 보여 준다.
                let ends = code == "suspended" || code == "region_closed"
                if ends || result.step != step { self.reread { $0.error = .rejected(code) } } else { self.end { $0.error = .rejected(code) } }
            }
        }
    }

    public func back() {
        guard snapshot.state?.canGoBack == true, let from = snapshot.state?.step, begin(showBusy: false) else { return }
        let e = client.endpoint
        func send(_ from: HubOnboardingStep, again: Bool) {
            client.send({ HubOnboardingAPI.back(e, bearer: $0, from: from) }) { [weak self] r in
                guard let self = self else { return }
                switch r {
                case let .failure(err): self.end { $0.error = self.error(for: err) }
                case let .success(resp):
                    guard case let .success(step) = HubOnboardingAPI.parseBack(resp) else { self.end { $0.error = .unknown }; return }
                    if step == .guidePrivacy, again { send(.guidePrivacy, again: false) } else { self.reread() }
                }
            }
        }
        send(from, again: true)
    }

    public func joinInviteWaitlist() { join { HubOnboardingAPI.inviteWaitlist($0, bearer: $1) } }
    public func joinRegionWaitlist() { join { HubOnboardingAPI.regionWaitlist($0, bearer: $1) } }

    private func join(_ build: @escaping (ServerEndpoint, String?) -> PetHTTPRequest) {
        guard begin(showBusy: true) else { return }
        let e = client.endpoint
        client.send({ build(e, $0) }) { [weak self] r in
            guard let self = self else { return }
            if case .success = r { self.reread() } else { self.end { $0.error = .joinFailed } }
        }
    }

    /// 약관 갱신 동의: 필수를 모두 동의로 보내고 혜택 알림 선택은 그대로 둔다(앱 `reconsentAnswer`).
    public func agreeAgain() {
        guard let s = snapshot.state, let version = s.consentVersion, !version.isEmpty else { update { $0.error = .unknown }; return }
        guard begin(showBusy: true) else { return }
        let e = client.endpoint
        let value = HubOnboardingRules.consentValue(terms: true, privacy: true, thirdParty: true, aiTransfer: true, marketing: s.consentMarketing ?? false, version: version)
        client.send({ HubOnboardingAPI.submit(e, bearer: $0, step: .consent, value: value) }) { [weak self] r in
            guard let self = self else { return }
            switch r {
            case let .failure(err): self.end { $0.error = self.error(for: err) }
            case let .success(resp):
                guard case let .success(result) = HubOnboardingAPI.parseSubmit(resp), result.rejection == nil else {
                    self.end { $0.error = .server("저장하지 못했어요. 다시 시도해 주세요.") }
                    return
                }
                self.reread { if $0.phase == .reconsent { $0.error = .server("저장하지 못했어요. 다시 시도해 주세요.") } }
            }
        }
    }
}
