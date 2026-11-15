import AppKit
import NachoComboCore

/// U9 섹션(연결 보안·사용량·탐색·보관함)이 같이 쓰는 작은 도우미. 공용 기반은 고치지 않고 extension으로 둔다.
extension HubSectionBase {
    /// 요청을 보내고 메인 큐에서 결과를 준다. `HubClient`는 약한 참조(`[weak self]`)로 콜백을 잇기 때문에,
    /// 사용자가 다른 섹션으로 옮겨 컨텍스트가 바뀌어도 결과가 버려지지 않도록 완료 때까지 클라이언트를 붙잡는다.
    func call(_ build: @escaping (ServerEndpoint, String?) -> PetHTTPRequest,
              done: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        guard let client = ctx.client else { done(.failure(.hubNotSignedIn)); return }
        let endpoint = client.endpoint
        client.send({ build(endpoint, $0) }) { result in
            withExtendedLifetime(client) {}
            DispatchQueue.main.async { done(result) }
        }
    }

    func say(_ text: String, error: Bool = false) { ctx.toast(text, error) }
}

/// 섹션 안의 탭: 위에 분절 단추, 아래에 탭마다 상태 뷰(불러오는 중·빈 상태·오류·내용) 하나씩.
final class HubTabsView: NSView {
    let segmented: NSSegmentedControl
    let panes: [HubStateView]
    var onSelect: ((Int) -> Void)?

    init(titles: [String]) {
        segmented = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        panes = titles.map { _ in HubStateView() }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(changed)
        addSubview(segmented)
        let l = CGFloat(PetTokens.Space.l)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: topAnchor, constant: l),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: l),
        ])
        for p in panes {
            addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: CGFloat(PetTokens.Space.s)),
                p.leadingAnchor.constraint(equalTo: leadingAnchor),
                p.trailingAnchor.constraint(equalTo: trailingAnchor),
                p.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        select(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selected: Int { segmented.selectedSegment }

    func select(_ i: Int) {
        segmented.selectedSegment = i
        for (k, p) in panes.enumerated() { p.isHidden = k != i }
    }

    @objc private func changed() {
        select(segmented.selectedSegment)
        onSelect?(segmented.selectedSegment)
    }
}
