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
    func makeHubClient() -> HubClient? {
        guard state.auth == .signedIn, let endpoint = settings.endpoint else { return nil }
        let session = self.session!
        // 401을 받으면 새로고침을 강제해 새 토큰으로 한 번만 다시 보낸다(실패하면 로그아웃 안내로 끝난다).
        return HubClient(endpoint: endpoint, http: hubHTTP, tokens: { force, done in
            if force { session.refreshAccessToken(done) } else { session.withAccessToken(done) }
        })
    }

    var hubEnvironment: HubEnvironment {
        HubEnvironment(isSignedIn: { [weak self] in self?.state.auth == .signedIn },
                       client: { [weak self] in self?.makeHubClient() },
                       signIn: { [weak self] in self?.openChat(); self?.signIn() },
                       checksOnboarding: true,
                       onboardingFinished: { [weak self] in self?.session.onboardingFinished() },
                       signOut: { [weak self] in self?.signOut() })
    }

    /// 「나초 앱 열기…」. 이미 열려 있으면 앞으로 가져온다.
    func openHub(section: HubSectionID? = nil) {
        HubRooms.chatOpener = { [weak self] room in self?.openRoomInChat(room) }
        if hubWindow == nil { hubWindow = PetHubWindow(env: hubEnvironment) }
        if let s = section { hubWindow?.select(s) } else { hubWindow?.refreshAuth() }
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
    }
}

extension NachoPetModule {
    /// 허브에서 고른 방을 대화창에서 연다(NACHO-276).
    func openRoomInChat(_ room: HubRoom) {
        openChat()
        session.openRoom(id: room.id, title: room.displayTitle, kind: room.kind)
    }
}
