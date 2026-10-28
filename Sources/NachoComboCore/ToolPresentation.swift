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
    /// Orange: switched on, but a permission or extra setup is missing (nothing runs yet).
    case onNeedsSetup
    /// Red: switched on, but starting failed.
    case onError
}

/// What the UI shows for one tool. The dot is only a summary; `stateText` and `detail` always carry the real state,
/// and `accessibilityText` makes sure the state is never conveyed by color alone.
public struct ToolStatusPresentation: Equatable {
    public let dot: StatusDotKind
    public let stateText: String
    public let detail: String?
    public let accessibilityText: String
    /// The permission a switched-on tool still waits for ("Accessibility"), so every screen can name it.
    public let waitingFor: String?

    public init(dot: StatusDotKind, stateText: String, detail: String?, accessibilityText: String,
                waitingFor: String? = nil) {
        self.dot = dot
        self.stateText = stateText
        self.detail = detail
        self.accessibilityText = accessibilityText
        self.waitingFor = waitingFor
    }

    /// `permission` names what a tool waiting for a permission needs ("Accessibility"); without it the state says
    /// "Needs Permission".
    public static func make(enabled: Bool, state: ModuleState, permission: String? = nil) -> ToolStatusPresentation {
        guard enabled else {
            // OFF never keeps a setup badge: nothing is requested while the tool is off.
            return ToolStatusPresentation(dot: .off, stateText: "Off", detail: nil, accessibilityText: "Off")
        }
        switch state {
        case .running:
            return ToolStatusPresentation(dot: .on, stateText: "Running", detail: nil,
                                          accessibilityText: "On, running")
        case .needsPermission(let message):
            let name = permission ?? "Permission"
            return ToolStatusPresentation(dot: .onNeedsSetup, stateText: "Needs \(name)", detail: message,
                                          accessibilityText: "On, needs \(name), more setup required",
                                          waitingFor: permission)
        case .failed(let message):
            return ToolStatusPresentation(dot: .onError, stateText: "Error", detail: message,
                                          accessibilityText: "On, error: \(message)")
        case .off:
            return ToolStatusPresentation(dot: .onNeedsSetup, stateText: "Starting…", detail: nil,
                                          accessibilityText: "On, starting")
        }
    }
}

public extension ToolStatusPresentation {
    /// "3 running · 1 needs Accessibility · 1 error": only tools that really run count as running (the switches that are
    /// on can be more); a tool that waits for a permission is named with that permission, failures are counted apart.
    static func summary(of statuses: [ToolStatusPresentation]) -> String {
        var parts = [runningText(of: statuses)]
        if let waiting = waitingText(of: statuses) { parts.append(waiting) }
        if let errors = errorText(of: statuses) { parts.append(errors) }
        return parts.joined(separator: " · ")
    }

    static func runningText(of statuses: [ToolStatusPresentation]) -> String {
        "\(statuses.filter { $0.dot == .on }.count) running"
    }

    /// "1 needs Accessibility", "2 need Screen Recording", "2 need permissions", "1 starting"; nil when nothing waits.
    static func waitingText(of statuses: [ToolStatusPresentation]) -> String? {
        let waiting = statuses.filter { $0.dot == .onNeedsSetup }
        guard !waiting.isEmpty else { return nil }
        let verb = waiting.count == 1 ? "needs" : "need"
        let names = Set(waiting.compactMap { $0.waitingFor })
        if names.isEmpty { return "\(waiting.count) starting" }
        if names.count == 1, waiting.allSatisfy({ $0.waitingFor != nil }), let name = names.first {
            return "\(waiting.count) \(verb) \(name)"
        }
        return "\(waiting.count) need permissions"
    }

    static func errorText(of statuses: [ToolStatusPresentation]) -> String? {
        let failed = statuses.filter { $0.dot == .onError }.count
        return failed == 0 ? nil : "\(failed) error" + (failed == 1 ? "" : "s")
    }
}
