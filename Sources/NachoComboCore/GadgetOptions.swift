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

/// What a mouse's middle button does.
public enum MiddleButton: String, Codable, CaseIterable {
    case click, missionControl

    public var displayName: String {
        switch self {
        case .click: return "Middle Click"
        case .missionControl: return "Mission Control"
        }
    }
}

/// How the menu bar clock writes hours.
public enum ClockHours: String, Codable, CaseIterable {
    case system, twelve, twentyFour

    public var displayName: String {
        switch self {
        case .system: return "Like macOS"
        case .twelve: return "12-Hour"
        case .twentyFour: return "24-Hour"
        }
    }
}

/// A shortcut that opens (or brings forward, or hides) one app.
public struct AppHotKey: Codable, Equatable {
    public var bundleID: String
    public var name: String
    public var shortcut: ToolShortcut?

    public init(bundleID: String, name: String, shortcut: ToolShortcut?) {
        self.bundleID = bundleID
        self.name = name
        self.shortcut = shortcut
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
    /// Focus session length and the break after it, in minutes.
    public var focusMinutes: Int
    public var breakMinutes: Int
    /// Dim only while a focus session runs.
    public var dimOnlyInSession: Bool
    /// Names of Shortcuts to run when a focus session starts and ends ("" = none).
    public var sessionStartShortcut: String
    public var sessionEndShortcut: String

    // Window Snap layouts
    /// Put a saved layout back by itself when the same displays are connected again.
    public var autoApplyLayouts: Bool

    // Capture Float recording
    /// Also make a GIF of a recording (up to 15 s, 10 frames a second).
    public var recordGIF: Bool

    // Keep Awake
    /// Keep the display on too (otherwise only the Mac stays awake).
    public var keepAwakeDisplay: Bool
    /// How long a click keeps the Mac awake, in minutes (0 = until turned off).
    public var keepAwakeMinutes: Int
    /// Stay awake only while on the power adapter.
    public var keepAwakePowerOnly: Bool
    /// Let the Mac sleep again below this battery percentage (0 = never).
    public var keepAwakeBatteryFloor: Int
    /// Stay awake while any of these apps (bundle identifiers) runs.
    public var keepAwakeApps: [String]

    // Clipboard History
    public var clipboardLimit: Int
    /// Paste into the app you were in (needs Accessibility); otherwise only copy.
    public var clipboardPasteDirectly: Bool
    public var clipboardImages: Bool

    // Device Control
    /// Core Audio device UIDs to switch to when they appear ("" = none).
    public var preferredOutput: String
    public var preferredInput: String
    /// A red microphone in the menu bar while muted.
    public var micIndicator: Bool

    // App Switch
    public var appShortcuts: [AppHotKey]
    /// Pressing an app's shortcut while it is in front hides it.
    public var appHideOnRepeat: Bool

    // Mouse Tune
    public var mouseReverse: Bool
    public var mouseSmooth: Bool
    /// Scroll distance per wheel notch (1 = as macOS).
    public var mouseSpeed: Double
    public var mouseSideButtons: Bool
    public var mouseMiddle: MiddleButton

    // Calendar Clock
    public var clockDate: Bool
    public var clockWeekday: Bool
    public var clockSeconds: Bool
    public var clockHours: ClockHours
    public var clockNextEvent: Bool
    /// Time zone identifiers of the world clocks.
    public var worldClocks: [String]

    public static let autoCollapseChoices = [0, 5, 10, 15, 30, 60]
    public static let gapChoices = [0, 4, 8, 12, 16, 24]
    public static let fadeChoices: [Double] = [0, 0.25, 0.5, 1]
    public static let cpuAlertChoices = [0, 70, 80, 90, 95]
    public static let focusChoices = [15, 25, 45, 60, 90]
    public static let breakChoices = [0, 5, 10, 15]
    public static let keepAwakeChoices = [0, 15, 30, 60, 120, 300]
    public static let batteryFloorChoices = [0, 10, 20, 30, 50]
    public static let clipboardLimitChoices = [25, 50, 100, 200, 500]
    public static let mouseSpeedChoices: [Double] = [0.5, 1, 1.5, 2, 3]

    public static let defaults = GadgetOptions()

    public init(autoCollapseSeconds: Int = 10, expandOnHover: Bool = false, alwaysHiddenSection: Bool = false,
                snapGap: Int = 0, snapRepeat: SnapRepeat = .cycleSizes, snapDragToEdges: Bool = true,
                snapRestoreOnDrag: Bool = true, windowMotion: Bool = true, cpuAlertPercent: Int = 90,
                alertNotifications: Bool = false, shelfTrigger: ShelfTrigger = .shake,
                captureRoundedCorners: Bool = true, dimScope: DimScope = .frontWindow, dimOtherDisplays: Bool = true,
                dimFadeSeconds: Double = 0.25, focusMinutes: Int = 25, breakMinutes: Int = 5, dimOnlyInSession: Bool = false,
                sessionStartShortcut: String = "", sessionEndShortcut: String = "", autoApplyLayouts: Bool = true,
                recordGIF: Bool = false, keepAwakeDisplay: Bool = true, keepAwakeMinutes: Int = 0,
                keepAwakePowerOnly: Bool = false, keepAwakeBatteryFloor: Int = 20, keepAwakeApps: [String] = [],
                clipboardLimit: Int = 100, clipboardPasteDirectly: Bool = true, clipboardImages: Bool = true,
                preferredOutput: String = "", preferredInput: String = "", micIndicator: Bool = true,
                appShortcuts: [AppHotKey] = [], appHideOnRepeat: Bool = true, mouseReverse: Bool = true,
                mouseSmooth: Bool = true, mouseSpeed: Double = 1, mouseSideButtons: Bool = true,
                mouseMiddle: MiddleButton = .click, clockDate: Bool = true, clockWeekday: Bool = true,
                clockSeconds: Bool = false, clockHours: ClockHours = .system, clockNextEvent: Bool = true,
                worldClocks: [String] = []) {
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
        self.focusMinutes = focusMinutes
        self.breakMinutes = breakMinutes
        self.dimOnlyInSession = dimOnlyInSession
        self.sessionStartShortcut = sessionStartShortcut
        self.sessionEndShortcut = sessionEndShortcut
        self.autoApplyLayouts = autoApplyLayouts
        self.recordGIF = recordGIF
        self.keepAwakeDisplay = keepAwakeDisplay
        self.keepAwakeMinutes = keepAwakeMinutes
        self.keepAwakePowerOnly = keepAwakePowerOnly
        self.keepAwakeBatteryFloor = keepAwakeBatteryFloor
        self.keepAwakeApps = keepAwakeApps
        self.clipboardLimit = clipboardLimit
        self.clipboardPasteDirectly = clipboardPasteDirectly
        self.clipboardImages = clipboardImages
        self.preferredOutput = preferredOutput
        self.preferredInput = preferredInput
        self.micIndicator = micIndicator
        self.appShortcuts = appShortcuts
        self.appHideOnRepeat = appHideOnRepeat
        self.mouseReverse = mouseReverse
        self.mouseSmooth = mouseSmooth
        self.mouseSpeed = mouseSpeed
        self.mouseSideButtons = mouseSideButtons
        self.mouseMiddle = mouseMiddle
        self.clockDate = clockDate
        self.clockWeekday = clockWeekday
        self.clockSeconds = clockSeconds
        self.clockHours = clockHours
        self.clockNextEvent = clockNextEvent
        self.worldClocks = worldClocks
    }

    private enum CodingKeys: String, CodingKey {
        case autoCollapseSeconds, expandOnHover, alwaysHiddenSection, snapGap, snapRepeat, snapDragToEdges,
             snapRestoreOnDrag, windowMotion, cpuAlertPercent, alertNotifications, shelfTrigger, captureRoundedCorners, dimScope, dimOtherDisplays, dimFadeSeconds,
             focusMinutes, breakMinutes, dimOnlyInSession, sessionStartShortcut, sessionEndShortcut, autoApplyLayouts, recordGIF,
             keepAwakeDisplay, keepAwakeMinutes, keepAwakePowerOnly, keepAwakeBatteryFloor, keepAwakeApps, clipboardLimit,
             clipboardPasteDirectly, clipboardImages, preferredOutput, preferredInput, micIndicator, appShortcuts,
             appHideOnRepeat, mouseReverse, mouseSmooth, mouseSpeed, mouseSideButtons, mouseMiddle, clockDate, clockWeekday,
             clockSeconds, clockHours, clockNextEvent, worldClocks
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
        focusMinutes = max(1, min(240, value(.focusMinutes, d.focusMinutes)))
        breakMinutes = max(0, min(120, value(.breakMinutes, d.breakMinutes)))
        dimOnlyInSession = value(.dimOnlyInSession, d.dimOnlyInSession)
        sessionStartShortcut = value(.sessionStartShortcut, d.sessionStartShortcut)
        sessionEndShortcut = value(.sessionEndShortcut, d.sessionEndShortcut)
        autoApplyLayouts = value(.autoApplyLayouts, d.autoApplyLayouts)
        recordGIF = value(.recordGIF, d.recordGIF)
        keepAwakeDisplay = value(.keepAwakeDisplay, d.keepAwakeDisplay)
        keepAwakeMinutes = max(0, min(24 * 60, value(.keepAwakeMinutes, d.keepAwakeMinutes)))
        keepAwakePowerOnly = value(.keepAwakePowerOnly, d.keepAwakePowerOnly)
        keepAwakeBatteryFloor = max(0, min(90, value(.keepAwakeBatteryFloor, d.keepAwakeBatteryFloor)))
        keepAwakeApps = value(.keepAwakeApps, d.keepAwakeApps)
        clipboardLimit = max(10, min(1000, value(.clipboardLimit, d.clipboardLimit)))
        clipboardPasteDirectly = value(.clipboardPasteDirectly, d.clipboardPasteDirectly)
        clipboardImages = value(.clipboardImages, d.clipboardImages)
        preferredOutput = value(.preferredOutput, d.preferredOutput)
        preferredInput = value(.preferredInput, d.preferredInput)
        micIndicator = value(.micIndicator, d.micIndicator)
        appShortcuts = value(.appShortcuts, d.appShortcuts)
        appHideOnRepeat = value(.appHideOnRepeat, d.appHideOnRepeat)
        mouseReverse = value(.mouseReverse, d.mouseReverse)
        mouseSmooth = value(.mouseSmooth, d.mouseSmooth)
        let speed = value(.mouseSpeed, d.mouseSpeed)
        mouseSpeed = speed.isFinite ? max(0.25, min(5, speed)) : d.mouseSpeed
        mouseSideButtons = value(.mouseSideButtons, d.mouseSideButtons)
        mouseMiddle = value(.mouseMiddle, d.mouseMiddle)
        clockDate = value(.clockDate, d.clockDate)
        clockWeekday = value(.clockWeekday, d.clockWeekday)
        clockSeconds = value(.clockSeconds, d.clockSeconds)
        clockHours = value(.clockHours, d.clockHours)
        clockNextEvent = value(.clockNextEvent, d.clockNextEvent)
        worldClocks = value(.worldClocks, d.worldClocks)
    }
}
