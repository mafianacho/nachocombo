import Foundation

/// Window Snap (`window`): one window to a position, several windows at once, the window list.
/// The window lane (grid, halves/thirds/quarters, ratios, displays, undo) adds its tools here.
public enum WindowTools: GadgetToolProvider {
    public static let gadget = GadgetID.window

    static var app: JSONValue {
        GadgetSchema.string("앱 이름(한국어 표시 이름·영문 이름·번들 ID), 예: 사파리, Safari, com.apple.Safari", maxLength: PetCommands.maxAppNameLength)
    }

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .window, action: "arrange",
                   korean: "맨 앞 창(또는 지정한 실행 중 앱의 창) 하나를 화면 왼쪽 반·오른쪽 반·최대화·네 귀퉁이·3분할 등으로 옮겨요. "
                       + "next-display·previous-display는 옆 디스플레이로 옮겨요. 손쉬운 사용 권한이 필요해요.",
                   english: "Moves the front window (or the front window of the named running app) to a Window Snap position: halves, maximize, quarters, thirds, next/previous display.",
                   input: GadgetSchema.object([
                       "position": GadgetSchema.choice(PetCommands.positions.map { $0.rawValue },
                                                       "left=왼쪽 반, right=오른쪽 반, maximize=최대화, top-left=왼쪽 위 1/4, first-third=왼쪽 1/3 …"),
                       "app": app,
                   ], required: ["position"]),
                   output: "{ok, message}", risk: .change, permissions: [.accessibility],
                   legacyConnectorName: PetCommands.arrangeWindow, requiresGadgetOn: false),
        GadgetTool(gadget: .window, action: "layout",
                   korean: "여러 앱의 창을 한 번에 배치해요(예: 사파리는 왼쪽 반, 메모는 오른쪽 반, 슬랙은 2번 디스플레이 최대화). "
                       + "항목마다 앱과 위치, 필요하면 디스플레이 번호를 줘요. 최대 8개, 손쉬운 사용 권한이 필요해요.",
                   english: "Places windows of several apps at once (up to 8 items: app, position, optional display number and window number).",
                   input: GadgetSchema.object([
                       "items": .object([
                           "type": .string("array"), "minItems": .int(1), "maxItems": .int(PetCommands.maxLayoutItems),
                           "items": GadgetSchema.object([
                               "app": app,
                               "position": GadgetSchema.choice(PetCommands.layoutPositions.map { $0.rawValue }),
                               "display": GadgetSchema.integer("디스플레이 번호(combo_list_windows 기준, 왼쪽부터 1). 없으면 창이 있는 화면", minimum: 1, maximum: 16),
                               "window": GadgetSchema.integer("그 앱의 몇 번째 창인지(앞에서부터 1). 기본 1", minimum: 1, maximum: 20),
                           ], required: ["app", "position"]),
                       ]),
                   ], required: ["items"]),
                   output: "{ok, message, placed, missing}", risk: .change, permissions: [.accessibility],
                   legacyConnectorName: PetCommands.layoutWindows, requiresGadgetOn: false),
        GadgetTool(gadget: .window, action: "list_windows",
                   korean: "맥의 디스플레이 목록(번호·크기)과 앱별 열린 창의 위치·크기·디스플레이 번호를 봐요(창 제목은 보내지 않아요). "
                       + "여러 창을 배치하거나 다른 화면으로 옮기기 전에 지금 상태를 확인할 때 써요. 손쉬운 사용 권한이 필요해요.",
                   english: "Lists the displays (number, size) and every app's open windows (frame, display number). Window titles are not sent.",
                   output: "{ok, message, displays:[…], windows:[…]}", risk: .read, permissions: [.accessibility],
                   legacyConnectorName: PetCommands.listWindows, requiresGadgetOn: false),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .window,
        summary: "창 배치 가젯으로 창을 화면의 정해진 자리(반·4등분·3등분·최대화)나 다른 디스플레이로 옮기고, 여러 앱의 창을 한 번에 배치해요.",
        canDo: ["맨 앞 창 또는 지정한 앱의 창 하나를 자리로 옮기기", "여러 앱 창을 한 번에 배치(최대 8개, 디스플레이 지정 가능)",
                "디스플레이와 열린 창 목록 보기(창 제목은 보내지 않아요)"],
        steps: ["디스플레이가 여러 개이거나 어떤 창이 열려 있는지 모르면 먼저 창 목록을 봐요.",
                "창 하나는 arrange, 여러 앱은 layout으로 한 번에 배치해요.",
                "결과의 message를 사용자에게 짧게 알려 줘요."],
        examples: [
            .init("list_windows", note: "배치 전에 디스플레이 번호와 창 위치를 확인할 때"),
            .init("arrange", .object(["position": .string("left"), "app": .string("Safari")]), note: "사파리 창을 왼쪽 반으로"),
            .init("layout", .object(["items": .array([
                .object(["app": .string("Safari"), "position": .string("left")]),
                .object(["app": .string("Notes"), "position": .string("right")]),
            ])]), note: "사파리는 왼쪽 반, 메모는 오른쪽 반"),
        ],
        limits: ["손쉬운 사용 권한이 필요해요. 없으면 ok:false와 켜는 방법을 돌려줘요.",
                 "layout 항목은 최대 8개, 디스플레이 번호는 창 목록 기준(왼쪽부터 1)이에요.",
                 "실행 중이 아닌 앱의 창은 옮기지 않아요(먼저 앱을 열어요)."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .window, flow: "side_by_side",
                     description: "Put two apps side by side (left half / right half) with Nacho Combo's window tools.",
                     arguments: [.init("left", "App for the left half", required: true), .init("right", "App for the right half", required: true)],
                     template: "Read the guide nachocombo://gadgets/window/guide, check the windows with window_list_windows, then place {left} "
                         + "on the left half and {right} on the right half with one window_layout call. Tell me what moved."),
    ]
}
