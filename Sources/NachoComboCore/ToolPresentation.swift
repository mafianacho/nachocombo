import Foundation

public extension ModuleID {
    /// SF Symbols name (available since macOS 11; the UI falls back to the first letter when missing).
    var symbolName: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .systemMonitor: return "waveform.path.ecg"
        case .windowSnap: return "rectangle.split.2x1"
        case .fileShelf: return "tray"
        case .captureFloat: return "viewfinder"
        case .focusDim: return "circle.lefthalf.filled"
        }
    }

    var toolSummary: String {
        switch self {
        case .menuBar: return "구분선 왼쪽 아이콘을 접거나 펼칩니다."
        case .systemMonitor: return "CPU·메모리·네트워크를 메뉴 막대에 표시합니다."
        case .windowSnap: return "활성 창을 왼쪽·오른쪽 절반 또는 최대화로 배치합니다."
        case .fileShelf: return "파일·이미지·텍스트를 잠시 모아 두고 다시 끌어냅니다."
        case .captureFloat: return "화면 영역을 캡처해 다른 창 위에 고정합니다."
        case .focusDim: return "활성 창만 밝게 두고 나머지를 어둡게 합니다."
        }
    }
}

public enum StatusDotKind: String, Equatable {
    /// Gray: the user has not turned the tool on.
    case off
    /// Green: the user turned it on and it is running.
    case on
    /// Green with a yellow circle half behind it: switched on, but a permission or extra setup is missing.
    case onNeedsSetup
    /// Green with a red circle half behind it: switched on, but starting failed.
    case onError
}

/// What the UI shows for one tool. The dot is only a summary; `stateText` and `detail` always carry the real state,
/// and `accessibilityText` makes sure the state is never conveyed by color alone.
public struct ToolStatusPresentation: Equatable {
    public let dot: StatusDotKind
    public let stateText: String
    public let detail: String?
    public let accessibilityText: String

    public static func make(enabled: Bool, state: ModuleState) -> ToolStatusPresentation {
        guard enabled else {
            // OFF never keeps a setup badge: nothing is requested while the tool is off.
            return ToolStatusPresentation(dot: .off, stateText: "꺼짐", detail: nil, accessibilityText: "꺼짐")
        }
        switch state {
        case .running:
            return ToolStatusPresentation(dot: .on, stateText: "동작 중", detail: nil,
                                          accessibilityText: "켜짐, 동작 중")
        case .needsPermission(let message):
            return ToolStatusPresentation(dot: .onNeedsSetup, stateText: "권한 필요", detail: message,
                                          accessibilityText: "켜짐, 권한 필요, 추가 설정이 필요합니다")
        case .failed(let message):
            return ToolStatusPresentation(dot: .onError, stateText: "오류", detail: message,
                                          accessibilityText: "켜짐, 오류: \(message)")
        case .off:
            return ToolStatusPresentation(dot: .onNeedsSetup, stateText: "시작 대기", detail: nil,
                                          accessibilityText: "켜짐, 아직 시작되지 않음")
        }
    }
}

public extension ToolStatusPresentation {
    /// "3개 켜짐 · 1개 권한 필요 · 1개 오류": only tools that really run count as on; a tool that is switched on but
    /// still waits for a permission (or failed) is named separately instead of being counted as on.
    static func summary(of dots: [StatusDotKind]) -> String {
        let running = dots.filter { $0 == .on }.count
        let setup = dots.filter { $0 == .onNeedsSetup }.count
        let failed = dots.filter { $0 == .onError }.count
        var text = "\(running)개 켜짐"
        if setup > 0 { text += " · \(setup)개 권한 필요" }
        if failed > 0 { text += " · \(failed)개 오류" }
        return text
    }
}
