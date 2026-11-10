import AppKit
import NachoComboCore

/// In-app updates from the project's GitHub Releases, without an update server or signing keys of its own.
///
/// Checking: `GET /repos/mafianacho/nachocombo/releases/latest` (no sign-in) at launch and once a day while automatic
/// checks are on (General), or when the user presses Check Now. Drafts and pre-releases are ignored; a failed check
/// stays quiet unless the user asked.
///
/// Installing happens only when the user clicks Update: the release's zip is downloaded, checked against the
/// release's SHA256SUMS.txt, unpacked, its bundle id, version and code signature are verified, and only then does it
/// replace this copy in one step (the old copy goes to the Trash). Then Nacho Combo restarts. Any failure leaves the
/// running copy as it is.
///
/// Not run on a Mac yet - see the release notes.
final class UpdateController {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case available(version: String, summary: String)
        case installing(String)
        case failed(String)
    }

    static let latestURL = URL(string: "https://api.github.com/repos/mafianacho/nachocombo/releases/latest")!
    static let permissionNote = "Nacho Combo is ad-hoc signed, so after an update macOS may ask you to allow Screen "
        + "Recording and Accessibility again."
    private static let lastCheckKey = "updates.lastCheck"

    private(set) var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// General ▸ Check for Updates Automatically.
    var automaticChecks: () -> Bool = { true }
    /// Quits this copy and opens the one now at the same place.
    var relaunch: (() -> Void)?

    private var offer: (version: SemanticVersion, zip: ReleaseAsset, checksums: ReleaseAsset, page: URL?)?
    private var timer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var releasePage: URL? { offer?.page }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: UpdateController.lastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: UpdateController.lastCheckKey) }
    }

    /// Checks now if a check is due, then looks again every hour whether the day has passed.
    func startSchedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        checkIfDue()
    }

    func checkIfDue() {
        guard automaticChecks(), UpdatePlan.isCheckDue(last: lastCheck, now: Date()) else { return }
        check(manual: false)
    }

    func check(manual: Bool) {
        switch state {
        case .checking, .installing: return
        default: break
        }
        let before = state
        if manual { state = .checking }
        var request = URLRequest(url: UpdateController.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NachoCombo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                self?.finishCheck(data: error == nil && status == 200 ? data : nil, manual: manual, before: before)
            }
        }.resume()
    }

    private func finishCheck(data: Data?, manual: Bool, before: State) {
        lastCheck = Date()
        guard let data = data, let release = try? ReleaseInfo.parse(data) else {
            // Offline or GitHub unreachable: only a check the user asked for says so.
            state = manual ? .failed("Could not reach GitHub to look for updates. Try again later.") : before
            return
        }
        switch UpdatePlan.decide(current: currentVersion, release: release) {
        case .available(let version, let zip, let checksums):
            offer = (version, zip, checksums, release.pageURL)
            state = .available(version: version.description, summary: UpdatePlan.summary(of: release.body))
        case .upToDate:
            offer = nil
            state = .upToDate(Date())
        case .ignored:
            if case .available = before { state = before } else { state = manual ? .upToDate(Date()) : before }
        }
    }

    /// Asks first (with the release notes and the permission note), then installs. Only ever called from a click.
    func confirmAndInstall(window: NSWindow?) {
        guard case .available(let version, let summary) = state else { return }
        let alert = NSAlert()
        alert.messageText = "Update Nacho Combo to \(version)?"
        alert.informativeText = (summary.isEmpty ? "" : summary + "\n\n")
            + "The download is checked against the release's SHA256SUMS.txt and its code signature before it replaces "
            + "this copy, and Nacho Combo restarts. \(UpdateController.permissionNote)"
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Later")
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.install() }
        }
        if let window = window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    private func install() {
        guard let offer = offer else { return }
        if case .installing = state { return }
        state = .installing("Downloading \(offer.version)…")
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.performInstall(offer: offer, target: target)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.state = .installing("Restarting…")
                    self.relaunch?()
                case .failure(let problem):
                    self.state = .failed(problem.message)
                }
            }
        }
    }

    private struct Problem: Error { let message: String }

    /// Runs off the main thread. Every early return leaves the running copy untouched.
    private func performInstall(offer: (version: SemanticVersion, zip: ReleaseAsset, checksums: ReleaseAsset, page: URL?),
                                target: URL) -> Result<Void, Problem> {
        let fm = FileManager.default
        guard target.pathExtension == "app" else {
            return .failure(Problem(message: "This copy is not an app bundle, so it cannot be updated in place."))
        }
        if target.path.contains("/AppTranslocation/") {
            return .failure(Problem(message: "macOS runs this copy from a temporary place. Move Nacho Combo to the "
                                    + "Applications folder, open it from there and update again."))
        }
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path) else {
            return .failure(Problem(message: "Nacho Combo cannot replace itself in \(parent.path). Download the new "
                                    + "version from the release page and replace it by hand."))
        }

        guard let sumsData = fetch(offer.checksums.downloadURL), let sums = String(data: sumsData, encoding: .utf8) else {
            return .failure(Problem(message: "Could not download SHA256SUMS.txt. Nothing was changed."))
        }
        guard let zip = fetch(offer.zip.downloadURL) else {
            return .failure(Problem(message: "Could not download \(offer.zip.name). Nothing was changed."))
        }
        if let problem = UpdatePlan.verify(zip, name: offer.zip.name, checksums: sums) {
            let detail: String
            switch problem {
            case .badChecksumsFile: detail = "SHA256SUMS.txt of the release could not be read"
            case .notListed: detail = "\(offer.zip.name) is not listed in SHA256SUMS.txt"
            case .mismatch: detail = "the download does not match SHA256SUMS.txt"
            }
            return .failure(Problem(message: "Update stopped: \(detail). Nothing was changed."))
        }

        let staging: URL
        do {
            staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        } catch {
            return .failure(Problem(message: "Could not prepare a folder for the update (\(error.localizedDescription))."))
        }
        defer { try? fm.removeItem(at: staging) }
        let zipURL = staging.appendingPathComponent(offer.zip.name)
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        do { try zip.write(to: zipURL) } catch {
            return .failure(Problem(message: "Could not save the download (\(error.localizedDescription))."))
        }
        guard run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpacked.path]) == 0 else {
            return .failure(Problem(message: "Could not unpack \(offer.zip.name). Nothing was changed."))
        }
        let newApp = unpacked.appendingPathComponent(target.lastPathComponent)
        let fallback = unpacked.appendingPathComponent("NachoCombo.app")
        let candidate = fm.fileExists(atPath: newApp.path) ? newApp : fallback
        guard fm.fileExists(atPath: candidate.path), let info = NSDictionary(contentsOf:
                candidate.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            return .failure(Problem(message: "The download holds no Nacho Combo app. Nothing was changed."))
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            return .failure(Problem(message: "The download is a different app (bundle id). Nothing was changed."))
        }
        guard info["CFBundleShortVersionString"] as? String == offer.version.description else {
            return .failure(Problem(message: "The download is not version \(offer.version). Nothing was changed."))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path]) == 0 else {
            return .failure(Problem(message: "The download's code signature does not verify. Nothing was changed."))
        }

        // One step on the same volume; the previous copy is kept beside it, then moved to the Trash.
        let backupName = target.deletingPathExtension().lastPathComponent + " (previous).app"
        do {
            _ = try fm.replaceItemAt(target, withItemAt: candidate, backupItemName: backupName,
                                     options: [.withoutDeletingBackupItem])
        } catch {
            return .failure(Problem(message: "Could not replace this copy (\(error.localizedDescription)). It was kept."))
        }
        let backup = parent.appendingPathComponent(backupName)
        if fm.fileExists(atPath: backup.path) { try? fm.trashItem(at: backup, resultingItemURL: nil) }
        return .success(())
    }

    /// A blocking download for the install queue (never the main thread).
    private func fetch(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("NachoCombo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let done = DispatchSemaphore(value: 0)
        let box = DataBox()
        session.dataTask(with: request) { data, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 { box.data = data }
            done.signal()
        }.resume()
        done.wait()
        return box.data
    }

    /// Carries the answer out of the completion handler (written once before the semaphore is signalled).
    private final class DataBox: @unchecked Sendable { var data: Data? }

    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
