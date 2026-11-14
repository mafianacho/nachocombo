import Foundation

/// System Monitor (`monitor`). No tools yet: the gadget lane fills `tools`, `guide` and `prompts` here (append-only).
public enum MonitorTools: GadgetToolProvider {
    public static let gadget = GadgetID.monitor
    public static let tools: [GadgetTool] = []
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
