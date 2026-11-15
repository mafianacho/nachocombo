import AppKit
import NachoComboCore

/// 「새로운 기능」 창. 한 장에 GIF 하나, 제목, 한 줄 설명. 이전·다음, 쪽 표시, 닫기. 라이트·다크 둘 다 `PetTheme`를 따른다.
/// GIF는 `NSImageView.animates`로 재생한다(소리 없음). 그림 파일이 없으면 그 자리는 비워 두고 글만 보여 준다.
final class WhatsNewWindow: NSWindow {
    static let contentSize = NSSize(width: 460, height: 500)
    private static let gifHeight: CGFloat = 240

    private let content: WhatsNewContent
    private let resolveGIF: (String) -> URL?
    private(set) var index = 0

    private let gifView = NSImageView()
    private let titleLabel = HubKit.label("", font: PetTheme.title, wrap: true)
    private let bodyLabel = HubKit.label("", font: PetTheme.body, color: PetTheme.secondary, wrap: true)
    private let pageLabel = HubKit.label("", font: PetTheme.caption, color: PetTheme.tertiary, wrap: false)
    private let prev = PetPill(title: "이전", stroke: PetTheme.color(\.edge), width: 72)
    private let next = PetPill(title: "다음", color: PetTheme.color(\.onAccent), fill: PetTheme.accent, width: 72)
    var onClose: (() -> Void)?

    init(content: WhatsNewContent, resolveGIF: @escaping (String) -> URL?) {
        self.content = content
        self.resolveGIF = resolveGIF
        super.init(contentRect: NSRect(origin: .zero, size: WhatsNewWindow.contentSize),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "새로운 기능 \(content.version)"
        isReleasedWhenClosed = false
        build()
        show(0)
        center()
    }

    private func build() {
        let root = PetBox()
        root.fill = PetTheme.color(\.window)
        contentView = root

        let frame = PetBox()
        frame.fill = PetTheme.color(\.surface)
        frame.stroke = PetTheme.color(\.edge)
        frame.radius = CGFloat(PetTokens.Radius.chip)
        frame.translatesAutoresizingMaskIntoConstraints = false
        gifView.imageScaling = .scaleProportionallyUpOrDown
        gifView.animates = true
        gifView.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(gifView)

        prev.onClick = { [weak self] in self?.go(-1) }
        next.onClick = { [weak self] in self?.go(1) }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let nav = HubKit.hstack([pageLabel, spacer, prev, next], spacing: PetTokens.Space.s)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let m = CGFloat(PetTokens.Space.xl)
        let column = HubKit.vstack([frame, titleLabel, bodyLabel, nav], spacing: PetTokens.Space.m)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -m),
            frame.widthAnchor.constraint(equalTo: column.widthAnchor),
            frame.heightAnchor.constraint(equalToConstant: WhatsNewWindow.gifHeight),
            gifView.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 8),
            gifView.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -8),
            gifView.topAnchor.constraint(equalTo: frame.topAnchor, constant: 8),
            gifView.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -8),
            titleLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            bodyLabel.widthAnchor.constraint(equalTo: column.widthAnchor),
            nav.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    var pageCount: Int { content.items.count }
    var isLast: Bool { index >= pageCount - 1 }

    func go(_ delta: Int) {
        if delta > 0 && isLast { close(); return }   // 마지막 장의 단추는 「닫기」
        show(index + delta)
    }

    func show(_ i: Int) {
        index = max(0, min(content.items.count - 1, i))
        let item = content.items[index]
        titleLabel.stringValue = item.title
        bodyLabel.stringValue = item.body
        pageLabel.stringValue = "\(index + 1) / \(pageCount)"
        gifView.image = item.gif.flatMap { resolveGIF($0) }.flatMap { NSImage(contentsOf: $0) }
        gifView.animates = true
        prev.isHidden = index == 0
        next.set(title: isLast ? "닫기" : "다음")
    }

    override func close() {
        super.close()
        gifView.image = nil
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
