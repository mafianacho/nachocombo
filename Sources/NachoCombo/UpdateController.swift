import AppKit
import NachoComboCore

/// In-app updates from the project's GitHub Releases, without an update server or signing keys of its own.
///
/// Checking: `GET /repos/mafianacho/nachocombo/releases/latest` (no sign-in) at launch and every 6 hours while automatic
/// checks are on (General), or when the user presses Check Now. Drafts, pre-releases and versions this Mac went back
/// from are ignored; a failed check stays quiet unless the user asked.
///
/// Installing (General ▸ Install Automatically, on by default): a new release is downloaded in the background and
/// checked (SHA256SUMS.txt, bundle id, version, code signature) into `UpdateStore`; it replaces the app when Nacho Combo
/// quits (also at logout or restart), or at the next launch if quitting did not get to it, never while it runs.
/// "Restart to Update" applies it at once. Off: nothing is installed until the user clicks Update.
///
/// Rolling back: the version before is kept (one copy) and "Revert to Previous Version" puts it back. A new version
/// that does not get through its first launches twice is replaced by the previous one at the next launch. At most two
/// copies are kept (waiting + previous); older ones are deleted. Every failure leaves the running copy as it is.
///
/// Not run on a Mac yet - see the release notes. Limit: the automatic rollback runs inside the new version, so a
/// version that crashes before its first line of code runs cannot roll itself back (the previous copy stays in
/// `~/Library/Application Support/NachoCombo/Updates/previous`, and every release stays on GitHub).
final class UpdateController {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        /// Found; with automatic installs off it waits for the user's click.
        case available(version: String, summary: String)
        case downloading(String)
        /// Downloaded and verified; replaces this copy when Nacho Combo quits.
        case ready(version: String, summary: String)
        case installing(String)
        case failed(String)
    }

    static let latestURL = URL(string: "https://api.github.com/repos/mafianacho/nachocombo/releases/latest")!
    static let permissionNote = "Nacho Combo is ad-hoc signed, so after an update macOS may ask you to allow Screen "
        + "Recording and Accessibility again."
    /// A launch counts as healthy once it has run this long (or quits normally).
    static let healthyAfter: TimeInterval = 20
    private static let lastCheckKey = "updates.lastCheck"

    private(set) var state: State = .idle { didSet { if state != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    /// General ▸ Check Automatically.
    var automaticChecks: () -> Bool = { true }
    /// General ▸ Install Automatically.
    var automaticInstall: () -> Bool = { true }
    /// Quits this copy and opens the one now at the same place.
    var relaunch: (() -> Void)?

    let store = UpdateStore(root: UpdateStore.defaultRoot())
    private let tools = MacUpdateTools()
    private let fetcher = URLSessionUpdateFetcher()
    /// Every `store` change runs here, one at a time.
    private let work = DispatchQueue(label: "nacho.combo.updates")
    private var offer: (version: SemanticVersion, zip: ReleaseAsset, checksums: ReleaseAsset, page: URL?, summary: String)?
    private var releasePageURL: URL?
    private var timer: Timer?
    private var healthyTimer: Timer?
    private var downloading = false
    /// Set once this copy was replaced (update or rollback) and is about to restart: quitting must not swap again.
    private var replaced = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
    private var current: SemanticVersion? { SemanticVersion(currentVersion) }
    private var bundleID: String { Bundle.main.bundleIdentifier ?? "com.mafianacho.nachocombo" }
    private var target: URL { Bundle.main.bundleURL.resolvingSymlinksInPath() }

    var releasePage: URL? { releasePageURL }
    /// The kept copy "Revert to Previous Version" goes back to.
    /// (Reads go straight to the files: a download running on `work` must not block the main thread.)
    var previousVersion: String? { store.previous?.version.description }

    private var lastCheck: Date? {
        get { UserDefaults.standard.object(forKey: UpdateController.lastCheckKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: UpdateController.lastCheckKey) }
    }

    /// Why this copy cannot replace itself, or nil.
    private var replaceProblem: String? {
        let t = target
        guard t.pathExtension == "app" else { return "This copy is not an app bundle, so it cannot be updated in place." }
        if t.path.contains("/AppTranslocation/") {
            return "macOS runs this copy from a temporary place. Move Nacho Combo to the Applications folder and open it from there."
        }
        let parent = t.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), FileManager.default.isWritableFile(atPath: t.path) else {
            return "Nacho Combo cannot replace itself in \(parent.path). Download new versions from the release page."
        }
        return nil
    }

    // MARK: launch and quit

    /// First thing at launch, before any gadget starts. Swaps in an update that quitting did not get to, or rolls back
    /// a version that failed its first launches; then this copy is replaced and restarts (returns true: stop here).
    func handleLaunch() -> Bool {
        guard let current = current, replaceProblem == nil else { return false }
        let action = work.sync { store.launchBegan(current: current, autoInstall: automaticInstall(), target: target) }
        switch action {
        case .normal:
            if let s = store.staged {
                state = .ready(version: s.version.description, summary: "")
            }
            let t = Timer(timeInterval: UpdateController.healthyAfter, repeats: false) { [weak self] _ in self?.markHealthy() }
            RunLoop.main.add(t, forMode: .common)
            healthyTimer = t
            return false
        case .applyStaged:
            let result = work.sync { store.applyStaged(target: target, current: current, bundleID: bundleID, tools: tools) }
            if case .success = result { relaunchEarly(); return true }
            if case let .failure(p) = result { state = .failed("The waiting update could not be installed: \(p.message)") }
            return false
        case .rollBack:
            let result = work.sync { store.rollBack(target: target, current: current, bundleID: bundleID, tools: tools) }
            if case .success = result { relaunchEarly(); return true }
            if case let .failure(p) = result { state = .failed("Going back to the previous version failed: \(p.message)") }
            return false
        }
    }

    /// The notice for the first launch after an update or a rollback (once).
    func takeLaunchNotice() -> LaunchNotice? {
        guard let current = current else { return nil }
        return work.sync { store.takeLaunchNotice(current: current) }
    }

    func markHealthy() {
        healthyTimer?.invalidate()
        healthyTimer = nil
        guard let current = current else { return }
        work.sync { store.launchHealthy(current: current) }
    }

    /// From `applicationWillTerminate` (quit, logout, restart, shutdown): a quit that worked is a healthy launch, and a
    /// waiting update replaces this copy now. No restart.
    func applyAtQuit() {
        markHealthy()
        guard automaticInstall(), !downloading, !replaced, let current = current, replaceProblem == nil else { return }
        work.sync {
            guard store.staged != nil else { return }
            _ = store.applyStaged(target: target, current: current, bundleID: bundleID, tools: tools)
        }
    }

    /// Before restarting, the app starts its fresh copy after this process is gone. Used before the app is set up, so
    /// it exits directly instead of going through applicationWillTerminate.
    private func relaunchEarly() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", target.path]
        try? process.run()
        exit(0)
    }

    // MARK: checking

    /// Checks now if a check is due, then looks again every hour whether 6 hours have passed.
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
        case .checking, .installing, .downloading: return
        default: break
        }
        let before = state
        if manual { state = .checking }
        var request = URLRequest(url: UpdateController.latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NachoCombo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        fetcher.session.dataTask(with: request) { [weak self] data, response, error in
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
        let ledger = store.loadLedger()
        switch UpdatePlan.decide(current: currentVersion, release: release, ledger: ledger) {
        case .available(let version, let zip, let checksums):
            let summary = UpdatePlan.summary(of: release.body)
            offer = (version, zip, checksums, release.pageURL, summary)
            releasePageURL = release.pageURL
            if let s = store.staged, s.version == version {
                state = .ready(version: version.description, summary: summary)
            } else if automaticInstall(), replaceProblem == nil {
                download(then: nil)
            } else {
                state = .available(version: version.description, summary: summary)
            }
        case .upToDate:
            offer = nil
            state = .upToDate(Date())
        case .ignored:
            switch before {
            case .available, .ready: state = before
            default: state = manual ? .upToDate(Date()) : before
            }
        }
    }

    /// Downloads and verifies the offer into the store; `then` runs on the main thread after a success.
    private func download(then next: (() -> Void)?) {
        guard let offer = offer, !downloading else { return }
        downloading = true
        state = .downloading("Downloading \(offer.version)…")
        let id = bundleID
        work.async { [weak self] in
            guard let self = self else { return }
            let result = self.store.stage(version: offer.version, zip: offer.zip, checksums: offer.checksums, bundleID: id,
                                          fetcher: self.fetcher, tools: self.tools)
            DispatchQueue.main.async {
                self.downloading = false
                switch result {
                case .success(let copy):
                    self.state = .ready(version: copy.version.description, summary: offer.summary)
                    next?()
                case .failure(let problem):
                    self.state = .failed("Update \(offer.version) was not downloaded: \(problem.message) Nothing was changed.")
                }
            }
        }
    }

    // MARK: user actions

    /// Update… (automatic installs off) or Restart to Update: asks first, then installs and restarts.
    func confirmAndInstall(window: NSWindow?) {
        let version: String, summary: String
        switch state {
        case let .available(v, s), let .ready(v, s): version = v; summary = s
        default: return
        }
        if let problem = replaceProblem { state = .failed(problem); return }
        let alert = NSAlert()
        alert.messageText = "Restart Nacho Combo to update to \(version)?"
        alert.informativeText = (summary.isEmpty ? "" : summary + "\n\n")
            + "The new version was checked against the release's SHA256SUMS.txt and its code signature. This version is kept, "
            + "so you can go back to it in General ▸ Updates. \(UpdateController.permissionNote)"
        alert.addButton(withTitle: "Restart to Update")
        alert.addButton(withTitle: "Later")
        run(alert, window: window) { [weak self] in self?.installNow() }
    }

    private func installNow() {
        if case .ready = state { applyAndRelaunch(); return }
        download { [weak self] in self?.applyAndRelaunch() }
    }

    private func applyAndRelaunch() {
        guard let current = current else { return }
        state = .installing("Installing…")
        let result = work.sync { store.applyStaged(target: target, current: current, bundleID: bundleID, tools: tools) }
        switch result {
        case .success:
            replaced = true
            state = .installing("Restarting…")
            relaunch?()
        case .failure(let problem):
            state = .failed("The update was not installed: \(problem.message) This copy was kept.")
        }
    }

    /// Revert to Previous Version: asks first, then puts the kept copy back and restarts. The version left is not
    /// installed again automatically (a newer release still is).
    func confirmRollback(window: NSWindow?) {
        guard let previous = previousVersion, let current = current, !downloading else { return }
        if let problem = replaceProblem { state = .failed(problem); return }
        let alert = NSAlert()
        alert.messageText = "Go back to Nacho Combo \(previous)?"
        alert.informativeText = "Nacho Combo \(current) is removed and \(previous) restarts in its place. Automatic updates "
            + "will not install \(current) again; a newer version still comes. Older versions stay on the GitHub Releases page."
        alert.addButton(withTitle: "Go Back to \(previous)")
        alert.addButton(withTitle: "Cancel")
        run(alert, window: window) { [weak self] in
            guard let self = self else { return }
            let result = self.work.sync {
                self.store.rollBack(target: self.target, current: current, bundleID: self.bundleID, tools: self.tools)
            }
            switch result {
            case .success: self.replaced = true; self.state = .installing("Restarting…"); self.relaunch?()
            case .failure(let problem): self.state = .failed(problem.message + " This copy was kept.")
            }
        }
    }

    private func run(_ alert: NSAlert, window: NSWindow?, ok: @escaping () -> Void) {
        let apply: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { ok() } }
        if let window = window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: apply) }
        else { NSApp.activate(ignoringOtherApps: true); apply(alert.runModal()) }
    }
}

/// ditto and codesign, the same checks the release workflow uses.
final class MacUpdateTools: UpdateTools {
    func unpack(zip: URL, into directory: URL) -> Bool {
        run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path]) == 0
    }

    func signatureValid(_ app: URL) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
    }

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

/// Blocking downloads for the update queue (never the main thread).
final class URLSessionUpdateFetcher: UpdateFetching {
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    func fetch(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        request.setValue("NachoCombo/\(version)", forHTTPHeaderField: "User-Agent")
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
}
