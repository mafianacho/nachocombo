import Foundation

/// Keep Awake (`awake`): state, hold for a time, release (NACHO-150).
public enum AwakeTools: GadgetToolProvider {
    public static let gadget = GadgetID.awake

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .awake, action: "status",
                   korean: "잠자기 방지가 지금 맥을 깨워 두고 있는지, 남은 시간과 이유(수동·정한 앱·전원 규칙)를 봐요. 켜기 전에 확인할 때 써요.",
                   english: "Reads whether Keep Awake holds the Mac awake now, the time left and why (manual, chosen app, power rule).",
                   output: "{ok, message, holding, manual, seconds_left?, reason, keep_display, power_only, battery_floor_percent}",
                   risk: .read),
        GadgetTool(gadget: .awake, action: "start",
                   korean: "맥이 잠들지 않게 지금 붙잡아요. minutes에 분(1~1440)을 넣으면 그 시간만, 0이거나 생략하면 끌 때까지 유지해요. 발표나 긴 작업 전에 써요.",
                   english: "Keeps the Mac awake now: minutes 1-1440 for that long, 0 or omitted until stopped. Battery guard still applies.",
                   input: GadgetSchema.object(["minutes": GadgetSchema.integer("유지할 분. 0=끌 때까지", minimum: 0, maximum: 1440)]),
                   output: "{ok, message, holding, manual, seconds_left?, reason, …}", risk: .change),
        GadgetTool(gadget: .awake, action: "stop",
                   korean: "수동으로 붙잡은 깨어 있기를 풀어 맥이 평소처럼 잠들 수 있게 해요. 정한 앱·전원 규칙은 그대로 따라요.",
                   english: "Releases the manual hold so the Mac may sleep again. App and power rules still apply.",
                   output: "{ok, message, holding, manual, reason, …}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .awake,
        summary: "잠자기 방지 가젯은 맥이 잠들지 않게 붙잡아요. 도구로는 상태 확인, 시간 지정 켜기, 끄기를 할 수 있어요.",
        canDo: ["지금 깨어 있는지, 남은 시간, 이유 보기", "정한 시간(분) 동안 또는 끌 때까지 깨워 두기", "수동 유지 풀기"],
        steps: ["status로 이미 깨어 있는지 봐요.",
                "켜려면 start에 minutes를 넣어요(0이면 끌 때까지).",
                "끝나면 stop을 불러요. 결과의 message와 seconds_left를 짧게 알려 줘요."],
        examples: [
            .init("status", note: "깨어 있는지 확인할 때"),
            .init("start", .object(["minutes": .int(60)]), note: "한 시간 동안 맥이 잠들지 않게 할 때"),
            .init("stop", note: "발표가 끝나서 풀 때"),
        ],
        limits: ["가젯이 꺼져 있으면 gadget_off를 돌려줘요. 사용자에게 물어본 뒤 combo_set_gadget으로 켜요.",
                 "배터리 보호(정한 % 아래면 놓기)와 전원 연결 때만 규칙은 가젯 설정이 그대로 적용해요. 도구로 바꾸지 않아요.",
                 "디스플레이까지 켜 둘지는 가젯 설정이에요. 도구는 읽기만 해요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .awake, flow: "presentation",
                     description: "발표 모드 — Presentation mode: keep the Mac awake and dim everything but the front window.",
                     arguments: [.init("minutes", "깨워 둘 분(기본 60)")],
                     template: "Read nachocombo://gadgets/awake/guide and nachocombo://gadgets/dim/guide. Call awake_start with the minutes "
                         + "given (60 if none), then dim_resume so Focus Dim is active. If a call answers gadget_off, ask the user before "
                         + "switching the gadget on. Tell me what is on now and how to undo it (awake_stop, dim_pause)."),
    ]
}
