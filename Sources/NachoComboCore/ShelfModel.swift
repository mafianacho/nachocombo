import Foundation

public enum ShelfItemKind: String, Equatable {
    case file, image, text, link
}

public struct ShelfItem: Equatable {
    public let id: UUID
    public let kind: ShelfItemKind
    /// Original file (kind == .file) or an app-owned copy (`ownsFile`), e.g. a dropped image or a promised file.
    public let fileURL: URL?
    /// Text of a snippet, or the address of a web link.
    public let text: String?
    /// True only for files the shelf itself created inside its own directory.
    public let ownsFile: Bool
    public let title: String

    public init(id: UUID = UUID(), kind: ShelfItemKind, fileURL: URL?, text: String?, ownsFile: Bool, title: String) {
        self.id = id; self.kind = kind; self.fileURL = fileURL; self.text = text; self.ownsFile = ownsFile; self.title = title
    }

    public var linkURL: URL? { kind == .link ? text.flatMap(URL.init(string:)) : nil }
}

/// In-memory shelf contents. The shelf never moves or deletes a user's original file:
/// removing an item only forgets it, and only files the shelf created itself are deleted.
/// The last removal (one item, or a whole clear) can be undone; the shelf's own copies of those items are deleted only
/// once that undo is no longer possible.
public final class ShelfStore {
    public private(set) var items: [ShelfItem] = []
    public let ownedDirectory: URL
    private var imageCounter = 0
    /// Items of the last removal, kept for undo (their owned files stay on disk until discarded).
    public private(set) var undoable: [ShelfItem] = []

    public init(ownedDirectory: URL) { self.ownedDirectory = ownedDirectory }

    public static func defaultOwnedDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NachoCombo", isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }

    @discardableResult
    public func addFile(_ url: URL) -> ShelfItem? {
        guard url.isFileURL else { return nil }
        let standard = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standard.path) else { return nil }
        if let existing = items.first(where: { $0.fileURL?.standardizedFileURL == standard && !$0.ownsFile }) {
            return existing
        }
        let item = ShelfItem(id: UUID(), kind: Self.kind(for: standard), fileURL: standard, text: nil,
                             ownsFile: false, title: standard.lastPathComponent)
        items.append(item)
        return item
    }

    /// A file the app itself wrote into `ownedDirectory` (e.g. a promised file from a browser or Photos).
    /// Anything outside that directory is refused, so the shelf can never come to own a user's file.
    @discardableResult
    public func addOwnedFile(_ url: URL) -> ShelfItem? {
        let standard = url.standardizedFileURL
        guard isInsideOwnedDirectory(standard), FileManager.default.fileExists(atPath: standard.path) else { return nil }
        let item = ShelfItem(id: UUID(), kind: Self.kind(for: standard), fileURL: standard, text: nil,
                             ownsFile: true, title: standard.lastPathComponent)
        items.append(item)
        return item
    }

    @discardableResult
    public func addText(_ raw: String) -> ShelfItem? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = items.first(where: { $0.kind == .text && $0.text == trimmed }) { return existing }
        let item = ShelfItem(id: UUID(), kind: .text, fileURL: nil, text: trimmed,
                             ownsFile: false, title: Self.titleForText(trimmed))
        items.append(item)
        return item
    }

    /// A web (or mail, ftp...) address. File URLs go through `addFile`.
    @discardableResult
    public func addLink(_ url: URL) -> ShelfItem? {
        guard !url.isFileURL, let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        let address = url.absoluteString
        if let existing = items.first(where: { $0.kind == .link && $0.text == address }) { return existing }
        let host = url.host ?? ""
        let title = host.isEmpty ? Self.titleForText(address) : host + (url.path.count > 1 ? url.path : "")
        let item = ShelfItem(id: UUID(), kind: .link, fileURL: nil, text: address, ownsFile: false,
                             title: Self.titleForText(title))
        items.append(item)
        return item
    }

    /// Stores dropped image bytes (no file URL available) as a PNG copy owned by the shelf.
    @discardableResult
    public func addImagePNG(_ data: Data) throws -> ShelfItem {
        try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
        imageCounter += 1
        let name = "image-\(UUID().uuidString.prefix(8).lowercased()).png"
        let url = ownedDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let item = ShelfItem(id: UUID(), kind: .image, fileURL: url.standardizedFileURL, text: nil,
                             ownsFile: true, title: "Image \(imageCounter).png")
        items.append(item)
        return item
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        stashForUndo([items.remove(at: index)])
        return true
    }

    public func clear() {
        guard !items.isEmpty else { return }
        let old = items
        items.removeAll()
        stashForUndo(old)
    }

    /// Puts the last removed items back (in their old order, after what is on the shelf now).
    @discardableResult
    public func undo() -> Bool {
        guard !undoable.isEmpty else { return false }
        items.append(contentsOf: undoable)
        undoable = []
        return true
    }

    /// Ends the chance to undo: deletes the shelf's own copies of the removed items.
    public func discardUndo() {
        let old = undoable
        undoable = []
        old.forEach(deleteIfOwned)
    }

    /// Deletes every shelf-created copy (OFF / quit). Originals are never touched.
    public func removeAllOwnedFiles() {
        let old = items
        items.removeAll()
        old.forEach(deleteIfOwned)
        discardUndo()
    }

    private func stashForUndo(_ removed: [ShelfItem]) {
        discardUndo()
        undoable = removed
    }

    private func isInsideOwnedDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(ownedDirectory.standardizedFileURL.path + "/")
    }

    private func deleteIfOwned(_ item: ShelfItem) {
        guard item.ownsFile, let url = item.fileURL, isInsideOwnedDirectory(url) else { return }   // never outside
        try? FileManager.default.removeItem(at: url)
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "bmp", "webp"]

    static func kind(for url: URL) -> ShelfItemKind {
        imageExtensions.contains(url.pathExtension.lowercased()) ? .image : .file
    }

    public static func titleForText(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}

/// Recognises the "shake while dragging" gesture: quick left-right reversals of the pointer.
public struct ShakeDetector {
    /// Horizontal travel that counts as one stroke (points).
    public var minimumStroke: CGFloat = 24
    /// Direction changes needed within `window` seconds.
    public var reversals = 3
    public var window: TimeInterval = 0.7

    private var anchorX: CGFloat?
    private var direction = 0
    private var turns: [TimeInterval] = []

    public init() {}

    public mutating func reset() {
        anchorX = nil
        direction = 0
        turns = []
    }

    /// Feeds one pointer position; returns true once when the shake is complete.
    public mutating func add(x: CGFloat, time: TimeInterval) -> Bool {
        guard let anchor = anchorX else { anchorX = x; return false }
        let delta = x - anchor
        let newDirection = delta > 0 ? 1 : -1
        if direction == 0 {
            if abs(delta) >= minimumStroke { direction = newDirection; anchorX = x }
            return false
        }
        if newDirection == direction {
            anchorX = x                    // still going the same way: follow the furthest point
            return false
        }
        guard abs(delta) >= minimumStroke else { return false }
        direction = newDirection
        anchorX = x
        turns.append(time)
        turns.removeAll { time - $0 > window }
        if turns.count >= reversals {
            reset()
            return true
        }
        return false
    }
}
