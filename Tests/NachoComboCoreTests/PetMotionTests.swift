import Foundation
import XCTest
@testable import NachoComboCore

/// PetMotion.swift must move the pet exactly like the web mockup's design/web/motion.js: the fixture holds the web
/// model's poses (scripts/motion-vectors.mjs) for the same timelines.
final class PetMotionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fixture() throws -> [String: Any] {
        let url = root.appendingPathComponent("Tests/NachoComboCoreTests/Fixtures/pet-motion-vectors.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testSwiftPosesMatchTheWebModel() throws {
        let all = try fixture()
        XCTAssertEqual(Set(all.keys), ["states", "touch", "reduced"])
        var compared = 0
        for (name, value) in all {
            let tl = try XCTUnwrap(value as? [String: Any])
            let events = try XCTUnwrap(tl["events"] as? [[Any]])
            let samples = try XCTUnwrap(tl["samples"] as? [[String: Any]])
            let first = try XCTUnwrap(PetFace(rawValue: events[0][2] as? String ?? ""))
            var m = PetMotion(face: first, at: 0, reduceMotion: tl["reduceMotion"] as? Bool ?? false,
                              seed: UInt32(tl["seed"] as? Int ?? 1))
            var next = 1
            for s in samples {
                let t = try XCTUnwrap(s["t"] as? Double)
                while next < events.count, let at = events[next][0] as? Double, at <= t {
                    let op = events[next][1] as? String
                    switch op {
                    case "face": m.setFace(try XCTUnwrap(PetFace(rawValue: events[next][2] as? String ?? "")), at: at)
                    case "press": m.press(at: at)
                    case "release": m.release(at: at)
                    case "drag": m.drag(velocityX: try XCTUnwrap(events[next][2] as? Double), at: at)
                    case "drop": m.drop(at: at)
                    default: XCTFail("unknown event \(String(describing: op))")
                    }
                    next += 1
                }
                let p = m.pose(at: t)
                let label = "\(name) @\(Int(t))ms"
                XCTAssertEqual(p.asset, s["asset"] as? String, label)
                XCTAssertEqual(p.previous, s["previous"] as? String, label)
                for (key, value) in [("mix", p.mix), ("dx", p.dx), ("dy", p.dy), ("scaleX", p.scaleX), ("scaleY", p.scaleY), ("rotation", p.rotation)] {
                    XCTAssertEqual(value, try XCTUnwrap(s[key] as? Double, "\(label) \(key)"), accuracy: 0.001, "\(label) \(key)")
                }
                XCTAssertEqual(m.isAnimating(at: t), s["animating"] as? Bool, label)
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 500)
    }

    func testThePreviewShowsEveryMove() throws {
        let samples = try XCTUnwrap((try fixture()["states"] as? [String: Any])?["samples"] as? [[String: Any]])
        let assets = Set(samples.compactMap { $0["asset"] as? String })
        // 9 of the 10 originals: body.webp has no face, so it is not a pose.
        XCTAssertEqual(assets, ["idle", "eyes-closed", "calling", "calling-eyeless", "thinking", "working", "happy", "tired"])
        XCTAssertTrue(samples.contains { ($0["previous"] as? String) != nil }, "crossfades")
        XCTAssertTrue(samples.contains { ($0["dy"] as? Double ?? 0) > 8 }, "happy hop")
        XCTAssertTrue(samples.contains { abs($0["rotation"] as? Double ?? 0) > 4 }, "drag tilt")
    }

    func testReducedMotionOnlyCrossfadesAndThenStops() {
        var m = PetMotion(face: .idle, at: 0, reduceMotion: true, seed: 5)
        XCTAssertFalse(m.isAnimating(at: 10_000), "no breathing loop: no frames, no CPU")
        XCTAssertEqual(m.pose(at: 10_000), PetPose(asset: "idle", previous: nil))
        m.setFace(.thinking, at: 20_000)
        let mid = m.pose(at: 20_000 + PetTokens.Motion.transition / 2)
        XCTAssertEqual(mid.previous, "idle")
        XCTAssertEqual(mid.scaleX, 1)
        XCTAssertTrue(m.isAnimating(at: 20_100))
        XCTAssertFalse(m.isAnimating(at: 20_000 + PetTokens.Motion.transition))
        m.setFace(.tired, at: 30_000)
        XCTAssertEqual(m.asset(at: 30_000 + PetTokens.Motion.drowsePeriod - 10), "tired", "no dozing swap either")
    }

    func testBlinksAreShortAndOnlyWhereAnEyesShutTwinExists() {
        let m = PetMotion(face: .idle, at: 0, seed: 5)
        var shut = 0, run = 0, longest = 0
        for t in stride(from: 0.0, through: 60_000, by: 10) {
            if m.asset(at: t) == "eyes-closed" { shut += 1; run += 1; longest = max(longest, run) } else { run = 0 }
        }
        XCTAssertGreaterThan(shut, 0)
        XCTAssertLessThanOrEqual(Double(longest * 10), PetTokens.Motion.blink + 10)
        for face in PetFace.allCases where PetMotion.blinkAsset(face) == nil && face != .tired {
            let f = PetMotion(face: face, at: 0, seed: 5)
            XCTAssertTrue(stride(from: 0.0, through: 30_000, by: 50).allSatisfy { f.asset(at: $0) == face.assetName }, "\(face)")
        }
    }

    func testCurvesFollowCSS() {
        let linear = PetCurve("cubic-bezier(0, 0, 1, 1)")
        XCTAssertEqual(linear.y(0.3), 0.3, accuracy: 1e-6)
        let standard = PetCurve(PetTokens.Curve.standard)
        XCTAssertEqual(standard.y(0), 0)
        XCTAssertEqual(standard.y(1), 1)
        XCTAssertGreaterThan(standard.y(0.5), 0.5, "eases out")
        XCTAssertGreaterThan((0...100).map { PetCurve(PetTokens.Curve.emphasized).y(Double($0) / 100) }.max() ?? 0, 1, "overshoots")
    }
}
