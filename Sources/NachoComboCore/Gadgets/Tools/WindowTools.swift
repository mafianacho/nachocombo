import Foundation

/// Window Snap (`window`): one window to a position, several windows at once, the window list.
/// The window lane (grid, halves/thirds/quarters, ratios, displays, undo) adds its tools here.
public enum WindowTools: GadgetToolProvider {
    public static let gadget = GadgetID.window

    static var app: JSONValue {
        GadgetSchema.string("앱 이름(한국어 표시 이름·영문 이름·번들 ID), 예: 사파리, Safari, com.apple.Safari", maxLength: PetCommands.maxAppNameLength)
    }

    /// One window as the new tools name it: app plus the window's order in that app (the same numbers `window_list_windows` shows).
    static var windowRef: JSONValue {
        GadgetSchema.object([
            "app": app,
            "window": GadgetSchema.integer("그 앱의 몇 번째 창인지(앞에서부터 1). 기본 1. window_list_windows의 window 번호", minimum: 1, maximum: 20),
            "id": GadgetSchema.string("app 대신 쓰는 창 번호표 \"앱#번호\" (예: Safari#2). window_list_windows의 bundle_id 또는 앱 이름과 window 번호", maxLength: 120),
        ])
    }

    /// One rectangle of `window_place`.
    static var placeItem: JSONValue {
        GadgetSchema.object([
            "app": app,
            "window": GadgetSchema.integer("그 앱의 몇 번째 창인지(앞에서부터 1). 기본 1", minimum: 1, maximum: 20),
            "id": GadgetSchema.string("app 대신 쓰는 창 번호표 \"앱#번호\" (예: Safari#2)", maxLength: 120),
            "display": displayNumber,
            "x": GadgetSchema.number("왼쪽 가장자리. 사용 영역 왼쪽 위가 0"),
            "y": GadgetSchema.number("위쪽 가장자리. 사용 영역 왼쪽 위가 0"),
            "w": GadgetSchema.number("너비(0보다 커야 해요)"),
            "h": GadgetSchema.number("높이(0보다 커야 해요)"),
            "z": GadgetSchema.integer("앞뒤 순서. 클수록 앞. 없으면 목록 순서", minimum: -1000, maximum: 1000),
        ], required: ["x", "y", "w", "h"])
    }

    static func windowList(max: Int, _ note: String) -> JSONValue {
        .object(["type": .string("array"), "minItems": .int(1), "maxItems": .int(max), "items": windowRef,
                 "description": .string(note)])
    }

    static var displayNumber: JSONValue {
        GadgetSchema.integer("디스플레이 번호(window_displays 기준, 왼쪽부터 1). 없으면 첫 창이 있는 화면", minimum: 1, maximum: WindowTiling.maxDisplays)
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
                   korean: "여러 앱의 창을 한 번에 이름 붙은 자리(반·4등분·3등분·최대화 등)로 배치해요. 항목마다 앱과 위치, 필요하면 디스플레이 번호를 줘요. "
                       + "개수 제한은 없어요(한 번에 200개까지). 자유로운 좌표·바둑판은 window_place·window_tile을 써요. 손쉬운 사용 권한이 필요해요.",
                   english: "Places windows of several apps at once in named positions (halves, quarters, thirds, maximize). No layout limit: up to 200 items per call (a technical limit). For free coordinates or any grid use window_place and window_tile.",
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
        // NACHO-146: free placement, grids, splits, ratios, display moves, app bundles, undo. Names avoid `window_list` (kept for Computer Use).
        GadgetTool(gadget: .window, action: "displays",
                   korean: "연결된 디스플레이 목록(번호·이름·전체 크기·창이 놓일 수 있는 영역)을 봐요. 번호는 왼쪽부터 1이에요. "
                       + "여러 디스플레이에 창을 놓기 전에 어느 화면이 몇 번이고 얼마나 큰지 확인할 때 써요. 손쉬운 사용 권한이 필요해요.",
                   english: "Lists the displays (number from the left, name, size, usable area). Use it before placing windows on a specific display.",
                   output: "{ok, message, displays:[{display, name, main, x, y, width, height, usable:{x,y,width,height}}]}",
                   risk: .read, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "place",
                   korean: "창마다 원하는 자리(x, y, w, h)를 줘서 한 번에 놓아요. 개수 제한 없이(한 번에 200개까지) 겹쳐도 되고, z로 앞뒤도 정해요. "
                       + "다이아몬드·원형·계단 같은 모양은 직접 좌표를 계산해 써요. 부분 실패는 창별 결과로 알려요. 권한: 손쉬운 사용.",
                   english: "Free placement, the primitive behind every layout: one rectangle (x, y, w, h) per window inside a display's usable area, top-left origin, 0-1 ratios (default) or pixels. "
                       + "No layout limit (200 items per call is technical), overlaps and z order allowed, shapes are computed by the caller, out-of-range values are clamped.",
                   input: GadgetSchema.object([
                       "items": .object(["type": .string("array"), "minItems": .int(1), "maxItems": .int(WindowTiling.maxWindows), "items": placeItem,
                                         "description": .string("창마다 자리. 겹쳐도 돼요. 목록 순서가 기본 앞뒤 순서(뒤에 있는 항목이 위)")]),
                       "unit": GadgetSchema.choice(WindowCoordinateUnit.allCases.map { $0.rawValue }, "ratio(기본)=디스플레이 사용 영역의 0~1 비율, pixel=왼쪽 위에서부터의 포인트"),
                   ], required: ["items"]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing}", risk: .change, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "tile",
                   korean: "창을 바둑판으로 깔아요. rows×cols를 마음대로(예: 10×2), 채우는 순서(fill), 여러 디스플레이 걸치기(span)·디스플레이별, 간격(gap)을 정해요. "
                       + "all_windows:true면 열린 창 전부를 모든 화면에 깔아요. 개수 제한 없음(200개까지). 권한: 손쉬운 사용.",
                   english: "Tiles windows into a grid. Any rows x cols (e.g. 10x2), fill order, gap, one or several displays (span: per_display or across). all_windows:true tiles every open window. "
                       + "No layout limit (200 windows per call is a technical limit). Cells smaller than an app allows are reported with the applied frame.",
                   input: GadgetSchema.object([
                       "windows": windowList(max: WindowTiling.maxWindows, "깔 창들. 목록 순서대로 채워요. all_windows와 함께 쓰지 않아요"),
                       "all_windows": GadgetSchema.boolean("true면 열린 창 전부(모든 앱, 최소화 제외)를 깔아요. 전체 바둑판"),
                       "rows": GadgetSchema.integer("세로 칸 수. 없으면 창 수로 정해요", minimum: 1, maximum: WindowTiling.maxRowsOrColumns),
                       "cols": GadgetSchema.integer("가로 칸 수. 없으면 창 수로 정해요", minimum: 1, maximum: WindowTiling.maxRowsOrColumns),
                       "display": displayNumber,
                       "displays": .object(["type": .string("array"), "minItems": .int(1), "maxItems": .int(WindowTiling.maxDisplays),
                                            "items": GadgetSchema.integer(minimum: 1, maximum: WindowTiling.maxDisplays),
                                            "description": .string("쓸 디스플레이 번호들(window_displays 기준). display와 함께 쓰지 않아요. 없으면 첫 창이 있는 화면")]),
                       "span": GadgetSchema.choice(WindowSpan.allCases.map { $0.rawValue }, "per_display(기본)=화면마다 격자, across=모든 화면에 걸친 격자 하나"),
                       "fill": GadgetSchema.choice(WindowFill.allCases.map { $0.rawValue }, "row_major(기본)=가로로 먼저, column_major=세로로 먼저"),
                       "gap": GadgetSchema.integer("창 사이·가장자리 간격(포인트). 없으면 앱 설정", minimum: 0, maximum: 100),
                   ]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing}", risk: .change, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "split",
                   korean: "창을 2·3·4등분해서 놓아요. horizontal은 나란히(좌→우), vertical은 위아래, quadrant는 4창을 2x2로 놓아요. "
                       + "목록 순서대로 왼쪽/위부터 채워요. 더 많거나 다른 모양은 window_tile·window_place를 써요. 권한: 손쉬운 사용.",
                   english: "Convenience: splits a display into 2, 3 or 4 equal parts and places the windows in order: horizontal (side by side), vertical (stacked) or quadrant (2x2, needs parts 4). For more cells or other shapes use window_tile or window_place.",
                   input: GadgetSchema.object([
                       "parts": GadgetSchema.integer("몇 등분인지(2, 3, 4)", minimum: 2, maximum: 4),
                       "direction": GadgetSchema.choice(WindowSplitDirection.allCases.map { $0.rawValue }, "horizontal=나란히, vertical=위아래, quadrant=2x2(4등분만)"),
                       "windows": windowList(max: 4, "놓을 창들(등분 수 이하). 순서대로 채워요"),
                       "display": displayNumber,
                   ], required: ["parts", "direction", "windows"]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing}", risk: .change, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "ratio",
                   korean: "창 2~4개를 지정한 비율로 나눠 놓아요. 예: ratios [70,30]이면 왼쪽 70%, 오른쪽 30%. direction은 horizontal(나란히)이나 "
                       + "vertical(위아래)이에요. 더 복잡한 비율은 window_place를 써요. 권한: 손쉬운 사용.",
                   english: "Convenience: places 2-4 windows in the given proportions, e.g. ratios [70,30] gives 70% and 30% of the width. horizontal (default) or vertical. For anything more complex use window_place.",
                   input: GadgetSchema.object([
                       "ratios": .object(["type": .string("array"), "minItems": .int(2), "maxItems": .int(WindowTiling.maxRatioParts),
                                          "items": GadgetSchema.integer(minimum: 1, maximum: WindowTiling.maxRatioWeight),
                                          "description": .string("칸 비율 목록. [70,30], [1,2,1] 처럼. 합은 상관없고 서로의 비율만 봐요")]),
                       "direction": GadgetSchema.choice([WindowSplitDirection.horizontal.rawValue, WindowSplitDirection.vertical.rawValue], "기본 horizontal"),
                       "windows": windowList(max: WindowTiling.maxRatioParts, "놓을 창들(비율 개수 이하). 순서대로 채워요"),
                       "display": displayNumber,
                   ], required: ["ratios", "windows"]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing}", risk: .change, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "move_display",
                   korean: "창들을 다른 디스플레이로 옮겨요. 화면 안의 위치와 크기 비율은 그대로 유지해요. 디스플레이 번호는 window_displays 기준(왼쪽부터 1)이에요. "
                       + "손쉬운 사용 권한이 필요해요.",
                   english: "Moves windows to another display keeping their relative position and size. Display numbers come from window_displays.",
                   input: GadgetSchema.object([
                       "windows": windowList(max: WindowTiling.maxWindows, "옮길 창들"),
                       "display": GadgetSchema.integer("목적지 디스플레이 번호(왼쪽부터 1)", minimum: 1, maximum: WindowTiling.maxDisplays),
                   ], required: ["windows", "display"]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing}", risk: .change, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "arrange_apps",
                   korean: "앱 묶음(각 앱의 맨 앞 창)을 정해 둔 배치로 한 번에 놓아요. grid=바둑판, columns=나란히, rows=위아래, quadrants=2x2(최대 4개)예요. "
                       + "개수 제한 없음(200개까지). 실행 중인 앱만 옮겨요. 권한: 손쉬운 사용.",
                   english: "Places the front window of each listed running app in a preset arrangement: grid, columns, rows, quadrants (up to 4). No layout limit (200 apps per call).",
                   input: GadgetSchema.object([
                       "apps": .object(["type": .string("array"), "minItems": .int(1), "maxItems": .int(WindowTiling.maxApps), "items": app,
                                        "description": .string("앱 이름들(순서대로 왼쪽 위부터 채워요)")]),
                       "arrangement": GadgetSchema.choice(WindowArrangement.allCases.map { $0.rawValue }, "기본 grid"),
                       "display": displayNumber,
                   ], required: ["apps"]),
                   output: "{ok, message, windows:[{window, requested, applied, reason}], missing}", risk: .change, permissions: [.accessibility]),
        GadgetTool(gadget: .window, action: "undo",
                   korean: "직전 창 배치(자유 배치·바둑판·등분·비율·디스플레이 이동·앱 묶음)를 한 번에 되돌려 창을 배치 전 위치와 크기로 복원해요. "
                       + "steps로 최대 5번의 배치까지 되돌려요. 닫힌 창은 건너뛰어요. 권한: 손쉬운 사용.",
                   english: "Restores every window moved by the last placement(s) of these window tools to its frame from before, in one call. steps 1-5, default 1.",
                   input: GadgetSchema.object(["steps": GadgetSchema.integer("몇 번의 배치를 되돌릴지(1~5, 기본 1)", minimum: 1, maximum: WindowTiling.undoSteps)]),
                   output: "{ok, message, restored:[{window, applied}], missing}", risk: .change, permissions: [.accessibility]),
    ]

    static func rect(_ app: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, z: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["app": .string(app), "x": .double(x), "y": .double(y), "w": .double(w), "h": .double(h)]
        if let z = z { o["z"] = .int(z) }
        return .object(o)
    }

    /// The diamond recipe of the guide as `window_place` items: rows of 1, 2, 3, 2, 1 windows (ratios, top-left origin).
    static func diamond(apps: [String]) -> [JSONValue] {
        let counts = [1, 2, 3, 2, 1]
        var items: [JSONValue] = []
        var index = 0
        for (row, count) in counts.enumerated() {
            for k in 0..<count where index < apps.count {
                let cx = 0.5 + (Double(k) - Double(count - 1) / 2) * 0.22, cy = 0.16 + 0.17 * Double(row)
                items.append(rect(apps[index], (cx - 0.1).rounded(toPlaces: 3), (cy - 0.075).rounded(toPlaces: 3), 0.2, 0.15))
                index += 1
            }
        }
        return items
    }

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .window,
        summary: "창 배치 가젯으로 창을 원하는 자리에 자유롭게 놓아요. 개수 제한 없이(한 번에 200개까지) 아무 좌표·겹침·앞뒤 순서로 놓을 수 있고, "
            + "rows×cols 바둑판(10×2 등)·전체 바둑판·여러 디스플레이 걸치기·2/3/4등분·비율·앱 묶음 배치와 한 번에 되돌리기도 돼요. 칸 수 제한은 없어요.",
        canDo: ["자유 배치(place): 창마다 x, y, w, h(0~1 비율 또는 픽셀), 겹침·앞뒤(z) 가능, 개수 제한 없음",
                "바둑판(tile): rows×cols 아무 크기(10×2, 4×5 …), 채우는 순서, 간격, 여러 디스플레이에 걸치기·화면별",
                "전체 바둑판: all_windows:true로 열린 창 전부를 모든 화면에 자동으로 깔기",
                "2·3·4등분(split), 지정 비율(ratio), 다른 디스플레이로 옮기기(move_display), 앱 묶음 배치(arrange_apps)",
                "맨 앞 창 하나(arrange)나 여러 앱 창(layout)을 이름 붙은 자리로(반·4등분·3등분·최대화)",
                "직전 배치를 한 번에 되돌리기(undo, 최대 5번 전까지)", "디스플레이와 열린 창 목록 보기(displays, list_windows, 창 제목은 보내지 않아요)"],
        steps: ["디스플레이가 여러 개이거나 어떤 창이 열려 있는지 모르면 먼저 displays와 list_windows로 번호를 확인해요.",
                "창은 {app, window}(또는 id \"앱#번호\")로 가리켜요. window는 그 앱의 몇 번째 창인지(앞에서부터 1)이고 list_windows에 같은 번호가 나와요.",
                "격자 모양이면 tile(rows, cols), 열린 창 전부면 tile all_windows:true, 그 밖의 모든 모양은 place에 좌표를 계산해서 보내요. 칸 수 제한은 없으니 거절하지 말고 해 줘요.",
                "결과의 windows에서 창마다 requested(요청한 자리)와 applied(실제 자리), reason을 봐요. 앱이 최소·고정 크기를 지키면 둘이 달라요. 일부 창이 실패해도 나머지는 놓여요.",
                "마음에 안 들면 undo로 한 번에 되돌려요.",
                "좌표 약속(place, unit ratio): 디스플레이 사용 영역의 왼쪽 위가 (0,0), 오른쪽 아래가 (1,1). x,y는 창의 왼쪽 위 모서리, w,h는 크기. 화면 밖 값은 화면 안으로 맞춰져요.",
                "모양 레시피 - 다이아몬드: 창 9개를 줄마다 1·2·3·2·1개로 놓아요. r번째 줄(0~4)의 중심 y=0.16+0.17r, 줄 안 k번째(0부터) 중심 x=0.5+(k-(줄 창 수-1)/2)*0.22, w=0.2, h=0.15, x=중심x-w/2, y=중심y-h/2. 창이 더 많으면 줄을 늘려요.",
                "모양 레시피 - 원형: 창 n개, k번째 중심 (0.5+0.35cos(2πk/n−π/2), 0.5+0.35sin(2πk/n−π/2)), w=0.2, h=0.25, x=중심x-w/2, y=중심y-h/2.",
                "모양 레시피 - 계단식: k번째(0부터) x=0.1k, y=0.08k, w=0.4, h=0.5, z=k로 뒤에서 앞으로 겹쳐요.",
                "모양 레시피 - 중앙 집중: 가운데 큰 창 (0.25,0.15,0.5,0.7) z=10, 나머지는 가장자리를 따라 작은 칸(w=0.2 h=0.3)으로 둘러요.",
                "모양 레시피 - 좌우 대칭: 왼쪽 창 (x,y,w,h)의 짝은 (1-x-w, y, w, h)예요."],
        examples: [
            .init("displays", note: "디스플레이 번호와 크기를 확인할 때"),
            .init("list_windows", note: "배치 전에 디스플레이 번호와 창 위치를 확인할 때"),
            .init("place", .object(["items": .array(diamond(apps: ["Safari", "Notes", "Terminal", "Finder", "Slack", "Mail", "Music", "Preview", "Calendar"]))]),
                  note: "다이아몬드 모양으로 9개(줄마다 1·2·3·2·1개)"),
            .init("tile", .object(["rows": .int(10), "cols": .int(2), "all_windows": .bool(true)]), note: "열린 창 전부를 10×2 바둑판으로"),
            .init("tile", .object(["all_windows": .bool(true), "displays": .array([.int(1), .int(2)]), "span": .string("across")]),
                  note: "전체 바둑판: 모든 창을 두 화면에 걸쳐 자동 격자로"),
            .init("tile", .object(["windows": .array([.object(["app": .string("Safari")]), .object(["app": .string("Notes")]),
                                                      .object(["app": .string("Terminal")]), .object(["app": .string("Finder")])])]),
                  note: "창 4개를 2x2 바둑판으로"),
            .init("split", .object(["parts": .int(3), "direction": .string("horizontal"), "windows": .array([
                .object(["app": .string("Xcode")]), .object(["app": .string("Safari")]), .object(["app": .string("Terminal")]),
            ])]), note: "3등분으로 나란히(코드·브라우저·터미널)"),
            .init("ratio", .object(["ratios": .array([.int(70), .int(30)]), "windows": .array([
                .object(["app": .string("Xcode")]), .object(["app": .string("Notes")]),
            ])]), note: "왼쪽 70%, 오른쪽 30%"),
            .init("move_display", .object(["windows": .array([.object(["app": .string("Slack")])]), "display": .int(2)]),
                  note: "슬랙을 2번 디스플레이로"),
            .init("arrange_apps", .object(["apps": .array([.string("Safari"), .string("Notes")]), "arrangement": .string("columns")]),
                  note: "두 앱을 나란히"),
            .init("arrange", .object(["position": .string("left"), "app": .string("Safari")]), note: "사파리 창을 왼쪽 반으로"),
            .init("layout", .object(["items": .array([
                .object(["app": .string("Safari"), "position": .string("left")]),
                .object(["app": .string("Notes"), "position": .string("right")]),
            ])]), note: "사파리는 왼쪽 반, 메모는 오른쪽 반"),
            .init("undo", note: "방금 한 배치를 한 번에 되돌리기"),
        ],
        limits: ["손쉬운 사용 권한이 필요해요. 없으면 ok:false(permission_needed)와 켜는 방법을 돌려줘요.",
                 "칸 수·창 수에 레이아웃 제한은 없어요. 한 번의 호출은 기술상 창 200개까지예요(그보다 많으면 나눠서 불러요).",
                 "앱이 최소 크기나 고정 크기를 지키면 가능한 한 가깝게 놓고 applied와 reason으로 알려요. 일부만 실패해도 나머지는 그대로 놓여요.",
                 "undo는 이 도구들(place·tile·split·ratio·move_display·arrange_apps)로 한 직전 배치를 기억해요(앱을 끄면 사라져요). 닫힌 창은 건너뛰어요.",
                 "실행 중이 아닌 앱의 창은 옮기지 않아요(먼저 앱을 열어요). 최소화된 창은 건너뛰어요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .window, flow: "side_by_side",
                     description: "Put two apps side by side (left half / right half) with Nacho Combo's window tools.",
                     arguments: [.init("left", "App for the left half", required: true), .init("right", "App for the right half", required: true)],
                     template: "Read the guide nachocombo://gadgets/window/guide, check the windows with window_list_windows, then place {left} "
                         + "on the left half and {right} on the right half with one window_layout call. Tell me what moved."),
        GadgetPrompt(gadget: .window, flow: "work_in_three",
                     description: "Three-way work layout (작업용 3분할): editor, browser and terminal side by side in equal thirds.",
                     arguments: [.init("editor", "App for the left third", required: true), .init("browser", "App for the middle third", required: true),
                                 .init("terminal", "App for the right third", required: true)],
                     template: "Read nachocombo://gadgets/window/guide, check the displays with window_displays, then call window_split with parts 3, "
                         + "direction horizontal and the windows {editor}, {browser}, {terminal} in that order. If an app is not running, tell me instead "
                         + "of opening it. Report any window whose applied frame differs from requested, and offer window_undo."),
        GadgetPrompt(gadget: .window, flow: "tile_everything",
                     description: "Tile every open window in a grid over all displays (전체 바둑판), optionally rows x cols.",
                     arguments: [.init("rows", "Number of rows, empty for automatic"), .init("cols", "Number of columns, empty for automatic")],
                     template: "Read nachocombo://gadgets/window/guide, list the displays with window_displays, then call window_tile with all_windows true, "
                         + "span across, displays listing every display number, and rows {rows} / cols {cols} (leave them out when empty). There is no limit "
                         + "on the number of cells. Tell me how many windows were placed and which ones kept a different size, and offer window_undo."),
        GadgetPrompt(gadget: .window, flow: "arrange_shape",
                     description: "Arrange windows in any shape (diamond, circle, stairs, centered, mirrored) by computing coordinates for window_place.",
                     arguments: [.init("shape", "Shape such as diamond, circle, stairs, center focus, mirror", required: true),
                                 .init("apps", "Comma-separated app names, empty for the open windows", required: false)],
                     template: "Read nachocombo://gadgets/window/guide and follow its shape recipes. Arrange {apps} (all open windows from window_list_windows "
                         + "when empty) in this shape: {shape}. Compute one x, y, w, h rectangle per window (0-1 ratios, top-left origin, overlaps and z allowed) "
                         + "and send them all in one window_place call. Do not refuse because of the number of windows: there is no limit. "
                         + "Report windows whose applied frame differs from requested, and offer window_undo."),
    ]
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double { let m = pow(10, Double(places)); return (self * m).rounded() / m }
}
