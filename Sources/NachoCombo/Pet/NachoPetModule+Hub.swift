import AppKit
import NachoComboCore
import ObjectiveC

/// 나초 앱 창(허브)을 모듈에 연결한다. 모듈 본체는 건드리지 않고 이 extension 파일에서만 잇는다.
private var hubWindowKey: UInt8 = 0
private let hubHTTP = URLSessionPetHTTP()

extension NachoPetModule {
    private var hubWindow: PetHubWindow? {
        get { objc_getAssociatedObject(self, &hubWindowKey) as? PetHubWindow }
        set { objc_setAssociatedObject(self, &hubWindowKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 요청 실행기: 로그인이 되어 있고 서버 주소가 있을 때만. 토큰은 세션이 필요할 때 새로 받는다.
    /// (세션에 "강제 새로고침"이 아직 없어 401 재시도도 같은 `withAccessToken`을 쓴다. docs/HUB.md 참고.)
    func makeHubClient() -> HubClient? {
        guard state.auth == .signedIn, let endpoint = settings.endpoint else { return nil }
        let session = self.session!
        return HubClient(endpoint: endpoint, http: hubHTTP, tokens: { _, done in session.withAccessToken(done) })
    }

    var hubEnvironment: HubEnvironment {
        HubEnvironment(isSignedIn: { [weak self] in self?.state.auth == .signedIn },
                       client: { [weak self] in self?.makeHubClient() },
                       signIn: { [weak self] in self?.openChat(); self?.signIn() })
    }

    /// 「나초 앱 열기…」. 이미 열려 있으면 앞으로 가져온다.
    func openHub(section: HubSectionID? = nil) {
        if hubWindow == nil { hubWindow = PetHubWindow(env: hubEnvironment) }
        if let s = section { hubWindow?.select(s) } else { hubWindow?.refreshAuth() }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }
}
