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
    ]
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
