import AppKit
import NachoComboCore

/// What the quick panel needs from the app. Keeps the views free of module wiring.
protocol PanelHost: AnyObject {
    var panelManager: ModuleManager { get }
    var panelCollapse: (running: Bool, collapsed: Bool) { get }
    var panelShelf: (running: Bool, visible: Bool, count: Int) { get }
    var panelReading: SystemMonitorModule.Reading { get }
    func panelSetEnabled(_ id: ModuleID, _ on: Bool)
    func panelSetPinned(_ id: ModuleID, _ pinned: Bool)
    func panelOpenSettings()
    func panelQuit()
    func panelApplySnap(_ action: SnapAction)
    func panelToggleCollapse()
    func panelToggleShelf()
    func panelStartCapture()
    func panelSetDim(_ value: Double)
    func panelOpenPermissionPane(_ id: ModuleID)
    func panelRecheck(_ id: ModuleID)
}

enum PanelRoute: Equatable {
    case list
    case tool(ModuleID)

    var name: String {
        switch self {
        case .list: return "list"
        case .tool(let id): return "tool:\(id.rawValue)"
        }
    }
}

/// One popover for the main icon and for every pinned tool icon. Two levels only: tool list -> tool controls.
final class PanelController: NSObject, NSPopoverDelegate {
    private weak var host: PanelHost?
    private let popover = NSPopover()
    private let content = PanelViewController()
    private(set) var route: PanelRoute = .list
    private(set) weak var anchor: NSStatusBarButton?
    private var closedAt = Date.distantPast
    private var closedAnchor: ObjectIdentifier?
    private var liveTimer: Timer?
    private var pendingToken = 0
    private(set) var showCount = 0
    private(set) var backCount = 0

    init(host: PanelHost) {
        self.host = host
        super.init()
        content.host = host
        content.onBack = { [weak self] in self?.back() }
        content.onEscape = { [weak self] in self?.escape() }
        content.onSelect = { [weak self] id in self?.navigate(to: .tool(id)) }
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = false      // no motion at all: nothing here may start moving when Reduce Motion is on
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// Click on a menu bar button. A transient popover closes itself on the mouse-down that precedes the action,
    /// so a click on the same button right after a close must not re-open it.
    func toggle(from button: NSStatusBarButton, route newRoute: PanelRoute) {
        if popover.isShown {
            if anchor === button && route == newRoute { close() } else { show(from: button, route: newRoute) }
            return
        }
        if closedAnchor == ObjectIdentifier(button), Date().timeIntervalSince(closedAt) < 0.3 { return }
        show(from: button, route: newRoute)
    }

    func show(from button: NSStatusBarButton, route newRoute: PanelRoute) {
        if popover.isShown { popover.close() }
        route = newRoute
        anchor = button
        content.show(route: newRoute)
        pendingToken += 1
        let token = pendingToken
        if NSApp.isActive {
            present(from: button)
            return
        }
        // A transient popover closes the moment another window of the app becomes key. Opening it while the app is
        // still inactive let the late activation re-key the settings window and the popover vanished right away.
        // So: activate first, show once the activation has finished.
        var observer: NSObjectProtocol?
        let finish: () -> Void = { [weak self] in
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            guard let self = self, token == self.pendingToken, !self.popover.isShown else { return }
            self.present(from: button)
        }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            DispatchQueue.main.async { finish() }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish() }   // fallback when no notification comes
    }

    private func present(from button: NSStatusBarButton) {
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        content.view.window?.makeKey()
        content.focusInitial()
        showCount += 1
        updateLiveTimer()
    }

    func navigate(to newRoute: PanelRoute) {
        route = newRoute
        content.show(route: newRoute)
        content.focusInitial()
        updateLiveTimer()
    }

    func back() {
        guard case .tool = route else { return }
        backCount += 1
        navigate(to: .list)
    }

    /// Esc: tool screen -> list, list -> close.
    func escape() {
        if case .tool = route { back() } else { close() }
    }

    func close() {
        pendingToken += 1          // cancels an open that is still waiting for the activation
        guard popover.isShown else { return }
        popover.close()
    }

    func refresh() {
        guard popover.isShown else { return }
        content.refresh()
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
        closedAnchor = anchor.map { ObjectIdentifier($0) }
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func updateLiveTimer() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard popover.isShown, route == .tool(.systemMonitor) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    var diagnostics: [String: Any] {
        ["shown": popover.isShown, "route": route.name, "showCount": showCount, "backCount": backCount,
         "liveTimer": liveTimer?.isValid ?? false, "popoverAnimates": popover.animates]
    }

    /// Debug readout of the accessibility elements of the visible panel screen (`ctl a11y panel`).
    var accessibilityTree: [[String: String]] { UI.accessibilityTree(of: content.view) }

    /// Debug: the window server's own picture of the popover window (what the app really composited), to tell an
    /// app drawing defect from a stale frame in a captured screen.
    var window: NSWindow? { content.view.window }
}

final class PanelRootView: NSView {
    var onEscape: (() -> Void)?

    /// The popover hosts its content in a vibrancy view whose (vibrant) appearance makes fills and text blend with what
    /// is already there instead of replacing it - so a changed label kept the old glyphs on screen (real-OS captures
    /// that stayed garbled for 40 s+). A plain light/dark appearance on our own root view gives normal painting; the
    /// light/dark choice still follows the system.
    func applyBaseAppearance() {
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let wanted = NSAppearance(named: match ?? .aqua)
        if appearance?.name != wanted?.name { appearance = wanted }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class PanelViewController: NSViewController {
    weak var host: PanelHost?
    var onBack: (() -> Void)?
    var onEscape: (() -> Void)?
    var onSelect: ((ModuleID) -> Void)?
    private var listView: ToolListView?
    private var detailView: ToolDetailView?
    private var current: NSView?

    override func loadView() {
        let root = PanelRootView()
        root.onEscape = { [weak self] in self?.onEscape?() }
        view = root
    }

    func show(route: PanelRoute) {
        guard let host = host else { return }
        _ = view
        (view as? PanelRootView)?.applyBaseAppearance()
        current?.removeFromSuperview()
        listView = nil
        detailView = nil
        let child: NSView
        switch route {
        case .list:
            let list = ToolListView(host: host)
            list.onSelect = { [weak self] id in self?.onSelect?(id) }
            listView = list
            child = list
        case .tool(let id):
            let detail = ToolDetailView(module: id, host: host)
            detail.onBack = { [weak self] in self?.onBack?() }
            detailView = detail
            child = detail
        }
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        switch route {
        case .list: view.setAccessibilityLabel("Nacho Combo 도구 목록")
        case .tool(let id): view.setAccessibilityLabel("\(id.displayName) 조작 화면")
        }
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = child
        refresh()
    }

    func refresh() {
        (view as? PanelRootView)?.applyBaseAppearance()
        listView?.update()
        detailView?.update()
        guard let child = current else { return }
        child.layoutSubtreeIfNeeded()
        let size = child.fittingSize
        if abs(preferredContentSize.height - size.height) > 0.5 || abs(preferredContentSize.width - size.width) > 0.5 {
            preferredContentSize = size
        }
    }

    func focusInitial() {
        guard let window = view.window else { return }
        if let list = listView, let first = list.firstRow {
            window.makeFirstResponder(first)
        } else {
            window.makeFirstResponder(view)
        }
    }
}
