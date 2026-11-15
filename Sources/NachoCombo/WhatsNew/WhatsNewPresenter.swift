import AppKit
import NachoComboCore

/// 번들의 `WhatsNew/<버전>.json`을 읽어 「새로운 기능」 창을 띄운다. 네트워크는 쓰지 않는다.
/// 파일이 없거나 읽지 못하면 창을 띄우지 않고 앱은 그대로 동작한다.
final class WhatsNewPresenter {
    static let shared = WhatsNewPresenter()

    private let bundle: Bundle
    private var window: WhatsNewWindow?

    init(bundle: Bundle = .main) { self.bundle = bundle }

    var currentVersion: String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 현재 버전의 내용 파일. 없거나 깨졌으면 nil.
    func loadContent() -> WhatsNewContent? {
        guard let url = bundle.url(forResource: currentVersion, withExtension: "json", subdirectory: "WhatsNew"),
              let data = try? Data(contentsOf: url) else { return nil }
        return WhatsNewContent.parse(data)
    }

    /// 메뉴에 「새로운 기능」을 둘지(내용이 있을 때만).
    var isAvailable: Bool { loadContent() != nil }

    /// 실행 직후 한 번: 업데이트한 뒤 처음이면 창을 띄운다. `freshInstall`은 설정 파일이 없던 첫 실행인지다.
    func showIfUpdated(freshInstall: Bool, tracker: WhatsNewTracker = WhatsNewTracker()) {
        guard let content = tracker.evaluate(current: currentVersion, content: loadContent(), freshInstall: freshInstall)
        else { return }
        present(content)
    }

    /// 메뉴에서 다시 열기.
    func showAgain() {
        guard let content = loadContent() else { return }
        present(content)
    }

    private func present(_ content: WhatsNewContent) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = WhatsNewWindow(content: content) { [bundle] name in
            bundle.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension,
                       subdirectory: "WhatsNew")
        }
        w.onClose = { [weak self] in self?.window = nil }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
