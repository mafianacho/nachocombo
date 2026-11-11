import Foundation
import XCTest
@testable import NachoComboCore

/// Widget bodies come only from the values handed in: off tools without data fall back to the basic widget, nothing
/// is invented (no hidden-icon count, no built-in brightness, no event without Calendars access).
final class BentoBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_400_000)

    func testFormats() {
        XCTAssertEqual(BentoFormat.rate(1_200_000), "1.2MB/s")
        XCTAssertEqual(BentoFormat.rate(84_000), "84KB/s")
        XCTAssertEqual(BentoFormat.rate(0), "0B/s")
        XCTAssertEqual(BentoFormat.size(612_000_000_000), "612GB")
        XCTAssertEqual(BentoFormat.size(1_000_000_000_000), "1TB")
        XCTAssertEqual(BentoFormat.size(2_000_000_000_000), "2TB")
        XCTAssertEqual(BentoFormat.remaining(74 * 60), "1:14")
        XCTAssertEqual(BentoFormat.remaining(14 * 60 - 5), "14분")
        XCTAssertEqual(BentoFormat.remaining(45), "45초")
        XCTAssertEqual(BentoFormat.duration(7200), "2시간")
        XCTAssertEqual(BentoFormat.duration(5400), "1시간 30분")
        XCTAssertEqual(BentoFormat.age(20), "방금")
        XCTAssertEqual(BentoFormat.age(180), "3분")
        XCTAssertEqual(BentoFormat.age(7200), "2시간")
        XCTAssertEqual(BentoFormat.weekday(4), "수요일")
        XCTAssertEqual(BentoFormat.oneLine("회의는\n금요일   오후 3시"), "회의는 금요일 오후 3시")
        XCTAssertEqual(BentoRing(label: "CPU", fraction: nil, tone: .green).text, "—")
        XCTAssertEqual(BentoFormat.name(.menuBar), "Menu Bar")
        XCTAssertEqual(BentoFormat.name(.clipboard), ModuleID.clipboard.displayName)
        XCTAssertEqual(BentoRing(label: "CPU", fraction: 0.374, tone: .green).text, "37%")
    }

    func testDotsSayTheStateInWords() {
        XCTAssertEqual(BentoDot(.onNeedsSetup), .setup)
        XCTAssertEqual(BentoDot(.onNeedsSetup).koreanText, "켜짐 · 추가 설정 필요")
        XCTAssertEqual(BentoDot(.off).koreanText, "꺼짐")
        XCTAssertEqual(BentoDot(.onError), .error)
    }

    func testOffToolsWithoutDataAreBasicWidgets() {
        for body in [BentoBuilder.monitor(running: false, cpuPercent: 3, memoryPercent: 40, diskFraction: 0.6, down: 1, up: 1),
                     BentoBuilder.clipboard(running: false, items: [(.text, "secret", now)], now: now),
                     BentoBuilder.capture(running: false, floats: 2, shortcut: "⇧⌘2"),
                     BentoBuilder.devices(running: false, volume: 0.5, brightness: 80, output: "AirPods"),
                     BentoBuilder.shelf(running: false, items: [(.file, "a.pdf")]),
                     BentoBuilder.menuBar(running: false, collapsed: true, failed: false),
                     BentoBuilder.keepAwake(running: false, holds: true, manual: true, until: now, heldSince: nil, reason: nil, presetMinutes: 60, now: now)] {
            guard case .basic = body else { return XCTFail("\(body)") }
        }
        // Off, yet real: values that live in the settings or the system.
        guard case .level = BentoBuilder.focusDim(running: false, intensity: 0.5, paused: false) else { return XCTFail() }
        guard case .sliders = BentoBuilder.mouse(speed: 1, reverse: true) else { return XCTFail() }
        guard case .checklist = BentoBuilder.computerUse(accessibility: true, screenRecording: false) else { return XCTFail() }
        guard case .usage = BentoBuilder.disk(used: 612_000_000_000, total: 1_000_000_000_000, folders: []) else { return XCTFail() }
    }

    func testMonitorUsesOnlyMeasuredNumbers() {
        guard case let .gauges(rings, side) = BentoBuilder.monitor(running: true, cpuPercent: 2, memoryPercent: 37, diskFraction: nil,
                                                                  down: 1_200_000, up: nil) else { return XCTFail() }
        XCTAssertEqual(rings.map { $0.text }, ["2%", "37%", "—"])
        XCTAssertEqual(side.map { $0.value }, ["", "1.2MB/s", "—"])
    }

    func testComputerUseButtonOpensTheFirstMissingPermission() {
        guard case let .checklist(rows, action) = BentoBuilder.computerUse(accessibility: true, screenRecording: false) else { return XCTFail() }
        XCTAssertEqual(rows.map { $0.stateText }, ["허용됨", "필요"])
        XCTAssertEqual(action, "화면 기록 권한 열기")
        guard case let .checklist(_, none) = BentoBuilder.computerUse(accessibility: true, screenRecording: true) else { return XCTFail() }
        XCTAssertNil(none)
    }

    func testKeepAwakeTimerNeedsTheRealStart() {
        let until = now.addingTimeInterval(74 * 60)
        guard case let .timer(f, big, caption) = BentoBuilder.keepAwake(running: true, holds: true, manual: true, until: until,
                                                                          heldSince: until.addingTimeInterval(-7200), reason: nil,
                                                                          presetMinutes: 30, now: now) else { return XCTFail() }
        XCTAssertEqual(big, "1:14")
        XCTAssertEqual(caption, "남음 · 2시간")
        XCTAssertEqual(f ?? 0, 74.0 / 120, accuracy: 1e-6)
        // Without the start the ring is not drawn (no guessing from the preset).
        guard case let .timer(f2, _, c2) = BentoBuilder.keepAwake(running: true, holds: true, manual: true, until: until, heldSince: nil,
                                                                   reason: nil, presetMinutes: 30, now: now) else { return XCTFail() }
        XCTAssertNil(f2)
        XCTAssertEqual(c2, "남음")
        guard case let .timer(_, b3, c3) = BentoBuilder.keepAwake(running: true, holds: true, manual: false, until: nil, heldSince: nil,
                                                                   reason: "Xcode가 실행 중이라 깨어 있어요", presetMinutes: 30, now: now) else { return XCTFail() }
        XCTAssertEqual(b3, "켜짐")
        XCTAssertEqual(c3, "Xcode가 실행 중이라 깨어 있어요")
    }

    func testClipboardShowsTitlesAndAgesButNeverImageContent() {
        let items: [(kind: BentoRow.Kind, title: String, date: Date)] = [
            (.text, "회의는 금요일\n오후 3시로", now.addingTimeInterval(-10)), (.image, "Image", now.addingTimeInterval(-720)),
            (.link, "github.com/mafianacho/nachocombo", now.addingTimeInterval(-180))]
        guard case let .list(rows, _) = BentoBuilder.clipboard(running: true, items: items, now: now, limit: 2) else { return XCTFail() }
        XCTAssertEqual(rows.map { $0.text }, ["회의는 금요일 오후 3시로", "이미지"])
        XCTAssertEqual(rows.map { $0.detail }, ["방금", "12분"])
        guard case let .list(empty, emptyText) = BentoBuilder.clipboard(running: true, items: [], now: now) else { return XCTFail() }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(emptyText, "아직 복사한 게 없어요")
    }

    func testDevicesShowBrightnessOnlyForAnExternalDisplay() {
        guard case let .sliders(s, rows) = BentoBuilder.devices(running: true, volume: 0.64, brightness: nil, output: "AirPods Pro") else { return XCTFail() }
        XCTAssertEqual(s.map { $0.label }, ["볼륨"])
        XCTAssertEqual(s.first?.value, "64")
        XCTAssertEqual(rows.first?.label, "AirPods Pro")
        guard case let .sliders(s2, _) = BentoBuilder.devices(running: true, volume: nil, brightness: 80, output: nil) else { return XCTFail() }
        XCTAssertEqual(s2.map { $0.value }, ["—", "80"])
    }

    func testCalendarNeverShowsAnEventWithoutAccess() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let next = (start: now.addingTimeInterval(3600), title: "주간 회의")
        guard case let .calendar(_, _, event, note) = BentoBuilder.calendar(now: now, calendar: cal, running: true, access: false,
                                                                             showNext: true, next: next) else { return XCTFail() }
        XCTAssertNil(event)
        XCTAssertEqual(note, "캘린더 접근이 꺼져 있어요")
        guard case let .calendar(wd, day, ev, _) = BentoBuilder.calendar(now: now, calendar: cal, running: true, access: true,
                                                                          showNext: true, next: next) else { return XCTFail() }
        XCTAssertEqual(ev?.value, "주간 회의")
        XCTAssertFalse(wd.isEmpty)
        XCTAssertEqual(day, "\(cal.component(.day, from: now))")
    }

    func testDiskSegmentsComeFromTheScanOnly() {
        guard case let .usage(big, caption, segs) = BentoBuilder.disk(used: 612_000_000_000, total: 1_000_000_000_000, folders: []) else { return XCTFail() }
        XCTAssertEqual(big, "612GB")
        XCTAssertEqual(caption, "/ 1TB 사용")
        XCTAssertEqual(segs.map { $0.label }, ["사용"])
        guard case let .usage(_, _, s2) = BentoBuilder.disk(used: 600, total: 1000, folders: [("Users", 300), ("Applications", 100)]) else { return XCTFail() }
        XCTAssertEqual(s2.map { $0.label }, ["Users", "Applications", "기타"])
        XCTAssertEqual(s2.reduce(0) { $0 + $1.fraction }, 0.6, accuracy: 1e-9)
        guard case .basic = BentoBuilder.disk(used: nil, total: nil, folders: []) else { return XCTFail() }
    }

    func testMenuBarHasNoInventedIconCountAndAppSwitchIsBasic() {
        guard case let .strip(count, caption) = BentoBuilder.menuBar(running: true, collapsed: true, failed: false) else { return XCTFail() }
        XCTAssertNil(count)
        XCTAssertEqual(caption, "아이콘을 접어 뒀어요")
        guard case let .basic(line) = BentoBuilder.appSwitch(running: true, switcher: "⌥⇥", appShortcuts: 2) else { return XCTFail() }
        XCTAssertEqual(line, "⌥⇥로 최근 앱 순서 전환 · 앱 단축키 2개")
    }

    func testPetFollowsTheSession() {
        guard case let .pet(line, action, signedIn) = BentoBuilder.pet(auth: .signedOut, running: true) else { return XCTFail() }
        XCTAssertEqual(line, "로그인하면 말을 걸 수 있어요")
        XCTAssertEqual(action, "나초 계정으로 로그인")
        XCTAssertFalse(signedIn)
        XCTAssertEqual(BentoBuilder.petShort(auth: .signedOut).big, "로그인 필요")
        guard case let .pet(_, a2, s2) = BentoBuilder.pet(auth: .signedIn, running: true) else { return XCTFail() }
        XCTAssertEqual(a2, "대화 열기")
        XCTAssertTrue(s2)
        guard case let .pet(_, a3, _) = BentoBuilder.pet(auth: .signedOut, running: false) else { return XCTFail() }
        XCTAssertNil(a3, "no sign-in from a pet that is off")
    }

    func testMouseSpeedScale() {
        guard case let .sliders(s, rows) = BentoBuilder.mouse(speed: 1, reverse: false) else { return XCTFail() }
        XCTAssertEqual(s.first?.value, "1×")
        XCTAssertEqual(s.first?.fraction ?? 0, log(4) / log(20), accuracy: 1e-9)
        XCTAssertEqual(rows.first?.value, "끔")
    }
}
