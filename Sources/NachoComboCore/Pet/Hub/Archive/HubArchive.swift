import Foundation

// 보관함 섹션(NACHO-264 U9: I2). 파일 목록·삭제·만들기 옵션. 파일 열기는 서명 URL이 아니라 본인 토큰 다운로드 경로를 쓰고,
// 저장 위치는 사용자가 고른다(화면 쪽 NSSavePanel).

public struct HubArchiveFile: Equatable {
    public var id: String
    public var name: String
    /// page | file | media
    public var kind: String
    public var detail: String?
    public var sourceLabel: String?
    public var author: String
    public var dateLabel: String
    public var isVideo: Bool

    /// 열 수 있는(저장할 수 있는) 종류. 지식 문서(file)는 내려받는 경로가 없다.
    public var canSave: Bool { kind == "page" || kind == "media" }
}

public struct HubArchiveList: Equatable {
    public var files: [HubArchiveFile]
    public var nextCursor: String?
    public var hasMore: Bool { nextCursor != nil }
}

public struct HubCreateOption: Equatable {
    public var kind: String
    public var title: String
    public var formats: [String]
    public var promptText: String
    public var creditText: String?
}

public struct HubCreateOptions: Equatable {
    public var options: [HubCreateOption]
    public var restrictionCount: Int
}

public enum HubArchiveAPI {
    public static func list(_ e: ServerEndpoint, bearer: String?, cursor: String? = nil) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/archive/files", query: cursor.map { [("cursor", $0)] } ?? [], bearer: bearer)
    }

    public static func remove(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/archive/files/\(id)", bearer: bearer)
    }

    public static func createOptions(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/archive/create-options", bearer: bearer)
    }

    /// 페이지 원문(마크다운). 본인 토큰으로 받는다.
    public static func downloadPage(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/pages/\(id)/download", bearer: bearer)
    }

    /// 미디어 원본. 본인 토큰으로 받는다.
    public static func downloadMedia(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/media/\(id)", bearer: bearer)
    }

    /// 저장 이름: 경로 구분·제어 문자를 지우고 길이를 제한한다.
    public static func safeFileName(_ name: String, fallback: String, ext: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var base = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: CharacterSet(charactersIn: ". _"))
        if base.isEmpty { base = fallback }
        if base.count > 80 { base = String(base.prefix(80)) }
        return base.lowercased().hasSuffix("." + ext) ? base : base + "." + ext
    }

    public static func decodeList(_ resp: PetHTTPResponse) -> Result<HubArchiveList, PetAPIError> {
        HubAPI.object(resp).map { o in
            var files: [HubArchiveFile] = []
            for s in o.objs("file_sections") {
                let label = s.str("date_label") ?? s.str("key") ?? ""
                for it in s.objs("items") {
                    guard let id = it.str("id") else { continue }
                    files.append(HubArchiveFile(id: id, name: it.str("name") ?? "이름 없는 파일", kind: it.str("kind") ?? "file", detail: it.str("detail"),
                                                sourceLabel: it.str("source_label"), author: it.str("author_name_snapshot") ?? "", dateLabel: label, isVideo: false))
                }
            }
            for s in o.objs("media_sections") {
                let label = s.str("date_label") ?? s.str("key") ?? ""
                for it in s.objs("items") {
                    guard let id = it.str("id") else { continue }
                    let video = it.bool("is_video") ?? false
                    files.append(HubArchiveFile(id: id, name: video ? "동영상" : "사진", kind: "media", detail: it.str("duration_label"),
                                                sourceLabel: nil, author: it.str("author_name_snapshot") ?? "", dateLabel: label, isVideo: video))
                }
            }
            let next = o.str("next_cursor").flatMap { $0.isEmpty ? nil : $0 }
            return HubArchiveList(files: files, nextCursor: next)
        }
    }

    public static func decodeCreateOptions(_ resp: PetHTTPResponse) -> Result<HubCreateOptions, PetAPIError> {
        HubAPI.object(resp).map { o in
            let opts = o.objs("options").map { x -> HubCreateOption in
                let kind = x.str("kind") ?? ""
                var credit: String?
                if let c = x.obj("credit"), let lo = c.int("estimate_min"), let hi = c.int("estimate_max") {
                    credit = lo == hi ? "예상 \(PetText.number(lo)) 크레딧" : "예상 \(PetText.number(lo))~\(PetText.number(hi)) 크레딧"
                }
                return HubCreateOption(kind: kind, title: kind == "image" ? "이미지" : "문서", formats: x.strs("formats"),
                                       promptText: x.str("prompt_text") ?? "", creditText: credit)
            }
            return HubCreateOptions(options: opts, restrictionCount: o.objs("restrictions").count)
        }
    }

    public static func decodeDeleted(_ resp: PetHTTPResponse) -> Result<Void, PetAPIError> { HubAPI.empty(resp) }
}
