import Foundation

// 계정·설정 섹션(NACHO-267 U1)의 요청과 응답. 경로·필드는 nacho-server spec(`me.tsp`·`me-settings.tsp`·`social.tsp`)과 같다.
// 요청 만들기는 순수 함수라 시험이 바이트를 확인한다. 공용 `HubAPI`/`HubClient`를 그대로 쓰고 새 네트워크 층은 없다.

public struct AccountProfile: Equatable {
    public var displayName: String
    public var handle: String?
    public var birthday: String?
    public var phoneMasked: String?
    public var authProvider: String?
    public var version: Int
    public var deletedAt: String?
    public var purgeAt: String?
}

public enum HandleCheckStatus: Equatable { case available, taken, invalid, blocked, unknown }

public struct HandleCheckResult: Equatable {
    public var handle: String
    public var status: HandleCheckStatus
    public init(handle: String, status: HandleCheckStatus) { self.handle = handle; self.status = status }
}

public struct AccountPrivacy: Equatable {
    public var memoryPaused: Bool
    public var memoryIndicatorEnabled: Bool
    public var phoneDiscoverable: Bool
}

public struct AccountDeletionPreview: Equatable {
    public var runningTasks: Int
    public var scheduledActions: Int
    public var agentCount: Int
    public var runningGroupRuns: Int
    public var subscriptionActive: Bool
}

public struct AccountDeletionStatus: Equatable {
    public enum State: Equatable { case active, scheduled, purged }
    public var status: State
    public var purgeAt: String?
}

public struct AccountExportFile: Equatable {
    public var fileName: String
    public var data: Data
}

public enum HubAccountAPI {
    public struct Diagnostics: Equatable {
        public var appVersion: String, osVersion: String, deviceModel: String, language: String
        public init(appVersion: String, osVersion: String, deviceModel: String, language: String) {
            self.appVersion = appVersion; self.osVersion = osVersion; self.deviceModel = deviceModel; self.language = language
        }
        var json: [String: Any] {
            ["app_version": appVersion, "os_version": osVersion, "device_model": deviceModel, "language": language]
        }
    }

    // MARK: requests

    public static func me(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.get(e, "/api/v1/me", bearer: bearer) }

    /// `changes`는 `display_name`·`handle`·`birthday` 중 바꿀 것. `expected_version`은 언제나 본문.
    public static func patchMe(_ e: ServerEndpoint, bearer: String?, changes: [String: Any], expectedVersion: Int) -> PetHTTPRequest {
        HubAPI.patch(e, "/api/v1/me", bearer: bearer, json: changes, expectedVersion: expectedVersion)
    }

    public static func handleCheck(_ e: ServerEndpoint, handle: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/me/handle-check", query: [("handle", handle)], bearer: bearer)
    }

    public static func privacy(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.get(e, "/api/v1/me/privacy-settings", bearer: bearer) }

    /// 준 값만 바꾼다(부분 수정).
    public static func patchPrivacy(_ e: ServerEndpoint, bearer: String?, memoryPaused: Bool? = nil, memoryIndicatorEnabled: Bool? = nil,
                                    phoneDiscoverable: Bool? = nil) -> PetHTTPRequest {
        var json: [String: Any] = [:]
        if let v = memoryPaused { json["memory_paused"] = v }
        if let v = memoryIndicatorEnabled { json["memory_indicator_enabled"] = v }
        if let v = phoneDiscoverable { json["phone_discoverable"] = v }
        return HubAPI.patch(e, "/api/v1/me/privacy-settings", bearer: bearer, json: json)
    }

    public static func deleteContactMatches(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.delete(e, "/api/v1/me/contact-matches", bearer: bearer)
    }

    public static func export(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.get(e, "/api/v1/me/export", bearer: bearer) }
    public static func deletionPreview(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.get(e, "/api/v1/me/deletion-preview", bearer: bearer) }
    public static func deletionStatus(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.get(e, "/api/v1/me/deletion-status", bearer: bearer) }

    public static func cancelDeletion(_ e: ServerEndpoint, bearer: String?, idempotencyKey: String) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/me/deletion/cancel", bearer: bearer, idempotencyKey: idempotencyKey)
    }

    /// 계정 삭제(유예 시작). 화면은 `HubFeatureFlags.accountDelete`가 켜졌을 때만 이 요청을 만든다.
    public static func deleteAccount(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest { HubAPI.delete(e, "/api/v1/me", bearer: bearer) }

    public static func issueReport(_ e: ServerEndpoint, bearer: String?, description: String, category: String?, diagnostics: Diagnostics?,
                                   idempotencyKey: String) -> PetHTTPRequest {
        var json: [String: Any] = ["description": description]
        if let c = category, !c.isEmpty { json["category"] = c }
        if let d = diagnostics { json["diagnostics"] = d.json }
        return HubAPI.post(e, "/api/v1/issue-reports", bearer: bearer, json: json, idempotencyKey: idempotencyKey)
    }

    /// 사용자 신고. 다른 섹션(친구·탐색 등)이 부를 수 있게 공개한다. 상대에게 알리지 않는다.
    public static func reportUser(_ e: ServerEndpoint, userID: String, bearer: String?, description: String, idempotencyKey: String) -> PetHTTPRequest {
        // 서버 id는 UUID다. 경로를 바꾸는 글자(`/`·`?`·`#`·`%`)는 버린다.
        let seg = String(userID.filter { !"/?#%\\ ".contains($0) })
        return HubAPI.post(e, "/api/v1/users/\(seg)/report", bearer: bearer, json: ["description": description], idempotencyKey: idempotencyKey)
    }

    /// 비인증. 법적 문서 주소(`legal_docs`)를 읽는다.
    public static func clientConfig(_ e: ServerEndpoint) -> PetHTTPRequest { HubAPI.get(e, "/client/config", bearer: nil) }

    /// 사용자 신고 공개 함수(친구·탐색 등 다른 섹션이 부른다). 입력을 검사한 뒤에만 보낸다. 멱등 키는 한 번 만들어 401 재시도에도 같다.
    public static func submitUserReport(client: HubClient, userID: String, description: String, completion: @escaping (Result<Void, PetAPIError>) -> Void) {
        switch AccountRules.userReport(description) {
        case .empty:
            completion(.failure(PetAPIError(status: 0, code: "invalid_input", text: "신고 내용을 입력해 주세요.")))
        case .tooLong:
            completion(.failure(PetAPIError(status: 0, code: "invalid_input", text: "신고 내용은 \(AccountRules.userReportMax)자까지 쓸 수 있어요.")))
        case let .ok(text):
            let key = HubAPI.newIdempotencyKey()
            let e = client.endpoint
            client.send({ reportUser(e, userID: userID, bearer: $0, description: text, idempotencyKey: key) }) { r in
                completion(r.flatMap { parseCreated($0) })
            }
        }
    }

    // MARK: responses

    private static func profile(_ u: HubObject, authProvider: String? = nil) -> AccountProfile {
        AccountProfile(displayName: u.str("display_name") ?? "", handle: u.str("handle"), birthday: u.str("birthday"),
                       phoneMasked: u.obj("phone")?.str("masked"), authProvider: authProvider, version: u.int("version") ?? 0,
                       deletedAt: u.str("deleted_at"), purgeAt: u.str("purge_at"))
    }

    /// `GET /me` → `{user: {...}, auth_provider?}`
    public static func parseMe(_ resp: PetHTTPResponse) -> Result<AccountProfile, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<AccountProfile, PetAPIError> in
            guard let u = o.obj("user") else { return .failure(.badResponse) }
            return .success(profile(u, authProvider: o.str("auth_provider")))
        }
    }

    /// `PATCH /me` → User 본문 그대로.
    public static func parseUser(_ resp: PetHTTPResponse) -> Result<AccountProfile, PetAPIError> {
        HubAPI.object(resp).map { profile($0) }
    }

    public static func parseHandleCheck(_ resp: PetHTTPResponse) -> Result<HandleCheckResult, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<HandleCheckResult, PetAPIError> in
            guard let h = o.str("handle") else { return .failure(.badResponse) }
            let s: HandleCheckStatus
            switch o.str("status") {
            case "available": s = .available
            case "taken": s = .taken
            case "invalid": s = .invalid
            case "blocked": s = .blocked
            default: s = .unknown
            }
            return .success(HandleCheckResult(handle: h, status: s))
        }
    }

    public static func parsePrivacy(_ resp: PetHTTPResponse) -> Result<AccountPrivacy, PetAPIError> {
        HubAPI.object(resp).map {
            AccountPrivacy(memoryPaused: $0.bool("memory_paused") ?? false, memoryIndicatorEnabled: $0.bool("memory_indicator_enabled") ?? true,
                           phoneDiscoverable: $0.bool("phone_discoverable") ?? false)
        }
    }

    public static func parseDeletionPreview(_ resp: PetHTTPResponse) -> Result<AccountDeletionPreview, PetAPIError> {
        HubAPI.object(resp).map {
            AccountDeletionPreview(runningTasks: $0.int("running_tasks") ?? 0, scheduledActions: $0.int("scheduled_actions") ?? 0,
                                   agentCount: $0.int("agent_count") ?? 0, runningGroupRuns: $0.int("running_group_runs") ?? 0,
                                   subscriptionActive: $0.obj("subscription")?.bool("active") ?? false)
        }
    }

    public static func parseDeletionStatus(_ resp: PetHTTPResponse) -> Result<AccountDeletionStatus, PetAPIError> {
        HubAPI.object(resp).flatMap { (o: HubObject) -> Result<AccountDeletionStatus, PetAPIError> in
            let s: AccountDeletionStatus.State
            switch o.str("status") {
            case "active": s = .active
            case "scheduled": s = .scheduled
            case "purged": s = .purged
            default: return .failure(.badResponse)
            }
            return .success(AccountDeletionStatus(status: s, purgeAt: o.str("purge_at")))
        }
    }

    public static func parseDeletedCount(_ resp: PetHTTPResponse) -> Result<Int, PetAPIError> {
        HubAPI.object(resp).map { $0.int("deleted") ?? 0 }
    }

    /// 내보내기는 JSON 첨부다. 본문은 그대로 파일에 쓰고, 파일 이름은 `Content-Disposition`에서 읽는다(경로 부분은 버린다).
    public static func parseExport(_ resp: PetHTTPResponse) -> Result<AccountExportFile, PetAPIError> {
        guard (200...299).contains(resp.status) else { return .failure(HubAPI.error(resp)) }
        var name = "nacho-data.json"
        if let cd = resp.header("Content-Disposition"), let r = cd.range(of: "filename=") {
            var rest = String(cd[r.upperBound...])
            if let semi = rest.firstIndex(of: ";") { rest = String(rest[..<semi]) }
            let cleaned = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
            if !cleaned.isEmpty, cleaned != ".", cleaned != ".." { name = cleaned }
        }
        return .success(AccountExportFile(fileName: name, data: resp.body))
    }

    /// 만들었다/접수했다(201·200·204 모두).
    public static func parseCreated(_ resp: PetHTTPResponse) -> Result<Void, PetAPIError> { HubAPI.empty(resp) }

    // MARK: error text

    /// 이름·핸들·생일을 고칠 때의 서버 오류 이유를 나초 앱의 한국어 문구로.
    public static func errorText(_ e: PetAPIError) -> String {
        switch e.code {
        case "invalid_input": return "쓸 수 없는 값이에요. 다시 확인해 주세요"
        case "blocked_word": return "쓸 수 없는 표현이 들어 있어요"
        case "handle_taken": return "방금 누가 이 ID를 가져갔어요. 다른 ID를 골라 주세요"
        case "underage": return "나이 제한 때문에 이 생일로 바꿀 수 없어요"
        case "version_conflict": return "다른 기기에서 먼저 바뀌었어요. 나갔다가 다시 들어와 주세요"
        case "too_many_requests": return "방금 바꿔서 잠시 뒤에 다시 바꿀 수 있어요"
        default: return e.text
        }
    }
}
