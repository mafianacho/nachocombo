import Foundation

// 나초 섹션(NACHO-274 U8: F2·F3·F4·F5)의 요청 만들기. 경로·필드는 nacho-server `spec/agents.tsp`·`agent-media.tsp`·`onboarding.tsp`·`social.tsp`와 같다.
// 요청은 순수 함수(HubAPI)라 시험이 바이트를 그대로 확인한다. `expected_version`은 언제나 본문이다.

public enum HubNachosAPI {
    static let root = "/api/v1/agents"

    // MARK: F4 목록·만들기·상태

    public static func list(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, root, bearer: bearer)
    }

    public static func templates(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/agent-templates", bearer: bearer)
    }

    /// 새 나초. `idempotencyKey`는 헤더와 본문 `idempotency_key`에 같이 싣는다(같은 키 재요청은 첫 응답).
    public static func create(_ e: ServerEndpoint, bearer: String?, name: String, voiceID: String? = nil, speech: HubSpeech? = nil,
                              roleNote: String? = nil, templateID: String? = nil, idempotencyKey: String) -> PetHTTPRequest {
        var body: [String: Any] = ["name": name, "idempotency_key": idempotencyKey]
        if let v = voiceID, !v.isEmpty { body["voice_id"] = v }
        if let s = speech { body["speech"] = s.json }
        if let r = roleNote, !r.isEmpty { body["role_note"] = r }
        if let t = templateID, !t.isEmpty { body["template_id"] = t }
        return HubAPI.post(e, root, bearer: bearer, json: body, idempotencyKey: idempotencyKey)
    }

    public static func setDefault(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/default", bearer: bearer)
    }

    public static func rest(_ e: ServerEndpoint, bearer: String?, id: String, version: Int?) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/rest", bearer: bearer, expectedVersion: version)
    }

    public static func wake(_ e: ServerEndpoint, bearer: String?, id: String, version: Int?) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/wake", bearer: bearer, expectedVersion: version)
    }

    public static func restore(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/restore", bearer: bearer)
    }

    public static func removalPreview(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.get(e, "\(root)/\(id)/removal-preview", bearer: bearer)
    }

    /// 삭제. 본문은 `DeletePolicies`(진행 중 작업은 기다림, 예약은 대표에게 넘김, 이 나초만의 기억은 지움 — 서버 기본과 같다).
    public static func remove(_ e: ServerEndpoint, bearer: String?, id: String, version: Int?, idempotencyKey: String) -> PetHTTPRequest {
        let policies: [String: Any] = ["task_policy": "wait", "schedule_policy": "handoff", "own_memory_policy": "delete", "idempotency_key": idempotencyKey]
        return HubAPI.delete(e, "\(root)/\(id)", bearer: bearer, json: policies, idempotencyKey: idempotencyKey, expectedVersion: version)
    }

    /// 한도: 준 필드만 바꾼다.
    public static func limits(_ e: ServerEndpoint, bearer: String?, id: String, patch: HubLimitsPatch, version: Int?) -> PetHTTPRequest {
        HubAPI.put(e, "\(root)/\(id)/limits", bearer: bearer, json: patch.json, expectedVersion: version)
    }

    // MARK: F2 프로필·목소리·특성

    public static func get(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.get(e, "\(root)/\(id)", bearer: bearer)
    }

    public static func patch(_ e: ServerEndpoint, bearer: String?, id: String, patch: HubAgentPatch, version: Int?) -> PetHTTPRequest {
        HubAPI.patch(e, "\(root)/\(id)", bearer: bearer, json: patch.json, expectedVersion: version)
    }

    public static func agentVoices(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.get(e, "\(root)/\(id)/voices", bearer: bearer)
    }

    public static func voices(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/voices", bearer: bearer)
    }

    public static func traits(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.get(e, "\(root)/\(id)/traits", bearer: bearer)
    }

    public static func refreshTraits(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/traits/refresh", bearer: bearer)
    }

    public static func hideTrait(_ e: ServerEndpoint, bearer: String?, id: String, traitID: String) -> PetHTTPRequest {
        HubAPI.delete(e, "\(root)/\(id)/traits/\(traitID)", bearer: bearer)
    }

    // MARK: F3 사진

    public static func photos(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.get(e, "\(root)/\(id)/photos", bearer: bearer)
    }

    /// 사진 만들기(크레딧을 쓴다). 확인창을 거친 뒤에만 부른다.
    public static func takePhoto(_ e: ServerEndpoint, bearer: String?, id: String, sceneID: String, idempotencyKey: String) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/photos", bearer: bearer, json: ["scene_id": sceneID, "idempotency_key": idempotencyKey], idempotencyKey: idempotencyKey)
    }

    public static func selectPhoto(_ e: ServerEndpoint, bearer: String?, id: String, key: String) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/photos/\(key)/select", bearer: bearer)
    }

    public static func deletePhoto(_ e: ServerEndpoint, bearer: String?, id: String, key: String) -> PetHTTPRequest {
        HubAPI.delete(e, "\(root)/\(id)/photos/\(key)", bearer: bearer)
    }

    public static func clearAvatar(_ e: ServerEndpoint, bearer: String?, id: String) -> PetHTTPRequest {
        HubAPI.post(e, "\(root)/\(id)/avatar/clear", bearer: bearer)
    }

    // MARK: F5 상대 프로필

    public static func userProfile(_ e: ServerEndpoint, bearer: String?, userID: String) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/users/\(userID)/profile", bearer: bearer)
    }
}

// MARK: - 본문 모양

/// 말투(`Speech`). 존댓말|반말 × 다정|차분|장난|똑부러짐.
public struct HubSpeech: Equatable {
    public var honorific: String   // polite | casual
    public var tone: String        // warm | calm | playful | crisp
    public var mimic: Bool
    public var addressAs: String?

    public init(honorific: String = "polite", tone: String = "warm", mimic: Bool = false, addressAs: String? = nil) {
        self.honorific = honorific
        self.tone = tone
        self.mimic = mimic
        self.addressAs = addressAs
    }

    public static let honorifics: [(id: String, label: String)] = [("polite", "존댓말"), ("casual", "반말")]
    public static let tones: [(id: String, label: String)] = [("warm", "다정하게"), ("calm", "차분하게"), ("playful", "장난스럽게"), ("crisp", "똑부러지게")]

    public var json: [String: Any] {
        var o: [String: Any] = ["honorific": honorific, "tone": tone, "mimic": mimic]
        if let a = addressAs, !a.isEmpty { o["address_as"] = a }
        return o
    }

    init(_ o: HubObject) {
        self.init(honorific: o.str("honorific") ?? "polite", tone: o.str("tone") ?? "warm", mimic: o.bool("mimic") ?? false, addressAs: o.str("address_as"))
    }

    public var label: String {
        let h = HubSpeech.honorifics.first { $0.id == honorific }?.label ?? honorific
        let t = HubSpeech.tones.first { $0.id == tone }?.label ?? tone
        return "\(h) · \(t)"
    }
}

/// `PATCH /agents/{id}`: 바꾸는 필드만. 한 필드라도 거부되면 서버는 아무것도 저장하지 않는다.
public struct HubAgentPatch: Equatable {
    public var name: String?
    public var phoneName: String?
    public var voiceID: String?
    public var speech: HubSpeech?
    public var roleNote: String?

    public init(name: String? = nil, phoneName: String? = nil, voiceID: String? = nil, speech: HubSpeech? = nil, roleNote: String? = nil) {
        self.name = name
        self.phoneName = phoneName
        self.voiceID = voiceID
        self.speech = speech
        self.roleNote = roleNote
    }

    public var json: [String: Any] {
        var o: [String: Any] = [:]
        if let v = name { o["name"] = v }
        if let v = phoneName { o["phone_name"] = v }
        if let v = voiceID { o["voice_id"] = v }
        if let v = speech { o["speech"] = v.json }
        if let v = roleNote { o["role_note"] = v }
        return o
    }
}

/// `PUT /agents/{id}/limits`: 바꾸는 필드만. 값은 `shared`|`own_only`.
public struct HubLimitsPatch: Equatable {
    public var memoryRead: String?
    public var memoryWrite: String?
    public var documents: String?
    public var vaultCards: Bool?
    public var autoPayment: Bool?

    public init(memoryRead: String? = nil, memoryWrite: String? = nil, documents: String? = nil, vaultCards: Bool? = nil, autoPayment: Bool? = nil) {
        self.memoryRead = memoryRead
        self.memoryWrite = memoryWrite
        self.documents = documents
        self.vaultCards = vaultCards
        self.autoPayment = autoPayment
    }

    public var json: [String: Any] {
        var o: [String: Any] = [:]
        if let v = memoryRead { o["memory_read"] = v }
        if let v = memoryWrite { o["memory_write"] = v }
        if let v = documents { o["documents"] = v }
        if let v = vaultCards { o["vault_cards"] = v }
        if let v = autoPayment { o["auto_payment"] = v }
        return o
    }
}

// MARK: - 입력 검증(서버 규칙을 그대로 옮김; 서버가 최종 판단)

public enum HubNachosValidation {
    public static let nameMax = 20
    public static let phoneNameMax = 12
    public static let roleNoteMax = 80

    /// 이름 1–20자, 줄바꿈·`@` 금지.
    public static func name(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "이름을 입력해 주세요." }
        if v.count > nameMax { return "이름은 \(nameMax)자까지 쓸 수 있어요." }
        if raw.contains("\n") || raw.contains("\r") { return "이름에는 줄바꿈을 쓸 수 없어요." }
        if v.contains("@") { return "이름에는 @를 쓸 수 없어요." }
        return nil
    }

    /// 전화 상대에게 밝히는 이름 1–12자, 숫자만은 안 됨. 비우면 기본 「AI 비서」.
    public static func phoneName(_ raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return nil }
        if v.count > phoneNameMax { return "전화 이름은 \(phoneNameMax)자까지 쓸 수 있어요." }
        if v.allSatisfy({ $0.isNumber }) { return "전화 이름은 숫자만으로 정할 수 없어요." }
        return nil
    }

    /// 역할 한 줄 0–80자.
    public static func roleNote(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).count > roleNoteMax ? "역할은 \(roleNoteMax)자까지 쓸 수 있어요." : nil
    }
}

/// 서버 오류 코드 중 이 섹션에서 자주 보는 것의 한국어(공용 `ErrorText`가 모르는 것만).
public enum HubNachosText {
    public static func message(_ e: PetAPIError) -> String {
        switch e.code ?? "" {
        case "blocked_word": return "쓸 수 없는 말이 들어 있어요."
        case "impersonation": return "사칭으로 보여서 쓸 수 없어요."
        case "duplicate_name": return "같은 이름의 나초가 이미 있어요."
        case "last_agent": return "마지막 나초는 지울 수 없어요."
        case "default_agent": return "대표 나초에는 할 수 없어요. 다른 나초를 대표로 정한 뒤 해 주세요."
        case "agent_limit": return "만들 수 있는 나초 수를 넘었어요."
        case "expired": return "되살릴 수 있는 기간이 지났어요."
        case "conflict": return "지금 쓰는 사진은 지울 수 없어요."
        case "invalid_params", "invalid_input": return "입력을 다시 확인해 주세요."
        case "limit_exceeded": return "오늘 요청 한도를 넘었어요. 내일 다시 해 주세요."
        default: return e.text
        }
    }
}

// MARK: - 응답 모델

public struct HubAgentLimits: Equatable {
    public var memoryRead: String
    public var memoryWrite: String
    public var documents: String
    public var vaultCards: Bool
    public var autoPayment: Bool

    init(_ o: HubObject?) {
        memoryRead = o?.str("memory_read") ?? "shared"
        memoryWrite = o?.str("memory_write") ?? "shared"
        documents = o?.str("documents") ?? "shared"
        vaultCards = o?.bool("vault_cards") ?? false
        autoPayment = o?.bool("auto_payment") ?? false
    }
}

public struct HubAgent: Equatable {
    public var id: String
    public var name: String
    public var status: String      // active | resting | deleting | deleted
    public var isDefault: Bool
    public var version: Int
    public var voiceID: String
    public var speech: HubSpeech
    public var roleNote: String
    public var phoneName: String
    public var flavor: String
    public var avatarURL: String?
    public var avatarKey: String?
    public var limits: HubAgentLimits
    public var unread: Int
    public var activeTaskCount: Int

    public init?(_ o: HubObject) {
        guard let id = o.str("id") ?? o.str("agent_id"), let name = o.str("name") else { return nil }
        self.id = id
        self.name = name
        status = o.str("status") ?? "active"
        isDefault = o.bool("is_default") ?? false
        version = o.int("version") ?? 0
        voiceID = o.str("voice_id") ?? ""
        speech = o.obj("speech").map(HubSpeech.init) ?? HubSpeech()
        roleNote = o.str("role_note") ?? ""
        phoneName = o.str("phone_name") ?? ""
        flavor = o.obj("look")?.str("flavor") ?? "original"
        avatarURL = o.obj("avatar")?.str("url")
        avatarKey = o.obj("avatar")?.str("key")
        limits = HubAgentLimits(o.obj("limits"))
        unread = o.int("unread") ?? 0
        activeTaskCount = o.int("active_task_count") ?? 0
    }

    public var statusLabel: String {
        switch status {
        case "resting": return "쉬는 중"
        case "deleting": return "지워지는 중"
        case "deleted": return "지워짐"
        default: return "함께하는 중"
        }
    }
}

public struct HubAgentList: Equatable {
    public var agents: [HubAgent]
    public var canCreate: Bool
    public var used: Int
    public var maxAgents: Int

    public init?(_ o: HubObject) {
        guard o.raw["agents"] is [Any] else { return nil }
        agents = o.objs("agents").compactMap(HubAgent.init)
        let l = o.obj("limits") ?? o.obj("caps")
        canCreate = l?.bool("can_create") ?? true
        used = l?.int("used") ?? agents.count
        maxAgents = l?.int("max_agents") ?? 0
    }
}

public struct HubAgentTemplate: Equatable {
    public var id: String
    public var label: String
    public var roleNote: String
    public var speech: HubSpeech

    public init?(_ o: HubObject) {
        guard let id = o.str("template_id"), let label = o.str("label") else { return nil }
        self.id = id
        self.label = label
        roleNote = o.str("role_note") ?? ""
        speech = o.obj("speech").map(HubSpeech.init) ?? HubSpeech()
    }
}

/// 삭제 전 미리보기(`RemovalPreview`). 두 번째 확인창에 그대로 보여 준다.
public struct HubRemovalPreview: Equatable {
    public var isDefault: Bool
    public var canDelete: Bool
    public var activeTasks: [String]
    public var schedules: [String]
    public var pendingRequests: Int
    public var ownMemories: Int
    public var restoreDays: Int

    public init?(_ o: HubObject) {
        guard o.bool("can_delete") != nil || o.bool("is_default") != nil else { return nil }
        isDefault = o.bool("is_default") ?? false
        canDelete = o.bool("can_delete") ?? !isDefault
        activeTasks = o.objs("active_tasks").compactMap { $0.str("title") }
        schedules = o.objs("schedules").compactMap { $0.str("title") }
        pendingRequests = o.objs("pending_requests").count
        ownMemories = o.int("own_memories") ?? 0
        restoreDays = o.int("restore_days") ?? 0
    }

    /// 한국어 요약 줄들(비어 있으면 「영향 없음」).
    public var lines: [String] {
        var out: [String] = []
        if !activeTasks.isEmpty { out.append("진행 중인 일 \(activeTasks.count)건은 끝까지 한 뒤 지워져요: " + activeTasks.prefix(3).joined(separator: ", ")) }
        if !schedules.isEmpty { out.append("맡은 예약 \(schedules.count)건은 대표 나초에게 넘어가요: " + schedules.prefix(3).joined(separator: ", ")) }
        if pendingRequests > 0 { out.append("답을 기다리는 카드 \(pendingRequests)장은 만료돼요.") }
        if ownMemories > 0 { out.append("이 나초만 아는 기억 \(ownMemories)개는 함께 지워져요.") }
        if out.isEmpty { out.append("함께 사라지는 일이 없어요.") }
        if restoreDays > 0 { out.append("지운 뒤 \(restoreDays)일 안에는 되살릴 수 있어요.") }
        return out
    }
}

public struct HubVoice: Equatable {
    public var id: String
    public var label: String
    public var description: String
    /// 서버가 준 미리듣기 주소. https가 아니면 버린다(서버가 준 주소만, 그 밖의 어디도 재생하지 않는다).
    public var sampleURL: URL?

    public init?(_ o: HubObject) {
        guard let id = o.str("voice_id") else { return nil }
        self.id = id
        label = o.str("label") ?? o.str("name") ?? id
        description = o.str("description") ?? ""
        sampleURL = HubVoice.playable(o.str("sample_url"))
    }

    static func playable(_ s: String?) -> URL? {
        guard let s = s, !s.isEmpty, let u = URL(string: s), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return nil }
        return u
    }
}

public struct HubTrait: Equatable {
    public var id: String
    public var text: String
    public var evidence: String

    public init?(_ o: HubObject) {
        guard let id = o.str("trait_id"), let text = o.str("text") else { return nil }
        self.id = id
        self.text = text
        evidence = o.str("evidence") ?? ""
    }
}

public struct HubPhoto: Equatable {
    public var key: String
    public var sceneID: String
    public var url: String
    public var inUse: Bool

    init?(_ o: HubObject) {
        guard let k = o.str("key") else { return nil }
        key = k
        sceneID = o.str("scene_id") ?? ""
        url = o.str("url") ?? ""
        inUse = o.bool("in_use") ?? false
    }
}

public struct HubPhotos: Equatable {
    public var photos: [HubPhoto]
    public var currentKey: String?
    public var remainingToday: Int
    public var nextAvailableAt: String?
    public var scenes: [(id: String, label: String)]

    public static func == (a: HubPhotos, b: HubPhotos) -> Bool {
        a.photos == b.photos && a.currentKey == b.currentKey && a.remainingToday == b.remainingToday && a.nextAvailableAt == b.nextAvailableAt
            && a.scenes.map { $0.id } == b.scenes.map { $0.id }
    }

    /// `GET /photos`(`AgentPhotos`) 또는 `POST /photos`의 `{photos: AgentPhotos, photo}`.
    public init?(_ o: HubObject) {
        let src = o.obj("photos") ?? o
        guard src.raw["photos"] is [Any] else { return nil }
        photos = src.objs("photos").compactMap(HubPhoto.init)
        currentKey = src.str("current_key")
        remainingToday = src.int("remaining_today") ?? 0
        nextAvailableAt = src.str("next_available_at")
        scenes = src.objs("scenes").compactMap { s in s.str("scene_id").map { ($0, s.str("label") ?? $0) } }
    }

    /// 만들기 확인창 문구. 크레딧을 쓴다는 것·오늘 남은 장수·남은 크레딧을 보여 준다(U6과 같은 규칙).
    public static func creditConfirmMessage(sceneLabel: String, remainingToday: Int, credits: Int?) -> String {
        var s = "「\(sceneLabel)」 사진을 만들어요. 크레딧을 써요."
        s += " 오늘 \(remainingToday)장 더 만들 수 있어요."
        if let c = credits { s += " 남은 크레딧: \(PetText.number(c))." }
        return s
    }
}

/// 상대 프로필(`UserProfile`, F5).
public struct HubUserProfile: Equatable {
    public var userID: String
    public var displayName: String
    public var handle: String?
    public var relationship: String
    public var characterName: String?
    public var flavor: String
    public var avatarURL: String?
    public var friendDays: Int?
    public var mutualCount: Int
    public var deleted: Bool

    public init?(_ o: HubObject) {
        guard let id = o.str("user_id") else { return nil }
        userID = id
        displayName = o.str("display_name") ?? "친구"
        handle = o.str("handle")
        relationship = o.str("relationship") ?? "none"
        characterName = o.str("character_name")
        flavor = o.obj("character_look")?.str("flavor") ?? "original"
        avatarURL = o.str("character_avatar_url")
        friendDays = o.int("friend_days")
        mutualCount = o.int("mutual_count") ?? 0
        deleted = o.bool("deleted") ?? false
    }

    public var relationshipLabel: String { HubRelationship.label(relationship) }
}

public enum HubRelationship {
    public static func label(_ r: String) -> String {
        switch r {
        case "friend": return "친구"
        case "outgoing_request": return "요청을 보냈어요"
        case "incoming_request": return "나에게 요청을 보냈어요"
        case "blocked": return "차단함"
        case "self": return "나"
        default: return "아직 친구가 아니에요"
        }
    }
}
