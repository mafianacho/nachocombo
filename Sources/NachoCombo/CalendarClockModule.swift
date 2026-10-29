import AppKit
import EventKit
import NachoComboCore

/// A menu bar clock written the way the user likes, with a month calendar, the day's events, a Join button for the next
/// video call and world clocks one click away. Events are read on this Mac through EventKit, only once the user allowed
/// Calendars; the clock and the world clocks need nothing.
final class CalendarClockModule: NSObject, FeatureModule, NSPopoverDelegate {
    let id = ModuleID.calendarClock
    var optionsProvider: () -> GadgetOptions = { .defaults }
    var onChange: (() -> Void)?
    var openSettings: (() -> Void)?

    let store = EKEventStore()
    private var item: NSStatusItem?
    private var timer: Timer?
    private var formatter = DateFormatter()
    private var formatKey = ""
    private var lastTitle = ""
    private var observers: [NSObjectProtocol] = []
    private var popover: NSPopover?
    private var lastLoad = Date.distantPast
    private(set) var upcoming: [EKEvent] = []
    private(set) var running = false

    /// true: allowed, false: refused or limited to adding events, nil: not asked yet.
    static var access: Bool? {
        switch EKEventStore.authorizationStatus(for: .event).rawValue {
        case 0: return nil
        case 3: return true          // authorized (fullAccess from macOS 14)
        default: return false
        }
    }

    func start() -> ModuleState {
        guard !running else { return .running }
        running = true
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.setAccessibilityLabel("Calendar Clock")
        self.item = item
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.loadEvents(force: true)
        })
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.formatKey = ""
                self?.loadEvents(force: true)
                self?.tick()
            })
        }
        // One tick a second; the title only changes when its text does.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        loadEvents(force: true)
        tick()
        return .running
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        popover?.close()
        popover = nil
        if let item = item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        upcoming = []
        formatKey = ""
        lastTitle = ""
        running = false
    }

    func applyOptions() {
        formatKey = ""
        loadEvents(force: true)
        tick()
    }

    // MARK: clock

    private func tick() {
        guard running, let button = item?.button else { return }
        let options = optionsProvider()
        let key = "\(options.clockDate)\(options.clockWeekday)\(options.clockSeconds)\(options.clockHours.rawValue)"
        if key != formatKey {
            formatKey = key
            formatter = DateFormatter()
            formatter.locale = Locale.current
            let template = ClockFormat.template(date: options.clockDate, weekday: options.clockWeekday,
                                                seconds: options.clockSeconds, hours: options.clockHours)
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: Locale.current)
        }
        if Date().timeIntervalSince(lastLoad) > 300 { loadEvents(force: false) }
        var title = formatter.string(from: Date())
        if options.clockNextEvent, let next = nextMeeting(within: 15 * 60),
           let countdown = ClockFormat.countdown(to: next.event.startDate, now: Date()) {
            let name = next.event.title ?? "Event"
            title += "  ·  " + (name.count > 18 ? String(name.prefix(17)) + "…" : name) + " " + countdown
        }
        guard title != lastTitle else { return }
        lastTitle = title
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        button.setAccessibilityValue(title)
    }

    var clockText: String { lastTitle }

    // MARK: events

    func loadEvents(force: Bool) {
        guard running, CalendarClockModule.access == true else { upcoming = []; return }
        guard force || Date().timeIntervalSince(lastLoad) > 60 else { return }
        lastLoad = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(2 * 86_400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        upcoming = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        lastTitle = ""
        onChange?()
    }

    /// The next timed event that has not ended, starting within `seconds` (or started up to 5 minutes ago), and its
    /// video call link.
    func nextMeeting(within seconds: TimeInterval = 12 * 3600) -> (event: EKEvent, link: URL?)? {
        let now = Date()
        guard let event = upcoming.first(where: { !$0.isAllDay && $0.endDate > now
            && $0.startDate.timeIntervalSince(now) <= seconds && $0.startDate.timeIntervalSince(now) > -5 * 60 }) else { return nil }
        return (event, CalendarClockModule.link(of: event))
    }

    static func link(of event: EKEvent) -> URL? {
        MeetingLinks.detect(in: [event.url?.absoluteString, event.location, event.notes])
    }

    func events(on day: Date) -> [EKEvent] {
        guard CalendarClockModule.access == true else { return [] }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
    }

    /// Days of the month (1…31) that have at least one event.
    func busyDays(inMonthOf day: Date) -> Set<Int> {
        guard CalendarClockModule.access == true,
              let month = Calendar.current.dateInterval(of: .month, for: day) else { return [] }
        let events = store.events(matching: store.predicateForEvents(withStart: month.start, end: month.end, calendars: nil))
        var days = Set<Int>()
        for event in events {
            var date = max(event.startDate, month.start)
            while date < min(event.endDate, month.end) {
                days.insert(Calendar.current.component(.day, from: date))
                guard let next = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))
                else { break }
                date = next
            }
            if event.startDate == event.endDate { days.insert(Calendar.current.component(.day, from: event.startDate)) }
        }
        return days
    }

    func requestAccess(_ done: @escaping () -> Void) {
        let finish: (Bool, Error?) -> Void = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.loadEvents(force: true)
                done()
            }
        }
        // Built against an SDK before macOS 14, this asks for full access on every macOS version.
        store.requestAccess(to: .event, completion: finish)
    }

    func join(_ url: URL) {
        popover?.close()
        NSWorkspace.shared.open(url)
    }

    func joinNext() {
        if let link = nextMeeting()?.link { join(link) } else { Toast.show("No video call coming up", near: NSEvent.mouseLocation) }
    }

    // MARK: popover

    @objc private func clicked() { togglePopover() }

    var popoverShown: Bool { popover?.isShown ?? false }

    func togglePopover() {
        guard running, let button = item?.button else { return }
        if let popover = popover, popover.isShown { popover.close(); return }
        loadEvents(force: true)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !UI.reduceMotion
        popover.delegate = self
        let controller = NSViewController()
        let view = CalendarPopoverView(module: self)
        view.onResize = { [weak popover] size in popover?.contentSize = size }
        controller.view = view
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        onChange?()
    }

    func closePopover() { popover?.close() }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        onChange?()
    }

    var diagnostics: [String: String] {
        [
            "running": "\(running)",
            "statusItem": "\(item != nil)",
            "title": lastTitle,
            "access": CalendarClockModule.access.map { "\($0)" } ?? "notAsked",
            "upcoming": "\(upcoming.count)",
            "nextMeeting": nextMeeting().map { "\($0.event.title ?? "-") link=\($0.link != nil)" } ?? "-",
            "popover": "\(popoverShown)",
        ]
    }
}

// MARK: - The calendar under the clock

final class CalendarPopoverView: NSView {
    private weak var module: CalendarClockModule?
    private var month: Date
    private var selected: Date
    private let stack = UI.vstack([], spacing: 10)
    static let width: CGFloat = 300
    var onResize: ((NSSize) -> Void)?

    init(module: CalendarClockModule) {
        self.module = module
        let today = Calendar.current.startOfDay(for: Date())
        month = today
        selected = today
        super.init(frame: NSRect(x: 0, y: 0, width: CalendarPopoverView.width, height: 400))
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: CalendarPopoverView.width),
        ])
        render()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private var inner: CGFloat { CalendarPopoverView.width - 28 }

    private func render() {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        guard let module = module else { return }
        let calendar = Calendar.current
        let options = module.optionsProvider()

        // Month header.
        let title = DateFormatter()
        title.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        let monthLabel = UI.label(title.string(from: month), style: .headline, weight: .bold)
        let back = navButton("chevron.left", "Previous month") { [weak self] in self?.shiftMonth(-1) }
        let today = UI.pushButton("Today", small: true) { [weak self] in
            self?.month = Date()
            self?.selected = calendar.startOfDay(for: Date())
            self?.render()
        }
        let forward = navButton("chevron.right", "Next month") { [weak self] in self?.shiftMonth(1) }
        let header = UI.hstack([monthLabel, UI.spacer(), back, today, forward], spacing: 4)
        header.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(monthGrid(busy: module.busyDays(inMonthOf: month)))

        // The chosen day.
        let dayTitle = DateFormatter()
        dayTitle.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        stack.addArrangedSubview(UI.label(dayTitle.string(from: selected), style: .callout, weight: .semibold))
        switch CalendarClockModule.access {
        case true?:
            let events = module.events(on: selected)
            if events.isEmpty {
                stack.addArrangedSubview(UI.label("No events", style: .subheadline, color: UI.secondaryText))
            }
            for event in events.prefix(6) { stack.addArrangedSubview(eventRow(event)) }
            if events.count > 6 {
                stack.addArrangedSubview(UI.label("\(events.count - 6) more in Calendar", style: .caption1, color: UI.secondaryText))
            }
        case nil:
            stack.addArrangedSubview(UI.wrapLabel("Allow Calendars to see your events and join video calls from here.",
                                                  width: inner, style: .subheadline))
            stack.addArrangedSubview(UI.pushButton("Allow Calendars…", primary: true, small: true) { [weak self] in
                module.requestAccess { self?.render() }
            })
        case false?:
            stack.addArrangedSubview(UI.wrapLabel("Calendars is not allowed for Nacho Combo, so events do not show here.",
                                                  width: inner, style: .subheadline))
            stack.addArrangedSubview(UI.pushButton("Open Settings", small: true) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            })
        }

        // World clocks.
        if !options.worldClocks.isEmpty {
            stack.addArrangedSubview(UI.separator(width: inner))
            let time = DateFormatter()
            time.setLocalizedDateFormatFromTemplate(options.clockHours == .twentyFour ? "EEEHHmm"
                                                    : (options.clockHours == .twelve ? "EEEhmma" : "EEEjmm"))
            for identifier in options.worldClocks {
                guard let zone = TimeZone(identifier: identifier) else { continue }
                time.timeZone = zone
                let city = UI.label(WorldClock.city(identifier), style: .callout)
                let offset = UI.label(WorldClock.offset(zone, from: .current, at: Date()), style: .caption1, color: UI.secondaryText)
                let clock = UI.label(time.string(from: Date()), style: .callout, weight: .medium)
                clock.font = UI.digitsFont(.callout)
                let line = UI.hstack([city, offset, UI.spacer(), clock], spacing: 6)
                line.widthAnchor.constraint(equalToConstant: inner).isActive = true
                stack.addArrangedSubview(line)
            }
        }

        stack.addArrangedSubview(UI.separator(width: inner))
        let open = UI.pushButton("Open Calendar", small: true) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            module.closePopover()
        }
        let settings = UI.pushButton("Clock Settings…", small: true) {
            module.closePopover()
            module.openSettings?()
        }
        let footer = UI.hstack([open, UI.spacer(), settings], spacing: 8)
        footer.widthAnchor.constraint(equalToConstant: inner).isActive = true
        stack.addArrangedSubview(footer)
        layoutSubtreeIfNeeded()
        let size = NSSize(width: CalendarPopoverView.width, height: stack.fittingSize.height)
        setFrameSize(size)
        onResize?(size)
    }

    private func shiftMonth(_ step: Int) {
        month = Calendar.current.date(byAdding: .month, value: step, to: month) ?? month
        render()
    }

    private func navButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: "", handler: action)
        button.image = UI.symbol(symbol, size: 12, weight: .semibold)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.setAccessibilityLabel(label)
        return button
    }

    private func monthGrid(busy: Set<Int>) -> NSView {
        let calendar = Calendar.current
        let cell = inner / 7
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let days = calendar.range(of: .day, in: .month, for: month) else { return NSView() }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        let rows = Int(ceil(Double(leading + days.count) / 7))
        let grid = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: inner).isActive = true
        grid.heightAnchor.constraint(equalToConstant: CGFloat(rows + 1) * 30).isActive = true
        let total = CGFloat(rows + 1) * 30
        for (column, symbol) in ordered.enumerated() {
            let label = UI.label(symbol, style: .caption1, weight: .semibold, color: UI.secondaryText)
            label.alignment = .center
            label.frame = NSRect(x: CGFloat(column) * cell, y: total - 24, width: cell, height: 18)
            label.translatesAutoresizingMaskIntoConstraints = true
            grid.addSubview(label)
        }
        let today = calendar.startOfDay(for: Date())
        for day in days {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) else { continue }
            let position = leading + day - 1
            let row = position / 7, column = position % 7
            let button = DayCell(day: day, today: date == today, selected: date == selected, busy: busy.contains(day))
            button.frame = NSRect(x: CGFloat(column) * cell, y: total - 30 - CGFloat(row + 1) * 30 + 2, width: cell, height: 28)
            button.onPick = { [weak self] in
                self?.selected = date
                self?.render()
            }
            grid.addSubview(button)
        }
        return grid
    }

    private func eventRow(_ event: EKEvent) -> NSView {
        let color = NSView()
        color.wantsLayer = true
        color.layer?.backgroundColor = (event.calendar?.color ?? .controlAccentColor).cgColor
        color.layer?.cornerRadius = 2
        color.translatesAutoresizingMaskIntoConstraints = false
        color.widthAnchor.constraint(equalToConstant: 4).isActive = true
        color.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let time: String
        if event.isAllDay {
            time = "All day"
        } else {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            time = formatter.string(from: event.startDate) + " – " + formatter.string(from: event.endDate)
        }
        let title = UI.label(event.title ?? "Event", style: .callout, weight: .medium)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detail = UI.label(time, style: .caption1, color: UI.secondaryText)
        var views: [NSView] = [color, UI.vstack([title, detail], spacing: 1), UI.spacer()]
        if let link = CalendarClockModule.link(of: event), event.endDate > Date() {
            let join = UI.pushButton("Join", primary: true, small: true) { [weak self] in self?.module?.join(link) }
            join.setAccessibilityLabel("Join \(event.title ?? "the call")")
            views.append(join)
        }
        let line = UI.hstack(views, spacing: 8)
        line.widthAnchor.constraint(equalToConstant: inner).isActive = true
        return line
    }
}

final class DayCell: NSView {
    private let day: Int
    private let today: Bool
    private let selected: Bool
    private let busy: Bool
    var onPick: (() -> Void)?

    init(day: Int, today: Bool, selected: Bool, busy: Bool) {
        self.day = day
        self.today = today
        self.selected = selected
        self.busy = busy
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(day)" + (today ? ", today" : "") + (busy ? ", has events" : ""))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: bounds.midX - 12, y: bounds.midY - 11, width: 24, height: 24)
        var ink = NSColor.labelColor
        if today {
            Brand.nacho.setFill()
            NSBezierPath(ovalIn: circle).fill()
            ink = Brand.onNacho
        } else if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: today ? .bold : .regular)
        let text = "\(day)" as NSString
        let size = text.size(withAttributes: [.font: font])
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: circle.midY - size.height / 2),
                  withAttributes: [.font: font, .foregroundColor: ink])
        if busy {
            (today ? Brand.onNacho : NSColor.secondaryLabelColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: circle.minY + 2, width: 3, height: 3)).fill()
        }
    }

    override func mouseUp(with event: NSEvent) { onPick?() }
    override func accessibilityPerformPress() -> Bool { onPick?(); return true }
}
