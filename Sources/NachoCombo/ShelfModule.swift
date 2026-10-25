import AppKit
import Quartz
import UniformTypeIdentifiers
import NachoComboCore

/// Temporary drag-and-drop shelf. Dragged files, images, links and text are collected on a small floating panel and
/// can be dragged out again (copy only). Originals are never moved or deleted. The shelf shows itself when the user
/// shakes the pointer during a drag (or on any drag, or only from its shortcut), at the pointer.
final class ShelfModule: NSObject, FeatureModule {
    let id = ModuleID.fileShelf
    var optionsProvider: () -> GadgetOptions = { .defaults }

    let store: ShelfStore
    private var panel: ShelfPanel?
    private var globalMonitor: Any?
    private var dragChangeAtMouseDown = 0
    private var shownForThisDrag = false
    private var shake = ShakeDetector()
    private(set) var lastDropResult = "-"
    private(set) var autoShowCount = 0
    private(set) var running = false
    private let promiseQueue = OperationQueue()
    var onVisibilityChange: (() -> Void)?

    init(store: ShelfStore = ShelfStore(ownedDirectory: ShelfStore.defaultOwnedDirectory())) {
        self.store = store
        promiseQueue.qualityOfService = .userInitiated
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func start() -> ModuleState {
        guard !running else { return .running }
        running = true
        installDragMonitor()
        ensurePanel().showAtDefaultPosition()
        refreshPanel()
        return .running
    }

    func stop() {
        running = false
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        panel?.onModelChange = nil
        panel?.orderOut(nil)
        panel?.closeForReal()
        panel = nil
        store.removeAllOwnedFiles()     // only shelf-created copies; user originals are never touched
    }

    // MARK: panel control

    func show() {
        guard running else { return }
        ensurePanel().showAtDefaultPosition()
        refreshPanel()
        onVisibilityChange?()
    }

    /// Opens the shelf under the pointer (after a shake), fully on screen.
    func show(near point: NSPoint) {
        guard running else { return }
        ensurePanel().show(near: point)
        refreshPanel()
        onVisibilityChange?()
    }

    func hide() {
        panel?.orderOut(nil)
        onVisibilityChange?()
    }

    func toggle() { isPanelVisible ? hide() : show() }

    /// Adds what is on the clipboard (explicit action only; the clipboard is never read otherwise).
    func pasteClipboard() {
        guard running else { return }
        ingest(NSPasteboard.general)
        show()
    }

    func clear() {
        store.clear()
        refreshPanel()
    }

    private func ensurePanel() -> ShelfPanel {
        if let panel = panel { return panel }
        let created = ShelfPanel()
        created.onDrop = { [weak self] pasteboard in self?.ingest(pasteboard) ?? false }
        created.onRemove = { [weak self] id in
            self?.store.remove(id: id)
            self?.refreshPanel()
        }
        created.onClear = { [weak self] in self?.clear() }
        created.onUndo = { [weak self] in
            guard let self = self else { return }
            self.store.undo()
            self.refreshPanel()
        }
        created.onPaste = { [weak self] in self?.pasteClipboard() }
        created.onClosed = { [weak self] in self?.onVisibilityChange?() }
        panel = created
        return created
    }

    private func refreshPanel() {
        panel?.setItems(store.items, canUndo: !store.undoable.isEmpty)
        onVisibilityChange?()
    }

    // MARK: ingest

    /// Adds whatever the pasteboard offers: file URLs, then promised files (browsers, Photos, Mail), then image data,
    /// then web links, then plain text.
    @discardableResult
    func ingest(_ pasteboard: NSPasteboard) -> Bool {
        var added = 0
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            for url in urls where store.addFile(url) != nil { added += 1 }
        } else if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
                    as? [NSFilePromiseReceiver], !promises.isEmpty {
            receive(promises)
            lastDropResult = "promised:\(promises.count)"
            return true
        } else if let png = ShelfModule.pngData(from: pasteboard) {
            if (try? store.addImagePNG(png)) != nil { added += 1 }
        } else if let links = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !links.isEmpty {
            for url in links where store.addLink(url) != nil { added += 1 }
        } else if let text = pasteboard.string(forType: .string) {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true,
               store.addLink(url) != nil {
                added += 1
            } else if store.addText(text) != nil {
                added += 1
            }
        }
        lastDropResult = added > 0 ? "ok:\(added)" : "none"
        refreshPanel()
        return added > 0
    }

    /// Promised files are written by the source app into a fresh folder inside the shelf's own directory.
    private func receive(_ promises: [NSFilePromiseReceiver]) {
        let destination = store.ownedDirectory.appendingPathComponent("promised-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for promise in promises {
            promise.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: promiseQueue) { url, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, error == nil, self.running else { return }
                    if self.store.addOwnedFile(url) != nil { self.lastDropResult = "ok:promise" }
                    self.refreshPanel()
                }
            }
        }
    }

    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: drag detection

    /// A passive mouse monitor (no permission needed) notices drags; a change of the drag pasteboard since the mouse
    /// went down tells a real drag (files, text, images) from a plain pointer move.
    private func installDragMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            let drag = NSPasteboard(name: .drag)
            if event.type == .leftMouseDown {
                self.dragChangeAtMouseDown = drag.changeCount
                self.shownForThisDrag = false
                self.shake.reset()
                return
            }
            guard !self.shownForThisDrag, drag.changeCount != self.dragChangeAtMouseDown else { return }
            switch self.optionsProvider().shelfTrigger {
            case .shortcutOnly:
                return
            case .anyDrag:
                guard !self.isPanelVisible else { return }
                self.shownForThisDrag = true
                self.autoShowCount += 1
                self.show()
            case .shake:
                let point = NSEvent.mouseLocation
                if self.shake.add(x: point.x, time: event.timestamp) {
                    self.shownForThisDrag = true
                    self.autoShowCount += 1
                    self.show(near: point)
                }
            }
        }
    }

    var diagnostics: [String: String] {
        [
            "panelVisible": "\(isPanelVisible)",
            "itemCount": "\(store.items.count)",
            "items": store.items.map { "\($0.kind.rawValue):\($0.title)" }.joined(separator: " | "),
            "ownedFiles": "\(store.items.filter { $0.ownsFile }.count)",
            "undoable": "\(store.undoable.count)",
            "trigger": optionsProvider().shelfTrigger.rawValue,
            "dropTargetRegistered": "\(panel != nil)",
            "dragMonitorActive": "\(globalMonitor != nil)",
            "autoShowCount": "\(autoShowCount)",
            "lastDropResult": lastDropResult,
        ]
    }
}

// MARK: - Panel

final class ShelfPanel: NSPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onRemove: ((UUID) -> Void)?
    var onClear: (() -> Void)?
    var onUndo: (() -> Void)?
    var onPaste: (() -> Void)?
    var onClosed: (() -> Void)?
    var onModelChange: (() -> Void)?

    private let dropView = ShelfDropView()
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(wrappingLabelWithString: "Drop files, images, links or text here.\nDragging an item out to another app copies it (the original stays put).")
    private let stackHandle = ShelfStackHandle()
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private var rows: [ShelfRowView] = []
    private(set) var items: [ShelfItem] = []
    private var selectedID: UUID? { didSet { rows.forEach { $0.selected = $0.item.id == selectedID } } }
    private var positioned = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "File Shelf"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 220, height: 160)
        buildContent()
    }

    override var canBecomeKey: Bool { true }

    /// The red close button hides the shelf; items stay until removed or the module is switched OFF.
    override func close() {
        orderOut(nil)
        onClosed?()
    }

    func closeForReal() { super.close() }

    func showAtDefaultPosition() {
        if !positioned, let screen = NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let size = frame.size
            // Right screen edge, vertically centred (clear of the notification banners at the top right).
            setFrameOrigin(NSPoint(x: visible.maxX - size.width - 16, y: visible.midY - size.height / 2 - 40))
            positioned = true
        }
        orderFrontRegardless()
    }

    /// Centred on the pointer, so the drag in progress can drop straight onto it.
    func show(near point: NSPoint) {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let size = frame.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrameOrigin(origin)
        positioned = true
        orderFrontRegardless()
    }

    private func buildContent() {
        dropView.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDrop = { [weak self] pb in self?.onDrop?(pb) ?? false }
        contentView = dropView

        stackHandle.toolTip = "Drag to take every item at once"
        stackHandle.setAccessibilityIdentifier("shelf-stack")
        stackHandle.translatesAutoresizingMaskIntoConstraints = false
        func small(_ title: String, _ id: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 11)
            b.setAccessibilityIdentifier(id)
            return b
        }
        let paste = small("Paste", "shelf-paste", #selector(pasteTapped))
        paste.toolTip = "Add what is on the clipboard (⌘V)"
        undoButton.target = self
        undoButton.action = #selector(undoTapped)
        undoButton.controlSize = .small
        undoButton.bezelStyle = .rounded
        undoButton.font = NSFont.systemFont(ofSize: 11)
        undoButton.toolTip = "Bring back what you removed (⌘Z)"
        undoButton.setAccessibilityIdentifier("shelf-undo")
        let clear = small("Clear All", "shelf-clear", #selector(clearTapped))
        let header = NSStackView(views: [stackHandle, NSView(), paste, undoButton, clear])
        header.orientation = .horizontal
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        dropView.addSubview(header)
        dropView.addSubview(scroll)
        dropView.addSubview(hint)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: dropView.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: dropView.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: dropView.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: dropView.bottomAnchor, constant: -6),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            hint.centerXAnchor.constraint(equalTo: dropView.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: dropView.centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: dropView.widthAnchor, constant: -30),
        ])
    }

    func setItems(_ items: [ShelfItem], canUndo: Bool = false) {
        self.items = items
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rows = []
        for item in items {
            let row = ShelfRowView(item: item)
            row.onRemove = { [weak self] id in self?.onRemove?(id) }
            row.onSelect = { [weak self] id in self?.selectedID = id; self?.makeKey() }
            row.onQuickLook = { [weak self] id in self?.selectedID = id; self?.toggleQuickLook() }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }
        if let selected = selectedID, !items.contains(where: { $0.id == selected }) { selectedID = nil }
        rows.forEach { $0.selected = $0.item.id == selectedID }
        hint.isHidden = !items.isEmpty
        stackHandle.items = items
        undoButton.isHidden = !canUndo
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().reloadData() }
        onModelChange?()
    }

    @objc private func clearTapped() { onClear?() }
    @objc private func undoTapped() { onUndo?() }
    @objc private func pasteTapped() { onPaste?() }

    // Keyboard: Space Quick Look, ⌫ remove, ⌘Z undo, ⌘V paste, ⌘C copy, arrows move the selection.
    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.charactersIgnoringModifiers ?? "", command) {
        case ("z", true): onUndo?()
        case ("v", true): onPaste?()
        case ("c", true): if let item = selectedItem { ShelfRowView.copy(item) }
        default:
            switch event.keyCode {
            case 49: toggleQuickLook()
            case 51, 117: if let id = selectedID { onRemove?(id) }
            case 125, 126:
                guard !items.isEmpty else { return }
                let index = items.firstIndex { $0.id == selectedID } ?? -1
                let next = event.keyCode == 125 ? min(items.count - 1, index + 1) : max(0, index - 1)
                selectedID = items[next].id
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
                    QLPreviewPanel.shared().reloadData()
                }
            default: super.keyDown(with: event)
            }
        }
    }

    private var selectedItem: ShelfItem? { items.first { $0.id == selectedID } }
    private var previewURL: URL? { selectedItem?.fileURL }

    func toggleQuickLook() {
        guard previewURL != nil else { return }
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible { panel.orderOut(nil) } else { makeKey(); panel.makeKeyAndOrderFront(nil) }
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
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURL as NSURL? }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ShelfDropView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promised = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, .URL, .png, .tiff, .string] + promised)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        // Our own rows dropped back on the shelf are not added again.
        if (sender.draggingSource as? NSView)?.window === window { return false }
        return onDrop?(sender.draggingPasteboard) ?? false
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { highlighted = false }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
            bounds.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            path.lineWidth = 2
            path.stroke()
        }
    }
}

/// Item count with a stack icon; dragging it takes every item at once.
final class ShelfStackHandle: NSView, NSDraggingSource {
    var items: [ShelfItem] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize(); updateAccessibility() } }
    private var downPoint: NSPoint?

    override var intrinsicContentSize: NSSize { NSSize(width: 26 + ceil(label.size(withAttributes: attributes).width), height: 22) }
    private var label: NSString { (items.isEmpty ? "Empty" : (items.count == 1 ? "1 item" : "\(items.count) items")) as NSString }
    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
    }

    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag every item: \(label)")
    }

    override func draw(_ dirtyRect: NSRect) {
        if let symbol = UI.symbol(items.count > 1 ? "square.stack.3d.up.fill" : "square.stack.3d.up", size: 13) {
            let tinted = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [
                items.isEmpty ? NSColor.tertiaryLabelColor : NSColor.controlAccentColor])) ?? symbol
            let s = tinted.size
            tinted.draw(in: NSRect(x: 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: 22, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow }
    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !items.isEmpty else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        downPoint = nil
        let draggingItems = items.compactMap { item -> NSDraggingItem? in
            guard let writer = ShelfRowView.writer(for: item) else { return nil }
            let dragging = NSDraggingItem(pasteboardWriter: writer)
            dragging.setDraggingFrame(bounds, contents: ShelfRowView.icon(for: item))
            return dragging
        }
        guard !draggingItems.isEmpty else { return }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy      // never .move: originals stay where they are
    }
}

final class ShelfRowView: NSView, NSDraggingSource {
    let item: ShelfItem
    var onRemove: ((UUID) -> Void)?
    var onSelect: ((UUID) -> Void)?
    var onQuickLook: ((UUID) -> Void)?
    var selected = false { didSet { updateBackground() } }
    private let iconView = NSImageView()
    private var mouseDownPoint: NSPoint?

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 6
        updateBackground()
        setAccessibilityIdentifier("shelf-row-\(item.kind.rawValue)")
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(item.title)

        iconView.image = ShelfRowView.icon(for: item)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = NSTextField(labelWithString: ShelfRowView.detail(for: item))
        detail.font = NSFont.systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        let remove = NSButton(title: "✕", target: self, action: #selector(removeTapped))
        remove.isBordered = false
        remove.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        remove.setAccessibilityLabel("Remove item")
        remove.setAccessibilityIdentifier("shelf-remove")
        remove.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(remove)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: remove.leadingAnchor, constant: -4),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 22),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateBackground() {
        let color = selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35)
                             : NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    static func icon(for item: ShelfItem) -> NSImage {
        switch item.kind {
        case .image:
            if let url = item.fileURL, let image = NSImage(contentsOf: url) { return image }
            return fileIcon(item.fileURL)
        case .file:
            return fileIcon(item.fileURL)
        case .text:
            return NSWorkspace.shared.icon(for: .plainText)
        case .link:
            return UI.symbol("link", size: 22, weight: .medium) ?? NSWorkspace.shared.icon(for: .url)
        }
    }

    /// The file's own icon, or its type's icon when it is not on disk (sample items in the gallery picture).
    private static func fileIcon(_ url: URL?) -> NSImage {
        guard let url = url else { return NSWorkspace.shared.icon(for: .data) }
        if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    static func detail(for item: ShelfItem) -> String {
        switch item.kind {
        case .text: return "Text, \(item.text?.count ?? 0) characters"
        case .link: return item.text ?? "Link"
        case .image, .file:
            let path = item.fileURL?.deletingLastPathComponent().path ?? ""
            return item.ownsFile ? "Copy kept by the shelf" : path
        }
    }

    static func writer(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .text: return item.text.map { $0 as NSString }
        case .link: return item.linkURL.map { $0 as NSURL }
        case .file, .image: return item.fileURL.map { $0 as NSURL }
        }
    }

    static func copy(_ item: ShelfItem) {
        guard let writer = writer(for: item) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([writer])
    }

    @objc private func removeTapped() { onRemove?(item.id) }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        onSelect?(item.id)
        if event.clickCount == 2 { open() }
    }

    private func open() {
        switch item.kind {
        case .file, .image: if let url = item.fileURL { NSWorkspace.shared.open(url) }
        case .link: if let url = item.linkURL { NSWorkspace.shared.open(url) }
        case .text: ShelfRowView.copy(item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?(item.id)
        let menu = NSMenu()
        let entries: [(String, () -> Void)] = {
            var list: [(String, () -> Void)] = []
            switch item.kind {
            case .file, .image:
                list.append(("Open", { [weak self] in self?.open() }))
                list.append(("Quick Look", { [weak self] in guard let self = self else { return }; self.onQuickLook?(self.item.id) }))
                if !item.ownsFile, let url = item.fileURL {
                    list.append(("Show in Finder", { NSWorkspace.shared.activateFileViewerSelecting([url]) }))
                }
            case .link:
                list.append(("Open Link", { [weak self] in self?.open() }))
            case .text:
                break
            }
            list.append(("Copy", { [weak self] in if let item = self?.item { ShelfRowView.copy(item) } }))
            list.append(("Remove", { [weak self] in guard let self = self else { return }; self.onRemove?(self.item.id) }))
            return list
        }()
        for (title, action) in entries { menu.addItem(ClosureMenuItem(title: title, handler: action)) }
        return menu
    }

    // MARK: dragging out (copy only)

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        guard let writer = ShelfRowView.writer(for: item) else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        draggingItem.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy      // never .move: the original must stay where it is
    }
}
