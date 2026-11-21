import XCTest
@testable import NachoComboCore

final class SettingsPanelTests: XCTestCase {
    // 1. Every gadget has a panel page.
    func testEveryGadgetHasPanelTabs() {
        for id in ModuleID.allCases {
            let tabs = SettingsPanelRoute.tabs(for: id)
            XCTAssertEqual(tabs, [.settings, .shortcuts, .permissions], "\(id) panel tabs")
            XCTAssertEqual(SettingsEntry.gadgetOpenSettings(id).route, .gadget(id, .settings), "\(id) settings")
            XCTAssertEqual(SettingsEntry.widgetClick(id).route, .gadget(id, .settings), "\(id) tile click")
            XCTAssertEqual(SettingsEntry.hiddenWidgetSettings(id).route, .gadget(id, .settings), "\(id) hidden widget")
            XCTAssertEqual(SettingsEntry.permissionNeeded(id).route, .gadget(id, .permissions), "\(id) permission")
            XCTAssertEqual(SettingsEntry.deepLink(page: id.rawValue, tab: nil).route, .gadget(id, .settings), "\(id) deep link")
        }
    }

    func testTabTitles() {
        XCTAssertEqual(GadgetPanelTab.allCases.map { $0.title }, ["설정", "단축키", "권한"])
        XCTAssertEqual(AppPanelTab.allCases.map { $0.title }, ["일반", "권한", "콤보", "MCP"])
    }

    // 2. Transitions.
    func testOpenAndSwapContent() {
        var s = SettingsPanelState()
        XCTAssertFalse(s.isOpen)
        XCTAssertTrue(s.open(.gadget(.calendarClock, .settings)))
        XCTAssertEqual(s.route, .gadget(.calendarClock, .settings))
        XCTAssertTrue(s.tileClick(.diskMap))
        XCTAssertEqual(s.route, .gadget(.diskMap, .settings), "another tile swaps the content")
        XCTAssertTrue(s.isOpen)
    }

    func testSameTileClosesAndPillToggles() {
        var s = SettingsPanelState()
        s.tileClick(.clipboard)
        XCTAssertTrue(s.isOpen)
        s.tileClick(.clipboard)
        XCTAssertFalse(s.isOpen, "the same tile again closes")
        s.settingsPillClick()
        XCTAssertEqual(s.route, .app(.general))
        s.settingsPillClick()
        XCTAssertFalse(s.isOpen, "the pill again closes")
        s.tileClick(.clipboard)
        s.settingsPillClick()
        XCTAssertEqual(s.route, .app(.general), "pill while a gadget is shown swaps to app settings")
    }

    func testCloseAndEditing() {
        var s = SettingsPanelState(route: .app(.mcp))
        s.close()
        XCTAssertNil(s.route)
        s.open(.gadget(.keepAwake, .shortcuts))
        s.beginEditing()
        XCTAssertNil(s.route, "edit mode closes the panel")
        XCTAssertTrue(s.editing)
        XCTAssertFalse(s.open(.app(.general)), "nothing opens while editing")
        XCTAssertFalse(s.tileClick(.keepAwake))
        XCTAssertFalse(s.settingsPillClick())
        XCTAssertNil(s.route)
        s.endEditing()
        XCTAssertFalse(s.editing)
        XCTAssertTrue(s.open(.app(.combos)))
        XCTAssertEqual(s.route, .app(.combos))
    }

    // 3. Entry points.
    func testEntryRoutes() {
        XCTAssertEqual(SettingsEntry.settingsPill.route, .app(.general))
        XCTAssertEqual(SettingsEntry.menuBarSettings.route, .app(.general))
        XCTAssertEqual(SettingsEntry.firstRunCombo.route, .app(.combos))
        XCTAssertEqual(SettingsEntry.combos.route, .app(.combos))
        XCTAssertEqual(SettingsEntry.permissionsOverview.route, .app(.permissions))
        XCTAssertEqual(SettingsEntry.mcp.route, .app(.mcp))
        XCTAssertEqual(SettingsEntry.whenNeeded(.windowSnap, needsPermission: true).route, .gadget(.windowSnap, .permissions))
        XCTAssertEqual(SettingsEntry.whenNeeded(.keepAwake, needsPermission: false).route, .gadget(.keepAwake, .settings))
    }

    // 4. Old keys still work.
    func testLegacyKeys() {
        XCTAssertNil(SettingsEntry.deepLink(page: "home", tab: nil).route, "home closes the panel")
        XCTAssertEqual(SettingsEntry.deepLink(page: "combos", tab: nil).route, .app(.combos))
        XCTAssertEqual(SettingsEntry.deepLink(page: "general", tab: nil).route, .app(.general))
        XCTAssertEqual(SettingsEntry.deepLink(page: "permissions", tab: nil).route, .app(.permissions))
        XCTAssertEqual(SettingsEntry.deepLink(page: "mcp", tab: nil).route, .app(.mcp))
        XCTAssertEqual(SettingsEntry.deepLink(page: "systemMonitor", tab: "overview").route, .gadget(.systemMonitor, .settings),
                       "overview moved into the settings tab")
        XCTAssertEqual(SettingsEntry.deepLink(page: "systemMonitor", tab: "settings").route, .gadget(.systemMonitor, .settings))
        XCTAssertEqual(SettingsEntry.deepLink(page: "systemMonitor", tab: "shortcuts").route, .gadget(.systemMonitor, .shortcuts))
        XCTAssertEqual(SettingsEntry.deepLink(page: "systemMonitor", tab: "permissions").route, .gadget(.systemMonitor, .permissions))
        XCTAssertNil(SettingsEntry.deepLink(page: "nonsense", tab: nil).route)
        XCTAssertEqual(SettingsPanelRoute(legacyPage: "general")?.key, "general")
        XCTAssertEqual(SettingsPanelRoute.gadget(.diskMap, .shortcuts).key, "diskMap")
    }
}
