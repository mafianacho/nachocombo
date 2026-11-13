import Foundation

// Where the chat bubble sits next to the pet and how big it is. Foundation-only so the rules (follow the pet, flip
// below it at the top of the screen, stay on the pet's screen, size limits) are testable on any OS; the AppKit
// window (PetChatWindow) only applies the result.

/// The chat bubble's body (without the tail) in points. Saved in the settings when the user resizes it.
public struct PetChatSize: Codable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in screen points with the origin at the bottom left (AppKit screen coordinates).
public struct PetRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var minX: Double { x }
    public var maxX: Double { x + width }
    public var minY: Double { y }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
}

/// The chat window's place for one pet position: window origin (bottom left, the tail included), which side the
/// tail is on, and the tail's centre measured from the window's right edge.
public struct PetChatPlacement: Equatable {
    public var x: Double
    public var y: Double
    /// The chat is below the pet (not enough room above it), so the tail points up.
    public var tailOnTop: Bool
    public var tailFromRight: Double
}

/// The parts of the chat's edge the user can drag to resize it. The right edge is lined up with the pet and the tail
/// side touches the pet, so only the free sides move: the left edge, the edge away from the pet, and their corner.
public enum PetChatEdge: String, CaseIterable, Equatable {
    case left, top, bottom, topLeft, bottomLeft

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesTop: Bool { self == .top || self == .topLeft }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft }
}

public enum PetChatLayout {
    private typealias S = PetTokens.Size

    /// The confirmed design's bubble (360 × 520).
    public static let defaultSize = PetChatSize(width: S.chatWidth, height: S.chatHeight)
    /// Smallest body that still shows the header (avatar, name, status, tabs), a few log lines and the composer.
    public static let minimumSize = PetChatSize(width: 320, height: 420)
    /// Room kept between the chat and the screen's edges.
    public static let screenMargin: Double = PetTokens.Space.s
    static let tail: Double = S.chatTail
    static let gap: Double = S.chatGapToPet
    static let corner: Double = PetTokens.Radius.window

    /// The window's size for a body size: the tail adds to the height.
    public static func windowSize(_ body: PetChatSize) -> PetChatSize {
        PetChatSize(width: body.width, height: body.height + tail)
    }

    /// The largest body that fits in a screen's visible frame with the tail and the margins (never below the minimum).
    public static func maximumSize(screen: PetRect) -> PetChatSize {
        PetChatSize(width: max(minimumSize.width, screen.width - 2 * screenMargin),
                    height: max(minimumSize.height, screen.height - 2 * screenMargin - tail))
    }

    /// The saved size made safe: a hand-edited or broken value falls back, and the body fits the screen it is shown on.
    public static func clamp(_ size: PetChatSize?, screen: PetRect?) -> PetChatSize {
        guard let s = size, s.width.isFinite, s.height.isFinite else { return clamp(defaultSize, screen: screen) }
        var w = max(minimumSize.width, s.width), h = max(minimumSize.height, s.height)
        if let screen = screen {
            let most = maximumSize(screen: screen)
            w = min(w, most.width)
            h = min(h, most.height)
        }
        return PetChatSize(width: w.rounded(), height: h.rounded())
    }

    /// Above the pet with the tail on its head, right edges lined up; below the pet when it does not fit above;
    /// always inside the pet's screen. The same rule for opening the chat, following a dragged pet and resizing.
    public static func place(body: PetChatSize, pet: PetRect, screen: PetRect) -> PetChatPlacement {
        let size = windowSize(body)
        var x = pet.maxX - size.width
        var y = pet.maxY + gap
        let below = y + size.height > screen.maxY
        if below { y = pet.minY - size.height - gap }
        x = min(max(x, screen.minX + screenMargin), screen.maxX - size.width - screenMargin)
        y = min(max(y, screen.minY + screenMargin), screen.maxY - size.height - screenMargin)
        let tailFromRight = min(max(x + size.width - pet.midX, corner + tail), size.width - corner - tail)
        return PetChatPlacement(x: x, y: y, tailOnTop: below, tailFromRight: tailFromRight)
    }

    /// The edges that can be dragged for the current side of the pet (the tail side never moves).
    public static func resizableEdges(tailOnTop: Bool) -> [PetChatEdge] {
        tailOnTop ? [.left, .bottom, .bottomLeft] : [.left, .top, .topLeft]
    }

    /// The largest body while dragging an edge: as wide as the screen, and as tall as the room on the pet's current
    /// side, so the chat does not jump to the other side of the pet in the middle of a drag.
    public static func dragLimit(pet: PetRect, screen: PetRect, tailOnTop: Bool) -> PetChatSize {
        let most = maximumSize(screen: screen)
        let room = tailOnTop ? pet.minY - gap - tail - (screen.minY + screenMargin)
            : (screen.maxY - screenMargin) - (pet.maxY + gap) - tail
        return PetChatSize(width: most.width, height: min(most.height, max(minimumSize.height, room)))
    }

    /// The body after dragging `edge` by (dx, dy) points from the size the drag started with, within the limits.
    public static func resized(_ start: PetChatSize, edge: PetChatEdge, dx: Double, dy: Double, limit: PetChatSize) -> PetChatSize {
        var w = start.width, h = start.height
        if edge.movesLeft { w -= dx }
        if edge.movesTop { h += dy }
        if edge.movesBottom { h -= dy }
        w = min(max(w, minimumSize.width), max(minimumSize.width, limit.width))
        h = min(max(h, minimumSize.height), max(minimumSize.height, limit.height))
        return PetChatSize(width: w.rounded(), height: h.rounded())
    }

    /// The size worth saving: nil when it is the default, so a later design change of the default still applies.
    public static func saved(_ size: PetChatSize) -> PetChatSize? {
        size == defaultSize ? nil : size
    }
}
