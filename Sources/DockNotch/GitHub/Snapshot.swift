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
        struct Day: Equatable, Sendable {
            /// Midnight UTC of the calendar day GitHub counted it on.
            let date: Date
            let count: Int
        }

        let total: Int
        let thisWeek: Int
        let lastWeek: Int
        /// Rolling 7-day totals, oldest first, ending today.
        let weekly: [Int]
        /// The last 14 days, oldest first, ending today.
        let days: [Day]
        /// Days in a row with a contribution, ending today, or yesterday while today is still empty.
        let streak: Int
    }

    /// One of the viewer's open pull requests.
    struct PullRequest: Equatable, Sendable {
        enum Review: Equatable, Sendable { case draft, waiting, approved, changesRequested }
        enum Checks: Equatable, Sendable { case none, passing, pending, failing }

        let ref: PRRef
        let review: Review
        let checks: Checks
        let failingChecks: [String]
        let runningChecks: [String]
        let additions: Int
        let deletions: Int
        let updatedAt: Date
    }

    struct OpenPRs: Equatable, Sendable {
        let total: Int
        let approved: Int
        let changesRequested: Int
        let awaitingReview: Int
        let drafts: Int
        let items: [PullRequest]
    }

    struct ReviewRequest: Equatable, Sendable {
        let ref: PRRef
        let author: String?
        let avatar: URL?
        let openedAt: Date
        let additions: Int
        let deletions: Int
    }

    struct ReviewQueue: Equatable, Sendable {
        let count: Int
        /// Newest activity first.
        let items: [ReviewRequest]

        var latest: PRRef? { items.first?.ref }
        var latestAuthor: String? { items.first?.author }
        var latestAvatar: URL? { items.first?.avatar }
    }

    struct Checks: Equatable, Sendable {
        let passing: Int
        let failing: Int
        let pending: Int
        let firstFailing: PRRef?
        var total: Int { passing + failing + pending }
    }

    struct MergedPR: Equatable, Sendable {
        let ref: PRRef
        let mergedAt: Date?
    }

    struct Merged: Equatable, Sendable {
        let count: Int
        /// Most recently merged first.
        let items: [MergedPR]

        var latest: PRRef? { items.first?.ref }
    }

    struct Comment: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case comment, approved, changesRequested, reviewed }

        /// A review comment left on a line of a file.
        struct Note: Equatable, Sendable {
            let path: String?
            let body: String
        }

        let id: String
        let kind: Kind
        let author: String
        let avatar: URL?
        let byViewer: Bool
        /// One line of plain text, for the card.
        let text: String
        /// The comment's Markdown with HTML and images removed, for reading in full.
        let body: String
        let notes: [Note]
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
    /// Recent comments and reviews on the latest comment's pull request, oldest first.
    let conversation: [Comment]

    var avatarURLs: [URL] {
        var urls = reviewQueue.items.compactMap(\.avatar) + conversation.compactMap(\.avatar)
        if let avatar = latestComment?.avatar { urls.append(avatar) }
        return urls
    }
}

extension Snapshot {
    init(payload: Payload) {
        login = payload.viewer.login
        contributions = Self.contributions(from: payload.viewer.contributionsCollection.contributionCalendar)

        let pullRequests = payload.authored.nodes.map(Self.pullRequest)
        openPRs = Self.openPRs(total: payload.authored.issueCount, items: pullRequests)
        checks = Self.checks(from: pullRequests)

        reviewQueue = ReviewQueue(
            count: payload.reviewRequested.issueCount,
            items: payload.reviewRequested.nodes.map {
                ReviewRequest(
                    ref: PRRef(repo: $0.repository.name, number: $0.number, title: $0.title, url: $0.url),
                    author: $0.author?.login,
                    avatar: $0.author?.avatarUrl,
                    openedAt: $0.createdAt,
                    additions: $0.additions,
                    deletions: $0.deletions
                )
            }
        )

        merged = Merged(
            count: payload.merged.issueCount,
            items: payload.merged.nodes.map {
                MergedPR(
                    ref: PRRef(repo: $0.repository.name, number: $0.number, title: $0.title, url: $0.url),
                    mergedAt: $0.mergedAt
                )
            }
        )

        let comments = Self.comments(in: payload.recent.nodes, viewer: payload.viewer.login)
        let newestFirst = comments.sorted { $0.date > $1.date }
        // Comments from other people win; the viewer's own only show when nobody else has said anything.
        let latest = newestFirst.first(where: { !$0.byViewer }) ?? newestFirst.first
        latestComment = latest
        conversation = latest.map { latest in
            Array(comments.filter { $0.pr.url == latest.pr.url }.sorted { $0.date < $1.date }.suffix(6))
        } ?? []
    }

    private static func contributions(from calendar: ContributionCalendar) -> Contributions {
        let calendarDays = calendar.weeks.flatMap(\.contributionDays)
        let days = calendarDays.map(\.contributionCount)
        var weekly: [Int] = []
        var end = days.count
        while end > 0, weekly.count < 24 {
            let start = max(0, end - 7)
            weekly.insert(days[start..<end].reduce(0, +), at: 0)
            end = start
        }

        let parse = Date.ISO8601FormatStyle().year().month().day()
        let recent = calendarDays.suffix(14).compactMap { day in
            (try? parse.parse(day.date)).map { Contributions.Day(date: $0, count: day.contributionCount) }
        }

        var streak = 0
        for (offset, count) in days.reversed().enumerated() {
            if count > 0 {
                streak += 1
            } else if offset > 0 || streak > 0 {
                break
            }
        }

        return Contributions(
            total: calendar.totalContributions,
            thisWeek: weekly.last ?? 0,
            lastWeek: weekly.dropLast().last ?? 0,
            weekly: weekly,
            days: recent,
            streak: streak
        )
    }

    private static func pullRequest(from pr: AuthoredPR) -> PullRequest {
        let review: PullRequest.Review =
            if pr.isDraft { .draft }
            else if pr.reviewDecision == "APPROVED" { .approved }
            else if pr.reviewDecision == "CHANGES_REQUESTED" { .changesRequested }
            else { .waiting }

        let rollup = pr.commits.nodes.last?.commit.statusCheckRollup
        let checks: PullRequest.Checks = switch rollup?.state {
        case "SUCCESS": .passing
        case "FAILURE", "ERROR": .failing
        case "PENDING", "EXPECTED": .pending
        default: .none
        }

        var failing: [String] = []
        var running: [String] = []
        for context in rollup?.contexts.nodes ?? [] {
            if let name = context.name {
                if context.status != "COMPLETED" {
                    running.append(name)
                } else if ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED"].contains(context.conclusion) {
                    failing.append(name)
                }
            } else if let name = context.context {
                switch context.state {
                case "FAILURE", "ERROR": failing.append(name)
                case "PENDING", "EXPECTED": running.append(name)
                default: break
                }
            }
        }

        return PullRequest(
            ref: PRRef(repo: pr.repository.name, number: pr.number, title: pr.title, url: pr.url),
            review: review,
            checks: checks,
            failingChecks: failing,
            runningChecks: running,
            additions: pr.additions,
            deletions: pr.deletions,
            updatedAt: pr.updatedAt
        )
    }

    private static func openPRs(total: Int, items: [PullRequest]) -> OpenPRs {
        var approved = 0, changes = 0, awaiting = 0, drafts = 0
        for pr in items {
            switch pr.review {
            case .draft: drafts += 1
            case .approved: approved += 1
            case .changesRequested: changes += 1
            case .waiting: awaiting += 1
            }
        }
        return OpenPRs(
            total: total,
            approved: approved,
            changesRequested: changes,
            awaitingReview: awaiting,
            drafts: drafts,
            items: items
        )
    }

    private static func checks(from prs: [PullRequest]) -> Checks? {
        var passing = 0, failing = 0, pending = 0
        var firstFailing: PRRef?
        for pr in prs {
            switch pr.checks {
            case .passing:
                passing += 1
            case .failing:
                failing += 1
                if firstFailing == nil { firstFailing = pr.ref }
            case .pending:
                pending += 1
            case .none:
                break
            }
        }
        guard passing + failing + pending > 0 else { return nil }
        return Checks(passing: passing, failing: failing, pending: pending, firstFailing: firstFailing)
    }

    /// Human comments and submitted reviews on PRs involving the viewer. Bots are left out.
    private static func comments(in prs: [RecentPR], viewer: String) -> [Comment] {
        var comments: [Comment] = []

        for pr in prs {
            let ref = PRRef(repo: pr.repository.name, number: pr.number, title: pr.title, url: pr.url)

            for comment in pr.comments.nodes {
                guard let author = comment.author, !author.isBot else { continue }
                let text = plainText(fromMarkdown: comment.body)
                guard !text.isEmpty else { continue }
                comments.append(Comment(
                    id: comment.id, kind: .comment, author: author.login, avatar: author.avatarUrl,
                    byViewer: author.login == viewer, text: text,
                    body: readableMarkdown(comment.body), notes: [],
                    date: comment.createdAt, url: comment.url, pr: ref
                ))
            }

            for review in pr.reviews.nodes {
                guard let author = review.author, !author.isBot, let date = review.submittedAt else { continue }
                let kind: Comment.Kind = switch review.state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                default: .reviewed
                }
                let notes = review.comments.nodes
                    .map { Comment.Note(path: $0.path, body: readableMarkdown($0.body)) }
                    .filter { !$0.body.isEmpty }

                var text = plainText(fromMarkdown: review.body)
                if text.isEmpty { text = plainText(fromMarkdown: review.comments.nodes.first?.body ?? "") }
                if text.isEmpty {
                    switch kind {
                    case .approved: text = "Approved these changes"
                    case .changesRequested: text = "Requested changes"
                    case .comment, .reviewed: continue
                    }
                }
                comments.append(Comment(
                    id: review.id, kind: kind, author: author.login, avatar: author.avatarUrl,
                    byViewer: author.login == viewer, text: text,
                    body: readableMarkdown(review.body), notes: notes,
                    date: date, url: review.url, pr: ref
                ))
            }
        }
        return comments
    }

    /// Markdown kept for reading: comments, HTML tags and images go, line structure stays.
    static func readableMarkdown(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<img[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            // Only real HTML tags, so generics like `Array<Int>` in code survive.
            .replacingOccurrences(
                of: "</?(details|summary|p|div|span|sub|sup|b|i|em|strong|a|kbd|table|thead|tbody|tr|td|th|h[1-6]|ul|ol|li|picture|source|video|blockquote|hr|code|pre)\\b[^>]*>",
                with: "", options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
