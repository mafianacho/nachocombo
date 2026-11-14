import AppKit
import XCTest
@testable import NachoCombo
@testable import NachoComboCore

/// The real Nacho Pet settings card (PetSettingsCard), signed out, drawn off screen in light and dark. Release 0.10.0:
/// the "On This Mac" note says Nacho quits an app only after you approve it (combo_quit_app, #27) instead of "never
/// quits apps". AppKit off-screen renders on macOS CI, not a real Mac.
/// Pictures go to .build/bento-captures and, base64 in chunks, to the test log (BENTO-CAPTURE lines) for CI.
final class PetSettingsCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var outDir: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bento-captures")
    }

    private func texts(_ v: NSView) -> [String] {
        var out: [String] = []
        if let f = v as? NSTextField { out.append(f.stringValue) }
        for s in v.subviews { out += texts(s) }
        return out
    }

    func testSettingsCardSaysQuitOnlyAfterApproval() throws {
        let width = GadgetDetailView.cardInner
        let card = PetSettingsCard(module: NachoPetModule(), width: width)
        let all = texts(card.view).joined(separator: "\n")
        XCTAssertTrue(all.contains("Nacho quits an app only after you approve it on a card"), all)
        XCTAssertFalse(all.contains("never quits apps"), "the old note is gone")

        for dark in [false, true] {
            let size = NSSize(width: width + 32, height: max(card.view.fittingSize.height + 32, 400))
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            root.wantsLayer = true
            root.layer?.backgroundColor = (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
            root.addSubview(card.view)
            NSLayoutConstraint.activate([
                card.view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                card.view.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
                card.view.widthAnchor.constraint(equalToConstant: width),
            ])
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rep = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try emit(png, name: "pet-settings-\(dark ? "dark" : "light")")
            card.view.removeFromSuperview()
        }
    }

    private func emit(_ png: Data, name: String) throws {
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
        XCTAssertGreaterThan(png.count, 10_000, "\(name) is not empty")
    }
}
