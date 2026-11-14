import Foundation

/// Mouse Tune (`mouse`): scroll direction, smooth scroll, speed, side and middle buttons (NACHO-150).
public enum MouseTools: GadgetToolProvider {
    public static let gadget = GadgetID.mouse
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .mouse, action: "status",
                   korean: "마우스 조정 가젯의 설정을 봐요: 스크롤 반대로, 부드러운 스크롤, 속도, 옆 버튼, 가운데 버튼 동작. 바꾸기 전에 확인할 때 써요.",
                   english: "Reads the Mouse Tune settings: reverse scroll, smooth scroll, speed, side buttons, middle button.",
                   output: "{ok, message, reverse_scroll, smooth_scroll, speed, side_buttons, middle_button, speed_choices}", risk: .read),
        GadgetTool(gadget: .mouse, action: "set",
                   korean: "마우스 조정 설정을 바꿔요(바꿀 항목만). 스크롤 반대로·부드러운 스크롤·옆 버튼은 true/false, 속도는 0.5·1·1.5·2·3, 가운데 버튼은 click 또는 missionControl.",
                   english: "Changes Mouse Tune settings (only the given ones): reverse/smooth scroll, side buttons, speed from a closed list, middle button.",
                   input: GadgetSchema.object([
                       "reverse_scroll": GadgetSchema.boolean("마우스 스크롤 방향 반대로"),
                       "smooth_scroll": GadgetSchema.boolean("부드러운 스크롤"),
                       "speed": GadgetSchema.number("스크롤 속도 배율: 0.5, 1, 1.5, 2, 3 중 하나"),
                       "side_buttons": GadgetSchema.boolean("옆 버튼을 뒤로/앞으로로 쓰기"),
                       "middle_button": GadgetSchema.choice(MiddleButton.allCases.map { $0.rawValue }, "가운데 버튼 동작"),
                   ]),
                   output: "{ok, message, …settings}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .mouse,
        summary: "마우스 조정 가젯은 마우스 휠과 버튼의 동작을 바꿔요(트랙패드는 그대로). 도구로는 설정 읽기와 바꾸기를 할 수 있어요.",
        canDo: ["스크롤 방향·부드러운 스크롤·속도 보기", "옆 버튼과 가운데 버튼 동작 보기", "위 설정을 닫힌 목록 안에서 바꾸기"],
        steps: ["status로 지금 설정을 봐요.",
                "set에 바꿀 항목만 넣어요. speed는 speed_choices 중 하나만 돼요.",
                "결과의 설정 값을 짧게 알려 줘요."],
        examples: [
            .init("status", note: "지금 마우스 설정을 볼 때"),
            .init("set", .object(["reverse_scroll": .bool(true), "speed": .double(1.5)]), note: "휠 방향을 반대로 하고 조금 빠르게 할 때"),
            .init("set", .object(["middle_button": .string("missionControl")]), note: "가운데 버튼을 미션 컨트롤로 쓸 때"),
        ],
        limits: ["속도는 0.5·1·1.5·2·3, 가운데 버튼은 click·missionControl만 받아요.",
                 "스크롤 변환은 마우스 휠에만 적용돼요. 트랙패드는 건드리지 않아요.",
                 "가젯이 꺼져 있으면 gadget_off예요. 사용자에게 물어본 뒤 combo_set_gadget으로 켜요.",
                 "마우스 포인터 속도 같은 macOS 시스템 설정은 바꾸지 않아요. 가젯이 보여 주는 값만 다뤄요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .mouse, flow: "wheel_setup",
                     description: "마우스 휠 설정 — Mouse setup: read the current wheel settings and change what the user asks.",
                     arguments: [],
                     template: "Read nachocombo://gadgets/mouse/guide. Call mouse_status, tell me the settings in one line, then call mouse_set "
                         + "with only the items I ask to change."),
    ]
}
