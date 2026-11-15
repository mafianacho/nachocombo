import Foundation

// 기억 섹션(NACHO-273 U7, 표 행 D2·D3)의 Core. 경로·필드는 nacho-server `spec/memory.tsp`를 따른다.
//   GET·POST /api/v1/memory/facts · PATCH·DELETE /api/v1/memory/facts/{id} · POST /api/v1/memory/facts/seen
//   GET /api/v1/memory/episodes · GET·PATCH·DELETE /api/v1/memory/episodes/{id} · POST /api/v1/memory/{id}/restore
//   GET·PATCH /api/v1/me/memory-settings · DELETE /api/v1/me/memories
// `expected_version`은 언제나 본문. 사실 쪽은 `before`(마지막 created_at) 커서로 이어 읽는다(서버가 next 커서를 주지 않는다).

public struct HubMemoryFact: Equatable {
    public var id: String
    public var text: String
    public var category: String
    public var visibility: String
    public var sourceType: String
    public var authorName: String?
    public var inferred: Bool
    public var editedByUser: Bool
    public var version: Int
    public var createdAt: String
    public var seenAt: String?
    /// 아직 보지 않은 "새로 기억한 것".
    public var isUnseen: Bool { seenAt == nil }
}

public struct HubMemoryFactList: Equatable {
    public var facts: [HubMemoryFact]
    public var unseenCount: Int
    public var hasMore: Bool
    /// 다음 쪽 `before`(마지막 사실의 created_at). 더 없으면 nil.
    public var nextBefore: String? { hasMore ? facts.last?.createdAt : nil }
}

public struct HubMemoryEpisode: Equatable {
    public var id: String
    public var title: String
    public var summary: String
    public var date: String
    public var dateLabel: String?
    public var visibility: String
    public var version: Int
    public var editedByUser: Bool
    /// 편집용 원문(상세 응답에만 있다).
    public var content: String?
}

public struct HubMemorySettings: Equatable {
    public var paused: Bool
    public var indicatorEnabled: Bool
    public init(paused: Bool, indicatorEnabled: Bool) { self.paused = paused; self.indicatorEnabled = indicatorEnabled }
}

public enum HubMemoryKind: String { case fact, episode }

/// 잊은 직후 10초 동안만 되돌릴 수 있다(서버 규칙, 지나면 410 `restore_expired`). 시계는 앱이 센다 — DELETE가 시각을 주지 않는다.
public struct HubMemoryUndo: Equatable {
    public static let window: TimeInterval = 10
    public var id: String
    public var kind: HubMemoryKind
    public var forgottenAt: Date
    public init(id: String, kind: HubMemoryKind, forgottenAt: Date) { self.id = id; self.kind = kind; self.forgottenAt = forgottenAt }
    public func isExpired(now: Date) -> Bool { now.timeIntervalSince(forgottenAt) >= HubMemoryUndo.window }
}

public enum HubMemoryCategory {
    public static let all: [(id: String, title: String)] = [
        ("favorites", "좋아하는 것"), ("people", "사람들"), ("rhythm", "생활 리듬"), ("plans", "계획"), ("other", "기타"),
    ]
    public static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? "기타" }
}

/// 입력 검증(서버: 사실 본문 1–4000자, 추억 제목 1–100자·내용 ≤20000자, 글자 수는 코드 포인트. 앱: 앞뒤 공백을 자르고 비면 막는다).
public enum HubMemoryRules {
    public static let factMax = 4000
    public static let titleMax = 100
    public static let contentMax = 20000

    private static func count(_ s: String) -> Int { s.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }

    public static func factTextProblem(_ text: String) -> String? {
        let n = count(text)
        if n == 0 { return "기억할 내용을 써 주세요." }
        if n > factMax { return "기억은 \(factMax)자까지 쓸 수 있어요." }
        return nil
    }

    public static func episodeProblem(title: String, content: String) -> String? {
        let t = count(title), c = count(content)
        if t == 0 || c == 0 { return "제목과 내용을 모두 써 주세요." }
        if t > titleMax { return "제목은 \(titleMax)자까지 쓸 수 있어요." }
        if c > contentMax { return "내용은 \(contentMax)자까지 쓸 수 있어요." }
        return nil
    }
}

/// 앱(`memory.error.*`)과 같은 문구. 모르는 코드는 공용 한국어 문구(`PetAPIError.text`)를 쓴다.
public enum HubMemoryText {
    /// 로그인이 안 된 상태에서 요청하려 할 때.
    public static let signedOut = PetAPIError(status: 401, code: "unauthorized", text: "로그인이 필요해요.")

    public static func error(_ e: PetAPIError) -> String {
        switch e.code ?? "" {
        case "not_found": return "이 기억은 이제 없어요."
        case "forbidden": return "바꿀 수 없는 기억이에요."
        case "restore_expired": return "되돌릴 시간이 지났어요."
        case "version_conflict": return "다른 곳에서 바뀌었어요. 새로 불러올게요."
        case "validation_error", "invalid_input": return "쓸 수 없는 내용이에요."
        default: return e.text
        }
    }
}

public enum HubMemoryAPI {
    private static let facts = "/api/v1/memory/facts"
    private static let episodes = "/api/v1/memory/episodes"
    private static let settings = "/api/v1/me/memory-settings"

    // MARK: requests

    public static func listFacts(_ e: ServerEndpoint, bearer: String?, limit: Int = 50, before: String? = nil) -> PetHTTPRequest {
        var q: [(String, String)] = [("limit", String(limit))]
        if let b = before { q.append(("before", b)) }
        return HubAPI.get(e, facts, query: q, bearer: bearer)
    }

    public static func createFact(_ e: ServerEndpoint, bearer: String?, text: String, category: String, visibility: String, idempotencyKey: String) -> PetHTTPRequest {
        HubAPI.post(e, facts, bearer: bearer, json: ["text": text, "category": category, "visibility": visibility], idempotencyKey: idempotencyKey)
    }

    /// `confirmGuess`가 true면 짐작을 「맞아요」로 확인한다(`inferred:false`).
    public static func updateFact(_ e: ServerEndpoint, bearer: String?, id: String, text: String?, category: String?, visibility: String?,
                                  confirmGuess: Bool = false, expectedVersion: Int) -> PetHTTPRequest {
        var j: [String: Any] = [:]
        if let t = text { j["text"] = t }
        if let c = category { j["category"] = c }
        if let v = visibility { j["visibility"] = v }
        if confirmGuess { j["inferred"] = false }
        return HubAPI.patch(e, "\(facts)/\(id)", bearer: bearer, json: j, expectedVersion: expectedVersion)
    }

    public static func forgetFact(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.delete(e, "\(facts)/\(id)", bearer: bearer)
    }

    public static func markAllSeen(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "\(facts)/seen", bearer: bearer, json: ["all": true])
    }

    public static func listEpisodes(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, episodes, bearer: bearer)
    }

    public static func getEpisode(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.get(e, "\(episodes)/\(id)", bearer: bearer)
    }

    public static func updateEpisode(_ e: ServerEndpoint, bearer: String?, id: String, title: String, content: String, expectedVersion: Int) -> PetHTTPRequest {
        HubAPI.patch(e, "\(episodes)/\(id)", bearer: bearer, json: ["title": title, "content": content], expectedVersion: expectedVersion)
    }

    public static func forgetEpisode(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.delete(e, "\(episodes)/\(id)", bearer: bearer)
    }

    /// 사실·추억 공통. 10초가 지났으면 410 `restore_expired`.
    public static func restore(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/memory/\(id)/restore", bearer: bearer)
    }

    public static func getSettings(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, settings, bearer: bearer)
    }

    public static func patchSettings(_ e: ServerEndpoint, bearer: String?, paused: Bool?, indicator: Bool?) -> PetHTTPRequest {
        var j: [String: Any] = [:]
        if let p = paused { j["memory_paused"] = p }
        if let i = indicator { j["memory_indicator_enabled"] = i }
        return HubAPI.patch(e, settings, bearer: bearer, json: j)
    }

    /// 되돌릴 수 없다. `HubFeatureFlags.memoryDeleteAll`이 켜져 있을 때만 화면이 부른다.
    public static func forgetAll(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/me/memories", bearer: bearer)
    }

    // MARK: responses

    static func fact(_ o: HubObject) -> HubMemoryFact? {
        guard let id = o.str("id") else { return nil }
        return HubMemoryFact(
            id: id, text: o.str("text") ?? o.str("content") ?? "", category: o.str("category") ?? "other",
            visibility: o.str("visibility") ?? "shared", sourceType: o.str("source_type") ?? "",
            authorName: o.str("author_name_snapshot"), inferred: o.bool("inferred") ?? false,
            editedByUser: o.bool("edited_by_user") ?? false, version: o.int("version") ?? 0,
            createdAt: o.str("created_at") ?? "", seenAt: o.str("seen_at"))
    }

    static func episode(_ o: HubObject) -> HubMemoryEpisode? {
        guard let id = o.str("id") else { return nil }
        return HubMemoryEpisode(
            id: id, title: o.str("title") ?? "", summary: o.str("summary") ?? "", date: o.str("date") ?? "",
            dateLabel: o.str("date_label"), visibility: o.str("visibility") ?? "shared", version: o.int("version") ?? 0,
            editedByUser: o.bool("edited_by_user") ?? false, content: o.str("content"))
    }

    public static func decodeFact(_ r: PetHTTPResponse) -> Result<HubMemoryFact, PetAPIError> {
        switch HubAPI.object(r) {
        case let .failure(e): return .failure(e)
        case let .success(o): return fact(o).map { .success($0) } ?? .failure(.badResponse)
        }
    }

    public static func decodeFacts(_ r: PetHTTPResponse) -> Result<HubMemoryFactList, PetAPIError> {
        switch HubAPI.object(r) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            let list = o.objs("facts").compactMap(fact)
            return .success(HubMemoryFactList(facts: list, unseenCount: o.int("unseen_count") ?? 0, hasMore: o.bool("has_more") ?? false))
        }
    }

    /// 날짜 구역을 한 줄 목록으로 편다(서버 순서 그대로: 날짜 내림차순). 구역의 `date_label`을 각 항목에 붙인다.
    public static func decodeEpisodes(_ r: PetHTTPResponse) -> Result<[HubMemoryEpisode], PetAPIError> {
        switch HubAPI.object(r) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            var out: [HubMemoryEpisode] = []
            for s in o.objs("sections") {
                let label = s.str("date_label")
                for item in s.objs("items") {
                    if var ep = episode(item) {
                        if ep.dateLabel == nil { ep.dateLabel = label }
                        out.append(ep)
                    }
                }
            }
            return .success(out)
        }
    }

    public static func decodeEpisode(_ r: PetHTTPResponse) -> Result<HubMemoryEpisode, PetAPIError> {
        switch HubAPI.object(r) {
        case let .failure(e): return .failure(e)
        case let .success(o): return episode(o).map { .success($0) } ?? .failure(.badResponse)
        }
    }

    public static func decodeSettings(_ r: PetHTTPResponse) -> Result<HubMemorySettings, PetAPIError> {
        switch HubAPI.object(r) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            guard let p = o.bool("memory_paused"), let i = o.bool("memory_indicator_enabled") else { return .failure(.badResponse) }
            return .success(HubMemorySettings(paused: p, indicatorEnabled: i))
        }
    }

    /// `DELETE /me/memories` → `{deleted}`.
    public static func decodeDeleted(_ r: PetHTTPResponse) -> Result<Int, PetAPIError> {
        switch HubAPI.object(r) {
        case let .failure(e): return .failure(e)
        case let .success(o): return o.int("deleted").map { .success($0) } ?? .failure(.badResponse)
        }
    }

    /// 되돌리기 응답(200 `{kind,item}` 또는 410). 내용은 쓰지 않고 성공만 본다.
    public static func decodeRestore(_ r: PetHTTPResponse) -> Result<Void, PetAPIError> { HubAPI.empty(r) }

    /// 204 등 본문이 필요 없는 쓰기.
    public static func decodeDone(_ r: PetHTTPResponse) -> Result<Void, PetAPIError> { HubAPI.empty(r) }
}

public extension HubMemoryText {
    /// 「어디서 알았나요」 — 앱(`memory.source.*`)과 같은 문구. 서버가 문구를 주지 않아 앱이 정한다.
    static func source(_ type: String, inferred: Bool) -> String {
        switch type {
        case "chat": return "대화에서"
        case "connection": return "커넥터에서"
        case "task": return "맡긴 작업에서"
        case "user": return "내가 직접 알려 줌"
        case "inferred": return inferred ? "대화를 보고 짐작함" : "대화에서"
        case "friend": return "친구의 나초에게서 · 약속"
        case "agent_group": return "단톡방에서"
        default: return "어딘가에서 알게 됨"
        }
    }
}
