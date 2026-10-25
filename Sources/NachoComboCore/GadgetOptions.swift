import Foundation

/// When the file shelf appears by itself during a drag.
public enum ShelfTrigger: String, Codable, CaseIterable {
    /// Shake the pointer left and right while dragging something.
    case shake
    /// As soon as any drag starts.
    case anyDrag
    /// Never by itself: only the shortcut, the menu bar or the settings window open it.
    case shortcutOnly

    public var displayName: String {
        switch self {
        case .shake: return "Shake While Dragging"
        case .anyDrag: return "Any Drag"
        case .shortcutOnly: return "Shortcut Only"
        }
    }
}

/// Which windows Focus Dim keeps bright.
public enum DimScope: String, Codable, CaseIterable {
    case frontWindow
    case frontApp

    public var displayName: String {
        switch self {
        case .frontWindow: return "Front Window"
        case .frontApp: return "All Windows of the App"
        }
    }
}

/// What repeating a left / right half command does.
public enum SnapRepeat: String, Codable, CaseIterable {
    /// 1/2 → 2/3 → 1/3 of the screen.
    case cycleSizes
    /// Moves on to the neighbouring display.
    case nextDisplay
    /// Leaves the window where it is.
    case nothing

    public var displayName: String {
        switch self {
        case .cycleSizes: return "Cycle ½ → ⅔ → ⅓"
        case .nextDisplay: return "Move to Next Display"
        case .nothing: return "Do Nothing"
        }
    }
}

/// Per-gadget behaviour choices from the gallery's detail pane. Every field falls back to its default on its own, so
/// a settings file from an older version (or with one broken value) keeps everything else.
public struct GadgetOptions: Codable, Equatable {
    // Menu Bar Organizer
    /// Collapse again this many seconds after expanding (0 = stay expanded). Waits while the pointer is in the menu bar.
    public var autoCollapseSeconds: Int
    /// Resting the pointer on the ‹ item expands the hidden icons.
    public var expandOnHover: Bool
    /// A second divider: icons left of it stay hidden even when expanded (⌥-click ‹ shows them).
    public var alwaysHiddenSection: Bool

    // Window Snap
    /// Space around snapped windows, in points.
    public var snapGap: Int
    public var snapRepeat: SnapRepeat
    /// Dragging a window to a screen edge or corner snaps it there.
    public var snapDragToEdges: Bool
    /// Dragging a snapped window away gives it back the size it had before snapping.
    public var snapRestoreOnDrag: Bool
    /// ⌃⌘-drag anywhere in a window moves it; ⌃⌘-right-drag resizes it from the nearest corner.
    public var windowMotion: Bool

    // System Monitor
    /// Alert when CPU usage stays at or above this percentage (0 = no CPU alert).
    public var cpuAlertPercent: Int
    /// Post a notification when an alert starts (the gallery badge counts alerts either way).
    public var alertNotifications: Bool

    // File Shelf
    public var shelfTrigger: ShelfTrigger

    // Capture Float
    /// Rounded corners and a shadow on floating captures.
    public var captureRoundedCorners: Bool

    // Focus Dim
    public var dimScope: DimScope
    /// Displays without the active window are dimmed too.
    public var dimOtherDisplays: Bool
    /// Fade when the active window changes, in seconds (0 = instant; always instant while Reduce Motion is on).
    public var dimFadeSeconds: Double

    public static let autoCollapseChoices = [0, 5, 10, 15, 30, 60]
    public static let gapChoices = [0, 4, 8, 12, 16, 24]
    public static let fadeChoices: [Double] = [0, 0.25, 0.5, 1]
    public static let cpuAlertChoices = [0, 70, 80, 90, 95]

    public static let defaults = GadgetOptions()

    public init(autoCollapseSeconds: Int = 10, expandOnHover: Bool = false, alwaysHiddenSection: Bool = false,
                snapGap: Int = 0, snapRepeat: SnapRepeat = .cycleSizes, snapDragToEdges: Bool = true,
                snapRestoreOnDrag: Bool = true, windowMotion: Bool = true, cpuAlertPercent: Int = 90,
                alertNotifications: Bool = false, shelfTrigger: ShelfTrigger = .shake,
                captureRoundedCorners: Bool = true, dimScope: DimScope = .frontWindow, dimOtherDisplays: Bool = true,
                dimFadeSeconds: Double = 0.25) {
        self.autoCollapseSeconds = autoCollapseSeconds
        self.expandOnHover = expandOnHover
        self.alwaysHiddenSection = alwaysHiddenSection
        self.snapGap = snapGap
        self.snapRepeat = snapRepeat
        self.snapDragToEdges = snapDragToEdges
        self.snapRestoreOnDrag = snapRestoreOnDrag
        self.windowMotion = windowMotion
        self.cpuAlertPercent = cpuAlertPercent
        self.alertNotifications = alertNotifications
        self.shelfTrigger = shelfTrigger
        self.captureRoundedCorners = captureRoundedCorners
        self.dimScope = dimScope
        self.dimOtherDisplays = dimOtherDisplays
        self.dimFadeSeconds = dimFadeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case autoCollapseSeconds, expandOnHover, alwaysHiddenSection, snapGap, snapRepeat, snapDragToEdges,
             snapRestoreOnDrag, windowMotion, cpuAlertPercent, alertNotifications, shelfTrigger, captureRoundedCorners, dimScope, dimOtherDisplays, dimFadeSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GadgetOptions.defaults
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        autoCollapseSeconds = max(0, min(3600, value(.autoCollapseSeconds, d.autoCollapseSeconds)))
        expandOnHover = value(.expandOnHover, d.expandOnHover)
        alwaysHiddenSection = value(.alwaysHiddenSection, d.alwaysHiddenSection)
        snapGap = max(0, min(64, value(.snapGap, d.snapGap)))
        snapRepeat = value(.snapRepeat, d.snapRepeat)
        snapDragToEdges = value(.snapDragToEdges, d.snapDragToEdges)
        snapRestoreOnDrag = value(.snapRestoreOnDrag, d.snapRestoreOnDrag)
        windowMotion = value(.windowMotion, d.windowMotion)
        cpuAlertPercent = max(0, min(100, value(.cpuAlertPercent, d.cpuAlertPercent)))
        alertNotifications = value(.alertNotifications, d.alertNotifications)
        shelfTrigger = value(.shelfTrigger, d.shelfTrigger)
        captureRoundedCorners = value(.captureRoundedCorners, d.captureRoundedCorners)
        dimScope = value(.dimScope, d.dimScope)
        dimOtherDisplays = value(.dimOtherDisplays, d.dimOtherDisplays)
        let fade = value(.dimFadeSeconds, d.dimFadeSeconds)
        dimFadeSeconds = fade.isFinite ? max(0, min(5, fade)) : d.dimFadeSeconds
    }
}
