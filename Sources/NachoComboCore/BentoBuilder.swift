import Foundation

/// Turns what each tool's module has right now into its widget body. The app reads the modules; these functions only
/// shape plain values, so the rules (what shows when, what falls back to the basic widget) are tested on Linux.
/// A tool that is off and has no data of its own gets `.basic` with the line "켜면 …" (what it would show).
public enum BentoBuilder {
    /// The basic widget's line for a tool that is off or has nothing to show.
    public static func offLine(_ id: ModuleID) -> String {
        switch id {
        case .systemMonitor: return "켜면 CPU·메모리·디스크·네트워크를 보여요"
        case .computerUse: return "MCP 클라이언트가 이 맥을 보고 조작해요"
        case .windowSnap: return "켜면 창을 반·4분의 1·3분의 1로 붙여요"
        case .keepAwake: return "켜면 맥이 잠들지 않게 붙잡아 둬요"
        case .clipboard: return "켜면 복사한 것을 기억해요"
        case .captureFloat: return "켜면 캡처를 화면 위에 띄워 둬요"
        case .focusDim: return "켜면 다른 창이 어두워져요"
        case .deviceControl: return "켜면 소리 장치와 볼륨을 보여요"
        case .calendarClock: return "켜면 다음 일정을 보여요"
        case .diskMap: return "디스크를 무엇이 채우는지 보여요"
        case .fileShelf: return "켜면 파일을 잠깐 올려 둘 수 있어요"
        case .menuBar: return "켜면 상단바 아이콘을 접어 둬요"
        case .appSwitch: return "최근 앱 순서로 전환해요"
        case .mouseTune: return "휠 마우스의 스크롤 방향과 버튼을 고쳐요"
        case .nachoPet: return "나초가 화면 구석에서 기다려요"
        }
    }

    // MARK: per tool

    /// Signed in or not, from the pet's session (valid whether the pet is on or off).
    public static func pet(auth: PetAuthPhase, running: Bool) -> BentoBody {
        guard running else { return .pet(line: "켜면 나초가 화면에 나와요", action: nil, signedIn: auth == .signedIn) }
        switch auth {
        case .signedIn:
            return .pet(line: "눌러서 나초와 대화해요", action: "대화 열기", signedIn: true)
        case .signingIn:
            return .pet(line: "브라우저에서 로그인하는 중이에요", action: nil, signedIn: false)
        case .failed:
            return .pet(line: "로그인하지 못했어요. 다시 해 주세요", action: "나초 계정으로 로그인", signedIn: false)
        case .signedOut:
            return .pet(line: "로그인하면 말을 걸 수 있어요", action: "나초 계정으로 로그인", signedIn: false)
        }
    }

    /// The mini board's short version of the pet: "로그인 필요" / "눌러서 로그인 ›".
    public static func petShort(auth: PetAuthPhase) -> (big: String, caption: String, attention: Bool) {
        switch auth {
        case .signedIn: return ("연결됨", "눌러서 대화 ›", false)
        case .signingIn: return ("로그인 중", "브라우저를 확인해 주세요", true)
        case .signedOut, .failed: return ("로그인 필요", "눌러서 로그인 ›", true)
        }
    }

    /// CPU and memory in percent (0…100), the startup disk as a fraction, network in bytes per second. Nil = not
    /// measured yet. The monitor gives numbers only while it runs.
    public static func monitor(running: Bool, cpuPercent: Double?, memoryPercent: Double?, diskFraction: Double?,
                               down: Double?, up: Double?) -> BentoBody {
        guard running else { return .basic(line: offLine(.systemMonitor)) }
        let rings = [BentoRing(label: "CPU", fraction: cpuPercent.map { clamp($0 / 100) }, tone: .green),
                     BentoRing(label: "메모리", fraction: memoryPercent.map { clamp($0 / 100) }, tone: .blue),
                     BentoRing(label: "디스크", fraction: diskFraction.map(clamp), tone: .orange)]
        let side = [BentoLine("네트워크", ""), BentoLine("↓", down.map(BentoFormat.rate) ?? "—"),
                    BentoLine("↑", up.map(BentoFormat.rate) ?? "—")]
        return .gauges(rings: rings, side: side)
    }

    /// Accessibility and Screen Recording as the system answers them now (no prompt). The button opens the first one
    /// that is missing.
    public static func computerUse(accessibility: Bool?, screenRecording: Bool?) -> BentoBody {
        let rows = [BentoCheck(name: "손쉬운 사용", granted: accessibility), BentoCheck(name: "화면 기록", granted: screenRecording)]
        let missing = rows.first { $0.granted == false }
        return .checklist(rows: rows, action: missing.map { "\($0.name) 권한 열기" })
    }

    /// The four snap positions the widget draws (left half, right half, top-left quarter, maximize) and the real
    /// shortcut of "left half" with how many more snap shortcuts there are.
    public static func windowSnap(running: Bool, leftLabel: String?, otherShortcuts: Int) -> BentoBody {
        let shapes = [BentoSnapShape(0, 0, 0.5, 1), BentoSnapShape(0.5, 0, 0.5, 1), BentoSnapShape(0, 0, 0.5, 0.5), BentoSnapShape(0, 0, 1, 1)]
        var caption: String?
        if let l = leftLabel { caption = otherShortcuts > 0 ? "\(l) 외 단축키 \(otherShortcuts)개" : l }
        else if otherShortcuts > 0 { caption = "단축키 \(otherShortcuts)개" }
        if !running { caption = offLine(.windowSnap) }
        return .layouts(shapes, caption: caption)
    }

    /// A timed hold (until/heldSince), an open-ended one (manual, no until), awake because of a rule (`reason`), or
    /// asleep allowed.
    public static func keepAwake(running: Bool, holds: Bool, manual: Bool, until: Date?, heldSince: Date?, reason: String?,
                                 presetMinutes: Int, now: Date) -> BentoBody {
        guard running else { return .basic(line: offLine(.keepAwake)) }
        if holds, let end = until {
            let left = end.timeIntervalSince(now)
            var fraction: Double?
            var caption = "남음"
            if let start = heldSince, end > start {
                fraction = clamp(left / end.timeIntervalSince(start))
                caption = "남음 · \(BentoFormat.duration(end.timeIntervalSince(start)))"
            }
            return .timer(fraction: fraction, big: BentoFormat.remaining(left), caption: caption)
        }
        if holds {
            return .timer(fraction: nil, big: "켜짐", caption: manual ? "끌 때까지" : (reason ?? "깨어 있어요"))
        }
        let preset = presetMinutes > 0 ? "누르면 \(BentoFormat.duration(Double(presetMinutes) * 60)) 깨워 둬요" : "누르면 끌 때까지 깨워 둬요"
        return .timer(fraction: 0, big: "꺼짐", caption: preset)
    }

    /// The latest items, newest first, as the history panel lists them (its title line, never more). Images show only
    /// their kind. At most `limit` (the large widget shows 8).
    public static func clipboard(running: Bool, items: [(kind: BentoRow.Kind, title: String, date: Date)], now: Date, limit: Int = 8) -> BentoBody {
        guard running else { return .basic(line: offLine(.clipboard)) }
        let rows = items.prefix(limit).map { item -> BentoRow in
            let text = item.kind == .image ? "이미지" : BentoFormat.oneLine(item.title, limit: 80)
            return BentoRow(kind: item.kind, text: text, detail: BentoFormat.age(now.timeIntervalSince(item.date)))
        }
        return .list(rows: Array(rows), empty: "아직 복사한 게 없어요")
    }

    public static func capture(running: Bool, floats: Int, shortcut: String?) -> BentoBody {
        guard running else { return .basic(line: offLine(.captureFloat)) }
        var caption = floats == 0 ? "떠 있는 캡처 없음" : "떠 있는 캡처 \(floats)장"
        if let s = shortcut { caption += " · \(s)" }
        return .stack(count: floats, caption: caption)
    }

    /// Intensity 0.1…0.9 from the settings (also when off).
    public static func focusDim(running: Bool, intensity: Double, paused: Bool) -> BentoBody {
        let lo = FocusDimLogic.minimumIntensity, hi = FocusDimLogic.maximumIntensity
        let f = clamp((intensity - lo) / (hi - lo))
        let caption = !running ? offLine(.focusDim) : (paused ? "잠시 멈췄어요" : "다른 창을 \(BentoFormat.percentNumber(intensity))% 어둡게")
        return .level(fraction: f, low: "약", high: "강", caption: caption)
    }

    /// Output volume 0…1 (nil: the device has none), external display brightness 0…100 (nil: no external display),
    /// the current output's name.
    public static func devices(running: Bool, volume: Double?, brightness: Int?, output: String?) -> BentoBody {
        guard running else { return .basic(line: offLine(.deviceControl)) }
        var sliders = [BentoSlider(symbol: "speaker.wave.2", label: "볼륨", fraction: volume.map(clamp),
                                   value: volume.map(BentoFormat.percentNumber) ?? "—")]
        if let b = brightness {
            sliders.append(BentoSlider(symbol: "sun.max", label: "밝기", fraction: clamp(Double(b) / 100), value: "\(b)"))
        }
        return .sliders(sliders, rows: [BentoLine(output ?? "출력 장치 없음", "출력")])
    }

    /// Today from the clock; the next timed event only when the module runs, Calendars access is allowed and the
    /// "next event" option is on.
    public static func calendar(now: Date, calendar: Calendar = .current, running: Bool, access: Bool?, showNext: Bool,
                                next: (start: Date, title: String)?) -> BentoBody {
        let c = calendar.dateComponents([.weekday, .day], from: now)
        var event: BentoLine?
        var note: String?
        if !running { note = offLine(.calendarClock) }
        else if access != true { note = "캘린더 접근이 꺼져 있어요" }
        else if showNext, let n = next {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            event = BentoLine(f.string(from: n.start), BentoFormat.oneLine(n.title, limit: 40))
        } else if showNext { note = "다음 일정 없음" }
        return .calendar(weekday: BentoFormat.weekday(c.weekday ?? 1), day: "\(c.day ?? 1)", event: event, note: note)
    }

    /// The startup disk (works while the tool is off) and, when a scan is there, its top-level folders.
    public static func disk(used: Int64?, total: Int64?, folders: [(name: String, size: Int64)]) -> BentoBody {
        guard let u = used, let t = total, t > 0 else { return .basic(line: offLine(.diskMap)) }
        var segments: [BentoSegment] = []
        if !folders.isEmpty {
            for f in folders.prefix(3) where f.size > 0 { segments.append(BentoSegment(label: f.name, fraction: Double(f.size) / Double(t))) }
            let shown = segments.reduce(0) { $0 + $1.fraction }
            let rest = Double(u) / Double(t) - shown
            if rest > 0.005 { segments.append(BentoSegment(label: "기타", fraction: rest)) }
        } else {
            segments = [BentoSegment(label: "사용", fraction: Double(u) / Double(t))]
        }
        return .usage(big: BentoFormat.size(Double(u)), caption: "/ \(BentoFormat.size(Double(t))) 사용", segments: segments)
    }

    public static func shelf(running: Bool, items: [(kind: BentoRow.Kind, title: String)]) -> BentoBody {
        guard running else { return .basic(line: offLine(.fileShelf)) }
        return .slots(items.prefix(8).map { BentoRow(kind: $0.kind, text: BentoFormat.oneLine($0.title, limit: 40)) }, drop: "여기로 끌어놓기")
    }

    /// macOS gives no list of other apps' icons, so the widget says only folded or not (no count).
    public static func menuBar(running: Bool, collapsed: Bool, failed: Bool) -> BentoBody {
        guard running else { return .basic(line: offLine(.menuBar)) }
        if failed { return .strip(count: nil, caption: "macOS가 구분선을 늘리지 못했어요") }
        return .strip(count: nil, caption: collapsed ? "아이콘을 접어 뒀어요" : "아이콘을 모두 보여요")
    }

    /// No recent-apps list exists, so App Switch stays a basic widget: its switcher shortcut and app shortcut count.
    public static func appSwitch(running: Bool, switcher: String?, appShortcuts: Int) -> BentoBody {
        guard running else { return .basic(line: offLine(.appSwitch)) }
        var parts: [String] = []
        if let s = switcher { parts.append("\(s)로 최근 앱 순서 전환") }
        if appShortcuts > 0 { parts.append("앱 단축키 \(appShortcuts)개") }
        return .basic(line: parts.isEmpty ? offLine(.appSwitch) : parts.joined(separator: " · "))
    }

    /// Scroll speed 0.25…5 (1 = as macOS) on a log scale, and the reverse-scroll choice (settings, also when off).
    public static func mouse(speed: Double, reverse: Bool) -> BentoBody {
        let f = clamp((log(max(0.25, min(5, speed))) - log(0.25)) / (log(5) - log(0.25)))
        let v = speed == speed.rounded() ? "\(Int(speed))×" : String(format: "%.1f×", speed)
        return .sliders([BentoSlider(symbol: "", label: "속도", fraction: f, value: v)], rows: [BentoLine("스크롤 반전", reverse ? "켬" : "끔")])
    }

    static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}
