import Foundation
import XCTest
@testable import NachoComboCore

final class SemanticVersionTests: XCTestCase {
    func testParsesReleaseTagsAndBundleVersions() {
        XCTAssertEqual(SemanticVersion("v0.4.0"), SemanticVersion(major: 0, minor: 4, patch: 0))
        XCTAssertEqual(SemanticVersion("0.3.0"), SemanticVersion(major: 0, minor: 3, patch: 0))
        XCTAssertEqual(SemanticVersion(" 1.10.2 \n"), SemanticVersion(major: 1, minor: 10, patch: 2))
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2")?.preRelease, "beta.2")
        XCTAssertEqual(SemanticVersion("1.0.0+build.7"), SemanticVersion(major: 1, minor: 0, patch: 0))
    }

    func testRejectsWhatIsNotAVersion() {
        for text in ["", "v", "0.4", "0.4.0.1", "a.b.c", "0.4.x", "1..0", "-1.0.0", "1.0.0-", "latest", "v 0.4.0", "0.4.0 beta"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testOrdersNumericallyNotAsText() {
        XCTAssertLessThan(SemanticVersion("0.3.0")!, SemanticVersion("0.4.0")!)
        XCTAssertLessThan(SemanticVersion("0.9.0")!, SemanticVersion("0.10.0")!)
        XCTAssertLessThan(SemanticVersion("0.4.9")!, SemanticVersion("0.4.10")!)
        XCTAssertLessThan(SemanticVersion("0.99.99")!, SemanticVersion("1.0.0")!)
        XCTAssertFalse(SemanticVersion("0.4.0")! < SemanticVersion("v0.4.0")!)
    }

    func testPreReleaseSortsBeforeTheRelease() {
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha")!, SemanticVersion("1.0.0")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha")!, SemanticVersion("1.0.0-alpha.1")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-alpha.1")!, SemanticVersion("1.0.0-beta")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-beta.2")!, SemanticVersion("1.0.0-beta.11")!)
        XCTAssertLessThan(SemanticVersion("1.0.0-rc.1")!, SemanticVersion("1.0.0")!)
    }
}

final class ReleaseInfoTests: XCTestCase {
    /// Trimmed from the real `releases/latest` answer for v0.3.0 (fields the updater does not read are left in).
    static let latestJSON = """
    {
      "url": "https://api.github.com/repos/mafianacho/nachocombo/releases/1",
      "html_url": "https://github.com/mafianacho/nachocombo/releases/tag/v0.4.0",
      "tag_name": "v0.4.0",
      "target_commitish": "main",
      "name": "Nacho Combo 0.4.0",
      "draft": false,
      "prerelease": false,
      "created_at": "2026-11-10T12:00:00Z",
      "body": "## What's new\\n- **Computer Use** (experimental)\\n- In-app updates\\n\\nVerify with `shasum`.",
      "assets": [
        {"name": "NachoCombo-0.4.0-macos.dmg", "size": 4967501, "content_type": "application/octet-stream",
         "browser_download_url": "https://github.com/mafianacho/nachocombo/releases/download/v0.4.0/NachoCombo-0.4.0-macos.dmg"},
        {"name": "NachoCombo-0.4.0-macos.zip", "size": 4478870,
         "browser_download_url": "https://github.com/mafianacho/nachocombo/releases/download/v0.4.0/NachoCombo-0.4.0-macos.zip"},
        {"name": "SHA256SUMS.txt", "size": 186,
         "browser_download_url": "https://github.com/mafianacho/nachocombo/releases/download/v0.4.0/SHA256SUMS.txt"},
        {"name": "broken-asset-without-url", "size": 1}
      ]
    }
    """

    func testParsesTheLatestReleaseAnswer() throws {
        let release = try ReleaseInfo.parse(Data(ReleaseInfoTests.latestJSON.utf8))
        XCTAssertEqual(release.tag, "v0.4.0")
        XCTAssertEqual(release.version, SemanticVersion("0.4.0"))
        XCTAssertEqual(release.name, "Nacho Combo 0.4.0")
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.pageURL?.absoluteString, "https://github.com/mafianacho/nachocombo/releases/tag/v0.4.0")
        // The broken asset is dropped, the others stay.
        XCTAssertEqual(release.assets.map { $0.name },
                       ["NachoCombo-0.4.0-macos.dmg", "NachoCombo-0.4.0-macos.zip", "SHA256SUMS.txt"])
        XCTAssertEqual(release.assets[1].size, 4478870)
    }

    func testRejectsAnswersWithoutATag() {
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("{\"message\":\"Not Found\"}".utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try ReleaseInfo.parse(Data()))
    }
}

final class UpdatePlanTests: XCTestCase {
    private func asset(_ name: String) -> ReleaseAsset {
        ReleaseAsset(name: name, downloadURL: URL(string: "https://example.invalid/\(name)")!, size: 1)
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, assets: [String]? = nil) -> ReleaseInfo {
        let version = SemanticVersion(tag)?.description ?? tag
        let names = assets ?? ["NachoCombo-\(version)-macos.dmg", "NachoCombo-\(version)-macos.zip", "SHA256SUMS.txt"]
        return ReleaseInfo(tag: tag, name: nil, body: nil, pageURL: nil, draft: draft, prerelease: prerelease,
                           assets: names.map(asset))
    }

    func testOffersANewerReleaseWithTheMacZipAndItsChecksums() {
        let decision = UpdatePlan.decide(current: "0.3.0", release: release("v0.4.0"))
        XCTAssertEqual(decision, .available(version: SemanticVersion("0.4.0")!, zip: asset("NachoCombo-0.4.0-macos.zip"),
                                            checksums: asset("SHA256SUMS.txt")))
    }

    func testSameOrOlderReleaseIsUpToDate() {
        XCTAssertEqual(UpdatePlan.decide(current: "0.4.0", release: release("v0.4.0")), .upToDate)
        XCTAssertEqual(UpdatePlan.decide(current: "0.5.0", release: release("v0.4.0")), .upToDate)
        XCTAssertEqual(UpdatePlan.decide(current: "0.10.0", release: release("v0.9.0")), .upToDate)
    }

    func testDraftsPreReleasesAndOddTagsAreIgnored() {
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: release("v0.4.0", draft: true)) else { return XCTFail() }
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: release("v0.4.0", prerelease: true)) else { return XCTFail() }
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: release("v0.4.0-beta.1")) else { return XCTFail() }
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: release("nightly")) else { return XCTFail() }
        guard case .ignored = UpdatePlan.decide(current: "dev", release: release("v0.4.0")) else { return XCTFail() }
    }

    func testPicksOnlyTheZipOfThatVersion() {
        // A dmg is not installable in place, and a zip of another version must not be taken for this one.
        let onlyDmg = release("v0.4.0", assets: ["NachoCombo-0.4.0-macos.dmg", "SHA256SUMS.txt"])
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: onlyDmg) else { return XCTFail() }
        let wrongZip = release("v0.4.0", assets: ["NachoCombo-0.3.0-macos.zip", "SHA256SUMS.txt"])
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: wrongZip) else { return XCTFail() }
        let noSums = release("v0.4.0", assets: ["NachoCombo-0.4.0-macos.zip"])
        guard case .ignored = UpdatePlan.decide(current: "0.3.0", release: noSums) else { return XCTFail() }
        XCTAssertEqual(UpdatePlan.zipName(for: SemanticVersion("v1.2.3")!), "NachoCombo-1.2.3-macos.zip")
    }

    func testDailyCheckSchedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdatePlan.isCheckDue(last: nil, now: now))
        XCTAssertFalse(UpdatePlan.isCheckDue(last: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdatePlan.isCheckDue(last: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(UpdatePlan.isCheckDue(last: now.addingTimeInterval(3600), now: now), "a clock set back still checks")
    }

    func testSummaryIsPlainAndShort() {
        let body = "## What's new\n- **Computer Use** (experimental)\n* In-app `updates`\n\n\nmore\nand more"
        XCTAssertEqual(UpdatePlan.summary(of: body), "What's new\n• Computer Use (experimental)\n• In-app updates\nmore")
        XCTAssertEqual(UpdatePlan.summary(of: nil), "")
        XCTAssertEqual(UpdatePlan.summary(of: String(repeating: "x", count: 500), maxLength: 10).count, 10)
    }
}

final class SHA256SumsTests: XCTestCase {
    static let zipBytes = Data("pretend this is NachoCombo-0.4.0-macos.zip".utf8)
    static var zipDigest: String { SHA256.hex(of: zipBytes) }

    func testParsesShasumOutputInTextAndBinaryMode() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "B", count: 64)
        let sums = try SHA256Sums.parse("\(a)  NachoCombo-0.4.0-macos.zip\n\(b) *NachoCombo-0.4.0-macos.dmg\n\n")
        XCTAssertEqual(sums["NachoCombo-0.4.0-macos.zip"], a)
        XCTAssertEqual(sums["NachoCombo-0.4.0-macos.dmg"], b.lowercased())
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(try SHA256Sums.parse("\(a)  x.zip\r\n").count, 1)
    }

    func testRejectsADamagedFileAsAWhole() {
        let a = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try SHA256Sums.parse("\(a)  ok.zip\nnot a checksum line"))
        XCTAssertThrowsError(try SHA256Sums.parse(String(repeating: "g", count: 64) + "  x.zip"))   // not hex
        XCTAssertThrowsError(try SHA256Sums.parse(String(repeating: "a", count: 63) + "  x.zip"))   // short digest
        XCTAssertThrowsError(try SHA256Sums.parse("\(a) x.zip"))                                     // one space
        XCTAssertThrowsError(try SHA256Sums.parse("\(a)  ../x.zip"))                                 // a path
        XCTAssertThrowsError(try SHA256Sums.parse("\(a)  x.zip\n\(a)  x.zip"))                       // listed twice
    }

    func testVerifyAcceptsOnlyTheListedMatchingDigest() {
        let name = "NachoCombo-0.4.0-macos.zip"
        let good = "\(SHA256SumsTests.zipDigest)  \(name)\n\(String(repeating: "0", count: 64))  NachoCombo-0.4.0-macos.dmg\n"
        XCTAssertNil(UpdatePlan.verify(SHA256SumsTests.zipBytes, name: name, checksums: good))
        // Upper-case hex (some tools write it) is the same digest.
        XCTAssertNil(UpdatePlan.verify(SHA256SumsTests.zipBytes, name: name,
                                       checksums: "\(SHA256SumsTests.zipDigest.uppercased()) *\(name)\n"))

        var tampered = SHA256SumsTests.zipBytes
        tampered.append(0)
        guard case .mismatch(let expected, let actual)? = UpdatePlan.verify(tampered, name: name, checksums: good) else {
            return XCTFail("a changed download must be refused")
        }
        XCTAssertEqual(expected, SHA256SumsTests.zipDigest)
        XCTAssertNotEqual(actual, expected)

        XCTAssertEqual(UpdatePlan.verify(SHA256SumsTests.zipBytes, name: "Other.zip", checksums: good), .notListed("Other.zip"))
        XCTAssertEqual(UpdatePlan.verify(SHA256SumsTests.zipBytes, name: name, checksums: "garbage"), .badChecksumsFile)
    }

    func testKnownDigest() {
        // FIPS 180-4 example: SHA-256("abc").
        XCTAssertEqual(SHA256.hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class UpdateSettingsTests: XCTestCase {
    func testAutomaticChecksDefaultOnAndOlderFilesKeepThem() throws {
        XCTAssertTrue(AppSettings.defaults.checkForUpdates)
        let old = "{\"version\":1,\"enabledModules\":{\"focusDim\":true},\"menuBarCollapsed\":false}"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertTrue(decoded.checkForUpdates)
        XCTAssertTrue(decoded.isEnabled(.focusDim))
        XCTAssertEqual(decoded.computerUse, ComputerUseSettings())
        XCTAssertFalse(decoded.isEnabled(.computerUse))

        var off = AppSettings.defaults
        off.checkForUpdates = false
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(round.checkForUpdates)
    }

    func testABrokenComputerUseSectionFallsBackToEverythingOff() throws {
        let text = "{\"version\":1,\"enabledModules\":{},\"menuBarCollapsed\":false,\"computerUse\":{\"port\":\"oops\"},"
            + "\"dimIntensity\":0.5}"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))
        XCTAssertEqual(decoded.computerUse, ComputerUseSettings())
        XCTAssertEqual(decoded.dimIntensity, 0.5)
    }

    func testCombosNeverTouchComputerUse() {
        XCTAssertFalse(ModuleID.comboGadgets.contains(.computerUse))
        XCTAssertEqual(ModuleID.comboGadgets.count, ModuleID.allCases.count - 1)
        for combo in ComboCatalog.presets { XCTAssertFalse(combo.gadgets.contains(.computerUse), combo.id) }
        var settings = AppSettings.defaults
        settings.setEnabled(.computerUse, true)
        settings.setEnabled(.focusDim, true)
        let plan = ComboPlan.make(ComboCatalog.combo("starter")!, settings: settings)
        XCTAssertFalse(plan.turnsOff.contains(.computerUse), "ordering a combo leaves Computer Use as it is")
        XCTAssertFalse(ComboCatalog.draft(from: settings).gadgets.contains(.computerUse))
    }

    func testEmergencyStopShortcutIsReserved() {
        let stop = ToolShortcut(keyCode: 47, modifiers: ToolShortcut.control | ToolShortcut.option | ToolShortcut.command)
        guard case .reservedBySystem? = ShortcutPolicy.validateAction(stop, actionID: "dim.toggle", settings: .defaults) else {
            return XCTFail("⌃⌥⌘. must stay free for the emergency stop")
        }
        guard case .reservedBySystem? = ShortcutPolicy.validate(stop, for: .focusDim, existing: [:]) else { return XCTFail() }
        // No default action shortcut uses it.
        XCTAssertFalse(AppSettings.defaults.effectiveActionShortcuts.contains { $0.keyCode == 47 && $0.modifiers == stop.modifiers })
    }
}
