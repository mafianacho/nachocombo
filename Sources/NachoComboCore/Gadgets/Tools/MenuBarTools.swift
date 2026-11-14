import Foundation

/// Menu Bar Organizer (`menubar`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum MenuBarTools: GadgetToolProvider {
    public static let gadget = GadgetID.menubar
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
