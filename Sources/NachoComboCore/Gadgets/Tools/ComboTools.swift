import Foundation

/// Nacho Combo itself: the gadget list and switches, workspaces, and the gadget guides.
public enum ComboTools: GadgetToolProvider {
    public static let gadget = GadgetID.combo

    static var workspaceName: JSONValue {
        GadgetSchema.string("작업 공간 이름, 예: 업무 모드", minLength: 1, maxLength: DesktopWorkspaceStore.maxNameLength)
    }

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .combo, action: "set_gadget",
                   korean: "나초콤보 가젯(창 배치·집중 디밍·잠자기 방지·파일 선반 등) 하나를 켜거나 꺼요. 가젯 이름은 gadget 목록에서 골라요. "
                       + "권한이 더 필요한 가젯은 사용자가 나초콤보에서 직접 켜야 해요.",
                   english: "Switches one Nacho Combo gadget on or off (never Computer Use or Nacho Pet). Gadgets that need more macOS permissions must be switched on by the user.",
                   input: GadgetSchema.object(["gadget": GadgetSchema.choice(PetCommands.toggleable.map { $0.rawValue }),
                                               "on": GadgetSchema.boolean()], required: ["gadget", "on"]),
                   output: "{ok, message, gadgets:{id: state}}", risk: .change,
                   legacyConnectorName: PetCommands.setGadget, requiresGadgetOn: false),
        GadgetTool(gadget: .combo, action: "list_gadgets",
                   korean: "나초콤보 가젯 목록과 각각 켜져 있는지 봐요. 어떤 가젯이 있는지, 지금 켜져 있는지 확인할 때 써요.",
                   english: "Lists the Nacho Combo gadgets and whether each one is on.",
                   output: "{ok, message, gadgets:{id: state}}", risk: .read,
                   legacyConnectorName: PetCommands.listGadgets, requiresGadgetOn: false),
        GadgetTool(gadget: .combo, action: "workspace_save",
                   korean: "지금 맥 상태(실행 중인 앱, 창 위치, 가젯 켜짐 상태)를 이름을 붙여 작업 공간으로 저장해요(예: \"업무 모드\"). "
                       + "같은 이름이 있으면 덮어써요. 손쉬운 사용 권한이 필요해요.",
                   english: "Saves the current Mac state (running apps, window frames, gadget switches) as a named workspace; the same name is overwritten.",
                   input: GadgetSchema.object(["name": workspaceName], required: ["name"]),
                   output: "{ok, message, workspace}", risk: .change, permissions: [.accessibility],
                   legacyConnectorName: PetCommands.saveWorkspace, requiresGadgetOn: false),
        GadgetTool(gadget: .combo, action: "workspace_apply",
                   korean: "저장한 작업 공간을 불러와요: 빠진 앱을 열고, 창을 저장한 자리로 옮기고, 가젯을 저장한 대로 켜고 꺼요. "
                       + "이미 열려 있는 다른 앱은 종료하지 않아요. 이름은 combo_workspace_list로 확인해요.",
                   english: "Restores a saved workspace: opens missing apps, moves windows back and switches gadgets as saved. Never quits other apps.",
                   input: GadgetSchema.object(["name": workspaceName], required: ["name"]),
                   output: "{ok, message}", risk: .change, permissions: [.accessibility],
                   legacyConnectorName: PetCommands.applyWorkspace, requiresGadgetOn: false),
        GadgetTool(gadget: .combo, action: "workspace_list",
                   korean: "저장된 작업 공간 이름과 각각의 앱·창 수, 저장 시각을 봐요. 어떤 작업 공간이 있는지 확인할 때 써요.",
                   english: "Lists the saved workspaces (name, app and window counts, time saved).",
                   output: "{ok, message, workspaces:[…]}", risk: .read,
                   legacyConnectorName: PetCommands.listWorkspaces, requiresGadgetOn: false),
        GadgetTool(gadget: .combo, action: "gadget_guide",
                   korean: "가젯 하나의 사용 가이드(할 수 있는 일, 순서, 예시 호출, 제약·권한)를 봐요. 처음 쓰는 가젯이거나 어떤 도구를 어떤 순서로 쓸지 모를 때 먼저 불러요.",
                   english: "Returns the usage guide of one gadget (what it can do, order of calls, example calls, limits). The same text as the MCP resource nachocombo://gadgets/<id>/guide.",
                   input: GadgetSchema.object(["gadget": GadgetSchema.choice(GadgetID.allCases.map { $0.rawValue }, "가젯 id, 예: window")],
                                              required: ["gadget"]),
                   output: "{ok, message, gadget, guide (markdown)}", risk: .read, exits: [.connector], requiresGadgetOn: false),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .combo,
        summary: "나초콤보 자체를 다뤄요: 가젯을 켜고 끄고, 지금 맥 상태를 작업 공간으로 저장했다가 다시 불러와요.",
        canDo: ["가젯 목록과 켜짐 상태 보기", "가젯 하나 켜기/끄기(컴퓨터 사용·나초 펫은 사용자만 바꿔요)",
                "작업 공간 저장·목록·불러오기", "가젯별 사용 가이드 보기"],
        steps: ["가젯 상태를 모르면 먼저 목록을 봐요.", "꺼진 가젯이 필요하면 사용자에게 켤지 물어본 뒤 켜요.",
                "작업 공간을 불러오기 전에 목록으로 이름을 확인해요."],
        examples: [
            .init("list_gadgets", note: "어떤 가젯이 켜져 있는지 볼 때"),
            .init("set_gadget", .object(["gadget": .string("focusDim"), "on": .bool(true)]), note: "사용자가 켜도 된다고 한 뒤 집중 디밍을 켤 때"),
            .init("workspace_apply", .object(["name": .string("업무 모드")]), note: "저장해 둔 '업무 모드'로 돌아갈 때"),
        ],
        limits: ["작업 공간 저장·불러오기는 손쉬운 사용 권한이 필요해요.", "불러오기는 다른 앱을 종료하지 않아요.",
                 "결과가 ok:false, reason:gadget_off이면 사용자에게 켤지 물어보고 combo_set_gadget을 불러요."])

    public static let prompts: [GadgetPrompt] = []
}
