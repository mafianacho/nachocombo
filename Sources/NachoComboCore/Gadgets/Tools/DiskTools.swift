import Foundation

/// Disk Map (`disk`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum DiskTools: GadgetToolProvider {
    public static let gadget = GadgetID.disk
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
