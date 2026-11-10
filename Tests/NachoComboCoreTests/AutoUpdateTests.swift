import Foundation
import XCTest
@testable import NachoComboCore

/// A fake "zip": JSON naming the app it unpacks to, so the state machine runs on real folders without ditto.
final class FakeUpdateTools: UpdateTools {
    var signatureOK = true
    var unpackOK = true
    func unpack(zip: URL, into directory: URL) -> Bool {
        guard unpackOK, let data = try? Data(contentsOf: zip),
              let spec = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return (try? FakeApp.make(at: directory.appendingPathComponent(UpdateStore.appName), id: spec["id"]!, version: spec["version"]!)) != nil
    }
    func signatureValid(_ app: URL) -> Bool { signatureOK }
}

enum FakeApp {
    static func make(at app: URL, id: String = "com.mafianacho.nachocombo", version: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try Data("binary \(version)".utf8).write(to: contents.appendingPathComponent("MacOS/NachoCombo"))
    }

    static func version(_ app: URL) -> String? { AppBundleInfo.read(app)?.version }
}

final class FakeFetcher: UpdateFetching {
    var files: [String: Data] = [:]
    var fetched: [String] = []
    func fetch(_ url: URL) -> Data? {
        fetched.append(url.lastPathComponent)
        return files[url.lastPathComponent]
    }
}

final class AutoUpdateTests: XCTestCase {
    let id = "com.mafianacho.nachocombo"
    var dir: URL!
    var target: URL!
    var store: UpdateStore!
    let tools = FakeUpdateTools()
    let fetcher = FakeFetcher()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("autoupdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        target = dir.appendingPathComponent("Applications/NachoCombo.app")
        try FakeApp.make(at: target, version: "0.5.0")
        store = UpdateStore(root: dir.appendingPathComponent("Support/Updates"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func v(_ s: String) -> SemanticVersion { SemanticVersion(s)! }

    /// Puts a release in the fake network: zip + SHA256SUMS (optionally with a wrong digest).
    private func publish(_ version: String, id: String? = nil, corrupt: Bool = false) -> (ReleaseAsset, ReleaseAsset) {
        let name = "NachoCombo-\(version)-macos.zip"
        let zip = try! JSONEncoder().encode(["id": id ?? self.id, "version": version])
        fetcher.files[name] = zip
        let digest = corrupt ? String(repeating: "0", count: 64) : SHA256.hex(of: zip)
        fetcher.files["SHA256SUMS.txt"] = Data("\(digest)  \(name)\n".utf8)
        let base = URL(string: "https://example.invalid/\(version)/")!
        return (ReleaseAsset(name: name, downloadURL: base.appendingPathComponent(name), size: zip.count),
                ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: base.appendingPathComponent("SHA256SUMS.txt"), size: 1))
    }

    @discardableResult
    private func stage(_ version: String, corrupt: Bool = false, otherID: String? = nil) -> Result<UpdateStore.Copy, UpdateProblem> {
        let (zip, sums) = publish(version, id: otherID, corrupt: corrupt)
        return store.stage(version: v(version), zip: zip, checksums: sums, bundleID: id, fetcher: fetcher, tools: tools)
    }

    private func installed() -> String? { FakeApp.version(target) }

    private func storeEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).sorted()
    }

    private func applicationsEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []).sorted()
    }

    // MARK: staging

    func testStageDownloadsVerifiesAndKeepsOneWaitingCopy() throws {
        let staged = try stage("0.5.1").get()
        XCTAssertEqual(staged.version, v("0.5.1"))
        XCTAssertEqual(FakeApp.version(staged.app), "0.5.1")
        XCTAssertEqual(installed(), "0.5.0", "nothing changes while Nacho Combo runs")
        XCTAssertEqual(storeEntries(), ["staged"], "zip and download folder are gone")
        // A newer release replaces the waiting one; still one.
        try stage("0.5.2").get()
        XCTAssertEqual(store.staged?.version, v("0.5.2"))
        XCTAssertEqual(store.keptCopies, 1)
        // Same version again: no second download.
        fetcher.fetched = []
        try stage("0.5.2").get()
        XCTAssertTrue(fetcher.fetched.isEmpty)
    }

    func testStageRefusesBadDownloadsAndKeepsWhatWasThere() throws {
        try stage("0.5.1").get()
        XCTAssertEqual(stage("0.5.2", corrupt: true), .failure(UpdateProblem("The download does not match SHA256SUMS.txt.")))
        XCTAssertEqual(stage("0.5.2", otherID: "com.evil.app"), .failure(UpdateProblem("The download is a different app (bundle id).")))
        tools.signatureOK = false
        XCTAssertEqual(stage("0.5.2"), .failure(UpdateProblem("The download's code signature does not verify.")))
        tools.signatureOK = true
        tools.unpackOK = false
        XCTAssertEqual(stage("0.5.2"), .failure(UpdateProblem("Could not unpack NachoCombo-0.5.2-macos.zip.")))
        tools.unpackOK = true
        fetcher.files = [:]
        let (zip, sums) = (ReleaseAsset(name: "NachoCombo-0.5.2-macos.zip", downloadURL: URL(string: "https://x.invalid/a.zip")!, size: 1),
                           ReleaseAsset(name: "SHA256SUMS.txt", downloadURL: URL(string: "https://x.invalid/SHA256SUMS.txt")!, size: 1))
        if case .success = store.stage(version: v("0.5.2"), zip: zip, checksums: sums, bundleID: id, fetcher: fetcher, tools: tools) {
            XCTFail("offline stage succeeded")
        }
        XCTAssertEqual(store.staged?.version, v("0.5.1"), "the earlier verified copy is kept")
        XCTAssertEqual(storeEntries(), ["staged"], "no download leftovers")
    }

    func testAZipThatIsNotTheAnnouncedVersionIsRefused() {
        let (zip, sums) = publish("0.5.3")
        XCTAssertEqual(store.stage(version: v("0.5.2"), zip: zip, checksums: sums, bundleID: id, fetcher: fetcher, tools: tools),
                       .failure(UpdateProblem("The download is not version 0.5.2.")))
    }

    // MARK: swap and the two-copy limit

    func testApplySwapsKeepsOnePreviousAndDeletesOlderCopies() throws {
        try stage("0.5.1").get()
        XCTAssertEqual(store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools), .success(v("0.5.1")))
        XCTAssertEqual(installed(), "0.5.1")
        XCTAssertEqual(store.previous?.version, v("0.5.0"))
        XCTAssertNil(store.staged)
        XCTAssertEqual(applicationsEntries(), ["NachoCombo.app"], "nothing left beside the app")
        XCTAssertEqual(store.loadLedger().trial, UpdateLedger.Trial(version: "0.5.1", previous: "0.5.0", startedLaunches: 0))

        try stage("0.5.2").get()
        XCTAssertEqual(store.keptCopies, 2, "waiting + previous: the most there ever is")
        XCTAssertEqual(store.applyStaged(target: target, current: v("0.5.1"), bundleID: id, tools: tools), .success(v("0.5.2")))
        XCTAssertEqual(installed(), "0.5.2")
        XCTAssertEqual(store.previous?.version, v("0.5.1"), "0.5.0 was deleted, not kept")
        XCTAssertEqual(store.keptCopies, 1)
        XCTAssertEqual(storeEntries(), ["ledger.json", "previous"])
        let previousApps = try FileManager.default.contentsOfDirectory(atPath: store.previousDir.path).filter { $0.hasSuffix(".app") }
        XCTAssertEqual(previousApps, ["NachoCombo.app"])
    }

    func testApplyFailureLeavesTheRunningCopy() throws {
        try stage("0.5.1").get()
        tools.signatureOK = false   // the waiting copy was tampered with after the download
        XCTAssertEqual(store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools),
                       .failure(UpdateProblem("The download's code signature does not verify.")))
        XCTAssertEqual(installed(), "0.5.0")
        XCTAssertNil(store.staged, "a copy that failed the check is deleted")
        tools.signatureOK = true
        // Not writable: the target folder is gone.
        try stage("0.5.1").get()
        let elsewhere = dir.appendingPathComponent("Missing/NachoCombo.app")
        if case .success = store.applyStaged(target: elsewhere, current: v("0.5.0"), bundleID: id, tools: tools) { XCTFail() }
        XCTAssertEqual(installed(), "0.5.0")
        XCTAssertNotNil(store.staged, "kept for the next try")
        // Not newer (the user installed 0.5.1 by hand meanwhile): dropped.
        XCTAssertEqual(store.applyStaged(target: target, current: v("0.5.1"), bundleID: id, tools: tools),
                       .failure(UpdateProblem("The waiting update is not newer than this copy.")))
        XCTAssertNil(store.staged)
    }

    // MARK: rollback

    func testManualRollbackRestoresThePreviousAndSkipsTheNewer() throws {
        try stage("0.5.1").get()
        _ = store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools)
        XCTAssertEqual(store.rollBack(target: target, current: v("0.5.1"), bundleID: id, tools: tools), .success(v("0.5.0")))
        XCTAssertEqual(installed(), "0.5.0")
        XCTAssertNil(store.previous)
        XCTAssertEqual(store.keptCopies, 0, "the version gone back from is deleted")
        XCTAssertEqual(applicationsEntries(), ["NachoCombo.app"])
        let ledger = store.loadLedger()
        XCTAssertEqual(ledger.skipped, ["0.5.1"])
        XCTAssertNil(ledger.trial)

        // The same release is not offered again; a newer one is.
        let release051 = ReleaseInfo(tag: "v0.5.1", name: nil, body: nil, pageURL: nil, draft: false, prerelease: false,
                                     assets: [publish("0.5.1").0, publish("0.5.1").1])
        guard case .ignored = UpdatePlan.decide(current: "0.5.0", release: release051, ledger: ledger) else { return XCTFail() }
        let (z, s) = publish("0.5.2")
        let release052 = ReleaseInfo(tag: "v0.5.2", name: nil, body: nil, pageURL: nil, draft: false, prerelease: false, assets: [z, s])
        guard case .available = UpdatePlan.decide(current: "0.5.0", release: release052, ledger: ledger) else { return XCTFail() }
        // A stale waiting copy of the skipped version is not installed at launch.
        XCTAssertEqual(store.takeLaunchNotice(current: v("0.5.0")), .rolledBack(from: "0.5.1", to: "0.5.0"))
        XCTAssertNil(store.takeLaunchNotice(current: v("0.5.0")), "shown once")
    }

    func testRollbackDropsAWaitingUpdateSoQuittingDoesNotUndoIt() throws {
        try stage("0.5.1").get()
        _ = store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools)
        try stage("0.5.2").get()   // downloaded before the user decided to go back
        XCTAssertEqual(store.rollBack(target: target, current: v("0.5.1"), bundleID: id, tools: tools), .success(v("0.5.0")))
        XCTAssertNil(store.staged)
        XCTAssertEqual(store.applyStaged(target: target, current: v("0.5.1"), bundleID: id, tools: tools),
                       .failure(UpdateProblem("No update is waiting.")))
        XCTAssertEqual(installed(), "0.5.0")
    }

    func testPreviousCopyIsLabelledWithItsRealVersion() throws {
        try stage("0.5.1").get()
        // The caller believes 0.4.9 runs, but the bundle in place is 0.5.0.
        _ = store.applyStaged(target: target, current: v("0.4.9"), bundleID: id, tools: tools)
        XCTAssertEqual(store.previous?.version, v("0.5.0"))
    }

    func testRollbackWithoutAPreviousCopyChangesNothing() {
        XCTAssertEqual(store.rollBack(target: target, current: v("0.5.0"), bundleID: id, tools: tools),
                       .failure(UpdateProblem("There is no previous version to go back to.")))
        XCTAssertEqual(installed(), "0.5.0")
    }

    func testDamagedPreviousCopyIsNotRestored() throws {
        try stage("0.5.1").get()
        _ = store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools)
        try FileManager.default.removeItem(at: store.previousDir.appendingPathComponent("NachoCombo.app/Contents/Info.plist"))
        if case .success = store.rollBack(target: target, current: v("0.5.1"), bundleID: id, tools: tools) { XCTFail() }
        XCTAssertEqual(installed(), "0.5.1", "the running copy stays")
    }

    // MARK: launches (automatic rollback state machine)

    func testANewVersionThatNeverGetsHealthyIsRolledBackOnTheThirdLaunch() throws {
        try stage("0.5.1").get()
        _ = store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools)
        // Launch 1 and 2 of 0.5.1 start and die before "healthy".
        XCTAssertEqual(store.launchBegan(current: v("0.5.1"), autoInstall: true), .normal)
        XCTAssertEqual(store.loadLedger().trial?.startedLaunches, 1)
        XCTAssertEqual(store.launchBegan(current: v("0.5.1"), autoInstall: true), .normal)
        XCTAssertEqual(store.loadLedger().trial?.startedLaunches, 2)
        // Launch 3: two unhealthy launches in a row → back to 0.5.0.
        XCTAssertEqual(store.launchBegan(current: v("0.5.1"), autoInstall: true), .rollBack(from: "0.5.1", to: "0.5.0"))
        XCTAssertEqual(store.rollBack(target: target, current: v("0.5.1"), bundleID: id, tools: tools), .success(v("0.5.0")))
        XCTAssertEqual(installed(), "0.5.0")
        XCTAssertEqual(store.launchBegan(current: v("0.5.0"), autoInstall: true), .normal)
        XCTAssertEqual(store.loadLedger().skipped, ["0.5.1"])
    }

    func testAHealthyLaunchEndsTheTrial() throws {
        try stage("0.5.1").get()
        _ = store.applyStaged(target: target, current: v("0.5.0"), bundleID: id, tools: tools)
        XCTAssertEqual(store.launchBegan(current: v("0.5.1"), autoInstall: true), .normal)
        store.launchHealthy(current: v("0.5.1"))
        XCTAssertNil(store.loadLedger().trial)
        for _ in 0..<5 { XCTAssertEqual(store.launchBegan(current: v("0.5.1"), autoInstall: true), .normal) }
        XCTAssertEqual(store.previous?.version, v("0.5.0"), "the rollback copy stays available")
        XCTAssertEqual(store.takeLaunchNotice(current: v("0.5.1")), .updated(to: "0.5.1"))
        XCTAssertNil(store.takeLaunchNotice(current: v("0.5.1")))
    }

    func testAWaitingUpdateIsAppliedAtTheNextLaunchOnlyWhenAutomatic() throws {
        try stage("0.5.1").get()
        XCTAssertEqual(store.launchBegan(current: v("0.5.0"), autoInstall: false), .normal)
        XCTAssertEqual(store.launchBegan(current: v("0.5.0"), autoInstall: true), .applyStaged(version: "0.5.1"))
    }

    func testLaunchTidiesLeftovers() throws {
        try stage("0.5.1").get()
        // An interrupted download, a stray file, and the old copy of a swap cut short.
        try FileManager.default.createDirectory(at: store.downloadDir.appendingPathComponent("unpacked"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.downloadDir.appendingPathComponent("NachoCombo-0.5.2-macos.zip"))
        try Data("x".utf8).write(to: store.root.appendingPathComponent("junk.tmp"))
        try FakeApp.make(at: UpdateStore.asideURL(for: target), version: "0.4.0")
        _ = store.launchBegan(current: v("0.5.0"), autoInstall: false, target: target)
        XCTAssertEqual(storeEntries(), ["staged"])
        XCTAssertEqual(applicationsEntries(), ["NachoCombo.app"])
        // The waiting copy is dropped once this copy is as new (installed by hand).
        _ = store.launchBegan(current: v("0.5.1"), autoInstall: false)
        XCTAssertNil(store.staged)
        XCTAssertEqual(store.keptCopies, 0)
    }

    func testABrokenLedgerIsAFreshStart() throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.ledgerURL)
        XCTAssertEqual(store.loadLedger(), UpdateLedger())
        XCTAssertEqual(store.launchBegan(current: v("0.5.0"), autoInstall: true), .normal)
    }
}
