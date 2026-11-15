import Foundation

/// 계정·설정 섹션의 입력 검증(NACHO-267 U1). 나초 앱의 규칙을 그대로 옮겼다:
/// `name-rules.ts`(이름 1~40자) · `handle-rules.ts`(소문자·숫자·밑줄 3~20자) · `birthday-rules.ts`(1900년~오늘) ·
/// `issue-rules.ts`(이슈 신고 1~2000자) · `report-screen.tsx`(사용자 신고 1000자). 서버가 마지막 판정을 한다.
public enum AccountRules {
    public enum TextCheck: Equatable {
        case ok(String)
        case empty
        case tooLong
    }

    // MARK: name

    public static let nameMax = 40

    /// 줄바꿈은 공백 하나로, 앞뒤 공백은 뺀다. 길이는 코드 포인트로 센다(이모지 하나는 1자).
    public static func name(_ raw: String) -> TextCheck {
        let joined = raw.replacingOccurrences(of: "\\s*[\\r\\n]+\\s*", with: " ", options: .regularExpression)
        let value = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        return value.unicodeScalars.count > nameMax ? .tooLong : .ok(value)
    }

    // MARK: handle

    public enum HandleState: Equatable {
        case same, short, uppercase, invalid, checking, failed, available, taken, blocked
    }

    private static let handleMin = 3
    private static let handleMax = 20

    public static func handleShapeOK(_ s: String) -> Bool {
        let n = s.unicodeScalars.count
        guard n >= handleMin, n <= handleMax else { return false }
        return s.unicodeScalars.allSatisfy { ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0.value == 95 }
    }

    /// 확인 결과는 물어본 글자에만 맞는다(늦게 온 옛 답은 지금 글자를 바꾸지 못한다).
    public static func handleState(input: String, current: String, check: HandleCheckResult?, checkFailed: Bool) -> HandleState {
        if input == current { return .same }
        if input.unicodeScalars.count < handleMin { return .short }
        if input.unicodeScalars.contains(where: { $0.value >= 65 && $0.value <= 90 }) { return .uppercase }
        if !handleShapeOK(input) { return .invalid }
        if checkFailed { return .failed }
        guard let c = check, c.handle == input else { return .checking }
        switch c.status {
        case .available: return .available
        case .taken: return .taken
        case .blocked: return .blocked
        case .invalid: return .invalid
        case .unknown: return .failed   // 이 앱이 모르는 값은 확인에 실패한 것과 같다
        }
    }

    public static func handleNeedsCheck(input: String, current: String) -> Bool {
        input != current && handleShapeOK(input)
    }

    public static func canSaveHandle(_ s: HandleState) -> Bool { s == .available }

    // MARK: birthday

    public struct Day: Equatable {
        public var year: Int, month: Int, day: Int
        public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

        public static func today(_ date: Date = Date(), calendar: Calendar = .current) -> Day {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return Day(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        }
    }

    public enum BirthdayCheck: Equatable {
        case ok(String)
        case incomplete, notADate, future, tooOld
    }

    private static let firstYear = 1900

    /// 최소 나이는 서버 몫이라 상수가 없다.
    public static func birthday(_ y: String, _ m: String, _ d: String, today: Day) -> BirthdayCheck {
        let y = y.trimmingCharacters(in: .whitespaces), m = m.trimmingCharacters(in: .whitespaces), d = d.trimmingCharacters(in: .whitespaces)
        if y.count < 4 || m.isEmpty || d.isEmpty { return .incomplete }
        guard let year = Int(y), let month = Int(m), let day = Int(d), year >= 0, month >= 1, month <= 12, day >= 1 else { return .notADate }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)),
              cal.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day) else { return .notADate }
        if year < firstYear { return .tooOld }
        let value = String(format: "%04d-%02d-%02d", year, month, day)
        let now = String(format: "%04d-%02d-%02d", today.year, today.month, today.day)
        return value > now ? .future : .ok(value)
    }

    /// 서버가 준 `YYYY-MM-DD`를 칸에 나눠 담는다.
    public static func birthdayParts(_ iso: String?) -> (year: String, month: String, day: String) {
        let p = (iso ?? "").split(separator: "-").map(String.init)
        guard p.count == 3 else { return ("", "", "") }
        return (p[0], String(Int(p[1]) ?? 0), String(Int(p[2]) ?? 0))
    }

    // MARK: reports

    public static let issueDescriptionMax = 2000
    public static let userReportMax = 1000
    public static let issueCategories = ["account", "chat", "tasks", "character", "friends", "connections", "privacy", "memories", "billing", "profile", "other"]

    /// 앱의 분류 이름(`issue.category.*`).
    public static func issueCategoryTitle(_ key: String) -> String {
        switch key {
        case "account": return "계정"
        case "chat": return "채팅"
        case "tasks": return "작업·전화"
        case "character": return "음성·나초 모습"
        case "friends": return "친구"
        case "connections": return "커넥터"
        case "privacy": return "개인정보·공개 범위"
        case "memories": return "추억"
        case "billing": return "사용량·결제"
        case "profile": return "프로필"
        default: return "기타"
        }
    }

    /// 보낼 글은 쓴 그대로, 비었는지만 공백을 뺀 뒤 본다. 길이는 앱처럼 UTF-16으로 센다.
    private static func report(_ raw: String, max: Int) -> TextCheck {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return raw.utf16.count > max ? .tooLong : .ok(raw)
    }

    public static func issueDescription(_ raw: String) -> TextCheck { report(raw, max: issueDescriptionMax) }
    public static func userReport(_ raw: String) -> TextCheck { report(raw, max: userReportMax) }

    // MARK: legal

    /// 기본 브라우저로 열 수 있는 주소는 http(s)이고 호스트가 있는 것만이다.
    public static func webLink(_ s: String?) -> URL? {
        guard let s = s, let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return nil }
        return u
    }

    public struct LegalDocument: Equatable {
        public var kind: String
        public var title: String
        public var url: URL?
    }

    /// 서버가 주소를 안 준 문서를 위한 공개 주소(나초 앱 `legal-target.ts`의 PUBLIC_DOCS).
    private static let publicDocs: [String: String] = [
        "terms": "https://nachotown.com/legal/terms/2026-10-01",
        "refund_policy": "https://nachotown.com/legal/refund-policy/2026-10-01",
    ]
    private static let docKinds: [(String, String)] = [
        ("terms", "이용약관"), ("privacy", "개인정보 처리방침"), ("third_party", "개인정보 제3자 제공"),
        ("ai_transfer", "AI 서비스 개인정보 전송"), ("refund_policy", "환불 정책"),
    ]

    /// `GET /client/config`의 `legal_docs`를 우선하고, 없거나 웹 주소가 아니면 공개 주소, 그것도 없으면 주소 없음(안내만).
    public static func legalDocuments(clientConfig: Data?) -> [LegalDocument] {
        var served: [String: Any] = [:]
        if let d = clientConfig, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let docs = o["legal_docs"] as? [String: Any] { served = docs }
        return docKinds.map { kind, title in
            let fromServer = ((served[kind] as? [String: Any])?["url"] as? String).flatMap(webLink)
            return LegalDocument(kind: kind, title: title, url: fromServer ?? webLink(publicDocs[kind]))
        }
    }
}
