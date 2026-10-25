import AppKit
import NachoComboCore

/// App-icon style artwork for the gadget gallery: a rounded square with a gradient and a small drawing of what the
/// gadget does. Drawn in code (a 100 × 100 design grid, y pointing down), so it is sharp at every size and needs no
/// bundled image files.
enum GadgetIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for id: ModuleID, size: CGFloat) -> NSImage {
        let key = "\(id.rawValue)@\(size)"
        if let cached = cache[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.scaleBy(x: rect.width / 100, y: rect.height / 100)
            draw(id, in: context)
            context.restoreGState()
            return true
        }
        image.accessibilityDescription = id.displayName
        cache[key] = image
        return image
    }

    // MARK: drawing

    private static let tile = CGRect(x: 6, y: 6, width: 88, height: 88)

    private static func draw(_ id: ModuleID, in context: CGContext) {
        let shape = NSBezierPath(roundedRect: tile, xRadius: 21, yRadius: 21)
        // Soft drop shadow under the tile, like an app icon resting on the window.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 5,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.black.setFill()
        shape.fill()
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let (top, bottom) = colors(for: id)
        NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: 90)   // flipped: 90° runs top to bottom
        // A faint top highlight gives the glossy edge app icons have.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))?
            .draw(in: CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: 34), angle: 90)
        switch id {
        case .menuBar: drawMenuBar()
        case .systemMonitor: drawMonitor()
        case .windowSnap: drawSnap()
        case .fileShelf: drawShelf()
        case .captureFloat: drawCapture()
        case .focusDim: drawDim()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 20.5, yRadius: 20.5)
        rim.lineWidth = 1
        rim.stroke()
    }

    private static func colors(for id: ModuleID) -> (NSColor, NSColor) {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch id {
        case .menuBar: return (rgb(0xD6ECFF), rgb(0x7DB8F7))
        case .systemMonitor: return (rgb(0x4A4A52), rgb(0x1C1C21))
        case .windowSnap: return (rgb(0x5EE0B0), rgb(0x119A74))
        case .fileShelf: return (rgb(0xFFC860), rgb(0xF27A1A))
        case .captureFloat: return (rgb(0xFF8FB1), rgb(0xD92A63))
        case .focusDim: return (rgb(0x8C86FF), rgb(0x4630C9))
        }
    }

    private static func fill(_ rect: CGRect, radius: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// A light window with a menu bar along the top: two icons stay, three fold away behind the divider.
    private static func drawMenuBar() {
        let blue = NSColor(srgbRed: 0.23, green: 0.47, blue: 0.95, alpha: 1)
        fill(CGRect(x: 16, y: 24, width: 68, height: 56), radius: 8, NSColor.white.withAlphaComponent(0.92))
        fill(CGRect(x: 16, y: 24, width: 68, height: 13), radius: 6, NSColor(white: 0.93, alpha: 1))
        // Folded icons (faded) | divider | visible icons.
        for (i, x) in [22.0, 30, 38].enumerated() {
            fill(CGRect(x: x, y: 28, width: 5.5, height: 5.5), radius: 2.75, blue.withAlphaComponent(0.22 + 0.08 * Double(i)))
        }
        NSColor(white: 0.55, alpha: 1).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 49, y: 26.5))
        divider.line(to: NSPoint(x: 49, y: 35))
        divider.lineWidth = 1.4
        divider.setLineDash([1.6, 1.6], count: 2, phase: 0)
        divider.stroke()
        fill(CGRect(x: 55, y: 28, width: 5.5, height: 5.5), radius: 2.75, blue)
        fill(CGRect(x: 64, y: 28, width: 5.5, height: 5.5), radius: 2.75, blue)
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: 78, y: 27.5))
        chevron.line(to: NSPoint(x: 74.5, y: 30.75))
        chevron.line(to: NSPoint(x: 78, y: 34))
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        blue.setStroke()
        chevron.stroke()
        // Content lines and a small chart, so it reads as a working desktop.
        for (i, width) in [34.0, 26, 30].enumerated() {
            fill(CGRect(x: 23, y: 44 + Double(i) * 7, width: width, height: 3.2), radius: 1.6,
                 [NSColor.systemBlue, NSColor.systemGreen, NSColor.systemOrange][i].withAlphaComponent(0.85))
        }
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 23, y: 72))
        line.curve(to: NSPoint(x: 50, y: 64), controlPoint1: NSPoint(x: 33, y: 64), controlPoint2: NSPoint(x: 40, y: 72))
        line.curve(to: NSPoint(x: 77, y: 58), controlPoint1: NSPoint(x: 60, y: 57), controlPoint2: NSPoint(x: 68, y: 66))
        line.lineWidth = 2.4
        line.lineCapStyle = .round
        blue.setStroke()
        line.stroke()
    }

    /// Ring gauge, bar graph and a line chart: the three chart kinds of the monitor panels.
    private static func drawMonitor() {
        let green = NSColor(srgbRed: 0.27, green: 0.85, blue: 0.62, alpha: 1)
        let blue = NSColor(srgbRed: 0.33, green: 0.62, blue: 1, alpha: 1)
        let orange = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1)
        let center = NSPoint(x: 33, y: 37)
        NSColor.white.withAlphaComponent(0.14).setStroke()
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: 11, startAngle: 0, endAngle: 360)
        track.lineWidth = 6
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: 11, startAngle: -90, endAngle: 160, clockwise: false)
        arc.lineWidth = 6
        arc.lineCapStyle = .round
        green.setStroke()
        arc.stroke()
        for (i, h) in [10.0, 16, 8, 20, 13, 22].enumerated() {
            fill(CGRect(x: 52 + Double(i) * 5.4, y: 48 - h, width: 3.4, height: h), radius: 1.2,
                 blue.withAlphaComponent(i == 5 ? 1 : 0.75))
        }
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 18, y: 74))
        wave.curve(to: NSPoint(x: 44, y: 66), controlPoint1: NSPoint(x: 27, y: 74), controlPoint2: NSPoint(x: 33, y: 64))
        wave.curve(to: NSPoint(x: 78, y: 62), controlPoint1: NSPoint(x: 56, y: 69), controlPoint2: NSPoint(x: 64, y: 71))
        wave.lineWidth = 3
        wave.lineCapStyle = .round
        orange.setStroke()
        wave.stroke()
        fill(CGRect(x: 75.5, y: 59.5, width: 6, height: 6), radius: 3, .white)
    }

    /// A screen with two windows snapped side by side.
    private static func drawSnap() {
        let screen = CGRect(x: 16, y: 22, width: 68, height: 50)
        fill(screen, radius: 7, NSColor.white.withAlphaComponent(0.28))
        fill(CGRect(x: 20, y: 26, width: 29, height: 42), radius: 4.5, NSColor.white.withAlphaComponent(0.95))
        fill(CGRect(x: 51, y: 26, width: 29, height: 42), radius: 4.5, NSColor.white.withAlphaComponent(0.6))
        for x in [23.0, 54] {
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                fill(CGRect(x: x + Double(i) * 4.2, y: 29, width: 2.8, height: 2.8), radius: 1.4, color)
            }
        }
        // Stand.
        fill(CGRect(x: 43, y: 72, width: 14, height: 5), radius: 1, NSColor.white.withAlphaComponent(0.5))
        fill(CGRect(x: 35, y: 77, width: 30, height: 3), radius: 1.5, NSColor.white.withAlphaComponent(0.6))
    }

    /// A tray holding two cards that stick out of it.
    private static func drawShelf() {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 40, yBy: 44)
        transform.rotate(byDegrees: -10)
        transform.concat()
        fill(CGRect(x: -12, y: -24, width: 24, height: 30), radius: 3.5, NSColor.white.withAlphaComponent(0.8))
        NSGraphicsContext.restoreGraphicsState()
        fill(CGRect(x: 47, y: 18, width: 24, height: 30), radius: 3.5, .white)
        for (i, w) in [14.0, 10, 12].enumerated() {
            fill(CGRect(x: 52, y: 25 + Double(i) * 5.5, width: w, height: 2.4), radius: 1.2,
                 NSColor(srgbRed: 0.95, green: 0.48, blue: 0.1, alpha: 0.7))
        }
        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: 18, y: 50))
        tray.line(to: NSPoint(x: 32, y: 50))
        tray.line(to: NSPoint(x: 36, y: 58))
        tray.line(to: NSPoint(x: 64, y: 58))
        tray.line(to: NSPoint(x: 68, y: 50))
        tray.line(to: NSPoint(x: 82, y: 50))
        tray.line(to: NSPoint(x: 82, y: 74))
        tray.curve(to: NSPoint(x: 76, y: 80), controlPoint1: NSPoint(x: 82, y: 78), controlPoint2: NSPoint(x: 80, y: 80))
        tray.line(to: NSPoint(x: 24, y: 80))
        tray.curve(to: NSPoint(x: 18, y: 74), controlPoint1: NSPoint(x: 20, y: 80), controlPoint2: NSPoint(x: 18, y: 78))
        tray.close()
        NSColor.white.setFill()
        tray.fill()
    }

    /// Viewfinder corners around a picture that floats with a pin.
    private static func drawCapture() {
        let corners = NSBezierPath()
        let r = CGRect(x: 18, y: 18, width: 64, height: 64)
        let l: CGFloat = 13
        for (p, dx, dy) in [(NSPoint(x: r.minX, y: r.minY), 1.0, 1.0), (NSPoint(x: r.maxX, y: r.minY), -1, 1),
                            (NSPoint(x: r.minX, y: r.maxY), 1, -1), (NSPoint(x: r.maxX, y: r.maxY), -1, -1)] {
            corners.move(to: NSPoint(x: p.x + dx * l, y: p.y))
            corners.line(to: p)
            corners.line(to: NSPoint(x: p.x, y: p.y + dy * l))
        }
        corners.lineWidth = 4.5
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        NSColor.white.setStroke()
        corners.stroke()
        let photo = CGRect(x: 29, y: 33, width: 42, height: 34)
        fill(photo, radius: 4, .white)
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 32, y: 64))
        mountain.line(to: NSPoint(x: 44, y: 49))
        mountain.line(to: NSPoint(x: 52, y: 58))
        mountain.line(to: NSPoint(x: 57, y: 53))
        mountain.line(to: NSPoint(x: 68, y: 64))
        mountain.close()
        NSColor(srgbRed: 0.85, green: 0.16, blue: 0.39, alpha: 0.75).setFill()
        mountain.fill()
        fill(CGRect(x: 58, y: 38, width: 7, height: 7), radius: 3.5, NSColor(srgbRed: 1, green: 0.75, blue: 0.2, alpha: 1))
        fill(CGRect(x: 47, y: 27, width: 6, height: 6), radius: 3, NSColor(srgbRed: 1, green: 0.27, blue: 0.27, alpha: 1))
    }

    /// Dimmed windows behind one bright front window.
    private static func drawDim() {
        fill(CGRect(x: 14, y: 20, width: 40, height: 32), radius: 4, NSColor.black.withAlphaComponent(0.28))
        fill(CGRect(x: 52, y: 56, width: 34, height: 26), radius: 4, NSColor.black.withAlphaComponent(0.28))
        let front = CGRect(x: 30, y: 34, width: 42, height: 34)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        fill(front, radius: 4.5, .white)
        NSGraphicsContext.restoreGraphicsState()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            fill(CGRect(x: 34 + Double(i) * 4.4, y: 37.5, width: 3, height: 3), radius: 1.5, color)
        }
        for (i, w) in [26.0, 20, 30].enumerated() {
            fill(CGRect(x: 35, y: 47 + Double(i) * 6, width: w, height: 2.6), radius: 1.3,
                 NSColor(srgbRed: 0.27, green: 0.19, blue: 0.79, alpha: 0.55))
        }
    }
}

/// The app's own icon (the bundle's AppIcon) for places inside the app: the menu bar item, the gallery and the quick
/// panel. The icon file keeps the usual transparent margin; `artwork` trims it so a small rendering fills its space.
enum AppIcon {
    static var image: NSImage { NSApp.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage() }

    private static var trimmed: NSImage?

    /// The artwork without the transparent margin, `height` points tall (width follows its shape).
    static func artwork(height: CGFloat) -> NSImage {
        let art = trimmed ?? trim()
        trimmed = art
        let width = art.size.height > 0 ? (height * art.size.width / art.size.height).rounded() : height
        let result = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            art.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        result.accessibilityDescription = "Nacho Combo"
        return result
    }

    /// Crops the icon to the bounding box of its visible pixels (rendered once at 512 px).
    private static func trim() -> NSImage {
        let side = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var minX = side, minY = side, maxX = -1, maxY = -1
        for y in 0..<side {
            for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY, let cg = rep.cgImage,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
