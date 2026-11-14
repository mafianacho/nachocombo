import Foundation

/// Disk Map (`disk`): the largest folders and files of the last scan, and starting a scan (NACHO-149).
/// There is deliberately no tool that deletes or moves anything. Runner: `DataGadgetRunner`.
public enum DiskTools: GadgetToolProvider {
    public static let gadget = GadgetID.disk
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .disk, action: "top_items",
                   korean: "디스크 지도의 마지막 스캔에서 가장 큰 폴더·파일 상위 N개(이름·경로·크기·수정 시각)와 스캔 시각을 봐요. "
                       + "\"뭐가 디스크를 차지해?\"에 써요. 읽기만 하고 지우지 않아요.",
                   english: "The largest folders and files of Disk Map's last scan (rank, name, path, kind, bytes, modified time; at most 50) and when it was scanned. Read only.",
                   input: GadgetSchema.object([
                       "count": GadgetSchema.integer("몇 개(1–50, 기본 10)", minimum: 1, maximum: DataGadgetRunner.maxDiskItems),
                       "kind": GadgetSchema.choice(DataGadgetRunner.DiskTopKind.allCases.map { $0.rawValue }, "both=폴더와 파일, folders=폴더만, files=파일만 (기본 both)"),
                   ]),
                   output: "{ok, message, scanned_at, scanned_path, items:[{rank, name, path, kind, bytes, modified_at}]}", risk: .read),
        GadgetTool(gadget: .disk, action: "scan",
                   korean: "디스크 지도 창을 열고 홈 폴더(또는 홈 안의 지정한 폴더)를 스캔하기 시작해요. 몇 분 걸릴 수 있고, 끝나면 top_items로 결과를 봐요. 아무것도 지우지 않아요.",
                   english: "Opens Disk Map and starts scanning the home folder or a folder inside it (~, ~/… or an absolute path under home). Takes minutes; read the result with disk_top_items.",
                   input: GadgetSchema.object([
                       "path": GadgetSchema.string("홈 안의 폴더: ~, ~/Downloads 또는 홈 폴더 아래의 절대 경로 (기본 ~)", maxLength: 1024),
                   ]),
                   output: "{ok, message, path, scan}", risk: .change),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .disk,
        summary: "디스크 지도 가젯이 스캔한 결과에서 공간을 많이 차지하는 폴더와 파일을 찾아요. 이 도구들은 아무것도 지우거나 옮기지 않아요.",
        canDo: ["마지막 스캔에서 큰 폴더·파일 상위 N개 보기(최대 50개)", "홈 폴더나 홈 안의 폴더를 새로 스캔하기"],
        steps: ["top_items를 먼저 불러요. 스캔이 없으면(no_scan) scan으로 시작해요.",
                "스캔 중이면(scanning) 1–2분 뒤 다시 top_items를 불러요.",
                "결과의 큰 항목을 사용자에게 알려 주고, 지울지는 사용자가 디스크 지도 창에서 직접 정하게 해요."],
        examples: [
            .init("top_items", .object(["count": .int(10)]), note: "디스크를 무엇이 차지하는지 볼 때"),
            .init("scan", .object(["path": .string("~/Downloads")]), note: "다운로드 폴더만 새로 스캔할 때"),
        ],
        limits: ["디스크 지도 가젯이 켜져 있어야 해요.",
                 "스캔은 홈 폴더 안에서만 시작해요. 홈 밖 경로는 outside_home으로 거절해요.",
                 "결과는 마지막 스캔 기준이에요(scanned_at). 창을 닫고 10분이 지나면 결과가 메모리에서 지워져요.",
                 "전체 디스크 접근 권한이 없으면 일부 폴더는 읽지 못해 작게 보일 수 있어요.",
                 "삭제 도구는 없어요. 지우기는 사용자가 디스크 지도 창에서 직접 해요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .disk, flow: "find_space",
                     description: "Find what takes the most space in the home folder (or a folder inside it) with Disk Map. Nothing is deleted.",
                     arguments: [.init("path", "Folder inside the home folder, default ~")],
                     template: "Read nachocombo://gadgets/disk/guide. Call disk_top_items; if there is no scan, call disk_scan with path \"{path}\" "
                         + "(use ~ when empty) and ask again after a minute. List the 10 largest items in Korean with their sizes. Do not delete anything."),
    ]
}
