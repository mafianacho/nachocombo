import Foundation

public enum ShelfItemKind: String, Equatable {
    case file, image, text
}

public struct ShelfItem: Equatable {
    public let id: UUID
    public let kind: ShelfItemKind
    /// Original file (kind == .file) or an app-owned PNG copy (kind == .image, `ownsFile`).
    public let fileURL: URL?
    public let text: String?
    /// True only for files the shelf itself created inside its own directory.
    public let ownsFile: Bool
    public let title: String
}

/// In-memory shelf contents. The shelf never moves or deletes a user's original file:
/// removing an item only forgets it, and only files the shelf created itself are deleted.
public final class ShelfStore {
    public private(set) var items: [ShelfItem] = []
    public let ownedDirectory: URL
    private var imageCounter = 0

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
        let kind: ShelfItemKind = Self.imageExtensions.contains(standard.pathExtension.lowercased()) ? .image : .file
        let item = ShelfItem(id: UUID(), kind: kind, fileURL: standard, text: nil,
                             ownsFile: false, title: standard.lastPathComponent)
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

    /// Stores dropped image bytes (no file URL available) as a PNG copy owned by the shelf.
    @discardableResult
    public func addImagePNG(_ data: Data) throws -> ShelfItem {
        try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: true)
        imageCounter += 1
        let name = "image-\(UUID().uuidString.prefix(8).lowercased()).png"
        let url = ownedDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let item = ShelfItem(id: UUID(), kind: .image, fileURL: url.standardizedFileURL, text: nil,
                             ownsFile: true, title: "이미지 \(imageCounter).png")
        items.append(item)
        return item
    }

    @discardableResult
    public func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let item = items.remove(at: index)
        deleteIfOwned(item)
        return true
    }

    public func clear() {
        let old = items
        items.removeAll()
        old.forEach(deleteIfOwned)
    }

    /// Deletes shelf-created copies still on disk (OFF / quit). Originals are never touched.
    public func removeAllOwnedFiles() { clear() }

    private func deleteIfOwned(_ item: ShelfItem) {
        guard item.ownsFile, let url = item.fileURL else { return }
        let dir = ownedDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(dir + "/") else { return }   // never delete outside the shelf directory
        try? FileManager.default.removeItem(at: url)
    }

    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "bmp", "webp"]

    public static func titleForText(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
    }
}
