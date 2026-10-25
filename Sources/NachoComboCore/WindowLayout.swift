import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Every window position the snap gadget offers. Raw values of the first three are kept from the first version
/// (debug channel `ctl snap left|right|maximize`).
public enum SnapAction: String, CaseIterable {
    case left, right, centerHalf = "center-half", topHalf = "top-half", bottomHalf = "bottom-half"
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"
    case firstThird = "first-third", centerThird = "center-third", lastThird = "last-third"
    case firstTwoThirds = "first-two-thirds", centerTwoThirds = "center-two-thirds", lastTwoThirds = "last-two-thirds"
    case maximize, almostMaximize = "almost-maximize", maximizeHeight = "maximize-height", center
    case smaller, larger, restore
    case nextDisplay = "next-display", previousDisplay = "previous-display"

    public var displayName: String {
        switch self {
        case .left: return "Left Half"
        case .right: return "Right Half"
        case .centerHalf: return "Center Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .centerTwoThirds: return "Center Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .maximizeHeight: return "Maximize Height"
        case .center: return "Center"
        case .smaller: return "Make Smaller"
        case .larger: return "Make Larger"
        case .restore: return "Restore"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        }
    }

    /// Positions the quick panel offers as one-click buttons (the rest stay on the keyboard).
    public static let panelChoices: [SnapAction] = [.left, .right, .maximize, .topLeft, .topRight, .bottomLeft,
                                                    .bottomRight, .firstThird, .centerThird, .lastThird, .center]

    /// Halves cycle through 1/2 → 2/3 → 1/3 when the same command is repeated.
    public var cycles: Bool { [.left, .right, .topHalf, .bottomHalf].contains(self) }
    /// Needs the window's current frame (not just the screen) to compute its target.
    public var dependsOnCurrentFrame: Bool { [.center, .maximizeHeight, .smaller, .larger].contains(self) }
}

/// Carbon virtual key codes and modifier masks (kVK_*, controlKey, optionKey).
public struct HotKeySpec: Equatable {
    public let action: SnapAction
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public static let commandKey: UInt32 = 1 << 8
    public static let shiftKey: UInt32 = 1 << 9
    public static let optionKey: UInt32 = 1 << 11
    public static let controlKey: UInt32 = 1 << 12

    public var label: String { KeyNames.label(keyCode: keyCode, modifiers: carbonModifiers) }

    /// The widely used ⌃⌥ layout of keyboard window managers: arrows for halves, U I J K for the corners,
    /// D F G for thirds, E R T for two thirds, Return to maximize, C to center, Delete to restore,
    /// ⌃⌥⌘ arrows for the neighbouring display.
    public static let defaults: [HotKeySpec] = {
        let co = controlKey | optionKey
        return [
            HotKeySpec(action: .left, keyCode: 123, carbonModifiers: co),
            HotKeySpec(action: .right, keyCode: 124, carbonModifiers: co),
            HotKeySpec(action: .topHalf, keyCode: 126, carbonModifiers: co),
            HotKeySpec(action: .bottomHalf, keyCode: 125, carbonModifiers: co),
            HotKeySpec(action: .topLeft, keyCode: 32, carbonModifiers: co),
            HotKeySpec(action: .topRight, keyCode: 34, carbonModifiers: co),
            HotKeySpec(action: .bottomLeft, keyCode: 38, carbonModifiers: co),
            HotKeySpec(action: .bottomRight, keyCode: 40, carbonModifiers: co),
            HotKeySpec(action: .firstThird, keyCode: 2, carbonModifiers: co),
            HotKeySpec(action: .centerThird, keyCode: 3, carbonModifiers: co),
            HotKeySpec(action: .lastThird, keyCode: 5, carbonModifiers: co),
            HotKeySpec(action: .firstTwoThirds, keyCode: 14, carbonModifiers: co),
            HotKeySpec(action: .centerTwoThirds, keyCode: 15, carbonModifiers: co),
            HotKeySpec(action: .lastTwoThirds, keyCode: 17, carbonModifiers: co),
            HotKeySpec(action: .maximize, keyCode: 36, carbonModifiers: co),
            HotKeySpec(action: .maximizeHeight, keyCode: 126, carbonModifiers: co | shiftKey),
            HotKeySpec(action: .center, keyCode: 8, carbonModifiers: co),
            HotKeySpec(action: .smaller, keyCode: 27, carbonModifiers: co),
            HotKeySpec(action: .larger, keyCode: 24, carbonModifiers: co),
            HotKeySpec(action: .restore, keyCode: 51, carbonModifiers: co),
            HotKeySpec(action: .nextDisplay, keyCode: 124, carbonModifiers: co | commandKey),
            HotKeySpec(action: .previousDisplay, keyCode: 123, carbonModifiers: co | commandKey),
        ]
    }()

    public static func spec(for action: SnapAction) -> HotKeySpec? { defaults.first { $0.action == action } }
}

public enum WindowLayout {
    /// Proportions of one half when a half command is repeated: 1/2 → 2/3 → 1/3 → 1/2.
    public static let cycleFractions: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]
    /// "Make smaller / larger" step on each side, in points.
    public static let resizeStep: CGFloat = 30
    /// "Almost maximize" share of the screen in each direction.
    public static let almostMaximizeFraction: CGFloat = 0.9
    /// Frames closer than this count as the same (apps round sizes to their own grid).
    public static let matchTolerance: CGFloat = 4

    /// Target rectangle in Cocoa coordinates (origin bottom-left) inside `visible`, without gaps and without cycling.
    /// Integer rounding gives the second part the odd pixel so neighbours never overlap or leave a gap.
    public static func target(for action: SnapAction, in visible: CGRect) -> CGRect {
        target(for: action, in: visible, current: nil, gap: 0, cycle: false)
    }

    /// Target rectangle for `action`. `current` is the window's frame now (Cocoa coordinates): it drives
    /// center / maximize height / smaller / larger and, with `cycle`, the 1/2 → 2/3 → 1/3 sequence of the halves.
    /// `gap` leaves that much space at the screen edges and between neighbouring windows.
    /// Restore and display moves are not layouts; they return `current` (or `visible`) unchanged.
    public static func target(for action: SnapAction, in visible: CGRect, current: CGRect?,
                              gap: CGFloat, cycle: Bool) -> CGRect {
        if action.cycles, cycle, let current = current {
            for (index, fraction) in cycleFractions.enumerated() {
                let candidate = applyGap(base(for: action, in: visible, fraction: fraction), in: visible, gap: gap)
                if matches(current, candidate) {
                    let next = cycleFractions[(index + 1) % cycleFractions.count]
                    return applyGap(base(for: action, in: visible, fraction: next), in: visible, gap: gap)
                }
            }
        }
        switch action {
        case .center:
            let size = current?.size ?? CGSize(width: visible.width / 2, height: visible.height / 2)
            let w = min(size.width, visible.width), h = min(size.height, visible.height)
            return CGRect(x: (visible.midX - w / 2).rounded(), y: (visible.midY - h / 2).rounded(), width: w, height: h)
        case .maximizeHeight:
            let frame = current ?? visible
            return applyGap(CGRect(x: frame.minX, y: visible.minY, width: min(frame.width, visible.width),
                                   height: visible.height), in: visible, gap: gap, horizontal: false)
        case .smaller, .larger:
            guard let frame = current else { return visible }
            return resized(frame, in: visible, grow: action == .larger)
        case .restore, .nextDisplay, .previousDisplay:
            return current ?? visible
        default:
            return applyGap(base(for: action, in: visible, fraction: 0.5), in: visible, gap: gap)
        }
    }

    /// Layout before gaps. `fraction` is the share of the half commands (1/2, or 2/3 / 1/3 while cycling).
    private static func base(for action: SnapAction, in v: CGRect, fraction: CGFloat) -> CGRect {
        let portrait = v.height > v.width
        func columns(_ start: CGFloat, _ length: CGFloat) -> CGRect {
            // Thirds run top to bottom on a portrait screen (first = top), left to right otherwise.
            // The tiny epsilon keeps 1/6 + 2/3 from flooring to one point short of 5/6.
            if portrait {
                let y0 = (v.height * start + 1e-6).rounded(.down), y1 = (v.height * (start + length) + 1e-6).rounded(.down)
                return CGRect(x: v.minX, y: v.maxY - y1, width: v.width, height: y1 - y0)
            }
            let x0 = (v.width * start + 1e-6).rounded(.down), x1 = (v.width * (start + length) + 1e-6).rounded(.down)
            return CGRect(x: v.minX + x0, y: v.minY, width: x1 - x0, height: v.height)
        }
        let halfW = (v.width / 2).rounded(.down), halfH = (v.height / 2).rounded(.down)
        // The right / top part is the remainder of its complement, so it gets the odd pixel and meets the
        // left / bottom part of the same split exactly.
        let partW = (v.width * fraction).rounded(.down), partH = (v.height * fraction).rounded(.down)
        let restW = v.width - (v.width * (1 - fraction)).rounded(.down)
        let restH = v.height - (v.height * (1 - fraction)).rounded(.down)
        switch action {
        case .left: return CGRect(x: v.minX, y: v.minY, width: partW, height: v.height)
        case .right: return CGRect(x: v.maxX - restW, y: v.minY, width: restW, height: v.height)
        case .topHalf: return CGRect(x: v.minX, y: v.maxY - restH, width: v.width, height: restH)
        case .bottomHalf: return CGRect(x: v.minX, y: v.minY, width: v.width, height: partH)
        case .centerHalf:
            return CGRect(x: v.minX + (v.width / 4).rounded(.down), y: v.minY, width: halfW, height: v.height)
        case .topLeft: return CGRect(x: v.minX, y: v.minY + halfH, width: halfW, height: v.height - halfH)
        case .topRight: return CGRect(x: v.minX + halfW, y: v.minY + halfH, width: v.width - halfW, height: v.height - halfH)
        case .bottomLeft: return CGRect(x: v.minX, y: v.minY, width: halfW, height: halfH)
        case .bottomRight: return CGRect(x: v.minX + halfW, y: v.minY, width: v.width - halfW, height: halfH)
        case .firstThird: return columns(0, 1.0 / 3)
        case .centerThird: return columns(1.0 / 3, 1.0 / 3)
        case .lastThird: return columns(2.0 / 3, 1.0 / 3)
        case .firstTwoThirds: return columns(0, 2.0 / 3)
        case .centerTwoThirds: return columns(1.0 / 6, 2.0 / 3)
        case .lastTwoThirds: return columns(1.0 / 3, 2.0 / 3)
        case .almostMaximize:
            let w = (v.width * almostMaximizeFraction).rounded(), h = (v.height * almostMaximizeFraction).rounded()
            return CGRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h)
        default: return v
        }
    }

    /// Insets by the full gap on a side that touches the screen edge and by half of it on an inner side,
    /// so two neighbours end up exactly one gap apart.
    public static func applyGap(_ rect: CGRect, in visible: CGRect, gap: CGFloat, horizontal: Bool = true) -> CGRect {
        guard gap > 0 else { return rect }
        func inset(_ touchesEdge: Bool) -> CGFloat { touchesEdge ? gap : gap / 2 }
        let left = horizontal ? inset(abs(rect.minX - visible.minX) < 1) : 0
        let right = horizontal ? inset(abs(rect.maxX - visible.maxX) < 1) : 0
        let bottom = inset(abs(rect.minY - visible.minY) < 1)
        let top = inset(abs(rect.maxY - visible.maxY) < 1)
        return CGRect(x: rect.minX + left, y: rect.minY + bottom,
                      width: max(1, rect.width - left - right), height: max(1, rect.height - bottom - top))
    }

    /// Grows or shrinks by `resizeStep` on every side, staying inside the screen and above a quarter of it.
    public static func resized(_ frame: CGRect, in visible: CGRect, grow: Bool) -> CGRect {
        let step = grow ? resizeStep : -resizeStep
        let minW = (visible.width / 4).rounded(), minH = (visible.height / 4).rounded()
        var w = min(visible.width, max(minW, frame.width + 2 * step))
        var h = min(visible.height, max(minH, frame.height + 2 * step))
        if !grow { w = min(w, frame.width); h = min(h, frame.height) }
        var x = frame.midX - w / 2, y = frame.midY - h / 2
        x = min(max(x, visible.minX), visible.maxX - w)
        y = min(max(y, visible.minY), visible.maxY - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
    }

    /// Same place and proportions on another screen (used by next / previous display).
    public static func move(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return frame }
        let sx = destination.width / source.width, sy = destination.height / source.height
        let w = min(destination.width, (frame.width * sx).rounded()), h = min(destination.height, (frame.height * sy).rounded())
        var x = destination.minX + ((frame.minX - source.minX) * sx).rounded()
        var y = destination.minY + ((frame.minY - source.minY) * sy).rounded()
        x = min(max(x, destination.minX), destination.maxX - w)
        y = min(max(y, destination.minY), destination.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Screen after (or before) `index` in left-to-right, then top-to-bottom order, wrapping around.
    public static func adjacentScreen(of index: Int, screens: [CGRect], forward: Bool) -> Int? {
        guard screens.count > 1, screens.indices.contains(index) else { return nil }
        let order = screens.indices.sorted {
            screens[$0].minX != screens[$1].minX ? screens[$0].minX < screens[$1].minX : screens[$0].maxY > screens[$1].maxY
        }
        guard let position = order.firstIndex(of: index) else { return nil }
        let next = (position + (forward ? 1 : order.count - 1)) % order.count
        return order[next]
    }

    public static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= matchTolerance && abs(a.minY - b.minY) <= matchTolerance
            && abs(a.width - b.width) <= matchTolerance && abs(a.height - b.height) <= matchTolerance
    }

    /// Result of an action inside a unit square (origin bottom-left), used for the panel preview.
    public static func previewFraction(for action: SnapAction) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch action {
        case .center: return CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        case .maximizeHeight: return CGRect(x: 0.3, y: 0, width: 0.4, height: 1)
        case .smaller: return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        case .larger: return CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
        case .restore, .nextDisplay, .previousDisplay: return CGRect(x: 0.15, y: 0.2, width: 0.55, height: 0.6)
        default:
            // Unit square scaled ×1000 so the integer rounding of the real layout does not show.
            let big = CGRect(x: 0, y: 0, width: 1000, height: 600)
            let r = base(for: action, in: big, fraction: 0.5)
            return CGRect(x: r.minX / big.width, y: r.minY / big.height, width: r.width / big.width,
                          height: r.height / big.height).intersection(unit)
        }
    }

    /// Accessibility API uses a top-left origin anchored at the primary display.
    public static func accessibilityOrigin(forCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX, y: primaryScreenHeight - rect.maxY)
    }

    public static func cocoaRect(fromAccessibilityOrigin origin: CGPoint, size: CGSize,
                                 primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: origin.x, y: primaryScreenHeight - origin.y - size.height,
               width: size.width, height: size.height)
    }

    /// Index of the screen sharing the largest area with `window`; falls back to the nearest centre.
    public static func screenIndex(for window: CGRect, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        var best = 0
        var bestArea: CGFloat = -1
        for (index, screen) in screens.enumerated() {
            let inter = screen.intersection(window)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; best = index }
        }
        if bestArea > 0 { return best }
        let cx = window.midX, cy = window.midY
        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (index, screen) in screens.enumerated() {
            let d = hypot(screen.midX - cx, screen.midY - cy)
            if d < nearestDistance { nearestDistance = d; nearest = index }
        }
        return nearest
    }
}

/// Drag-to-snap: where a window dragged with the pointer would land when it is released at `point`.
public enum SnapZones {
    /// Distance from a screen edge that counts as "at the edge" (points).
    public static let edge: CGFloat = 5
    /// Length along an edge, from a corner, that gives a quarter.
    public static let corner: CGFloat = 20
    /// Length along a side edge, beyond the corner, that gives the top / bottom half.
    public static let halfBand: CGFloat = 145

    /// The action for a pointer at `point` (Cocoa coordinates) on a screen whose full frame is `screen`, or nil when
    /// the pointer is not at an edge:
    /// corners → quarters; left / right edge → halves (near a corner → top / bottom half); top edge → maximize;
    /// bottom edge → first / center / last third by position (bottom half on a portrait screen).
    public static func action(at point: CGPoint, screen: CGRect) -> SnapAction? {
        guard point.x >= screen.minX - 1, point.x <= screen.maxX + 1,
              point.y >= screen.minY - 1, point.y <= screen.maxY + 1 else { return nil }
        let fromLeft = point.x - screen.minX, fromRight = screen.maxX - point.x
        let fromBottom = point.y - screen.minY, fromTop = screen.maxY - point.y
        let atLeft = fromLeft <= edge, atRight = fromRight <= edge
        let atBottom = fromBottom <= edge, atTop = fromTop <= edge
        guard atLeft || atRight || atBottom || atTop else { return nil }
        if (atLeft && fromTop <= corner) || (atTop && fromLeft <= corner) { return .topLeft }
        if (atRight && fromTop <= corner) || (atTop && fromRight <= corner) { return .topRight }
        if (atLeft && fromBottom <= corner) || (atBottom && fromLeft <= corner) { return .bottomLeft }
        if (atRight && fromBottom <= corner) || (atBottom && fromRight <= corner) { return .bottomRight }
        if atLeft || atRight {
            if fromTop <= corner + halfBand { return .topHalf }
            if fromBottom <= corner + halfBand { return .bottomHalf }
            return atLeft ? .left : .right
        }
        if atTop { return .maximize }
        // Bottom edge. Thirds stack vertically on a portrait screen, so there it gives the bottom half instead.
        if screen.height > screen.width { return .bottomHalf }
        let third = screen.width / 3
        if fromLeft < third { return .firstThird }
        if fromLeft < 2 * third { return .centerThird }
        return .lastThird
    }
}
