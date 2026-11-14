import Foundation

/// System Monitor (`monitor`): the current numbers (NACHO-149). Runner: `DataGadgetRunner`.
public enum MonitorTools: GadgetToolProvider {
    public static let gadget = GadgetID.monitor
    public static let tools: [GadgetTool] = [
        GadgetTool(gadget: .monitor, action: "stats",
                   korean: "시스템 모니터의 지금 수치를 봐요: CPU·메모리(압력·스왑)·네트워크 속도·디스크 사용률·배터리·온도(있으면). "
                       + "\"맥이 느려\", \"배터리 얼마나 남았어\"처럼 지금 상태를 물을 때 써요.",
                   english: "Current System Monitor numbers: CPU %, memory % (pressure, swap), network down/up bytes per second, startup disk used %, battery, CPU/GPU temperature when the Mac reports them, busiest apps when already sampled.",
                   output: "{ok, message, cpu_percent, memory_percent, memory_pressure_percent, network_*_bytes_per_second, disk_used_percent, battery_percent, cpu_temperature_celsius, top_apps?}",
                   risk: .read),
    ]

    public static let guide: GadgetGuide? = GadgetGuide(
        gadget: .monitor,
        summary: "시스템 모니터 가젯이 2초마다 재는 맥의 지금 수치(CPU·메모리·네트워크·디스크·배터리·온도)를 읽어요.",
        canDo: ["CPU 사용률과 부하 평균 보기", "메모리 사용률·메모리 압력·스왑 보기", "네트워크 내려받기·올리기 속도 보기",
                "시동 디스크 사용률 보기", "배터리 잔량·충전 여부·전원 연결 보기", "CPU·GPU 온도 보기(맥이 알려 줄 때만)"],
        steps: ["stats를 한 번 불러 지금 수치를 봐요.",
                "숫자가 높으면(CPU 80% 이상, 메모리 압력 높음, 스왑 큼) 사용자에게 무엇이 부담인지 쉬운 말로 설명해요.",
                "디스크가 거의 찼으면 디스크 지도(disk_top_items)로 큰 항목을 함께 봐요."],
        examples: [
            .init("stats", note: "\"맥이 왜 이렇게 느려?\"에 답하기 전에 지금 수치를 볼 때"),
        ],
        limits: ["시스템 모니터 가젯이 켜져 있어야 해요. 꺼져 있으면 gadget_off를 돌려줘요.",
                 "켠 직후 몇 초는 수치가 없을 수 있어요(no_reading). 잠시 뒤 다시 불러요.",
                 "온도·배터리는 맥이 알려 주는 경우에만 있어요(없으면 null).",
                 "앱별 사용량(top_apps)은 모니터의 CPU·메모리 창이 열려 있을 때만 들어 있어요."])

    public static let prompts: [GadgetPrompt] = [
        GadgetPrompt(gadget: .monitor, flow: "why_slow",
                     description: "Find out why the Mac feels slow: current System Monitor numbers, then the largest items of Disk Map.",
                     template: "Read nachocombo://gadgets/monitor/guide and nachocombo://gadgets/disk/guide. Call monitor_stats and look at CPU, "
                         + "memory pressure, swap and disk use. If the disk is nearly full, call disk_top_items (start disk_scan first if there is "
                         + "no scan). Explain in Korean, in plain words, what slows the Mac down and what I could do. Do not delete anything."),
    ]
}
