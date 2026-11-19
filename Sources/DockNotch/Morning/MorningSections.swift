import Foundation
import Observation

/// One block of the morning window: a heading, then rows like a popover's.
struct MorningSection: Identifiable {
    let id: String
    let title: String
    var trailing: String?
    var url: URL?
    var rows: [DetailModel.Row]
    /// Shown instead of rows, such as "Nothing waiting for you" or an error.
    var note: String?
    /// Where it goes in the window, lowest first: the calendar is 10, review requests 20,
    /// your pull requests 30, and plugins 50 unless they say otherwise.
    var order = 50
}

/// Something that fills part of the morning window. Each source of data (GitHub, the
/// calendar, plugins) is one provider, listed in `MorningProviders.make`. Providers are
/// `@Observable`, so the window redraws when their sections change.
@MainActor
protocol MorningProvider: AnyObject {
    var sections: [MorningSection] { get }
    var isLoading: Bool { get }
    func refresh() async
}

@MainActor
enum MorningProviders {
    /// Every provider the window shows.
    static func make(store: NotchStore) -> [any MorningProvider] {
        [
            CalendarMorning(),
            GitHubMorning(avatars: store.avatars),
            PluginMorning(avatars: store.avatars),
        ]
    }
}

/// Pull requests for the morning: what's waiting for your review and your own open ones,
/// fetched with the picked filter on top of the app's own `searchQualifier`, so the filter
/// changes only this window and not the strip.
@MainActor
@Observable
final class GitHubMorning: MorningProvider {
    private(set) var isLoading = false
    var filter = MorningFilter.everything {
        didSet { if filter != oldValue { Task { await refresh() } } }
    }

    /// Fetched snapshots by filter name, so switching back to a filter is instant.
    private var snapshots: [String: Snapshot] = [:]
    private var error: String?
    @ObservationIgnored private let avatars: AvatarCache
    @ObservationIgnored private var runner: GHRunner?

    init(avatars: AvatarCache) {
        self.avatars = avatars
    }

    /// Shows a fixed snapshot instead of fetching one (used for rendering previews).
    func load(_ snapshot: Snapshot) {
        snapshots[filter.name] = snapshot
    }

    func refresh() async {
        let filter = filter
        isLoading = true
        defer { isLoading = false }
        do {
            let runner = try await resolveRunner()
            let qualifier = [Settings.searchQualifier, filter.query].filter { !$0.isEmpty }.joined(separator: " ")
            let fresh = try await GitHubClient(runner: runner).fetchSnapshot(qualifier: qualifier)
            avatars.preload(fresh.avatarURLs)
            snapshots[filter.name] = fresh
            error = nil
        } catch {
            self.error = (error as? GitHubError)?.localizedDescription ?? error.localizedDescription
        }
    }

    var sections: [MorningSection] {
        guard let snapshot = snapshots[filter.name] else {
            let note = error ?? "Fetching from GitHub…"
            return [MorningSection(id: "reviews", title: "Waiting for your review", rows: [], note: note, order: 20)]
        }
        return [
            section(.reviews, in: snapshot, title: "Waiting for your review", empty: "Nothing waiting for your review", order: 20),
            section(.openPRs, in: snapshot, title: "Your pull requests", empty: "No open pull requests", order: 30),
        ]
    }

    private func section(_ kind: CardKind, in snapshot: Snapshot, title: String, empty: String, order: Int) -> MorningSection {
        guard let model = DetailModel.make(for: kind, snapshot: snapshot, rows: 30),
              case .rows(let rows, let more) = model.content else {
            return MorningSection(id: kind.rawValue, title: title, rows: [], note: empty, order: order)
        }
        return MorningSection(
            id: kind.rawValue,
            title: title,
            trailing: model.header.trailing,
            url: model.header.url,
            rows: (rows + (more.map { [$0] } ?? [])).map { $0.prefixed(kind.rawValue) },
            order: order
        )
    }

    private func resolveRunner() async throws -> GHRunner {
        if let runner { return runner }
        guard let found = await Task.detached(operation: { GHRunner.locate() }).value else {
            throw GitHubError.ghNotFound
        }
        runner = found
        return found
    }
}

/// A row that does something in the window instead of opening a page, such as allowing a
/// plugin to run. Its URL is `docknotch-morning://<action>/<argument>`.
enum MorningAction {
    static let scheme = "docknotch-morning"

    static func url(_ action: String, _ argument: String = "") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = action
        components.path = "/" + argument
        return components.url
    }

    /// The action and its argument, from a URL `url(_:_:)` made.
    static func parse(_ url: URL) -> (action: String, argument: String)? {
        guard url.scheme == scheme, let action = url.host(percentEncoded: false) else { return nil }
        return (action, String(url.path(percentEncoded: false).dropFirst()))
    }
}

@MainActor
protocol MorningActionHandler {
    /// Does what a `MorningAction` URL asks, returning false when it isn't this provider's.
    func perform(_ url: URL) -> Bool
}

extension DetailModel.Row {
    /// The same row with an id unique across the window's sections.
    func prefixed(_ prefix: String) -> DetailModel.Row {
        DetailModel.Row(id: "\(prefix):\(id)", leading: leading, title: title, lead: lead, leadTint: leadTint, rest: rest, url: url)
    }
}
