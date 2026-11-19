import Foundation

/// A named set of GitHub search qualifiers that applies only in the morning window, such
/// as "Work: -repo:acme/deps -repo:acme/infra".
struct MorningFilter: Equatable, Sendable {
    static let everything = MorningFilter(name: "Everything", query: "")

    let name: String
    let query: String

    /// Parses one "Name: qualifiers" line. The name ends at the first colon followed by a
    /// space, which qualifiers like `repo:acme/web` never have. A line without a name is
    /// named after its qualifiers.
    init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let split = trimmed.range(of: ": ") {
            name = trimmed[..<split.lowerBound].trimmingCharacters(in: .whitespaces)
            query = trimmed[split.upperBound...].trimmingCharacters(in: .whitespaces)
        } else {
            name = trimmed
            query = trimmed
        }
        guard !name.isEmpty, name != Self.everything.name else { return nil }
    }

    init(name: String, query: String) {
        self.name = name
        self.query = query
    }

    var line: String { "\(name): \(query)" }
}

/// The morning window's settings, in the app's `defaults` domain beside the upstream ones.
///
///     defaults write com.rikuws.docknotch morningFilters -array "Work: -repo:acme/deps" "Side: user:me"
///     defaults write com.rikuws.docknotch morningAutoOpen -bool false
///     defaults write com.rikuws.docknotch morningHours "7-11"
///     defaults write com.rikuws.docknotch morningHiddenCalendars -array Birthdays
enum MorningSettings {
    private static var defaults: UserDefaults { .standard }

    /// Saved filters, after the built-in Everything.
    static var filters: [MorningFilter] {
        get { (defaults.stringArray(forKey: "morningFilters") ?? []).compactMap(MorningFilter.init(line:)) }
        set { defaults.set(newValue.map(\.line), forKey: "morningFilters") }
    }

    /// The filter picked last time, by name.
    static var selectedFilter: String? {
        get { defaults.string(forKey: "morningFilter") }
        set { defaults.set(newValue, forKey: "morningFilter") }
    }

    /// Whether the window opens by itself the first time you're at the Mac each morning.
    static var autoOpen: Bool {
        defaults.object(forKey: "morningAutoOpen") as? Bool ?? true
    }

    /// Whether the window has a Today section from the calendar.
    static var calendar: Bool {
        defaults.object(forKey: "morningCalendar") as? Bool ?? true
    }

    /// Calendars to leave out of Today, by name, such as "Birthdays".
    static var hiddenCalendars: [String] {
        defaults.stringArray(forKey: "morningHiddenCalendars") ?? []
    }

    /// Plugins you've allowed to run, by folder name, with the command you allowed. A
    /// plugin whose command changes asks again.
    static var allowedPlugins: [String: String] {
        get { defaults.dictionary(forKey: "allowedPlugins") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "allowedPlugins") }
    }

    /// Whether ⌃⌥M opens and closes the window from any app.
    static var hotKey: Bool {
        defaults.object(forKey: "morningHotKey") as? Bool ?? true
    }

    /// The hours, as "start-end" in 24-hour time, when it may open by itself. Default 6-11.
    static var hours: Range<Int> {
        let parts = (defaults.string(forKey: "morningHours") ?? "")
            .split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, (0...24).contains(parts[0]), (0...24).contains(parts[1]), parts[0] < parts[1] else {
            return 6..<11
        }
        return parts[0]..<parts[1]
    }

    /// The day the window last opened, as yyyy-MM-dd, so it opens by itself once a day.
    static var lastShownDay: String? {
        get { defaults.string(forKey: "morningLastShown") }
        set { defaults.set(newValue, forKey: "morningLastShown") }
    }
}
