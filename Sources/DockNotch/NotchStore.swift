import AppKit
import Observation
import SwiftUI

enum CardKind: String, CaseIterable {
    case contributions, openPRs, comment, reviews, checks, merged
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
    private(set) var isHovering = false
    var pillSize = CGSize(width: 420, height: 70)

    let avatars = AvatarCache()

    @ObservationIgnored private var nextRotation = Date.distantFuture
    @ObservationIgnored private var client: GitHubClient?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    /// Cards that have something worth showing, in rotation order.
    var cards: [CardKind] {
        guard let snapshot else { return [] }
        return CardKind.allCases.filter { kind in
            switch kind {
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

    func refresh() async {
        do {
            let client = try await resolveClient()
            let fresh = try await client.fetchSnapshot(qualifier: Settings.searchQualifier)
            let previous = snapshot
            snapshot = fresh
            status = .ready
            avatars.preload(fresh.avatarURLs)

            if let previous {
                if let changed = Self.notableChange(from: previous, to: fresh) {
                    show(changed, highlight: true)
                } else if !cards.contains(current) {
                    step(1)
                }
            } else {
                show(.contributions, highlight: false)
            }
        } catch {
            // Keep showing stale data rather than replacing it with an error.
            guard snapshot == nil else { return }
            status = .failed(error as? GitHubError ?? .failed(error.localizedDescription))
        }
    }

    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if !hovering {
            nextRotation = max(nextRotation, .now + Settings.rotationInterval / 2)
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

    /// Shows a fixed snapshot instead of fetching one (used for rendering previews).
    func load(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        status = .ready
    }

    func openCurrent() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    private var currentURL: URL? {
        guard let snapshot else {
            return URL(string: "https://cli.github.com")
        }
        switch current {
        case .contributions: return URL(string: "https://github.com/\(snapshot.login)")
        case .openPRs: return URL(string: "https://github.com/pulls")
        case .reviews: return URL(string: "https://github.com/pulls/review-requested")
        case .comment: return snapshot.latestComment?.url
        case .checks: return snapshot.checks?.firstFailing?.url ?? URL(string: "https://github.com/pulls")
        case .merged: return snapshot.merged.latest?.url
        }
    }

    private func show(_ kind: CardKind, highlight: Bool) {
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) {
            current = kind
        }
        if highlight { self.highlight += 1 }
        // News lingers a little longer than routine rotation.
        nextRotation = .now + Settings.rotationInterval * (highlight ? 1.6 : 1)
    }

    private func tick() {
        guard !isHovering, cards.count > 1, Date.now >= nextRotation else { return }
        step(1)
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
