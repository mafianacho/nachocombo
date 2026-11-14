import Foundation

/// Mouse Tune (`mouse`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum MouseTools: GadgetToolProvider {
    public static let gadget = GadgetID.mouse
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
