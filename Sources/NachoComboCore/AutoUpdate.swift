import Foundation

// Automatic updates from GitHub Releases: download and verify in the background, swap the app when Nacho Combo quits
// (or at the next launch), keep exactly one previous copy for rolling back, and roll back by itself when a new version
// cannot get through its first launches. Foundation only, so the whole state machine is tested on Linux; the app
// supplies the macOS tools (ditto, codesign) and the network.
//
// Files (`~/Library/Application Support/NachoCombo/Updates`), at most two app copies at rest:
//   staged/NachoCombo.app + staged/info.json     verified new version waiting for the swap (0 or 1)
//   previous/NachoCombo.app + previous/info.json the version before the running one, for rolling back (0 or 1)
//   download/                                    work folder of a download in progress; removed after every attempt
//   ledger.json                                  skipped versions, trial launches of a just-installed version
// Older copies, zips and temporary files are deleted at once (not moved to the Trash).

/// The macOS-only steps the engine needs. Tests and the dev CLI pass their own.
public protocol UpdateTools: AnyObject {
    /// Unpacks a release zip into `directory` (macOS: `ditto -x -k`).
    func unpack(zip: URL, into directory: URL) -> Bool
    /// The app's code signature verifies (macOS: `codesign --verify --deep --strict`).
    func signatureValid(_ app: URL) -> Bool
}

/// Blocking GET for the update queue (never the main thread). nil on any failure or a status other than 200.
public protocol UpdateFetching: AnyObject {
    func fetch(_ url: URL) -> Data?
}

/// Bundle id and version from `Contents/Info.plist`.
public struct AppBundleInfo: Equatable {
    public let identifier: String
    public let version: String

    public init(identifier: String, version: String) {
        self.identifier = identifier
        self.version = version
    }

    public static func read(_ app: URL) -> AppBundleInfo? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, let version = plist["CFBundleShortVersionString"] as? String
        else { return nil }
        return AppBundleInfo(identifier: id, version: version)
    }
}

/// What survives between launches.
public struct UpdateLedger: Codable, Equatable {
    /// A just-installed version that has not yet reported a healthy launch.
    public struct Trial: Codable, Equatable {
        public var version: String
        public var previous: String
        /// Launches of `version` that started but did not reach "healthy" (counted at the start of each launch).
        public var startedLaunches: Int
    }

    /// Versions the user (or the automatic rollback) went back from: never installed again automatically.
    public var skipped: [String] = []
    public var trial: Trial?
    /// Set when an update was swapped in; the first launch of that version shows the permission check, then clears it.
    public var justUpdatedTo: String?
    /// Set by a rollback, for the same first-launch notice.
    public var rolledBackFrom: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skipped = (try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? []
        trial = try? c.decodeIfPresent(Trial.self, forKey: .trial)
        justUpdatedTo = try? c.decodeIfPresent(String.self, forKey: .justUpdatedTo)
        rolledBackFrom = try? c.decodeIfPresent(String.self, forKey: .rolledBackFrom)
    }

    public func isSkipped(_ version: SemanticVersion) -> Bool {
        skipped.contains { SemanticVersion($0) == version }
    }
}

public struct UpdateProblem: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// What the start of a launch has to do before anything else.
public enum LaunchAction: Equatable {
    /// Nothing waiting: start normally.
    case normal
    /// A verified update is waiting and was not swapped in at quit: swap now, then relaunch.
    case applyStaged(version: String)
    /// This version failed its first launches: go back to the previous copy, then relaunch.
    case rollBack(from: String, to: String)
}

public final class UpdateStore {
    public static let appName = "NachoCombo.app"
    /// Launches a new version may start without reaching "healthy" before the next launch rolls it back.
    public static let maxUnhealthyLaunches = 2

    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NachoCombo", isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
    }

    var stagedDir: URL { root.appendingPathComponent("staged", isDirectory: true) }
    var previousDir: URL { root.appendingPathComponent("previous", isDirectory: true) }
    var downloadDir: URL { root.appendingPathComponent("download", isDirectory: true) }
    var ledgerURL: URL { root.appendingPathComponent("ledger.json") }

    // MARK: ledger

    public func loadLedger() -> UpdateLedger {
        guard let data = try? Data(contentsOf: ledgerURL), let l = try? JSONDecoder().decode(UpdateLedger.self, from: data)
        else { return UpdateLedger() }
        return l
    }

    public func saveLedger(_ ledger: UpdateLedger) {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL, options: .atomic) }
    }

    // MARK: copies

    public struct Copy: Equatable {
        public let version: SemanticVersion
        public let app: URL
    }

    private func copy(in dir: URL) -> Copy? {
        let app = dir.appendingPathComponent(UpdateStore.appName, isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")),
              let info = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = info["version"], let version = SemanticVersion(raw),
              fm.fileExists(atPath: app.path) else { return nil }
        return Copy(version: version, app: app)
    }

    /// The verified new version waiting for the swap.
    public var staged: Copy? { copy(in: stagedDir) }
    /// The copy to roll back to.
    public var previous: Copy? { copy(in: previousDir) }

    /// App copies kept on disk by the updater (not counting the installed app). Never more than 2 at rest.
    public var keptCopies: Int { (staged == nil ? 0 : 1) + (previous == nil ? 0 : 1) }

    private func writeInfo(_ version: SemanticVersion, in dir: URL) throws {
        try JSONEncoder().encode(["version": version.description]).write(to: dir.appendingPathComponent("info.json"), options: .atomic)
    }

    private func remove(_ url: URL) {
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    /// Removes what must not stay: an interrupted download, a staged copy that is not newer than `current` (or was
    /// skipped), a previous copy that is not older, half-written folders and anything else in the folder.
    public func tidy(current: SemanticVersion) {
        remove(downloadDir)
        let ledger = loadLedger()
        if let s = staged {
            if !(current < s.version) || ledger.isSkipped(s.version) { remove(stagedDir) }
        } else {
            remove(stagedDir)
        }
        if let p = previous {
            if !(p.version < current) { remove(previousDir) }
        } else {
            remove(previousDir)
        }
        let known: Set<String> = ["staged", "previous", "ledger.json"]
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !known.contains(name) {
            remove(root.appendingPathComponent(name))
        }
    }

    // MARK: download and stage

    /// Downloads the release's checksums and zip, checks the SHA-256, unpacks, checks bundle id, version and code
    /// signature, and keeps the app as the one staged copy (replacing an older staged one). Every failure leaves the
    /// staged and previous copies as they were and removes the download folder.
    public func stage(version: SemanticVersion, zip: ReleaseAsset, checksums: ReleaseAsset, bundleID: String,
                      fetcher: UpdateFetching, tools: UpdateTools) -> Result<Copy, UpdateProblem> {
        defer { remove(downloadDir) }
        if let s = staged, s.version == version { return .success(s) }
        remove(downloadDir)
        do { try fm.createDirectory(at: downloadDir, withIntermediateDirectories: true) } catch {
            return .failure(UpdateProblem("Could not prepare a folder for the download."))
        }
        guard let sumsData = fetcher.fetch(checksums.downloadURL), let sums = String(data: sumsData, encoding: .utf8) else {
            return .failure(UpdateProblem("Could not download \(UpdatePlan.checksumsName)."))
        }
        guard let data = fetcher.fetch(zip.downloadURL) else {
            return .failure(UpdateProblem("Could not download \(zip.name)."))
        }
        if let problem = UpdatePlan.verify(data, name: zip.name, checksums: sums) {
            switch problem {
            case .badChecksumsFile: return .failure(UpdateProblem("SHA256SUMS.txt of the release could not be read."))
            case .notListed: return .failure(UpdateProblem("\(zip.name) is not listed in SHA256SUMS.txt."))
            case .mismatch: return .failure(UpdateProblem("The download does not match SHA256SUMS.txt."))
            }
        }
        let zipURL = downloadDir.appendingPathComponent(zip.name)
        let unpacked = downloadDir.appendingPathComponent("unpacked", isDirectory: true)
        do { try data.write(to: zipURL) } catch { return .failure(UpdateProblem("Could not save the download.")) }
        guard tools.unpack(zip: zipURL, into: unpacked) else { return .failure(UpdateProblem("Could not unpack \(zip.name).")) }
        let app = unpacked.appendingPathComponent(UpdateStore.appName, isDirectory: true)
        if let problem = UpdateStore.check(app: app, bundleID: bundleID, version: version, tools: tools) { return .failure(problem) }
        // The new copy replaces an older staged one: still at most one waiting.
        remove(stagedDir)
        do {
            try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
            try fm.moveItem(at: app, to: stagedDir.appendingPathComponent(UpdateStore.appName, isDirectory: true))
            try writeInfo(version, in: stagedDir)
        } catch {
            remove(stagedDir)
            return .failure(UpdateProblem("Could not keep the verified update."))
        }
        return staged.map { .success($0) } ?? .failure(UpdateProblem("Could not keep the verified update."))
    }

    static func check(app: URL, bundleID: String, version: SemanticVersion, tools: UpdateTools) -> UpdateProblem? {
        guard let info = AppBundleInfo.read(app) else { return UpdateProblem("The download holds no Nacho Combo app.") }
        guard info.identifier == bundleID else { return UpdateProblem("The download is a different app (bundle id).") }
        guard SemanticVersion(info.version) == version else { return UpdateProblem("The download is not version \(version).") }
        guard tools.signatureValid(app) else { return UpdateProblem("The download's code signature does not verify.") }
        return nil
    }

    // MARK: swap

    /// Puts the staged copy in place of `target` (the running app) and keeps the running version as the previous copy.
    /// The previous copy before that is deleted. On any failure `target` is what it was before.
    public func applyStaged(target: URL, current: SemanticVersion, bundleID: String,
                            tools: UpdateTools) -> Result<SemanticVersion, UpdateProblem> {
        guard let s = staged else { return .failure(UpdateProblem("No update is waiting.")) }
        var ledger = loadLedger()
        guard current < s.version, !ledger.isSkipped(s.version) else {
            remove(stagedDir)
            return .failure(UpdateProblem("The waiting update is not newer than this copy."))
        }
        // Checked again right before the swap: the folder could have been touched since the download.
        if let problem = UpdateStore.check(app: s.app, bundleID: bundleID, version: s.version, tools: tools) {
            remove(stagedDir)
            return .failure(problem)
        }
        switch swap(target: target, incoming: s.app) {
        case let .failure(p): return .failure(p)
        case let .success(outgoing):
            // Labelled with what is really in the bundle, not what the caller thinks is running.
            let outgoingVersion = AppBundleInfo.read(outgoing).flatMap { SemanticVersion($0.version) } ?? current
            keepAsPrevious(outgoing, version: outgoingVersion)
            remove(stagedDir)
            ledger.trial = UpdateLedger.Trial(version: s.version.description, previous: current.description, startedLaunches: 0)
            ledger.justUpdatedTo = s.version.description
            ledger.rolledBackFrom = nil
            saveLedger(ledger)
            return .success(s.version)
        }
    }

    /// Goes back to the previous copy: it replaces `target`, the running (newer) version is deleted and skipped by
    /// automatic updates. On any failure `target` stays as it is.
    public func rollBack(target: URL, current: SemanticVersion, bundleID: String,
                         tools: UpdateTools) -> Result<SemanticVersion, UpdateProblem> {
        guard let p = previous, p.version < current else { return .failure(UpdateProblem("There is no previous version to go back to.")) }
        guard let info = AppBundleInfo.read(p.app), info.identifier == bundleID, SemanticVersion(info.version) == p.version else {
            remove(previousDir)
            return .failure(UpdateProblem("The kept previous copy is damaged. Download an older version from the Releases page."))
        }
        guard tools.signatureValid(p.app) else {
            remove(previousDir)
            return .failure(UpdateProblem("The kept previous copy's code signature does not verify."))
        }
        switch swap(target: target, incoming: p.app) {
        case let .failure(problem): return .failure(problem)
        case let .success(outgoing):
            remove(outgoing)
            remove(previousDir)
            var ledger = loadLedger()
            if !ledger.isSkipped(current) { ledger.skipped.append(current.description) }
            ledger.trial = nil
            ledger.justUpdatedTo = nil
            ledger.rolledBackFrom = current.description
            saveLedger(ledger)
            // The user just chose the older version: nothing waiting is swapped in behind their back (a newer release
            // comes again with the next check).
            remove(stagedDir)
            return .success(p.version)
        }
    }

    /// Moves `target` aside, moves `incoming` into its place, restores `target` if that fails. Returns where the old
    /// `target` now is (beside it, same volume).
    private func swap(target: URL, incoming: URL) -> Result<URL, UpdateProblem> {
        let aside = UpdateStore.asideURL(for: target)
        remove(aside)
        do { try fm.moveItem(at: target, to: aside) } catch {
            return .failure(UpdateProblem("Nacho Combo cannot replace itself in \(target.deletingLastPathComponent().path)."))
        }
        do { try fm.moveItem(at: incoming, to: target) } catch {
            try? fm.moveItem(at: aside, to: target)
            return .failure(UpdateProblem("Could not put the new copy in place. This copy was kept."))
        }
        return .success(aside)
    }

    static func asideURL(for target: URL) -> URL {
        target.deletingLastPathComponent()
            .appendingPathComponent("." + target.deletingPathExtension().lastPathComponent + "-update-old.app", isDirectory: true)
    }

    private func keepAsPrevious(_ outgoing: URL, version: SemanticVersion) {
        remove(previousDir)
        do {
            try fm.createDirectory(at: previousDir, withIntermediateDirectories: true)
            try fm.moveItem(at: outgoing, to: previousDir.appendingPathComponent(UpdateStore.appName, isDirectory: true))
            try writeInfo(version, in: previousDir)
        } catch {
            remove(previousDir)
            remove(outgoing)
        }
    }

    // MARK: launches

    /// Called first thing at every launch. Tidies the folder and says whether to swap or roll back before starting.
    /// `autoInstall` off: a waiting update is not swapped in by itself.
    public func launchBegan(current: SemanticVersion, autoInstall: Bool, target: URL? = nil) -> LaunchAction {
        tidy(current: current)
        // A swap cut short (power loss between the two moves) leaves the old copy beside the app.
        if let target = target { remove(UpdateStore.asideURL(for: target)) }
        var ledger = loadLedger()
        if let trial = ledger.trial {
            if SemanticVersion(trial.version) == current {
                if trial.startedLaunches >= UpdateStore.maxUnhealthyLaunches, let p = previous {
                    return .rollBack(from: current.description, to: p.version.description)
                }
                if trial.startedLaunches >= UpdateStore.maxUnhealthyLaunches {
                    ledger.trial = nil   // nothing to go back to: stop counting
                } else {
                    ledger.trial?.startedLaunches += 1
                }
                saveLedger(ledger)
            } else {
                // Replaced by hand since: the trial is over.
                ledger.trial = nil
                saveLedger(ledger)
            }
        }
        if autoInstall, let s = staged, current < s.version { return .applyStaged(version: s.version.description) }
        return .normal
    }

    /// The running version started fine (a while after launch, or quit normally): it is no longer on trial.
    public func launchHealthy(current: SemanticVersion) {
        var ledger = loadLedger()
        guard let trial = ledger.trial, SemanticVersion(trial.version) == current else { return }
        ledger.trial = nil
        saveLedger(ledger)
    }

    /// The first-launch notice after an update or a rollback: returns it once, then forgets it.
    public func takeLaunchNotice(current: SemanticVersion) -> LaunchNotice? {
        var ledger = loadLedger()
        defer { saveLedger(ledger) }
        if let to = ledger.justUpdatedTo {
            ledger.justUpdatedTo = nil
            if SemanticVersion(to) == current { return .updated(to: to) }
        }
        if let from = ledger.rolledBackFrom {
            ledger.rolledBackFrom = nil
            return .rolledBack(from: from, to: current.description)
        }
        return nil
    }
}

public enum LaunchNotice: Equatable {
    case updated(to: String)
    case rolledBack(from: String, to: String)
}

extension UpdatePlan {
    /// `decide` with the versions the user went back from left out.
    public static func decide(current: String, release: ReleaseInfo, ledger: UpdateLedger) -> Decision {
        let d = decide(current: current, release: release)
        if case let .available(version, _, _) = d, ledger.isSkipped(version) {
            return .ignored("\(version) was rolled back on this Mac")
        }
        return d
    }
}
