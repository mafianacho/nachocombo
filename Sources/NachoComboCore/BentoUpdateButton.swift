import Foundation

/// The updater's state as the widget window needs it (the app maps `UpdateController.State` onto this).
public enum BentoUpdateState: Equatable {
    case idle, checking, upToDate
    case available(version: String)
    case downloading
    case ready(version: String)
    case installing
    case failed
}

/// What the yellow update pill of the widget window shows.
public struct BentoUpdateButtonModel: Equatable {
    public let visible: Bool
    public let title: String
    public let enabled: Bool

    public init(visible: Bool, title: String, enabled: Bool) {
        self.visible = visible
        self.title = title
        self.enabled = enabled
    }
}

/// Where the update confirmation sheet hangs.
public enum UpdateConfirmParent: Equatable { case widget, settings, none }

public enum BentoUpdateLogic {
    /// State → (visible, text, active). Hidden while editing (only "완료" shows there).
    public static func button(for state: BentoUpdateState, editing: Bool) -> BentoUpdateButtonModel {
        let hidden = BentoUpdateButtonModel(visible: false, title: "", enabled: false)
        if editing { return hidden }
        switch state {
        case let .available(version): return BentoUpdateButtonModel(visible: true, title: "업데이트 \(version)", enabled: true)
        case .ready: return BentoUpdateButtonModel(visible: true, title: "재시작해 업데이트", enabled: true)
        case .downloading, .installing: return BentoUpdateButtonModel(visible: true, title: "업데이트 중…", enabled: false)
        case .idle, .checking, .upToDate, .failed: return hidden
        }
    }

    /// The confirmation sheet's parent: the widget window when the click came from it and it is on screen, else the
    /// settings window when that is open (the old behaviour), else none.
    public static func confirmParent(fromWidget: Bool, widgetVisible: Bool, settingsVisible: Bool) -> UpdateConfirmParent {
        if fromWidget && widgetVisible { return .widget }
        return settingsVisible ? .settings : .none
    }
}
