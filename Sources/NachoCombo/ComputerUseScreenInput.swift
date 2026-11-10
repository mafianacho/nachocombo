import AppKit
import ApplicationServices
import CoreGraphics
import NachoComboCore

// Screen capture and synthetic input. Not verified on a Mac yet (see ComputerUseBackend.swift).
//
// Screenshots use CGDisplayCreateImage / CGWindowListCreateImage on every macOS version, the same calls the
// existing screen-capture pinning module already uses. A ScreenCaptureKit path for macOS 12.3+ is intentionally not included yet:
// linking that framework could stop the whole app from launching on 12.0-12.2 and it cannot be tried on a Mac now.

extension MacComputerUseBackend {
    // MARK: screen

    private func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    func listDisplays() throws -> ToolResult {
        let main = CGMainDisplayID()
        let items: [JSONValue] = activeDisplays().map { id in
            let bounds = CGDisplayBounds(id)
            let pixelsWide = Double(CGDisplayPixelsWide(id))
            let scale = bounds.width > 0 ? pixelsWide / Double(bounds.width) : 1
            return .object(["displayId": .int(Int(id)), "main": .bool(id == main), "frame": rectJSON(bounds),
                            "scale": .double(scale)])
        }
        return json(.object(["displays": .array(items)]))
    }

    func capture(_ args: ToolArguments) throws -> ToolResult {
        try requireScreenRecording()
        let target = try args.string("target")
        let maxWidth = ScreenshotPolicy.clampMaxWidth(try args.optionalInt("maxWidth"))
        var image: CGImage?
        switch target {
        case "display":
            let requested = try args.optionalInt("displayId")
            let id = requested.map { CGDirectDisplayID(clamping: $0) } ?? CGMainDisplayID()
            guard activeDisplays().contains(id) else { throw PolicyError("Display not found") }
            image = CGDisplayCreateImage(id)
        case "window":
            let windowId = try args.int("windowId")
            guard windowId > 0, windowId <= Int(UInt32.max) else { throw ToolArgumentError("windowId is invalid") }
            image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(windowId), [.boundsIgnoreFraming, .bestResolution])
        case "region":
            let x = try args.double("x"), y = try args.double("y")
            let width = try args.double("width"), height = try args.double("height")
            try InputPolicy.validatePoint(x: x, y: y)
            guard width >= 1, height >= 1, width <= 20_000, height <= 20_000 else { throw ToolArgumentError("width/height is out of range") }
            image = CGWindowListCreateImage(CGRect(x: x, y: y, width: width, height: height), .optionOnScreenOnly,
                                            kCGNullWindowID, [.bestResolution])
        default:
            throw ToolArgumentError("target must be one of display, window, region")
        }
        guard let captured = image else { throw PolicyError("Could not capture (the target may not exist, or the permission may not have taken effect yet)") }
        let scaled = resized(captured, maxWidth: maxWidth)
        guard let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:]) else {
            throw PolicyError("Could not convert to PNG")
        }
        return ToolResult(content: [
            .image(base64: png.base64EncodedString(), mimeType: "image/png"),
            .text("\(scaled.width)x\(scaled.height) pixels (original \(captured.width)x\(captured.height))"),
        ])
    }

    private func resized(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth else { return image }
        let height = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage() ?? image
    }

    // MARK: input

    private var eventSource: CGEventSource? { CGEventSource(stateID: .hidSystemState) }

    private func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

    private func point(_ args: ToolArguments, _ xKey: String = "x", _ yKey: String = "y") throws -> CGPoint {
        let x = try args.double(xKey), y = try args.double(yKey)
        try InputPolicy.validatePoint(x: x, y: y)
        return CGPoint(x: x, y: y)
    }

    func mouseMove(_ args: ToolArguments) throws -> ToolResult {
        try requireAccessibility()
        let target = try point(args)
        post(CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left))
        return .text("Moved")
    }

    func mouseClick(_ args: ToolArguments) throws -> ToolResult {
        try requireAccessibility()
        let target = try point(args)
        let count = try InputPolicy.validateClickCount(try args.optionalInt("clickCount"))
        let name = try args.optionalString("button") ?? "left"
        let down: CGEventType, up: CGEventType, button: CGMouseButton
        switch name {
        case "left": down = .leftMouseDown; up = .leftMouseUp; button = .left
        case "right": down = .rightMouseDown; up = .rightMouseUp; button = .right
        case "middle": down = .otherMouseDown; up = .otherMouseUp; button = .center
        default: throw ToolArgumentError("button must be one of left, right, middle")
        }
        let source = eventSource
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left))
        usleep(20_000)
        for click in 1...count {
            let press = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: target, mouseButton: button)
            press?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            post(press)
            let release = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: target, mouseButton: button)
            release?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            post(release)
            usleep(30_000)
        }
        return .text("Clicked")
    }

    func mouseDrag(_ args: ToolArguments) throws -> ToolResult {
        try requireAccessibility()
        let from = try point(args, "fromX", "fromY")
        let to = try point(args, "toX", "toY")
        let source = eventSource
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left))
        usleep(20_000)
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let position = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: position, mouseButton: .left))
            usleep(10_000)
        }
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
        return .text("Dragged")
    }

    func mouseScroll(_ args: ToolArguments) throws -> ToolResult {
        try requireAccessibility()
        let rawDX = try args.optionalInt("deltaX") ?? 0
        let rawDY = try args.optionalInt("deltaY") ?? 0
        let dx = max(-10_000, min(10_000, rawDX))
        let dy = max(-10_000, min(10_000, rawDY))
        if dx == 0 && dy == 0 { throw ToolArgumentError("deltaX or deltaY is required") }
        if args.values["x"] != nil || args.values["y"] != nil {
            let target = try point(args)
            post(CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left))
            usleep(20_000)
        }
        post(CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                     wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0))
        return .text("Scrolled")
    }

    func keyPress(_ args: ToolArguments) throws -> ToolResult {
        try requireAccessibility()
        let name = try args.string("key")
        guard let code = KeyboardMap.keyCode(for: name) else { throw ToolArgumentError("Unknown key name") }
        let flags = CGEventFlags(rawValue: try KeyboardMap.modifierFlags(try args.stringList("modifiers")))
        pressKey(code, flags: flags)
        return .text("Pressed")
    }

    private func pressKey(_ code: UInt16, flags: CGEventFlags = []) {
        let source = eventSource
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
        down?.flags = flags
        post(down)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
        up?.flags = flags
        post(up)
        usleep(8_000)
    }

    /// Typed as Unicode strings in small chunks, so layout and IME do not matter. Never logged.
    func typeText(_ args: ToolArguments) throws -> ToolResult {
        try requireAccessibility()
        let text = try args.string("text")
        try InputPolicy.validateText(text)
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            let source = eventSource
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
            chunk.removeAll()
            usleep(8_000)
        }
        for character in text {
            if character == "\n" || character == "\r\n" { flush(); pressKey(36); continue }
            if character == "\t" { flush(); pressKey(48); continue }
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 16 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
        return .text("Typed")
    }
}
