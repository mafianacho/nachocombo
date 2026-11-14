import Foundation

/// Apps (`appswitch`): list, open, switch to, hide and quit apps.
public enum AppSwitchTools: GadgetToolProvider {
    public static let gadget = GadgetID.appswitch

    static var app: JSONValue { WindowTools.app }

    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .appswitch, action: "list",
                   korean: "맥에서 지금 실행 중인 앱 목록(이름·번들 ID·맨 앞인지·숨김인지)을 봐요. installed=true면 설치된 앱 이름도 함께 봐요. "
                       + "앱 이름이 확실하지 않을 때 열거나 전환하기 전에 써요.",
                   english: "Lists the running apps (name, bundle id, frontmost, hidden); installed=true adds the names of installed apps.",
                   input: GadgetSchema.object(["installed": GadgetSchema.boolean("설치된 앱도 포함(기본 false)")]),
                   output: "{ok, message, running:[…], installed?:[…]}", risk: .read,
                   legacyConnectorName: PetCommands.listApps, requiresGadgetOn: false),
        GadgetTool(gadget: .appswitch, action: "open",
                   korean: "맥에 설치된 앱을 열고 맨 앞으로 가져와요(예: \"사파리 열어 줘\", \"메모 켜 줘\"). 이미 실행 중이면 그 앱으로 전환해요. "
                       + "앱 이름은 한국어 표시 이름·영문 이름·번들 ID 모두 돼요.",
                   english: "Opens an installed app and brings it to the front (switches to it when it already runs). Korean or English name, or bundle id.",
                   input: GadgetSchema.object(["app": app], required: ["app"]),
                   output: "{ok, message, candidates?, suggestions?}", risk: .change,
                   legacyConnectorName: PetCommands.openApp, requiresGadgetOn: false),
        GadgetTool(gadget: .appswitch, action: "focus",
                   korean: "이미 실행 중인 앱으로 전환해 맨 앞에 보여 줘요(숨겨져 있으면 다시 보이게). \"크롬으로 바꿔 줘\"처럼 앱 전환을 원할 때 써요. "
                       + "실행 중이 아니면 combo_open_app을 써요.",
                   english: "Switches to a running app and shows it in front (unhides it). Use appswitch_open for an app that is not running.",
                   input: GadgetSchema.object(["app": app], required: ["app"]),
                   output: "{ok, message}", risk: .change,
                   legacyConnectorName: PetCommands.focusApp, requiresGadgetOn: false),
        GadgetTool(gadget: .appswitch, action: "hide",
                   korean: "실행 중인 앱의 창을 모두 숨겨요(⌘H와 같고 앱은 종료하지 않아요). \"슬랙 잠깐 가려 줘\"처럼 화면에서 치우고 싶을 때 써요. "
                       + "Finder·나초콤보는 숨기지 않아요.",
                   english: "Hides all windows of a running app (like Cmd-H; the app keeps running). Finder and Nacho Combo are never hidden.",
                   input: GadgetSchema.object(["app": app], required: ["app"]),
                   output: "{ok, message}", risk: .change,
                   legacyConnectorName: PetCommands.hideApp, requiresGadgetOn: false),
        GadgetTool(gadget: .appswitch, action: "quit",
                   korean: "실행 중인 앱을 종료해요(저장하지 않은 내용은 그 앱이 물어봐요). 사용자가 분명히 종료를 원할 때만 쓰고, "
                       + "실행 전에 사용자 승인이 필요해요. Finder·나초콤보는 종료하지 않아요.",
                   english: "Asks a running app to quit (the app asks about unsaved work). Only when the user clearly wants it; Finder and Nacho Combo are never quit.",
                   input: GadgetSchema.object(["app": app], required: ["app"]),
                   output: "{ok, message}", risk: .destructive,
                   legacyConnectorName: PetCommands.quitApp, requiresGadgetOn: false),
        GadgetTool(gadget: .appswitch, action: "settings",
                   korean: "앱 전환 가젯의 설정을 봐요: 같은 단축키를 다시 누르면 숨길지, 단축키를 정해 둔 앱 이름 목록. 설정을 바꾸기 전에 확인할 때 써요.",
                   english: "Reads the App Switch settings: hide on repeat, and the names of apps that have a shortcut.",
                   output: "{ok, message, hide_on_repeat, shortcut_apps:[name]}", risk: .read),
        GadgetTool(gadget: .appswitch, action: "set_settings",
                   korean: "앱 전환 설정을 바꿔요: hide_on_repeat=true면 이미 맨 앞인 앱의 단축키를 다시 누를 때 그 앱을 숨겨요. 단축키 자체는 바꾸지 않아요.",
                   english: "Changes App Switch settings: hide_on_repeat hides the front app when its shortcut is pressed again. Shortcuts themselves are not changed.",
                   input: GadgetSchema.object(["hide_on_repeat": GadgetSchema.boolean("같은 단축키를 다시 누르면 숨기기")], required: ["hide_on_repeat"]),
                   output: "{ok, message, hide_on_repeat, shortcut_apps}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .appswitch,
        summary: "앱 전환 가젯은 앱을 열고 전환하고 숨기고 종료해요. 도구로는 앱 목록, 열기, 전환, 숨기기, 종료와 설정 읽기·바꾸기를 할 수 있어요.",
        canDo: ["실행 중인 앱 목록 보기(list)", "앱 열기·전환·숨기기(open·focus·hide)", "앱 종료(quit, 승인 필요)", "단축키 반복 시 숨김 설정 보기·바꾸기"],
        steps: ["앱 이름이 불확실하면 list를 먼저 불러요.",
                "열기는 open, 이미 실행 중인 앱으로 전환은 focus, 치우기는 hide를 불러요.",
                "설정은 settings로 읽고 set_settings로 hide_on_repeat만 바꿔요."],
        examples: [
            .init("list", note: "어떤 앱이 켜져 있는지 볼 때"),
            .init("focus", .object(["app": .string("Safari")]), note: "사파리로 전환할 때"),
            .init("settings", note: "반복 숨김이 켜져 있는지 볼 때"),
            .init("set_settings", .object(["hide_on_repeat": .bool(false)]), note: "다시 눌러도 숨기지 않게 할 때"),
        ],
        limits: ["Finder와 나초콤보는 숨기거나 종료하지 않아요. quit은 되돌릴 수 없어서 매번 승인이 필요해요.",
                 "단축키를 새로 만들거나 지우는 일은 도구로 열지 않았어요. 가젯 설정에서 해요.",
                 "settings·set_settings는 가젯이 꺼져 있으면 gadget_off예요. list·open·focus·hide·quit은 꺼져 있어도 동작해요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .appswitch, flow: "tidy_apps",
                     description: "앱 정리 — Tidy apps: list the running apps and hide the ones the user names.",
                     arguments: [],
                     template: "Read nachocombo://gadgets/appswitch/guide. Call appswitch_list, show me the running apps in one line, then hide "
                         + "only the apps I name with appswitch_hide. Never quit an app unless I clearly ask."),
    ]
}
