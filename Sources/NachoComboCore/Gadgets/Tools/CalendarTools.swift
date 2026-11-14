import Foundation

/// Calendar Clock (`calendar`): the menu bar clock's display settings (NACHO-150). Event contents are not exposed.
public enum CalendarTools: GadgetToolProvider {
    public static let gadget = GadgetID.calendar
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .calendar, action: "status",
                   korean: "달력 시계가 메뉴 막대에 무엇을 보여 주는지 봐요: 날짜·요일·초·12/24시간·다음 일정 표시 여부와 세계 시계 목록. 일정 내용은 읽지 않아요.",
                   english: "Reads what the Calendar Clock shows: date, weekday, seconds, hour format, next-event switch and world clocks. Never event contents.",
                   output: "{ok, message, show_date, show_weekday, show_seconds, hours, show_next_event, world_clocks, hours_choices}", risk: .read),
        GadgetTool(gadget: .calendar, action: "set",
                   korean: "달력 시계 표시를 바꿔요(바꿀 항목만): 날짜·요일·초·다음 일정 표시, hours(system·twelve·twentyFour), 세계 시계(시간대 ID 최대 6개).",
                   english: "Changes the Calendar Clock display (only the given items): date, weekday, seconds, next-event switch, hours, and up to 6 world clock time zones.",
                   input: GadgetSchema.object([
                       "show_date": GadgetSchema.boolean("날짜 표시"),
                       "show_weekday": GadgetSchema.boolean("요일 표시"),
                       "show_seconds": GadgetSchema.boolean("초 표시"),
                       "hours": GadgetSchema.choice(ClockHours.allCases.map { $0.rawValue }, "시간 표기"),
                       "show_next_event": GadgetSchema.boolean("다음 일정 표시(켜면 캘린더 권한을 써요)"),
                       "world_clocks": GadgetSchema.stringList("세계 시계 시간대 ID 목록(예: Asia/Seoul), 최대 6개. 빈 목록이면 모두 지움"),
                   ]),
                   output: "{ok, message, …settings}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .calendar,
        summary: "달력 시계 가젯은 메뉴 막대에 날짜·시간·다음 일정과 세계 시계를 보여 줘요. 도구로는 표시 설정 읽기와 바꾸기를 할 수 있어요.",
        canDo: ["날짜·요일·초·시간 표기 설정 보기", "다음 일정 표시 켜고 끄기", "세계 시계 시간대 바꾸기(최대 6개)"],
        steps: ["status로 지금 설정과 세계 시계를 봐요.",
                "set에 바꿀 항목만 넣어요. 시간대는 Asia/Seoul 같은 ID로 넣어요.",
                "결과를 짧게 알려 줘요."],
        examples: [
            .init("status", note: "시계에 무엇이 보이는지 볼 때"),
            .init("set", .object(["show_seconds": .bool(true), "hours": .string("twentyFour")]), note: "초를 보이고 24시간제로 할 때"),
            .init("set", .object(["world_clocks": .array([.string("Asia/Seoul"), .string("America/New_York")])]), note: "세계 시계를 서울·뉴욕으로 맞출 때"),
        ],
        limits: ["일정의 제목·시간·장소 같은 내용은 읽는 도구를 만들지 않았어요. 다음 일정 표시는 가젯이 메뉴 막대에 직접 보여 줘요.",
                 "hours는 system·twelve·twentyFour만, 세계 시계는 올바른 시간대 ID 최대 6개만 받아요.",
                 "가젯이 꺼져 있으면 gadget_off예요. 사용자에게 물어본 뒤 combo_set_gadget으로 켜요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .calendar, flow: "world_clock",
                     description: "세계 시계 맞추기 — World clocks: show the time in the cities the user names.",
                     arguments: [.init("cities", "보고 싶은 도시 또는 시간대", required: true)],
                     template: "Read nachocombo://gadgets/calendar/guide. Turn the cities given into time zone ids (for example Asia/Seoul), call "
                         + "calendar_status, then calendar_set with world_clocks (at most 6). Tell me which clocks are shown now."),
    ]
}
