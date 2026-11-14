import Foundation

/// Focus Dim (`dim`).
public enum DimTools: GadgetToolProvider {
    public static let gadget = GadgetID.dim
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .dim, action: "set_strength",
                   korean: "집중 디밍(맨 앞 창만 밝게 두고 나머지 화면을 어둡게 하는 가젯)의 어둡기를 10~90%로 바꿔요. "
                       + "\"디밍 더 어둡게\"처럼 요청할 때 써요. 가젯이 꺼져 있으면 강도만 저장돼요.",
                   english: "Sets how dark Focus Dim makes everything but the front window (10-90%). Stored only while the gadget is off.",
                   input: GadgetSchema.object(["percent": GadgetSchema.integer(minimum: 10, maximum: 90)], required: ["percent"]),
                   output: "{ok, message}", risk: .change,
                   legacyConnectorName: PetCommands.setDimStrength, requiresGadgetOn: false),
        GadgetTool(gadget: .dim, action: "status",
                   korean: "집중 디밍이 지금 화면을 어둡게 하는지(잠시 멈춤인지), 어둡기와 범위 설정을 봐요. 조절하기 전에 확인할 때 써요.",
                   english: "Reads whether Focus Dim is dimming or paused, the strength and the scope settings.",
                   output: "{ok, message, paused, strength_percent, scope, other_displays, only_in_session}", risk: .read),
        GadgetTool(gadget: .dim, action: "pause",
                   korean: "집중 디밍을 잠시 멈춰 화면을 원래 밝기로 보여 줘요(가젯은 켜진 채). 다시 어둡게 하려면 dim_resume을 써요.",
                   english: "Pauses Focus Dim so the screen shows at normal brightness (the gadget stays on). dim_resume turns it back.",
                   output: "{ok, message, paused, strength_percent, …}", risk: .change),
        GadgetTool(gadget: .dim, action: "resume",
                   korean: "멈춰 둔 집중 디밍을 다시 시작해 맨 앞 창만 밝게 두고 나머지를 어둡게 해요.",
                   english: "Resumes a paused Focus Dim: everything but the front window is dimmed again.",
                   output: "{ok, message, paused, strength_percent, …}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .dim,
        summary: "집중 디밍 가젯은 맨 앞 창만 밝게 두고 나머지 화면을 어둡게 해요. 도구로는 상태 확인, 잠시 멈춤·다시 시작, 어둡기 바꾸기를 할 수 있어요.",
        canDo: ["어둡게 하는 중인지, 어둡기와 범위 보기", "잠시 멈추기와 다시 시작", "어둡기 10~90% 바꾸기"],
        steps: ["status로 멈춤 여부와 어둡기를 봐요.",
                "어둡기를 바꾸려면 set_strength에 percent(10~90)를 넣어요.",
                "화면을 잠깐 원래대로 보려면 pause, 다시 어둡게 하려면 resume을 불러요."],
        examples: [
            .init("status", note: "지금 어둡게 하는 중인지 볼 때"),
            .init("set_strength", .object(["percent": .int(70)]), note: "더 어둡게 해 달라고 할 때"),
            .init("pause", note: "잠깐 화면을 원래대로 보고 싶을 때"),
            .init("resume", note: "다시 집중하려고 어둡게 할 때"),
        ],
        limits: ["가젯을 켜고 끄는 일은 combo_set_gadget이에요. pause·resume은 켜진 가젯 안에서만 돼요(꺼져 있으면 gadget_off).",
                 "set_strength는 꺼져 있어도 강도만 저장돼요. 옛 이름 combo_set_dim_strength도 그대로 받아요.",
                 "범위(앞 창만·앱 전체)와 다른 화면, 집중 시간 설정은 가젯 설정에서 바꿔요. 도구는 읽기만 해요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .dim, flow: "focus_now",
                     description: "집중 모드 — Focus mode: dim everything but the front window at a strength you choose.",
                     arguments: [.init("percent", "어둡기 10~90(기본 60)")],
                     template: "Read nachocombo://gadgets/dim/guide. Call dim_status; if it is paused call dim_resume. Then call dim_set_strength "
                         + "with the percent given (60 if none). If the answer is gadget_off, ask the user before switching Focus Dim on."),
    ]
}
