import AppKit
import Observation
import SwiftUI

enum CardKind: String, CaseIterable {
    case contributions, openPRs, comment, reviews, checks, merged
}

/// How much a card asks of you, which decides how long it stays up.
enum Attention: Comparable {
    /// Just numbers, like contributions or recent merges: a short look, every other lap.
    case quiet
    case routine
    /// Something waits on you, such as a review request or a failing check.
    case needsYou
}

@MainActor
@Observable
final class NotchStore {
    enum Status: Equatable {
        case loading
        case ready
        case failed(GitHubError)
    }

    private(set) var snapshot: Snapshot?
    private(set) var status: Status = .loading
    private(set) var current: CardKind = .contributions
    /// Bumped whenever the notch jumps to a card because its data changed.
    private(set) var highlight = 0
    /// True while the pointer is on the strip or its popover. Nothing moves meanwhile:
    /// the card stays put and fresh data waits until the pointer leaves.
    private(set) var isHovering = false
    /// Stat tiles currently on screen, decided by the space beside the Dock.
    private(set) var visibleTiles: [TileKind] = []
    /// Bumped per tile when that tile's number changes meaningfully.
    private(set) var tileHighlights: [TileKind: Int] = [:]

    let avatars = AvatarCache()

    @ObservationIgnored private var nextRotation = Date.distantFuture
    /// What each card needed from you when you last had a proper look at it. Once seen,
    /// a card that needs you no longer holds the rotation as long.
    @ObservationIgnored private var seen: [CardKind: String] = [:]
    /// Counts trips round the rotation, so quiet cards can sit out every other one.
    @ObservationIgnored private var lap = 0
    @ObservationIgnored private var heldSnapshot: Snapshot?
    @ObservationIgnored private var client: GitHubClient?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    /// Cards that have something worth showing and aren't already covered by a
    /// visible tile, in rotation order.
    var cards: [CardKind] {
        guard let snapshot else { return [] }
        let covered = Set(visibleTiles.compactMap(\.replacesCard))
        return CardKind.allCases.filter { kind in
            guard !covered.contains(kind) else { return false }
            return switch kind {
            case .contributions, .openPRs: true
            case .comment: snapshot.latestComment != nil
            case .reviews: snapshot.reviewQueue.count > 0
            case .checks: snapshot.checks != nil
            case .merged: snapshot.merged.count > 0
            }
        }
    }

    func start() {
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Settings.refreshInterval))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        })
    }

    /// Fetches fresh data. While the strip is hovered it's held back until the pointer
    /// leaves, unless `immediately`, as for Refresh Now.
    func refresh(immediately: Bool = false) async {
        do {
            let client = try await resolveClient()
            let fresh = try await client.fetchSnapshot(qualifier: Settings.searchQualifier)
            avatars.preload(fresh.avatarURLs)
            if isHovering && snapshot != nil && !immediately {
                heldSnapshot = fresh
            } else {
                apply(fresh)
            }
        } catch {
            // Keep showing stale data rather than replacing it with an error.
            guard snapshot == nil else { return }
            status = .failed(error as? GitHubError ?? .failed(error.localizedDescription))
        }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if !hovering {
            nextRotation = max(nextRotation, .now + Settings.rotationInterval / 2)
            if let held = heldSnapshot {
                heldSnapshot = nil
                apply(held)
            }
        }
    }

    func step(_ delta: Int) {
        let list = cards
        guard !list.isEmpty else { return }
        let index = list.firstIndex(of: current) ?? -delta
        let next = list[((index + delta) % list.count + list.count) % list.count]
        show(next, highlight: false)
    }

    func select(_ kind: CardKind) {
        show(kind, highlight: false)
    }

    /// Notes that you've had a proper look at a card, as when hovering it or opening it
    /// in the larger window, so it stops asking for extra time.
    func markSeen(_ box: StripBox) {
        markSeen(kind(for: box))
    }

    func kind(for box: StripBox) -> CardKind {
        switch box {
        case .card: current
        case .tile(let tile): tile.replacesCard ?? .contributions
        }
    }

    func markSeen(_ kind: CardKind) {
        guard let snapshot else { return }
        seen[kind] = Self.signature(of: kind, in: snapshot)
    }

    /// Whether a card needs you, and if so whether that's news since you last looked.
    func attention(of kind: CardKind) -> (level: Attention, isNew: Bool) {
        guard let snapshot else { return (.routine, false) }
        let level = Self.attention(of: kind, in: snapshot)
        let isNew = level == .needsYou && seen[kind] != Self.signature(of: kind, in: snapshot)
        return (level, isNew)
    }

    func setVisibleTiles(_ tiles: [TileKind]) {
        guard tiles != visibleTiles else { return }
        visibleTiles = tiles
        if snapshot != nil, !cards.contains(current) { step(1) }
    }

    /// Shows a fixed snapshot instead of fetching one (used for rendering previews).
    func load(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        status = .ready
    }

    func openCurrent() {
        open(current)
    }

    func open(_ tile: TileKind) {
        open(tile.replacesCard ?? .contributions)
    }

    private func open(_ kind: CardKind) {
        guard let url = url(for: kind) else { return }
        NSWorkspace.shared.open(url)
    }

    private func url(for kind: CardKind) -> URL? {
        guard let snapshot else {
            return URL(string: "https://cli.github.com")
        }
        switch kind {
        case .contributions: return URL(string: "https://github.com/\(snapshot.login)")
        case .openPRs: return URL(string: "https://github.com/pulls")
        case .reviews: return URL(string: "https://github.com/pulls/review-requested")
        case .comment: return snapshot.latestComment?.url
        case .checks: return snapshot.checks?.firstFailing?.url ?? URL(string: "https://github.com/pulls")
        case .merged: return snapshot.merged.latest?.url
        }
    }

    private func apply(_ fresh: Snapshot) {
        let previous = snapshot
        snapshot = fresh
        status = .ready
        heldSnapshot = nil

        if let previous {
            if let changed = Self.notableChange(from: previous, to: fresh) {
                announce(changed)
            } else if !cards.contains(current) {
                step(1)
            }
        } else {
            show(.contributions, highlight: false)
        }
    }

    /// Draws attention to changed data: the tile that shows it glows, or the card jumps to it.
    private func announce(_ kind: CardKind) {
        if let tile = visibleTiles.first(where: { $0.replacesCard == kind }) {
            tileHighlights[tile, default: 0] += 1
        } else {
            show(kind, highlight: true)
        }
    }

    private func show(_ kind: CardKind, highlight: Bool) {
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) {
            current = kind
        }
        if highlight { self.highlight += 1 }
        // News lingers a little longer than routine rotation.
        nextRotation = .now + max(3, Settings.rotationInterval * max(dwell(for: kind), highlight ? 1.6 : 0))
    }

    /// How long a card stays up, as a share of the rotation interval: twice as long when it
    /// has something new for you, a little longer while it still needs you, less when it's
    /// only numbers.
    private func dwell(for kind: CardKind) -> Double {
        switch attention(of: kind) {
        case (.needsYou, true): 2
        case (.needsYou, false): 1.25
        case (.routine, _): 1
        case (.quiet, _): 0.65
        }
    }

    private func tick() {
        guard !isHovering, cards.count > 1, Date.now >= nextRotation else { return }
        // Staying up for its full time counts as having seen it.
        markSeen(current)
        advance()
    }

    /// The rotation's next card. Quiet cards come round every other lap, unless that
    /// would leave nothing else to show.
    private func advance() {
        let list = cards
        guard let index = list.firstIndex(of: current) else { return step(1) }
        for offset in 1..<list.count {
            let position = index + offset
            let kind = list[position % list.count]
            let nextLap = lap + position / list.count
            if attention(of: kind).level != .quiet || nextLap.isMultiple(of: 2) {
                lap = nextLap
                return show(kind, highlight: false)
            }
        }
        lap += 1
        step(1)
    }

    private static func attention(of kind: CardKind, in snapshot: Snapshot) -> Attention {
        switch kind {
        case .contributions, .merged:
            return .quiet
        case .openPRs:
            return actionable(snapshot.openPRs.items).isEmpty ? .routine : .needsYou
        case .reviews:
            return snapshot.reviewQueue.count > 0 ? .needsYou : .quiet
        case .comment:
            guard let comment = snapshot.latestComment else { return .quiet }
            return !comment.byViewer && Date.now.timeIntervalSince(comment.date) < 86_400 ? .needsYou : .quiet
        case .checks:
            guard let checks = snapshot.checks else { return .quiet }
            if checks.failing > 0 { return .needsYou }
            return checks.pending > 0 ? .routine : .quiet
        }
    }

    /// What a card needs from you, so a change to it reads as news.
    private static func signature(of kind: CardKind, in snapshot: Snapshot) -> String {
        switch kind {
        case .contributions: "\(snapshot.contributions.total)"
        case .openPRs: actionable(snapshot.openPRs.items).joined(separator: " ")
        case .reviews: snapshot.reviewQueue.items.map(\.ref.url.absoluteString).sorted().joined(separator: " ")
        case .comment: snapshot.latestComment?.id ?? ""
        case .checks: snapshot.openPRs.items.filter { $0.checks == .failing }.map(\.ref.url.absoluteString).sorted().joined(separator: " ")
        case .merged: snapshot.merged.items.map(\.ref.url.absoluteString).joined(separator: " ")
        }
    }

    /// Your pull requests waiting on you: failing, sent back with changes, or ready to merge.
    private static func actionable(_ prs: [Snapshot.PullRequest]) -> [String] {
        prs.compactMap { pr in
            guard pr.review != .draft else { return nil }
            let state = switch (pr.checks, pr.review) {
            case (.failing, _): "failing"
            case (_, .changesRequested): "changes"
            case (.passing, .approved), (.none, .approved): "ready"
            default: ""
            }
            return state.isEmpty ? nil : "\(pr.ref.url.absoluteString)=\(state)"
        }.sorted()
    }

    private func resolveClient() async throws -> GitHubClient {
        if let client { return client }
        guard let runner = await Task.detached(operation: { GHRunner.locate() }).value else {
            throw GitHubError.ghNotFound
        }
        let client = GitHubClient(runner: runner)
        self.client = client
        return client
    }

    /// The card that deserves attention after a refresh, if anything meaningful changed.
    private static func notableChange(from old: Snapshot, to new: Snapshot) -> CardKind? {
        if let comment = new.latestComment, !comment.byViewer,
           comment.id != old.latestComment?.id,
           comment.date > old.latestComment?.date ?? .distantPast {
            return .comment
        }
        if new.reviewQueue.count > old.reviewQueue.count { return .reviews }
        if let checks = new.checks, checks.failing > old.checks?.failing ?? 0 { return .checks }
        if new.merged.count > old.merged.count { return .merged }
        if new.openPRs.total != old.openPRs.total { return .openPRs }
        if new.contributions.total > old.contributions.total { return .contributions }
        return nil
    }
}

/// Avatars are fetched once and kept, so rotating back to a card never flashes a placeholder.
@MainActor
@Observable
final class AvatarCache {
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<URL> = []

    func preload(_ urls: [URL]) {
        for url in urls where images[url] == nil && !inFlight.contains(url) {
            inFlight.insert(url)
            Task {
                defer { inFlight.remove(url) }
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                images[url] = image
            }
        }
    }
}
