import AppKit
import NachoComboCore

/// trust 섹션 자리. 지금은 「준비 중」이다. 담당 이슈가 이 파일만 고쳐 `load()`를 채운다(docs/HUB.md).
final class TrustSection: HubSectionBase {
    init() { super.init(id: .trust) }

    override func load() {
        showPlaceholder()
    }
}
