import Foundation
import NachoComboCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// nacho-update-cli: drives the app's `UpdateStore` against a release feed, playing the app's lifecycle steps
// (dev/test only; used by scripts/update-roundtrip.sh with tools/mock-server/releases.mjs).
//
//   nacho-update-cli <launch [--crash] | check | quit | rollback | status> --root DIR --target APP --feed URL [--skip-signature]
//
//   launch   what the app does first at launch: tidy, then swap a waiting update in or roll back a failing version;
//            then report healthy, unless --crash (the launch "dies" before it)
//   check    what a scheduled check does: read the feed, then download, verify and stage a newer release
//   quit     what quitting does: swap the waiting update in, report healthy
//   rollback "Revert to Previous Version"
//   status   installed version, waiting and previous copies, skipped versions, trial
// --skip-signature: the fake apps of the round trip are not code signed (Linux has no codesign at all).

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(2)
}

final class BlockingFetcher: UpdateFetching {
    let session = URLSession(configuration: .ephemeral)
    func fetch(_ url: URL) -> Data? {
        var out: Data?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200 { out = data }
            done.signal()
        }.resume()
        done.wait()
        return out
    }
}

final class ShellTools: UpdateTools {
    let skipSignature: Bool
    init(skipSignature: Bool) { self.skipSignature = skipSignature }

    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    func unpack(zip: URL, into directory: URL) -> Bool {
        #if os(macOS)
        return run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path]) == 0
        #else
        return run("/usr/bin/unzip", ["-q", zip.path, "-d", directory.path]) == 0
        #endif
    }

    func signatureValid(_ app: URL) -> Bool {
        if skipSignature { return true }
        #if os(macOS)
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0
        #else
        return false
        #endif
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: nacho-update-cli launch|check|quit|rollback|status --root DIR --target APP --feed URL") }
args.removeFirst()
var root = "", target = "", feed = ""
var crash = false, skipSignature = false
var i = 0
while i < args.count {
    switch args[i] {
    case "--root" where i + 1 < args.count: root = args[i + 1]; i += 2
    case "--target" where i + 1 < args.count: target = args[i + 1]; i += 2
    case "--feed" where i + 1 < args.count: feed = args[i + 1]; i += 2
    case "--crash": crash = true; i += 1
    case "--skip-signature": skipSignature = true; i += 1
    default: fail("unknown argument \(args[i])")
    }
}
guard !root.isEmpty, !target.isEmpty else { fail("--root and --target are required") }
let store = UpdateStore(root: URL(fileURLWithPath: root))
let targetURL = URL(fileURLWithPath: target)
let tools = ShellTools(skipSignature: skipSignature)
guard let info = AppBundleInfo.read(targetURL), let current = SemanticVersion(info.version) else { fail("no app at \(target)") }

func say(_ s: String) { print(s); fflush(stdout) }

func status() {
    let installed = AppBundleInfo.read(targetURL)?.version ?? "-"
    let ledger = store.loadLedger()
    let trial = ledger.trial.map { "\($0.version) started=\($0.startedLaunches)" } ?? "-"
    say("status installed=\(installed) staged=\(store.staged?.version.description ?? "-") previous=\(store.previous?.version.description ?? "-") kept=\(store.keptCopies) skipped=\(ledger.skipped.joined(separator: ",").isEmpty ? "-" : ledger.skipped.joined(separator: ",")) trial=\(trial)")
}

switch command {
case "status":
    status()

case "launch":
    let action = store.launchBegan(current: current, autoInstall: true, target: targetURL)
    switch action {
    case .normal:
        say("launch \(current): normal")
    case let .applyStaged(version):
        say("launch \(current): update \(version) is waiting, swapping before start")
        switch store.applyStaged(target: targetURL, current: current, bundleID: info.identifier, tools: tools) {
        case let .success(v): say("applied \(v) (relaunch)")
        case let .failure(p): say("apply failed: \(p.message)")
        }
    case let .rollBack(from, to):
        say("launch \(current): \(from) did not start properly twice, rolling back to \(to)")
        switch store.rollBack(target: targetURL, current: current, bundleID: info.identifier, tools: tools) {
        case let .success(v): say("rolled back to \(v) (relaunch)")
        case let .failure(p): say("rollback failed: \(p.message)")
        }
    }
    if case .normal = action {
        if let notice = store.takeLaunchNotice(current: current) { say("notice \(notice)") }
        if crash { say("launch died before healthy"); status(); exit(3) }
        store.launchHealthy(current: current)
        say("healthy \(current)")
    }
    status()

case "check":
    guard let url = URL(string: feed), let data = BlockingFetcher().fetch(url) else { say("check: feed unreachable"); status(); exit(1) }
    guard let release = try? ReleaseInfo.parse(data) else { say("check: feed unreadable"); exit(1) }
    switch UpdatePlan.decide(current: current.description, release: release, ledger: store.loadLedger()) {
    case .upToDate: say("check: up to date (\(current))")
    case let .ignored(why): say("check: ignored (\(why))")
    case let .available(version, zip, sums):
        say("check: \(version) available, downloading in the background")
        switch store.stage(version: version, zip: zip, checksums: sums, bundleID: info.identifier, fetcher: BlockingFetcher(), tools: tools) {
        case let .success(copy): say("staged \(copy.version) (verified: sha256, bundle id, version, signature)")
        case let .failure(p): say("stage failed: \(p.message)")
        }
    }
    status()

case "quit":
    store.launchHealthy(current: current)
    if store.staged != nil {
        switch store.applyStaged(target: targetURL, current: current, bundleID: info.identifier, tools: tools) {
        case let .success(v): say("quit: applied \(v)")
        case let .failure(p): say("quit: apply failed: \(p.message)")
        }
    } else {
        say("quit: nothing waiting")
    }
    status()

case "rollback":
    switch store.rollBack(target: targetURL, current: current, bundleID: info.identifier, tools: tools) {
    case let .success(v): say("rollback: back to \(v)")
    case let .failure(p): say("rollback failed: \(p.message)")
    }
    status()

default:
    fail("unknown command \(command)")
}
