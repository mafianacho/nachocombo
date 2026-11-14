import Foundation

// NACHO-38: desktop tidy-up. Looks at the files directly on the desktop, plans where each would go
// (`정리됨/<category>/`), moves them when the user approved the plan, keeps a journal for one-step undo.
// Core only (Foundation, no AppKit), so it runs in Linux tests with a temporary folder as the desktop.
//
// Rules this file keeps (tests: DesktopTidyTests):
//  - Only plain files directly on the desktop are touched: no folders, app bundles, symlinks, hidden files,
//    downloads in progress, nothing changed in the last 2 minutes.
//  - Files are only ever MOVED (`FileManager.moveItem`, which refuses to overwrite). Nothing here removes a file.
//  - A name clash gets a number (`name 2.ext`). Undo never overwrites either.
//  - The journal holds the paths (so undo works); logs get counts only, and this file does not log at all.

/// Where a desktop file goes.
public enum DesktopCategory: String, CaseIterable, Codable {
    case screenshot
    case image
    case document
    case archive
    case installer
    case other

    /// Folder under `정리됨`.
    public var folderName: String {
        switch self {
        case .screenshot: return "스크린샷"
        case .image: return "이미지"
        case .document: return "문서"
        case .archive: return "압축"
        case .installer: return "설치 파일"
        case .other: return "기타"
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp", "svg"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers",
                                                  "txt", "md", "rtf", "csv", "hwp", "hwpx"]
    static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg"]
    static let screenshotPrefixes = ["스크린샷 ", "Screenshot ", "Screen Shot "]

    /// First match wins: screenshot, image, document, archive, installer, other. The name is compared in its
    /// precomposed form (the Finder may hand Korean names decomposed).
    public static func classify(name: String) -> DesktopCategory {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let composed = name.precomposedStringWithCanonicalMapping
            if screenshotPrefixes.contains(where: { composed.hasPrefix($0.precomposedStringWithCanonicalMapping) }) { return .screenshot }
            return .image
        }
        if documentExtensions.contains(ext) { return .document }
        if archiveExtensions.contains(ext) { return .archive }
        if installerExtensions.contains(ext) { return .installer }
        return .other
    }
}

/// One file a plan would move.
public struct DesktopTidyCandidate: Equatable {
    public let name: String
    public let category: DesktopCategory
    let size: Int64
    let modified: Date
}

public struct DesktopTidyPlan: Equatable {
    public let id: String
    public let createdAt: Date
    public let expiresAt: Date
    public let candidates: [DesktopTidyCandidate]
    /// Files on the desktop the rules leave alone (folders are not counted).
    public let skippedCount: Int

    public var total: Int { candidates.count }

    public var counts: [DesktopCategory: Int] {
        var out: [DesktopCategory: Int] = [:]
        for c in candidates { out[c.category, default: 0] += 1 }
        return out
    }
}

public struct DesktopTidyMoveRecord: Equatable, Codable {
    public let from: String
    public let to: String
}

public struct DesktopTidySkip: Equatable {
    public let name: String
    /// `missing`, `changed`, `recent`, `not_a_file`, `move_failed`.
    public let reason: String
}

public struct DesktopTidyApplied: Equatable {
    public let tidyID: String?
    public let moves: [DesktopTidyMoveRecord]
    public let skipped: [DesktopTidySkip]
    public let counts: [DesktopCategory: Int]
    /// False when the journal could not be written: the files were moved but undo cannot restore them.
    public let journalSaved: Bool
}

public struct DesktopTidyUndoSkip: Equatable {
    public let name: String
    /// `conflict` (another file sits at the original place), `not_found` (the moved file is gone), `invalid_record`, `move_failed`.
    public let reason: String
}

public struct DesktopTidyUndone: Equatable {
    public let tidyID: String
    public let restored: Int
    public let notRestored: [DesktopTidyUndoSkip]
    /// True when nothing is left to restore for this tidy (all restored, or the rest is gone).
    public let complete: Bool
}

public struct DesktopTidyHistoryRow: Equatable {
    public let tidyID: String
    public let at: Date
    public let count: Int
    public let undone: Bool
    /// Files still waiting to be restored after a partial undo.
    public let pendingRestore: Int
}

public enum DesktopTidyError: Error, Equatable {
    case desktopUnreadable
    case planNotFound
    case planStale
    case tidyNotFound
    case alreadyUndone
    case nothingToUndo

    public var reason: String {
        switch self {
        case .desktopUnreadable: return "desktop_unreadable"
        case .planNotFound: return "plan_not_found"
        case .planStale: return "plan_stale"
        case .tidyNotFound: return "tidy_not_found"
        case .alreadyUndone: return "already_undone"
        case .nothingToUndo: return "nothing_to_undo"
        }
    }
}

public final class DesktopTidyEngine {
    public static let folderName = "정리됨"
    /// Files changed more recently than this are left alone (still being written or just saved).
    public static let recentSeconds: TimeInterval = 120
    public static let planLifetime: TimeInterval = 600
    public static let journalDays = 30
    /// File names a plan lists; the rest is only counted.
    public static let maxListedNames = 50
    static let downloadExtensions: Set<String> = ["download", "crdownload", "part"]
    static let maxStoredPlans = 8

    public let desktop: URL
    public let journalURL: URL
    private let now: () -> Date
    private let fm: FileManager
    private let lock = NSLock()
    private var plans: [String: DesktopTidyPlan] = [:]

    /// `~/Library/Application Support/NachoCombo/desktop-tidy/journal.json`
    public static var defaultJournalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NachoCombo", isDirectory: true)
            .appendingPathComponent("desktop-tidy", isDirectory: true)
            .appendingPathComponent("journal.json")
    }

    public static var defaultDesktop: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    public init(desktop: URL = DesktopTidyEngine.defaultDesktop, journalURL: URL = DesktopTidyEngine.defaultJournalURL,
                now: @escaping () -> Date = { Date() }, fileManager: FileManager = .default) {
        self.desktop = desktop
        self.journalURL = journalURL
        self.now = now
        self.fm = fileManager
    }

    // MARK: rules

    private struct Stat {
        let isRegularFile: Bool
        let size: Int64
        let modified: Date?
    }

    private func inspect(_ path: String) -> Stat? {
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let type = attrs[.type] as? FileAttributeType
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return Stat(isRegularFile: type == .typeRegular, size: size, modified: attrs[.modificationDate] as? Date)
    }

    /// Why a desktop entry is left alone, nil when it may be moved.
    private func skipReason(name: String, stat: Stat?, at moment: Date) -> String? {
        guard let st = stat else { return "missing" }
        if name.hasPrefix(".") || !st.isRegularFile { return "not_a_file" }
        if DesktopTidyEngine.downloadExtensions.contains((name as NSString).pathExtension.lowercased()) { return "recent" }
        guard let modified = st.modified, moment.timeIntervalSince(modified) >= DesktopTidyEngine.recentSeconds else { return "recent" }
        return nil
    }

    private func desktopPath(_ name: String) -> String { desktop.appendingPathComponent(name).path }

    // MARK: plan

    /// Looks at the desktop and keeps a plan for 10 minutes. Moves nothing.
    public func plan() -> Result<DesktopTidyPlan, DesktopTidyError> {
        guard let names = try? fm.contentsOfDirectory(atPath: desktop.path) else { return .failure(.desktopUnreadable) }
        let moment = now()
        var candidates: [DesktopTidyCandidate] = []
        var skipped = 0
        for name in names.sorted() {
            let st = inspect(desktopPath(name))
            if skipReason(name: name, stat: st, at: moment) != nil {
                // Folders, bundles, links and hidden files are not "skipped files": they are not the tool's business.
                if let s = st, s.isRegularFile, !name.hasPrefix(".") { skipped += 1 }
                continue
            }
            guard let s = st, let modified = s.modified else { continue }
            candidates.append(DesktopTidyCandidate(name: name, category: DesktopCategory.classify(name: name), size: s.size, modified: modified))
        }
        let plan = DesktopTidyPlan(id: DesktopTidyEngine.newID(), createdAt: moment,
                                   expiresAt: moment.addingTimeInterval(DesktopTidyEngine.planLifetime),
                                   candidates: candidates, skippedCount: skipped)
        lock.lock()
        plans = plans.filter { $0.value.expiresAt > moment }
        if plans.count >= DesktopTidyEngine.maxStoredPlans, let oldest = plans.min(by: { $0.value.createdAt < $1.value.createdAt }) {
            plans[oldest.key] = nil
        }
        if !candidates.isEmpty { plans[plan.id] = plan }
        lock.unlock()
        return .success(plan)
    }

    static func newID() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased() }

    // MARK: apply

    /// Runs a plan once. Every file is checked again right before it moves; a file changed since the plan is skipped.
    public func apply(planID: String) -> Result<DesktopTidyApplied, DesktopTidyError> {
        let moment = now()
        lock.lock()
        let found = plans[planID]
        if found != nil { plans[planID] = nil }
        lock.unlock()
        guard let plan = found else { return .failure(.planNotFound) }
        guard plan.expiresAt > moment else { return .failure(.planStale) }

        var moves: [DesktopTidyMoveRecord] = []
        var skipped: [DesktopTidySkip] = []
        var counts: [DesktopCategory: Int] = [:]
        for item in plan.candidates {
            let from = desktopPath(item.name)
            let st = inspect(from)
            if let why = skipReason(name: item.name, stat: st, at: moment) {
                skipped.append(DesktopTidySkip(name: item.name, reason: why))
                continue
            }
            guard let current = st, current.size == item.size, current.modified == item.modified else {
                skipped.append(DesktopTidySkip(name: item.name, reason: "changed"))
                continue
            }
            let folder = desktop.appendingPathComponent(DesktopTidyEngine.folderName, isDirectory: true)
                .appendingPathComponent(item.category.folderName, isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = uniqueTarget(for: item.name, in: folder)
                try fm.moveItem(atPath: from, toPath: target.path)
                moves.append(DesktopTidyMoveRecord(from: from, to: target.path))
                counts[item.category, default: 0] += 1
            } catch {
                skipped.append(DesktopTidySkip(name: item.name, reason: "move_failed"))
            }
        }
        guard !moves.isEmpty else {
            return .success(DesktopTidyApplied(tidyID: nil, moves: [], skipped: skipped, counts: [:], journalSaved: true))
        }
        let tidyID = DesktopTidyEngine.newID()
        lock.lock()
        var journal = loadJournal(at: moment)
        journal.entries.append(JournalEntry(tidyID: tidyID, at: DesktopTidyEngine.iso(moment), moves: moves, total: moves.count, undoneAt: nil))
        let saved = saveJournal(journal)
        lock.unlock()
        return .success(DesktopTidyApplied(tidyID: tidyID, moves: moves, skipped: skipped, counts: counts, journalSaved: saved))
    }

    /// `name`, then `name 2.ext`, `name 3.ext` … The first free name in the folder (nothing is overwritten).
    func uniqueTarget(for name: String, in folder: URL) -> URL {
        func taken(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
        let first = folder.appendingPathComponent(name)
        if !taken(first) { return first }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while n < 10_000 {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !taken(candidate) { return candidate }
            n += 1
        }
        return folder.appendingPathComponent("\(base) \(DesktopTidyEngine.newID())" + (ext.isEmpty ? "" : ".\(ext)"))
    }

    // MARK: undo

    /// Puts the files of one tidy (default: the latest one not undone) back where they were. A file whose old place is
    /// taken stays where it is and is reported; a moved file that is gone is reported too.
    public func undo(tidyID: String? = nil) -> Result<DesktopTidyUndone, DesktopTidyError> {
        let moment = now()
        lock.lock()
        defer { lock.unlock() }
        var journal = loadJournal(at: moment)
        let index: Int
        if let wanted = tidyID {
            guard let i = journal.entries.firstIndex(where: { $0.tidyID == wanted }) else { return .failure(.tidyNotFound) }
            guard journal.entries[i].undoneAt == nil else { return .failure(.alreadyUndone) }
            index = i
        } else {
            guard let i = journal.entries.lastIndex(where: { $0.undoneAt == nil }) else { return .failure(.nothingToUndo) }
            index = i
        }
        let entry = journal.entries[index]
        let tidyRoot = desktop.appendingPathComponent(DesktopTidyEngine.folderName, isDirectory: true).standardizedFileURL.path + "/"
        let desktopRoot = desktop.standardizedFileURL.path
        var restored = 0
        var failed: [DesktopTidyUndoSkip] = []
        var remaining: [DesktopTidyMoveRecord] = []
        for move in entry.moves {
            let name = (move.from as NSString).lastPathComponent
            // A journal is a file the user could edit: only ever move from inside 정리됨 to directly on the desktop.
            let toPath = URL(fileURLWithPath: move.to).standardizedFileURL.path
            let fromURL = URL(fileURLWithPath: move.from).standardizedFileURL
            guard toPath.hasPrefix(tidyRoot), fromURL.deletingLastPathComponent().path == desktopRoot else {
                failed.append(DesktopTidyUndoSkip(name: name, reason: "invalid_record"))
                continue
            }
            guard inspect(toPath) != nil else {
                failed.append(DesktopTidyUndoSkip(name: name, reason: "not_found"))
                continue
            }
            if inspect(fromURL.path) != nil {
                failed.append(DesktopTidyUndoSkip(name: name, reason: "conflict"))
                remaining.append(move)
                continue
            }
            do {
                try fm.moveItem(atPath: toPath, toPath: fromURL.path)
                restored += 1
            } catch {
                failed.append(DesktopTidyUndoSkip(name: name, reason: "move_failed"))
                remaining.append(move)
            }
        }
        journal.entries[index].moves = remaining
        if remaining.isEmpty { journal.entries[index].undoneAt = DesktopTidyEngine.iso(moment) }
        _ = saveJournal(journal)
        return .success(DesktopTidyUndone(tidyID: entry.tidyID, restored: restored, notRestored: failed, complete: remaining.isEmpty))
    }

    // MARK: history and journal

    /// Tidies of the last 30 days, newest first.
    public func history() -> [DesktopTidyHistoryRow] {
        lock.lock(); defer { lock.unlock() }
        let journal = loadJournal(at: now())
        return journal.entries.reversed().compactMap { e in
            guard let at = DesktopTidyEngine.date(e.at) else { return nil }
            return DesktopTidyHistoryRow(tidyID: e.tidyID, at: at, count: e.total ?? e.moves.count, undone: e.undoneAt != nil,
                                         pendingRestore: e.undoneAt == nil ? e.moves.count : 0)
        }
    }

    /// Drops journal entries older than 30 days (the record only, never a file). Called on every tidy and at app start.
    public func pruneJournal() {
        lock.lock(); defer { lock.unlock() }
        let moment = now()
        let before = loadJournalRaw()
        let kept = prune(before, at: moment)
        if kept.entries.count != before.entries.count { _ = saveJournal(kept) }
    }

    struct JournalEntry: Codable, Equatable {
        var tidyID: String
        var at: String
        var moves: [DesktopTidyMoveRecord]
        /// Files in the tidy when it ran (`moves` shrinks after a partial undo).
        var total: Int?
        var undoneAt: String?

        enum CodingKeys: String, CodingKey {
            case tidyID = "tidy_id"
            case at, moves, total
            case undoneAt = "undone_at"
        }
    }

    struct Journal: Codable, Equatable {
        var entries: [JournalEntry] = []
    }

    private func loadJournalRaw() -> Journal {
        guard let data = try? Data(contentsOf: journalURL) else { return Journal() }
        if let journal = try? JSONDecoder().decode(Journal.self, from: data) { return journal }
        // Unreadable: keep it next to the journal under another name instead of overwriting it.
        let aside = journalURL.deletingLastPathComponent()
            .appendingPathComponent("journal-unreadable-\(Int(now().timeIntervalSince1970)).json")
        try? fm.moveItem(at: journalURL, to: aside)
        return Journal()
    }

    private func prune(_ journal: Journal, at moment: Date) -> Journal {
        let limit = moment.addingTimeInterval(-Double(DesktopTidyEngine.journalDays) * 86_400)
        var out = journal
        out.entries = journal.entries.filter { entry in
            guard let at = DesktopTidyEngine.date(entry.at) else { return false }
            return at >= limit
        }
        return out
    }

    private func loadJournal(at moment: Date) -> Journal { prune(loadJournalRaw(), at: moment) }

    private func saveJournal(_ journal: Journal) -> Bool {
        do {
            try fm.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(journal).write(to: journalURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
}
