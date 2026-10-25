import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum RegionSelection {
    public static let minimumSide: CGFloat = 8

    /// Normalised rectangle for a drag from `a` to `b` (any direction).
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public static func isCapturable(_ rect: CGRect) -> Bool {
        rect.width >= minimumSide && rect.height >= minimumSide
    }

    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let r = rect.intersection(bounds)
        return r.isNull ? .zero : r
    }

    /// Cocoa (bottom-left origin) screen rect -> CoreGraphics global display rect (top-left origin at the primary display).
    public static func captureRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

public enum FloatSizing {
    public static let minimumWidth: CGFloat = 48

    /// Size for a requested width that keeps the original aspect ratio and stays within [minimumWidth, max].
    public static func resized(original: CGSize, proposedWidth: CGFloat, max maxSize: CGSize) -> CGSize {
        guard original.width > 0, original.height > 0 else { return CGSize(width: minimumWidth, height: minimumWidth) }
        let aspect = original.width / original.height
        let minimumWidthForHeight = minimumWidth   // height >= minimumWidth / aspect follows from the aspect ratio
        var width = Swift.max(minimumWidthForHeight, proposedWidth)
        if maxSize.width > 0 { width = Swift.min(width, maxSize.width) }
        if maxSize.height > 0 { width = Swift.min(width, maxSize.height * aspect) }
        width = Swift.max(width, 1)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    public static func scaled(_ size: CGSize, percent: Double) -> CGSize {
        CGSize(width: (size.width * CGFloat(percent) / 100).rounded(),
               height: (size.height * CGFloat(percent) / 100).rounded())
    }
}
