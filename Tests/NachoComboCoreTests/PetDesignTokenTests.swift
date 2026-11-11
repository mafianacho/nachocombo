import Foundation
import XCTest

@testable import NachoComboCore

/// design/tokens.json is the single source. The web mockup (design/web/tokens.css) and the app (PetDesignTokens.swift,
/// generated) must carry exactly its values.
final class PetDesignTokenTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func flatJSON() throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("design/tokens.json"))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var out: [String: String] = [:]
        for (group, value) in o where !group.hasPrefix("$") {
            let g = try XCTUnwrap(value as? [String: Any], group)
            for (k, v) in g {
                if group == "color" {
                    for (ck, cv) in try XCTUnwrap(v as? [String: String], k) { out["color.\(k).\(ck)"] = cv }
                } else if let s = v as? String {
                    out["\(group).\(k)"] = s
                } else {
                    out["\(group).\(k)"] = PetTokens.text(try XCTUnwrap(v as? Double, "\(group).\(k)"))
                }
            }
        }
        return out
    }

    func testSwiftConstantsEqualTokensJSON() throws {
        let json = try flatJSON()
        XCTAssertEqual(json.count, PetTokens.flat.count)
        for (k, v) in json { XCTAssertEqual(PetTokens.flat[k], v, k) }
        XCTAssertEqual(PetTokens.Size.pet, 112)
        XCTAssertEqual(PetTokens.light.accent, json["color.light.accent"])
        XCTAssertEqual(PetTokens.dark.window, json["color.dark.window"])
    }

    func testWebCSSVariablesEqualTokensJSON() throws {
        let css = try String(contentsOf: root.appendingPathComponent("design/web/tokens.css"), encoding: .utf8)
        let parts = css.components(separatedBy: "[data-theme=\"dark\"] {")
        XCTAssertEqual(parts.count, 2, "one dark block")
        let lightAndBase = parts[0], dark = parts[1]
        func kebab(_ s: String) -> String {
            var out = ""
            for ch in s {
                if ch.isUppercase { out += "-" + ch.lowercased() } else { out.append(ch) }
            }
            return out
        }
        let unitless: Set<String> = ["font.weightRegular", "font.weightMedium", "font.weightSemibold", "font.lineHeight", "shadow.petOpacity"]
        var checked = 0
        for (key, value) in try flatJSON() {
            let p = key.split(separator: ".").map(String.init)
            let line: String
            let block: String
            if p[0] == "color" {
                line = "  --color-\(kebab(p[2])): \(value);"
                block = p[1] == "dark" ? dark : lightAndBase
            } else {
                let raw = p[0] == "font" && p[1] == "family" || p[0] == "curve" || p[0] == "motionAmount" || unitless.contains(key)
                let unit = raw ? "" : (p[0] == "motion" ? "ms" : "px")
                line = "  --\(kebab(p[0]))-\(kebab(p[1])): \(value)\(unit);"
                block = lightAndBase
            }
            XCTAssertTrue(block.contains(line + "\n"), "missing in tokens.css: \(line)")
            checked += 1
        }
        XCTAssertEqual(css.components(separatedBy: "\n").filter { $0.hasPrefix("  --") }.count, checked, "no extra variables")
    }

    func testColorsAreValidHexAndTextIsReadable() throws {
        for (key, value) in PetTokens.flat where key.hasPrefix("color.") {
            XCTAssertNotNil(PetColorHex.parse(value), "\(key)=\(value)")
        }
        // WCAG 2.x contrast for text on the surfaces it sits on (4.5:1 normal text).
        for (name, p) in [("light", PetTokens.light), ("dark", PetTokens.dark)] {
            let pairs: [(String, String, String)] = [
                ("text/surface", p.text, p.surface), ("textSecondary/surface", p.textSecondary, p.surface),
                ("textTertiary/surfaceRaised", p.textTertiary, p.surfaceRaised), ("mineText/mineBubble", p.mineText, p.mineBubble),
                ("nachoText/nachoBubble", p.nachoText, p.nachoBubble), ("link/surface", p.link, p.surface),
                ("onAccent/accent", p.onAccent, p.accent), ("onTooltip/tooltip", p.onTooltip, p.tooltip),
                ("warning/warningSoft", p.warning, p.warningSoft), ("danger/dangerSoft", p.danger, p.dangerSoft),
                ("onDanger/danger", p.onDanger, p.danger),
            ]
            for (label, fg, bg) in pairs {
                let r = PetColorHex.contrast(fg, on: bg, backdrop: p.window)
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(name) \(label) = \(String(format: "%.2f", r))")
            }
        }
    }
}
