import Foundation

// 허브 대화 섹션(NACHO-269 U3): 방 목록·보관·이름·삭제(B6·B7), 메시지 검색(B8), 방별 미디어·파일·링크(B12), 문서 페이지·받은 파일(B11).
// 경로·필드는 nacho-server spec(rooms·search·media·pages .tsp)과 같다. 요청 만들기는 순수 함수라 시험이 바이트를 그대로 확인한다.
// 새 네트워크 층은 만들지 않는다: HubAPI(요청)·HubClient(실행·401 한 번 재시도)·PetAPIError(한국어 오류)를 그대로 쓴다.

/// 사용자가 쓴 값이 규칙에 맞지 않을 때의 한국어 문구.
public struct HubRoomsInputError: Error, Equatable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

public struct HubRoom: Equatable {
    public let id: String
    public let kind: String
    public let title: String?
    public let peerName: String?
    public let stored: Bool
    public let version: Int
    public let lastSeq: Int
    public let readSeq: Int
    public let muted: Bool
    public let updatedAt: String?
    public let memberCount: Int?

    public init?(_ o: HubObject) {
        guard let id = o.str("id"), !id.isEmpty else { return nil }
        self.id = id
        kind = o.str("kind") ?? "direct"
        title = o.str("title")
        peerName = o.str("peer_display_name")
        stored = o.bool("stored") ?? false
        version = o.int("version") ?? 0
        lastSeq = o.int("last_seq") ?? 0
        readSeq = o.int("read_seq") ?? 0
        muted = o.bool("muted") ?? false
        updatedAt = o.str("updated_at")
        memberCount = o.obj("member_counts").flatMap { c in
            let n = (c.int("users") ?? 0) + (c.int("agents") ?? 0)
            return n > 0 ? n : nil
        }
    }

    public var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let p = peerName?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return p }
        return kind == "character" ? "나초와의 대화" : "이름 없는 대화"
    }

    public var unread: Int { max(0, lastSeq - readSeq) }
    /// 1:1(character) 방은 이름을 바꿀 수 없다(서버 403).
    public var canRename: Bool { kind != "character" }
    /// 서버가 지우게 해 주는 방: direct·character_pair의 내 사본, group(방장만 — 아니면 서버가 403). 1:1·나초끼리 단톡은 지울 수 없다.
    public var canDelete: Bool { ["direct", "character_pair", "group"].contains(kind) }
    public var isGroup: Bool { kind == "group" }
}

public struct HubRoomSync: Equatable {
    public var rooms: [HubRoom]
    public var unseenRequestCount: Int
}

public struct HubRoomsPage {
    public var rooms: [HubRoom]
    public var next: [(String, String)]?
}

public struct HubSearchSegment: Equatable {
    public let text: String
    public let match: Bool
}

public struct HubSearchItem: Equatable {
    public let id: String
    public let kind: String
    public let segments: [HubSearchSegment]
    public let label: String
    public let dateLabel: String
    public let roomID: String?
    public let seq: Int?
    public var plainText: String { segments.map { $0.text }.joined() }
}

public struct HubSearchPage {
    public var items: [HubSearchItem]
    public var next: [(String, String)]?
}

public enum HubRoomMediaKind { case photos, files, links }

/// 방 미디어·파일 한 줄(사진·동영상은 `photos`, 그 밖의 첨부는 `files`, 둘 다 `attachment_id`로 `/media/{id}`를 받는다).
public struct HubMediaItem: Equatable {
    public let id: String
    public let kind: String
    public let name: String?
    public let mime: String?
    public let bytes: Int?
    public let seq: Int?
    public let deleted: Bool
    public var isImage: Bool { (mime ?? "").hasPrefix("image/") || kind == "image" }
}

public struct HubMediaPage {
    public var items: [HubMediaItem]
    public var total: Int?
    public var next: [(String, String)]?
}

public struct HubLinkItem: Equatable {
    public let seq: Int
    public let url: String
}

public struct HubLinksPage {
    public var items: [HubLinkItem]
    public var next: [(String, String)]?
}

public struct HubPageRef: Equatable {
    public let id: String
    public let title: String
}

public struct HubMessage: Equatable {
    public let seq: Int
    public let role: String
    public let senderName: String?
    public let text: String
    public let createdAt: String?
    public let attachments: [HubMediaItem]
    public let pageRef: HubPageRef?
    public var isMine: Bool { role == "user" }
}

public struct HubHistoryPage {
    public var messages: [HubMessage]
    public var hasMore: Bool
}

public struct HubPageBlock: Equatable {
    public let type: String
    public let text: String?
    public let items: [String]
    public let rows: [[String]]
    public let href: String?
}

public struct HubPageDoc: Equatable {
    public let id: String
    public let title: String
    public let blocks: [HubPageBlock]
}

public enum HubRoomsAPI {
    public static let titleMax = 40
    public static let pageSize = 50

    // MARK: requests (pure)

    public static func syncRequest(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/rooms/sync", bearer: bearer)
    }

    public static func getRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/rooms/\(id)", bearer: bearer)
    }

    public static func listRequest(_ e: ServerEndpoint, stored: Bool?, limit: Int, next: [(String, String)]?, bearer: String?) -> PetHTTPRequest {
        var q: [(String, String)] = []
        if let s = stored { q.append(("stored", s ? "true" : "false")) }
        q.append(("limit", String(limit)))
        q += next ?? []
        return HubAPI.get(e, "/api/v1/rooms", query: q, bearer: bearer)
    }

    public static func renameRequest(_ e: ServerEndpoint, id: String, title: String, version: Int, bearer: String?) -> PetHTTPRequest {
        HubAPI.patch(e, "/api/v1/rooms/\(id)", bearer: bearer, json: ["title": title], expectedVersion: version)
    }

    public static func storeRequest(_ e: ServerEndpoint, id: String, stored: Bool, version: Int, bearer: String?) -> PetHTTPRequest {
        HubAPI.patch(e, "/api/v1/rooms/\(id)", bearer: bearer, json: ["stored": stored], expectedVersion: version)
    }

    /// spec상 `DELETE /rooms/{id}`는 본문이 없다.
    public static func deleteRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/rooms/\(id)", bearer: bearer)
    }

    /// 검색어는 URL이 아니라 본문에 싣는다(서버 로그·트레이스에 남지 않게).
    public static func searchRequest(_ e: ServerEndpoint, query: String, roomID: String?, limit: Int, next: [(String, String)]?, bearer: String?) -> PetHTTPRequest {
        var json: [String: Any] = ["query": query, "limit": limit]
        if let r = roomID { json["room_id"] = r }
        for (k, v) in next ?? [] { json[k] = v }
        return HubAPI.post(e, "/api/v1/messages/search", bearer: bearer, json: json)
    }

    public static func roomMediaRequest(_ e: ServerEndpoint, id: String, kind: HubRoomMediaKind, next: [(String, String)]?, bearer: String?) -> PetHTTPRequest {
        let leaf: String
        switch kind {
        case .photos: leaf = "media"
        case .files: leaf = "files"
        case .links: leaf = "links"
        }
        return HubAPI.get(e, "/api/v1/rooms/\(id)/\(leaf)", query: next ?? [], bearer: bearer)
    }

    public static func historyRequest(_ e: ServerEndpoint, id: String, beforeSeq: Int?, limit: Int, bearer: String?) -> PetHTTPRequest {
        var q: [(String, String)] = [("view", "app"), ("limit", String(limit))]
        if let b = beforeSeq { q.append(("before_seq", String(b))) }
        return HubAPI.get(e, "/api/v1/rooms/\(id)/history", query: q, bearer: bearer)
    }

    public static func pageRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/pages/\(id)", bearer: bearer)
    }

    public static func pageDownloadRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/pages/\(id)/download", bearer: bearer)
    }

    public static func mediaRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/media/\(id)", bearer: bearer)
    }

    public static func mediaDeleteRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/media/\(id)", bearer: bearer)
    }

    // MARK: responses

    public static func decodeSync(_ resp: PetHTTPResponse) -> Result<HubRoomSync, PetAPIError> {
        HubAPI.object(resp).map { o in
            HubRoomSync(rooms: (o.objs("rooms") + o.objs("extra_conversations")).compactMap(HubRoom.init),
                        unseenRequestCount: o.int("unseen_request_count") ?? 0)
        }
    }

    public static func decodeRoom(_ resp: PetHTTPResponse) -> Result<HubRoom, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o): return HubRoom(o).map { .success($0) } ?? .failure(.badResponse)
        }
    }

    public static func decodeRooms(_ resp: PetHTTPResponse) -> Result<HubRoomsPage, PetAPIError> {
        HubAPI.page(resp).map { HubRoomsPage(rooms: $0.items.compactMap(HubRoom.init), next: $0.nextQuery) }
    }

    public static func decodeSearch(_ resp: PetHTTPResponse) -> Result<HubSearchPage, PetAPIError> {
        HubAPI.page(resp).map { p in
            let items: [HubSearchItem] = p.items.compactMap { o -> HubSearchItem? in
                guard let id = o.str("id") else { return nil }
                let segs = o.objs("segments").map { HubSearchSegment(text: $0.str("text") ?? "", match: $0.bool("match") ?? false) }
                return HubSearchItem(id: id, kind: o.str("kind") ?? "chat", segments: segs, label: o.str("label") ?? "", dateLabel: o.str("date_label") ?? "",
                                     roomID: o.str("room_id"), seq: o.int("seq"))
            }
            return HubSearchPage(items: items, next: p.nextQuery)
        }
    }

    static func mediaItem(_ o: HubObject) -> HubMediaItem? {
        guard let id = o.str("attachment_id"), !id.isEmpty else { return nil }
        return HubMediaItem(id: id, kind: o.str("kind") ?? "file", name: o.str("name"), mime: o.str("mime"), bytes: o.int("bytes"),
                            seq: o.int("seq"), deleted: o.bool("deleted") ?? false)
    }

    public static func decodeMedia(_ resp: PetHTTPResponse, kind: HubRoomMediaKind) -> Result<HubMediaPage, PetAPIError> {
        let key = kind == .photos ? "photos" : "items"
        let total: Int? = (try? JSONSerialization.jsonObject(with: resp.body)).flatMap { ($0 as? [String: Any])?.int("total") }
        return HubAPI.page(resp, key: key).map { HubMediaPage(items: $0.items.compactMap(mediaItem), total: total, next: $0.nextQuery) }
    }

    /// http/https 주소만 남긴다(`javascript:`·`file:` 같은 것은 누르게 두지 않는다).
    public static func decodeLinks(_ resp: PetHTTPResponse) -> Result<HubLinksPage, PetAPIError> {
        HubAPI.page(resp).map { p in
            let items: [HubLinkItem] = p.items.compactMap { o -> HubLinkItem? in
                guard let u = o.str("url"), let url = URL(string: u), let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
                return HubLinkItem(seq: o.int("seq") ?? 0, url: u)
            }
            return HubLinksPage(items: items, next: p.nextQuery)
        }
    }

    public static func decodeHistory(_ resp: PetHTTPResponse) -> Result<HubHistoryPage, PetAPIError> {
        HubAPI.page(resp).map { p in
            let msgs: [HubMessage] = p.items.compactMap { o -> HubMessage? in
                guard let seq = o.int("seq"), o.bool("interim") != true else { return nil }
                var ref: HubPageRef?
                if let a = o.obj("attachment"), a.str("kind") == "page", a.bool("deleted") != true, let fid = a.str("file_id") {
                    ref = HubPageRef(id: fid, title: a.str("name") ?? "문서")
                }
                return HubMessage(seq: seq, role: o.str("role") ?? "assistant", senderName: o.str("sender_name_snapshot"), text: o.str("text") ?? "",
                                  createdAt: o.str("created_at"), attachments: o.objs("attachments").compactMap { mediaItem($0) }, pageRef: ref)
            }
            return HubHistoryPage(messages: msgs, hasMore: (resp.header("X-Has-More") ?? "").lowercased() == "true")
        }
    }

    public static func decodePage(_ resp: PetHTTPResponse) -> Result<HubPageDoc, PetAPIError> {
        HubAPI.object(resp).map { o in
            let blocks = o.objs("blocks").map { b -> HubPageBlock in
                let rows = (b.raw["rows"] as? [Any])?.map { ($0 as? [Any])?.compactMap { $0 as? String } ?? [] } ?? []
                return HubPageBlock(type: b.str("type") ?? "", text: b.str("text"), items: b.strs("items"), rows: rows, href: b.str("href"))
            }
            return HubPageDoc(id: o.str("id") ?? "", title: o.str("title") ?? "문서", blocks: blocks)
        }
    }

    public static func decodeDone(_ resp: PetHTTPResponse) -> Result<Void, PetAPIError> { HubAPI.empty(resp) }

    // MARK: 입력 검증 (앱 규칙 그대로: title-rules.ts·use-search.ts)

    /// 이름: 앞뒤 공백 제거 → 비면 안 되고, 줄바꿈 금지, 40자(코드 포인트, 이모지 하나가 한 글자)까지.
    public static func normalizeTitle(_ raw: String) -> Result<String, HubRoomsInputError> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(HubRoomsInputError("이름을 적어 주세요.")) }
        if t.contains("\n") || t.contains("\r") { return .failure(HubRoomsInputError("이름에 줄바꿈은 쓸 수 없어요.")) }
        if t.unicodeScalars.count > titleMax { return .failure(HubRoomsInputError("이름은 \(titleMax)자까지 쓸 수 있어요.")) }
        return .success(t)
    }

    /// 검색어: 공백이나 가린 구간 글자(•)뿐이면 찾지 않는다(서버도 400).
    public static func normalizeQuery(_ raw: String) -> Result<String, HubRoomsInputError> {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.unicodeScalars.allSatisfy({ $0 == "•" || CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return .failure(HubRoomsInputError("검색어를 입력해 주세요."))
        }
        return .success(t)
    }

    // MARK: 내려받기 이름

    /// 저장 창에 미리 적어 둘 파일 이름. 경로 구분자·제어 문자·앞의 점을 없앤다(위치는 사용자가 고른다).
    public static func attachmentFileName(_ raw: String?, fallback: String) -> String {
        var s = ""
        for u in (raw ?? "").unicodeScalars {
            if u.value < 0x20 || u.value == 0x7F { continue }
            s.unicodeScalars.append("/\\:".unicodeScalars.contains(u) ? "-" : u)
        }
        // "../../etc" → "etc": 앞뒤의 점·하이픈·공백을 떼고, 겹친 하이픈은 하나로.
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".- ").union(.whitespacesAndNewlines))
        if s.count > 80 { s = String(s.prefix(80)) }
        return s.isEmpty ? fallback : s
    }

    public static func downloadFileName(title: String) -> String {
        let base = attachmentFileName(title, fallback: "문서")
        return base.lowercased().hasSuffix(".md") ? base : base + ".md"
    }
}
