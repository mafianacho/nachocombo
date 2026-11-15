import Foundation
import XCTest
@testable import NachoComboCore

// NACHO-146: Window Snap MCP tools: grid, 2/3/4 splits, ratios, multi-display coordinates, undo, argument checks,
// registry integrity and an MCP round trip with a stub runner.

private let screen = CGRect(x: 0, y: 25, width: 1200, height: 775)

private func cells(_ r: Result<[CGRect], WindowTilingError>, file: StaticString = #filePath, line: UInt = #line) -> [CGRect] {
    switch r {
    case .success(let c): return c
    case .failure(let e): XCTFail("unexpected \(e)", file: file, line: line); return []
    }
}

/// No overlap, nothing outside `area`, and (without gap) the cells fill the area.
private func assertTiles(_ c: [CGRect], in area: CGRect, filled: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
    for (i, a) in c.enumerated() {
        XCTAssertTrue(area.contains(a), "cell \(i) \(a) outside \(area)", file: file, line: line)
        for b in c[(i + 1)...] {
            let overlap = a.intersection(b)
            XCTAssertTrue(overlap.isNull || overlap.width * overlap.height == 0, "\(a) overlaps \(b)", file: file, line: line)
        }
    }
    if filled { XCTAssertEqual(c.map { $0.width * $0.height }.reduce(0, +), area.width * area.height, file: file, line: line) }
}

final class WindowTilingTests: XCTestCase {
    func testGridShapeForOneToNine() {
        XCTAssertEqual((1...9).map { WindowTiling.gridRows($0) },
                       [[1], [2], [2, 1], [2, 2], [3, 2], [3, 3], [3, 3, 1], [3, 3, 2], [3, 3, 3]])
    }

    func testGridFramesForOneToNineTileTheScreenExactly() {
        for n in 1...9 {
            let c = cells(WindowTiling.grid(count: n, in: screen))
            XCTAssertEqual(c.count, n, "n=\(n)")
            assertTiles(c, in: screen)
        }
    }

    func testGridReadingOrderAndSpecificFrames() {
        let two = cells(WindowTiling.grid(count: 2, in: screen))
        XCTAssertEqual(two, [CGRect(x: 0, y: 25, width: 600, height: 775), CGRect(x: 600, y: 25, width: 600, height: 775)])
        let four = cells(WindowTiling.grid(count: 4, in: screen))
        XCTAssertEqual(four[0].minX, 0); XCTAssertEqual(four[0].maxY, screen.maxY, "first cell is top-left")
        XCTAssertEqual(four[3].maxX, screen.maxX); XCTAssertEqual(four[3].minY, screen.minY, "last cell is bottom-right")
        let three = cells(WindowTiling.grid(count: 3, in: screen))
        XCTAssertEqual(three[2].width, screen.width, "a short last row stretches across the display")
        XCTAssertEqual(three[0].width, 600)
    }

    func testGridOddSizesGiveNoGapAndNoOverlap() {
        let odd = CGRect(x: 0, y: 0, width: 1001, height: 703)
        for n in 1...9 { assertTiles(cells(WindowTiling.grid(count: n, in: odd)), in: odd) }
    }

    func testGridRefusesZeroAndTooManyButHasNoLayoutLimit() {
        XCTAssertEqual(WindowTiling.grid(count: 0, in: screen), .failure(.invalid("A grid needs 1 to 200 windows.")))
        if case .success = WindowTiling.grid(count: 201, in: screen) { XCTFail("201 windows is over the per-call technical limit") }
        // 20 windows (more than 4 per display, more than 8 on two) are fine.
        let twenty = cells(WindowTiling.grid(count: 20, in: screen))
        XCTAssertEqual(twenty.count, 20); assertTiles(twenty, in: screen)
        XCTAssertEqual(cells(WindowTiling.grid(count: 200, in: screen)).count, 200)
        // Tiny cells are placed anyway; the result only warns.
        let tiny = cells(WindowTiling.grid(count: 9, in: CGRect(x: 0, y: 0, width: 320, height: 300)))
        XCTAssertEqual(tiny.count, 9)
        XCTAssertEqual(WindowTiling.tightCells(tiny), 9)
        XCTAssertEqual(WindowTiling.tightCells(cells(WindowTiling.grid(count: 4, in: screen))), 0)
    }

    func testRowsByColsTenByTwo() {
        let c = cells(WindowTiling.grid(count: 20, rows: 10, cols: 2, in: screen))
        XCTAssertEqual(c.count, 20); assertTiles(c, in: screen)
        XCTAssertEqual(Set(c.map { $0.width }), [600])
        XCTAssertEqual(c[0].maxY, screen.maxY); XCTAssertEqual(c[0].minX, 0)
        XCTAssertEqual(c[1].minX, 600, "row major: second window is right of the first")
        XCTAssertEqual(c[2].maxY, c[0].minY, "third window starts the next row")
        XCTAssertEqual(c[19].maxX, screen.maxX); XCTAssertEqual(c[19].minY, screen.minY)
        let byColumn = cells(WindowTiling.grid(count: 20, rows: 10, cols: 2, fill: .columnMajor, in: screen))
        XCTAssertEqual(byColumn[1].maxY, byColumn[0].minY, "column major: second window is below the first")
        XCTAssertEqual(byColumn[10].minX, 600, "column major: the eleventh window starts the second column")
        XCTAssertEqual(byColumn.map { "\($0)" }.sorted(), c.map { "\($0)" }.sorted(), "same cells, different order")
    }

    func testRowsOrColsAlone() {
        XCTAssertEqual(cells(WindowTiling.grid(count: 7, rows: 2, cols: nil, in: screen)).count, 7)   // 2 x 4
        XCTAssertEqual(Set(cells(WindowTiling.grid(count: 7, rows: 2, cols: nil, in: screen)).map { $0.width }), [300])
        XCTAssertEqual(Set(cells(WindowTiling.grid(count: 6, rows: nil, cols: 3, in: screen)).map { $0.height }), [387, 388])
        if case .success = WindowTiling.grid(count: 7, rows: 2, cols: 3, in: screen) { XCTFail("2 x 3 has 6 cells for 7 windows") }
        if case .success = WindowTiling.grid(count: 2, rows: 101, cols: 1, in: screen) { XCTFail("rows above 100") }
        XCTAssertEqual(cells(WindowTiling.grid(count: 3, rows: 5, cols: 5, in: screen)).count, 3, "unused cells stay empty")
    }

    func testTwoDisplaysPerDisplayAndAcross() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055), right = CGRect(x: 0, y: 25, width: 1440, height: 875)
        // Separate grids: 20 windows on two displays, 10 each, an auto grid per display.
        let per = cells(WindowTiling.tile(count: 20, rows: nil, cols: nil, fill: .rowMajor, span: .perDisplay, areas: [left, right]))
        XCTAssertEqual(per.count, 20)
        XCTAssertTrue(per.prefix(10).allSatisfy { left.contains($0) }); XCTAssertTrue(per.suffix(10).allSatisfy { right.contains($0) })
        assertTiles(Array(per.prefix(10)), in: left); assertTiles(Array(per.suffix(10)), in: right)
        // 10 x 2 on each display (20 cells per display, 20 windows -> all on the first display).
        let full = cells(WindowTiling.tile(count: 40, rows: 10, cols: 2, fill: .rowMajor, span: .perDisplay, areas: [left, right]))
        XCTAssertEqual(full.count, 40)
        XCTAssertTrue(full.prefix(20).allSatisfy { left.contains($0) }); XCTAssertTrue(full.suffix(20).allSatisfy { right.contains($0) })
        if case .success = WindowTiling.tile(count: 41, rows: 10, cols: 2, fill: .rowMajor, span: .perDisplay, areas: [left, right]) { XCTFail("41 > 40 cells") }
        // One grid across both: 10 x 2 over the union is 1 column per display width... i.e. cells straddle nothing odd.
        let union = left.union(right)
        let across = cells(WindowTiling.tile(count: 20, rows: 10, cols: 2, fill: .rowMajor, span: .across, areas: [left, right]))
        XCTAssertEqual(across.count, 20); assertTiles(across, in: union)
        // Auto shape across two displays has a whole number of columns per display.
        let auto = cells(WindowTiling.tile(count: 20, rows: nil, cols: nil, fill: .rowMajor, span: .across, areas: [left, right]))
        XCTAssertEqual(auto.count, 20); assertTiles(auto, in: union, filled: false)
        XCTAssertEqual(Set(auto.map { $0.minX }).count % 2, 0, "columns come in pairs, one half per display")
        if case .success = WindowTiling.tile(count: 3, rows: nil, cols: nil, fill: .rowMajor, span: .perDisplay, areas: []) { XCTFail("no display") }
    }

    func testSplitsInEveryDirection() {
        for parts in 2...4 {
            let columns = cells(WindowTiling.split(parts: parts, direction: .horizontal, in: screen))
            XCTAssertEqual(columns.count, parts); assertTiles(columns, in: screen)
            XCTAssertTrue(zip(columns, columns.dropFirst()).allSatisfy { $0.maxX == $1.minX && $0.minX < $1.minX }, "left to right")
            XCTAssertTrue(columns.allSatisfy { $0.height == screen.height })
            let rows = cells(WindowTiling.split(parts: parts, direction: .vertical, in: screen))
            XCTAssertEqual(rows.count, parts); assertTiles(rows, in: screen)
            XCTAssertTrue(zip(rows, rows.dropFirst()).allSatisfy { $0.minY == $1.maxY }, "top to bottom")
            XCTAssertTrue(rows.allSatisfy { $0.width == screen.width })
        }
        let q = cells(WindowTiling.split(parts: 4, direction: .quadrant, in: screen))
        assertTiles(q, in: screen)
        XCTAssertEqual(q[0], CGRect(x: 0, y: 413, width: 600, height: 387))
        XCTAssertEqual(q[3], CGRect(x: 600, y: 25, width: 600, height: 388), "the odd point goes to the bottom row")
        XCTAssertEqual(q[1].minX, q[0].maxX); XCTAssertEqual(q[2].maxY, q[0].minY)
        XCTAssertEqual(cells(WindowTiling.split(parts: 3, direction: .horizontal, in: screen)).map { $0.width }, [400, 400, 400])
    }

    func testSplitRefusesBadParts() {
        for bad in [0, 1, 5] { if case .success = WindowTiling.split(parts: bad, direction: .horizontal, in: screen) { XCTFail("parts \(bad)") } }
        for parts in [2, 3] { if case .success = WindowTiling.split(parts: parts, direction: .quadrant, in: screen) { XCTFail("quadrant of \(parts)") } }
    }

    func testRatioSumAndMinimumSize() {
        let c = cells(WindowTiling.ratio(weights: [70, 30], direction: .horizontal, in: screen))
        XCTAssertEqual(c.map { $0.width }, [840, 360])
        XCTAssertEqual(c.map { $0.width }.reduce(0, +), screen.width, "shares always add up to the whole width")
        assertTiles(c, in: screen)
        let rows = cells(WindowTiling.ratio(weights: [1, 2, 1], direction: .vertical, in: screen))
        XCTAssertEqual(rows.map { $0.height }.reduce(0, +), screen.height)
        XCTAssertEqual(rows[0].maxY, screen.maxY); assertTiles(rows, in: screen)
        let odd = cells(WindowTiling.ratio(weights: [33, 33, 34], direction: .horizontal, in: CGRect(x: 0, y: 0, width: 1001, height: 600)))
        assertTiles(odd, in: CGRect(x: 0, y: 0, width: 1001, height: 600))
        // 5:95 of 1200 is a 60 point cell: placed, but counted as tight.
        XCTAssertEqual(WindowTiling.tightCells(cells(WindowTiling.ratio(weights: [5, 95], direction: .horizontal, in: screen))), 1)
        for bad in [[100], [10, 20, 30, 40, 50], [0, 50], [50, 101], [-1, 5]] {
            if case .success = WindowTiling.ratio(weights: bad, direction: .horizontal, in: screen) { XCTFail("\(bad)") }
        }
        if case .success = WindowTiling.ratio(weights: [1, 1], direction: .quadrant, in: screen) { XCTFail("quadrant ratio") }
    }

    func testGapsLeaveSpaceBetweenAndAtEdges() {
        let c = cells(WindowTiling.split(parts: 2, direction: .horizontal, in: screen, gap: 10))
        XCTAssertEqual(c[0].minX, 10); XCTAssertEqual(c[1].maxX, screen.maxX - 10)
        XCTAssertEqual(c[1].minX - c[0].maxX, 10)
        XCTAssertEqual(c[0].minY, screen.minY + 10)
    }

    func testMultiDisplayCoordinates() {
        // Display 2 sits left of the main one (negative x) and a third is above it; numbering is left to right.
        let full = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                    CGRect(x: 100, y: 900, width: 1280, height: 720)]
        let visible = [CGRect(x: 0, y: 0, width: 1440, height: 875), CGRect(x: -1920, y: 0, width: 1920, height: 1055),
                       CGRect(x: 100, y: 900, width: 1280, height: 695)]
        XCTAssertEqual(WindowTiling.visibleFrame(display: 1, full: full, visible: visible), visible[1], "display 1 is the left-most")
        XCTAssertEqual(WindowTiling.visibleFrame(display: 2, full: full, visible: visible), visible[0])
        XCTAssertEqual(WindowTiling.visibleFrame(display: 3, full: full, visible: visible), visible[2])
        XCTAssertNil(WindowTiling.visibleFrame(display: 4, full: full, visible: visible))
        XCTAssertNil(WindowTiling.visibleFrame(display: 0, full: full, visible: visible))
        let left = cells(WindowTiling.grid(count: 4, in: visible[1]))
        assertTiles(left, in: visible[1])
        XCTAssertTrue(left.allSatisfy { $0.maxX <= 0 }, "cells stay on the left display")
        let above = cells(WindowTiling.split(parts: 3, direction: .horizontal, in: visible[2]))
        assertTiles(above, in: visible[2]); XCTAssertEqual(above[0].minX, 100)
        // Moving a window keeps its relative place.
        let moved = WindowLayout.move(CGRect(x: 720, y: 437, width: 360, height: 218), from: visible[0], to: visible[1])
        XCTAssertTrue(visible[1].contains(moved))
    }

    func testDivideEdgeCases() {
        XCTAssertTrue(WindowTiling.divide(100, weights: []).isEmpty)
        XCTAssertTrue(WindowTiling.divide(100, weights: [0, 0]).isEmpty)
        let d = WindowTiling.divide(10, weights: [1, 1, 1])
        XCTAssertEqual(d.map { $0.length }.reduce(0, +), 10)
        XCTAssertEqual(d.last.map { $0.offset + $0.length }, 10)
    }
}

final class WindowPlacementTests: XCTestCase {
    private let visible = CGRect(x: 100, y: 50, width: 1000, height: 600)   // another display: not at the origin

    private func item(_ x: Double, _ y: Double, _ w: Double, _ h: Double, z: Int? = nil) -> WindowPlacementItem {
        WindowPlacementItem(ref: WindowSelector(app: "A"), x: x, y: y, w: w, h: h, z: z)
    }

    func testRatioRectangleUsesTopLeftOrigin() {
        let r = WindowPlacement.frame(of: item(0.25, 0.1, 0.5, 0.4), unit: .ratio, in: visible)
        XCTAssertFalse(r.clamped)
        XCTAssertEqual(r.frame, CGRect(x: 350, y: 650 - 60 - 240, width: 500, height: 240), "x from the left, y from the top")
    }

    func testPixelRectangle() {
        let r = WindowPlacement.frame(of: item(10, 20, 300, 200), unit: .pixel, in: visible)
        XCTAssertEqual(r.frame, CGRect(x: 110, y: 650 - 20 - 200, width: 300, height: 200)); XCTAssertFalse(r.clamped)
    }

    func testOutOfRangeValuesAreClamped() {
        let past = WindowPlacement.frame(of: item(0.8, 0.9, 0.5, 0.5), unit: .ratio, in: visible)
        XCTAssertTrue(past.clamped)
        XCTAssertTrue(visible.contains(past.frame), "pushed back inside: \(past.frame)")
        XCTAssertEqual(past.frame.size, CGSize(width: 500, height: 300), "size kept, position moved")
        let negative = WindowPlacement.frame(of: item(-0.5, -1, 0.2, 0.2), unit: .ratio, in: visible)
        XCTAssertEqual(negative.frame.minX, visible.minX); XCTAssertEqual(negative.frame.maxY, visible.maxY); XCTAssertTrue(negative.clamped)
        let huge = WindowPlacement.frame(of: item(0, 0, 5, 5), unit: .ratio, in: visible)
        XCTAssertEqual(huge.frame, visible); XCTAssertTrue(huge.clamped)
        let pixelHuge = WindowPlacement.frame(of: item(900, 500, 800, 800), unit: .pixel, in: visible)
        XCTAssertTrue(visible.contains(pixelHuge.frame)); XCTAssertTrue(pixelHuge.clamped)
    }

    func testOverlapsAreAllowedAndZOrderIsAscending() {
        let a = WindowPlacement.frame(of: item(0.3, 0.3, 0.4, 0.4), unit: .ratio, in: visible).frame
        let b = WindowPlacement.frame(of: item(0.4, 0.4, 0.4, 0.4), unit: .ratio, in: visible).frame
        XCTAssertFalse(a.intersection(b).isNull, "overlap is fine")
        XCTAssertEqual(WindowPlacement.raiseOrder([item(0, 0, 1, 1), item(0, 0, 1, 1), item(0, 0, 1, 1)]), [0, 1, 2], "list order by default")
        XCTAssertEqual(WindowPlacement.raiseOrder([item(0, 0, 1, 1, z: 9), item(0, 0, 1, 1, z: 1), item(0, 0, 1, 1, z: 5)]), [1, 2, 0])
        XCTAssertEqual(WindowPlacement.raiseOrder([item(0, 0, 1, 1, z: 1), item(0, 0, 1, 1)]).count, 2)
    }

    func testDiamondRecipeFromTheGuideStaysOnScreenAndKeepsTheShape() {
        // The recipe of the guide, computed here independently: rows of 1, 2, 3, 2, 1 windows.
        var frames: [CGRect] = []
        for (row, count) in [1, 2, 3, 2, 1].enumerated() {
            for k in 0..<count {
                let cx = 0.5 + (Double(k) - Double(count - 1) / 2) * 0.22, cy = 0.16 + 0.17 * Double(row)
                let r = WindowPlacement.frame(of: item(cx - 0.1, cy - 0.075, 0.2, 0.15), unit: .ratio, in: visible)
                XCTAssertFalse(r.clamped); XCTAssertTrue(visible.contains(r.frame)); frames.append(r.frame)
            }
        }
        XCTAssertEqual(frames.count, 9)
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).width * a.intersection(b).height == 0, "diamond cells do not collide") } }
        XCTAssertEqual(frames[0].midX, frames[8].midX, accuracy: 1, "tip and tail on the vertical axis")
        XCTAssertEqual(frames[3].minX, visible.minX + 0.28 * visible.width - 0.1 * visible.width, accuracy: 1)
        XCTAssertGreaterThan(frames[0].midY, frames[8].midY, "Cocoa y grows upwards: the first is the top tip")
        XCTAssertEqual(frames[1].midX + frames[2].midX, 2 * frames[0].midX, accuracy: 2, "mirror symmetric")
        // The same items the guide shows are accepted by the parser and place 9 windows.
        guard let example = WindowTools.guide?.examples.first(where: { $0.action == "place" }),
              case .success(.place(let items, _)) = WindowToolArguments.parse(action: "place", example.arguments.objectValue ?? [:]) else { return XCTFail("guide place example") }
        XCTAssertEqual(items.count, 9)
        XCTAssertTrue(items.allSatisfy { !WindowPlacement.frame(of: $0, unit: .ratio, in: visible).clamped })
    }

    func testTwentyTwoWindowsInOneCallAreFine() {
        let items = (0..<22).map { item(Double($0 % 11) / 11, Double($0 / 11) / 2, 1.0 / 11, 0.5) }
        XCTAssertEqual(items.map { WindowPlacement.frame(of: $0, unit: .ratio, in: visible).frame }.count, 22)
    }
}

final class WindowUndoTests: XCTestCase {
    func testUndoRestoresTheFramesFromBeforeAndNewestFirst() {
        let stack = WindowUndoStack<String>(capacity: 3)
        let a0 = CGRect(x: 0, y: 0, width: 400, height: 300), a1 = CGRect(x: 50, y: 50, width: 400, height: 300)
        stack.push(WindowUndoSnapshot(items: [(window: "A", frame: a0), (window: "B", frame: a1)]))
        stack.push(WindowUndoSnapshot(items: [(window: "A", frame: a1)]))
        let one = stack.pop()
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].items.map { $0.window }, ["A"]); XCTAssertEqual(one[0].items[0].frame, a1, "the previous placement's frame")
        XCTAssertEqual(stack.count, 1)
        let rest = stack.pop(steps: 5)
        XCTAssertEqual(rest.count, 1, "asking for more than remembered returns what exists")
        XCTAssertEqual(rest[0].items.map { $0.frame }, [a0, a1])
        XCTAssertTrue(stack.pop().isEmpty)
    }

    func testTwoStepUndoAppliesOldestFrameLast() {
        let stack = WindowUndoStack<String>()
        stack.push(WindowUndoSnapshot(items: [(window: "A", frame: CGRect(x: 1, y: 1, width: 10, height: 10))]))   // first placement: before = original
        stack.push(WindowUndoSnapshot(items: [(window: "A", frame: CGRect(x: 2, y: 2, width: 10, height: 10))]))   // second: before = first result
        var current: [String: CGRect] = [:]
        for snapshot in stack.pop(steps: 2) { for item in snapshot.items { current[item.window] = item.frame } }
        XCTAssertEqual(current["A"], CGRect(x: 1, y: 1, width: 10, height: 10), "back to the original")
    }

    func testCapacityDropsTheOldestAndEmptySnapshotsAreIgnored() {
        let stack = WindowUndoStack<Int>(capacity: 2)
        for i in 1...4 { stack.push(WindowUndoSnapshot(items: [(window: i, frame: .zero)])) }
        stack.push(WindowUndoSnapshot(items: []))
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.pop(steps: 2).map { $0.items[0].window }, [4, 3])
    }
}

final class WindowToolArgumentsTests: XCTestCase {
    private func parse(_ action: String, _ json: String) -> Result<WindowToolRequest, WindowToolProblem> {
        let o = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))) ?? [:]
        return WindowToolArguments.parse(action: action, o)
    }
    private func fails(_ action: String, _ json: String, _ part: String, file: StaticString = #filePath, line: UInt = #line) {
        switch parse(action, json) {
        case .success(let r): XCTFail("\(action) \(json) was accepted: \(r)", file: file, line: line)
        case .failure(let p): XCTAssertTrue(p.message.contains(part), "\(p.message) lacks \(part)", file: file, line: line)
        }
    }

    func testValidRequests() {
        XCTAssertEqual(try? parse("displays", "{}").get(), .displays)
        XCTAssertEqual(try? parse("tile", #"{"windows":[{"app":"Safari"},{"app":"Notes","window":2}],"display":2}"#).get(),
                       .tile(WindowTileSpec(windows: [WindowSelector(app: "Safari"), WindowSelector(app: "Notes", window: 2)], rows: nil, cols: nil,
                                           displays: [2], span: .perDisplay, fill: .rowMajor, gap: nil)))
        XCTAssertEqual(try? parse("tile", #"{"all_windows":true,"rows":10,"cols":2,"displays":[1,2],"span":"across","fill":"column_major","gap":8}"#).get(),
                       .tile(WindowTileSpec(windows: nil, rows: 10, cols: 2, displays: [1, 2], span: .across, fill: .columnMajor, gap: 8)))
        XCTAssertEqual(try? parse("place", #"{"items":[{"app":"Safari","x":0.1,"y":0,"w":0.5,"h":1,"z":3},{"id":"Notes#2","display":2,"x":0,"y":0,"w":1,"h":1}]}"#).get(),
                       .place(items: [WindowPlacementItem(ref: WindowSelector(app: "Safari"), x: 0.1, y: 0, w: 0.5, h: 1, z: 3),
                                      WindowPlacementItem(ref: WindowSelector(app: "Notes", window: 2), display: 2, x: 0, y: 0, w: 1, h: 1)], unit: .ratio))
        XCTAssertEqual(try? parse("place", #"{"unit":"pixel","items":[{"app":"A","x":10,"y":20,"w":300,"h":200}]}"#).get(),
                       .place(items: [WindowPlacementItem(ref: WindowSelector(app: "A"), x: 10, y: 20, w: 300, h: 200)], unit: .pixel))
        XCTAssertEqual(try? parse("split", #"{"parts":4,"direction":"quadrant","windows":[{"app":"A"}]}"#).get(),
                       .split(parts: 4, direction: .quadrant, windows: [WindowSelector(app: "A")], display: nil))
        XCTAssertEqual(try? parse("ratio", #"{"ratios":[70,30],"windows":[{"app":"A"},{"app":"B"}]}"#).get(),
                       .ratio(weights: [70, 30], direction: .horizontal, windows: [WindowSelector(app: "A"), WindowSelector(app: "B")], display: nil))
        XCTAssertEqual(try? parse("move_display", #"{"windows":[{"app":"Slack"}],"display":2}"#).get(), .moveDisplay(windows: [WindowSelector(app: "Slack")], display: 2))
        XCTAssertEqual(try? parse("arrange_apps", #"{"apps":["Safari","Notes"],"arrangement":"columns"}"#).get(),
                       .arrangeApps(apps: ["Safari", "Notes"], arrangement: .columns, display: nil))
        XCTAssertEqual(try? parse("undo", "{}").get(), .undo(steps: 1))
        XCTAssertEqual(try? parse("undo", #"{"steps":3}"#).get(), .undo(steps: 3))
    }

    func testNoLayoutLimitOnTheNumberOfWindows() {
        let twenty = (1...20).map { #"{"app":"App\#($0)","x":0,"y":0,"w":0.1,"h":0.1}"# }.joined(separator: ",")
        guard case .success(.place(let items, _)) = parse("place", #"{"items":[\#(twenty)]}"#) else { return XCTFail("20 items must be accepted") }
        XCTAssertEqual(items.count, 20)
        let many = (1...200).map { #"{"app":"App\#($0)"}"# }.joined(separator: ",")
        guard case .success(.tile(let spec)) = parse("tile", #"{"windows":[\#(many)]}"#) else { return XCTFail("200 windows must be accepted") }
        XCTAssertEqual(spec.windows?.count, 200)
        fails("tile", #"{"windows":[\#(many),{"app":"One more"}]}"#, "1 to 200")
        let layout = (1...20).map { #"{"app":"App\#($0)","position":"left"}"# }.joined(separator: ",")
        if case .failure(let p) = PetCommands.parse(capability: PetCommands.layoutWindows, params: (try? JSONSerialization.jsonObject(with: Data(#"{"items":[\#(layout)]}"#.utf8))) as? [String: Any] ?? [:]) {
            XCTFail("combo_layout_windows still refuses 20 items: \(p)")
        }
        XCTAssertEqual(PetCommands.maxLayoutItems, 200)
    }

    func testClosedListsRangesAndUnknownFieldsAreRefused() {
        fails("displays", #"{"x":1}"#, "unknown field x")
        fails("tile", "{}", "all_windows")
        fails("tile", #"{"windows":[]}"#, "1 to 200")
        fails("tile", #"{"windows":[{"app":"A"}],"all_windows":true}"#, "not both")
        fails("tile", #"{"all_windows":"yes"}"#, "all_windows")
        fails("tile", #"{"windows":[{"app":"A"}],"extra":1}"#, "unknown field extra")
        fails("tile", #"{"windows":[{"app":"A","title":"secret"}]}"#, "unknown field title")
        fails("tile", #"{"windows":[{"app":"A"}],"display":0}"#, "display")
        fails("tile", #"{"windows":[{"app":"A"}],"display":17}"#, "display")
        fails("tile", #"{"windows":[{"app":"A"}],"display":"2"}"#, "display")
        fails("tile", #"{"windows":[{"app":"A"}],"display":1,"displays":[1]}"#, "not both")
        fails("tile", #"{"windows":[{"app":"A"}],"displays":[1,1]}"#, "twice")
        fails("tile", #"{"windows":[{"app":"A"}],"displays":[]}"#, "displays")
        fails("tile", #"{"windows":[{"app":"A"}],"rows":0}"#, "rows")
        fails("tile", #"{"windows":[{"app":"A"}],"cols":101}"#, "cols")
        fails("tile", #"{"windows":[{"app":"A"}],"span":"wrap"}"#, "span must be one of per_display, across")
        fails("tile", #"{"windows":[{"app":"A"}],"fill":"spiral"}"#, "fill must be one of row_major, column_major")
        fails("tile", #"{"windows":[{"app":"A"}],"gap":101}"#, "gap")
        fails("tile", #"{"windows":[{"app":"A","window":21}]}"#, "window")
        fails("tile", #"{"windows":[{"app":""}]}"#, "app")
        fails("tile", #"{"windows":[{}]}"#, "app")
        fails("tile", #"{"windows":[{"id":"Safari"}]}"#, "id must look like")
        fails("tile", #"{"windows":[{"id":"Safari#1","app":"Safari"}]}"#, "either id or app")
        fails("tile", #"{"windows":[{"app":"A"},{"app":"a"}]}"#, "twice")
        fails("place", "{}", "items")
        fails("place", #"{"items":[]}"#, "1 to 200")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":1}]}"#, "h must be a number")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":0,"h":1}]}"#, "above 0")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":1,"h":-1}]}"#, "h must be from")
        fails("place", #"{"items":[{"app":"A","x":"0","y":0,"w":1,"h":1}]}"#, "x must be a number")
        fails("place", #"{"items":[{"app":"A","x":99,"y":0,"w":1,"h":1}]}"#, "x must be from")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":1,"h":1,"title":"t"}]}"#, "unknown field title")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":1,"h":1,"z":1001}]}"#, "z must be")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":1,"h":1,"display":0}]}"#, "display")
        fails("place", #"{"unit":"em","items":[{"app":"A","x":0,"y":0,"w":1,"h":1}]}"#, "unit must be one of ratio, pixel")
        fails("place", #"{"items":[{"app":"A","x":0,"y":0,"w":1,"h":1},{"app":"A","x":0,"y":0,"w":1,"h":1}]}"#, "twice")
        fails("split", #"{"parts":5,"direction":"horizontal","windows":[{"app":"A"}]}"#, "parts")
        fails("split", #"{"parts":3,"direction":"diagonal","windows":[{"app":"A"}]}"#, "direction must be one of horizontal, vertical, quadrant")
        fails("split", #"{"parts":3,"direction":"quadrant","windows":[{"app":"A"}]}"#, "quadrant needs parts = 4")
        fails("split", #"{"parts":2,"direction":"horizontal","windows":[{"app":"A"},{"app":"B"},{"app":"C"}]}"#, "1 to 2")
        fails("split", #"{"direction":"horizontal","windows":[{"app":"A"}]}"#, "parts is required")
        fails("ratio", #"{"ratios":[100],"windows":[{"app":"A"}]}"#, "2 to 4")
        fails("ratio", #"{"ratios":[50,0],"windows":[{"app":"A"}]}"#, "each ratio")
        fails("ratio", #"{"ratios":[50,"x"],"windows":[{"app":"A"}]}"#, "each ratio")
        fails("ratio", #"{"ratios":[50,50],"direction":"quadrant","windows":[{"app":"A"}]}"#, "horizontal or vertical")
        fails("ratio", #"{"ratios":[50,50],"windows":[{"app":"A"},{"app":"B"},{"app":"C"}]}"#, "1 to 2")
        fails("move_display", #"{"windows":[{"app":"A"}]}"#, "display is required")
        fails("arrange_apps", #"{"apps":[]}"#, "1 to 200")
        fails("arrange_apps", #"{"apps":["A"],"arrangement":"columns"}"#, "at least 2")
        fails("arrange_apps", #"{"apps":["A","B","C","D","E"],"arrangement":"quadrants"}"#, "at most 4")
        fails("arrange_apps", #"{"apps":["A","a"]}"#, "twice")
        fails("arrange_apps", #"{"apps":["A"],"arrangement":"spiral"}"#, "arrangement must be one of")
        fails("undo", #"{"steps":0}"#, "steps")
        fails("undo", #"{"steps":6}"#, "steps")
        fails("nope", "{}", "unknown window action")
    }

    func testRequestsTurnIntoCells() {
        let apps = try? parse("arrange_apps", #"{"apps":["A","B","C"],"arrangement":"columns"}"#).get()
        XCTAssertEqual(cells(apps?.cells(in: screen, gap: 0) ?? .failure(.invalid("none"))).map { $0.width }, [400, 400, 400])
        let rows = try? parse("arrange_apps", #"{"apps":["A","B","C","D","E","F"],"arrangement":"rows"}"#).get()
        XCTAssertEqual(cells(rows?.cells(in: screen, gap: 0) ?? .failure(.invalid("none"))).count, 6)
        let quad = try? parse("arrange_apps", #"{"apps":["A","B"],"arrangement":"quadrants"}"#).get()
        XCTAssertEqual(cells(quad?.cells(in: screen, gap: 0) ?? .failure(.invalid("none"))).count, 4, "empty quadrants stay empty")
        let grid = try? parse("arrange_apps", #"{"apps":["A","B","C","D","E","F","G","H","I","J","K","L"]}"#).get()
        XCTAssertEqual(cells(grid?.cells(in: screen, gap: 0) ?? .failure(.invalid("none"))).count, 12, "more than 8 apps in one call")
        XCTAssertNil(WindowToolRequest.undo(steps: 1).cells(in: screen, gap: 0))
        XCTAssertNil(WindowToolRequest.displays.cells(in: screen, gap: 0))
    }
}

// MARK: registry and MCP

final class WindowRegistryTests: XCTestCase {
    private let names = ["window_displays", "window_place", "window_tile", "window_split", "window_ratio", "window_move_display", "window_arrange_apps", "window_undo"]

    func testRegistryStaysValidWithTheWindowTools() {
        XCTAssertEqual(GadgetToolRegistry.problems(), [])
        for name in names {
            let tool = GadgetToolRegistry.all.first { $0.mcpName == name }
            XCTAssertNotNil(tool, name)
            XCTAssertEqual(tool?.declaredConnectorName, name.replacingOccurrences(of: "window_", with: "combo_window_"))
            XCTAssertEqual(tool?.permissions, [.accessibility])
            XCTAssertNil(tool?.legacyConnectorName)
            XCTAssertTrue(tool?.requiresGadgetOn == true)
            XCTAssertTrue(tool?.exits.contains(.mcp) == true && tool?.exits.contains(.connector) == true)
        }
        XCTAssertEqual(WindowToolArguments.actions.count, names.count)
        XCTAssertEqual(GadgetToolRegistry.all.first { $0.mcpName == "window_displays" }?.risk, .read)
        for name in names.dropFirst() { XCTAssertEqual(GadgetToolRegistry.all.first { $0.mcpName == name }?.risk, .change, name) }
        XCTAssertEqual(Set(WindowTools.tools.map { $0.action }).intersection(WindowToolArguments.actions), Set(WindowToolArguments.actions))
    }

    func testOldWindowToolsKeepTheirNamesAndNoLongerAdvertiseALimitOfEight() {
        XCTAssertEqual(WindowTools.tools.prefix(3).map { $0.mcpName }, ["window_arrange", "window_layout", "window_list_windows"])
        let layout = WindowTools.tools[1]
        XCTAssertEqual(layout.legacyConnectorName, "combo_layout_windows")
        XCTAssertFalse(layout.koreanDescription.contains("최대 8개") || layout.englishDescription.contains("up to 8"))
        XCTAssertTrue(layout.koreanDescription.contains("제한은 없어요"))
        if case .object(let schema) = layout.inputSchema, case .object(let props)? = schema["properties"], case .object(let items)? = props["items"] {
            XCTAssertEqual(items["maxItems"], .int(200))
        } else { XCTFail("layout schema") }
        for tool in WindowTools.tools { XCTAssertFalse((tool.koreanDescription + tool.englishDescription).contains("최대 4칸")) }
        XCTAssertEqual(GadgetToolRegistry.connectorTool(named: "combo_arrange_window")?.mcpName, "window_arrange")
        XCTAssertNil(GadgetToolRegistry.all.first { $0.mcpName == "window_list" }, "window_list stays Computer Use's old name")
    }

    func testInputSchemasAreClosedAndMatchTheParser() {
        for name in names {
            guard case .object(let schema)? = GadgetToolRegistry.all.first(where: { $0.mcpName == name })?.inputSchema,
                  case .object(let props)? = schema["properties"] else { XCTFail(name); continue }
            XCTAssertEqual(schema["additionalProperties"], .bool(false), name)
            XCTAssertFalse(props.keys.contains("title"), "window titles are never part of an input")
        }
    }

    func testGuideAndPrompts() {
        let guide = GadgetToolRegistry.guide(for: .window)
        XCTAssertNotNil(guide)
        let mcp = guide?.render(for: .mcp, tools: GadgetToolRegistry.all) ?? ""
        for name in names { XCTAssertTrue(mcp.contains("`\(name)"), "\(name) missing from the MCP guide") }
        let nacho = guide?.render(for: .connector, tools: GadgetToolRegistry.all) ?? ""
        XCTAssertTrue(nacho.contains("combo_window_tile") && !nacho.contains("`window_tile"))
        for word in ["다이아몬드", "원형", "계단식", "중앙 집중", "좌우 대칭", "제한은 없", "전체 바둑판", "10×2"] { XCTAssertTrue(mcp.contains(word), "guide lacks \(word)") }
        XCTAssertFalse(mcp.contains("최대 8개"), "the old 8 item limit is gone from the guide")
        let prompts = WindowTools.prompts
        XCTAssertGreaterThanOrEqual(prompts.count, 4)
        let three = prompts.first { $0.name == "window_work_in_three" }
        XCTAssertNotNil(three)
        let text = three?.render(["editor": "Xcode", "browser": "Safari", "terminal": "Terminal"]) ?? ""
        XCTAssertTrue(text.contains("window_split") && text.contains("Xcode") && !text.contains("{"))
        let shape = prompts.first { $0.name == "window_arrange_shape" }?.render(["shape": "diamond", "apps": ""]) ?? ""
        XCTAssertTrue(shape.contains("window_place") && shape.contains("diamond") && shape.contains("no limit"))
        XCTAssertTrue((prompts.first { $0.name == "window_tile_everything" }?.render([:]) ?? "").contains("all_windows"))
    }
}

/// Answers every window tool with the Core geometry and records what it received (stands in for the app's `WindowToolRunner`).
private final class StubWindowRunner: GadgetToolRunning {
    private let lock = NSLock()
    private(set) var calls: [(String, [String: JSONValue])] = []
    func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        lock.lock(); calls.append((tool.mcpName, arguments)); lock.unlock()
        switch WindowToolArguments.parse(action: tool.action, arguments) {
        case .failure(let p): done(PetCommandOutcome(ok: false, message: p.message))
        case .success(let request):
            var placed: [CGRect] = []
            switch request {
            case let .tile(spec):
                let count = spec.windows?.count ?? 12
                placed = (try? WindowTiling.tile(count: count, rows: spec.rows, cols: spec.cols, fill: spec.fill, span: spec.span,
                                                 areas: [screen]).get()) ?? []
            case let .place(items, unit): placed = items.map { WindowPlacement.frame(of: $0, unit: unit, in: screen).frame }
            default: placed = request.cells(in: screen, gap: 0).flatMap { try? $0.get() } ?? []
            }
            done(PetCommandOutcome(ok: true, message: "stub placed \(placed.count)",
                                   details: ["windows": placed.map { ["requested": ["width": Int($0.width), "height": Int($0.height)]] }]))
        }
    }
}

final class WindowMCPRoundTripTests: XCTestCase {
    private var settings = ComputerUseSettings()
    private var runner = StubWindowRunner()
    private var service: NachoComboMCPService!
    private var token = ""
    private(set) var log: [String] = []

    override func setUpWithError() throws {
        settings = ComputerUseSettings(); runner = StubWindowRunner(); log = []
        let keys = APIKeyStore(url: nil, random: CountingRandom())
        token = try keys.create(label: "Test Key").token
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(runner, for: [.window])
        service = NachoComboMCPService(settings: { [unowned self] in self.settings }, keys: keys, backend: FakeBackend(), gadgets: dispatcher)
    }

    private func rpc(_ id: Int, _ method: String, _ params: String = "{}") -> [String: Any] {
        let body = #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        let r = service.handle(HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47653", "authorization": "Bearer \(token)"],
                                           body: Data(body.utf8)), peer: "127.0.0.1")
        let text = String(decoding: r.body, as: UTF8.self)
        log.append("> \(method) \(params.prefix(120))")
        log.append("< \(r.status) \(text.count > 140 ? String(text.prefix(140)) + "…" : text)")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func text(_ o: [String: Any]) -> String {
        ((o["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    }

    func testToolsListGuideAndToolCallRoundTrip() {
        settings.setGadgetEnabled(.window, true)
        let tools = ((rpc(1, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        for name in ["window_displays", "window_place", "window_tile", "window_split", "window_ratio", "window_move_display", "window_arrange_apps", "window_undo"] {
            XCTAssertTrue(tools.contains(name), name)
        }
        let read = (rpc(2, "resources/read", #"{"uri":"nachocombo://gadgets/window/guide"}"#)["result"] as? [String: Any])?["contents"] as? [[String: Any]]
        XCTAssertTrue((read?.first?["text"] as? String ?? "").contains("window_tile"))
        let call = rpc(3, "tools/call", #"{"name":"window_tile","arguments":{"windows":[{"app":"Safari"},{"app":"Notes"},{"app":"Terminal"},{"app":"Finder"}]}}"#)
        XCTAssertEqual((call["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(text(call).contains("stub placed 4"), text(call))
        // 10 x 2 and 22 free rectangles are not refused: there is no layout limit.
        let tenByTwo = rpc(4, "tools/call", #"{"name":"window_tile","arguments":{"all_windows":true,"rows":10,"cols":2}}"#)
        XCTAssertEqual((tenByTwo["result"] as? [String: Any])?["isError"] as? Bool, false)
        let items = (0..<22).map { #"{"app":"App\#($0)","x":0.\#($0 % 9),"y":0.\#($0 % 7),"w":0.1,"h":0.1}"# }.joined(separator: ",")
        let place = rpc(5, "tools/call", #"{"name":"window_place","arguments":{"items":[\#(items)]}}"#)
        XCTAssertTrue(text(place).contains("stub placed 22"), text(place))
        XCTAssertEqual(runner.calls.map { $0.0 }, ["window_tile", "window_tile", "window_place"])
        // A bad argument is refused by the checks (isError), never moving anything.
        let bad = rpc(6, "tools/call", #"{"name":"window_split","arguments":{"parts":3,"direction":"diagonal","windows":[{"app":"A"}]}}"#)
        XCTAssertEqual((bad["result"] as? [String: Any])?["isError"] as? Bool, true)
        // Off by default: hidden and refused.
        settings.setGadgetEnabled(.window, false)
        let hidden = ((rpc(7, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertFalse(hidden.contains("window_tile"))
        XCTAssertEqual((rpc(8, "tools/call", #"{"name":"window_undo","arguments":{}}"#)["result"] as? [String: Any])?["isError"] as? Bool, true)
        print("MCP-ROUNDTRIP-LOG\n" + log.joined(separator: "\n"))
    }
}

// MARK: Nacho (connector) round trip

/// "다이아몬드 모양으로 배치해 줘": the request frame is built by hand the way the server forwards the model's tool call
/// (no language model and no real server here); the coordinates are the guide's diamond recipe.
final class WindowConnectorRoundTripTests: XCTestCase {
    func testNachoCanDeclareAndCallWindowPlaceWithAnyNumberOfWindows() {
        let factory = PetTransportFactory()
        let runner = StubWindowRunner()
        let dispatcher = GadgetToolDispatcher()
        dispatcher.register(runner, for: [.window])
        let client = PetConnectorClient(url: URL(string: "ws://127.0.0.1:8787/ws/connector")!, token: "nct_abc", executor: PetRecordingExecutor(),
                                        makeTransport: factory.make, schedule: { _, _ in }, trust: GadgetTrust(trustable: { [] }),
                                        tools: GadgetToolRegistry.all, dispatcher: dispatcher)
        client.connect(); client.flush()
        let t = factory.with(path: "/ws/connector")[0]
        t.handler?(.opened); client.flush()
        t.deliver(#"{"type":"ready","agent_id":"a"}"#); client.flush()
        func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
        let hello = t.sent.map(object).first { $0["type"] as? String == "hello" } ?? [:]
        let caps = (hello["capabilities"] as? [[String: Any]]) ?? []
        for name in ["combo_window_place", "combo_window_tile", "combo_window_displays", "combo_window_undo"] {
            let c = caps.first { $0["name"] as? String == name }
            XCTAssertNotNil(c, "\(name) is declared to Nacho")
            XCTAssertNil(c?["approval"], "\(name) is a change/read tool: no approval card")
        }
        let tool = caps.first { $0["name"] as? String == "combo_window_place" }
        let text = ((tool?["description"] as? String) ?? "")
        XCTAssertFalse(text.contains("최대 4"), "no limit of 4 cells in what Nacho reads")
        XCTAssertTrue(text.contains("제한 없이"))
        // 9 windows in a diamond, sent as the server would.
        let items = WindowTools.diamond(apps: ["Safari", "Notes", "Terminal", "Finder", "Slack", "Mail", "Music", "Preview", "Calendar"])
        let params = String(decoding: (try? JSONEncoder().encode(JSONValue.object(["items": .array(items)]))) ?? Data(), as: UTF8.self)
        t.deliver(#"{"type":"request","id":"d1","capability":"combo_window_place","params":\#(params)}"#)
        client.flush(); client.flush()
        let reply = t.sent.map(object).last { $0["id"] as? String == "d1" } ?? [:]
        let result = reply["result"] as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(result?["message"] as? String, "stub placed 9")
        XCTAssertEqual(runner.calls.map { $0.0 }, ["window_place"])
        print("NACHO-ROUNDTRIP: hello declared combo_window_place; request d1 (9 windows, diamond) -> \(result?["message"] ?? "?")")
    }
}
