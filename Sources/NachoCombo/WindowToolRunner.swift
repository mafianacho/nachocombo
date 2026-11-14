import AppKit
import ApplicationServices
import NachoComboCore

/// Runs the Window Snap tools of the NachoCombo MCP registry (NACHO-146): displays, place, tile, split, ratio,
/// move_display, arrange_apps and undo. The older tools (arrange, layout, list_windows) keep going through `fallback`,
/// the pet's executor, because one runner serves a whole gadget. All AppKit / Accessibility work runs on the main thread;
/// `done` is called exactly once. Window titles and contents are never read or returned. There is no layout limit: the
/// only cap is `WindowTiling.maxWindows` per call (payload size).
final class WindowToolRunner: GadgetToolRunning {
    private struct Target { let window: AXWindow; let label: String }
    private struct Move { let target: Target; let before: CGRect; let goal: CGRect; let note: String? }

    private let fallback: GadgetToolRunning
    private weak var snap: WindowSnapModule?
    private let undo = WindowUndoStack<Target>(capacity: 10)

    init(fallback: GadgetToolRunning, snap: WindowSnapModule) {
        self.fallback = fallback
        self.snap = snap
    }

    func run(_ tool: GadgetTool, arguments: [String: JSONValue], done: @escaping (PetCommandOutcome) -> Void) {
        guard tool.legacyConnectorName == nil, WindowToolArguments.actions.contains(tool.action) else {
            return fallback.run(tool, arguments: arguments, done: done)
        }
        switch WindowToolArguments.parse(action: tool.action, arguments) {
        case let .failure(problem):
            done(PetCommandOutcome(ok: false, message: problem.message))
        case let .success(request):
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return done(PetCommandOutcome(ok: false, message: "Nacho Combo is closing")) }
                done(self.execute(request))
            }
        }
    }

    // MARK: execution (main thread)

    private func execute(_ request: WindowToolRequest) -> PetCommandOutcome {
        guard WindowSnapModule.isTrusted(prompt: false) else { return .permissionNeeded(.window, .accessibility) }
        switch request {
        case .displays: return displays()
        case let .tile(spec): return tile(spec)
        case let .place(items, unit): return place(items, unit: unit)
        case let .split(_, _, windows, display): return fitOneDisplay(request, windows: windows, display: display)
        case let .ratio(_, _, windows, display): return fitOneDisplay(request, windows: windows, display: display)
        case let .arrangeApps(apps, _, display): return fitOneDisplay(request, windows: apps.map { WindowRef(app: $0, window: 1) }, display: display)
        case let .moveDisplay(windows, display): return moveToDisplay(windows, display: display)
        case let .undo(steps): return restore(steps: steps)
        }
    }

    private var screens: (full: [CGRect], visible: [CGRect]) {
        (NSScreen.screens.map { $0.frame }, NSScreen.screens.map { $0.visibleFrame })
    }

    /// Points from the display's top-left corner, like `window_list_windows`.
    private func report(_ frame: CGRect, on display: CGRect) -> [String: Any] {
        ["x": Int(frame.minX - display.minX), "y": Int(display.maxY - frame.maxY), "width": Int(frame.width), "height": Int(frame.height)]
    }

    private func displayFrame(containing frame: CGRect) -> CGRect {
        let full = screens.full
        return full.isEmpty ? .zero : full[WindowLayout.screenIndex(for: frame, screens: full) ?? 0]
    }

    private func displays() -> PetCommandOutcome {
        let (full, visible) = screens
        let list: [[String: Any]] = PetDisplays.ordered(full).enumerated().map { n, index in
            var item: [String: Any] = ["display": n + 1, "name": NSScreen.screens[index].localizedName, "main": index == 0]
            item.merge(report(full[index], on: full[index])) { a, _ in a }
            item["usable"] = report(visible[index], on: full[index])
            return item
        }
        return PetCommandOutcome(ok: true, message: "\(list.count) display\(list.count == 1 ? "" : "s").", details: ["displays": list])
    }

    // MARK: finding windows

    private func entries() -> [PetAppEntry] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && $0.bundleIdentifier != nil
        }.map { app in
            var names: [String] = []
            if let n = app.localizedName { names.append(n) }
            if let base = app.bundleURL?.deletingPathExtension().lastPathComponent, !names.contains(base) { names.append(base) }
            return PetAppEntry(bundleID: app.bundleIdentifier ?? "", names: names, running: true)
        }
    }

    private enum Resolved {
        case found(Target, frame: CGRect)
        case missing(String)
    }

    private func resolve(_ ref: WindowRef, matching all: [PetAppEntry]) -> Resolved {
        let label = "\(ref.app) #\(ref.window)"
        switch PetAppMatcher.match(ref.app, in: all) {
        case .ambiguous(let list):
            return .missing("more than one app matches (\(list.map { $0.displayName }.joined(separator: ", ")))")
        case .none:
            return .missing("no running app with that name")
        case .found(let entry):
            guard let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier?.caseInsensitiveCompare(entry.bundleID) == .orderedSame && $0.activationPolicy == .regular
            }) else { return .missing("not running") }
            if app.isHidden { app.unhide() }
            let windows = WindowLayoutKeeper.windows(of: app)
            guard windows.indices.contains(ref.window - 1), let frame = windows[ref.window - 1].frame else {
                return .missing("\(entry.displayName) has \(windows.count) open window\(windows.count == 1 ? "" : "s"), not \(ref.window)")
            }
            return .found(Target(window: windows[ref.window - 1], label: "\(entry.displayName) #\(ref.window)"), frame: frame)
        }
    }

    private struct Found { let index: Int; let label: String; let target: Target?; let frame: CGRect?; let problem: String? }

    /// Every ref, in order; refs that cannot be found carry the reason (they never stop the others).
    private func resolveAll(_ refs: [WindowRef]) -> [Found] {
        let all = entries()
        return refs.enumerated().map { index, ref in
            switch resolve(ref, matching: all) {
            case let .found(target, frame): return Found(index: index, label: target.label, target: target, frame: frame, problem: nil)
            case let .missing(text): return Found(index: index, label: "\(ref.app) #\(ref.window)", target: nil, frame: nil, problem: text)
            }
        }
    }

    /// All open standard windows of all visible apps (the "whole checkerboard").
    private func allOpenWindows() -> [Found] {
        var found: [Found] = []
        for app in WindowLayoutKeeper.apps() {
            for (order, window) in WindowLayoutKeeper.windows(of: app).enumerated() {
                guard found.count < WindowTiling.maxWindows, let frame = window.frame else { continue }
                let label = "\(app.localizedName ?? app.bundleIdentifier ?? "?") #\(order + 1)"
                found.append(Found(index: found.count, label: label, target: Target(window: window, label: label), frame: frame, problem: nil))
            }
        }
        return found
    }

    private func visibleFrames(for numbers: [Int]) -> Result<[CGRect], PetCommandOutcome> {
        let (full, visible) = screens
        var areas: [CGRect] = []
        for number in numbers {
            guard let frame = WindowTiling.visibleFrame(display: number, full: full, visible: visible) else {
                return .failure(PetCommandOutcome(ok: false, message: "there is no display \(number) (this Mac has \(full.count)); see window_displays"))
            }
            areas.append(frame)
        }
        return .success(areas)
    }

    private func usableFrame(of frame: CGRect) -> CGRect {
        let visible = screens.visible
        return visible.isEmpty ? .zero : visible[WindowLayout.screenIndex(for: frame, screens: visible) ?? 0]
    }

    // MARK: applying

    /// Moves every window, keeps going when one fails, remembers the frames from before for undo and reports each window.
    private func apply(_ moves: [Move], problems: [(label: String, why: String)], what: String, raise: [Int]? = nil,
                       tight: Int = 0) -> PetCommandOutcome {
        var snapshot: [(window: Target, frame: CGRect)] = []
        var rows: [[String: Any]] = []
        var placed: [Target?] = []
        var different = 0, notPlaced = 0
        for move in moves {
            snap?.memory.remember(move.target.window.element, before: move.before, applied: move.goal)
            let result = PetDesktopActions.move(move.target.window, to: move.goal)
            let display = displayFrame(containing: move.goal)
            var row: [String: Any] = ["window": move.target.label, "requested": report(move.goal, on: display)]
            if case .failed(let why) = result {
                snap?.memory.forget(move.target.window.element)
                row["placed"] = false; row["reason"] = "failed: \(why)"
                notPlaced += 1; placed.append(nil)
            } else {
                snapshot.append((move.target, move.before))
                let landed = move.target.window.frame ?? move.goal
                snap?.memory.updateApplied(move.target.window.element, landed)
                row["applied"] = report(landed, on: displayFrame(containing: landed))
                row["placed"] = true
                var reasons: [String] = []
                if let note = move.note { reasons.append(note) }
                if result == .movedOnly { reasons.append("the app does not let its window be resized; moved to the top-left of its cell") }
                else if !WindowLayout.matches(landed, move.goal) { reasons.append("the app keeps its own minimum or fixed size") }
                if reasons.count > (move.note == nil ? 0 : 1) { different += 1 }
                row["reason"] = reasons.isEmpty ? "ok" : reasons.joined(separator: "; ")
                placed.append(move.target)
            }
            rows.append(row)
        }
        for problem in problems { rows.append(["window": problem.label, "placed": false, "reason": "not found: \(problem.why)"]) }
        // Bring windows to the front in the given order (overlapping shapes need it); the last one ends up on top.
        if let order = raise { for index in order where placed.indices.contains(index) { placed[index]?.window.raise() } }
        undo.push(WindowUndoSnapshot(items: snapshot))
        let total = moves.count + problems.count
        var text = "\(what): \(snapshot.count) of \(total) window\(total == 1 ? "" : "s") placed"
        if different > 0 { text += "; \(different) differ from the request (see reason)" }
        if notPlaced + problems.count > 0 { text += "; \(notPlaced + problems.count) not placed" }
        if tight > 0 { text += "; \(tight) cell\(tight == 1 ? " is" : "s are") under \(Int(WindowTiling.comfortableSide)) points on a side, apps may refuse that size" }
        if !snapshot.isEmpty { text += ". window_undo restores them." }
        return PetCommandOutcome(ok: !snapshot.isEmpty, message: text, details: ["windows": rows, "missing": problems.map { "\($0.label): \($0.why)" }])
    }

    private func nothingFound(_ found: [Found]) -> PetCommandOutcome {
        let missing = found.compactMap { f in f.problem.map { "\(f.label): \($0)" } }
        return PetCommandOutcome(ok: false, message: "No window could be found: " + missing.joined(separator: "; "), details: ["missing": missing])
    }

    private func tile(_ spec: WindowTileSpec) -> PetCommandOutcome {
        let found = spec.windows.map { resolveAll($0) } ?? allOpenWindows()
        let usable = found.filter { $0.target != nil }
        guard !usable.isEmpty else {
            return spec.windows == nil ? PetCommandOutcome(ok: false, message: "There are no open windows to tile.") : nothingFound(found)
        }
        let areas: [CGRect]
        switch visibleFrames(for: spec.displays ?? []) {
        case .failure(let outcome): return outcome
        case .success(let list): areas = list.isEmpty ? [usableFrame(of: usable[0].frame ?? .zero)] : list
        }
        let gap = CGFloat(spec.gap ?? snap?.optionsProvider().snapGap ?? 0)
        switch WindowTiling.tile(count: usable.count, rows: spec.rows, cols: spec.cols, fill: spec.fill, span: spec.span, areas: areas, gap: gap) {
        case .failure(let error): return PetCommandOutcome(ok: false, message: error.message)
        case .success(let cells):
            let moves = zip(usable, cells).map { Move(target: $0.target!, before: $0.frame!, goal: $1, note: nil) }
            let problems = found.compactMap { f in f.problem.map { (label: f.label, why: $0) } }
            return apply(moves, problems: problems, what: spec.windows == nil ? "All windows tiled" : "Tile", tight: WindowTiling.tightCells(cells))
        }
    }

    private func place(_ items: [WindowPlacementItem], unit: WindowCoordinateUnit) -> PetCommandOutcome {
        let found = resolveAll(items.map { $0.ref })
        guard found.contains(where: { $0.target != nil }) else { return nothingFound(found) }
        var moves: [Move] = []
        var keptItems: [WindowPlacementItem] = []
        var problems: [(label: String, why: String)] = []
        for f in found {
            guard let target = f.target, let frame = f.frame else { problems.append((f.label, f.problem ?? "?")); continue }
            let item = items[f.index]
            let area: CGRect
            if let number = item.display {
                switch visibleFrames(for: [number]) {
                case .failure(let outcome): problems.append((f.label, outcome.message)); continue
                case .success(let list): area = list[0]
                }
            } else {
                area = usableFrame(of: frame)
            }
            let placement = WindowPlacement.frame(of: item, unit: unit, in: area)
            moves.append(Move(target: target, before: frame, goal: placement.frame, note: placement.clamped ? "clamped to the display" : nil))
            keptItems.append(item)
        }
        guard !moves.isEmpty else {
            return PetCommandOutcome(ok: false, message: "No window could be placed: " + problems.map { "\($0.label): \($0.why)" }.joined(separator: "; "),
                                     details: ["missing": problems.map { "\($0.label): \($0.why)" }])
        }
        return apply(moves, problems: problems, what: "Place", raise: WindowPlacement.raiseOrder(keptItems))
    }

    private func fitOneDisplay(_ request: WindowToolRequest, windows refs: [WindowRef], display: Int?) -> PetCommandOutcome {
        let found = resolveAll(refs)
        guard let first = found.first(where: { $0.target != nil }) else { return nothingFound(found) }
        let visible: CGRect
        switch display.map({ visibleFrames(for: [$0]) }) ?? .success([usableFrame(of: first.frame ?? .zero)]) {
        case .failure(let outcome): return outcome
        case .success(let list): visible = list[0]
        }
        let gap = CGFloat(snap?.optionsProvider().snapGap ?? 0)
        guard let result = request.cells(in: visible, gap: gap) else { return PetCommandOutcome(ok: false, message: "This request does not place windows.") }
        switch result {
        case .failure(let error): return PetCommandOutcome(ok: false, message: error.message)
        case .success(let cells):
            let moves: [Move] = found.compactMap { f in
                guard let target = f.target, let frame = f.frame, cells.indices.contains(f.index) else { return nil }
                return Move(target: target, before: frame, goal: cells[f.index], note: nil)
            }
            let problems = found.compactMap { f in f.problem.map { (label: f.label, why: $0) } }
            return apply(moves, problems: problems, what: "Placement", tight: WindowTiling.tightCells(cells))
        }
    }

    private func moveToDisplay(_ refs: [WindowRef], display: Int) -> PetCommandOutcome {
        let destination: CGRect
        switch visibleFrames(for: [display]) {
        case .failure(let outcome): return outcome
        case .success(let list): destination = list[0]
        }
        let found = resolveAll(refs)
        let visible = screens.visible
        let moves: [Move] = found.compactMap { f in
            guard let target = f.target, let frame = f.frame else { return nil }
            let source = visible[WindowLayout.screenIndex(for: frame, screens: visible) ?? 0]
            return Move(target: target, before: frame, goal: WindowLayout.move(frame, from: source, to: destination), note: nil)
        }
        guard !moves.isEmpty else { return nothingFound(found) }
        return apply(moves, problems: found.compactMap { f in f.problem.map { (label: f.label, why: $0) } }, what: "Move to display \(display)")
    }

    private func restore(steps: Int) -> PetCommandOutcome {
        let snapshots = undo.pop(steps: steps)
        guard !snapshots.isEmpty else {
            return PetCommandOutcome(ok: false, message: "Nothing to undo: no placement by these window tools is remembered.")
        }
        var restored: [[String: Any]] = []
        var missing: [String] = []
        for snapshot in snapshots {   // newest first: the oldest frame is written last and wins
            for item in snapshot.items {
                guard item.window.window.frame != nil else { missing.append("\(item.window.label): window is gone"); continue }
                switch PetDesktopActions.move(item.window.window, to: item.frame) {
                case .failed(let why): missing.append("\(item.window.label): \(why)")
                default:
                    let landed = item.window.window.frame ?? item.frame
                    restored.append(["window": item.window.label, "applied": report(landed, on: displayFrame(containing: landed))])
                    snap?.memory.forget(item.window.window.element)
                }
            }
        }
        return PetCommandOutcome(ok: !restored.isEmpty, message: "Restored \(restored.count) window\(restored.count == 1 ? "" : "s") "
                                 + "from \(snapshots.count) placement\(snapshots.count == 1 ? "" : "s")"
                                 + (missing.isEmpty ? "." : "; \(missing.count) could not be restored."),
                                 details: ["restored": restored, "missing": missing])
    }
}
