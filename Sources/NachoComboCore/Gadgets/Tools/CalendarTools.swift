import Foundation

/// Calendar Clock (`calendar`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum CalendarTools: GadgetToolProvider {
    public static let gadget = GadgetID.calendar
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
