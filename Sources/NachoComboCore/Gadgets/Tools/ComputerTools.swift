import Foundation

/// Computer Use (`computer`): the tools of the former Computer Use MCP server. On the MCP exit each one sits under its
/// tool group switch (`mcpGroup`, all off by default) and runs in `ComputerUseBackend` under its old name, which
/// `tools/call` still accepts.
///
/// Nacho (NACHO-147): the screenshot, the display list, mouse, keys and typing are also declared to the connector
/// (`nacho: true`), and the accessibility tree tools (`ui_tree`, `find_element`, `click_element`) are new on both exits.
/// On Nacho's path content_out / input_inject ask every time unless Computer Use is "always allowed"; they run in
/// `ComputerGadgetRunner` (emergency stop, closed argument checks, screenshots attached to the chat). The high-risk
/// groups (AppleScript, shell, files, processes) and the rest stay MCP only, under their own switches.
public enum ComputerTools: GadgetToolProvider {
    public static let gadget = GadgetID.computer

    private typealias S = GadgetSchema

    private static let windowTarget: [String: JSONValue] = [
        "pid": S.integer("Process ID of the app that owns the window (from app_list/window_list)"),
        "windowIndex": S.integer("Window number within that app (starts at 0, the index from window_list)"),
    ]

    /// `nacho`: also declared to the connector (Nacho in the chat), with the approval of its risk.
    private static func tool(_ old: String, _ group: ToolGroup, _ risk: GadgetToolRisk, korean: String, english: String,
                             input: JSONValue = GadgetSchema.object(), output: String = "MCP content (text)",
                             nacho: Bool = false) -> GadgetTool {
        GadgetTool(gadget: .computer, action: old, korean: korean, english: english, input: input, output: output, risk: risk,
                   permissions: group.requiredPermissions, exits: nacho ? [.mcp, .connector] : [.mcp], legacyMCPName: old, mcpGroup: group)
    }

    public static let tools: [GadgetTool] = [
        // screen
        tool("screen_list_displays", .screen, .read,
             korean: "연결된 디스플레이 목록(아이디·크기·배율·주 디스플레이인지)을 돌려줘요.",
             english: "Returns the connected displays (ID, size, scale, whether it is the main display).",
             nacho: true),
        tool("screen_capture", .screen, .contentOut,
             korean: "화면을 PNG로 찍어 돌려줘요. 디스플레이 전체, 창 하나, 지정한 영역 중에서 골라요.",
             english: "Returns a screenshot as PNG. target: display (whole display, displayId optional), window (needs windowId), region (needs x, y, width, height in screen points).",
             input: S.object([
                 "target": S.choice(["display", "window", "region"], "What to capture"),
                 "displayId": S.integer("Display ID (main display if omitted)"),
                 "windowId": S.integer("Window ID (windowId from window_list)"),
                 "x": S.number("Region top-left x"), "y": S.number("Region top-left y"),
                 "width": S.number("Region width"), "height": S.number("Region height"),
                 "maxWidth": S.integer("Wider images are scaled down keeping the aspect ratio (default \(ScreenshotPolicy.defaultMaxWidth))"),
             ], required: ["target"]),
             output: "MCP content (image/png)",
             nacho: true),
        // apps and windows
        tool("app_list", .appsWindows, .read,
             korean: "실행 중인 일반 앱 목록(이름·번들 아이디·프로세스 번호·맨 앞인지)을 돌려줘요.",
             english: "Running regular apps (name, bundleId, pid, whether active)."),
        tool("app_open", .appsWindows, .change,
             korean: "앱을 실행해요. 번들 아이디나 앱 이름 중 하나를 꼭 줘요.",
             english: "Launches an app. Give either bundleId or name.",
             input: S.object(["bundleId": S.string("e.g. com.apple.Safari"), "name": S.string("App name")])),
        tool("app_activate", .appsWindows, .change,
             korean: "앱을 맨 앞으로 가져와요. 프로세스 번호나 번들 아이디 중 하나를 줘요.",
             english: "Brings an app to the front. Give either pid or bundleId.",
             input: S.object(["pid": S.integer("Process ID"), "bundleId": S.string("bundleId")])),
        tool("app_quit", .appsWindows, .destructive,
             korean: "앱에 정상 종료를 요청해요(저장 여부는 그 앱이 물어봐요). 강제 종료는 프로세스 끝내기 도구를 써요.",
             english: "Asks an app to quit normally (the app handles save prompts and so on). For a forced quit use process_kill.",
             input: S.object(["pid": S.integer("Process ID"), "bundleId": S.string("bundleId")])),
        tool("window_list", .appsWindows, .read,
             korean: "보이는 창 목록(창 아이디·프로세스 번호·앱 이름·제목·위치와 크기·순번)을 돌려줘요.",
             english: "Visible windows (windowId, pid, app name, title, position and size, index)."),
        tool("window_set_frame", .appsWindows, .change,
             korean: "창의 위치와 크기를 바꿔요. 준 값만 바뀌어요.",
             english: "Changes a window's position and size. Only the given values among x, y, width, height are changed.",
             input: S.object(windowTarget.merging([
                 "x": S.number("New x"), "y": S.number("New y"), "width": S.number("New width"), "height": S.number("New height"),
             ]) { a, _ in a }, required: ["pid", "windowIndex"])),
        tool("window_minimize", .appsWindows, .change,
             korean: "창 하나를 독으로 최소화하거나 다시 화면에 펼쳐요.",
             english: "Minimizes a window or restores it.",
             input: S.object(windowTarget.merging(["minimized": S.boolean("true = minimize, false = restore (default true)")]) { a, _ in a },
                             required: ["pid", "windowIndex"])),
        // input
        tool("mouse_move", .input, .inputInject,
             korean: "마우스 포인터를 화면 좌표(포인트, 주 디스플레이 왼쪽 위가 0,0)로 옮겨요. 클릭하지는 않아요.",
             english: "Moves the mouse pointer to screen coordinates (in points).",
             input: S.object(["x": S.number("x"), "y": S.number("y")], required: ["x", "y"]),
             nacho: true),
        tool("mouse_click", .input, .inputInject,
             korean: "지정한 좌표를 클릭해요(왼쪽·오른쪽·가운데 버튼, 1~3번).",
             english: "Clicks at the given coordinates.",
             input: S.object(["x": S.number("x"), "y": S.number("y"),
                              "button": S.choice(["left", "right", "middle"], "Default left"),
                              "clickCount": S.integer("1 to 3, default 1")], required: ["x", "y"]),
             nacho: true),
        tool("mouse_drag", .input, .inputInject,
             korean: "마우스로 화면의 한 점에서 다른 점까지 끌어다 놓아요.",
             english: "Drags from one point to another.",
             input: S.object(["fromX": S.number("Start x"), "fromY": S.number("Start y"),
                              "toX": S.number("End x"), "toY": S.number("End y")], required: ["fromX", "fromY", "toX", "toY"]),
             nacho: true),
        tool("mouse_scroll", .input, .inputInject,
             korean: "픽셀 단위로 스크롤해요. 좌표를 주면 먼저 그 자리로 포인터를 옮겨요.",
             english: "Scrolls (in pixels). If x and y are given, the pointer moves there first.",
             input: S.object(["deltaX": S.integer("Horizontal"), "deltaY": S.integer("Vertical (positive = up)"),
                              "x": S.number("x"), "y": S.number("y")]),
             nacho: true),
        tool("key_press", .input, .inputInject,
             korean: "키 하나를 눌러요(수정 키와 함께). 예: 키 c와 커맨드.",
             english: "One key press (plus modifier keys). Example: key=\"c\", modifiers=[\"cmd\"]. Key names: a-z, 0-9, return, tab, space, delete, escape, arrow keys (left/right/up/down), f1-f12 and so on.",
             input: S.object(["key": S.string("Key name"),
                              "modifiers": S.stringList("cmd, shift, option(alt), control(ctrl), fn")], required: ["key"]),
             nacho: true),
        tool("type_text", .input, .inputInject,
             korean: "지금 초점이 있는 입력 칸에 글을 입력해요(최대 \(InputPolicy.maxTextLength)자). 먼저 그 칸을 클릭해 초점을 옮겨요.",
             english: "Types text into the focused field (up to \(InputPolicy.maxTextLength) characters).",
             input: S.object(["text": S.string("Text to type")], required: ["text"]),
             nacho: true),
        // clipboard
        tool("clipboard_read", .clipboard, .contentOut,
             korean: "지금 클립보드에 복사돼 있는 글을 읽어 돌려줘요.",
             english: "Reads the text on the clipboard."),
        tool("clipboard_write", .clipboard, .change,
             korean: "클립보드에 글을 써서 붙여 넣을 수 있게 해요.",
             english: "Writes text to the clipboard.",
             input: S.object(["text": S.string("Text to copy")], required: ["text"])),
        // open
        tool("open_url", .openItems, .change,
             korean: "웹 주소나 메일 주소를 기본 앱으로 열어요(http·https·mailto 주소만 받아요).",
             english: "Opens a URL in the default app (http, https and mailto only).",
             input: S.object(["url": S.string("URL")], required: ["url"])),
        tool("open_file", .openItems, .change,
             korean: "파일을 기본 앱으로 열어요(절대 경로, 실행 파일 종류는 거절해요).",
             english: "Opens a file in the default app (absolute path; executable file types are refused).",
             input: S.object(["path": S.string("Absolute path")], required: ["path"])),
        // system
        tool("system_info", .systemInfo, .read,
             korean: "운영체제 버전·모델·켜진 시간·배터리·소리·디스플레이 요약을 돌려줘요.",
             english: "Summary of macOS version, model, uptime, battery, volume and displays."),
        tool("process_list", .systemInfo, .read,
             korean: "실행 중인 프로세스 목록(번호·이름)을 돌려줘요. 실행 인자는 넣지 않아요.",
             english: "Running processes (pid, name). Command-line arguments are not included."),
        // high risk
        tool("applescript_run", .appleScript, .destructive,
             korean: "[고위험] 애플스크립트를 실행하고 결과를 돌려줘요.",
             english: "[High risk] Runs AppleScript and returns the result.",
             input: S.object(["script": S.string("AppleScript source")], required: ["script"])),
        tool("shell_run", .shell, .destructive,
             korean: "[고위험] 셸 명령을 실행해요(시간과 출력 크기 제한이 있어요).",
             english: "[High risk] Runs a command with /bin/zsh -c (time and output size limits).",
             input: S.object(["command": S.string("Command"), "cwd": S.string("Working directory (absolute path, optional)"),
                              "timeoutSeconds": S.integer("1 to \(ShellPolicy.maxTimeout), default \(ShellPolicy.defaultTimeout)")],
                             required: ["command"])),
        tool("file_read", .fileAccess, .contentOut,
             korean: "[고위험] 글 파일을 읽어요(최대 \(FilePolicy.maxReadBytes)바이트).",
             english: "[High risk] Reads a text file (up to \(FilePolicy.maxReadBytes) bytes).",
             input: S.object(["path": S.string("Absolute path")], required: ["path"])),
        tool("file_write", .fileAccess, .destructive,
             korean: "[고위험] 글 파일을 써요(덧붙이기 선택 가능).",
             english: "[High risk] Writes a text file (append=true appends).",
             input: S.object(["path": S.string("Absolute path"), "content": S.string("Content"),
                              "append": S.boolean("Whether to append")], required: ["path", "content"])),
        tool("process_kill", .processControl, .destructive,
             korean: "[고위험] 프로세스에 종료 신호를 보내요(기본 TERM, KILL·INT·HUP도 가능).",
             english: "[High risk] Sends a signal to a process (TERM by default; KILL/INT/HUP also allowed).",
             input: S.object(["pid": S.integer("Process ID"), "signal": S.choice(["TERM", "KILL", "INT", "HUP"], "Default TERM")],
                             required: ["pid"])),
        // accessibility tree (NACHO-147): run in ComputerGadgetRunner on both exits
        GadgetTool(gadget: .computer, action: ComputerGadgetRunner.treeAction,
                   korean: "맨 앞 창(또는 지정한 앱)의 화면 요소를 손쉬운 사용 트리로 읽어요. 역할·제목·값·위치와 요소 아이디를 돌려줘요. "
                       + "깊이·개수·글자 수 상한이 있고 암호 칸 값은 보내지 않아요.",
                   english: "Reads the accessibility tree of the front window (scope window) or the whole app (scope app) of the frontmost app, "
                       + "or of the app given by pid or app name. Bounded: maxDepth 1-25 (8), maxNodes 1-500 (200), maxTextLength 10-200 (80). "
                       + "Each element has an id for computer_click_element, its role, title, value, label and frame in screen points.",
                   input: S.object(target.merging([
                       "maxDepth": S.integer("How deep to read (1-25, default 8)", minimum: UITreeLimits.depthRange.lowerBound,
                                             maximum: UITreeLimits.depthRange.upperBound),
                       "maxNodes": S.integer("At most this many elements (1-500, default 200)", minimum: UITreeLimits.nodeRange.lowerBound,
                                             maximum: UITreeLimits.nodeRange.upperBound),
                       "maxTextLength": S.integer("Texts are cut to this many characters (10-200, default 80)",
                                                  minimum: UITreeLimits.textRange.lowerBound, maximum: UITreeLimits.textRange.upperBound),
                   ]) { a, _ in a }),
                   output: "{ok, message, app, scope, read, nodes:[{id, depth, role, title?, value?, label?, frame?, children?}], truncated}",
                   risk: .contentOut, permissions: [.accessibility], mcpGroup: .appsWindows),
        GadgetTool(gadget: .computer, action: ComputerGadgetRunner.findAction,
                   korean: "맨 앞 창(또는 지정한 앱)에서 역할(버튼·글 칸 등)이나 제목·이름으로 화면 요소를 찾아 아이디와 위치를 돌려줘요. "
                       + "누를 버튼이나 입력 칸을 찾을 때 트리 전체 대신 써요.",
                   english: "Finds elements of the front window (or app) by role (button, textField, AXCheckBox …) and/or title "
                       + "(case-insensitive text in title, label or value). Returns up to maxResults (1-30, default 10) elements with ids "
                       + "for computer_click_element and frames in screen points.",
                   input: S.object(target.merging([
                       "role": S.string("Role, e.g. button, textField, checkBox, menuItem (AX prefix optional)", maxLength: 60),
                       "title": S.string("Text the title, label or value contains (case-insensitive)", maxLength: 100),
                       "maxResults": S.integer("1-30, default 10", minimum: UITreeLimits.resultRange.lowerBound,
                                               maximum: UITreeLimits.resultRange.upperBound),
                   ]) { a, _ in a }),
                   output: "{ok, message, app, read, nodes:[{id, role, title?, frame?}], scanned}",
                   risk: .contentOut, permissions: [.accessibility], mcpGroup: .appsWindows),
        GadgetTool(gadget: .computer, action: ComputerGadgetRunner.clickAction,
                   korean: "트리나 찾기 결과의 요소 아이디로 그 요소 가운데를 클릭해요(press면 기본 동작 실행). 아이디 대신 화면 좌표도 돼요. "
                       + "요소가 바뀌었으면 클릭하지 않아요.",
                   english: "Clicks an element by its id from a recent computer_ui_tree / computer_find_element answer (the middle of its frame; "
                       + "press=true runs its default action instead), or clicks screen coordinates x, y. Refuses an id whose element "
                       + "changed or is gone (read the tree again).",
                   input: S.object([
                       "id": S.string("Element id, e.g. t3.12", maxLength: 20),
                       "x": S.number("Screen x in points (instead of id)"), "y": S.number("Screen y in points (instead of id)"),
                       "press": S.boolean("true = run the element's default action (AXPress) instead of a mouse click"),
                       "button": S.choice(["left", "right", "middle"], "Default left"),
                       "clickCount": S.integer("1 to 3, default 1", minimum: 1, maximum: 3),
                   ]),
                   output: "{ok, message, id?, clicked:{x, y}}",
                   risk: .inputInject, permissions: [.accessibility], mcpGroup: .input),
    ]

    /// Which app the tree tools read (frontmost app's front window by default).
    private static let target: [String: JSONValue] = [
        "scope": S.choice(UITreeScope.allCases.map { $0.rawValue }, "window = the app's front window (default), app = menu bar and every window"),
        "app": S.string("App name or bundle id (default: the frontmost app)", minLength: 1, maxLength: PetCommands.maxAppNameLength),
        "pid": S.integer("Process id of the app (from computer_app_list), instead of app", minimum: 1),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .computer,
        summary: "컴퓨터 사용 가젯으로 화면을 보고(손쉬운 사용 트리·스크린샷) 클릭·입력·단축키·스크롤로 맥을 대신 조작해요. "
            + "항상 관찰 → 행동 → 확인 순서로 한 걸음씩 해요.",
        canDo: ["맨 앞 창이나 지정한 앱의 화면 요소를 트리로 읽기(역할·제목·값·위치·아이디)",
                "역할이나 제목으로 버튼·입력 칸 같은 요소 찾기",
                "요소 아이디나 화면 좌표로 클릭하기, 기본 동작(press) 실행하기",
                "글 입력, 단축키 누르기, 스크롤, 끌어다 놓기, 마우스 옮기기",
                "스크린샷 찍기(나초 대화에서는 입력 칸에 첨부돼요), 디스플레이 목록 보기"],
        steps: ["관찰: 먼저 ui_tree(또는 find_element)로 지금 화면을 읽어요. 글로 충분하면 스크린샷은 찍지 않아요.",
                "행동: 트리의 요소 아이디로 click_element를 해요. 아이디가 없을 때만 좌표를 써요. 글은 입력 칸을 클릭한 뒤 type_text로 넣어요.",
                "확인: 행동 뒤에 ui_tree를 다시 읽어 결과를 확인해요. 바뀌지 않았으면 같은 행동을 되풀이하지 말고 사용자에게 물어요.",
                "한 번에 한 행동만 해요. 사용자가 승인한 것보다 많이 하지 않아요."],
        examples: [
            .init(ComputerGadgetRunner.treeAction, .object(["maxNodes": .int(120)]), note: "맨 앞 창의 요소를 120개까지 읽을 때"),
            .init(ComputerGadgetRunner.findAction, .object(["role": .string("button"), "title": .string("저장")]), note: "'저장' 버튼을 찾을 때"),
            .init(ComputerGadgetRunner.clickAction, .object(["id": .string("t3.12")]), note: "찾은 요소(아이디 t3.12)를 클릭할 때"),
            .init("type_text", .object(["text": .string("안녕하세요")]), note: "입력 칸을 클릭한 뒤 글을 넣을 때"),
            .init("key_press", .object(["key": .string("s"), "modifiers": .array([.string("cmd")])]), note: "⌘S 단축키"),
            .init("screen_capture", .object(["target": .string("display")]), note: "트리로 알 수 없을 때만 화면을 찍어요"),
        ],
        limits: ["좌표는 화면 포인트예요. 주 디스플레이 왼쪽 위가 (0, 0)이고 아래로 갈수록 y가 커져요. 레티나 화면의 스크린샷 픽셀은 포인트의 2배일 수 있으니 트리의 frame 값을 써요.",
                 "트리는 깊이 1~25(기본 8), 요소 1~500개(기본 200), 글자 10~200자(기본 80)까지만 보내요. truncated가 true면 범위를 좁혀(app·scope·find_element) 다시 읽어요.",
                 "암호 입력 칸의 값은 보내지 않아요(secure:true). 요소 아이디는 최근 5번의 읽기에서만 쓸 수 있고, 요소가 바뀌었으면 클릭하지 않아요.",
                 "권한: 트리·클릭·입력은 손쉬운 사용, 스크린샷은 화면 기록 권한이 필요해요. 없으면 ok:false와 켜는 방법을 돌려줘요.",
                 "컴퓨터 사용 가젯은 사용자가 나초콤보에서 직접 켜요(combo_set_gadget으로는 켤 수 없어요). 꺼져 있으면 사용자에게 켜 달라고 말해요.",
                 "비상정지 ⌃⌥⌘.를 누르면 진행 중인 요청과 기다리는 요청이 모두 바로 거절돼요(reason: emergency_stop). 다시 시도하지 않아요.",
                 "나초 대화에서 스크린샷은 결과로 바로 보이지 않고 입력 칸에 첨부돼요. 사용자가 보내면 그다음 메시지에서 볼 수 있어요.",
                 "애플스크립트·셸·파일 읽기/쓰기·프로세스 종료는 나초에게 열지 않아요(MCP 클라이언트 전용, 고위험 스위치)."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .computer, flow: "click_by_label",
                     description: "Find an element by its label in the front window, click it, and check the result (observe, act, confirm).",
                     arguments: [.init("label", "Text on the button or control", required: true),
                                 .init("app", "App name (default: the frontmost app)")],
                     template: "Read the guide nachocombo://gadgets/computer/guide. With computer_find_element find the element whose title "
                         + "contains \"{label}\" (app: {app}; empty means the frontmost app). Click it with computer_click_element using its id, "
                         + "then read computer_ui_tree again and tell me what changed. If nothing matches, show me the closest elements instead of guessing."),
        GadgetPrompt(gadget: .computer, flow: "describe_screen",
                     description: "Describe what is on the screen from the accessibility tree (a screenshot only when the tree is not enough).",
                     arguments: [.init("app", "App name (default: the frontmost app)")],
                     template: "Read the guide nachocombo://gadgets/computer/guide, read computer_ui_tree for {app} (empty means the frontmost app) "
                         + "and describe the window: its main areas, buttons and fields. Take computer_screen_capture only if the tree is not enough."),
    ]
}
