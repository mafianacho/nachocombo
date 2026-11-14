import Foundation

/// File Shelf (`shelf`).
public enum ShelfTools: GadgetToolProvider {
    public static let gadget = GadgetID.shelf
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .shelf, action: "clear",
                   korean: "파일 선반에 올려 둔 항목을 모두 비워요(원본 파일은 지우지 않고, 선반에서 되돌리기 할 수 있어요). "
                       + "\"선반 비워 줘\"처럼 요청할 때 써요.",
                   english: "Empties the File Shelf (original files are untouched; undoable in the shelf).",
                   output: "{ok, message}", risk: .change,
                   legacyConnectorName: PetCommands.clearShelf, requiresGadgetOn: false),
    ]
    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
