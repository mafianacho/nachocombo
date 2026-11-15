import AppKit
import NachoComboCore

/// 연결 보안(NACHO-264 U9: E5·E7·E8). 탭 셋: 연결(나초 허용·공유 대상) · 사용 기록 · 승인 규칙.
/// 연결을 켜고 끄거나 새로 연동하는 일은 연결 탭(#47) 몫이라 여기엔 없다. 쓰기는 전부 서버가 준 사실을 고치는 것뿐이다.
final class TrustSection: HubSectionBase {
    let tabs = HubTabsView(titles: ["연결", "사용 기록", "승인 규칙"])
    var built = false

    // 연결 탭 상태
    var connections: [HubConnection] = []
    var agents: [HubAgentRef] = []
    var sharing: [String: HubSharingRow] = [:]
    // 사용 기록 탭 상태
    var logList: HubListView?
    var logRows: [HubAccessRow] = []
    // 승인 규칙 탭 상태
    var limitField: HubFormField?

    init() { super.init(id: .trust) }

    override func load() {
        guard ctx.client != nil else { state.show(.failed("로그인이 필요해요.")); return }
        if !built {
            built = true
            HubKit.pin(tabs, in: state.contentHost)
            tabs.onSelect = { [weak self] i in self?.loadTab(i) }
        }
        state.show(.content)
        loadTab(tabs.selected)
    }

    func loadTab(_ i: Int) {
        switch i {
        case 0: loadConnections()
        case 1: loadLog(next: nil)
        default: loadRules()
        }
    }

    override func reload() { loadTab(tabs.selected) }
}
