import AppKit
import Quartz
import NachoComboCore

/// A disk or a folder the map can show.
struct DiskTarget: Equatable {
    let name: String
    let path: String
    let isVolume: Bool
}

enum DiskVolumes {
    static func space(at path: String) -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        return DiskSpace(total: Int64(total), free: free, available: max(free, values.volumeAvailableCapacityForImportantUsage ?? free))
    }

    /// The Mac's own disk first, then whatever else is mounted.
    static func list() -> [DiskTarget] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
        let targets = urls.map { url -> DiskTarget in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            return DiskTarget(name: name.isEmpty ? url.path : name, path: url.path, isVolume: true)
        }
        return targets.sorted { $0.path == "/" ? true : ($1.path == "/" ? false : $0.name < $1.name) }
    }

    static var startup: DiskTarget { list().first { $0.path == "/" } ?? DiskTarget(name: "Macintosh HD", path: "/", isVolume: true) }
}

/// Disk Map: what fills a disk, as a sunburst or as blocks, and what is left. Costs nothing until its window is used: a
/// scan runs only when the user asks for one, and the result is dropped a while after the window closes. Nothing is
/// taken off the disk without the user approving exactly what goes.
final class DiskMapModule: NSObject, FeatureModule {
    let id = ModuleID.diskMap
    var optionsProvider: () -> GadgetOptions = { .defaults }
    var updateOptions: ((GadgetOptions) -> Void)?
    var onChange: (() -> Void)?
    var openFullDiskAccess: (() -> Void)?

    private(set) var running = false
    private(set) var controller: DiskMapController?
    private var cachedSpace: (space: DiskSpace?, at: Date)?
    private var releaseTimer: Timer?

    /// How long a finished map stays in memory after its window closes.
    private static let keptAfterClose: TimeInterval = 10 * 60

    /// macOS has no call for this: Full Disk Access shows in whether a file only it opens can be read. Trying never
    /// raises a dialog.
    static var hasFullDiskAccess: Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(probe, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return true
        }
        return errno != EPERM && errno != EACCES
    }

    func start() -> ModuleState {
        running = true
        return .running
    }

    func stop() {
        running = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        controller?.shutDown()
        controller = nil
        cachedSpace = nil
    }

    var isWindowVisible: Bool { controller?.window.isVisible ?? false }

    func showWindow() {
        guard running else { return }
        releaseTimer?.invalidate()
        releaseTimer = nil
        let window = controller ?? makeController()
        window.show()
        onChange?()
    }

    /// Debug only: the made-up disk of the documentation pictures, whether or not the gadget is on.
    func showSample() {
        let window = controller ?? makeController()
        window.show()
        window.loadSample()
    }

    private func makeController() -> DiskMapController {
        let created = DiskMapController(module: self)
        controller = created
        return created
    }

    func windowClosed() {
        onChange?()
        let timer = Timer(timeInterval: DiskMapModule.keptAfterClose, repeats: false) { [weak self] _ in
            guard let self = self, !self.isWindowVisible else { return }
            self.controller?.shutDown()
            self.controller = nil
            self.onChange?()
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    /// The Mac's own disk, read at most every half minute (asking for purgeable space is slow).
    var startupSpace: DiskSpace? {
        if let cached = cachedSpace, Date().timeIntervalSince(cached.at) < 30 { return cached.space }
        let space = DiskVolumes.space(at: "/")
        cachedSpace = (space, Date())
        return space
    }

    func spaceChanged() { cachedSpace = nil }

    var statusLine: String {
        guard let space = startupSpace else { return "Disk space not known" }
        var text = "\(DiskFormat.size(space.free)) free of \(DiskFormat.size(space.total))"
        if let scanned = controller?.summary { text += " · " + scanned }
        return text
    }

    var diagnostics: [String: String] {
        var values: [String: String] = ["running": "\(running)", "windowVisible": "\(isWindowVisible)",
                                        "fullDiskAccess": "\(DiskMapModule.hasFullDiskAccess)"]
        if let controller = controller { values.merge(controller.diagnostics) { $1 } }
        return values
    }
}

// MARK: - Window

/// The map's window: its keyboard and Quick Look.
final class DiskMapWindow: NSWindow, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onKey: ((NSEvent) -> Bool)?
    var onEscape: (() -> Void)?
    var previewURL: (() -> URL?)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    func toggleQuickLook() {
        guard previewURL?() != nil, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func reloadQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL?() == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL?() as NSURL? }
}

/// A plain flipped view that lays its children out by hand, so the window can give the map all the room there is.
final class DiskBoardView: NSView {
    var onLayout: ((NSRect) -> Void)?
    var fill: NSColor?
    var corner: CGFloat = 0

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let fill = fill else { return }
        fill.setFill()
        if corner > 0 {
            NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).fill()
        } else {
            bounds.fill()
        }
    }
}

private final class ButtonRelay {
    var actions: [String: () -> Void] = [:]
}

final class DiskMapController: NSObject, NSWindowDelegate {
    enum Phase: String {
        case idle, scanning, ready
    }

    let window: DiskMapWindow
    private unowned let module: DiskMapModule

    private(set) var phase = Phase.idle
    private(set) var target = DiskVolumes.startup
    private(set) var root: DiskNode?
    private(set) var focus: DiskNode?
    private(set) var selection: DiskNode?
    private(set) var picked = DiskCollection()
    private var space: DiskSpace?
    private var slices: [DiskNode] = []
    /// The sample disk of the documentation pictures: nothing on it exists, so nothing can be done to it.
    private var isSample = false
    private var scanner: DiskScanner?
    private var scanStart = Date()
    private var scanSeconds = 0.0
    private var scanFailed = false
    private var unreadable = 0
    private var nodesKept = 0
    private var scannedAt: Date?
    private var progressTimer: Timer?
    private var expanding: DiskScanner?
    private var removing = false
    private var lastRemoval = "-"
    private var pendingAlert: NSAlert?

    // Views.
    private let board = DiskBoardView()
    private let headerTitle = Brand.signLabel("Disk Map", size: 20, color: Brand.boardInk)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let styleControl: NSSegmentedControl
    private let coloringPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scanButton: ClosureButton
    private let capacity = DiskCapacityView()
    private let crumbs = NSStackView()
    private let canvas = DiskCanvasView()
    private let start = NSStackView()
    private let startTitle = Brand.signLabel("Map this disk", size: 30, color: Brand.boardInk)
    private let startText = UI.wrapLabel("", width: 420, style: .callout, color: Brand.boardMute)
    private let startButton: BrandButton
    private let startAccess: BrandButton
    private let cancelButton: BrandButton
    private let listTitle = NSTextField(labelWithString: "")
    private let listSize = NSTextField(labelWithString: "")
    private let list = DiskListView()
    private let detail = DiskBoardView()
    private let detailIcon = NSImageView()
    private let detailName = NSTextField(labelWithString: "")
    private let detailPath = NSTextField(labelWithString: "")
    private let detailSize = NSTextField(labelWithString: "")
    private let detailShare = NSTextField(labelWithString: "")
    private let detailFacts = NSTextField(labelWithString: "")
    private let detailNote = NSTextField(wrappingLabelWithString: "")
    private let finderButton: BrandButton
    private let pickButton: BrandButton
    private let removeButton: BrandButton
    private let accessButton: BrandButton
    private let bin = DiskBoardView()
    private let binText = NSTextField(labelWithString: "")
    private let binClear: BrandButton
    private let binReview: BrandButton
    private let banner = DiskBoardView()
    private let bannerText = NSTextField(labelWithString: "")
    private let bannerButton: BrandButton
    private var bannerAction: (() -> Void)?

    private static let sidebarWidth: CGFloat = 316
    private static let margin: CGFloat = 16

    init(module: DiskMapModule) {
        self.module = module
        window = DiskMapWindow(contentRect: NSRect(x: 0, y: 0, width: 1140, height: 780),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        styleControl = NSSegmentedControl(labels: DiskMapStyle.allCases.map { $0.displayName }, trackingMode: .selectOne, target: nil, action: nil)
        // The buttons exist before `self` does, so they call through a table filled in right after.
        let relay = ButtonRelay()
        func handler(_ key: String) -> () -> Void { { relay.actions[key]?() } }
        scanButton = ClosureButton(title: "Scan Again", handler: handler("scan"))
        startButton = BrandButton("Scan", style: .primary, handler: handler("scan"))
        startAccess = BrandButton("Allow Full Disk Access…", style: .board, small: true, handler: handler("access"))
        cancelButton = BrandButton("Cancel", style: .board, small: true, handler: handler("cancel"))
        finderButton = BrandButton("Show in Finder", style: .board, small: true, handler: handler("finder"))
        pickButton = BrandButton("Add to List", style: .board, small: true, handler: handler("pick"))
        removeButton = BrandButton("Remove…", style: .board, small: true, handler: handler("remove"))
        accessButton = BrandButton("Allow Full Disk Access…", style: .board, small: true, handler: handler("access"))
        binClear = BrandButton("Clear", style: .board, small: true, handler: handler("binClear"))
        binReview = BrandButton("Review…", style: .attention, small: true, handler: handler("binReview"))
        bannerButton = BrandButton("Open Trash", style: .board, small: true, handler: handler("banner"))
        super.init()
        relay.actions = [
            "scan": { [weak self] in self?.scanCurrentTarget() },
            "access": { [weak self] in self?.module.openFullDiskAccess?() },
            "cancel": { [weak self] in self?.cancelScan() },
            "finder": { [weak self] in if let node = self?.selection ?? self?.focus { self?.showInFinder(node) } },
            "pick": { [weak self] in self?.togglePicked() },
            "remove": { [weak self] in if let node = self?.selection { self?.askToRemove([node]) } },
            "binClear": { [weak self] in self?.clearPicked() },
            "binReview": { [weak self] in if let items = self?.picked.items { self?.askToRemove(items) } },
            "banner": { [weak self] in self?.bannerAction?() },
        ]
        buildWindow()
        selectStyle(module.optionsProvider().diskMapStyle)
        refreshAll()
    }

    // MARK: building

    private func buildWindow() {
        window.title = "Disk Map"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The map hangs on the menu board, which looks the same in both appearances.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Brand.board
        window.contentMinSize = NSSize(width: 900, height: 640)
        window.previewURL = { [weak self] in
            guard let self = self, !self.isSample, let node = self.selection, node.isItem else { return nil }
            return URL(fileURLWithPath: node.path)
        }
        window.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        window.onEscape = { [weak self] in self?.escape() }
        if !window.setFrameUsingName("NachoComboDiskMap") { window.center() }
        window.setFrameAutosaveName("NachoComboDiskMap")

        board.fill = Brand.board
        board.autoresizingMask = [.width, .height]
        board.onLayout = { [weak self] rect in self?.layOut(rect) }
        window.contentView = board

        headerTitle.setAccessibilityIdentifier("disk-title")
        targetPopup.target = self
        targetPopup.action = #selector(targetChosen)
        targetPopup.controlSize = .regular
        targetPopup.font = UI.controlFont(.callout)
        targetPopup.setAccessibilityLabel("Disk or folder to map")
        targetPopup.setAccessibilityIdentifier("disk-target")
        styleControl.target = self
        styleControl.action = #selector(styleChosen)
        styleControl.setAccessibilityLabel("Picture")
        styleControl.setAccessibilityIdentifier("disk-style")
        for (index, symbol) in ["chart.pie.fill", "square.split.2x2.fill"].enumerated() {
            styleControl.setImage(UI.symbol(symbol, size: 12), forSegment: index)
            styleControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        coloringPopup.addItems(withTitles: DiskColoring.allCases.map { $0.displayName })
        coloringPopup.target = self
        coloringPopup.action = #selector(coloringChosen)
        coloringPopup.font = UI.controlFont(.callout)
        coloringPopup.setAccessibilityLabel("Color the map")
        coloringPopup.setAccessibilityIdentifier("disk-coloring")
        coloringPopup.selectItem(at: DiskColoring.allCases.firstIndex(of: module.optionsProvider().diskColoring) ?? 0)
        canvas.coloring = module.optionsProvider().diskColoring
        scanButton.bezelStyle = .rounded
        scanButton.font = UI.controlFont(.callout)
        scanButton.image = UI.symbol("arrow.clockwise", size: 12, weight: .medium)
        scanButton.imagePosition = .imageLeading
        scanButton.setAccessibilityIdentifier("disk-scan-again")
        scanButton.toolTip = "Scan again (⌘R)"

        crumbs.orientation = .horizontal
        crumbs.spacing = 2
        crumbs.alignment = .centerY
        crumbs.setAccessibilityLabel("Where you are")

        canvas.onSelect = { [weak self] node in self?.select(node) }
        canvas.onOpen = { [weak self] node in self?.open(node) }
        canvas.onUp = { [weak self] in self?.goUp() }
        canvas.onMenu = { [weak self] node, _ in self?.menu(for: node) }
        canvas.setAccessibilityIdentifier("disk-canvas")
        list.onSelect = { [weak self] node in self?.select(node, fromList: true) }
        list.onOpen = { [weak self] node in self?.open(node) }
        list.onMenu = { [weak self] node, _ in self?.menu(for: node) }

        startTitle.setAccessibilityIdentifier("disk-start-title")
        startButton.setAccessibilityIdentifier("disk-scan")
        startAccess.setAccessibilityIdentifier("disk-allow-access")
        start.orientation = .vertical
        start.alignment = .centerX
        start.spacing = 12
        for view in [startTitle, startText, startButton, startAccess] as [NSView] { start.addArrangedSubview(view) }
        startText.alignment = .center
        start.setCustomSpacing(18, after: startText)
        cancelButton.setAccessibilityIdentifier("disk-cancel")

        configure(listTitle, font: Brand.mono(11), color: Brand.boardMute, truncation: .byTruncatingMiddle)
        configure(listSize, font: Brand.mono(11), color: Brand.boardInk, truncation: .byClipping)
        listSize.alignment = .right

        detail.fill = Brand.board2
        detail.corner = 10
        detail.onLayout = { [weak self] rect in self?.layOutDetail(rect) }
        configure(detailName, font: Brand.body(14, weight: .semibold), color: Brand.boardInk, truncation: .byTruncatingMiddle)
        configure(detailPath, font: Brand.mono(10, weight: .medium), color: Brand.boardMute, truncation: .byTruncatingMiddle)
        configure(detailSize, font: Brand.sign(26), color: Brand.nacho, truncation: .byClipping)
        configure(detailShare, font: Brand.mono(10), color: Brand.boardMute, truncation: .byTruncatingTail)
        configure(detailFacts, font: Brand.body(11.5), color: Brand.boardMute, truncation: .byTruncatingTail)
        detailNote.font = Brand.body(11.5)
        detailNote.textColor = Brand.boardMute
        detailNote.isSelectable = false
        detailNote.maximumNumberOfLines = 5
        detailIcon.imageScaling = .scaleProportionallyUpOrDown
        detailIcon.setAccessibilityElement(false)
        finderButton.setAccessibilityIdentifier("disk-finder")
        finderButton.toolTip = "Go to this item in Finder"
        pickButton.setAccessibilityIdentifier("disk-pick")
        pickButton.toolTip = "Collect items, then review and remove them together"
        removeButton.setAccessibilityIdentifier("disk-remove")
        removeButton.toolTip = "Asks first (⌘⌫)"
        accessButton.setAccessibilityIdentifier("disk-allow-access-detail")
        for view in [detailIcon, detailName, detailPath, detailSize, detailShare, detailFacts, detailNote, finderButton, pickButton, removeButton,
                     accessButton] as [NSView] { detail.addSubview(view) }

        bin.fill = Brand.boardPick
        bin.corner = 10
        bin.onLayout = { [weak self] rect in self?.layOutBin(rect) }
        configure(binText, font: Brand.body(12, weight: .semibold), color: Brand.boardInk, truncation: .byTruncatingTail)
        binText.setAccessibilityIdentifier("disk-list-total")
        binReview.setAccessibilityIdentifier("disk-review")
        binClear.setAccessibilityIdentifier("disk-clear-list")
        for view in [binText, binClear, binReview] as [NSView] { bin.addSubview(view) }

        banner.fill = Brand.board2
        banner.corner = 8
        banner.onLayout = { [weak self] rect in self?.layOutBanner(rect) }
        configure(bannerText, font: Brand.body(12), color: Brand.boardInk, truncation: .byTruncatingTail)
        bannerText.setAccessibilityIdentifier("disk-banner")
        bannerButton.setAccessibilityIdentifier("disk-banner-action")
        for view in [bannerText, bannerButton] as [NSView] { banner.addSubview(view) }
        banner.isHidden = true

        for view in [headerTitle, targetPopup, styleControl, coloringPopup, scanButton, capacity, crumbs, canvas, listTitle, listSize, list, detail, bin, banner]
            as [NSView] { board.addSubview(view) }
        canvas.addSubview(start)
        canvas.addSubview(cancelButton)
        reloadTargets()
    }

    private func configure(_ field: NSTextField, font: NSFont, color: NSColor, truncation: NSLineBreakMode) {
        field.font = font
        field.textColor = color
        field.lineBreakMode = truncation
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
    }

    private func layOut(_ rect: NSRect) {
        let margin = DiskMapController.margin
        let width = rect.width
        // The title bar's buttons sit in the top-left corner.
        var x: CGFloat = 86
        headerTitle.sizeToFit()
        headerTitle.frame = NSRect(x: x, y: 13, width: headerTitle.frame.width + 2, height: 30)
        x = headerTitle.frame.maxX + 14
        targetPopup.frame = NSRect(x: x, y: 14, width: 210, height: 28)
        var right = width - margin
        scanButton.sizeToFit()
        let scanWidth = scanButton.frame.width + 6
        scanButton.frame = NSRect(x: right - scanWidth, y: 15, width: scanWidth, height: 26)
        right = scanButton.frame.minX - 8
        coloringPopup.sizeToFit()
        let coloringWidth = coloringPopup.frame.width + 2
        coloringPopup.frame = NSRect(x: right - coloringWidth, y: 14, width: coloringWidth, height: 28)
        right = coloringPopup.frame.minX - 8
        styleControl.sizeToFit()
        let styleWidth = styleControl.frame.width
        styleControl.frame = NSRect(x: right - styleWidth, y: 15, width: styleWidth, height: 26)

        capacity.frame = NSRect(x: margin, y: 54, width: width - 2 * margin, height: 56)
        let sidebar = DiskMapController.sidebarWidth
        let columnGap: CGFloat = 16
        let mapWidth = width - sidebar - 2 * margin - columnGap
        crumbs.frame = NSRect(x: margin, y: 114, width: mapWidth, height: 26)
        let bottom = rect.height - margin
        let bannerHeight: CGFloat = banner.isHidden ? 0 : 36
        canvas.frame = NSRect(x: margin, y: 146, width: mapWidth, height: bottom - 146 - (bannerHeight > 0 ? bannerHeight + 8 : 0))
        banner.frame = NSRect(x: margin, y: bottom - bannerHeight, width: mapWidth, height: bannerHeight)

        let sideX = width - margin - sidebar
        listSize.sizeToFit()
        let sizeWidth = listSize.frame.width + 4
        listSize.frame = NSRect(x: sideX + sidebar - sizeWidth - 8, y: 116, width: sizeWidth, height: 18)
        listTitle.frame = NSRect(x: sideX, y: 116, width: sidebar - sizeWidth - 16, height: 18)
        var y = bottom
        if !bin.isHidden {
            bin.frame = NSRect(x: sideX, y: y - 42, width: sidebar, height: 42)
            y = bin.frame.minY - 8
        }
        let detailHeight = detailHeightNeeded()
        detail.frame = NSRect(x: sideX, y: y - detailHeight, width: sidebar, height: detailHeight)
        y = detail.frame.minY - 8
        list.frame = NSRect(x: sideX, y: 138, width: sidebar, height: max(60, y - 138))

        let fitting = start.fittingSize
        start.frame = NSRect(x: (canvas.bounds.width - fitting.width) / 2, y: (canvas.bounds.height - fitting.height) / 2 - 12,
                             width: fitting.width, height: fitting.height)
        let cancelSize = cancelButton.intrinsicContentSize
        cancelButton.frame = NSRect(x: (canvas.bounds.width - cancelSize.width) / 2, y: min(canvas.bounds.height - 40, canvas.bounds.midY + 150),
                                    width: cancelSize.width, height: cancelSize.height)
    }

    private func detailHeightNeeded() -> CGFloat {
        let noteWidth = DiskMapController.sidebarWidth - 28
        var height: CGFloat = 12 + 40 + 6 + 36 + 18 + 12 + 24 + 12
        if !detailNote.stringValue.isEmpty {
            height += ceil(detailNote.attributedStringValue.boundingRect(with: NSSize(width: noteWidth, height: 200),
                                                                        options: [.usesLineFragmentOrigin]).height) + 8
        }
        return height
    }

    private func layOutDetail(_ rect: NSRect) {
        let pad: CGFloat = 14, width = rect.width - 2 * pad
        detailIcon.frame = NSRect(x: pad, y: 12, width: 36, height: 36)
        detailName.frame = NSRect(x: pad + 44, y: 12, width: width - 44, height: 20)
        detailPath.frame = NSRect(x: pad + 44, y: 33, width: width - 44, height: 14)
        detailSize.sizeToFit()
        let sizeWidth = detailSize.frame.width + 4
        detailSize.frame = NSRect(x: pad, y: 54, width: sizeWidth, height: 38)
        detailShare.frame = NSRect(x: pad + sizeWidth + 8, y: 68, width: max(0, width - sizeWidth - 8), height: 14)
        detailFacts.frame = NSRect(x: pad, y: 92, width: width, height: 16)
        var y: CGFloat = 112
        if !detailNote.stringValue.isEmpty {
            let height = ceil(detailNote.attributedStringValue.boundingRect(with: NSSize(width: width, height: 200),
                                                                            options: [.usesLineFragmentOrigin]).height)
            detailNote.frame = NSRect(x: pad, y: y, width: width, height: height)
            y += height + 8
        } else {
            detailNote.frame = .zero
        }
        var x = pad
        for button in [finderButton, pickButton, removeButton, accessButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: rect.height - 12 - size.height, width: size.width, height: size.height)
            x += size.width + 6
        }
    }

    private func layOutBin(_ rect: NSRect) {
        let review = binReview.intrinsicContentSize, clear = binClear.intrinsicContentSize
        binReview.frame = NSRect(x: rect.width - review.width - 10, y: (rect.height - review.height) / 2, width: review.width, height: review.height)
        binClear.frame = NSRect(x: binReview.frame.minX - clear.width - 6, y: binReview.frame.minY, width: clear.width, height: clear.height)
        binText.frame = NSRect(x: 12, y: (rect.height - 18) / 2, width: max(0, binClear.frame.minX - 18), height: 18)
    }

    private func layOutBanner(_ rect: NSRect) {
        let size = bannerButton.intrinsicContentSize
        bannerButton.frame = NSRect(x: rect.width - size.width - 8, y: (rect.height - size.height) / 2, width: size.width, height: size.height)
        let right = bannerButton.isHidden ? rect.width - 8 : bannerButton.frame.minX - 8
        bannerText.frame = NSRect(x: 12, y: (rect.height - 18) / 2, width: max(0, right - 12), height: 18)
    }

    // MARK: showing

    func show() {
        reloadTargets()
        refreshSpace()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The map's last look before it goes: nothing keeps running or stays in memory.
    func shutDown() {
        progressTimer?.invalidate()
        progressTimer = nil
        scanner?.cancel()
        scanner = nil
        expanding?.cancel()
        expanding = nil
        window.delegate = nil
        window.close()
        root = nil
        focus = nil
        selection = nil
        picked.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        if phase == .scanning { cancelScan() }
        DispatchQueue.main.async { [weak self] in self?.module.windowClosed() }
    }

    func windowDidResize(_ notification: Notification) { board.needsLayout = true }

    private func reloadTargets() {
        var targets = DiskVolumes.list()
        if !target.isVolume { targets.append(target) }
        targetPopup.removeAllItems()
        for item in targets {
            targetPopup.addItem(withTitle: item.name)
            targetPopup.lastItem?.representedObject = item.path
            targetPopup.lastItem?.toolTip = item.path
            if !item.isVolume { targetPopup.lastItem?.image = UI.symbol("folder", size: 12) }
        }
        targetPopup.menu?.addItem(.separator())
        targetPopup.addItem(withTitle: "Choose Folder…")
        targetPopup.selectItem(at: targets.firstIndex { $0.path == target.path } ?? 0)
    }

    @objc private func targetChosen() {
        guard let path = targetPopup.selectedItem?.representedObject as? String else {
            chooseFolder()
            return
        }
        guard path != target.path || phase == .idle else { return }
        let chosen = DiskVolumes.list().first { $0.path == path } ?? target
        scan(chosen)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to map."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let url = panel.url else {
                self.reloadTargets()
                return
            }
            let name = FileManager.default.displayName(atPath: url.path)
            let volume = DiskVolumes.list().first { $0.path == url.path }
            self.scan(volume ?? DiskTarget(name: name, path: url.path, isVolume: false))
        }
    }

    @objc private func styleChosen() {
        let style = DiskMapStyle.allCases[max(0, styleControl.selectedSegment)]
        selectStyle(style)
        var options = module.optionsProvider()
        guard options.diskMapStyle != style else { return }
        options.diskMapStyle = style
        module.updateOptions?(options)
    }

    func selectStyle(_ style: DiskMapStyle) {
        styleControl.selectedSegment = DiskMapStyle.allCases.firstIndex(of: style) ?? 0
        canvas.style = style
    }

    @objc private func coloringChosen() {
        let coloring = DiskColoring.allCases[max(0, coloringPopup.indexOfSelectedItem)]
        selectColoring(coloring)
        var options = module.optionsProvider()
        guard options.diskColoring != coloring else { return }
        options.diskColoring = coloring
        module.updateOptions?(options)
    }

    func selectColoring(_ coloring: DiskColoring) {
        coloringPopup.selectItem(at: DiskColoring.allCases.firstIndex(of: coloring) ?? 0)
        canvas.coloring = coloring
        refreshMap()
    }

    /// The settings changed on the gadget's page.
    func applyOptions() {
        let options = module.optionsProvider()
        if canvas.style != options.diskMapStyle { selectStyle(options.diskMapStyle) }
        if canvas.coloring != options.diskColoring { selectColoring(options.diskColoring) }
    }

    // MARK: scanning

    private func scanCurrentTarget() { scan(isSample ? DiskVolumes.startup : target) }

    func scan(_ newTarget: DiskTarget) {
        cancelRunningScan()
        target = newTarget
        isSample = false
        scanFailed = false
        root = nil
        focus = nil
        selection = nil
        picked.removeAll()
        slices = []
        hideBanner()
        space = DiskVolumes.space(at: newTarget.path)
        let scanner = DiskScanner(path: newTarget.path, name: newTarget.name)
        self.scanner = scanner
        scanStart = Date()
        phase = .scanning
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.updateProgress() }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        reloadTargets()
        refreshAll()
        updateProgress()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = scanner.run()
            DispatchQueue.main.async { self?.scanEnded(scanner, result: result) }
        }
    }

    private func cancelRunningScan() {
        progressTimer?.invalidate()
        progressTimer = nil
        scanner?.cancel()
        scanner = nil
    }

    func cancelScan() {
        cancelRunningScan()
        phase = .idle
        refreshAll()
    }

    private func scanEnded(_ finished: DiskScanner, result: DiskNode?) {
        guard finished === scanner else { return }
        progressTimer?.invalidate()
        progressTimer = nil
        scanner = nil
        scanSeconds = Date().timeIntervalSince(scanStart)
        unreadable = finished.progress.unreadable
        scannedAt = Date()
        guard let result = result else {
            scanFailed = true
            phase = .idle
            refreshAll()
            return
        }
        root = result
        focus = result
        nodesKept = result.nodeCount
        phase = .ready
        refreshSpace()
        refreshAll()
        list.focusList()
    }

    private func updateProgress() {
        guard let scanner = scanner else { return }
        let progress = scanner.progress
        var fraction: Double?
        if target.isVolume, let used = space?.used, used > 0 { fraction = min(0.99, Double(progress.bytes) / Double(used)) }
        canvas.scan = (fraction, fraction.map { "\(Int($0 * 100))%" } ?? DiskFormat.size(progress.bytes),
                       "\(DiskFormat.files(progress.files)) · \(DiskFormat.size(progress.bytes))", progress.current)
    }

    func loadSample() {
        cancelRunningScan()
        let sample = DiskSample.tree()
        isSample = true
        target = DiskVolumes.startup
        root = sample.root
        focus = sample.root
        selection = nil
        space = sample.space
        picked.removeAll()
        phase = .ready
        hideBanner()
        reloadTargets()
        refreshAll()
    }

    // MARK: moving around

    func select(_ node: DiskNode?, fromList: Bool = false) {
        selection = node
        canvas.selected = node
        if !fromList { list.select(node) }
        refreshDetail()
        window.reloadQuickLook()
    }

    func open(_ node: DiskNode) {
        switch node.kind {
        case .folder:
            focus = node
            selection = nil
            refreshAll()
            expandIfNeeded(node)
        case .file, .smaller:
            showInFinder(node)
        case .hidden, .free:
            break
        }
    }

    /// A folder dropped to save memory comes back by scanning just it.
    private func expandIfNeeded(_ node: DiskNode) {
        guard node.isCollapsed, !isSample else { return }
        expanding?.cancel()
        let scanner = DiskScanner(path: node.path, name: node.name)
        expanding = scanner
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = scanner.run()
            DispatchQueue.main.async {
                guard let self = self, self.expanding === scanner else { return }
                self.expanding = nil
                guard let result = result, node.root === self.root else { return }
                node.adopt(contentsOf: result)
                self.refreshAll()
            }
        }
    }

    func goUp() {
        guard let parent = focus?.parent else { return }
        let from = focus
        focus = parent
        refreshAll()
        select(from)
    }

    private func escape() {
        if selection != nil { select(nil) } else { goUp() }
    }

    func focus(onPath path: String) {
        if let node = root?.descendant(at: path) { open(node) }
    }

    func select(onPath path: String) {
        if let node = focus?.children.first(where: { $0.path == path }) ?? root?.descendant(at: path) { select(node) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if command {
            switch event.charactersIgnoringModifiers ?? "" {
            case "1": selectStyleFromKey(.sunburst); return true
            case "2": selectStyleFromKey(.blocks); return true
            case "r": scanCurrentTarget(); return true
            default: break
            }
            switch event.keyCode {
            case 126: goUp(); return true
            case 125: if let node = selection { open(node) }; return true
            case 51: if let node = selection { askToRemove([node]) }; return true
            default: return false
            }
        }
        if event.keyCode == 49 {
            window.toggleQuickLook()
            return true
        }
        return false
    }

    private func selectStyleFromKey(_ style: DiskMapStyle) {
        styleControl.selectedSegment = DiskMapStyle.allCases.firstIndex(of: style) ?? 0
        styleChosen()
    }

    // MARK: acting on items

    private func menu(for node: DiskNode) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        if node.isFolder { add("Go Inside") { [weak self] in self?.open(node) } }
        guard node.isItem || node.kind == .smaller else { return menu.items.isEmpty ? nil : menu }
        add("Show in Finder") { [weak self] in self?.showInFinder(node) }
        guard node.isItem else { return menu }
        add("Open") { [weak self] in self?.openInApp(node) }
        add("Quick Look") { [weak self] in
            self?.select(node)
            self?.window.toggleQuickLook()
        }
        add("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
        menu.addItem(.separator())
        let verdict = self.verdict(for: node)
        add(picked.contains(node) ? "Take Off the List" : "Add to List", enabled: !verdict.isBlocked) { [weak self] in
            self?.select(node)
            self?.togglePicked()
        }
        add("Remove…", enabled: !verdict.isBlocked && !removing && !isSample) { [weak self] in self?.askToRemove([node]) }
        return menu
    }

    private func showInFinder(_ node: DiskNode) {
        guard !isSample else { return }
        guard FileManager.default.fileExists(atPath: node.path) else {
            say("\(node.name) is no longer there. Scan again to update the map.")
            return
        }
        // A sum stands for the folder it is in, a real item is shown selected in its folder.
        let url = URL(fileURLWithPath: node.path)
        if node.isItem {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInApp(_ node: DiskNode) {
        guard !isSample else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: node.path))
    }

    private func togglePicked() {
        guard let node = selection, node.isItem else { return }
        if picked.items.contains(where: { $0 === node }) {
            picked.remove(node)
        } else if !verdict(for: node).isBlocked {
            picked.add(node)
        }
        refreshPicked()
        refreshDetail()
    }

    private func clearPicked() {
        picked.removeAll()
        refreshPicked()
        refreshDetail()
    }

    func pickSelection() { togglePicked() }

    private func verdict(for node: DiskNode) -> DiskRemovalVerdict {
        guard node.parent != nil else { return .blocked("This is what you scanned. Choose something inside it.") }
        guard node.isItem else { return .blocked("This is not one item on the disk.") }
        // The sample disk has its own owner, so its notes read as they would on a real Mac.
        let home = isSample ? "/" + ["Users", "sam"].joined(separator: "/") : NSHomeDirectory()
        return DiskRemovalPolicy.verdict(path: node.path, home: home)
    }

    /// The approval: the sheet names everything that would go and what it means. Nothing happens without a click on
    /// one of its buttons, and Return does nothing here on purpose.
    func askToRemove(_ nodes: [DiskNode]) {
        guard !removing, !isSample, window.attachedSheet == nil else { return }
        let allowed = nodes.filter { !verdict(for: $0).isBlocked }
        guard !allowed.isEmpty else { return }
        let bytes = allowed.reduce(Int64(0)) { $0 + $1.size }
        let count = allowed.reduce(0) { $0 + $1.fileCount }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = allowed.count == 1 ? NSWorkspace.shared.icon(forFile: allowed[0].path) : GadgetIcon.image(for: .diskMap, size: 64)
        alert.messageText = allowed.count == 1 ? "Remove “\(allowed[0].name)”?" : "Remove \(allowed.count) items?"
        var text = "\(DiskFormat.size(bytes))" + (count > 1 ? " in \(DiskFormat.files(count))." : ".")
        text += " The Trash keeps it on the disk until you empty it. Deleting frees the space now, for good."
        if let space = space, DiskFormat.size(space.free) != DiskFormat.size(space.free + bytes) {
            text += "\n\nFree space goes from \(DiskFormat.size(space.free)) to \(DiskFormat.size(space.free + bytes))."
        }
        alert.informativeText = text
        alert.accessoryView = removalList(allowed)
        let trash = alert.addButton(withTitle: "Move to Trash")
        let delete = alert.addButton(withTitle: "Delete Permanently…")
        let cancel = alert.addButton(withTitle: "Cancel")
        trash.keyEquivalent = ""
        delete.hasDestructiveAction = true
        cancel.keyEquivalent = "\u{1b}"
        trash.setAccessibilityIdentifier("disk-approve-trash")
        delete.setAccessibilityIdentifier("disk-approve-delete")
        cancel.setAccessibilityIdentifier("disk-approve-cancel")
        alert.window.initialFirstResponder = cancel
        pendingAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            self.pendingAlert = nil
            switch response {
            case .alertFirstButtonReturn: self.perform(allowed, permanently: false)
            case .alertSecondButtonReturn: self.askToDelete(allowed, bytes: bytes)
            default: self.lastRemoval = "cancelled"
            }
            self.module.onChange?()
        }
        module.onChange?()
    }

    private func removalList(_ nodes: [DiskNode]) -> NSView {
        let width: CGFloat = 320
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingMiddle
        let wrapped = NSMutableParagraphStyle()
        wrapped.lineBreakMode = .byWordWrapping
        wrapped.paragraphSpacing = 6
        let lines = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor, _ font: NSFont, _ style: NSParagraphStyle) {
            lines.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        let shown = nodes.sorted { $0.size > $1.size }.prefix(6)
        for node in shown {
            add("\(DiskFormat.size(node.size))   \(node.name)", NSColor.labelColor, NSFont.systemFont(ofSize: 12, weight: .medium), oneLine)
            let caution = verdict(for: node).cautionText
            add(node.path, NSColor.secondaryLabelColor, NSFont.systemFont(ofSize: 10.5), caution == nil ? wrapped : oneLine)
            if let caution = caution { add(caution, NSColor.systemOrange, NSFont.systemFont(ofSize: 11), wrapped) }
        }
        if nodes.count > shown.count {
            add("and \(nodes.count - shown.count) more", NSColor.secondaryLabelColor, NSFont.systemFont(ofSize: 11), wrapped)
        }
        lines.deleteCharacters(in: NSRange(location: lines.length - 1, length: 1))
        let field = NSTextField(labelWithAttributedString: lines)
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.preferredMaxLayoutWidth = width
        let height = ceil(lines.boundingRect(with: NSSize(width: width, height: 2000), options: [.usesLineFragmentOrigin]).height)
        field.frame = NSRect(x: 0, y: 0, width: width, height: height + 4)
        return field
    }

    /// Deleting cannot be undone, so it has its own question, and here the safe answer is the default.
    private func askToDelete(_ nodes: [DiskNode], bytes: Int64) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(DiskFormat.size(bytes)) for good?"
        alert.informativeText = "This cannot be undone. Nothing goes to the Trash."
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete Permanently")
        delete.hasDestructiveAction = true
        delete.setAccessibilityIdentifier("disk-confirm-delete")
        pendingAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            self.pendingAlert = nil
            if response == .alertSecondButtonReturn {
                self.perform(nodes, permanently: true)
            } else {
                self.lastRemoval = "cancelled"
            }
            self.module.onChange?()
        }
    }

    /// Debug only: presses a button of the sheet that is showing.
    func clickSheet(_ button: Int) {
        guard let alert = pendingAlert, alert.buttons.indices.contains(button) else { return }
        alert.buttons[button].performClick(nil)
    }

    /// The last look before anything goes: the policy again and the disk as it is now, not as it was when scanned.
    private func stillRemovable(_ node: DiskNode) -> String? {
        if case .blocked(let reason) = verdict(for: node) { return reason }
        var info = stat()
        guard lstat(node.path, &info) == 0 else { return "It is no longer there." }
        return nil
    }

    private func perform(_ nodes: [DiskNode], permanently: Bool) {
        var ready: [DiskNode] = []
        var failed: [(DiskNode, String)] = []
        for node in nodes {
            if let reason = stillRemovable(node) { failed.append((node, reason)) } else { ready.append(node) }
        }
        guard !ready.isEmpty else {
            finishRemoval(done: [], failed: failed, permanently: permanently)
            return
        }
        removing = true
        say(permanently ? "Deleting…" : "Moving to the Trash…")
        refreshDetail()
        if permanently {
            let paths = ready.map { $0.path }
            DispatchQueue.global(qos: .userInitiated).async {
                var errors: [Int: String] = [:]
                for (index, path) in paths.enumerated() {
                    do { try FileManager.default.removeItem(atPath: path) } catch { errors[index] = error.localizedDescription }
                }
                DispatchQueue.main.async { [weak self] in
                    var done: [DiskNode] = []
                    var all = failed
                    for (index, node) in ready.enumerated() {
                        if let message = errors[index] { all.append((node, message)) } else { done.append(node) }
                    }
                    self?.finishRemoval(done: done, failed: all, permanently: true)
                }
            }
        } else {
            let urls = ready.map { URL(fileURLWithPath: $0.path) }
            NSWorkspace.shared.recycle(urls) { moved, error in
                DispatchQueue.main.async { [weak self] in
                    var done: [DiskNode] = []
                    var all = failed
                    for (url, node) in zip(urls, ready) {
                        if moved[url] != nil {
                            done.append(node)
                        } else {
                            all.append((node, error?.localizedDescription ?? "macOS did not move it."))
                        }
                    }
                    self?.finishRemoval(done: done, failed: all, permanently: false)
                }
            }
        }
    }

    private func finishRemoval(done: [DiskNode], failed: [(DiskNode, String)], permanently: Bool) {
        removing = false
        let bytes = done.reduce(Int64(0)) { $0 + $1.size }
        for node in done {
            if let focus = focus, focus === node || focus.isInside(node) { self.focus = node.parent }
            if let selection = selection, selection === node || selection.isInside(node) { self.selection = nil }
            picked.remove(node)
            node.detach()
        }
        picked.keep(in: root)
        module.spaceChanged()
        refreshSpace()
        refreshAll()
        // APFS gives deleted space back a moment later.
        if permanently { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.spaceTick() } }
        lastRemoval = "\(permanently ? "deleted" : "trashed"):\(done.count) failed:\(failed.count)"
        var message = ""
        if !done.isEmpty {
            message = permanently ? "Deleted \(DiskFormat.size(bytes)). It is free now."
                                  : "Moved \(DiskFormat.size(bytes)) to the Trash. The space comes back when you empty it."
        }
        if let first = failed.first {
            let reason = failed.count == 1 ? "“\(first.0.name)” was not removed: \(first.1)" : "\(failed.count) items were not removed. \(first.1)"
            message += (message.isEmpty ? "" : " ") + reason
        }
        say(message, action: !done.isEmpty && !permanently ? ("Open Trash", { [weak self] in self?.openTrash() }) : nil)
        module.onChange?()
    }

    private func spaceTick() {
        module.spaceChanged()
        refreshSpace()
        refreshAll()
    }

    private func openTrash() {
        guard let url = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(url)
    }

    private func say(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        guard !message.isEmpty else { return hideBanner() }
        bannerText.stringValue = message
        bannerText.toolTip = message
        bannerAction = action?.run
        bannerButton.isHidden = action == nil
        if let action = action { bannerButton.title = action.title }
        banner.isHidden = false
        board.needsLayout = true
        banner.needsLayout = true
    }

    private func hideBanner() {
        banner.isHidden = true
        board.needsLayout = true
    }

    // MARK: refreshing

    private func refreshSpace() {
        if !isSample, let fresh = DiskVolumes.space(at: target.path) { space = fresh }
        capacity.space = space
        rebuildSlices()
    }

    /// With the top of a whole disk showing, hidden and free space are part of the picture.
    private func rebuildSlices() {
        var list: [DiskNode] = []
        if target.isVolume, let root = root, focus === root, let space = space {
            let hidden = space.hidden(scanned: root.size)
            if hidden > 0 { list.append(DiskNode(name: "Hidden Space", kind: .hidden, size: hidden)) }
            if space.free > 0 { list.append(DiskNode(name: "Free Space", kind: .free, size: space.free)) }
        }
        if let kind = selection?.kind, kind == .hidden || kind == .free { selection = list.first { $0.kind == kind } }
        slices = list
    }

    private func refreshAll() {
        rebuildSlices()
        refreshMap()
        refreshCrumbs()
        refreshPicked()
        refreshDetail()
        refreshStart()
        board.needsLayout = true
    }

    private func refreshMap() {
        let ready = phase == .ready && focus != nil
        canvas.content = ready ? .map : (phase == .scanning ? .scanning : .empty)
        canvas.focus = focus
        canvas.slices = slices
        canvas.selected = selection
        scanButton.isHidden = phase != .ready
        listTitle.stringValue = ready ? (focus?.name.uppercased() ?? "") : ""
        listSize.stringValue = ready ? DiskFormat.size(focus?.size ?? 0) : ""
        list.set(listRows, selected: selection, picked: picked.items)
        // The bar at the top always shows the whole disk, in the colors of the disk's top level.
        capacity.space = space
        if let root = root, target.isVolume, let space = space {
            capacity.parts = zip(root.children, DiskTone.tones(of: root.children)).map { node, tone in
                DiskCapacityView.Part(bytes: node.size, color: DiskMapRenderer.color(of: node, tone: tone, depth: 0, coloring: canvas.coloring, now: Date()))
            }
            capacity.hiddenBytes = space.hidden(scanned: root.size)
        } else {
            capacity.parts = []
            capacity.hiddenBytes = 0
        }
    }

    private func refreshCrumbs() {
        for view in crumbs.arrangedSubviews { crumbs.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let focus = focus else { return }
        let chain = focus.ancestry
        let hiddenCount = max(0, chain.count - 6)
        for (index, node) in chain.enumerated() {
            if index > 0 && index < hiddenCount { continue }
            let isLast = node === focus
            let button = ClosureButton(title: "") { [weak self] in
                guard let self = self, node !== self.focus else { return }
                self.open(node)
            }
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: node.name, attributes: [
                .font: Brand.mono(11, weight: isLast ? .semibold : .medium), .foregroundColor: isLast ? Brand.boardInk : Brand.boardMute])
            button.setAccessibilityLabel(node.name)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            crumbs.addArrangedSubview(button)
            if !isLast {
                let separator = UI.symbolView("chevron.right", size: 9, tint: Brand.boardMute)
                separator.setAccessibilityElement(false)
                crumbs.addArrangedSubview(separator)
            }
        }
    }

    private func refreshPicked() {
        canvas.picked = picked.items
        bin.isHidden = picked.isEmpty
        let count = picked.items.count
        binText.stringValue = "\(count == 1 ? "1 item" : "\(count) items") · \(DiskFormat.size(picked.bytes))"
        list.set(listRows, selected: selection, picked: picked.items)
        board.needsLayout = true
    }

    private var listRows: [DiskRowView.Row] {
        guard phase == .ready, let focus = focus else { return [] }
        let items = focus.children + slices
        let largest = max(1, items.map { $0.size }.max() ?? 1)
        return zip(items, DiskTone.tones(of: items)).map { node, tone in
            DiskRowView.Row(node: node, color: DiskMapRenderer.color(of: node, tone: tone, depth: 0, coloring: canvas.coloring, now: Date()),
                            share: Double(node.size) / Double(largest))
        }
    }

    private func refreshDetail() {
        let node = selection ?? focus
        detail.isHidden = node == nil
        guard let node = node else { return }
        detailName.stringValue = node.name
        detailPath.stringValue = node.isItem || node.kind == .smaller ? node.path : (target.isVolume ? target.name : "")
        detailPath.toolTip = detailPath.stringValue
        detailSize.stringValue = DiskFormat.size(node.size)
        let whole = space?.total ?? root?.size ?? 0
        let percent = whole > 0 ? Double(node.size) / Double(whole) * 100 : 0
        detailShare.stringValue = percent >= 0.1 ? String(format: "%.1f%% OF THE DISK", percent) : "UNDER 0.1% OF THE DISK"
        var facts: [String] = []
        if node.kind == .folder, node.fileCount > 0 { facts.append(DiskFormat.files(node.fileCount)) }
        if node.kind == .smaller { facts.append(DiskFormat.files(node.fileCount)) }
        if node.isItem, let age = DiskFormat.age(node.modified, now: Date()) { facts.append("changed \(age)") }
        detailFacts.stringValue = facts.joined(separator: " · ")

        detailIcon.image = icon(for: node)
        let verdict = self.verdict(for: node)
        var note = ""
        let noAccess = !DiskMapModule.hasFullDiskAccess
        switch node.kind {
        case .hidden:
            note = "Used on the disk but out of the scan's sight: folders macOS protects, local snapshots, swap and other volumes."
            if unreadable > 0 { note += " \(DiskFormat.count(unreadable)) folders could not be read." }
        case .free:
            note = "Free right now."
            if let space = space, space.purgeable > 0 { note += " macOS can clear another \(DiskFormat.size(space.purgeable)) by itself when it needs room." }
        case .smaller:
            note = "Items too small to draw, summed up."
        case .file, .folder:
            if node.isUnreadable { note = "macOS did not let Nacho Combo read this folder." }
            else if node !== focus {
                if case .blocked(let reason) = verdict { note = reason } else if let caution = verdict.cautionText { note = caution }
            }
        }
        detailNote.stringValue = note
        detailNote.textColor = verdict.cautionText != nil && node.isItem && node !== focus ? Brand.nacho : Brand.boardMute
        finderButton.isHidden = !(node.isItem || node.kind == .smaller)
        finderButton.isEnabled = !isSample
        pickButton.isHidden = !node.isItem || node.parent == nil
        pickButton.isEnabled = !verdict.isBlocked
        pickButton.title = picked.items.contains { $0 === node } ? "On the List" : "Add to List"
        removeButton.isHidden = !node.isItem || node.parent == nil
        removeButton.isEnabled = !verdict.isBlocked && !removing && !isSample
        accessButton.isHidden = !(node.kind == .hidden && noAccess) || isSample
        board.needsLayout = true
        detail.needsLayout = true
    }

    private func icon(for node: DiskNode) -> NSImage? {
        switch node.kind {
        case .file, .folder:
            if isSample {
                return NSWorkspace.shared.icon(for: node.isFolder ? .folder : .data)
            }
            return NSWorkspace.shared.icon(forFile: node.path)
        case .smaller: return UI.symbol("square.grid.3x3", size: 26)
        case .hidden: return UI.symbol("eye.slash", size: 26)
        case .free: return UI.symbol("sparkles", size: 26)
        }
    }

    private func refreshStart() {
        let idle = phase == .idle
        start.isHidden = !idle
        cancelButton.isHidden = phase != .scanning
        guard idle else { return }
        let noAccess = !DiskMapModule.hasFullDiskAccess
        var words: String
        if scanFailed {
            words = "macOS did not let Nacho Combo read \(target.name)."
        } else {
            words = "Find out what fills \(target.name). Only names and sizes are read, on this Mac, and nothing leaves it."
        }
        if noAccess {
            words += " Without Full Disk Access macOS asks about your folders one by one, and what it keeps closed counts as hidden space."
        }
        startTitle.attributedStringValue = NSAttributedString(string: "MAP \(target.name.uppercased())", attributes: [
            .font: Brand.sign(30), .foregroundColor: Brand.boardInk, .kern: 0.6])
        startText.stringValue = words
        startButton.title = "Scan \(target.name)"
        startAccess.isHidden = !noAccess
        start.needsLayout = true
        board.needsLayout = true
    }

    // MARK: facts

    var summary: String? {
        guard phase == .ready, let root = root, let at = scannedAt else { return phase == .scanning ? "scanning" : nil }
        return "\(root.name) mapped \(DiskFormat.age(at.timeIntervalSince1970, now: Date()) ?? "today")"
    }

    var diagnostics: [String: String] {
        [
            "phase": phase.rawValue,
            "target": target.path,
            "sample": "\(isSample)",
            "focus": focus?.path ?? "",
            "selection": selection?.path ?? "",
            "selectionKind": selection.map { "\($0.kind)" } ?? "",
            "picked": "\(picked.items.count)",
            "pickedBytes": "\(picked.bytes)",
            "nodes": "\(nodesKept)",
            "scanned": "\(root?.size ?? 0)",
            "files": "\(root?.fileCount ?? 0)",
            "scanSeconds": String(format: "%.2f", scanSeconds),
            "unreadable": "\(unreadable)",
            "free": "\(space?.free ?? 0)",
            "hidden": "\(root.flatMap { root in space?.hidden(scanned: root.size) } ?? 0)",
            "style": canvas.style.rawValue,
            "coloring": canvas.coloring.rawValue,
            "drawn": "\(canvas.renderer?.drawnCount ?? 0)",
            "sheet": pendingAlert?.messageText ?? "",
            "lastRemoval": lastRemoval,
            "banner": banner.isHidden ? "" : bannerText.stringValue,
        ]
    }

    /// Debug only: a click at a point of the map, through the view's own mouse handling.
    func simulateClick(x: CGFloat, y: CGFloat, count: Int) {
        let point = canvas.convert(NSPoint(x: x, y: y), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) else { return }
        canvas.mouseDown(with: event)
    }

    /// Debug only: a key press, through the window's own key handling.
    func simulateKey(code: UInt16, characters: String, command: Bool) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? [.command] : [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        window.keyDown(with: event)
    }

    /// Debug only: the approval sheet's picture.
    func writeSheetSnapshot(to url: URL) -> Bool {
        guard let view = pendingAlert?.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Debug only: the window's picture as it is now.
    func writeSnapshot(to url: URL) -> Bool {
        guard let view = window.contentView else { return false }
        board.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep = rep else { return false }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
