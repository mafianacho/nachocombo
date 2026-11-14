import Foundation

/// Clipboard History (`clipboard`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum ClipboardTools: GadgetToolProvider {
    public static let gadget = GadgetID.clipboard
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
