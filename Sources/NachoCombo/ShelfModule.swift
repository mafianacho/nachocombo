import AppKit
import NachoComboCore

/// Dropover-style temporary file shelf. Dragged files, images and text are collected on a small
/// floating panel and can be dragged out again (copy only). Originals are never moved or deleted.
final class ShelfModule: NSObject, FeatureModule {
    let id = ModuleID.fileShelf
    static let hotKeyLabel = "⌃⌥S"

    let store: ShelfStore
    private var panel: ShelfPanel?
    private let hotKeys = HotKeyCenter(signature: 0x4E43_5348)   // 'NCSH'
    private var globalMonitor: Any?
    private var dragChangeAtMouseDown = 0
    private var shownForThisDrag = false
    private(set) var lastDropResult = "-"
    private(set) var autoShowCount = 0
    private(set) var running = false
    var onVisibilityChange: (() -> Void)?

    init(store: ShelfStore = ShelfStore(ownedDirectory: ShelfStore.defaultOwnedDirectory())) {
        self.store = store
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    func start() -> ModuleState {
        guard !running else { return .running }
        running = true
        // A hotkey conflict does not block the shelf; the menu and the settings window still open it.
        _ = hotKeys.register(id: 1, keyCode: 1, modifiers: HotKeySpec.controlKey | HotKeySpec.optionKey) { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        installDragMonitor()
        ensurePanel().showAtDefaultPosition()
        refreshPanel()
        return .running
    }

    func stop() {
        running = false
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        globalMonitor = nil
        hotKeys.unregisterAll()
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

    func hide() {
        panel?.orderOut(nil)
        onVisibilityChange?()
    }

    func toggle() { isPanelVisible ? hide() : show() }

    private func ensurePanel() -> ShelfPanel {
        if let panel = panel { return panel }
        let created = ShelfPanel()
        created.onDrop = { [weak self] pasteboard in self?.ingest(pasteboard) ?? false }
        created.onRemove = { [weak self] id in
            self?.store.remove(id: id)
            self?.refreshPanel()
        }
        created.onClear = { [weak self] in
            self?.store.clear()
            self?.refreshPanel()
        }
        created.onClosed = { [weak self] in self?.onVisibilityChange?() }
        panel = created
        return created
    }

    private func refreshPanel() { panel?.setItems(store.items) }

    // MARK: ingest

    /// Adds whatever the pasteboard offers: file URLs first, then image data, then plain text.
    @discardableResult
    func ingest(_ pasteboard: NSPasteboard) -> Bool {
        var added = 0
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            for url in urls where store.addFile(url) != nil { added += 1 }
        } else if let png = ShelfModule.pngData(from: pasteboard) {
            if (try? store.addImagePNG(png)) != nil { added += 1 }
        } else if let text = pasteboard.string(forType: .string), store.addText(text) != nil {
            added += 1
        }
        lastDropResult = added > 0 ? "ok:\(added)" : "none"
        refreshPanel()
        return added > 0
    }

    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: drag detection (shows the shelf when a drag begins anywhere)

    private func installDragMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self = self else { return }
            let drag = NSPasteboard(name: .drag)
            if event.type == .leftMouseDown {
                self.dragChangeAtMouseDown = drag.changeCount
                self.shownForThisDrag = false
            } else if !self.shownForThisDrag, drag.changeCount != self.dragChangeAtMouseDown, !self.isPanelVisible {
                self.shownForThisDrag = true
                self.autoShowCount += 1
                self.show()
            }
        }
    }

    var diagnostics: [String: String] {
        [
            "panelVisible": "\(isPanelVisible)",
            "itemCount": "\(store.items.count)",
            "items": store.items.map { "\($0.kind.rawValue):\($0.title)" }.joined(separator: " | "),
            "ownedFiles": "\(store.items.filter { $0.ownsFile }.count)",
            "dropTargetRegistered": "\(panel != nil)",
            "dragMonitorActive": "\(globalMonitor != nil)",
            "hotkeysRegistered": "\(hotKeys.registeredCount)",
            "autoShowCount": "\(autoShowCount)",
            "lastDropResult": lastDropResult,
        ]
    }
}

// MARK: - Panel

final class ShelfPanel: NSPanel {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onRemove: ((UUID) -> Void)?
    var onClear: (() -> Void)?
    var onClosed: (() -> Void)?
    var onModelChange: (() -> Void)?

    private let dropView = ShelfDropView()
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(wrappingLabelWithString: "여기에 파일·이미지·텍스트를 끌어다 놓으세요.\n항목을 다른 앱으로 끌어내면 복사됩니다(원본은 그대로).")
    private let countLabel = NSTextField(labelWithString: "")
    private var positioned = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 360),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "파일 선반"
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

    private func buildContent() {
        dropView.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDrop = { [weak self] pb in self?.onDrop?(pb) ?? false }
        contentView = dropView

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let clear = NSButton(title: "모두 비우기", target: self, action: #selector(clearTapped))
        clear.controlSize = .small
        clear.bezelStyle = .rounded
        clear.setAccessibilityIdentifier("shelf-clear")
        header.addArrangedSubview(countLabel)
        header.addArrangedSubview(clear)
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
            header.trailingAnchor.constraint(lessThanOrEqualTo: dropView.trailingAnchor, constant: -10),
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

    func setItems(_ items: [ShelfItem]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        for item in items {
            let row = ShelfRowView(item: item)
            row.onRemove = { [weak self] id in self?.onRemove?(id) }
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        hint.isHidden = !items.isEmpty
        countLabel.stringValue = items.isEmpty ? "비어 있음" : "\(items.count)개 항목"
        onModelChange?()
    }

    @objc private func clearTapped() { onClear?() }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ShelfDropView: NSView {
    var onDrop: ((NSPasteboard) -> Bool)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
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

final class ShelfRowView: NSView, NSDraggingSource {
    let item: ShelfItem
    var onRemove: ((UUID) -> Void)?
    private let iconView = NSImageView()
    private var mouseDownPoint: NSPoint?

    init(item: ShelfItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 44))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        setAccessibilityIdentifier("shelf-row-\(item.kind.rawValue)")

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
        remove.setAccessibilityLabel("항목 제거")
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

    static func icon(for item: ShelfItem) -> NSImage {
        switch item.kind {
        case .image:
            if let url = item.fileURL, let image = NSImage(contentsOf: url) { return image }
            return NSWorkspace.shared.icon(forFile: item.fileURL?.path ?? "")
        case .file:
            return NSWorkspace.shared.icon(forFile: item.fileURL?.path ?? "")
        case .text:
            return NSWorkspace.shared.icon(forFileType: "txt")
        }
    }

    static func detail(for item: ShelfItem) -> String {
        switch item.kind {
        case .text: return "텍스트 \(item.text?.count ?? 0)자"
        case .image, .file:
            let path = item.fileURL?.deletingLastPathComponent().path ?? ""
            return item.ownsFile ? "선반이 보관한 이미지 사본" : path
        }
    }

    @objc private func removeTapped() { onRemove?(item.id) }

    // MARK: dragging out (copy only)

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let writer: NSPasteboardWriting
        switch item.kind {
        case .text:
            guard let text = item.text else { return }
            writer = text as NSString
        case .file, .image:
            guard let url = item.fileURL else { return }
            writer = url as NSURL
        }
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
