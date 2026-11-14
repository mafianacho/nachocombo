import Foundation

/// Menu Bar Organizer (`menubar`): state, the items Accessibility can read, fold / unfold / tidy / show hidden.
/// Hiding or showing ONE other app's item is deliberately not a tool (see the guide and NACHO-148): macOS has no public
/// API for it.
public enum MenuBarTools: GadgetToolProvider {
    public static let gadget = GadgetID.menubar

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .menubar, action: "status",
                   korean: "메뉴 막대 정리 가젯의 지금 상태를 봐요: 접혀 있는지, 자동으로 다시 접는 시간, 항상 숨김 구역을 쓰는지. 접기·펼치기 전에 확인할 때 써요.",
                   english: "Reads the Menu Bar Organizer state: folded or expanded, auto-collapse seconds, whether the always-hidden section is on.",
                   output: "{ok, message, collapsed, auto_collapse_seconds, always_hidden_section, showing_always_hidden, divider_failed}",
                   risk: .read),
        GadgetTool(gadget: .menubar, action: "list_items",
                   korean: "메뉴 막대에 올라 있는 앱 아이콘(상태 항목)의 앱 이름·제목·위치와 구역(보임·숨김·항상 숨김)을 읽어요. 손쉬운 사용 권한이 필요해요.",
                   english: "Lists the menu bar status items read through Accessibility: app, title, position and zone (visible, hidden, always_hidden).",
                   output: "{ok, message, items:[{app,title,x,y,width,height,zone,on_screen,own}], count, zones}",
                   risk: .read, permissions: [.accessibility]),
        GadgetTool(gadget: .menubar, action: "tidy",
                   korean: "지금 메뉴 막대를 정리해요: 구분선 왼쪽 아이콘을 접어 숨겨요(항상 숨김 구역도 다시 접어요). 아이콘이 어수선할 때 써요.",
                   english: "Tidies the menu bar now: folds the icons left of the divider away and re-folds the always-hidden section.",
                   output: "{ok, message, collapsed, changed, …state}", risk: .change),
        GadgetTool(gadget: .menubar, action: "set_collapsed",
                   korean: "메뉴 막대 아이콘을 접거나(collapsed=true) 펼쳐요(false). 펼치면 설정한 시간 뒤 다시 접혀요.",
                   english: "Folds (collapsed=true) or unfolds (false) the menu bar icons. An unfolded bar folds again after the auto-collapse time.",
                   input: GadgetSchema.object(["collapsed": GadgetSchema.boolean("true=접기, false=펼치기")], required: ["collapsed"]),
                   output: "{ok, message, collapsed, changed, …state}", risk: .change),
        GadgetTool(gadget: .menubar, action: "show_hidden",
                   korean: "항상 숨김 구역까지 모든 아이콘을 잠깐 보여 줘요. 다음에 접을 때까지 보여요. 숨겨 둔 아이콘을 눌러야 할 때 써요.",
                   english: "Shows every icon including the always-hidden section until the next fold.",
                   output: "{ok, message, collapsed, showing_always_hidden, …state}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .menubar,
        summary: "메뉴 막대 정리 가젯은 구분선 왼쪽의 아이콘을 접어 숨겨요. 도구로는 상태 확인, 아이콘 읽기, 접기·펼치기·정리, 숨긴 아이콘 잠깐 보기를 할 수 있어요.",
        canDo: ["접힘 여부와 자동 접힘 설정 보기", "메뉴 막대 아이콘 목록과 구역 읽기(손쉬운 사용 권한)",
                "지금 접기·펼치기·정리", "항상 숨김 구역까지 잠깐 보이기"],
        steps: ["먼저 status로 접혀 있는지 봐요.",
                "어떤 아이콘이 있는지 알고 싶으면 list_items를 불러요. 권한이 없으면 안내를 사용자에게 전해요.",
                "정리하려면 tidy, 펼치려면 set_collapsed(false), 숨긴 아이콘을 눌러야 하면 show_hidden을 불러요.",
                "결과의 message를 짧게 알려 줘요."],
        examples: [
            .init("status", note: "접혀 있는지 확인할 때"),
            .init("list_items", note: "메뉴 막대에 어떤 앱 아이콘이 있는지 볼 때"),
            .init("tidy", note: "메뉴 막대를 지금 정리할 때"),
            .init("set_collapsed", .object(["collapsed": .bool(false)]), note: "아이콘을 펼쳐서 보여 줄 때"),
        ],
        limits: ["어떤 아이콘을 숨길지는 사용자가 ⌘를 누른 채 아이콘을 구분선 왼쪽으로 끌어 정해요. macOS에는 다른 앱의 아이콘을 옮기거나 숨기는 공개 방법이 없어서, 아이콘 하나만 숨기고 보이는 도구는 없어요.",
                 "list_items는 손쉬운 사용 권한이 필요해요. 없으면 ok:false(permission_needed)와 켜는 방법을 돌려줘요.",
                 "항목 위치는 읽기 전용이에요. 아이콘의 그림이나 앱 안의 내용은 읽지 않아요.",
                 "맥 화면 구성이나 macOS 버전에 따라 구분선이 늘어나지 않으면 접어도 숨겨지지 않아요(divider_failed)."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .menubar, flow: "organize",
                     description: "메뉴 막대 정리해 줘 — Tidy the menu bar: check its state, fold it and report what is hidden.",
                     arguments: [],
                     template: "Read the guide nachocombo://gadgets/menubar/guide, call menubar_status, then menubar_tidy. "
                         + "If Accessibility is allowed, call menubar_list_items and tell me which apps are hidden now. "
                         + "Remind me that I choose which icons to hide by dragging them left of the divider with the Command key held."),
    ]
}
