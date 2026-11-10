import XCTest
@testable import NachoComboCore

final class ComputerUsePermissionPlanTests: XCTestCase {
    private func settings(_ groups: [ToolGroup]) -> ComputerUseSettings {
        var c = ComputerUseSettings()
        for group in groups { c.setEnabled(group, true) }
        return c
    }

    func testEverythingGrantedServesEveryEnabledGroup() {
        let c = settings([.screen, .input, .clipboard])
        let plan = c.permissionPlan { _ in true }
        XCTAssertTrue(plan.missing.isEmpty)
        XCTAssertTrue(plan.blockedGroups.isEmpty)
        XCTAssertEqual(plan.servable, c)
        XCTAssertTrue(plan.canOpen)
    }

    func testMissingAccessibilityOnlyTurnsOffTheGroupsThatNeedIt() {
        // The reported case: Screen Recording allowed, Accessibility not: the server must still open with Screen.
        let c = settings([.screen, .appsWindows, .input, .clipboard])
        let plan = c.permissionPlan { $0 != .accessibility }
        XCTAssertEqual(plan.missing, [.accessibility])
        XCTAssertEqual(plan.blockedGroups, [.appsWindows, .input])
        XCTAssertEqual(plan.servable.enabledToolGroups, [.screen, .clipboard])
        XCTAssertTrue(plan.canOpen)
        XCTAssertTrue(c.isEnabled(.input), "the saved settings are never changed by a missing permission")
    }

    func testServerStaysClosedWhenEveryEnabledGroupIsBlocked() {
        let plan = settings([.appsWindows, .input]).permissionPlan { $0 != .accessibility }
        XCTAssertEqual(plan.blockedGroups, [.appsWindows, .input])
        XCTAssertFalse(plan.canOpen)
    }

    func testNoGroupOnStillOpensAsBefore() {
        let plan = ComputerUseSettings().permissionPlan { _ in false }
        XCTAssertTrue(plan.missing.isEmpty)
        XCTAssertTrue(plan.canOpen)
    }

    func testEachPermissionIsAskedOnce() {
        var asked: [OSPermission] = []
        _ = settings([.screen, .appsWindows, .input]).permissionPlan { asked.append($0); return false }
        XCTAssertEqual(asked, [.screenRecording, .accessibility])
    }

    func testBlockedGroupToolsAreNotServed() {
        let plan = settings([.screen, .input]).permissionPlan { $0 != .accessibility }
        let served = Set(ToolCatalog.all.filter { plan.servable.isEnabled($0.group) }.map { $0.group })
        XCTAssertEqual(served, [.screen])
    }
}

final class AppLocationDiagnosisTests: XCTestCase {
    func testApplicationsFoldersAreFine() {
        XCTAssertEqual(AppLocationDiagnosis.diagnose(bundlePath: "/Applications/NachoCombo.app", home: "/Users/a").warnings, [])
        XCTAssertEqual(AppLocationDiagnosis.diagnose(bundlePath: "/Users/a/Applications/NachoCombo.app", home: "/Users/a/").warnings, [])
    }

    func testTranslocationIsDetected() {
        let path = "/private/var/folders/xy/abc/T/AppTranslocation/1234-ABCD/d/NachoCombo.app"
        let d = AppLocationDiagnosis.diagnose(bundlePath: path, home: "/Users/a")
        XCTAssertEqual(d.warnings, [.translocated])
        XCTAssertTrue(d.isTranslocated)
        XCTAssertTrue(AppLocationDiagnosis.message(for: .translocated).contains("Applications"))
    }

    func testDiskImageAndOtherFolders() {
        XCTAssertEqual(AppLocationDiagnosis.diagnose(bundlePath: "/Volumes/Nacho Combo/NachoCombo.app", home: "/Users/a").warnings,
                       [.diskImage])
        XCTAssertEqual(AppLocationDiagnosis.diagnose(bundlePath: "/Users/a/Downloads/NachoCombo.app", home: "/Users/a").warnings,
                       [.outsideApplications])
        XCTAssertEqual(AppLocationDiagnosis.diagnose(bundlePath: "/Users/ab/Applications/NachoCombo.app", home: "/Users/a").warnings,
                       [.outsideApplications], "another user's Applications folder is not this user's")
    }
}

final class PermissionResetTests: XCTestCase {
    func testResetArgumentsForThisApp() {
        XCTAssertEqual(PermissionReset.arguments(for: .accessibility, bundleID: "com.mafianacho.nachocombo"),
                       ["reset", "Accessibility", "com.mafianacho.nachocombo"])
        XCTAssertEqual(PermissionReset.arguments(for: .screenRecording, bundleID: "com.mafianacho.nachocombo"),
                       ["reset", "ScreenCapture", "com.mafianacho.nachocombo"])
        XCTAssertNil(PermissionReset.arguments(for: .automation, bundleID: "com.mafianacho.nachocombo"))
    }

    func testNeverResetsWithoutAPlainBundleID() {
        // An empty id would make tccutil reset the permission of every app.
        for bad in [nil, "", "nachocombo", "com..x", "com.x;rm", "com.x y", "-all.x", ".com.x", "com.x."] as [String?] {
            XCTAssertNil(PermissionReset.arguments(for: .accessibility, bundleID: bad), "\(String(describing: bad))")
        }
    }
}
