import AppKit
import EventKit
import Observation
import SwiftUI

/// Today's calendar for the morning window: what's left of the day, the next meeting first,
/// from every calendar macOS knows about (Calendar.app's accounts, such as iCloud, Google or
/// Exchange). Nothing asks for calendar access until you click the row that offers it.
@MainActor
@Observable
final class CalendarMorning: MorningProvider, MorningActionHandler {
    private(set) var isLoading = false
    private var events: [Event] = []
    private var status = EKEventStore.authorizationStatus(for: .event)

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observer: Any?

    struct Event: Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let calendar: String
        let joinURL: URL?
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }

    /// Shows fixed events instead of reading the calendar (used for rendering previews).
    func load(_ events: [Event]) {
        status = .fullAccess
        self.events = events
    }

    func refresh() async {
        status = EKEventStore.authorizationStatus(for: .event)
        guard MorningSettings.calendar, status == .fullAccess else { return }
        let now = Date.now
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let hidden = Set(MorningSettings.hiddenCalendars)
        let calendars = store.calendars(for: .event).filter { !hidden.contains($0.title) }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled && !Self.declined($0) }
            .map { event in
                Event(
                    id: event.calendarItemIdentifier + "@\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Busy",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
                    calendar: event.calendar.title,
                    joinURL: Self.joinURL(event)
                )
            }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    func perform(_ url: URL) -> Bool {
        guard let (action, _) = MorningAction.parse(url) else { return false }
        switch action {
        case "allow-calendar":
            Task {
                _ = try? await store.requestFullAccessToEvents()
                await refresh()
            }
        case "calendar-settings":
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
        default:
            return false
        }
        return true
    }

    var sections: [MorningSection] {
        guard MorningSettings.calendar else { return [] }
        let title = "Today"
        let calendarApp = URL(fileURLWithPath: "/System/Applications/Calendar.app")
        switch status {
        case .fullAccess:
            break
        case .notDetermined:
            let row = DetailModel.Row(
                id: "calendar:allow", leading: .symbol("calendar.badge.plus", Palette.green),
                title: "Show today's meetings here", lead: "Allow calendar access", leadTint: Palette.green,
                rest: " · read from Calendar's accounts, nothing leaves your Mac",
                url: MorningAction.url("allow-calendar")
            )
            return [MorningSection(id: "calendar", title: title, rows: [row], order: 10)]
        default:
            let row = DetailModel.Row(
                id: "calendar:settings", leading: .symbol("calendar.badge.exclamationmark", Palette.amber),
                title: "Calendar access is off", lead: "Open Privacy settings", leadTint: Palette.amber,
                rest: " · turn on Dock Notch under Calendars",
                url: MorningAction.url("calendar-settings")
            )
            return [MorningSection(id: "calendar", title: title, rows: [row], order: 10)]
        }

        let now = Date.now
        let left = events.filter { $0.isAllDay || $0.end > now }
        let done = events.count - left.count
        guard !left.isEmpty else {
            let note = events.isEmpty ? "Nothing on the calendar today" : "That's all for today"
            return [MorningSection(id: "calendar", title: title, url: calendarApp, rows: [], note: note, order: 10)]
        }
        let next = left.first { !$0.isAllDay }
        let rows = left.map { row(for: $0, isNext: $0 == next, now: now) }
        let timed = left.filter { !$0.isAllDay }.count
        let trailing = timed == 0 ? nil : done > 0 ? "\(timed) left, \(done) done" : "\(timed)"
        return [MorningSection(id: "calendar", title: title, trailing: trailing, url: calendarApp, rows: rows, order: 10)]
    }

    private func row(for event: Event, isNext: Bool, now: Date) -> DetailModel.Row {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let ongoing = !event.isAllDay && event.start <= now
        let lead: String
        let tint: Color
        if event.isAllDay {
            lead = "All day"
            tint = Palette.secondary
        } else if ongoing {
            lead = "Now, until \(event.end.formatted(time))"
            tint = Palette.green
        } else if isNext, event.start.timeIntervalSince(now) < 3_600 {
            let minutes = max(1, Int(event.start.timeIntervalSince(now) / 60))
            lead = "In \(minutes) min, \(event.start.formatted(time))"
            tint = Palette.amber
        } else {
            lead = "\(event.start.formatted(time))–\(event.end.formatted(time))"
            tint = isNext ? Palette.primary : Palette.secondary
        }
        var rest: [String] = []
        if event.joinURL != nil { rest.append("Join online") } else if let location = event.location { rest.append(location) }
        rest.append(event.calendar)

        let symbol = event.isAllDay ? "sun.max" : event.joinURL != nil ? "video.fill" : "calendar"
        let symbolTint = ongoing ? Palette.green : isNext ? Palette.primary : Palette.tertiary
        return DetailModel.Row(
            id: "calendar:\(event.id)",
            leading: .symbol(symbol, symbolTint),
            title: event.title,
            lead: lead,
            leadTint: tint,
            rest: " · " + rest.joined(separator: " · "),
            url: event.joinURL ?? URL(string: "ical://")
        )
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// A Teams, Zoom, Meet or Webex link from the event's URL, location or notes.
    private static func joinURL(_ event: EKEvent) -> URL? {
        let hosts = ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com"]
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let host = url.host()?.lowercased() else { continue }
                if hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
