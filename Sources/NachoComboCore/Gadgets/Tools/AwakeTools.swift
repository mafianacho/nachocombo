import Foundation

/// Keep Awake (`awake`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum AwakeTools: GadgetToolProvider {
    public static let gadget = GadgetID.awake
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
