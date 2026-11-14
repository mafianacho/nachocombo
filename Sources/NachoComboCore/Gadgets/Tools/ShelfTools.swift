import Foundation

/// File Shelf (`shelf`): the list, handing a file to Nacho (approved), taking an item off, emptying (NACHO-149).
/// Runner: `DataGadgetRunner` (`clear` keeps its old `combo_clear_shelf` path).
public enum ShelfTools: GadgetToolProvider {
    public static let gadget = GadgetID.shelf

    static var index: JSONValue { GadgetSchema.integer("목록의 번호(1부터)", minimum: 1, maximum: DataGadgetRunner.maxIndex) }
    static var id: JSONValue { GadgetSchema.string("목록의 id(8자리). 주면 목록이 바뀌었는지 확인해요", minLength: 8, maxLength: 8) }

    public static let tools: [GadgetTool] = [
        // NACHO-149: destructive (was change), so Nacho asks for approval every time, "always allow" or not.
        GadgetTool(gadget: .shelf, action: "clear",
                   korean: "파일 선반에 올려 둔 항목을 모두 비워요(원본 파일은 지우지 않아요). 매번 사용자 승인을 받아요. "
                       + "\"선반 비워 줘\"처럼 요청할 때 써요.",
                   english: "Empties the File Shelf (original files are untouched). Approval every time on Nacho's side.",
                   output: "{ok, message}", risk: .destructive,
                   legacyConnectorName: PetCommands.clearShelf, requiresGadgetOn: false),
        GadgetTool(gadget: .shelf, action: "list",
                   korean: "파일 선반에 올려 둔 항목 목록을 봐요: 번호·id·이름·종류(파일·그림·글·링크)·크기만 보여 주고 내용은 없어요. 선반에 무엇이 있는지 물을 때 써요.",
                   english: "Lists the File Shelf: index, id, name, kind (file, image, text, link), size in bytes or characters. No content.",
                   output: "{ok, message, items:[{index, id, name, kind, bytes|characters}]}", risk: .read),
        GadgetTool(gadget: .shelf, action: "give",
                   korean: "파일 선반의 N번 항목을 나초 대화의 다음 메시지에 첨부해요. 사용자가 보내기를 누르면 나초에게 가요. 파일이 맥 밖으로 나가므로 매번 승인을 받아요.",
                   english: "Attaches File Shelf item N to the user's next chat message with Nacho (sent when the user presses send).",
                   input: GadgetSchema.object(["index": index, "id": id], required: ["index"]),
                   output: "{ok, message, attached, delivery}", risk: .contentOut, exits: [.connector]),
        GadgetTool(gadget: .shelf, action: "forget",
                   korean: "파일 선반에서 N번 항목을 빼요. 원본 파일은 그대로 두고, 선반에서 되돌리기 할 수 있어요. \"선반에서 그거 빼 줘\"에 써요.",
                   english: "Takes File Shelf item N off the shelf. The original file is untouched; the shelf can undo it.",
                   input: GadgetSchema.object(["index": index, "id": id], required: ["index"]),
                   output: "{ok, message, index}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .shelf,
        summary: "파일 선반 가젯에 잠시 올려 둔 파일·그림·글·링크를 번호로 다뤄요. 선반은 원본 파일을 옮기거나 지우지 않아요.",
        canDo: ["선반 목록 보기(이름·종류·크기, 내용 없음)", "N번 항목을 나초 대화에 첨부하기(승인)", "N번 항목을 선반에서 빼기(원본 유지)",
                "선반 비우기(원본 유지, 승인)"],
        steps: ["list로 번호와 이름을 확인해요.",
                "사용자가 고른 파일만 give로 첨부해요. 사용자가 보내기를 눌러야 나초에게 가요.",
                "빼거나 비운 뒤에는 번호가 바뀌니 다음 호출 전에 list를 다시 봐요."],
        examples: [
            .init("list", note: "선반에 무엇이 있는지 볼 때"),
            .init("give", .object(["index": .int(1)]), note: "사용자가 \"선반 첫 번째 파일 봐 줘\"라고 할 때"),
            .init("forget", .object(["index": .int(2)]), note: "두 번째 항목만 선반에서 뺄 때"),
        ],
        limits: ["파일 선반 가젯이 켜져 있어야 해요.",
                 "give는 나초 대화에서만 쓸 수 있어요(MCP에는 없어요). 한 메시지에 첨부는 4개까지, 사진·PDF·텍스트·mp4만 보낼 수 있어요.",
                 "clear는 이제 destructive예요. '항상 허용'과 상관없이 매번 승인을 받아요(예전 combo_clear_shelf도 같아요).",
                 "선반은 원본 파일을 지우지 않아요. 선반이 직접 만든 복사본(끌어다 놓은 그림)만 정리해요."])

    public static let prompts: [GadgetPrompt] = []
}
