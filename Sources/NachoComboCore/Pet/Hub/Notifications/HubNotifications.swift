import Foundation

// 알림·활동 섹션(NACHO-268 U2, 표 행 A7)의 Core. 요청은 순수 함수라 시험이 바이트를 그대로 확인한다.
//   GET /api/v1/me/notifications?unread&limit&before  (본문은 배열, 다음 쪽은 마지막 항목의 created_at을 `before`로)
//   POST /api/v1/me/notifications/{id}/read
//   GET·PATCH /api/v1/me/notification-settings (본문 {all_enabled, items, muted_agent_ids}; expected_version 없음)
//   GET /api/v1/activity · POST /api/v1/activity/seen
// 경로·필드는 nacho-server spec(me.tsp, me-settings.tsp, activity.tsp)을 따른다.

// MARK: - 알림 목록

public struct HubNotification: Equatable {
    public var id: String
    public var kind: String
    public var title: String
    public var body: String
    public var createdAt: String
    public var readAt: String?
    public var roomID: String?
    public var taskID: String?

    public var isUnread: Bool { readAt == nil || readAt?.isEmpty == true }
}

public struct HubNotificationPage: Equatable {
    public var items: [HubNotification]
    /// 다음 쪽을 부를 `before`. 더 없으면 nil.
    public var nextBefore: String?
    public var hasMore: Bool { nextBefore != nil }
}

public enum HubNotificationsAPI {
    public static let pageSize = 50

    public static func listRequest(_ e: ServerEndpoint, unreadOnly: Bool = false, limit: Int = HubNotificationsAPI.pageSize,
                                   before: String? = nil, bearer: String?) -> PetHTTPRequest {
        var q: [(String, String)] = []
        if unreadOnly { q.append(("unread", "true")) }
        q.append(("limit", String(limit)))
        if let b = before, !b.isEmpty { q.append(("before", b)) }
        return HubAPI.get(e, "/api/v1/me/notifications", query: q, bearer: bearer)
    }

    public static func markReadRequest(_ e: ServerEndpoint, id: String, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/me/notifications/\(id)/read", bearer: bearer)
    }

    public static func parseList(_ resp: PetHTTPResponse, limit: Int = HubNotificationsAPI.pageSize) -> Result<HubNotificationPage, PetAPIError> {
        switch HubAPI.page(resp) {
        case let .failure(e): return .failure(e)
        case let .success(page):
            let items = page.items.compactMap(notification)
            // 서버는 커서를 따로 주지 않는다: 꽉 찬 쪽이면 마지막 항목의 created_at이 다음 `before`다.
            let next = (page.items.count >= limit) ? items.last?.createdAt : nil
            return .success(HubNotificationPage(items: items, nextBefore: next))
        }
    }

    static func notification(_ o: HubObject) -> HubNotification? {
        guard let id = o.str("id"), !id.isEmpty else { return nil }
        let data = o.obj("data")
        return HubNotification(id: id, kind: o.str("kind") ?? "", title: o.str("title") ?? "", body: o.str("body") ?? "",
                               createdAt: o.str("created_at") ?? "", readAt: o.str("read_at"),
                               roomID: data?.str("room_id"), taskID: data?.str("task_id"))
    }

    /// 사이드바 배지 수: 안 읽은 알림 수(불러온 목록 기준) + 활동 피드의 안 읽은 수.
    public static func badgeCount(notifications: [HubNotification], activityUnread: Int) -> Int {
        notifications.filter { $0.isUnread }.count + max(0, activityUnread)
    }

    /// 앱처럼 사람 관련 종류는 활동 피드가 보여 주므로 알림 목록에서는 뺀다(한 사건이 두 번 보이지 않게).
    static let activityOnlyKinds: Set<String> = ["friend_request", "friend_accepted", "contact_joined", "message_request", "agreement_confirm", "push_test"]
    public static func isInboxKind(_ kind: String) -> Bool { !activityOnlyKinds.contains(kind) }

    /// 본문(body)을 보여 줘도 되는 종류. 결제 같은 종류의 본문에는 금액이 들어 있어 제목만 보인다(앱과 같다).
    static let bodyKinds: Set<String> = ["task_done", "task_failed", "task_interrupted", "schedule_result", "connection_expired", "connection_expiring"]
    public static func shownBody(_ n: HubNotification) -> String? {
        bodyKinds.contains(n.kind) && !n.body.isEmpty ? n.body : nil
    }

    /// 알림을 누르면 이동할 섹션. 없으면 nil(읽음 처리만).
    public static func destination(_ n: HubNotification) -> HubSectionID? {
        switch n.kind {
        case "usage_low", "quota_low", "payment_confirmed", "credit_purchase_confirmed", "refund", "purchase_refunded", "credit_granted",
             "billing_problem", "plan_changed", "subscription_renewed", "auto_payment":
            return .usage
        case "connector_connected", "connection_connected", "login_required", "connection_expired", "connection_expiring", "key_rotated":
            return .trust
        case "schedule_result":
            return .schedules
        default: break
        }
        if n.roomID != nil { return .rooms }
        if n.taskID != nil { return .tasks }
        return nil
    }
}

// MARK: - 알림 설정

public struct HubNotificationSettings: Equatable {
    public var allEnabled: Bool
    public var items: [String: Bool]
    public var mutedAgentIDs: [String]

    /// 서버가 값을 주지 않은 항목은 기본값(`task_delayed`·`nacho_checkin`만 꺼짐)이다.
    public func isOn(_ id: String) -> Bool { items[id] ?? HubNotificationCatalog.defaultOn(id) }
}

public struct HubNotificationItem: Equatable {
    public var id: String
    public var label: String
}

public struct HubNotificationGroup: Equatable {
    public var title: String
    public var items: [HubNotificationItem]
}

/// 앱 `NOTIFICATION_ITEMS`·`NOTIFICATION_GROUPS`와 같은 순서·문구(nacho-app settings.ko.ts).
public enum HubNotificationCatalog {
    public static let groups: [HubNotificationGroup] = [
        HubNotificationGroup(title: "일", items: [
            HubNotificationItem(id: "approval_input", label: "승인과 입력 요청"),
            HubNotificationItem(id: "task_done", label: "작업 완료"),
            HubNotificationItem(id: "task_failed", label: "작업 실패와 중단"),
            HubNotificationItem(id: "task_delayed", label: "작업 지연"),
            HubNotificationItem(id: "schedule_result", label: "예약 결과"),
            HubNotificationItem(id: "agreement_confirm", label: "약속 확정 요청"),
            HubNotificationItem(id: "resume", label: "이어서 하기 재개와 다시 묻기"),
            HubNotificationItem(id: "refund", label: "환급 처리"),
        ]),
        HubNotificationGroup(title: "계정", items: [
            HubNotificationItem(id: "relogin", label: "다시 로그인 필요"),
            HubNotificationItem(id: "low_balance", label: "사용량 적음"),
            HubNotificationItem(id: "billing_problem", label: "구독 결제 문제"),
        ]),
        HubNotificationGroup(title: "친구", items: [
            HubNotificationItem(id: "friend_request", label: "새 친구 요청"),
            HubNotificationItem(id: "friend_accepted", label: "친구 요청 수락"),
            HubNotificationItem(id: "nacho_chat_started", label: "나초끼리 대화 시작"),
        ]),
        HubNotificationGroup(title: "보안", items: [
            HubNotificationItem(id: "auto_payment", label: "자동 결제 완료"),
            HubNotificationItem(id: "key_lend_expiring", label: "열쇠 빌려주기 만료 전"),
        ]),
        HubNotificationGroup(title: "나초", items: [
            HubNotificationItem(id: "nacho_checkin", label: "나초의 안부와 아침 준비"),
        ]),
    ]

    static let offByDefault: Set<String> = ["task_delayed", "nacho_checkin"]
    public static func defaultOn(_ id: String) -> Bool { !offByDefault.contains(id) }

    /// `auto_payment`는 끌 수 없다(서버도 400 invalid_input).
    public static func canTurnOff(_ id: String) -> Bool { id != "auto_payment" }

    /// 끄면 답이 필요한 일이 멈춰 있을 수 있는 항목(앱이 끄기 전에 경고하는 두 가지).
    public static func needsWarning(_ id: String) -> Bool { id == "approval_input" || id == "agreement_confirm" }
}

public enum HubNotificationSettingsAPI {
    public static func getRequest(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/me/notification-settings", bearer: bearer)
    }

    /// 한 항목만 바꾼다(서버는 준 항목만 고친다). 끌 수 없는 항목을 끄려 하면 nil.
    public static func patchItemRequest(_ e: ServerEndpoint, id: String, on: Bool, bearer: String?) -> PetHTTPRequest? {
        if !on && !HubNotificationCatalog.canTurnOff(id) { return nil }
        return HubAPI.patch(e, "/api/v1/me/notification-settings", bearer: bearer, json: ["items": [id: on]])
    }

    public static func parse(_ resp: PetHTTPResponse) -> Result<HubNotificationSettings, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            var items: [String: Bool] = [:]
            if let raw = o.raw["items"] as? [String: Any] {
                for (k, v) in raw { if let b = v as? Bool { items[k] = b } }
            }
            return .success(HubNotificationSettings(allEnabled: o.bool("all_enabled") ?? true, items: items, mutedAgentIDs: o.strs("muted_agent_ids")))
        }
    }
}

// MARK: - 활동 피드

public struct HubActivityItem: Equatable {
    public var id: String
    public var kind: String
    public var timeLabel: String
    public var unread: Bool
    public var actorName: String?
    public var nameText: String?
    public var bodyText: String?
    public var roomID: String?
    public var day: String?
    public var action: String?

    /// 앱 `explore.activity.*` 문장.
    public var sentence: String {
        let who = nameText ?? actorName ?? "누군가"
        switch kind {
        case "friend_request": return "\(who)님이 친구 요청을 보냈어요"
        case "friend_accepted": return "\(who)님과 친구가 됐어요"
        case "contact_joined": return "\(who)님이 나초를 시작했어요"
        case "memory": return "\(who)\(HubActivityItem.subjectParticle(who)) 추억을 만들었어요"
        default: return "\(who)님의 대화 소식이 있어요"
        }
    }

    /// 이름 끝 글자에 받침이 있으면 「이」, 없으면 「가」.
    static func subjectParticle(_ name: String) -> String {
        guard let last = name.unicodeScalars.last else { return "가" }
        let v = last.value
        guard v >= 0xAC00 && v <= 0xD7A3 else { return "가" }
        return (v - 0xAC00) % 28 == 0 ? "가" : "이"
    }

    /// 눌렀을 때 갈 섹션(앱 `activityDestination`).
    public var destination: HubSectionID? {
        if roomID != nil { return .rooms }
        if day != nil { return .memory }
        if kind == "friend_request" || kind == "friend_accepted" || kind == "contact_joined" { return .friends }
        return nil
    }
}

public struct HubActivitySection: Equatable {
    public var key: String
    public var dateLabel: String
    public var items: [HubActivityItem]
}

public struct HubActivityFeed: Equatable {
    public var sections: [HubActivitySection]
    public var unreadCount: Int
    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }
}

public enum HubActivityAPI {
    static let knownKinds: Set<String> = ["friend_request", "friend_accepted", "contact_joined", "friend_chat", "memory"]
    static let knownActions: Set<String> = ["accept_decline", "message", "see_chat", "add_friend", "requested"]

    public static func feedRequest(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.get(e, "/api/v1/activity", bearer: bearer)
    }

    public static func seenRequest(_ e: ServerEndpoint, bearer: String?) -> PetHTTPRequest {
        HubAPI.post(e, "/api/v1/activity/seen", bearer: bearer)
    }

    /// 앱처럼 모르는 종류·행동은 줄 전체를 뺀다(갈 곳이 없을 수 있다).
    public static func parseFeed(_ resp: PetHTTPResponse) -> Result<HubActivityFeed, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o):
            let sections: [HubActivitySection] = o.objs("sections").compactMap { s in
                let items = s.objs("items").compactMap(item)
                if items.isEmpty { return nil }
                return HubActivitySection(key: s.str("key") ?? "", dateLabel: s.str("date_label") ?? "", items: items)
            }
            return .success(HubActivityFeed(sections: sections, unreadCount: o.int("activity_unread_count") ?? 0))
        }
    }

    static func item(_ o: HubObject) -> HubActivityItem? {
        guard let id = o.str("id"), let kind = o.str("kind"), knownKinds.contains(kind) else { return nil }
        if let a = o.str("action"), !knownActions.contains(a) { return nil }
        return HubActivityItem(id: id, kind: kind, timeLabel: o.str("time_label") ?? "", unread: o.bool("unread") ?? false,
                               actorName: o.obj("actor")?.str("display_name"), nameText: o.str("name_text"), bodyText: o.str("body_text"),
                               roomID: o.str("room_id"), day: o.str("day"), action: o.str("action"))
    }

    /// `POST /activity/seen` 응답의 안 읽은 수(없으면 0).
    public static func parseSeen(_ resp: PetHTTPResponse) -> Result<Int, PetAPIError> {
        switch HubAPI.object(resp) {
        case let .failure(e): return .failure(e)
        case let .success(o): return .success(o.int("activity_unread_count") ?? 0)
        }
    }
}
