import XCTest
@testable import NachoComboCore

/// NACHO-239 / NACHO-131: the Connections tab as values (rows, details, gadget actions, connect plans).
final class ConnectionsTabTests: XCTestCase {
    private func overview() -> ConnectorOverview {
        var o = ConnectorOverview()
        o.tools = [
            ToolRow(id: "t1", name: "tool_search", description: "필요한 도구를 찾아요. 대화마다 써요.", kind: "builtin", source: nil, enabled: true, userEnabled: true, locked: true),
            ToolRow(id: "t2", name: "search_web", description: "웹에서 정보를 찾아요.", kind: "builtin", source: nil, enabled: true, userEnabled: false, locked: false),
            ToolRow(id: "t3", name: "weather_now", description: "", kind: "http", source: nil, enabled: true),
            ToolRow(id: "t4", name: "gmail_search_messages", description: "받은편지함에서 메일을 검색해요.", kind: "connection", source: "gmail", enabled: true),
        ]
        o.connections = [
            ConnectionRow(id: "c1", source: "gmail", label: "Gmail", status: "connected", needsAttention: nil, accountLabel: "d***@gmail.com",
                          scopeSummary: "읽기만", link: nil, enabled: true, version: 3, connectKind: "oauth", scopeLevel: "read"),
            ConnectionRow(id: "c2", source: "naver_mail", label: "네이버 메일", status: "needs_reauth", needsAttention: "needs_reauth", accountLabel: nil,
                          scopeSummary: "읽기와 쓰기", link: nil, enabled: true, version: 1, connectKind: "app_password", scopeLevel: "read_write"),
            ConnectionRow(id: "c3", source: "notion", label: "Notion", status: "connected", needsAttention: nil, accountLabel: nil,
                          scopeSummary: "읽기만", link: nil, enabled: false, version: 2, connectKind: "oauth", scopeLevel: "read"),
        ]
        return o
    }

    private func gadgets(_ extra: [String: String] = [:]) -> [GadgetSwitchState] {
        GadgetSwitchState.states(from: ["windowSnap": "on", "clipboard": "off", "captureFloat": "waiting for permission"].merging(extra) { $1 })
    }

    // MARK: decoding the server contract

    func testToolSwitchFieldsDefaultToOnAndUnlockedWhenTheServerHasNoneYet() {
        let json = #"""
            {"tools":[{"id":"a","name":"x","config":{"kind":"builtin"},"enabled":true},
                      {"id":"b","name":"y","config":{"kind":"builtin"},"enabled":true,"user_enabled":false,"locked":false},
                      {"id":"c","name":"z","config":{"kind":"builtin"},"enabled":true,"user_enabled":true,"locked":true}]}
            """#
        let t = ConnectorDecoder.tools(Data(json.utf8))!.tools
        XCTAssertEqual(t.map { $0.userEnabled }, [true, false, true])
        XCTAssertEqual(t.map { $0.locked }, [false, false, true])
    }

    func testConnectionFieldsAreDecoded() {
        let json = #"[{"id":"u1","source":"gmail","label":"Gmail","status":"connected","enabled":false,"version":7,"connect_kind":"oauth","granted_scope":{"level":"read_write"}}]"#
        let c = ConnectorDecoder.connections(Data(json.utf8))![0]
        XCTAssertFalse(c.enabled)
        XCTAssertEqual(c.version, 7)
        XCTAssertEqual(c.connectKind, "oauth")
        XCTAssertEqual(c.scopeLevel, "read_write")
        let bare = ConnectorDecoder.connections(Data(#"[{"source":"s","status":"connected"}]"#.utf8))![0]
        XCTAssertTrue(bare.enabled)
        XCTAssertEqual(bare.version, 0)
    }

    func testHealthSaysOffBeforeAnythingElseAndNamesTheFourStates() {
        let o = overview().connections
        XCTAssertEqual(o[0].health.label, "연결됨")
        XCTAssertEqual(o[1].health.label, "다시 로그인 필요")
        XCTAssertEqual(o[2].health.label, "꺼짐")
        var perm = o[0]; perm.needsAttention = "needs_permission"
        XCTAssertEqual(perm.health.label, "권한 필요")
        var off = o[1]; off.enabled = false
        XCTAssertEqual(off.health, .off, "a switched-off service reads 꺼짐 even when it needs a login")
        XCTAssertEqual(o[0].statusLine, "연결됨 · d***@gmail.com")
    }

    // MARK: the list

    func testThreeSectionsInOrderWithTheirTitles() {
        let s = ConnectionsListBuilder.sections(overview: overview(), gadgets: gadgets(), disabled: [])
        XCTAssertEqual(s.map { $0.section.title }, ["도구", "커넥터", "가젯"])
    }

    func testToolRowsLockedOffAndConnectionToolsStayOutOfTheToolSection() {
        let tools = ConnectionsListBuilder.sections(overview: overview(), gadgets: gadgets(), disabled: [])[0].rows
        XCTAssertEqual(tools.count, 3, "the Gmail tool belongs to the Gmail detail")
        XCTAssertEqual(tools[0].control, .locked)
        XCTAssertFalse(tools[0].control.canToggle)
        XCTAssertTrue(tools[0].control.isOn)
        XCTAssertEqual(tools[0].status, "기본 도구 · 항상 켜져 있어요")
        XCTAssertEqual(tools[1].control, .off)
        XCTAssertTrue(tools[1].control.canToggle)
        XCTAssertEqual(tools[1].status, "꺼짐")
        XCTAssertEqual(tools[1].title, "웹 검색")
        XCTAssertEqual(tools[2].control, .on)
        XCTAssertEqual(tools[2].status, "HTTP", "without a description the kind is the status line")
    }

    func testConnectorRowsCarryTheSwitchAndOneStatusLine() {
        let rows = ConnectionsListBuilder.sections(overview: overview(), gadgets: gadgets(), disabled: [])[1].rows
        XCTAssertEqual(rows.map { $0.title }, ["Gmail", "네이버 메일", "Notion"])
        XCTAssertEqual(rows.map { $0.control }, [.on, .on, .off])
        XCTAssertEqual(rows[1].status, "다시 로그인 필요")
        XCTAssertEqual(rows[1].tone, .attention)
        XCTAssertEqual(rows[2].status, "꺼짐")
        XCTAssertEqual(rows[0].ref, .connector("c1"))
    }

    func testGadgetRowsFollowTheirSwitchAndCountTheMacActions() {
        let rows = ConnectionsListBuilder.sections(overview: overview(), gadgets: gadgets(), disabled: []).last!.rows
        let window = rows.first { $0.ref == .gadget(.window) }!
        XCTAssertEqual(window.control, .on)
        XCTAssertTrue(window.status.hasPrefix("맥 행동 "), window.status)
        XCTAssertEqual(rows.first { $0.ref == .gadget(.clipboard) }!.status, "꺼짐")
        XCTAssertEqual(rows.first { $0.ref == .gadget(.capture) }!.status, "맥 권한 필요")
        XCTAssertEqual(rows.first { $0.ref == .gadget(.capture) }!.tone, .attention)
        XCTAssertNil(rows.first { $0.ref == .gadget(.combo) }, "Nacho Combo itself is not a gadget row")
        XCTAssertEqual(rows.first { $0.ref == .gadget(.computer) }!.control, .fixed("설정에서 켜요"))
        XCTAssertFalse(rows.first { $0.ref == .gadget(.computer) }!.control.canToggle)
    }

    func testDisablingOneActionChangesTheGadgetSummary() {
        let window = GadgetToolRegistry.all.first { $0.gadget == .window && $0.exits.contains(.connector) }!
        let all = MacActions.rows(for: .window, disabled: [])
        let some = MacActions.rows(for: .window, disabled: [window.connectorName])
        XCTAssertEqual(all.filter { $0.isOn }.count, all.count)
        XCTAssertEqual(some.filter { $0.isOn }.count, all.count - 1)
        XCTAssertTrue(MacActions.summary(some).contains("\(all.count)개 중 \(all.count - 1)개 허용"), MacActions.summary(some))
    }

    func testSearchFiltersEverySectionAndHidesEmptyOnes() {
        let o = overview()
        let mail = ConnectionsListBuilder.sections(overview: o, gadgets: gadgets(), disabled: [], query: " 메일 ")
        XCTAssertEqual(mail.map { $0.section }, [.connectors], "only the naver mail connector matches")
        XCTAssertEqual(mail[0].rows.map { $0.title }, ["네이버 메일"])
        let g = ConnectionsListBuilder.sections(overview: o, gadgets: gadgets(), disabled: [], query: "GMAIL")
        XCTAssertEqual(g.map { $0.section }, [.connectors], "case-insensitive, by source too")
        XCTAssertTrue(ConnectionsListBuilder.sections(overview: o, gadgets: gadgets(), disabled: [], query: "없는이름").isEmpty)
        XCTAssertEqual(ConnectionsListBuilder.sections(overview: o, gadgets: gadgets(), disabled: [], query: "").count, 3)
    }

    func testBeforeTheServerListLoadsTheGadgetSectionStillShows() {
        let s = ConnectionsListBuilder.sections(overview: nil, gadgets: gadgets(), disabled: [])
        XCTAssertEqual(s.map { $0.rows.isEmpty }, [true, true, false])
    }

    // MARK: words

    func testToolNamesBecomeWords() {
        XCTAssertEqual(ToolWords.title("search_web"), "웹 검색")
        XCTAssertEqual(ToolWords.title("gmail_search_messages"), "gmail 메시지 검색")
        XCTAssertEqual(ToolWords.title("list-calendar-events"), "캘린더 일정 목록 보기")
        XCTAssertEqual(ToolWords.title("zzz_unknown"), "zzz unknown")
        XCTAssertEqual(ToolWords.firstSentence("메일을 검색해요. 받은편지함만 봐요."), "메일을 검색해요.")
        XCTAssertEqual(ToolWords.firstSentence(""), "")
        XCTAssertEqual(ToolWords.firstSentence(String(repeating: "가", count: 200), limit: 20).count, 20)
    }

    // MARK: gadget actions come from the registry

    func testEveryGadgetActionIsARegistryConnectorToolWithAKoreanSentence() {
        let registry = Set(GadgetToolRegistry.all.filter { $0.exits.contains(.connector) }.map { $0.connectorName })
        var seen = Set<String>()
        for g in GadgetSwitchState.listed {
            for a in MacActions.rows(for: g, disabled: []) {
                XCTAssertTrue(registry.contains(a.id), a.id)
                XCTAssertFalse(a.title.isEmpty, a.id)
                XCTAssertTrue(ToolWords.hasHangul(a.title), "\(a.id): \(a.title)")
                seen.insert(a.id)
            }
        }
        XCTAssertTrue(registry.subtracting(seen).isSubset(of: Set(GadgetToolRegistry.all.filter { $0.gadget == .combo }.map { $0.connectorName })),
                      "every connector tool but Nacho Combo's own is listed under some gadget")
        XCTAssertGreaterThanOrEqual(seen.count, 15)
    }

    func testSwitchingAnActionOffGoesThroughTheExistingDeclarationFilter() {
        let tool = GadgetToolRegistry.all.first { $0.gadget == .window && $0.exits.contains(.connector) }!
        let trust = GadgetTrust(trustable: { [] })
        let before = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: trust.disabled).compactMap { $0["name"] as? String }
        XCTAssertTrue(before.contains(tool.declaredConnectorName))
        var changes = 0
        trust.observe { changes += 1 }
        trust.setActionEnabled(tool, false)
        XCTAssertEqual(trust.disabled, [tool.connectorName])
        XCTAssertFalse(trust.isActionEnabled(tool))
        let after = PetCommands.capabilities(allowQuit: true, alwaysAllowed: [], disabled: trust.disabled).compactMap { $0["name"] as? String }
        XCTAssertFalse(after.contains(tool.declaredConnectorName), "the declaration leaves the action out")
        XCTAssertEqual(changes, 1, "observers (the connector's redeclare) are told")
        trust.setActionEnabled(tool, true)
        XCTAssertTrue(trust.disabled.isEmpty)
        XCTAssertEqual(changes, 2)
    }

    func testSwitchingOnClearsAnOldNameToo() {
        let tool = GadgetToolRegistry.all.first { $0.legacyConnectorName != nil && $0.exits.contains(.connector) }!
        let trust = GadgetTrust(trustable: { [] })
        trust.disabled = [tool.legacyConnectorName!]
        XCTAssertFalse(trust.isActionEnabled(tool))
        trust.setActionEnabled(tool, true)
        XCTAssertTrue(trust.isActionEnabled(tool))
    }

    // MARK: details

    func testToolDetailExplainsTheLock() {
        let o = overview()
        let locked = ConnectionsDetailBuilder.tool(o.tools[0])
        XCTAssertEqual(locked.control, .locked)
        XCTAssertEqual(locked.notice, "나초가 대화하는 데 꼭 필요한 기본 도구라서 끌 수 없어요.")
        let off = ConnectionsDetailBuilder.tool(o.tools[1])
        XCTAssertEqual(off.status, "꺼짐")
        XCTAssertEqual(off.notice, "꺼 두면 나초가 이 도구를 고르지 않아요.")
    }

    func testConnectorDetailListsTheServicesToolsAndAsksBeforeDisconnecting() {
        let o = overview()
        let d = ConnectionsDetailBuilder.connector(o.connections[0], tools: o.tools)
        XCTAssertEqual(d.abilities.map { $0.title }, ["gmail 메시지 검색"])
        XCTAssertEqual(d.abilities[0].note, "받은편지함에서 메일을 검색해요.")
        XCTAssertEqual(d.facts, [ConnectionsFact(label: "계정", value: "d***@gmail.com"), ConnectionsFact(label: "권한 범위", value: "읽기만")])
        XCTAssertEqual(d.scope?.selected, "read")
        XCTAssertEqual(d.disconnect?.confirmTitle, "Gmail 연결을 끊을까요?")
        XCTAssertTrue(d.disconnect!.confirmMessage.contains("되돌릴 수 없어요"))
        XCTAssertNil(d.reconnectTitle)
    }

    func testConnectorDetailNeedingALoginOffersToSignInAgain() {
        let o = overview()
        let d = ConnectionsDetailBuilder.connector(o.connections[1], tools: o.tools)
        XCTAssertEqual(d.status, "다시 로그인 필요")
        XCTAssertEqual(d.reconnectTitle, "다시 로그인")
        XCTAssertEqual(d.tone, .attention)
        XCTAssertTrue(d.notice!.contains("로그인이 만료됐어요"))
        let off = ConnectionsDetailBuilder.connector(o.connections[2], tools: o.tools)
        XCTAssertEqual(off.control, .off)
        XCTAssertEqual(off.status, "꺼짐")
    }

    func testConnectorDetailFallsBackToWhatTheServerSaysNachoCanDo() {
        var info = ConnectionDetailInfo()
        info.summary = "메일을 읽고 검색해요."
        info.canDo = ["메일 읽기", "메일 검색"]
        let c = overview().connections[1]
        let d = ConnectionsDetailBuilder.connector(c, tools: [], info: info)
        XCTAssertEqual(d.summary, "메일을 읽고 검색해요.")
        XCTAssertEqual(d.abilities.map { $0.title }, ["메일 읽기", "메일 검색"])
        let parsed = ConnectionDetailInfo.decode(Data(#"{"service":{"summary":"요약"},"notice":{"can_do":["a"],"cannot_do":["b"]},"ask_first":["결제"],"accounts":[{"account_label":"x***"}]}"#.utf8))!
        XCTAssertEqual(parsed.summary, "요약")
        XCTAssertEqual(parsed.canDo, ["a"])
        XCTAssertEqual(parsed.askFirst, ["결제"])
        XCTAssertEqual(parsed.accounts, ["x***"])
    }

    func testGadgetDetailListsTheMacActionsWithTheirSwitchesAndPermissions() {
        let g = GadgetSwitchState(id: .window, phase: .on)
        let tool = GadgetToolRegistry.all.first { $0.gadget == .window && $0.exits.contains(.connector) }!
        let d = ConnectionsDetailBuilder.gadget(g, disabled: [tool.connectorName])
        XCTAssertEqual(d.abilitiesTitle, "이 맥에서 나초가 하는 일")
        XCTAssertEqual(d.abilities.count, MacActions.rows(for: .window, disabled: []).count)
        XCTAssertEqual(d.abilities.first { $0.id == tool.connectorName }?.isOn, false)
        XCTAssertEqual(d.abilities.filter { $0.isOn == true }.count, d.abilities.count - 1)
        XCTAssertFalse(d.summary.isEmpty)
        let permitted = d.abilities.filter { !$0.permissions.isEmpty }
        for a in permitted { XCTAssertTrue(a.note!.hasPrefix("맥 권한: "), a.id) }
        XCTAssertNil(d.disconnect)
    }

    func testGadgetOffDetailSaysPermissionsAreAskedWhenTurningOn() {
        let d = ConnectionsDetailBuilder.gadget(GadgetSwitchState(id: .clipboard, phase: .off), disabled: [])
        XCTAssertEqual(d.status, "꺼짐")
        XCTAssertTrue(d.notice!.contains("켤 때 물어봐요"))
    }

    // MARK: connecting

    func testConnectPlansByKind() {
        XCTAssertEqual(MacConnectPlan.plan(connectKind: "oauth"), .browser)
        XCTAssertEqual(MacConnectPlan.plan(connectKind: "app_password"), .appPassword)
        for kind in ["qr", "site"] {
            guard case let .unsupported(reason, alternative) = MacConnectPlan.plan(connectKind: kind) else { return XCTFail(kind) }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertEqual(alternative, "휴대폰의 나초 앱에서 연결해 주세요.")
        }
        guard case let .unsupported(why, _) = MacConnectPlan.plan(connectKind: "oauth", supportStatus: "unsupported", supportReason: "점검 중이에요") else { return XCTFail() }
        XCTAssertEqual(why, "점검 중이에요")
        XCTAssertEqual(MacConnectPlan.plan(connectKind: "oauth", supportStatus: "limited"), .browser)
    }

    func testAttemptStatesBecomeProgressTheUserReads() {
        func attempt(_ state: String, _ failure: String? = nil) -> AttemptInfo {
            AttemptInfo(attemptID: "a", source: "gmail", state: state, failure: failure, connectionID: nil)
        }
        XCTAssertEqual(ConnectProgress.from(attempt("awaiting_provider")), .inBrowser)
        XCTAssertEqual(ConnectProgress.from(attempt("verifying")), .verifying)
        XCTAssertEqual(ConnectProgress.from(attempt("completed")), .done)
        XCTAssertEqual(ConnectProgress.from(attempt("expired")), .expired)
        XCTAssertEqual(ConnectProgress.from(attempt("failed", "access_denied")), .failed("동의하지 않아서 연결하지 않았어요."))
        XCTAssertTrue(ConnectProgress.done.isFinished)
        XCTAssertFalse(ConnectProgress.inBrowser.isFinished)
        XCTAssertTrue(attempt("completed").isTerminal)
        XCTAssertFalse(attempt("verifying").isTerminal)
        for code in ["access_denied", "scopes_declined", "wrong_account", "authentication_failed", "transport", "zzz", nil as String?] {
            XCTAssertFalse(AttemptFailureText.text(code).isEmpty)
        }
    }
}
