import Foundation

/// Clipboard History (`clipboard`): the list (no previews), one item's content (approved), copy again, clear
/// (NACHO-149). Runner: `DataGadgetRunner`.
public enum ClipboardTools: GadgetToolProvider {
    public static let gadget = GadgetID.clipboard

    static var index: JSONValue { GadgetSchema.integer("목록의 번호(1부터)", minimum: 1, maximum: DataGadgetRunner.maxIndex) }
    static var id: JSONValue { GadgetSchema.string("목록의 id(8자리). 주면 목록이 바뀌었는지 확인해요", minLength: 8, maxLength: 8) }

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .clipboard, action: "list",
                   korean: "클립보드 기록 목록을 봐요: 번호·id·종류(글·링크·그림·파일)·길이·복사한 시각·고정 여부만 보여 주고 내용 미리보기는 없어요. "
                       + "내용이 필요하면 번호로 get_item을 불러요.",
                   english: "Lists the clipboard history: index, id, kind (text, link, image, files), length and unit, copied time, pinned. No previews or content.",
                   output: "{ok, message, items:[{index, id, kind, length, unit, copied_at, pinned}]}", risk: .read),
        GadgetTool(gadget: .clipboard, action: "get_item",
                   korean: "클립보드 기록에서 N번 항목의 내용(글·링크·파일 경로)을 읽어요. 내용이 맥 밖으로 나가므로 매번 사용자 승인을 받아요. "
                       + "사용자가 그 항목을 보라고 할 때만 써요.",
                   english: "Reads the content of clipboard history item N (text, link or file paths, cut at 4000 characters). Pictures are not readable as text.",
                   input: GadgetSchema.object(["index": index, "id": id], required: ["index"]),
                   output: "{ok, message, index, kind, text, length, truncated}", risk: .contentOut),
        GadgetTool(gadget: .clipboard, action: "copy_again",
                   korean: "클립보드 기록의 N번 항목을 다시 복사해 지금 클립보드에 올려요(목록 맨 위로 와요). \"아까 복사한 거 다시 붙여 넣게 해 줘\"에 써요.",
                   english: "Copies clipboard history item N again: it is on the clipboard now and first in the list.",
                   input: GadgetSchema.object(["index": index, "id": id], required: ["index"]),
                   output: "{ok, message, index, kind}", risk: .change),
        GadgetTool(gadget: .clipboard, action: "clear",
                   korean: "클립보드 기록을 비워요. 고정한 항목은 남아요. 되돌릴 수 없어서 매번 사용자 승인을 받아요. 사용자가 기록을 지워 달라고 할 때만 써요.",
                   english: "Clears the clipboard history except pinned items. Cannot be undone.",
                   output: "{ok, message, cleared}", risk: .destructive),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .clipboard,
        summary: "클립보드 기록 가젯이 모아 둔 복사 기록을 번호로 다뤄요. 목록에는 내용이 없고, 내용은 사용자 승인을 받은 뒤 한 항목씩만 읽어요.",
        canDo: ["기록 목록 보기(번호·종류·길이·시각·고정, 미리보기 없음)", "N번 항목 내용 읽기(승인)", "N번 항목 다시 복사하기",
                "기록 비우기(고정 항목은 남김, 되돌릴 수 없음, 승인)"],
        steps: ["list로 번호와 종류를 확인해요.",
                "사용자가 고른 항목만 get_item으로 읽어요. 번호와 함께 목록의 id를 주면 그사이 목록이 바뀐 경우 list_changed로 멈춰요.",
                "다시 붙여 넣으려면 copy_again을 불러요. 그러면 번호가 바뀌니 다음 호출 전에 list를 다시 봐요."],
        examples: [
            .init("list", note: "어떤 항목이 있는지 볼 때(내용은 오지 않아요)"),
            .init("get_item", .object(["index": .int(2), "id": .string("3f2a9c1b")]), note: "사용자가 \"두 번째 거 읽어 줘\"라고 할 때"),
            .init("copy_again", .object(["index": .int(3)]), note: "세 번째 항목을 다시 클립보드에 올릴 때"),
        ],
        limits: ["클립보드 기록 가젯이 켜져 있어야 해요.",
                 "get_item은 글을 4000자까지만 돌려줘요(truncated). 그림 항목은 글로 읽지 못해요(not_text).",
                 "암호 관리자 등이 숨김 표시한 복사는 처음부터 기록되지 않아요.",
                 "clear는 되돌릴 수 없어요. 나초 대화에서는 '항상 허용'을 켜도 늘 승인을 받아요."])

    public static let prompts: [GadgetPrompt] = []
}
