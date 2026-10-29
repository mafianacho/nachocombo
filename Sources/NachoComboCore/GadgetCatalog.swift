import Foundation

/// macOS privacy permissions a gadget can need.
public enum GadgetPermission: String, CaseIterable {
    case accessibility, screenRecording, notifications, calendars

    public var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        case .calendars: return "Calendars"
        }
    }

    public var symbolName: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .notifications: return "bell.badge"
        case .calendars: return "calendar"
        }
    }

    /// The macOS major version the wording below follows.
    public static var currentMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    /// The app that holds the switches: System Preferences up to macOS 12, System Settings from macOS 13.
    public static func settingsAppName(major: Int = currentMajor) -> String {
        major <= 12 ? "System Preferences" : "System Settings"
    }

    /// The list the switch is in, as macOS names it on that version.
    public func paneName(major: Int = GadgetPermission.currentMajor) -> String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return major >= 15 ? "Screen & System Audio Recording" : "Screen Recording"
        case .notifications: return "Notifications"
        case .calendars: return "Calendars"
        }
    }

    /// The way from the settings app to the switch ("Privacy & Security ▸ Accessibility").
    public func path(major: Int = GadgetPermission.currentMajor) -> String {
        switch self {
        case .accessibility, .screenRecording, .calendars:
            return (major <= 12 ? "Security & Privacy ▸ Privacy ▸ " : "Privacy & Security ▸ ") + paneName(major: major)
        case .notifications:
            return (major <= 12 ? "Notifications & Focus" : "Notifications") + " ▸ Nacho Combo"
        }
    }

    /// Where the switch lives on the running macOS, one path only.
    public func location(major: Int = GadgetPermission.currentMajor) -> String {
        GadgetPermission.settingsAppName(major: major) + " ▸ " + path(major: major)
    }

    public var location: String { location() }

    /// The service name `tccutil reset` takes; nil when the permission is not kept in the privacy database.
    public var tccService: String? {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "ScreenCapture"
        case .calendars: return "Calendar"
        case .notifications: return nil
        }
    }
}

public struct GadgetFeature: Equatable {
    public let symbol: String
    public let title: String
    public let detail: String
}

/// A key or gesture that works inside the gadget (not a global shortcut): "[⌘][C] Copy", "[⌃][⌘] Drag Move".
public struct GadgetTip: Equatable {
    /// Keys drawn as key caps (may be empty for a pure gesture).
    public let keys: String
    /// Mouse part of the gesture, after the keys ("Drag", "Click ‹").
    public let gesture: String
    public let title: String
}

public struct GadgetPermissionNeed: Equatable {
    public let permission: GadgetPermission
    /// Why the gadget asks for it, in the user's terms.
    public let reason: String
    /// Optional permissions only matter for one feature the user turns on.
    public let optional: Bool
    /// What the gadget does with it, finishing "Window Snap …" ("moves and resizes other apps' windows").
    public let purpose: String
}

/// What the gallery's detail pane says about a gadget: one line, its features, the permissions it needs and why,
/// and the honest limits of what macOS allows.
public struct GadgetInfo: Equatable {
    public let id: ModuleID
    public let tagline: String
    public let features: [GadgetFeature]
    public let tips: [GadgetTip]
    public let permissions: [GadgetPermissionNeed]
    /// Shown when `permissions` is empty or only optional: why nothing more is needed.
    public let permissionNote: String
    public let limits: [String]

    /// The permission the gadget cannot run without (optional ones only matter for one feature).
    public var requiredPermission: GadgetPermission? { permissions.first { !$0.optional }?.permission }
}

public extension ModuleID {
    var info: GadgetInfo { GadgetCatalog.info(for: self) }
}

public enum GadgetCatalog {
    public static func info(for id: ModuleID) -> GadgetInfo {
        switch id {
        case .menuBar: return menuBar
        case .systemMonitor: return monitor
        case .windowSnap: return snap
        case .fileShelf: return shelf
        case .captureFloat: return capture
        case .focusDim: return dim
        case .keepAwake: return keepAwake
        case .clipboard: return clipboard
        case .deviceControl: return deviceControl
        case .appSwitch: return appSwitch
        case .mouseTune: return mouseTune
        case .calendarClock: return calendarClock
        }
    }

    static func f(_ symbol: String, _ title: String, _ detail: String) -> GadgetFeature {
        GadgetFeature(symbol: symbol, title: title, detail: detail)
    }

    static func t(_ keys: String, _ gesture: String = "", _ title: String) -> GadgetTip {
        GadgetTip(keys: keys, gesture: gesture, title: title)
    }

    static let menuBar = GadgetInfo(
        id: .menuBar,
        tagline: "Keeps the menu bar tidy: icons you rarely need fold away behind a divider.",
        features: [
            f("chevron.left.2", "Fold Away Icons", "Icons left of the divider ┊ collapse behind ‹ and come back with one click."),
            f("hand.draw", "You Choose What Hides", "⌘-drag any icon across ┊. macOS remembers the order."),
            f("timer", "Auto-Collapse", "Folds the icons away again after 5–60 seconds, but waits while the pointer is in the menu bar."),
            f("cursorarrow.motionlines", "Expand on Hover", "Rest the pointer on ‹ to show the hidden icons without clicking."),
            f("eye.slash", "Always-Hidden Section", "A second divider keeps rarely used icons out of sight even when expanded. ⌥-click ‹ to see them."),
            f("keyboard", "Shortcuts", "Optional keys to expand or collapse and to show the always-hidden icons."),
        ],
        tips: [t("", "Click ‹", "Expand or collapse"), t("⌥", "Click ‹", "Show the always-hidden icons too"),
               t("⌘", "Drag an icon", "Move it across ┊ to hide or show it")],
        permissions: [],
        permissionNote: "No permission needed. The gadget only owns its own two or three menu bar items: a divider that grows to push the icons on its left out of view. It never reads, records or moves other apps' icons.",
        limits: [
            "macOS has no public way to list or rearrange other apps' icons, so you arrange them yourself with ⌘-drag.",
            "On a Mac with a camera notch, icons that end up under the notch cannot be shown.",
            "If macOS refuses to let the divider grow (a future macOS may), the gadget says so and stays expanded.",
        ])

    static let monitor = GadgetInfo(
        id: .systemMonitor,
        tagline: "Live CPU, memory, disk, network, sensor and battery readings in the menu bar, with detail panels.",
        features: [
            f("menubar.rectangle", "Menu Bar Items", "Pick any of CPU, memory, disk, network, sensors and battery. Each shows a compact live graph or value, updated every 2 seconds."),
            f("chart.xyaxis.line", "Detail Panels", "Click an item for history charts, per-core load, top processes, volumes, interfaces, temperatures and fans."),
            f("rectangle.on.rectangle", "Hover Flyouts", "Rest on a panel card for a larger chart with 10 minutes to 24 hours of history."),
            f("battery.75", "Battery", "Charge, time remaining, cycle count, health, temperature and adapter power."),
            f("exclamationmark.triangle", "Alerts", "The badge counts sustained high CPU, memory pressure, a nearly full disk, hot sensors and a low battery. Notifications are optional."),
            f("network", "Public IP on Request", "Looked up only when you press Look Up or turn on automatic lookup."),
        ],
        tips: [t("", "Click an item", "Open its panel"), t("", "Rest on a card", "Open a larger chart beside the panel"),
               t("⎋", "", "Close the panel")],
        permissions: [
            GadgetPermissionNeed(permission: .notifications, reason: "Only to post alert notifications, if you turn them on.", optional: true,
                                 purpose: "posts alert notifications"),
        ],
        permissionNote: "Readings come from public system statistics; temperatures and fans are read from the SMC without root or a helper.",
        limits: [
            "Process lists count only processes of your account; macOS hides the others without root.",
            "Fan speeds are shown but not controlled (that needs a privileged helper).",
            "Temperature sensor names are best effort and vary between chips.",
        ])

    static let snap = GadgetInfo(
        id: .windowSnap,
        tagline: "Snap windows to halves, quarters, thirds and more, from the keyboard or by dragging to a screen edge.",
        features: [
            f("rectangle.split.2x2", "24 Window Commands", "Halves, quarters, thirds, two thirds, center, maximize, almost maximize, maximize height, larger and smaller."),
            f("arrow.up.left.and.arrow.down.right", "Drag to Snap", "Drag a window to an edge or corner and a preview shows where it lands: corners give quarters, the top maximizes, the bottom gives thirds."),
            f("repeat", "Repeat to Cycle", "Press a half again for two thirds, then one third; or move on to the next display."),
            f("arrow.uturn.backward", "Restore", "⌃⌥⌫, or dragging a snapped window away, brings back the size it had before."),
            f("display.2", "Displays", "⌃⌥⌘← and ⌃⌥⌘→ move a window to the neighbouring display and keep its proportions."),
            f("hand.point.up.left", "Window Motion", "⌃⌘-drag anywhere inside a window to move it, ⌃⌘-right-drag to resize it. No need to aim for the title bar."),
            f("square.split.2x1", "Gaps", "Leave 4 to 24 points between snapped windows and the screen edges."),
            f("rectangle.3.group", "Layouts", "Save where every window is and put them back later, or by itself when the same displays are connected again."),
        ],
        tips: [t("⌃⌘", "Drag", "Move the window under the pointer"),
               t("⌃⌘", "Right-Drag", "Resize it from the nearest corner"),
               t("", "Drag to an edge", "Snap there; drop elsewhere to cancel")],
        permissions: [
            GadgetPermissionNeed(permission: .accessibility,
                                 reason: "To read and change the position and size of other apps' windows, and to follow ⌃⌘-drags.",
                                 optional: false, purpose: "moves and resizes other apps' windows"),
        ],
        permissionNote: "",
        limits: [
            "macOS 15 and later tile windows dragged to an edge themselves. While that is on, edge drags are left to macOS; turn off “Drag windows to screen edges to tile” in Desktop & Dock to use these zones.",
            "Windows cannot be moved between Spaces; macOS has no public way to do it.",
            "Some apps keep a minimum size, so their windows may not shrink all the way.",
            "Rebuilding the app (ad-hoc signature) makes macOS ask for Accessibility again.",
        ])

    static let shelf = GadgetInfo(
        id: .fileShelf,
        tagline: "A floating shelf to park files, images, links and text while you move between apps.",
        features: [
            f("hand.wave", "Shake to Open", "Shake the pointer while dragging and the shelf appears. It can also open on any drag, or only from its shortcut."),
            f("tray.full", "Holds Anything", "Files and folders, images from browsers and Photos, web links and text snippets."),
            f("square.stack.3d.up", "Drag Out Again", "Drag one item, or all of them at once with the stack handle, into any app."),
            f("eye", "Quick Look", "Select an item and press Space to preview it."),
            f("arrow.uturn.backward.circle", "Undo", "⌘Z brings back items you removed or cleared."),
            f("doc.on.clipboard", "Clipboard", "⌘V on the shelf adds the clipboard; an optional shortcut does it from anywhere."),
        ],
        tips: [t("Space", "", "Quick Look the selected item"), t("⌘V", "", "Add the clipboard"),
               t("⌘Z", "", "Bring back what you removed"), t("⌫", "", "Remove the selected item"),
               t("", "Drag the stack handle", "Drag every item at once")],
        permissions: [],
        permissionNote: "No permission needed. Drags are noticed from mouse events, which macOS allows without a permission, and nothing is read unless you drop it on the shelf.",
        limits: [
            "Dragging out always copies; the original file stays where it is.",
            "Items stay until you remove them or switch the gadget off. Images and text are kept as copies in the app's own folder and deleted then.",
        ])

    static let capture = GadgetInfo(
        id: .captureFloat,
        tagline: "Capture part of the screen and keep it floating above your work as a reference.",
        features: [
            f("viewfinder", "Capture", "An area, a window, the whole screen, or the previous area again. Press Space while selecting to pick a window."),
            f("pin", "Floats on Top", "On every Space and over full-screen apps. Move it, pinch or ⌘-scroll to resize."),
            f("circle.lefthalf.filled", "Opacity", "Scroll over a float to fade it, to compare it with what is underneath."),
            f("lock", "Lock", "Make floats click-through so you can work under them; unlock them from the panel or a shortcut."),
            f("text.viewfinder", "Copy Text", "Recognises text and QR codes in a float, on this Mac, and copies them."),
            f("square.and.arrow.up", "Drag, Copy, Save", "Drag the handle into any app, ⌘C to copy, ⌘S to save as PNG."),
            f("xmark.circle", "Close or Hide All", "Esc closes one float; the panel or a shortcut closes or hides them all."),
            f("record.circle", "Record", "Record an area or the screen to a video on your Desktop, and a GIF if you like. Stop from the menu bar."),
            f("eyedropper", "Pick a Color", "Point at any pixel and its hex code is copied."),
            f("play.rectangle", "Live Window", "Float a window that keeps updating, like picture in picture for any app."),
            f("pencil.tip.crop.circle", "Mark Up", "Draw arrows and boxes on a float; copies and saves include them."),
        ],
        tips: [t("Space", "While selecting", "Pick a window instead of an area"), t("⌘C", "", "Copy the float"),
               t("⌘S", "", "Save it as PNG"), t("⎋", "", "Close it"), t("", "Scroll", "Change its opacity"),
               t("⌘", "Scroll", "Resize it"), t("", "Double-Click", "Close it"),
               t("", "Drag with ✎ on", "Draw an arrow on a float"), t("⌥", "Drag with ✎ on", "Draw a box")],
        permissions: [
            GadgetPermissionNeed(permission: .screenRecording,
                                 reason: "To read the pixels of the area you select. macOS 15 and later ask again about once a month.",
                                 optional: false, purpose: "reads the pixels of the area you select"),
        ],
        permissionNote: "",
        limits: [
            "The system screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5) stay with macOS.",
            "Nothing is recorded or uploaded; captures stay in memory until you save or copy them.",
            "After allowing Screen Recording, macOS may need the app to restart before captures work; its page offers the restart.",
        ])

    static let dim = GadgetInfo(
        id: .focusDim,
        tagline: "Dims everything behind the window you are working in, so it stands out.",
        features: [
            f("macwindow", "Spotlight the Active Window", "Other windows and the desktop darken; the menu bar and Dock stay clear."),
            f("slider.horizontal.3", "Strength", "From a soft shade at 10% to a dark backdrop at 90%, live."),
            f("pause.circle", "Pause", "⌃⌥⌘H pauses and resumes dimming without switching the gadget off."),
            f("macwindow.on.rectangle", "Whole App", "Keep every window of the active app bright instead of only the front one."),
            f("display.2", "Displays", "Dim the other displays too, or only the one you are working on."),
            f("wand.and.rays", "Fade", "Fades between windows; instant while Reduce Motion is on."),
            f("timer", "Focus Sessions", "A focus timer (25 minutes by default) with a break after it, a countdown in the menu bar, and dimming only while you focus if you like. It can run a Shortcut when it starts and ends."),
            f("cursorarrow.click", "Clicks Pass Through", "The shade never catches a click. Clicking the desktop shows everything."),
        ],
        tips: [t("", "Click the desktop", "Show every window undimmed")],
        permissions: [],
        permissionNote: "No permission needed. Window positions come from the system window list, which is available without a permission; window titles and contents are never read.",
        limits: [])
}

public extension GadgetCatalog {
    static let keepAwake = GadgetInfo(
        id: .keepAwake,
        tagline: "Keeps the Mac awake for a while, while an app runs, or until you turn it off.",
        features: [
            f("cup.and.saucer", "One Click", "Click the cup in the menu bar to keep the Mac awake; click again to let it sleep."),
            f("timer", "For a While", "15 minutes to 5 hours, or until you turn it off. The cup shows the time left."),
            f("app.badge", "While an App Runs", "Stay awake while chosen apps run, such as a download manager or a video call."),
            f("display", "Display Too", "Keep the display on, or let it sleep while the Mac keeps working."),
            f("battery.25", "Battery Guard", "Lets the Mac sleep again when the battery runs low, or stays awake only on power."),
        ],
        tips: [t("", "Click the cup", "Start or stop"), t("", "Right-click the cup", "Choose how long")],
        permissions: [],
        permissionNote: "No permission needed. It asks macOS not to sleep the way video players do (a power assertion) and lets go of it when it stops.",
        limits: [
            "Closing the lid of a laptop still puts it to sleep unless an external display and power are connected; macOS decides that.",
            "Sleep you choose yourself (Apple menu ▸ Sleep) always wins.",
        ])

    static let clipboard = GadgetInfo(
        id: .clipboard,
        tagline: "Remembers what you copy so you can find it and paste it again.",
        features: [
            f("clock.arrow.circlepath", "History", "Text, links, images and files you copy, newest first, up to the number you choose."),
            f("magnifyingglass", "Search and Paste", "⌃⌥V opens the list at the pointer; type to search, Return pastes into the app you were in."),
            f("pin", "Pinned", "Pin what you paste often (an address, a signature); pins stay at the top and are kept after a restart."),
            f("textformat", "Plain Text", "⌥Return pastes without formatting; a shortcut pastes your last copy as plain text."),
            f("tray.and.arrow.down", "To the Shelf", "Send an item to File Shelf to drag it somewhere later."),
            f("lock.shield", "Passwords Stay Out", "Copies marked secret by password managers are never recorded."),
        ],
        tips: [t("⌃⌥V", "", "Open the history"), t("↩", "", "Paste the selected item"),
               t("⌥↩", "", "Paste it as plain text"), t("⌘P", "", "Pin or unpin it"), t("⌘S", "", "Send it to File Shelf"),
               t("⌫", "", "Remove it"), t("⌘1…9", "", "Paste one of the first nine")],
        permissions: [
            GadgetPermissionNeed(permission: .accessibility,
                                 reason: "Only to paste into the app you were in. Without it the item is copied and you press ⌘V yourself.",
                                 optional: true, purpose: "pastes into the app you were in"),
        ],
        permissionNote: "No permission needed to record: the history reads the clipboard when it changes and keeps it in memory. Only pins are saved, in the app's own folder.",
        limits: [
            "The history is cleared when you quit; pinned items stay.",
            "Some apps put very large images on the clipboard; images over 8 MB are skipped.",
        ])

    static let deviceControl = GadgetInfo(
        id: .deviceControl,
        tagline: "Switches sound devices, mutes the microphone and sets external display brightness.",
        features: [
            f("hifispeaker.2", "Sound Output", "Pick speakers or headphones and set their volume from one place."),
            f("mic.slash", "Microphone Mute", "⌃⌥M mutes the microphone everywhere; a red icon in the menu bar shows it is muted."),
            f("airpodspro", "Preferred Devices", "Switch to your headphones or microphone by themselves when they connect."),
            f("arrow.left.arrow.right", "Next Output", "One shortcut moves the sound on to the next device, round the list."),
            f("sun.max", "External Displays", "Brightness of external monitors over DDC, with a slider each and shortcuts for all."),
        ],
        tips: [t("⌃⌥M", "", "Mute or unmute the microphone"), t("", "Click the red mic", "Unmute")],
        permissions: [],
        permissionNote: "No permission needed. Devices are switched through Core Audio; nothing is recorded. External displays get standard DDC brightness commands.",
        limits: [
            "External display control works on Apple silicon with monitors that accept DDC; some docks and TVs ignore it.",
            "Per-app volume would need an audio driver, so it is not offered.",
        ])

    static let appSwitch = GadgetInfo(
        id: .appSwitch,
        tagline: "Opens apps from your own shortcuts and switches between windows with ⌥Tab.",
        features: [
            f("keyboard", "App Shortcuts", "Give any app a shortcut: it opens it, brings it to the front, or hides it when it is already in front."),
            f("rectangle.stack", "Window Switcher", "Hold ⌥ and press Tab to go through every window, not only apps; let go to switch."),
            f("eye.slash", "Hide Others", "One shortcut hides every app but the one you work in."),
            f("macwindow.badge.plus", "Minimized Windows Too", "Minimized windows are listed after the open ones and come back when you pick them."),
            f("cursorarrow.click", "Pick with the Pointer", "Click a window in the switcher to go straight to it."),
        ],
        tips: [t("⌥Tab", "", "Next window"), t("⌥⇧Tab", "", "Previous window"), t("", "Let go of ⌥", "Switch to it"),
               t("⎋", "", "Cancel")],
        permissions: [
            GadgetPermissionNeed(permission: .accessibility,
                                 reason: "To list other apps' windows and bring the one you choose to the front.",
                                 optional: false, purpose: "lists and raises other apps' windows"),
        ],
        permissionNote: "",
        limits: [
            "Windows on other Spaces show, but macOS switches to their Space when you pick them.",
            "⌘Tab stays with macOS.",
        ])

    static let mouseTune = GadgetInfo(
        id: .mouseTune,
        tagline: "Fixes a wheel mouse: its own scroll direction, smooth scrolling and back / forward buttons.",
        features: [
            f("arrow.up.arrow.down", "Own Scroll Direction", "Reverse the wheel of a mouse while the trackpad keeps natural scrolling."),
            f("water.waves", "Smooth Scrolling", "Each wheel notch glides instead of jumping a line."),
            f("speedometer", "Scroll Speed", "Half to three times as far per notch."),
            f("arrow.left.arrow.right", "Back and Forward", "The side buttons go back and forward in browsers and Finder."),
            f("rectangle.3.group", "Middle Button", "Use the middle button for Mission Control if you like."),
        ],
        tips: [t("", "Side buttons", "Back and forward"), t("", "Middle button", "Mission Control, if you choose it")],
        permissions: [
            GadgetPermissionNeed(permission: .accessibility,
                                 reason: "To change scroll and button events of the mouse as they happen. Keystrokes are never read.",
                                 optional: false, purpose: "changes the scrolling and buttons of your mouse"),
        ],
        permissionNote: "",
        limits: [
            "Trackpads and Magic Mouse are left as they are; only wheel mice change.",
            "Pointer speed per device is not offered: macOS keeps it to its own settings.",
        ])

    static let calendarClock = GadgetInfo(
        id: .calendarClock,
        tagline: "A clock with a calendar, your next meeting and world clocks in the menu bar.",
        features: [
            f("clock", "Your Clock", "Date, weekday and time the way you like them, with seconds if you want."),
            f("calendar", "Month at a Glance", "Click the clock for a month calendar with your events."),
            f("video", "Join the Meeting", "The next event shows a countdown and a Join button when it has a video call link."),
            f("calendar.badge.clock", "Countdown", "Fifteen minutes before a meeting, its name and the minutes to go show beside the clock."),
            f("globe", "World Clocks", "The time in the cities you add, with how far ahead or behind they are."),
        ],
        tips: [t("", "Click the clock", "Open the calendar"), t("", "Click Join", "Open the meeting link")],
        permissions: [
            GadgetPermissionNeed(permission: .calendars,
                                 reason: "Only to show your events and meeting links. The clock and world clocks work without it.",
                                 optional: true, purpose: "shows your events and meeting links"),
        ],
        permissionNote: "No permission needed for the clock and world clocks. Events are read on this Mac and never sent anywhere.",
        limits: [
            "Hide the system clock's date in Control Center ▸ Clock Options if you do not want two.",
        ])
}

/// Which step of allowing a permission the gallery shows. macOS never says "the user is in System Settings right now"
/// or "allowed, waiting for a restart", so the stage is inferred from what the user did here and what is in front.
public enum PermissionStage: String, Equatable {
    /// The three steps: open the list, turn on Nacho Combo, come back.
    case notAllowed
    /// The user opened the list from here and System Settings is in front.
    case waiting
    /// Back from System Settings and still not allowed: Nacho Combo may be on in the list already but not applied.
    case stillNotAllowed
    /// Back from Screen Recording and still not allowed: macOS applies it after Nacho Combo restarts.
    case restartNeeded
    /// An earlier copy of the app was allowed; this copy is new (an update changes the ad-hoc signature).
    case updated
    case allowed
}

public enum PermissionGuide {
    /// - Parameters:
    ///   - visitedSettings: the user opened the permission's list from Nacho Combo since the gadget started waiting.
    ///   - settingsInFront: System Settings is the frontmost app.
    ///   - grantedSignature: the code signature of the copy that last had the permission (nil: never seen allowed).
    ///   - currentSignature: this copy's code signature.
    public static func stage(granted: Bool, permission: GadgetPermission, visitedSettings: Bool, settingsInFront: Bool,
                             grantedSignature: String?, currentSignature: String?) -> PermissionStage {
        if granted { return .allowed }
        if visitedSettings && settingsInFront { return .waiting }
        if visitedSettings && permission == .screenRecording { return .restartNeeded }
        if let old = grantedSignature, let now = currentSignature, old != now { return .updated }
        return visitedSettings ? .stillNotAllowed : .notAllowed
    }
}
