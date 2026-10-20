import SwiftUI

/// What one card says, independent of how it's drawn.
struct CardModel {
    enum Headline {
        /// A big number with a dimmed tail, like "7 open".
        case count(Int, suffix: String)
        /// A line of prose, such as a comment.
        case quote(String)
        case text(String)
    }

    enum Accessory {
        case chart([Int])
        case symbol(String)
        case avatar(URL?, fallback: String)
    }

    struct Footnote {
        var icon: String?
        var tint: Color
        var lead: String
        var rest: String = ""
    }

    let id: String
    let caption: String
    let headline: Headline
    let footnote: Footnote
    let accessory: Accessory
}

extension CardModel {
    @MainActor
    static func make(for store: NotchStore) -> CardModel {
        guard let snapshot = store.snapshot else {
            return placeholder(for: store.status)
        }
        switch store.current {
        case .contributions: return contributions(snapshot.contributions)
        case .openPRs: return openPRs(snapshot.openPRs)
        case .reviews: return reviews(snapshot.reviewQueue)
        case .comment: return snapshot.latestComment.map(comment) ?? contributions(snapshot.contributions)
        case .checks: return snapshot.checks.map(checks) ?? openPRs(snapshot.openPRs)
        case .merged: return merged(snapshot.merged)
        }
    }

    private static func contributions(_ c: Snapshot.Contributions) -> CardModel {
        let up = c.thisWeek >= c.lastWeek
        let footnote: Footnote = c.thisWeek == 0 && c.lastWeek == 0
            ? Footnote(icon: nil, tint: Palette.secondary, lead: "Quiet couple of weeks")
            : Footnote(
                icon: up ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                tint: up ? Palette.green : Palette.secondary,
                lead: "\(c.thisWeek) this week",
                rest: " (\(c.lastWeek) the week before)"
            )
        return CardModel(
            id: "contributions",
            caption: "Contributions in the last year",
            headline: .count(c.total, suffix: ""),
            footnote: footnote,
            accessory: .chart(c.weekly)
        )
    }

    private static func openPRs(_ prs: Snapshot.OpenPRs) -> CardModel {
        var footnote = Footnote(icon: nil, tint: Palette.secondary, lead: "Nothing in flight")
        if prs.total > 0 {
            var parts: [String] = []
            if prs.awaitingReview > 0 { parts.append("\(prs.awaitingReview) awaiting review") }
            if prs.changesRequested > 0 { parts.append("\(prs.changesRequested) need changes") }
            if prs.drafts > 0 { parts.append("\(prs.drafts) draft\(prs.drafts == 1 ? "" : "s")") }

            if prs.approved > 0 {
                footnote = Footnote(icon: "checkmark.circle.fill", tint: Palette.green, lead: "\(prs.approved) approved")
            } else if let first = parts.first {
                footnote = Footnote(icon: "ellipsis.circle.fill", tint: Palette.secondary, lead: first)
                parts.removeFirst()
            }
            if !parts.isEmpty { footnote.rest = " · " + parts.joined(separator: " · ") }
        }
        return CardModel(
            id: "openPRs",
            caption: "Your open pull requests",
            headline: .count(prs.total, suffix: " open"),
            footnote: footnote,
            accessory: .symbol("arrow.triangle.pull")
        )
    }

    private static func reviews(_ queue: Snapshot.ReviewQueue) -> CardModel {
        CardModel(
            id: "reviews",
            caption: "Waiting for your review",
            headline: .count(queue.count, suffix: queue.count == 1 ? " pull request" : " pull requests"),
            footnote: Footnote(
                icon: "person.crop.circle.fill",
                tint: Palette.green,
                lead: queue.latestAuthor.map { "@\($0)" } ?? "",
                rest: queue.latest.map { " · \($0.title)" } ?? ""
            ),
            accessory: .avatar(queue.latestAvatar, fallback: "eye")
        )
    }

    private static func comment(_ comment: Snapshot.Comment) -> CardModel {
        CardModel(
            id: "comment",
            caption: "Latest comment on \(comment.pr.label)",
            headline: .quote(comment.text),
            footnote: Footnote(
                icon: "bubble.left.circle.fill",
                tint: Palette.green,
                lead: comment.byViewer ? "You" : "@\(comment.author)",
                rest: " · \(relative(comment.date)) · \(comment.pr.title)"
            ),
            accessory: .avatar(comment.avatar, fallback: "text.bubble")
        )
    }

    private static func checks(_ checks: Snapshot.Checks) -> CardModel {
        let footnote: Footnote
        if let failing = checks.firstFailing {
            footnote = Footnote(
                icon: "xmark.circle.fill", tint: Palette.red,
                lead: "\(checks.failing) failing", rest: " · \(failing.label) \(failing.title)"
            )
        } else if checks.pending > 0 {
            footnote = Footnote(icon: "clock.circle.fill", tint: Palette.amber, lead: "\(checks.pending) running")
        } else {
            footnote = Footnote(icon: "checkmark.circle.fill", tint: Palette.green, lead: "All checks passing")
        }
        return CardModel(
            id: "checks",
            caption: "Checks on your open pull requests",
            headline: .count(checks.passing, suffix: "/\(checks.total) passing"),
            footnote: footnote,
            accessory: .symbol(checks.failing > 0 ? "xmark.seal" : "checkmark.seal")
        )
    }

    private static func merged(_ merged: Snapshot.Merged) -> CardModel {
        CardModel(
            id: "merged",
            caption: "Merged in the last 7 days",
            headline: .count(merged.count, suffix: " merged"),
            footnote: Footnote(
                icon: "checkmark.circle.fill",
                tint: Palette.green,
                lead: merged.latest?.label ?? "",
                rest: merged.latest.map { " \($0.title)" } ?? ""
            ),
            accessory: .symbol("arrow.triangle.merge")
        )
    }

    private static func placeholder(for status: NotchStore.Status) -> CardModel {
        switch status {
        case .loading, .ready:
            return CardModel(
                id: "loading", caption: "GitHub", headline: .text("Fetching…"),
                footnote: Footnote(icon: nil, tint: Palette.secondary, lead: "Asking gh about your pull requests"),
                accessory: .symbol("arrow.triangle.pull")
            )
        case .failed(.ghNotFound):
            return CardModel(
                id: "error", caption: "GitHub CLI not found", headline: .text("Install gh"),
                footnote: Footnote(icon: "exclamationmark.circle.fill", tint: Palette.amber, lead: "brew install gh", rest: ", then gh auth login"),
                accessory: .symbol("exclamationmark.triangle")
            )
        case .failed(.notAuthenticated):
            return CardModel(
                id: "error", caption: "GitHub CLI", headline: .text("Not signed in"),
                footnote: Footnote(icon: "exclamationmark.circle.fill", tint: Palette.amber, lead: "gh auth login", rest: " in a terminal"),
                accessory: .symbol("person.crop.circle.badge.questionmark")
            )
        case .failed(.failed(let message)):
            return CardModel(
                id: "error", caption: "Couldn’t reach GitHub", headline: .text("Retrying soon"),
                footnote: Footnote(icon: "exclamationmark.circle.fill", tint: Palette.red, lead: "", rest: message),
                accessory: .symbol("exclamationmark.triangle")
            )
        }
    }

    static func relative(_ date: Date) -> String {
        let seconds = max(0, Date.now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d ago"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
