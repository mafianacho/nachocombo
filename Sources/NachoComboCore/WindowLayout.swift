import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum SnapAction: String, CaseIterable {
    case left, right, maximize

    public var displayName: String {
        switch self {
        case .left: return "왼쪽 절반"
        case .right: return "오른쪽 절반"
        case .maximize: return "최대화"
        }
    }
}

/// Carbon virtual key codes and modifier masks (kVK_*, controlKey, optionKey).
public struct HotKeySpec: Equatable {
    public let action: SnapAction
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let label: String

    public static let controlKey: UInt32 = 1 << 12
    public static let optionKey: UInt32 = 1 << 11

    public static let defaults: [HotKeySpec] = [
        HotKeySpec(action: .left, keyCode: 123, carbonModifiers: controlKey | optionKey, label: "⌃⌥←"),
        HotKeySpec(action: .right, keyCode: 124, carbonModifiers: controlKey | optionKey, label: "⌃⌥→"),
        HotKeySpec(action: .maximize, keyCode: 36, carbonModifiers: controlKey | optionKey, label: "⌃⌥↩"),
    ]
}

public enum WindowLayout {
    /// Target rectangle in Cocoa coordinates (origin bottom-left) inside `visible`.
    /// Integer rounding gives the right half the odd pixel so the halves never overlap or leave a gap.
    public static func target(for action: SnapAction, in visible: CGRect) -> CGRect {
        let halfWidth = (visible.width / 2).rounded(.down)
        switch action {
        case .left:
            return CGRect(x: visible.minX, y: visible.minY, width: halfWidth, height: visible.height)
        case .right:
            return CGRect(x: visible.minX + halfWidth, y: visible.minY,
                          width: visible.width - halfWidth, height: visible.height)
        case .maximize:
            return visible
        }
    }

    /// Result of an action inside a unit square (origin bottom-left), used for the panel preview.
    public static func previewFraction(for action: SnapAction) -> CGRect {
        switch action {
        case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
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
