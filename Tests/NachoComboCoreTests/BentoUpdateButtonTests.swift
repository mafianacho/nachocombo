import XCTest
@testable import NachoComboCore

/// The widget window's yellow update pill: all eight updater states, edit mode, and the confirmation sheet's parent.
final class BentoUpdateButtonTests: XCTestCase {
    private func model(_ s: BentoUpdateState, editing: Bool = false) -> BentoUpdateButtonModel {
        BentoUpdateLogic.button(for: s, editing: editing)
    }

    func testAvailableShowsVersionAndIsActive() {
        let m = model(.available(version: "0.9.1"))
        XCTAssertEqual(m, BentoUpdateButtonModel(visible: true, title: "업데이트 0.9.1", enabled: true))
    }

    func testReadyAsksForRestartAndIsActive() {
        XCTAssertEqual(model(.ready(version: "0.9.1")), BentoUpdateButtonModel(visible: true, title: "재시작해 업데이트", enabled: true))
    }

    func testDownloadingAndInstallingShowDisabledBusyPill() {
        for s in [BentoUpdateState.downloading, .installing] {
            XCTAssertEqual(model(s), BentoUpdateButtonModel(visible: true, title: "업데이트 중…", enabled: false), "\(s)")
        }
    }

    func testIdleCheckingUpToDateFailedAreHidden() {
        for s in [BentoUpdateState.idle, .checking, .upToDate, .failed] {
            XCTAssertFalse(model(s).visible, "\(s)")
        }
    }

    func testEditModeHidesEveryState() {
        let all: [BentoUpdateState] = [.idle, .checking, .upToDate, .available(version: "1.0.0"), .downloading,
                                       .ready(version: "1.0.0"), .installing, .failed]
        XCTAssertEqual(all.count, 8)
        for s in all { XCTAssertFalse(model(s, editing: true).visible, "\(s)") }
    }

    func testConfirmParentPrefersWidgetWhenClickedThere() {
        XCTAssertEqual(BentoUpdateLogic.confirmParent(fromWidget: true, widgetVisible: true, settingsVisible: true), .widget)
        XCTAssertEqual(BentoUpdateLogic.confirmParent(fromWidget: true, widgetVisible: true, settingsVisible: false), .widget)
    }

    func testConfirmParentKeepsSettingsPathAsBefore() {
        XCTAssertEqual(BentoUpdateLogic.confirmParent(fromWidget: false, widgetVisible: true, settingsVisible: true), .settings)
        XCTAssertEqual(BentoUpdateLogic.confirmParent(fromWidget: false, widgetVisible: true, settingsVisible: false), .none)
        XCTAssertEqual(BentoUpdateLogic.confirmParent(fromWidget: true, widgetVisible: false, settingsVisible: true), .settings)
    }
}
