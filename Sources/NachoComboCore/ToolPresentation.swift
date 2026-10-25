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
        case .menuBar: return "Folds away the icons left of the divider; they come back on a click, on hover or from a shortcut."
        case .systemMonitor: return "Shows CPU, memory, disk, network, sensors and battery in the menu bar."
        case .windowSnap: return "Snaps windows to halves, quarters and thirds from the keyboard or by dragging to an edge."
        case .fileShelf: return "Holds files, images, links and text for a moment so you can drag them out again."
        case .captureFloat: return "Captures an area, a window or the screen and floats it above other windows."
        case .focusDim: return "Keeps the active window bright and dims the rest."
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
            return ToolStatusPresentation(dot: .off, stateText: "Off", detail: nil, accessibilityText: "Off")
        }
        switch state {
        case .running:
            return ToolStatusPresentation(dot: .on, stateText: "Running", detail: nil,
                                          accessibilityText: "On, running")
        case .needsPermission(let message):
            return ToolStatusPresentation(dot: .onNeedsSetup, stateText: "Needs Permission", detail: message,
                                          accessibilityText: "On, needs permission, more setup required")
        case .failed(let message):
            return ToolStatusPresentation(dot: .onError, stateText: "Error", detail: message,
                                          accessibilityText: "On, error: \(message)")
        case .off:
            return ToolStatusPresentation(dot: .onNeedsSetup, stateText: "Not Started", detail: nil,
                                          accessibilityText: "On, not started yet")
        }
    }
}

public extension ToolStatusPresentation {
    /// "3 on · 1 needs permission · 1 error": only tools that really run count as on; a tool that is switched on but
    /// still waits for a permission (or failed) is named separately instead of being counted as on.
    static func summary(of dots: [StatusDotKind]) -> String {
        let running = dots.filter { $0 == .on }.count
        let setup = dots.filter { $0 == .onNeedsSetup }.count
        let failed = dots.filter { $0 == .onError }.count
        var text = "\(running) on"
        if setup > 0 { text += " · \(setup) " + (setup == 1 ? "needs" : "need") + " permission" }
        if failed > 0 { text += " · \(failed) error" + (failed == 1 ? "" : "s") }
        return text
    }
}
