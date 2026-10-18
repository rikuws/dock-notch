import Foundation

/// Everything the notch can show, distilled from one GraphQL response.
struct Snapshot: Equatable, Sendable {
    struct PRRef: Equatable, Sendable {
        let repo: String
        let number: Int
        let title: String
        let url: URL
        var label: String { "\(repo)#\(number)" }
    }

    struct Contributions: Equatable, Sendable {
        let total: Int
        let thisWeek: Int
        let lastWeek: Int
        /// Rolling 7-day totals, oldest first, ending today.
        let weekly: [Int]
    }

    struct OpenPRs: Equatable, Sendable {
        let total: Int
        let approved: Int
        let changesRequested: Int
        let awaitingReview: Int
        let drafts: Int
    }

    struct ReviewQueue: Equatable, Sendable {
        let count: Int
        let latest: PRRef?
        let latestAuthor: String?
        let latestAvatar: URL?
    }

    struct Checks: Equatable, Sendable {
        let passing: Int
        let failing: Int
        let pending: Int
        let firstFailing: PRRef?
        var total: Int { passing + failing + pending }
    }

    struct Merged: Equatable, Sendable {
        let count: Int
        let latest: PRRef?
    }

    struct Comment: Equatable, Sendable {
        let id: String
        let author: String
        let avatar: URL?
        let byViewer: Bool
        let text: String
        let date: Date
        let url: URL
        let pr: PRRef
    }

    let login: String
    let contributions: Contributions
    let openPRs: OpenPRs
    let reviewQueue: ReviewQueue
    let checks: Checks?
    let merged: Merged
    let latestComment: Comment?

    var avatarURLs: [URL] {
        [reviewQueue.latestAvatar, latestComment?.avatar].compactMap { $0 }
    }
}

extension Snapshot {
    init(payload: Payload) {
        login = payload.viewer.login
        contributions = Self.contributions(from: payload.viewer.contributionsCollection.contributionCalendar)
        openPRs = Self.openPRs(from: payload.authored)
        checks = Self.checks(from: payload.authored.nodes)

        let requested = payload.reviewRequested.nodes.first
        reviewQueue = ReviewQueue(
            count: payload.reviewRequested.issueCount,
            latest: requested.map { PRRef(repo: $0.repository.name, number: $0.number, title: $0.title, url: $0.url) },
            latestAuthor: requested?.author?.login,
            latestAvatar: requested?.author?.avatarUrl
        )

        merged = Merged(
            count: payload.merged.issueCount,
            latest: payload.merged.nodes.first.map {
                PRRef(repo: $0.repository.name, number: $0.number, title: $0.title, url: $0.url)
            }
        )

        latestComment = Self.latestComment(in: payload.recent.nodes, viewer: payload.viewer.login)
    }

    private static func contributions(from calendar: ContributionCalendar) -> Contributions {
        let days = calendar.weeks.flatMap(\.contributionDays).map(\.contributionCount)
        var weekly: [Int] = []
        var end = days.count
        while end > 0, weekly.count < 24 {
            let start = max(0, end - 7)
            weekly.insert(days[start..<end].reduce(0, +), at: 0)
            end = start
        }
        return Contributions(
            total: calendar.totalContributions,
            thisWeek: weekly.last ?? 0,
            lastWeek: weekly.dropLast().last ?? 0,
            weekly: weekly
        )
    }

    private static func openPRs(from search: Search<AuthoredPR>) -> OpenPRs {
        var approved = 0, changes = 0, awaiting = 0, drafts = 0
        for pr in search.nodes {
            if pr.isDraft {
                drafts += 1
                continue
            }
            switch pr.reviewDecision {
            case "APPROVED": approved += 1
            case "CHANGES_REQUESTED": changes += 1
            default: awaiting += 1
            }
        }
        return OpenPRs(
            total: search.issueCount,
            approved: approved,
            changesRequested: changes,
            awaitingReview: awaiting,
            drafts: drafts
        )
    }

    private static func checks(from prs: [AuthoredPR]) -> Checks? {
        var passing = 0, failing = 0, pending = 0
        var firstFailing: PRRef?
        for pr in prs {
            switch pr.commits.nodes.last?.commit.statusCheckRollup?.state {
            case "SUCCESS":
                passing += 1
            case "FAILURE", "ERROR":
                failing += 1
                if firstFailing == nil {
                    firstFailing = PRRef(repo: pr.repository.name, number: pr.number, title: pr.title, url: pr.url)
                }
            case "PENDING", "EXPECTED":
                pending += 1
            default:
                break
            }
        }
        guard passing + failing + pending > 0 else { return nil }
        return Checks(passing: passing, failing: failing, pending: pending, firstFailing: firstFailing)
    }

    /// The newest human comment or review on PRs involving the viewer. Comments from
    /// other people win; the viewer's own only show when nobody else has said anything.
    private static func latestComment(in prs: [RecentPR], viewer: String) -> Comment? {
        var candidates: [Comment] = []

        for pr in prs {
            let ref = PRRef(repo: pr.repository.name, number: pr.number, title: pr.title, url: pr.url)

            for comment in pr.comments.nodes {
                guard let author = comment.author, !author.isBot else { continue }
                let text = plainText(fromMarkdown: comment.body)
                guard !text.isEmpty else { continue }
                candidates.append(Comment(
                    id: comment.id, author: author.login, avatar: author.avatarUrl,
                    byViewer: author.login == viewer, text: text,
                    date: comment.createdAt, url: comment.url, pr: ref
                ))
            }

            for review in pr.reviews.nodes {
                guard let author = review.author, !author.isBot, let date = review.submittedAt else { continue }
                var text = plainText(fromMarkdown: review.body)
                if text.isEmpty { text = plainText(fromMarkdown: review.comments.nodes.first?.body ?? "") }
                if text.isEmpty {
                    switch review.state {
                    case "APPROVED": text = "Approved these changes"
                    case "CHANGES_REQUESTED": text = "Requested changes"
                    default: continue
                    }
                }
                candidates.append(Comment(
                    id: review.id, author: author.login, avatar: author.avatarUrl,
                    byViewer: author.login == viewer, text: text,
                    date: date, url: review.url, pr: ref
                ))
            }
        }

        let newestFirst = candidates.sorted { $0.date > $1.date }
        return newestFirst.first(where: { !$0.byViewer }) ?? newestFirst.first
    }

    static func plainText(fromMarkdown markdown: String) -> String {
        var text = markdown
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^\\s*(#{1,6}|>|[-*+]|\\d+\\.)\\s+", with: "", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            text = String(attributed.characters)
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
