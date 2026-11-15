import Foundation

/// 「새로운 기능」 창의 한 장: 사용자 말로 쓴 제목, 한 줄 설명, 번들 안 GIF 파일 이름(없어도 된다).
public struct WhatsNewItem: Codable, Equatable {
    public let title: String
    public let body: String
    public let gif: String?

    public init(title: String, body: String, gif: String? = nil) {
        self.title = title
        self.body = body
        self.gif = gif
    }
}

/// 버전마다 앱에 번들로 들어가는 파일 하나(`Resources/WhatsNew/<version>.json`). 네트워크로 불러오지 않는다.
public struct WhatsNewContent: Codable, Equatable {
    public let version: String
    public let items: [WhatsNewItem]

    public init(version: String, items: [WhatsNewItem]) {
        self.version = version
        self.items = items
    }

    /// 읽지 못하거나 장이 하나도 없으면 nil(창을 띄우지 않는다). GIF 이름이 폴더 밖을 가리키면 그 그림만 뺀다.
    public static func parse(_ data: Data) -> WhatsNewContent? {
        guard let raw = try? JSONDecoder().decode(WhatsNewContent.self, from: data) else { return nil }
        let items = raw.items.compactMap { item -> WhatsNewItem? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return WhatsNewItem(title: title, body: item.body.trimmingCharacters(in: .whitespacesAndNewlines),
                                gif: item.gif.flatMap { safeFileName($0) })
        }
        guard !items.isEmpty, !raw.version.isEmpty else { return nil }
        return WhatsNewContent(version: raw.version, items: items)
    }

    /// 하위 폴더·상위 폴더·절대 경로는 받지 않는다(번들 폴더 안의 파일 이름만).
    static func safeFileName(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(".."), !name.hasPrefix(".") else { return nil }
        return name
    }
}
