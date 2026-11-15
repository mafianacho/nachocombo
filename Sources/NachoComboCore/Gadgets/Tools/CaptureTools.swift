import Foundation

/// Capture Float (`capture`): capture an area or the screen for Nacho (approved), the pinned captures, close them
/// (NACHO-149). Runner: `DataGadgetRunner`.
public enum CaptureTools: GadgetToolProvider {
    public static let gadget = GadgetID.capture
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .capture, action: "ask",
                   korean: "화면을 캡처해 나초 대화의 다음 메시지에 첨부해요. area는 사용자가 영역을 드래그하고, screen은 포인터가 있는 화면 전체예요. "
                       + "화면 내용이 나가므로 매번 승인을 받아요.",
                   english: "Captures an area the user drags over (area) or the whole screen under the pointer (screen) and attaches it to the user's next chat message with Nacho.",
                   input: GadgetSchema.object([
                       "mode": GadgetSchema.choice(CaptureAskMode.allCases.map { $0.rawValue }, "area=사용자가 드래그한 영역(기본), screen=포인터가 있는 화면 전체"),
                   ]),
                   output: "{ok, message, attached, delivery, pending?}", risk: .contentOut, permissions: [.screenRecording], exits: [.connector]),
        GadgetTool(gadget: .capture, action: "list_pinned",
                   korean: "화면에 떠 있는 고정 캡처 창의 개수와 크기(픽셀)를 봐요. 그림 내용은 보내지 않아요. 고정 캡처가 몇 개 열려 있는지 물을 때 써요.",
                   english: "Lists the open pinned captures (index, pixel width and height). No pictures.",
                   output: "{ok, message, items:[{index, width, height}]}", risk: .read),
        GadgetTool(gadget: .capture, action: "close_all",
                   korean: "화면에 떠 있는 고정 캡처 창을 모두 닫아요. \"떠 있는 캡처 다 닫아 줘\"에 써요.",
                   english: "Closes every pinned capture window.",
                   output: "{ok, message, closed}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .capture,
        summary: "캡처 플로트 가젯으로 화면을 캡처해 나초에게 보여 주고, 화면에 고정해 둔 캡처 창을 정리해요.",
        canDo: ["사용자가 드래그한 영역을 캡처해 나초 대화에 첨부하기(승인)", "포인터가 있는 화면 전체를 캡처해 첨부하기(승인)",
                "고정 캡처 창 개수·크기 보기", "고정 캡처 창 모두 닫기"],
        steps: ["사용자가 화면의 무엇을 물으면 ask를 불러요. 영역을 정해야 하면 area, 화면 전체면 screen이에요.",
                "area는 사용자가 드래그를 끝낼 때까지 기다려요. 45초가 지나면 pending으로 먼저 답하고, 끝나면 첨부돼요.",
                "첨부되면 사용자에게 보내기를 눌러 달라고 해요. 다음 메시지에서 그림을 보고 답해요."],
        examples: [
            .init("ask", .object(["mode": .string("area")]), note: "\"이 부분 뭐야?\"처럼 화면 일부를 물을 때"),
            .init("ask", .object(["mode": .string("screen")]), note: "화면 전체를 보고 답해야 할 때"),
            .init("close_all", note: "떠 있는 캡처를 모두 닫을 때"),
        ],
        limits: ["캡처 플로트 가젯이 켜져 있어야 하고 화면 기록 권한이 필요해요. 없으면 permission_needed와 켜는 방법을 돌려줘요.",
                 "ask는 나초 대화에서만 쓸 수 있어요(MCP 클라이언트는 computer_screen_capture를 써요).",
                 "캡처한 그림은 결과에 들어가지 않고 다음 메시지 첨부로만 가요. 사용자가 보내기를 눌러야 전송돼요.",
                 "사용자가 Esc로 취소하면 cancelled를 돌려주고 아무것도 첨부하지 않아요."])

    public static let prompts: [GadgetPrompt] = []
}
