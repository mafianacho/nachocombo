import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A window as reported by the window server (front-to-back order is the caller's contract).
public struct WindowSnapshot: Equatable {
    public let number: Int
    public let ownerPID: Int32
    public let layer: Int
    public let frame: CGRect
    public let alpha: Double

    public init(number: Int, ownerPID: Int32, layer: Int, frame: CGRect, alpha: Double) {
        self.number = number
        self.ownerPID = ownerPID
        self.layer = layer
        self.frame = frame
        self.alpha = alpha
    }
}

public enum FocusDimLogic {
    public static let minimumIntensity = 0.1
    public static let maximumIntensity = 0.9
    public static let defaultIntensity = 0.5
    /// Windows smaller than this (in either side) are treated as helpers, not as the working window.
    public static let minimumWindowSide: CGFloat = 32

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultIntensity }
        return min(maximumIntensity, max(minimumIntensity, value))
    }

    /// The window that stays bright: the top-most ordinary (layer 0) window of the frontmost app.
    /// `windows` must be ordered front to back; `excluding` removes our own overlay windows.
    public static func activeWindow(in windows: [WindowSnapshot], frontmostPID: Int32,
                                    excluding: Set<Int>) -> WindowSnapshot? {
        windows.first { w in
            w.ownerPID == frontmostPID
                && w.layer == 0
                && w.alpha > 0.01
                && !excluding.contains(w.number)
                && w.frame.width >= minimumWindowSide
                && w.frame.height >= minimumWindowSide
        }
    }

    /// True when `overlay` is behind `active` in a front-to-back list (dimming never covers the active window).
    public static func isBelow(_ overlay: Int, active: Int, in orderedNumbers: [Int]) -> Bool {
        guard let o = orderedNumbers.firstIndex(of: overlay),
              let a = orderedNumbers.firstIndex(of: active) else { return false }
        return o > a
    }
}
