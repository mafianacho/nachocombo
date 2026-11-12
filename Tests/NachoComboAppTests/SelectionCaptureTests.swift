import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// Draws the real AppKit selection bar pieces off screen (bar, question, preview, long selection, sent request and
/// answer, first-use card, settings), light and dark, to compare with the mockup scenes (design/web ?scene=sel-…).
/// The text below is a TEST FIXTURE in the state of the mockup; the app shows only what the user selected.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class SelectionCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    static let selected = "Every gadget starts off. Switching one on never asks for a permission it does not need, and switching it off stops it completely."
    static let title = "mafianacho/nachocombo: Small Mac gadgets in one box"

    private func capture(_ text: String = SelectionCaptureTests.selected) -> PetSelectionCapture {
        PetSelectionCapture(text: text, appName: "Safari", bundleID: "com.apple.Safari", windowTitle: SelectionCaptureTests.title,
                            url: "https://github.com/mafianacho/nachocombo", pageTitle: SelectionCaptureTests.title,
                            before: String(repeating: "Nacho Combo puts the small tools a Mac user reaches for every day into one menu bar app. ", count: 2)
                                .prefix(162).description,
                            after: String("The Nacho character sits in a corner of the screen and can be asked about anything.".prefix(96)), language: "en")
    }

    final class Recorder: PetSelectionSending {
        func sendSelection(_ sent: PetSelectionSent, completion: @escaping (String?) -> Void) { completion(nil) }
    }

    final class Host: PetSelectionSettingsHost {
        var s = PetSelectionBarSettings()
        init() {
            s.enabled = true
            s.excludedApps = [PetExcludedApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")]
        }
        var selectionSettings: PetSelectionBarSettings { s }
        func updateSelection(_ change: (inout PetSelectionBarSettings) -> Void) { change(&s) }
        var selectionAccessibilityGranted: Bool { true }
        func selectionSwitchedOn() {}
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    /// The pieces on the mockup's desktop colour with some room around them.
    private func stage(_ views: [NSView], width: CGFloat, fill: KeyPath<PetTokens.Palette, String> = \.desktop) -> NSView {
        let bg = PetBox()
        bg.fill = PetTheme.color(fill)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CGFloat(PetTokens.Space.s)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 16), stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        return bg
    }

    private func render(_ view: NSView, width: CGFloat, appearance: NSAppearance.Name, name: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 32, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let content = view.subviews.first?.fittingSize ?? .zero
        let size = NSSize(width: width + 32, height: ceil(content.height) + 32)
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
        let b64 = png.base64EncodedString()
        let chunk = 3000
        let n = (b64.count + chunk - 1) / chunk
        var i = 0
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            print("BENTO-CAPTURE \(name) \(i + 1)/\(n) \(b64[idx..<end])")
            idx = end
            i += 1
        }
        XCTAssertGreaterThan(png.count, 2_000, "\(name) is not empty")
    }

    private func both(_ name: String, width: CGFloat, _ make: () -> NSView) throws {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try render(make(), width: width, appearance: appearance, name: "\(name)-impl-\(suffix)")
        }
    }

    private var chatWidth: CGFloat { CGFloat(PetTokens.Size.chatWidth - 2 * PetTokens.Space.m) }

    private func items(_ list: [PetChatItem]) -> [NSView] {
        let maker = PetItemViews(width: chatWidth, onLink: { _ in }, onExample: { _ in })
        return list.map { maker.view($0) }
    }

    func testBarAndQuestion() throws {
        let bar = PetSelectionBarView(mode: .buttons(compact: false), buttons: PetSelectionAction.orderable)
        let buttons = bar.subviews.first?.subviews.compactMap { $0 as? PetSelectionButton } ?? []
        XCTAssertEqual(buttons.count, 7, "copy, search, translate, summarize, explain | ask Nacho, more")
        var s = PetSelectionBarSettings()
        s.hidden = [.search]
        let fewer = PetSelectionBarView(mode: .buttons(compact: false), buttons: s.visibleButtons)
        XCTAssertEqual(fewer.subviews.first?.subviews.compactMap { $0 as? PetSelectionButton }.count, 6)
        try both("sel-bar", width: 560) {
            stage([PetSelectionBarView(mode: .buttons(compact: false), buttons: PetSelectionAction.orderable)], width: 560)
        }
        try both("sel-ask", width: CGFloat(PetTokens.Size.selectAskWidth)) {
            stage([PetSelectionBarView(mode: .ask, buttons: [], question: "이 문장 쉽게 풀어서 설명해 줘")], width: CGFloat(PetTokens.Size.selectAskWidth))
        }
    }

    func testPreviewCards() throws {
        let flow = PetSelectionFlow(sender: Recorder(), copyText: { _ in }, openURL: { _ in })
        var on = PetSelectionBarSettings()
        on.enabled = true
        flow.present(capture())
        flow.choose(.translate, settings: on)
        flow.toggle(.around)
        let preview = try XCTUnwrap(flow.preview)
        XCTAssertEqual(preview.title, "번역 · 한국어로")
        try both("sel-preview", width: chatWidth) { stage(items([.selectionPreview(preview)]), width: chatWidth, fill: \.window) }

        flow.present(capture(String(repeating: SelectionCaptureTests.selected + " ", count: 100)))
        flow.choose(.summarize, settings: on)
        let long = try XCTUnwrap(flow.preview)
        XCTAssertNotNil(long.rows.first?.warning)
        try both("sel-long", width: chatWidth) { stage(items([.selectionPreview(long)]), width: chatWidth, fill: \.window) }
    }

    func testSentRequestAnswerAndIntro() throws {
        let ctx = PetSelectionContext(capture())
        let sent = PetSelectionSent(action: .summarize, instruction: "요약해 줘", chip: ctx.chipText, rows: ctx.rows, file: try XCTUnwrap(ctx.file()))
        try both("sel-result", width: chatWidth) {
            stage(items([.mine(text: "요약해 줘", attachments: [], past: false), .requestChip(sent.chip),
                         .nacho(text: "가젯은 처음에 모두 꺼져 있고, 켤 때 꼭 필요한 권한만 묻고, 끄면 완전히 멈춘다는 설명이에요.", past: false, streaming: false),
                         .answerActions(turnID: "c1", showingSent: true), .sentContext(sent.rows)]), width: chatWidth, fill: \.window)
        }
        try both("sel-intro", width: chatWidth) { stage(items([.selectionIntro]), width: chatWidth, fill: \.window) }
    }

    func testSettingsSection() throws {
        let host = Host()
        let width = GadgetDetailView.cardInner
        try both("sel-settings", width: width) {
            let section = PetSelectionSettingsSection(host: host, width: width)
            return stage([section.view], width: width, fill: \.window)
        }
    }
}
