import AppKit
import UniformTypeIdentifiers
import NachoComboCore

/// What the gallery previews read from the running app, so each picture shows the gadget as it is set up now.
struct GadgetPreviewInputs {
    var menuBarCollapsed = false
    var menuBarAlwaysHidden = false
    var monitor: (strip: NSImage?, panel: NSImage?, live: Bool)?
    var shelfItems: [ShelfItem] = []
    var dimIntensity = FocusDimLogic.defaultIntensity
    var snapGap: CGFloat = 0
    var keys: [String: String] = [:]
    var clockText = ""
    var worldClocks: [String] = []
    var keepAwakeMinutes = 0
}

/// Pictures of each gadget at work for the gallery's detail pane. Wherever the gadget has its own interface the
/// picture is that real view rendered offscreen (monitor items and panel, shelf panel, floating capture); the
/// desktop around it (wallpaper, menu bar, other apps' windows) is drawn, because the app does not record the screen.
enum GadgetPreview {
    struct Picture {
        let image: NSImage
        /// Short line under the picture: what is shown and whether the numbers are live.
        let caption: String
    }

    static let width: CGFloat = 400

    static func picture(for id: ModuleID, inputs: GadgetPreviewInputs, appearance: NSAppearance) -> Picture {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var picture: Picture!
        appearance.performAsCurrentDrawingAppearance {
            switch id {
            case .menuBar: picture = menuBar(inputs, dark: dark)
            case .systemMonitor: picture = monitor(inputs, dark: dark, appearance: appearance)
            case .windowSnap: picture = snap(inputs, dark: dark)
            case .fileShelf: picture = shelf(inputs, dark: dark, appearance: appearance)
            case .captureFloat: picture = capture(inputs, dark: dark, appearance: appearance)
            case .focusDim: picture = dim(inputs, dark: dark)
            case .keepAwake: picture = keepAwake(inputs, dark: dark)
            case .clipboard: picture = clipboard(inputs, dark: dark)
            case .deviceControl: picture = devices(inputs, dark: dark)
            case .appSwitch: picture = appSwitch(inputs, dark: dark)
            case .mouseTune: picture = mouse(inputs, dark: dark)
            case .calendarClock: picture = calendar(inputs, dark: dark)
            }
        }
        return picture
    }

    // MARK: scenes

    private static func menuBar(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let always = inputs.menuBarAlwaysHidden
        let size = NSSize(width: width, height: always ? 258 : 196)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            let hidden = ["icloud", "music.note", "paintpalette", "bolt.horizontal"]
            let alwaysHidden = ["clock.arrow.circlepath", "printer"]
            let shown = ["wifi", "battery.75"]
            enum State { case expanded, collapsed, all }
            func bar(y: CGFloat, caption: String, state: State, current: Bool) {
                Stage.caption(caption + (current ? "  ·  now" : ""), at: NSPoint(x: 14, y: y - 18))
                let r = NSRect(x: 10, y: y, width: rect.width - 20, height: 26)
                var items: [Stage.BarItem] = [.text("9:41"), .text(state == .collapsed ? "›" : "‹", bold: true)]
                items += shown.map { .symbol($0) }
                if state != .collapsed {
                    items.append(.text("┊", bold: true, accent: true))
                    items += hidden.map { .symbol($0) }
                    if state == .all {
                        items.append(.text("┊", bold: true, accent: true, faded: true))
                        items += alwaysHidden.map { .symbol($0) }
                    }
                }
                Stage.menuBar(r, dark: dark, app: "Notes", menus: ["File", "Edit", "View", "Window", "Help"], items: items,
                              rounded: true)
            }
            bar(y: 34, caption: "Expanded: every icon shows" + (always ? " but the always-hidden ones" : ""),
                state: .expanded, current: !inputs.menuBarCollapsed)
            bar(y: 98, caption: "Collapsed: icons left of ┊ fold away", state: .collapsed, current: inputs.menuBarCollapsed)
            var y: CGFloat = 146
            if always {
                bar(y: 160, caption: "⌥-click ‹: the always-hidden icons show too", state: .all, current: false)
                y = 208
            }
            Stage.caption("⌘-drag an icon across ┊ to choose what folds away", at: NSPoint(x: 14, y: y), small: true)
            if let keys = inputs.keys["menuBar.toggle"] {
                KeyCaps.draw(keys, at: NSPoint(x: 14, y: y + 20), height: 18, dark: true, flipped: true)
            }
        }
        return Picture(image: image, caption: "Drawn with the gadget's own menu bar items (‹ and ┊) on a sample menu bar.")
    }

    private static func monitor(_ inputs: GadgetPreviewInputs, dark: Bool, appearance: NSAppearance) -> Picture {
        let size = NSSize(width: width, height: 300)
        let images = inputs.monitor
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            let barRect = NSRect(x: 0, y: 0, width: rect.width, height: 24)
            Stage.menuBar(barRect, dark: dark, app: nil, menus: [], items: [.text("9:41")], rounded: false)
            var stripX = rect.width - 44
            if let strip = images?.strip {
                let s = strip.size
                let scale = min(1, (rect.width - 60) / s.width)
                stripX = rect.width - 44 - s.width * scale
                strip.draw(in: NSRect(x: stripX, y: (24 - s.height * scale) / 2, width: s.width * scale, height: s.height * scale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            if let panel = images?.panel {
                let scale: CGFloat = 0.8
                let w = panel.size.width * scale, h = panel.size.height * scale
                let x = min(max(8, stripX - 6), rect.width - w - 8)
                let frame = NSRect(x: x, y: 30, width: w, height: h)
                Stage.shadowed(frame, radius: 10) {
                    panel.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
        }
        let live = images?.live ?? false
        return Picture(image: image, caption: live ? "Live: your Mac's menu bar items and CPU panel, right now."
                                                   : "The real menu bar items and CPU panel, filled with sample numbers until you switch it on.")
    }

    private static func snap(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 224)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 20), dark: dark, app: "Notes",
                          menus: ["File", "Edit", "View"], items: [.text("9:41")], rounded: false)
            // Cocoa-style layout of the visible area (y down here), with the user's gap scaled to the picture.
            let visible = NSRect(x: 0, y: 20, width: rect.width, height: rect.height - 20)
            let gap = min(10, inputs.snapGap * 0.4)
            let left = NSRect(x: visible.minX + gap, y: visible.minY + gap, width: visible.width / 2 - gap * 1.5,
                              height: visible.height - 2 * gap)
            let right = NSRect(x: visible.midX + gap / 2, y: visible.minY + gap, width: visible.width / 2 - gap * 1.5,
                               height: visible.height - 2 * gap)
            Stage.window(left, dark: dark, title: "Notes", style: .text)
            // Drop zone shown while a window is dragged to the right edge.
            NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
            let zone = NSBezierPath(roundedRect: right.insetBy(dx: 3, dy: 3), xRadius: 9, yRadius: 9)
            zone.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            zone.lineWidth = 2
            zone.stroke()
            let dragged = NSRect(x: right.minX + 46, y: right.minY + 36, width: 150, height: 112)
            Stage.window(dragged, dark: dark, title: "Browser", style: .chart, alpha: 0.92)
            Stage.cursor(at: NSPoint(x: rect.width - 7, y: dragged.minY + 8))
            let keys = inputs.keys["snap.left"] ?? "⌃⌥←"
            let w = KeyCaps.width(of: keys, height: 22)
            KeyCaps.draw(keys, at: NSPoint(x: left.midX - w / 2, y: left.midY + 4), height: 22, dark: dark, flipped: true)
            Stage.caption("Left Half", at: NSPoint(x: left.midX - 26, y: left.midY + 32), dark: dark, onWindow: true)
        }
        return Picture(image: image, caption: "Keyboard: the left half from ⌃⌥←. Mouse: a window dragged to the right edge shows where it will land.")
    }

    private static func shelf(_ inputs: GadgetPreviewInputs, dark: Bool, appearance: NSAppearance) -> Picture {
        let size = NSSize(width: width, height: 244)
        let live = !inputs.shelfItems.isEmpty
        let items = live ? Array(inputs.shelfItems.prefix(4)) : sampleShelfItems()
        let panelImage = shelfPanelImage(items: items, appearance: appearance)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 20), dark: dark, app: "Finder",
                          menus: ["File", "Edit", "Go"], items: [.text("9:41")], rounded: false)
            let finder = NSRect(x: 14, y: 34, width: 214, height: 176)
            Stage.window(finder, dark: dark, title: "Documents", style: .files)
            if let panel = panelImage {
                let scale: CGFloat = 0.72
                let frame = NSRect(x: rect.width - panel.size.width * scale - 14, y: 30, width: panel.size.width * scale,
                                   height: panel.size.height * scale)
                Stage.shadowed(frame, radius: 9) {
                    panel.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                // A file on its way from the folder to the shelf.
                let icon = NSWorkspace.shared.icon(for: UTType.pdf)
                let ghost = NSRect(x: frame.minX - 40, y: frame.midY + 10, width: 40, height: 40)
                icon.draw(in: ghost, from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
                Stage.cursor(at: NSPoint(x: ghost.midX + 6, y: ghost.midY + 6))
            }
        }
        return Picture(image: image, caption: live ? "Your shelf as it is now, drawn by the shelf's own panel."
                                                   : "The shelf's own panel with sample items: drop on it, drag out again.")
    }

    private static func capture(_ inputs: GadgetPreviewInputs, dark: Bool, appearance: NSAppearance) -> Picture {
        let size = NSSize(width: width, height: 232)
        let source = NSRect(x: 58, y: 66, width: 150, height: 92)
        // First the desktop alone, so the floating copy shows exactly what was under the selection.
        let base = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 20), dark: dark, app: "Numbers",
                          menus: ["File", "Edit", "Insert"], items: [.text("9:41")], rounded: false)
            Stage.window(NSRect(x: 20, y: 30, width: 240, height: 182), dark: dark, title: "Q3 Sales", style: .chart)
        }
        let crop = Stage.crop(base, to: source)
        let float = crop.flatMap { floatingCaptureImage($0, appearance: appearance) }
        let image = canvas(size) { rect in
            base.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            // Selection outline with its size, like the real selection overlay draws it.
            let dash = NSBezierPath(rect: source)
            dash.lineWidth = 1.2
            dash.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            dash.stroke()
            Stage.caption("\(Int(source.width) * 2) × \(Int(source.height) * 2)", at: NSPoint(x: source.minX, y: source.maxY + 3),
                          small: true)
            if let float = float {
                let frame = NSRect(x: 236, y: 98, width: float.size.width, height: float.size.height)
                Stage.shadowed(frame, radius: 0) {
                    float.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            if let keys = inputs.keys["capture.area"] {
                KeyCaps.draw(keys, at: NSPoint(x: 280, y: 40), height: 20, dark: true, flipped: true)
            }
        }
        return Picture(image: image, caption: "A selected area floating above the other windows, with its own close, pin and resize controls.")
    }

    private static func dim(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 224)
        let intensity = CGFloat(FocusDimLogic.clamp(inputs.dimIntensity))
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.window(NSRect(x: 16, y: 40, width: 190, height: 130), dark: dark, title: "Mail", style: .text)
            Stage.window(NSRect(x: 228, y: 58, width: 158, height: 150), dark: dark, title: "Calendar", style: .files)
            // The overlay: everything below the menu bar and behind the active window darkens.
            NSColor.black.withAlphaComponent(intensity).setFill()
            NSRect(x: 0, y: 20, width: rect.width, height: rect.height - 20).fill()
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 20), dark: dark, app: "Notes",
                          menus: ["File", "Edit", "View"], items: [.text("9:41")], rounded: false)
            Stage.window(NSRect(x: 104, y: 78, width: 196, height: 132), dark: dark, title: "Notes", style: .text)
            Stage.caption("Strength \(Int((intensity * 100).rounded()))%", at: NSPoint(x: 14, y: 30), small: true)
            if let keys = inputs.keys["dim.toggle"] {
                KeyCaps.draw(keys, at: NSPoint(x: 14, y: 196), height: 18, dark: true, flipped: true)
            }
        }
        return Picture(image: image, caption: "The active window stays bright; the windows behind it dim at your strength.")
    }

    /// A menu drawn like the system's: rounded, translucent, one line per entry (`nil` = a separator).
    private static func menu(_ rect: NSRect, dark: Bool, lines: [(String, Bool)?]) {
        Stage.shadowed(rect, radius: 8) {
            (dark ? NSColor(white: 0.17, alpha: 0.96) : NSColor(white: 0.98, alpha: 0.96)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
        let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
        var y = rect.minY + 8
        for line in lines {
            guard let (text, checked) = line else {
                (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)).setFill()
                NSRect(x: rect.minX + 10, y: y + 3, width: rect.width - 20, height: 1).fill()
                y += 8
                continue
            }
            if checked { Stage.text("✓", at: NSPoint(x: rect.minX + 9, y: y + 9), font: .systemFont(ofSize: 11, weight: .bold), color: ink) }
            Stage.text(text, at: NSPoint(x: rect.minX + 24, y: y + 9), font: .systemFont(ofSize: 12), color: ink)
            y += 19
        }
    }

    private static func keepAwake(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 230)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.window(NSRect(x: 18, y: 44, width: 200, height: 160), dark: dark, title: "Downloads", style: .files)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 22), dark: dark, app: "Finder", menus: ["File", "Edit"],
                          items: [.text("9:41"), .text("45m"), .symbol("cup.and.saucer.fill"), .symbol("wifi")], rounded: false)
            let choices = GadgetOptions.keepAwakeChoices.map { (KeepAwakePolicy.durationName($0), false) }
            menu(NSRect(x: rect.width - 196, y: 26, width: 176, height: 176), dark: dark,
                 lines: [("Awake for 45m more", false), nil] + choices.map { Optional($0) } + [nil, ("Keep the Display On", true)])
            let click = KeepAwakePolicy.durationName(inputs.keepAwakeMinutes)
            Stage.caption("A click: \(click.lowercased())", at: NSPoint(x: 24, y: 208), small: true)
        }
        return Picture(image: image, caption: "Click the cup to stay awake; right-click it to choose for how long.")
    }

    private static func clipboard(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 250)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 20), dark: dark, app: "Mail", menus: ["File", "Edit"],
                          items: [.text("9:41")], rounded: false)
            Stage.window(NSRect(x: 14, y: 30, width: 190, height: 200), dark: dark, title: "New Message", style: .text)
            let list = NSRect(x: 170, y: 40, width: 214, height: 196)
            Stage.shadowed(list, radius: 10) {
                (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.99, alpha: 0.97)).setFill()
                NSBezierPath(roundedRect: list, xRadius: 10, yRadius: 10).fill()
            }
            let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
            let soft = dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.45)
            (dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)).setFill()
            NSBezierPath(roundedRect: NSRect(x: list.minX + 10, y: list.minY + 10, width: list.width - 20, height: 22),
                         xRadius: 6, yRadius: 6).fill()
            Stage.text("Search what you copied", at: NSPoint(x: list.minX + 20, y: list.minY + 21), font: .systemFont(ofSize: 11),
                       color: soft)
            let rows: [(String, String, String)] = [("Main Street 12, Springfield", "Pinned · Notes", "pin.fill"),
                                                    ("https://example.com/report", "Browser · 2 min ago", "link"),
                                                    ("Quarterly numbers are up 12%", "Numbers · 5 min ago", "text.alignleft"),
                                                    ("Screenshot", "Image · 12 min ago", "photo"),
                                                    ("Invoice-October.pdf", "Finder · 1 h ago", "doc")]
            for (index, row) in rows.enumerated() {
                let y = list.minY + 40 + CGFloat(index) * 30
                if index == 1 {
                    NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                    NSBezierPath(roundedRect: NSRect(x: list.minX + 6, y: y, width: list.width - 12, height: 28), xRadius: 6,
                                 yRadius: 6).fill()
                }
                let color = index == 1 ? NSColor.white : ink
                if let symbol = NSImage(systemSymbolName: row.2, accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [color]))) {
                    symbol.draw(in: NSRect(x: list.minX + 14, y: y + 8, width: symbol.size.width, height: symbol.size.height),
                                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                Draw.text(row.0, in: NSRect(x: list.minX + 34, y: y + 2, width: list.width - 74, height: 14),
                          font: .systemFont(ofSize: 11, weight: .medium), color: color)
                Stage.text(row.1, at: NSPoint(x: list.minX + 34, y: y + 21), font: .systemFont(ofSize: 9),
                           color: index == 1 ? NSColor.white.withAlphaComponent(0.8) : soft)
                Stage.text("⌘\(index + 1)", at: NSPoint(x: list.maxX - 30, y: y + 14), font: .systemFont(ofSize: 9), color: soft)
            }
            if let keys = inputs.keys["clipboard.show"] {
                KeyCaps.draw(keys, at: NSPoint(x: 24, y: 196), height: 20, dark: dark, flipped: true)
            }
        }
        return Picture(image: image, caption: "The history opens at the pointer: type to search, Return pastes into the message.")
    }

    private static func devices(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 230)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.window(NSRect(x: 16, y: 40, width: 180, height: 150), dark: dark, title: "Video Call", style: .chart)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 22), dark: dark, app: "Calls", menus: ["File"],
                          items: [.text("9:41"), .symbol("mic.slash.fill"), .symbol("speaker.wave.2")], rounded: false)
            let panel = NSRect(x: rect.width - 200, y: 30, width: 186, height: 180)
            Stage.shadowed(panel, radius: 10) {
                (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.99, alpha: 0.97)).setFill()
                NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10).fill()
            }
            let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
            let soft = dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.45)
            func slider(_ y: CGFloat, _ value: CGFloat) {
                (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.12)).setFill()
                NSBezierPath(roundedRect: NSRect(x: panel.minX + 14, y: y, width: panel.width - 28, height: 4), xRadius: 2, yRadius: 2).fill()
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: panel.minX + 14, y: y, width: (panel.width - 28) * value, height: 4),
                             xRadius: 2, yRadius: 2).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: panel.minX + 14 + (panel.width - 28) * value - 6, y: y - 4, width: 12, height: 12)).fill()
            }
            Stage.text("Output", at: NSPoint(x: panel.minX + 14, y: panel.minY + 16), font: .systemFont(ofSize: 10, weight: .semibold), color: soft)
            Stage.text("Headphones", at: NSPoint(x: panel.minX + 14, y: panel.minY + 32), font: .systemFont(ofSize: 12, weight: .medium), color: ink)
            slider(panel.minY + 46, 0.6)
            Stage.text("Microphone", at: NSPoint(x: panel.minX + 14, y: panel.minY + 72), font: .systemFont(ofSize: 10, weight: .semibold), color: soft)
            Stage.text("Built-in · Muted", at: NSPoint(x: panel.minX + 14, y: panel.minY + 88), font: .systemFont(ofSize: 12, weight: .medium),
                       color: NSColor.systemRed)
            Stage.text("External Display", at: NSPoint(x: panel.minX + 14, y: panel.minY + 116), font: .systemFont(ofSize: 10, weight: .semibold),
                       color: soft)
            slider(panel.minY + 134, 0.75)
            if let keys = inputs.keys["device.micMute"] {
                KeyCaps.draw(keys, at: NSPoint(x: panel.minX + 14, y: panel.minY + 150), height: 18, dark: dark, flipped: true)
            }
        }
        return Picture(image: image, caption: "Sound output, microphone mute and external display brightness in one place.")
    }

    private static func appSwitch(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 230)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 20), dark: dark, app: "Notes", menus: ["File", "Edit"],
                          items: [.text("9:41")], rounded: false)
            Stage.window(NSRect(x: 16, y: 34, width: 170, height: 130), dark: dark, title: "Notes", style: .text)
            Stage.window(NSRect(x: 214, y: 54, width: 170, height: 130), dark: dark, title: "Report", style: .chart)
            let panel = NSRect(x: 80, y: 46, width: 240, height: 150)
            Stage.shadowed(panel, radius: 12) {
                NSColor(white: 0.12, alpha: 0.88).setFill()
                NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
            }
            let rows: [(String, String, NSColor)] = [("Meeting notes", "Notes", .systemYellow), ("Q3 Report.numbers", "Numbers", .systemGreen),
                                                     ("Inbox", "Mail", .systemBlue), ("Design review", "Browser", .systemOrange)]
            for (index, row) in rows.enumerated() {
                let y = panel.minY + 10 + CGFloat(index) * 34
                if index == 1 {
                    NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                    NSBezierPath(roundedRect: NSRect(x: panel.minX + 8, y: y, width: panel.width - 16, height: 32), xRadius: 7,
                                 yRadius: 7).fill()
                }
                row.2.setFill()
                NSBezierPath(roundedRect: NSRect(x: panel.minX + 16, y: y + 6, width: 20, height: 20), xRadius: 5, yRadius: 5).fill()
                Stage.text(row.0, at: NSPoint(x: panel.minX + 46, y: y + 11), font: .systemFont(ofSize: 11, weight: .semibold), color: .white)
                Stage.text(row.1, at: NSPoint(x: panel.minX + 46, y: y + 24), font: .systemFont(ofSize: 9),
                           color: NSColor.white.withAlphaComponent(0.7))
            }
            let keys = inputs.keys["appSwitch.next"] ?? "⌥Tab"
            KeyCaps.draw(keys, at: NSPoint(x: 160, y: 204), height: 20, dark: true, flipped: true)
        }
        return Picture(image: image, caption: "Hold ⌥ and press Tab: every window, not only apps; let go to switch.")
    }

    private static func mouse(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 220)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            Stage.window(NSRect(x: 16, y: 20, width: 230, height: 184), dark: dark, title: "Article", style: .text)
            let body = NSRect(x: 290, y: 56, width: 64, height: 108)
            Stage.shadowed(body, radius: 32) {
                NSColor(white: 0.97, alpha: 1).setFill()
                NSBezierPath(roundedRect: body, xRadius: 32, yRadius: 32).fill()
            }
            NSColor(white: 0.75, alpha: 1).setFill()
            NSRect(x: body.minX, y: body.minY + 42, width: body.width, height: 1.2).fill()
            NSRect(x: body.midX - 0.6, y: body.minY, width: 1.2, height: 42).fill()
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: body.midX - 5, y: body.minY + 12, width: 10, height: 20), xRadius: 5, yRadius: 5).fill()
            for (y, symbol) in [(CGFloat(34), "arrow.up"), (CGFloat(172), "arrow.down")] {
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 14, weight: .bold).applying(.init(paletteColors: [.white]))) {
                    image.draw(in: NSRect(x: body.midX - image.size.width / 2, y: y, width: image.size.width, height: image.size.height),
                               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
            }
            Stage.caption("Smooth, in your direction", at: NSPoint(x: 262, y: 12), small: true)
            Stage.caption("Side buttons: back · forward", at: NSPoint(x: 258, y: 194), small: true)
            // A glide: the page moves in small steps instead of jumps.
            for i in 0..<6 {
                NSColor.controlAccentColor.withAlphaComponent(0.15 + 0.12 * CGFloat(i)).setFill()
                NSBezierPath(roundedRect: NSRect(x: 258, y: 60 + CGFloat(i) * 16, width: 6, height: 10), xRadius: 3, yRadius: 3).fill()
            }
        }
        return Picture(image: image, caption: "A wheel mouse scrolls smoothly in its own direction; the trackpad stays natural.")
    }

    private static func calendar(_ inputs: GadgetPreviewInputs, dark: Bool) -> Picture {
        let size = NSSize(width: width, height: 272)
        let image = canvas(size) { rect in
            Stage.wallpaper(rect, dark: dark)
            let clock = inputs.clockText.isEmpty ? "Thu 29 Oct 9:41" : inputs.clockText
            Stage.menuBar(NSRect(x: 0, y: 0, width: rect.width, height: 22), dark: dark, app: "Finder", menus: ["File"],
                          items: [.text(clock), .symbol("wifi")], rounded: false)
            let panel = NSRect(x: rect.width - 238, y: 28, width: 224, height: 236)
            Stage.shadowed(panel, radius: 10) {
                (dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 0.99, alpha: 0.97)).setFill()
                NSBezierPath(roundedRect: panel, xRadius: 10, yRadius: 10).fill()
            }
            let ink = dark ? NSColor(white: 1, alpha: 0.9) : NSColor(white: 0, alpha: 0.85)
            let soft = dark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.45)
            Stage.text("October 2026", at: NSPoint(x: panel.minX + 12, y: panel.minY + 16), font: .systemFont(ofSize: 12, weight: .bold), color: ink)
            let cell = (panel.width - 24) / 7
            for column in 0..<7 {
                for row in 0..<5 {
                    let day = row * 7 + column - 3
                    guard day >= 1, day <= 31 else { continue }
                    let x = panel.minX + 12 + CGFloat(column) * cell, y = panel.minY + 34 + CGFloat(row) * 18
                    if day == 29 {
                        Brand.nacho.setFill()
                        NSBezierPath(ovalIn: NSRect(x: x + cell / 2 - 8, y: y - 1, width: 16, height: 16)).fill()
                    }
                    let text = "\(day)"
                    let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: day == 29 ? .bold : .regular)
                    let w = Draw.width(text, font)
                    Stage.text(text, at: NSPoint(x: x + cell / 2 - w / 2, y: y + 7), font: font, color: day == 29 ? Brand.onNacho : ink)
                }
            }
            let event = NSRect(x: panel.minX + 12, y: panel.minY + 130, width: panel.width - 24, height: 34)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: event.minX, y: event.minY + 2, width: 4, height: 30), xRadius: 2, yRadius: 2).fill()
            Stage.text("Design review", at: NSPoint(x: event.minX + 12, y: event.minY + 11), font: .systemFont(ofSize: 11, weight: .semibold), color: ink)
            Stage.text("10:00 – 10:30 · in 5 min", at: NSPoint(x: event.minX + 12, y: event.minY + 25), font: .systemFont(ofSize: 9), color: soft)
            let join = NSRect(x: event.maxX - 44, y: event.minY + 7, width: 42, height: 20)
            Brand.nacho.setFill()
            NSBezierPath(roundedRect: join, xRadius: 6, yRadius: 6).fill()
            Stage.text("Join", at: NSPoint(x: join.minX + 10, y: join.midY), font: .systemFont(ofSize: 10, weight: .bold), color: Brand.onNacho)
            let cities = inputs.worldClocks.isEmpty ? ["Europe/London", "Asia/Tokyo"] : Array(inputs.worldClocks.prefix(2))
            for (index, identifier) in cities.enumerated() {
                let y = panel.minY + 182 + CGFloat(index) * 20
                Stage.text(WorldClock.city(identifier), at: NSPoint(x: panel.minX + 12, y: y), font: .systemFont(ofSize: 11), color: ink)
                if let zone = TimeZone(identifier: identifier) {
                    Stage.text(WorldClock.offset(zone, from: .current, at: Date()), at: NSPoint(x: panel.minX + 100, y: y),
                               font: .systemFont(ofSize: 9), color: soft)
                    let time = DateFormatter()
                    time.timeZone = zone
                    time.locale = Locale(identifier: "en_US")   // the sample picture is in English throughout
                    time.setLocalizedDateFormatFromTemplate("jmm")
                    let text = time.string(from: Date())
                    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                    Stage.text(text, at: NSPoint(x: panel.maxX - 12 - Draw.width(text, font), y: y), font: font, color: ink)
                }
            }
        }
        return Picture(image: image, caption: "Click the clock: the month, the day's events with Join, and your world clocks.")
    }

    // MARK: real views

    private static func sampleShelfItems() -> [ShelfItem] {
        [ShelfItem(kind: .file, fileURL: URL(fileURLWithPath: "/Documents/Quarterly Report.pdf"), text: nil,
                   ownsFile: false, title: "Quarterly Report.pdf"),
         ShelfItem(kind: .file, fileURL: URL(fileURLWithPath: "/Documents/Logo.png"), text: nil,
                   ownsFile: false, title: "Logo.png"),
         ShelfItem(kind: .text, fileURL: nil, text: "Meeting moved to Thursday 3 pm, room 4B", ownsFile: false,
                   title: "Meeting moved to Thursday 3 pm, room 4B")]
    }

    /// The shelf panel (title bar drawn here, content by the real view classes).
    private static func shelfPanelImage(items: [ShelfItem], appearance: NSAppearance) -> NSImage? {
        let panel = ShelfPanel()
        panel.appearance = appearance
        panel.setContentSize(NSSize(width: 280, height: 236))
        panel.setItems(items)
        guard let content = panel.contentView else { return nil }
        content.frame = NSRect(x: 0, y: 0, width: 280, height: 236)
        content.layoutSubtreeIfNeeded()
        let titleHeight: CGFloat = 22
        let size = NSSize(width: 280, height: 236 + titleHeight)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        let body = NSImage(size: content.bounds.size)
        body.addRepresentation(rep)
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return canvas(size) { rect in
            (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            Stage.titleBar(NSRect(x: 0, y: 0, width: rect.width, height: titleHeight), title: "File Shelf", dark: dark, small: true)
            body.draw(in: NSRect(x: 0, y: titleHeight, width: 280, height: 236), from: .zero, operation: .sourceOver,
                      fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The floating capture window's own canvas (picture, close / pin buttons, resize grip).
    private static func floatingCaptureImage(_ cgImage: CGImage, appearance: NSAppearance) -> NSImage? {
        let pointSize = NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2)
        let window = FloatingCaptureWindow(cgImage: cgImage, pointSize: pointSize, at: .zero)
        window.appearance = appearance
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// A 2x bitmap drawn with a flipped (y down) coordinate system.
    static func canvas(_ size: NSSize, draw: @escaping (NSRect) -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        // Text and images drawn into the flipped space must know it, or they come out upside down.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}

/// Drawing pieces of the preview desktop (flipped coordinates).
enum Stage {
    enum BarItem {
        case symbol(String)
        case text(String, bold: Bool = false, accent: Bool = false, faded: Bool = false)
    }

    enum WindowStyle { case text, chart, files }

    static func wallpaper(_ rect: NSRect, dark: Bool) {
        let colors: [NSColor] = dark
            ? [NSColor(srgbRed: 0.13, green: 0.16, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.29, green: 0.15, blue: 0.38, alpha: 1)]
            : [NSColor(srgbRed: 0.62, green: 0.78, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.96, green: 0.76, blue: 0.86, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: rect, angle: -35)
        // Two soft light blobs so the backdrop is not flat.
        for (center, radius, alpha) in [(NSPoint(x: rect.width * 0.2, y: rect.height * 0.8), rect.width * 0.35, 0.10),
                                        (NSPoint(x: rect.width * 0.85, y: rect.height * 0.25), rect.width * 0.3, 0.08)] {
            NSGradient(starting: NSColor.white.withAlphaComponent(alpha), ending: NSColor.white.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
        }
    }

    static func menuBar(_ rect: NSRect, dark: Bool, app: String?, menus: [String], items: [BarItem], rounded: Bool) {
        let path = rounded ? NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7) : NSBezierPath(rect: rect)
        (dark ? NSColor(white: 0.08, alpha: 0.72) : NSColor(white: 1, alpha: 0.72)).setFill()
        path.fill()
        let ink = dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0.08, alpha: 0.92)
        let size = min(13, rect.height * 0.5)
        // Status items first, right to left; app menus then fill what is left, like the real menu bar.
        var right = rect.maxX - 10
        for item in items {
            switch item {
            case .text(let string, let bold, let accent, let faded):
                let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
                let w = ceil((string as NSString).size(withAttributes: [.font: font]).width)
                var color = accent ? NSColor.controlAccentColor : ink
                if faded { color = color.withAlphaComponent(0.45) }
                text(string, at: NSPoint(x: right - w, y: rect.midY), font: font, color: color)
                right -= w + 11
            case .symbol(let name):
                guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
                        .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) else { continue }
                let s = symbol.size
                symbol.draw(in: NSRect(x: right - s.width, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                right -= s.width + 11
            }
        }
        guard let app = app else { return }
        var x = rect.minX + 10
        let bold = NSFont.systemFont(ofSize: size, weight: .bold), regular = NSFont.systemFont(ofSize: size)
        for (index, menu) in ([app] + menus).enumerated() {
            let font = index == 0 ? bold : regular
            let w = ceil((menu as NSString).size(withAttributes: [.font: font]).width)
            guard x + w <= right - 6 else { break }
            text(menu, at: NSPoint(x: x, y: rect.midY), font: font, color: ink)
            x += w + 12
        }
    }

    @discardableResult
    static func text(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(at: NSPoint(x: point.x, y: point.y - size.height / 2), withAttributes: attributes)
        return ceil(size.width)
    }

    /// White label with a dark halo, readable on any wallpaper; on a window it uses the window's text color.
    static func caption(_ string: String, at point: NSPoint, small: Bool = false, dark: Bool = true, onWindow: Bool = false) {
        let font = NSFont.systemFont(ofSize: small ? 10.5 : 11.5, weight: .semibold)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if onWindow {
            attributes[.foregroundColor] = dark ? NSColor(white: 1, alpha: 0.7) : NSColor(white: 0, alpha: 0.6)
        } else {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = .zero
            attributes[.foregroundColor] = NSColor.white
            attributes[.shadow] = shadow
        }
        (string as NSString).draw(at: point, withAttributes: attributes)
    }

    static func titleBar(_ rect: NSRect, title: String, dark: Bool, small: Bool = false) {
        let d: CGFloat = small ? 8 : 9
        for (i, color) in [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1), NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                           NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.minX + 9 + CGFloat(i) * (d + 5), y: rect.midY - d / 2, width: d, height: d)).fill()
        }
        let font = NSFont.systemFont(ofSize: small ? 10.5 : 11, weight: .semibold)
        let color = dark ? NSColor(white: 1, alpha: 0.75) : NSColor(white: 0, alpha: 0.7)
        let w = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        text(title, at: NSPoint(x: rect.midX - w / 2, y: rect.midY), font: font, color: color)
    }

    static func window(_ rect: NSRect, dark: Bool, title: String, style: WindowStyle, alpha: CGFloat = 1) {
        shadowed(rect, radius: 8) {
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            let body = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.99, alpha: 1)).setFill()
            body.fill()
            let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 22)
            (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 8, yRadius: 8).fill()
            NSRect(x: bar.minX, y: bar.maxY - 8, width: bar.width, height: 8).fill()
            titleBar(bar, title: title, dark: dark)
            let content = NSRect(x: rect.minX + 12, y: bar.maxY + 10, width: rect.width - 24, height: rect.height - 44)
            let line = dark ? NSColor(white: 1, alpha: 0.22) : NSColor(white: 0, alpha: 0.13)
            switch style {
            case .text:
                var y = content.minY
                var i = 0
                while y + 5 < content.maxY {
                    line.setFill()
                    let w = content.width * [0.92, 0.78, 0.86, 0.6, 0.9, 0.7][i % 6]
                    NSBezierPath(roundedRect: NSRect(x: content.minX, y: y, width: w, height: 4), xRadius: 2, yRadius: 2).fill()
                    y += 11
                    i += 1
                }
            case .chart:
                let values: [CGFloat] = [0.35, 0.55, 0.42, 0.7, 0.62, 0.85, 0.5, 0.74]
                let barWidth = content.width / CGFloat(values.count) * 0.6
                for (i, v) in values.enumerated() {
                    let h = (content.height - 8) * v
                    let x = content.minX + CGFloat(i) * content.width / CGFloat(values.count)
                    [NSColor.systemBlue, NSColor.systemTeal, NSColor.systemIndigo][i % 3].withAlphaComponent(0.8).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: content.maxY - h, width: barWidth, height: h),
                                 xRadius: 2, yRadius: 2).fill()
                }
                let trend = NSBezierPath()
                for (i, v) in values.enumerated() {
                    let p = NSPoint(x: content.minX + (CGFloat(i) + 0.3) * content.width / CGFloat(values.count),
                                    y: content.maxY - (content.height - 8) * v - 10)
                    i == 0 ? trend.move(to: p) : trend.line(to: p)
                }
                NSColor.systemOrange.setStroke()
                trend.lineWidth = 2
                trend.stroke()
            case .files:
                let types: [UTType] = [.pdf, .png, .folder, .plainText, .movie, .spreadsheet]
                let cell: CGFloat = 52
                let columns = max(1, Int(content.width / cell))
                for (i, type) in types.enumerated() {
                    let column = i % columns, row = i / columns
                    let frame = NSRect(x: content.minX + CGFloat(column) * cell + 6, y: content.minY + CGFloat(row) * 54,
                                       width: 34, height: 34)
                    guard frame.maxY <= content.maxY + 6 else { break }
                    NSWorkspace.shared.icon(for: type).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                                                            respectFlipped: true, hints: nil)
                    line.setFill()
                    NSBezierPath(roundedRect: NSRect(x: frame.minX - 2, y: frame.maxY + 4, width: 38, height: 3.5),
                                 xRadius: 1.75, yRadius: 1.75).fill()
                }
            }
        }
    }

    static func shadowed(_ rect: NSRect, radius: CGFloat, draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        (NSColor.black.withAlphaComponent(0.01)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        if radius > 0 { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip() }
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func cursor(at point: NSPoint) {
        let cursor = NSCursor.arrow
        let image = cursor.image
        let hot = cursor.hotSpot
        image.draw(in: NSRect(x: point.x - hot.x, y: point.y - hot.y, width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// The part of a 2x canvas image under `rect` (points, y down).
    static func crop(_ image: NSImage, to rect: NSRect) -> CGImage? {
        guard let cg = (image.representations.first as? NSBitmapImageRep)?.cgImage else { return nil }
        let scale = CGFloat(cg.width) / image.size.width
        return cg.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale,
                                      height: rect.height * scale))
    }
}
