import Foundation

// Gadget actions Nacho may run from the chat (NACHO-138): one connector capability per gadget function.
// Contract (see PetCommands.swift): names are `combo_*`, Korean descriptions of at most 200 characters, closed
// parameter lists. Names must not contain the words nacho-server's `classify_name` turns into payment / deletion /
// message approval kinds (pay, purchase, checkout, buy, phone call, delete, remove, publish, book, reserve, send,
// post), so an approval card for these shows the neutral `other` kind.
//
// Actions that carry what is on the Mac to the server (clipboard text, a file, a capture) are declared with
// `"approval": "required"` unless the user switched "always allow" on for that gadget (`PetGadgetTrust`).

public enum PetCaptureMode: String, Equatable, CaseIterable {
    /// The user drags over an area.
    case area
    /// The whole screen under the pointer.
    case screen
}

public struct PetMouseChange: Equatable {
    public var reverse: Bool?
    public var smooth: Bool?
    public var speed: Double?
    public init(reverse: Bool? = nil, smooth: Bool? = nil, speed: Double? = nil) {
        self.reverse = reverse
        self.smooth = smooth
        self.speed = speed
    }
    public var isEmpty: Bool { reverse == nil && smooth == nil && speed == nil }
}

public struct PetClockChange: Equatable {
    public var date: Bool?
    public var weekday: Bool?
    public var seconds: Bool?
    public init(date: Bool? = nil, weekday: Bool? = nil, seconds: Bool? = nil) {
        self.date = date
        self.weekday = weekday
        self.seconds = seconds
    }
    public var isEmpty: Bool { date == nil && weekday == nil && seconds == nil }
}

public enum PetGadgetAction: Equatable {
    case clipboardList
    /// Content leaves the Mac: approval card unless "always allow". 1-based index of the last list.
    case clipboardRead(Int)
    case clipboardRecopy(Int)
    case clipboardClear
    case shelfList
    /// Content leaves the Mac.
    case shelfGive(Int)
    case shelfForget(Int)
    /// Content leaves the Mac.
    case captureAsk(PetCaptureMode)
    case captureCloseAll
    case monitorRead
    case diskTop(Int)
    /// minutes 0 = until switched off.
    case keepAwake(on: Bool, minutes: Int)
    case focusDim(on: Bool)
    case menuBar(hidden: Bool)
    case deviceStatus
    case micMute(Bool)
    /// An empty change reads the settings.
    case mouseTune(PetMouseChange)
    case appSwitchList
    /// An empty change reads the settings.
    case clockDisplay(PetClockChange)

    public var capability: String {
        switch self {
        case .clipboardList: return PetGadgetCommands.clipboardList
        case .clipboardRead: return PetGadgetCommands.clipboardRead
        case .clipboardRecopy: return PetGadgetCommands.clipboardRecopy
        case .clipboardClear: return PetGadgetCommands.clipboardClear
        case .shelfList: return PetGadgetCommands.shelfList
        case .shelfGive: return PetGadgetCommands.shelfGive
        case .shelfForget: return PetGadgetCommands.shelfForget
        case .captureAsk: return PetGadgetCommands.captureAsk
        case .captureCloseAll: return PetGadgetCommands.captureCloseAll
        case .monitorRead: return PetGadgetCommands.monitorRead
        case .diskTop: return PetGadgetCommands.diskTop
        case .keepAwake: return PetGadgetCommands.keepAwake
        case .focusDim: return PetGadgetCommands.focusDim
        case .menuBar: return PetGadgetCommands.menuBar
        case .deviceStatus: return PetGadgetCommands.deviceStatus
        case .micMute: return PetGadgetCommands.micMute
        case .mouseTune: return PetGadgetCommands.mouseTune
        case .appSwitchList: return PetGadgetCommands.appSwitchList
        case .clockDisplay: return PetGadgetCommands.clockDisplay
        }
    }

    /// The gadget that has to be on for the action.
    public var gadget: ModuleID { PetGadgetCommands.owner[capability] ?? .nachoPet }
}

public enum PetGadgetCommands {
    public static let clipboardList = "combo_clipboard_list"
    public static let clipboardRead = "combo_clipboard_read"
    public static let clipboardRecopy = "combo_clipboard_recopy"
    public static let clipboardClear = "combo_clipboard_clear"
    public static let shelfList = "combo_shelf_list"
    public static let shelfGive = "combo_shelf_give"
    public static let shelfForget = "combo_shelf_forget"
    public static let captureAsk = "combo_capture_ask"
    public static let captureCloseAll = "combo_capture_close_all"
    public static let monitorRead = "combo_monitor_read"
    public static let diskTop = "combo_disk_top"
    public static let keepAwake = "combo_keep_awake"
    public static let focusDim = "combo_focus_dim"
    public static let menuBar = "combo_menu_bar"
    public static let deviceStatus = "combo_device_status"
    public static let micMute = "combo_mic_mute"
    public static let mouseTune = "combo_mouse_tune"
    public static let appSwitchList = "combo_app_switch_list"
    public static let clockDisplay = "combo_clock_display"

    /// In hello order.
    public static let names = [clipboardList, clipboardRead, clipboardRecopy, clipboardClear,
                               shelfList, shelfGive, shelfForget, captureAsk, captureCloseAll,
                               monitorRead, diskTop, keepAwake, focusDim, menuBar,
                               deviceStatus, micMute, mouseTune, appSwitchList, clockDisplay]

    /// Which gadget each capability belongs to (it has to be on; `gadget_off` otherwise).
    public static let owner: [String: ModuleID] = [
        clipboardList: .clipboard, clipboardRead: .clipboard, clipboardRecopy: .clipboard, clipboardClear: .clipboard,
        shelfList: .fileShelf, shelfGive: .fileShelf, shelfForget: .fileShelf,
        captureAsk: .captureFloat, captureCloseAll: .captureFloat,
        monitorRead: .systemMonitor, diskTop: .diskMap, keepAwake: .keepAwake, focusDim: .focusDim, menuBar: .menuBar,
        deviceStatus: .deviceControl, micMute: .deviceControl, mouseTune: .mouseTune,
        appSwitchList: .appSwitch, clockDisplay: .calendarClock,
    ]

    /// Capabilities that carry content from the Mac to the server, and the gadget whose "always allow" switch frees
    /// them from the approval card. Always a capability of its own, because approval is declared per capability.
    public static let contentSending: [String: ModuleID] = [clipboardRead: .clipboard, shelfGive: .fileShelf, captureAsk: .captureFloat]

    /// Gadgets that can be "always allowed" (the owners of `contentSending`).
    public static let trustable: [ModuleID] = [.clipboard, .fileShelf, .captureFloat]

    /// The content-sending capabilities of one gadget.
    public static func contentCapabilities(of gadget: ModuleID) -> [String] {
        names.filter { contentSending[$0] == gadget }
    }

    public static let maxClipboardIndex = 500
    public static let maxShelfIndex = 100
    public static let maxDiskItems = 20
    public static let maxKeepAwakeMinutes = 1440
    public static let mouseSpeeds: [Double] = GadgetOptions.mouseSpeedChoices

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { o["required"] = required }
        return o
    }

    private static func index(_ max: Int) -> [String: Any] {
        ["type": "integer", "minimum": 1, "maximum": max, "description": "목록의 번호(1부터)"]
    }

    /// Korean description (at most 200 characters) and JSON schema.
    public static func spec(_ name: String) -> (description: String, schema: [String: Any])? {
        switch name {
        case clipboardList:
            return ("클립보드 기록의 최근 항목 목록(번호·종류·길이·복사한 시각, 내용 미리보기는 없어요)을 봐요. "
                    + "내용을 읽거나 다시 복사하기 전에 번호를 확인할 때 써요.", object([:]))
        case clipboardRead:
            return ("클립보드 기록의 N번 항목 내용을 읽어요(최대 4,000자). 내용이 서버로 나가므로 실행 전에 사용자 승인이 필요해요. "
                    + "\"방금 복사한 거 뭐야\"처럼 내용이 필요할 때만 써요.", object(["index": index(maxClipboardIndex)], required: ["index"]))
        case clipboardRecopy:
            return ("클립보드 기록의 N번 항목을 다시 복사해 맨 위로 올려요. 내용은 읽지 않아요. \"아까 그거 다시 복사해 줘\"처럼 쓸 때 써요.",
                    object(["index": index(maxClipboardIndex)], required: ["index"]))
        case clipboardClear:
            return ("클립보드 기록을 비워요(고정한 항목은 남아요). 비운 기록은 되돌릴 수 없어요. 사용자가 분명히 비우라고 할 때만 써요.", object([:]))
        case shelfList:
            return ("파일 선반에 올려 둔 항목 목록(번호·이름·종류·크기)을 봐요. 파일 내용은 보내지 않아요. "
                    + "나초에게 넘기거나 빼기 전에 번호를 확인할 때 써요.", object([:]))
        case shelfGive:
            return ("파일 선반의 N번 항목을 나초에게 넘겨요(대화에 첨부돼요). 파일 내용이 서버로 나가므로 실행 전에 사용자 승인이 필요해요. "
                    + "사용자가 보내 달라고 한 파일만 써요.", object(["index": index(maxShelfIndex)], required: ["index"]))
        case shelfForget:
            return ("파일 선반의 N번 항목을 선반에서 빼요. 원본 파일은 건드리지 않고, 선반에서 되돌리기 할 수 있어요.",
                    object(["index": index(maxShelfIndex)], required: ["index"]))
        case captureAsk:
            return ("화면을 캡처해 나초에게 물어요. mode=area는 사용자가 드래그한 영역, screen은 포인터가 있는 화면 전체예요. "
                    + "화면 내용이 서버로 나가므로 실행 전에 사용자 승인이 필요해요. 화면 권한이 필요해요.",
                    object(["mode": ["type": "string", "enum": PetCaptureMode.allCases.map { $0.rawValue },
                                     "description": "area=드래그한 영역, screen=화면 전체"]], required: ["mode"]))
        case captureCloseAll:
            return ("캡처 고정 가젯으로 띄워 둔 고정 창을 모두 닫아요. 저장하지 않은 캡처는 사라져요. \"고정한 캡처 다 닫아 줘\"처럼 쓸 때 써요.", object([:]))
        case monitorRead:
            return ("시스템 모니터로 지금 값을 읽어요: CPU 사용률, 메모리, 네트워크 속도, 배터리, 시동 디스크 사용률. "
                    + "\"맥 지금 느려?\"처럼 상태를 물을 때 써요.", object([:]))
        case diskTop:
            return ("디스크 맵의 마지막 스캔에서 용량이 큰 폴더·파일 상위 N개(기본 10, 최대 20)를 읽어요. 스캔이 없으면 스캔을 시작하고 알려 줘요. "
                    + "읽기만 하고 지우거나 옮기지 않아요.",
                    object(["count": ["type": "integer", "minimum": 1, "maximum": maxDiskItems, "description": "항목 수(기본 10)"]]))
        case keepAwake:
            return ("깨어 있기(잠자기 방지)를 켜거나 꺼요. on=true일 때 minutes(1~1440)로 시간을 정하고, 없으면 끌 때까지 깨어 있어요. "
                    + "\"2시간 동안 안 꺼지게 해 줘\"처럼 쓸 때 써요.",
                    object(["on": ["type": "boolean"],
                            "minutes": ["type": "integer", "minimum": 1, "maximum": maxKeepAwakeMinutes, "description": "켤 때만, 분 단위"]],
                           required: ["on"]))
        case focusDim:
            return ("집중 디밍(맨 앞 창만 밝게)을 잠시 멈추거나 다시 시작해요. on=false는 가젯을 끄지 않고 화면만 밝게 돌려요. "
                    + "강도는 combo_set_dim_strength로 바꿔요.", object(["on": ["type": "boolean"]], required: ["on"]))
        case menuBar:
            return ("메뉴 막대 정리 가젯의 숨김 아이콘을 접거나 펼쳐요. hidden=true는 아이콘을 숨기고 false는 보여 줘요. "
                    + "\"메뉴 막대 아이콘 숨겨 줘\"처럼 쓸 때 써요.", object(["hidden": ["type": "boolean"]], required: ["hidden"]))
        case deviceStatus:
            return ("기기 제어 가젯이 보는 현재 상태를 읽어요: 소리 출력·입력 장치 이름, 소리 크기, 마이크 음소거, 화면 밝기. "
                    + "소리 크기·밝기를 바꾸는 건 combo_set_system을 써요.", object([:]))
        case micMute:
            return ("마이크를 음소거하거나 해제해요. muted=true가 음소거예요. 언제든 되돌릴 수 있어요. "
                    + "\"마이크 꺼 줘\"처럼 쓸 때 써요.", object(["muted": ["type": "boolean"]], required: ["muted"]))
        case mouseTune:
            return ("마우스 조정 가젯의 설정을 읽거나 바꿔요: reverse(스크롤 방향 뒤집기), smooth(부드러운 스크롤), "
                    + "speed(0.5·1·1.5·2·3). 바꿀 항목만 넣고, 아무것도 안 넣으면 지금 값을 읽어요.",
                    object(["reverse": ["type": "boolean"], "smooth": ["type": "boolean"],
                            "speed": ["type": "number", "enum": mouseSpeeds]]))
        case appSwitchList:
            return ("앱 전환 가젯에 등록된 앱 단축키 목록(앱 이름·단축키)을 읽어요. 읽기만 해요. "
                    + "앱을 바로 열거나 전환하려면 combo_open_app·combo_focus_app을 써요.", object([:]))
        case clockDisplay:
            return ("달력 시계 가젯의 표시 설정을 읽거나 바꿔요: date(날짜), weekday(요일), seconds(초). "
                    + "바꿀 항목만 넣고, 아무것도 안 넣으면 지금 값을 읽어요. 일정 내용은 보지 않아요.",
                    object(["date": ["type": "boolean"], "weekday": ["type": "boolean"], "seconds": ["type": "boolean"]]))
        default:
            return nil
        }
    }

    // MARK: parsing

    private static func present(_ v: Any?) -> Bool { v != nil && !(v is NSNull) }

    private static func unknownKeys(_ p: [String: Any], allowed: Set<String>) -> String? {
        let extra = Set(p.keys).subtracting(allowed)
        guard !extra.isEmpty else { return nil }
        return "unknown field\(extra.count == 1 ? "" : "s") \(extra.sorted().joined(separator: ", "))"
    }

    private static func requiredIndex(_ p: [String: Any], max: Int) -> Result<Int, PetCommandProblem> {
        if let why = unknownKeys(p, allowed: ["index"]) { return .failure(.badParams(why)) }
        guard let n = PetCommands.integer(p["index"]), (1...max).contains(n) else {
            return .failure(.badParams("index must be a whole number from 1 to \(max)"))
        }
        return .success(n)
    }

    private static func requiredBool(_ p: [String: Any], key: String, allowed: Set<String>) -> Result<Bool, PetCommandProblem> {
        if let why = unknownKeys(p, allowed: allowed) { return .failure(.badParams(why)) }
        guard let b = PetCommands.bool(p[key]) else { return .failure(.badParams("\(key) must be true or false")) }
        return .success(b)
    }

    private static func optionalBool(_ p: [String: Any], key: String) -> Result<Bool?, PetCommandProblem> {
        guard present(p[key]) else { return .success(nil) }
        guard let b = PetCommands.bool(p[key]) else { return .failure(.badParams("\(key) must be true or false")) }
        return .success(b)
    }

    /// A JSON number (not a boolean, not a string).
    private static func number(_ v: Any?) -> Double? {
        guard let v = v, PetCommands.bool(v) == nil, !(v is String), !(v is Bool) else { return nil }
        if let n = v as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// nil when `capability` is not a gadget action.
    public static func parse(capability: String, params p: [String: Any]) -> Result<PetGadgetAction, PetCommandProblem>? {
        switch capability {
        case clipboardList: return noParams(p, .clipboardList)
        case clipboardRead: return requiredIndex(p, max: maxClipboardIndex).map { .clipboardRead($0) }
        case clipboardRecopy: return requiredIndex(p, max: maxClipboardIndex).map { .clipboardRecopy($0) }
        case clipboardClear: return noParams(p, .clipboardClear)
        case shelfList: return noParams(p, .shelfList)
        case shelfGive: return requiredIndex(p, max: maxShelfIndex).map { .shelfGive($0) }
        case shelfForget: return requiredIndex(p, max: maxShelfIndex).map { .shelfForget($0) }
        case captureAsk:
            if let why = unknownKeys(p, allowed: ["mode"]) { return .failure(.badParams(why)) }
            guard let raw = p["mode"] as? String, let mode = PetCaptureMode(rawValue: raw) else {
                return .failure(.badParams("mode must be one of \(PetCaptureMode.allCases.map { $0.rawValue }.joined(separator: ", "))"))
            }
            return .success(.captureAsk(mode))
        case captureCloseAll: return noParams(p, .captureCloseAll)
        case monitorRead: return noParams(p, .monitorRead)
        case diskTop:
            if let why = unknownKeys(p, allowed: ["count"]) { return .failure(.badParams(why)) }
            guard present(p["count"]) else { return .success(.diskTop(10)) }
            guard let n = PetCommands.integer(p["count"]), (1...maxDiskItems).contains(n) else {
                return .failure(.badParams("count must be a whole number from 1 to \(maxDiskItems)"))
            }
            return .success(.diskTop(n))
        case keepAwake:
            if let why = unknownKeys(p, allowed: ["on", "minutes"]) { return .failure(.badParams(why)) }
            guard let on = PetCommands.bool(p["on"]) else { return .failure(.badParams("on must be true or false")) }
            guard present(p["minutes"]) else { return .success(.keepAwake(on: on, minutes: 0)) }
            guard on else { return .failure(.badParams("minutes only goes with on=true")) }
            guard let m = PetCommands.integer(p["minutes"]), (1...maxKeepAwakeMinutes).contains(m) else {
                return .failure(.badParams("minutes must be a whole number from 1 to \(maxKeepAwakeMinutes)"))
            }
            return .success(.keepAwake(on: true, minutes: m))
        case focusDim: return requiredBool(p, key: "on", allowed: ["on"]).map { .focusDim(on: $0) }
        case menuBar: return requiredBool(p, key: "hidden", allowed: ["hidden"]).map { .menuBar(hidden: $0) }
        case deviceStatus: return noParams(p, .deviceStatus)
        case micMute: return requiredBool(p, key: "muted", allowed: ["muted"]).map { .micMute($0) }
        case mouseTune:
            if let why = unknownKeys(p, allowed: ["reverse", "smooth", "speed"]) { return .failure(.badParams(why)) }
            var change = PetMouseChange()
            switch optionalBool(p, key: "reverse") { case let .success(b): change.reverse = b; case let .failure(e): return .failure(e) }
            switch optionalBool(p, key: "smooth") { case let .success(b): change.smooth = b; case let .failure(e): return .failure(e) }
            if present(p["speed"]) {
                guard let s = number(p["speed"]), mouseSpeeds.contains(s) else {
                    return .failure(.badParams("speed must be one of \(mouseSpeeds.map { String($0) }.joined(separator: ", "))"))
                }
                change.speed = s
            }
            return .success(.mouseTune(change))
        case appSwitchList: return noParams(p, .appSwitchList)
        case clockDisplay:
            if let why = unknownKeys(p, allowed: ["date", "weekday", "seconds"]) { return .failure(.badParams(why)) }
            var change = PetClockChange()
            switch optionalBool(p, key: "date") { case let .success(b): change.date = b; case let .failure(e): return .failure(e) }
            switch optionalBool(p, key: "weekday") { case let .success(b): change.weekday = b; case let .failure(e): return .failure(e) }
            switch optionalBool(p, key: "seconds") { case let .success(b): change.seconds = b; case let .failure(e): return .failure(e) }
            return .success(.clockDisplay(change))
        default:
            return nil
        }
    }

    private static func noParams(_ p: [String: Any], _ action: PetGadgetAction) -> Result<PetGadgetAction, PetCommandProblem>? {
        if let why = unknownKeys(p, allowed: []) { return .failure(.badParams(why)) }
        return .success(action)
    }

    /// Words nacho-server's `classify_name` maps to payment / deletion / message kinds; no capability name has one.
    public static let serverClassifierWords = ["pay", "purchase", "checkout", "buy", "phone", "call", "delete", "remove", "publish",
                                               "book", "reserve", "send", "post"]
}
