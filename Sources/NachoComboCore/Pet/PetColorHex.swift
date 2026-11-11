import Foundation

/// "#RRGGBB" / "#RRGGBBAA" design-token colors (design/tokens.json) as sRGB components, plus WCAG contrast.
public enum PetColorHex {
    public struct RGBA: Equatable {
        public var r: Double, g: Double, b: Double, a: Double
    }

    public static func parse(_ hex: String) -> RGBA? {
        guard hex.hasPrefix("#"), hex.count == 7 || hex.count == 9, let v = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        let full = hex.count == 7 ? (v << 8) | 0xFF : v
        return RGBA(r: Double((full >> 24) & 0xFF) / 255, g: Double((full >> 16) & 0xFF) / 255,
                    b: Double((full >> 8) & 0xFF) / 255, a: Double(full & 0xFF) / 255)
    }

    /// `top` over `bottom` (straight alpha); the result is opaque when `bottom` is.
    public static func over(_ top: RGBA, _ bottom: RGBA) -> RGBA {
        let a = top.a + bottom.a * (1 - top.a)
        guard a > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func c(_ t: Double, _ b: Double) -> Double { (t * top.a + b * bottom.a * (1 - top.a)) / a }
        return RGBA(r: c(top.r, bottom.r), g: c(top.g, bottom.g), b: c(top.b, bottom.b), a: a)
    }

    public static func luminance(_ c: RGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// Contrast of `fg` drawn on `bg`, where `bg` itself lies on `backdrop` (made opaque). 1…21.
    public static func contrast(_ fg: String, on bg: String, backdrop: String) -> Double {
        guard var base = parse(backdrop), let b = parse(bg), let f = parse(fg) else { return 0 }
        base.a = 1
        let back = over(b, base)
        let front = over(f, back)
        let l1 = luminance(front), l2 = luminance(back)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
