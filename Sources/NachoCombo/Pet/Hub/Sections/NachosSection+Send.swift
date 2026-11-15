import AppKit
import AVFoundation
import NachoComboCore

// 나초·친구 섹션이 같이 쓰는 도우미(자기 파일 안의 extension — 공용 기반은 고치지 않는다).

extension HubSectionBase {
    /// 요청 하나를 보내고 결과를 메인 큐에서 돌려준다.
    /// `HubClient`는 실행기를 약하게 쥐므로, 완료 콜백이 실행기를 붙잡아 사용자가 다른 섹션으로 옮겨도 결과(토스트·목록 갱신)가 버려지지 않게 한다.
    func hubSend(_ build: @escaping (String?) -> PetHTTPRequest, _ done: @escaping (Result<PetHTTPResponse, PetAPIError>) -> Void) {
        guard let client = ctx?.client else {
            let e = PetAPIError.hubSignedOut
            DispatchQueue.main.async { done(.failure(e)) }
            return
        }
        client.send(build) { result in
            withExtendedLifetime(client) {}
            if Thread.isMainThread { done(result) } else { DispatchQueue.main.async { done(result) } }
        }
    }

    /// 내용 자리를 한 화면으로 바꾼다.
    func hubShow(_ page: NSView) {
        let host = state.contentHost
        for v in host.subviews { v.removeFromSuperview() }
        HubKit.pin(page, in: host)
        state.show(.content)
    }
}

/// 한 화면: 위쪽 머리글(뒤로 + 제목) + 아래로 쌓이는 내용.
struct HubScreen {
    let view: NSView
    let stack: NSStackView

    init(title: String, back: (() -> Void)? = nil, trailing: [NSView] = []) {
        let parts = HubKit.scrollingStack(spacing: Double(PetTokens.Space.m))
        view = parts.scroll
        stack = parts.stack
        var head: [NSView] = []
        if let b = back { head.append(HubKit.secondaryButton("뒤로", symbol: "chevron.left", onClick: b)) }
        head.append(HubKit.label(title, font: PetTheme.title))
        head += trailing
        let row = HubKit.hstack(head, spacing: Double(PetTokens.Space.m))
        add(row, full: false)
    }

    /// 쌓는다. `full`이면 가로를 꽉 채운다(여러 줄 글이 줄바꿈되도록).
    func add(_ v: NSView, full: Bool = true) {
        stack.addArrangedSubview(v)
        if full { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    func note(_ text: String, color: NSColor = PetTheme.secondary) { add(HubKit.label(text, font: PetTheme.caption, color: color)) }
    func heading(_ text: String) { add(HubKit.label(text, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium))) }
}

/// 카드 한 줄: 제목·보조 글·배지 + 오른쪽 단추들.
final class HubActionRow: PetBox {
    init(title: String, subtitle: String? = nil, badge: String? = nil, buttons: [NSView] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        fill = PetTheme.color(\.surface)
        stroke = PetTheme.color(\.edge)
        radius = CGFloat(PetTokens.Radius.card)
        var titleViews: [NSView] = [HubKit.label(title, font: PetTheme.font(PetTokens.Font.body, PetTokens.Font.weightMedium), wrap: false)]
        if let b = badge, !b.isEmpty { titleViews.append(HubKit.label(b, font: PetTheme.caption, color: PetTheme.accent, wrap: false)) }
        let texts = HubKit.vstack([HubKit.hstack(titleViews, spacing: Double(PetTokens.Space.s))], spacing: Double(PetTokens.Space.xxs))
        if let s = subtitle, !s.isEmpty { texts.addArrangedSubview(HubKit.label(s, font: PetTheme.caption, color: PetTheme.secondary)) }
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for b in buttons { b.setContentHuggingPriority(.required, for: .horizontal) }   // 단추는 글자 크기만큼만
        let row = HubKit.hstack([texts] + buttons, spacing: Double(PetTokens.Space.s))
        addSubview(row)
        let p = CGFloat(PetTokens.Space.m)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
            row.topAnchor.constraint(equalTo: topAnchor, constant: p),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// 이름표 + 고르기 상자.
final class HubChoiceField: NSView {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ids: [String]

    init(title: String, options: [(String, String)], selected: String?) {
        ids = options.map { $0.0 }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.addItems(withTitles: options.map { $0.1 })
        if let s = selected, let i = ids.firstIndex(of: s) { popup.selectItem(at: i) }
        let stack = HubKit.vstack([HubKit.label(title, font: PetTheme.caption, color: PetTheme.secondary), popup], spacing: Double(PetTokens.Space.xs))
        HubKit.pin(stack, in: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var selectedID: String? {
        let i = popup.indexOfSelectedItem
        return ids.indices.contains(i) ? ids[i] : nil
    }
}

/// 목소리 미리 듣기. 서버가 준 https 주소만 재생한다(`HubVoice.sampleURL`이 이미 걸러 준다).
final class HubVoicePlayer {
    private var player: AVPlayer?
    private(set) var playing: URL?

    func play(_ url: URL) {
        guard url.scheme?.lowercased() == "https" else { return }
        stop()
        playing = url
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }

    func stop() {
        player?.pause()
        player = nil
        playing = nil
    }
}

/// 사진 한 장 자리표시(사진을 내려받지 않는다: 장면 이름과 사용 중 표시만 보여 준다).
enum HubArt {
    /// 나초 그림(기존 `PetArt` 재사용: 서버 그림이 있으면 그것, 없으면 번들).
    static func character(size: CGFloat) -> NSImageView {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = PetArt.image(.idle)
        v.imageScaling = .scaleProportionallyUpOrDown
        v.widthAnchor.constraint(equalToConstant: size).isActive = true
        v.heightAnchor.constraint(equalToConstant: size).isActive = true
        return v
    }
}
