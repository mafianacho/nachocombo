import Foundation

/// Device Control (`device`): volume, built-in display brightness, Do Not Disturb, microphone.
public enum DeviceTools: GadgetToolProvider {
    public static let gadget = GadgetID.device
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .device, action: "set",
                   korean: "맥의 소리 크기(0~100), 내장 화면 밝기(0~100), 방해금지 켜기/끄기를 바꿔요. 바꿀 항목만 넣어요. "
                       + "이 맥에서 지원하지 않는 항목(외장 모니터 밝기·방해금지 등)은 이유와 함께 실패로 알려 줘요.",
                   english: "Changes the volume (0-100), built-in display brightness (0-100) and Do Not Disturb. Give only what changes; unsupported items fail with a reason.",
                   input: GadgetSchema.object([
                       "volume": GadgetSchema.integer("소리 크기 %", minimum: 0, maximum: 100),
                       "brightness": GadgetSchema.integer("내장 화면 밝기 %", minimum: 0, maximum: 100),
                       "dnd": GadgetSchema.boolean("방해금지 켜기(true)/끄기(false)"),
                   ]),
                   output: "{ok, message}", risk: .change,
                   legacyConnectorName: PetCommands.setSystem, requiresGadgetOn: false),
        GadgetTool(gadget: .device, action: "status",
                   korean: "지금 소리 출력 장치 이름·소리 크기와 마이크 음소거 여부를 봐요. 소리나 마이크를 바꾸기 전에 확인할 때 써요.",
                   english: "Reads the current sound output (name, volume), the input name and whether the microphone is muted.",
                   output: "{ok, message, output?, volume?, input?, mic_muted}", risk: .read),
        GadgetTool(gadget: .device, action: "set_volume",
                   korean: "지금 소리 출력의 크기(0~100)나 음소거(muted)를 바꿔요. 둘 중 하나 이상 넣어요. 장치를 바꾸거나 외장 모니터는 건드리지 않아요.",
                   english: "Sets the current sound output volume (0-100) and/or mute. Never switches devices.",
                   input: GadgetSchema.object([
                       "volume": GadgetSchema.integer("소리 크기 %", minimum: 0, maximum: 100),
                       "muted": GadgetSchema.boolean("음소거(true)/해제(false)"),
                   ]),
                   output: "{ok, message}", risk: .change),
        GadgetTool(gadget: .device, action: "set_mic_muted",
                   korean: "마이크를 음소거(true)하거나 켜요(false). 화상 회의 전후에 써요. 음소거 중에는 메뉴 막대에 빨간 마이크가 떠요.",
                   english: "Mutes (true) or unmutes (false) the default microphone.",
                   input: GadgetSchema.object(["muted": GadgetSchema.boolean("true=음소거, false=켜기")], required: ["muted"]),
                   output: "{ok, message, mic_muted}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .device,
        summary: "기기 제어 가젯은 소리와 마이크, 화면 밝기를 다뤄요. 도구로는 상태 읽기, 소리 크기·음소거, 마이크 음소거, 밝기·방해금지(set)를 할 수 있어요.",
        canDo: ["출력 장치 이름, 소리 크기, 마이크 음소거 보기", "소리 크기 0~100과 음소거 바꾸기", "마이크 음소거 켜고 끄기", "내장 화면 밝기 바꾸기(set)"],
        steps: ["status로 지금 값을 봐요.",
                "소리는 set_volume, 마이크는 set_mic_muted를 불러요. 내장 밝기는 set에 brightness를 넣어요.",
                "결과의 message를 짧게 알려 줘요. 지원하지 않는 항목은 이유가 와요."],
        examples: [
            .init("status", note: "소리와 마이크 상태를 볼 때"),
            .init("set_volume", .object(["volume": .int(30)]), note: "소리를 줄여 달라고 할 때"),
            .init("set_mic_muted", .object(["muted": .bool(true)]), note: "회의 전에 마이크를 끌 때"),
        ],
        limits: ["일부러 뺀 것: 출력·입력 장치 바꾸기, 외장 모니터 밝기 직접 조작 범위 확장, 오디오 장치 설정 변경은 도구로 열지 않았어요.",
                 "방해금지는 macOS가 앱에 허용하지 않아 set에서 실패 이유로 돌아와요.",
                 "소리 크기·밝기는 닫힌 범위(0~100)만 받아요. 범위를 벗어나면 bad parameters예요.",
                 "set_volume·set_mic_muted·status는 가젯이 꺼져 있으면 gadget_off예요. 옛 set은 꺼져 있어도 동작해요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .device, flow: "meeting",
                     description: "회의 준비 — Meeting prep: check sound and microphone, then mute the microphone or set the volume.",
                     arguments: [],
                     template: "Read nachocombo://gadgets/device/guide. Call device_status and tell me the output volume and whether the "
                         + "microphone is muted. Ask whether to mute the microphone or change the volume, then call device_set_mic_muted "
                         + "or device_set_volume. Do not switch devices."),
    ]
}
