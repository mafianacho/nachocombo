import Foundation

/// Device Control (`device`): volume, built-in display brightness, Do Not Disturb.
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
    ]
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
