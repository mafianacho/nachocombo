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
    ]

    public static let guide: GadgetGuide? = nil
    public static let prompts: [GadgetPrompt] = []
}
