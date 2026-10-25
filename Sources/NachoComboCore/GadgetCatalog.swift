import Foundation

/// macOS privacy permissions a gadget can need.
public enum GadgetPermission: String, CaseIterable {
    case accessibility, screenRecording, notifications

    public var displayName: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        }
    }

    public var symbolName: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .notifications: return "bell.badge"
        }
    }

    /// Where the switch lives (macOS 13+ wording).
    public var location: String {
        switch self {
        case .accessibility: return "System Settings ▸ Privacy & Security ▸ Accessibility"
        case .screenRecording: return "System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording"
        case .notifications: return "System Settings ▸ Notifications ▸ Nacho Combo"
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
        }
    }

    private static func f(_ symbol: String, _ title: String, _ detail: String) -> GadgetFeature {
        GadgetFeature(symbol: symbol, title: title, detail: detail)
    }

    private static func t(_ keys: String, _ gesture: String = "", _ title: String) -> GadgetTip {
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
            GadgetPermissionNeed(permission: .notifications, reason: "Only to post alert notifications, if you turn them on.", optional: true),
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
        ],
        tips: [t("⌃⌘", "Drag", "Move the window under the pointer"),
               t("⌃⌘", "Right-Drag", "Resize it from the nearest corner"),
               t("", "Drag to an edge", "Snap there; drop elsewhere to cancel")],
        permissions: [
            GadgetPermissionNeed(permission: .accessibility,
                                 reason: "To read and change the position and size of other apps' windows, and to follow ⌃⌘-drags.",
                                 optional: false),
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
        ],
        tips: [t("Space", "While selecting", "Pick a window instead of an area"), t("⌘C", "", "Copy the float"),
               t("⌘S", "", "Save it as PNG"), t("⎋", "", "Close it"), t("", "Scroll", "Change its opacity"),
               t("⌘", "Scroll", "Resize it"), t("", "Double-Click", "Close it")],
        permissions: [
            GadgetPermissionNeed(permission: .screenRecording,
                                 reason: "To read the pixels of the area you select. macOS 15 and later ask again about once a month.",
                                 optional: false),
        ],
        permissionNote: "",
        limits: [
            "The system screenshot shortcuts (⇧⌘3, ⇧⌘4, ⇧⌘5) stay with macOS.",
            "Nothing is recorded or uploaded; captures stay in memory until you save or copy them.",
            "After allowing Screen Recording, macOS may need the app to restart before captures work.",
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
            f("cursorarrow.click", "Clicks Pass Through", "The shade never catches a click. Clicking the desktop shows everything."),
        ],
        tips: [t("", "Click the desktop", "Show every window undimmed")],
        permissions: [],
        permissionNote: "No permission needed. Window positions come from the system window list, which is available without a permission; window titles and contents are never read.",
        limits: [])
}
