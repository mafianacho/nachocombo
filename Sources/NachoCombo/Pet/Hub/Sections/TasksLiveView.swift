import AppKit
import WebKit
import NachoComboCore

/// 라이브 뷰(C4): 서버가 준 보기 주소를 `WKWebView`로 연다. https이고 서버 호스트일 때만 열고, 서버 호스트 밖으로 가려는 이동은 막는다.
/// 서버 → 맥 방향 보기만 한다. 맥 화면·클립보드·파일은 서버로 보내지 않는다.
final class TasksLiveViewPane: NSView, WKNavigationDelegate, WKUIDelegate {
    private let notice = HubKit.label("", font: PetTheme.caption, color: PetTheme.color(\.warning))
    private let serverHost: String
    private let serverPort: Int?

    /// `makeSurface`는 시험이 가짜 화면을 주려고 바꿀 수 있다(기본은 지우는 저장소를 쓰는 WKWebView).
    init(url: URL, serverHost: String, serverPort: Int?, verifiedHost: String?, onClose: @escaping () -> Void,
         makeSurface: ((URL, TasksLiveViewPane) -> NSView)? = nil) {
        self.serverHost = serverHost
        self.serverPort = serverPort
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let host = verifiedHost ?? serverHost
        let top = HubKit.hstack([HubKit.label("\(host) 원격 화면", font: PetTheme.title), HubKit.secondaryButton("창 닫기", symbol: "xmark", onClick: onClose)])
        let help = HubKit.vstack(HubLiveView.helpLines.map { HubKit.label($0, font: PetTheme.caption, color: PetTheme.secondary) }, spacing: Double(PetTokens.Space.xxs))
        notice.isHidden = true
        let surface = makeSurface?(url, self) ?? makeWebView(url)
        surface.translatesAutoresizingMaskIntoConstraints = false
        let col = HubKit.vstack([top, help, notice, surface], spacing: Double(PetTokens.Space.s))
        HubKit.pin(col, in: self, inset: Double(PetTokens.Space.l))
        HubKit.fill(col, [top, help, notice, surface])
        surface.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makeWebView(_ url: URL) -> NSView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()  // 이 브라우저는 앱에 아무것도 남기지 않는다
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.load(URLRequest(url: url))
        return web
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = navigationAction.request.url else { decisionHandler(.cancel); return }
        if u.scheme == "about" { decisionHandler(.allow); return }
        if HubLiveView.allowedURL(u.absoluteString, serverHost: serverHost, serverPort: serverPort) != nil {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            notice.stringValue = "\(serverHost) 밖의 주소로 바뀌었어요. 여기에 입력하지 말고 닫아 주세요."
            notice.isHidden = false
        }
    }

    /// 새 창은 열지 않는다.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

extension TasksSection {
    /// 브라우저·로그인 카드로 기다리는 작업의 원격 화면을 연다.
    func openLiveView(_ t: HubTask) {
        guard let client = ctx.client, let rid = t.pendingRequestID else { return }
        let e = client.endpoint
        write({ HubTasks.liveViewSession(e, bearer: $0, attemptID: nil, requestID: rid) }, failText: { err in
            err.status == 429 ? "잠시 뒤 다시 눌러 주세요." : (err.code == "not_implemented" ? "이 앱에서는 아직 열 수 없어요. 나초에게 다른 방법을 물어봐 주세요." : err.text)
        }) { [weak self] resp in
            guard let self = self else { return }
            switch HubTasks.decodeTicket(resp) {
            case let .failure(err): self.ctx.toast(err.text, true)
            case let .success(ticket): self.showLiveView(ticket, task: t)
            }
        }
    }

    /// 화면 그리기만(시험·캡처가 직접 부른다). 허용 규칙에 맞지 않으면 열지 않고 토스트로 알린다.
    func showLiveView(_ ticket: HubViewerTicket, task t: HubTask, makeSurface: ((URL, TasksLiveViewPane) -> NSView)? = nil) {
        let base = ctx.client?.endpoint.base
        guard let host = base?.host, let url = HubLiveView.allowedURL(ticket.viewerURL, serverHost: host, serverPort: base?.port) else {
            ctx.toast("안전하지 않은 주소라 열지 않았어요.", true)
            return
        }
        let pane = TasksLiveViewPane(url: url, serverHost: host, serverPort: base?.port, verifiedHost: ticket.verifiedHost, onClose: { [weak self] in
            self?.ctx.confirm([HubConfirmStep(title: "로그인을 그만둘까요?", message: "로그인하지 않으면 나초가 이 일을 이어 가지 못해요. 작업에서 다시 열 수 있어요.",
                                              confirmTitle: "그만두기", destructive: false)]) { self?.showDetail(t); self?.refreshDetail(t.id) }
        }, makeSurface: makeSurface)
        self.host(pane, name: "live:\(t.id)")
    }
}
