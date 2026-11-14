import Foundation

/// Computer Use (`computer`): the tools of the former Computer Use MCP server. On the MCP exit each one sits under its
/// tool group switch (`mcpGroup`, all off by default) and runs in `ComputerUseBackend` under its old name, which
/// `tools/call` still accepts. Not offered to Nacho yet: the computer use lane adds the connector exit (with the
/// content_out / input_inject approval rules) and the guide.
public enum ComputerTools: GadgetToolProvider {
    public static let gadget = GadgetID.computer

    private typealias S = GadgetSchema

    private static let windowTarget: [String: JSONValue] = [
        "pid": S.integer("Process ID of the app that owns the window (from app_list/window_list)"),
        "windowIndex": S.integer("Window number within that app (starts at 0, the index from window_list)"),
    ]

    private static func tool(_ old: String, _ group: ToolGroup, _ risk: GadgetToolRisk, korean: String, english: String,
                             input: JSONValue = GadgetSchema.object(), output: String = "MCP content (text)") -> GadgetTool {
        GadgetTool(gadget: .computer, action: old, korean: korean, english: english, input: input, output: output, risk: risk,
                   permissions: group.requiredPermissions, exits: [.mcp], legacyMCPName: old, mcpGroup: group)
    }

    public static let tools: [GadgetTool] = [
        // screen
        tool("screen_list_displays", .screen, .read,
             korean: "연결된 디스플레이 목록(아이디·크기·배율·주 디스플레이인지)을 돌려줘요.",
             english: "Returns the connected displays (ID, size, scale, whether it is the main display)."),
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
             output: "MCP content (image/png)"),
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
             korean: "마우스 포인터를 화면 좌표(포인트)로 옮겨요.",
             english: "Moves the mouse pointer to screen coordinates (in points).",
             input: S.object(["x": S.number("x"), "y": S.number("y")], required: ["x", "y"])),
        tool("mouse_click", .input, .inputInject,
             korean: "지정한 좌표를 클릭해요(왼쪽·오른쪽·가운데 버튼, 1~3번).",
             english: "Clicks at the given coordinates.",
             input: S.object(["x": S.number("x"), "y": S.number("y"),
                              "button": S.choice(["left", "right", "middle"], "Default left"),
                              "clickCount": S.integer("1 to 3, default 1")], required: ["x", "y"])),
        tool("mouse_drag", .input, .inputInject,
             korean: "마우스로 화면의 한 점에서 다른 점까지 끌어다 놓아요.",
             english: "Drags from one point to another.",
             input: S.object(["fromX": S.number("Start x"), "fromY": S.number("Start y"),
                              "toX": S.number("End x"), "toY": S.number("End y")], required: ["fromX", "fromY", "toX", "toY"])),
        tool("mouse_scroll", .input, .inputInject,
             korean: "픽셀 단위로 스크롤해요. 좌표를 주면 먼저 그 자리로 포인터를 옮겨요.",
             english: "Scrolls (in pixels). If x and y are given, the pointer moves there first.",
             input: S.object(["deltaX": S.integer("Horizontal"), "deltaY": S.integer("Vertical (positive = up)"),
                              "x": S.number("x"), "y": S.number("y")])),
        tool("key_press", .input, .inputInject,
             korean: "키 하나를 눌러요(수정 키와 함께). 예: 키 c와 커맨드.",
             english: "One key press (plus modifier keys). Example: key=\"c\", modifiers=[\"cmd\"]. Key names: a-z, 0-9, return, tab, space, delete, escape, arrow keys (left/right/up/down), f1-f12 and so on.",
             input: S.object(["key": S.string("Key name"),
                              "modifiers": S.stringList("cmd, shift, option(alt), control(ctrl), fn")], required: ["key"])),
        tool("type_text", .input, .inputInject,
             korean: "지금 입력 칸에 글을 입력해요(최대 \(InputPolicy.maxTextLength)자).",
             english: "Types text into the focused field (up to \(InputPolicy.maxTextLength) characters).",
             input: S.object(["text": S.string("Text to type")], required: ["text"])),
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
    ]

    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
