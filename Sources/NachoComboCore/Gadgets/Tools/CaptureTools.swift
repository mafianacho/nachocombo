import Foundation

/// Capture Float (`capture`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum CaptureTools: GadgetToolProvider {
    public static let gadget = GadgetID.capture
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
