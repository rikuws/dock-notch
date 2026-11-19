import AppKit
import CoreGraphics
import Observation
import SwiftUI

/// The morning window: a larger card in the middle of the screen with what to look at
/// first thing, from every `MorningProvider`. It opens by itself the first time you're at
/// the Mac each morning, and from the right-click menu or `docknotch://morning` any time.
///
/// Keys: ← → (or Tab) switch filters, ↑ ↓ pick a row, ↩ opens it, ⌘R refreshes,
/// ⌘, edits the filters, Esc closes. Clicking anywhere else closes it too.
@MainActor
final class MorningController {
    private let store: NotchStore
    private let providers: [any MorningProvider]
    private let github: GitHubMorning?
    private let panel = SectionPanel()
    private let pointer = DetailPointer()
    private lazy var hostingView = MorningHostingView(pointer: pointer)
    private let measure = NSHostingController(rootView: MorningView.empty)

    private(set) var isOpen = false
    private var selection: String?
    private var keyMonitor: Any?
    private var observation = 0
    private var top: CGFloat?
    private var timer: Timer?
    private var lastRefresh = Date.distantPast
    private lazy var hotKey = MorningHotKey { [weak self] in self?.toggle() }

    init(store: NotchStore) {
        self.store = store
        providers = MorningProviders.make(store: store)
        github = providers.lazy.compactMap { $0 as? GitHubMorning }.first
        github?.filter = Self.filter(named: MorningSettings.selectedFilter)
        panel.contentView = hostingView
        panel.onResignKey = { [weak self] in self?.close() }
    }

    /// Starts watching for the first moment you're at the Mac each morning.
    func start() {
        hotKey.register()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.openIfMorning() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give the login screen a moment to go away.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self?.openIfMorning()
            }
        }
        // Start fetching now, so the first morning opening already has data.
        refresh()
        Task { try? await Task.sleep(for: .seconds(3)); openIfMorning() }
    }

    func show() {
        let opening = !isOpen
        isOpen = true
        MorningSettings.lastShownDay = Self.today
        if opening {
            selection = nil
            // Fresh data on each opening, unless it was fetched a moment ago.
            if Date.now.timeIntervalSince(lastRefresh) > 60 { refresh() }
        }
        render(opening: opening)
        observe()
        if opening { startKeys() }
    }

    func toggle() {
        isOpen ? close() : show()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        selection = nil
        top = nil
        observation += 1
        stopKeys()
        hostingView.stopFollowingPointer()
        pointer.location = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isOpen else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    func refresh() {
        lastRefresh = .now
        for provider in providers {
            Task { await provider.refresh() }
        }
    }

    // MARK: - Opening by itself

    private func openIfMorning() {
        guard MorningSettings.autoOpen, !isOpen, MorningSettings.lastShownDay != Self.today else { return }
        guard MorningSettings.hours.contains(Calendar.current.component(.hour, from: .now)) else { return }
        guard !Self.isScreenLocked, Self.secondsSinceInput < 60 else { return }
        show()
    }

    private static var today: String {
        Date.now.formatted(.iso8601.year().month().day())
    }

    private static var isScreenLocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Seconds since the last key press, click or pointer move, so it only opens when
    /// you're there to see it.
    private static var secondsSinceInput: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: - Filters

    private static func filter(named name: String?) -> MorningFilter {
        MorningSettings.filters.first { $0.name == name } ?? .everything
    }

    private var filterNames: [String] {
        guard github != nil else { return [] }
        let saved = MorningSettings.filters.map(\.name)
        return saved.isEmpty ? [] : [MorningFilter.everything.name] + saved
    }

    private func selectFilter(_ name: String) {
        guard let github else { return }
        let filter = Self.filter(named: name)
        MorningSettings.selectedFilter = filter.name
        selection = nil
        github.filter = filter
        render(opening: false)
    }

    private func switchFilter(_ delta: Int) {
        let names = filterNames
        guard let github, !names.isEmpty else { return }
        let index = names.firstIndex(of: github.filter.name) ?? 0
        selectFilter(names[((index + delta) % names.count + names.count) % names.count])
    }

    /// One line per filter, "Name: qualifiers", in a plain text box.
    private func editFilters() {
        close()
        let alert = NSAlert()
        alert.messageText = "Morning Filters"
        alert.informativeText = """
            One filter per line: a name, a colon and GitHub search qualifiers. They apply only \
            in the morning window. For example:
            Work: -repo:acme/deps -repo:acme/infra
            """
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 140)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.string = MorningSettings.filters.map(\.line).joined(separator: "\n")
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return show() }
        MorningSettings.filters = text.string.components(separatedBy: .newlines).compactMap(MorningFilter.init(line:))
        // Keep the picked filter if it still exists, with its new qualifiers.
        let picked = Self.filter(named: github?.filter.name)
        MorningSettings.selectedFilter = picked.name
        github?.filter = picked
        show()
    }

    // MARK: - Contents

    /// Every provider's sections by their order, keeping each provider's own order for ties.
    private var sections: [MorningSection] {
        providers.flatMap(\.sections).enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element)
    }

    private var rows: [DetailModel.Row] {
        sections.flatMap(\.rows)
    }

    private func makeView() -> MorningView {
        MorningView(
            date: .now,
            filters: filterNames,
            selectedFilter: github?.filter.name ?? "",
            sections: sections,
            isLoading: providers.contains { $0.isLoading },
            selection: selection,
            avatars: store.avatars,
            pointer: pointer,
            selectFilter: { [weak self] name in self?.selectFilter(name) },
            editFilters: { [weak self] in self?.editFilters() },
            open: { [weak self] url in self?.open(url) }
        )
    }

    // MARK: - Window

    private func render(opening: Bool) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let padding = notchShadowPadding
        let maxHeight = min(MorningMetrics.maxHeight, visible.height * 0.84)

        let view = makeView()
        hostingView.rootView = view
        measure.rootView = view
        let fitting = measure.sizeThatFits(in: CGSize(
            width: MorningMetrics.width + padding * 2,
            height: maxHeight + padding * 2
        ))
        let size = CGSize(width: fitting.width.rounded(.up), height: fitting.height.rounded(.up))

        let top = opening || self.top == nil ? visible.maxY - visible.height * 0.08 + padding : self.top!
        self.top = top
        let frame = NSRect(x: visible.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)

        if opening {
            panel.setFrame(frame.offsetBy(dx: 0, dy: -8), display: true)
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private func observe() {
        observation += 1
        let generation = observation
        withObservationTracking {
            _ = makeView()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observation == generation, self.isOpen else { return }
                if let selection = self.selection, !self.rows.contains(where: { $0.id == selection }) {
                    self.selection = nil
                }
                self.render(opening: false)
                self.observe()
            }
        }
    }

    private func open(_ url: URL) {
        // Rows that act inside the window, such as allowing a plugin or the calendar.
        if url.scheme == MorningAction.scheme {
            for provider in providers {
                if let handler = provider as? MorningActionHandler, handler.perform(url) { return }
            }
            return
        }
        NSWorkspace.shared.open(url)
        close()
    }

    // MARK: - Keyboard

    private func startKeys() {
        stopKeys()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.isOpen, event.window === self.panel else { return false }
                return self.handle(event)
            }
            return handled ? nil : event
        }
    }

    private func stopKeys() {
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers {
            case "r": refresh(); return true
            case "w": close(); return true
            case ",": editFilters(); return true
            default: return false
            }
        }
        switch event.keyCode {
        case 53: close() // Esc
        case 123: switchFilter(-1) // ←
        case 124: switchFilter(1) // →
        case 48: switchFilter(modifiers.contains(.shift) ? -1 : 1) // Tab
        case 125: moveSelection(1) // ↓
        case 126: moveSelection(-1) // ↑
        case 36, 76: openSelection() // Return, Enter
        default: return false
        }
        return true
    }

    private func moveSelection(_ delta: Int) {
        let items = rows.filter { $0.url != nil }
        guard !items.isEmpty else { return }
        let index = selection.flatMap { id in items.firstIndex { $0.id == id } }
        let next = index.map { min(max($0 + delta, 0), items.count - 1) } ?? (delta > 0 ? 0 : items.count - 1)
        selection = items[next].id
        render(opening: false)
    }

    private func openSelection() {
        guard let selection, let url = rows.first(where: { $0.id == selection })?.url else { return }
        open(url)
    }
}

// MARK: - Rendering

extension MorningController {
    /// Writes the window with made-up data to `morning.png`, as a check that it still draws.
    static func render(into directory: URL, avatars: AvatarCache) {
        let github = GitHubMorning(avatars: avatars)
        github.load(.sample)
        let calendar = CalendarMorning()
        let hour: TimeInterval = 3_600
        let soon = Date.now.addingTimeInterval(25 * 60)
        calendar.load([
            .init(id: "1", title: "Release day", start: Calendar.current.startOfDay(for: .now), end: .now + 12 * hour,
                  isAllDay: true, location: nil, calendar: "Team", joinURL: nil),
            .init(id: "2", title: "Standup", start: soon, end: soon + 0.25 * hour,
                  isAllDay: false, location: nil, calendar: "Work", joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/x")),
            .init(id: "3", title: "Design review", start: soon + 2 * hour, end: soon + 3 * hour,
                  isAllDay: false, location: "Room 4", calendar: "Work", joinURL: nil),
        ])
        let plugin = PluginMorning.preview(name: "Mail", json: """
            {"sections": [{"title": "Mail", "trailing": "2 unread", "rows": [
              {"symbol": "envelope.badge.fill", "tint": "blue", "title": "Q4 planning notes",
               "lead": "Anna Virtanen", "leadTint": "blue", "detail": "8:12"},
              {"symbol": "bubble.left.and.bubble.right.fill", "tint": "amber", "title": "2 mentions in #release",
               "lead": "Slack", "leadTint": "amber", "detail": "digest, 7:30"}]}]}
            """)
        let sections = (calendar.sections + github.sections + plugin).sorted { $0.order < $1.order }
        let view = MorningView(
            date: .now, filters: ["Everything", "Work", "Side projects"], selectedFilter: "Work",
            sections: sections, isLoading: false, selection: sections.first?.rows.dropFirst().first?.id,
            avatars: avatars, pointer: DetailPointer(), selectFilter: { _ in }, editFilters: {}, open: { _ in }
        )
        .environment(\.notchIsStatic, true)
        .background(LinearGradient(
            colors: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.55, green: 0.35, blue: 0.75)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        let url = directory.appendingPathComponent("morning.png")
        try? png?.write(to: url)
        print(url.path)
    }
}
