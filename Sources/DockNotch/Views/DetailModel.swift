import SwiftUI

/// What the popover above a box says: the detail behind the box's number, shaped by
/// what's there. Nil when the box has nothing more to tell.
struct DetailModel {
    struct Header {
        var caption: String?
        let title: String
        var trailing: String?
        var url: URL?
    }

    struct Row: Identifiable {
        enum Leading {
            case symbol(String, Color)
            case avatar(URL?, fallback: String)
        }

        let id: String
        let leading: Leading
        let title: String
        let lead: String
        let leadTint: Color
        var rest: String = ""
        let url: URL?
    }

    struct Entry: Identifiable {
        let id: String
        let author: String
        let avatar: URL?
        let verdict: (text: String, tint: Color)?
        let when: String
        let blocks: [TextBlock]
        let notes: [(path: String?, blocks: [TextBlock])]
        let url: URL
        let isLatest: Bool
    }

    struct Activity {
        let days: [Snapshot.Contributions.Day]
        let thisWeek: Int
        let lastWeek: Int
        let streak: Int
    }

    enum Content {
        case rows([Row], more: Row?)
        case conversation([Entry])
        case activity(Activity)
    }

    let id: String
    let header: Header
    let content: Content
}

extension DetailModel {
    @MainActor
    static func make(for box: StripBox, store: NotchStore) -> DetailModel? {
        guard let snapshot = store.snapshot else { return nil }
        let kind: CardKind = switch box {
        case .card: store.current
        case .tile(let tile): tile.replacesCard ?? .contributions
        }
        switch kind {
        case .contributions: return activity(snapshot.contributions, login: snapshot.login)
        case .openPRs: return openPRs(snapshot.openPRs)
        case .comment: return conversation(snapshot)
        case .reviews: return reviews(snapshot.reviewQueue)
        case .checks: return checks(snapshot.openPRs.items)
        case .merged: return merged(snapshot.merged)
        }
    }

    // MARK: - Kinds

    private static func conversation(_ snapshot: Snapshot) -> DetailModel? {
        guard let latest = snapshot.latestComment, !snapshot.conversation.isEmpty else { return nil }
        let entries = snapshot.conversation.map { comment in
            let verdict: (text: String, tint: Color)? = switch comment.kind {
            case .approved: ("Approved", Palette.green)
            case .changesRequested: ("Requested changes", Palette.amber)
            case .reviewed where comment.body.isEmpty && !comment.notes.isEmpty: ("Reviewed", Palette.secondary)
            case .comment, .reviewed: nil
            }
            return Entry(
                id: comment.id,
                author: comment.byViewer ? "You" : "@\(comment.author)",
                avatar: comment.avatar,
                verdict: verdict,
                when: relative(comment.date),
                blocks: TextBlock.parse(comment.body),
                notes: comment.notes.map { ($0.path, TextBlock.parse($0.body, limit: 700)) },
                url: comment.url,
                isLatest: comment.id == latest.id
            )
        }
        return DetailModel(
            id: "conversation-\(latest.pr.url)",
            header: Header(caption: latest.pr.label, title: latest.pr.title, url: latest.pr.url),
            content: .conversation(entries)
        )
    }

    private static func openPRs(_ prs: Snapshot.OpenPRs) -> DetailModel? {
        guard !prs.items.isEmpty else { return nil }
        // The ones that need something from you first.
        let ranked = prs.items.sorted {
            (urgency(of: $0), $1.updatedAt) < (urgency(of: $1), $0.updatedAt)
        }
        let rows = ranked.prefix(6).map { pr in
            let (symbol, lead, tint) = status(of: pr)
            return Row(
                id: pr.ref.url.absoluteString,
                leading: .symbol(symbol, tint),
                title: pr.ref.title,
                lead: lead,
                leadTint: tint,
                rest: " · \(pr.ref.label) · \(size(pr.additions, pr.deletions))",
                url: pr.ref.url
            )
        }
        return DetailModel(
            id: "openPRs",
            header: Header(title: "Your open pull requests", trailing: "\(prs.total)", url: URL(string: "https://github.com/pulls")),
            content: .rows(Array(rows), more: more(prs.total - rows.count, url: "https://github.com/pulls"))
        )
    }

    private static func reviews(_ queue: Snapshot.ReviewQueue) -> DetailModel? {
        guard !queue.items.isEmpty else { return nil }
        let rows = queue.items.prefix(6).map { request in
            Row(
                id: request.ref.url.absoluteString,
                leading: .avatar(request.avatar, fallback: "person.crop.circle"),
                title: request.ref.title,
                lead: request.author.map { "@\($0)" } ?? request.ref.label,
                leadTint: Palette.green,
                rest: (request.author == nil ? "" : " · \(request.ref.label)")
                    + " · \(size(request.additions, request.deletions)) · opened \(relative(request.openedAt))",
                url: request.ref.url
            )
        }
        let url = "https://github.com/pulls/review-requested"
        return DetailModel(
            id: "reviews",
            header: Header(title: "Waiting for your review", trailing: "\(queue.count)", url: URL(string: url)),
            content: .rows(Array(rows), more: more(queue.count - rows.count, url: url))
        )
    }

    private static func checks(_ prs: [Snapshot.PullRequest]) -> DetailModel? {
        let failing = prs.filter { $0.checks == .failing }
        let running = prs.filter { $0.checks == .pending }
        let passing = prs.filter { $0.checks == .passing }
        guard !(failing + running + passing).isEmpty else { return nil }

        var rows = failing.map { pr in
            Row(
                id: pr.ref.url.absoluteString,
                leading: .symbol("xmark.circle.fill", Palette.red),
                title: pr.ref.title,
                lead: pr.failingChecks.isEmpty ? "Failing" : "\(names(pr.failingChecks)) failed",
                leadTint: Palette.red,
                rest: " · \(pr.ref.label)",
                url: pr.ref.url
            )
        }
        rows += running.map { pr in
            Row(
                id: pr.ref.url.absoluteString,
                leading: .symbol("clock.fill", Palette.amber),
                title: pr.ref.title,
                lead: pr.runningChecks.isEmpty ? "Running" : "\(names(pr.runningChecks)) running",
                leadTint: Palette.amber,
                rest: " · \(pr.ref.label)",
                url: pr.ref.url
            )
        }

        // When something needs attention, the passing ones only need counting.
        var more: Row?
        if rows.isEmpty {
            rows = passing.map { pr in
                Row(
                    id: pr.ref.url.absoluteString,
                    leading: .symbol("checkmark.circle.fill", Palette.green),
                    title: pr.ref.title,
                    lead: "Passing",
                    leadTint: Palette.green,
                    rest: " · \(pr.ref.label)",
                    url: pr.ref.url
                )
            }
        } else if !passing.isEmpty {
            more = Row(
                id: "passing",
                leading: .symbol("checkmark.circle", Palette.green),
                title: "\(passing.count) more passing",
                lead: "",
                leadTint: Palette.secondary,
                rest: passing.prefix(3).map(\.ref.label).joined(separator: ", ") + (passing.count > 3 ? "…" : ""),
                url: URL(string: "https://github.com/pulls")
            )
        }

        let total = failing.count + running.count + passing.count
        return DetailModel(
            id: "checks",
            header: Header(title: "Checks on your pull requests", trailing: "\(passing.count)/\(total) passing", url: URL(string: "https://github.com/pulls")),
            content: .rows(Array(rows.prefix(6)), more: more)
        )
    }

    private static func merged(_ merged: Snapshot.Merged) -> DetailModel? {
        guard !merged.items.isEmpty else { return nil }
        let rows = merged.items.prefix(6).map { pr in
            Row(
                id: pr.ref.url.absoluteString,
                leading: .symbol("arrow.triangle.merge", Palette.green),
                title: pr.ref.title,
                lead: pr.ref.label,
                leadTint: Palette.secondary,
                rest: pr.mergedAt.map { " · merged \(relative($0))" } ?? "",
                url: pr.ref.url
            )
        }
        let url = "https://github.com/pulls?q=is%3Apr+author%3A%40me+is%3Amerged"
        return DetailModel(
            id: "merged",
            header: Header(title: "Merged in the last 7 days", trailing: "\(merged.count)", url: URL(string: url)),
            content: .rows(Array(rows), more: more(merged.count - rows.count, url: url))
        )
    }

    private static func activity(_ contributions: Snapshot.Contributions, login: String) -> DetailModel? {
        guard !contributions.days.isEmpty else { return nil }
        return DetailModel(
            id: "activity",
            header: Header(title: "Your last two weeks", trailing: "\(contributions.thisWeek) this week", url: URL(string: "https://github.com/\(login)")),
            content: .activity(Activity(
                days: contributions.days,
                thisWeek: contributions.thisWeek,
                lastWeek: contributions.lastWeek,
                streak: contributions.streak
            ))
        )
    }

    // MARK: - Helpers

    private static func urgency(of pr: Snapshot.PullRequest) -> Int {
        guard pr.review != .draft else { return 5 }
        if pr.checks == .failing { return 0 }
        switch pr.review {
        case .changesRequested: return 1
        case .approved: return pr.checks == .pending ? 3 : 2
        case .waiting, .draft: return 4
        }
    }

    private static func status(of pr: Snapshot.PullRequest) -> (symbol: String, lead: String, tint: Color) {
        if pr.review == .draft { return ("pencil.circle.fill", "Draft", Palette.tertiary) }
        if pr.checks == .failing {
            let lead = pr.failingChecks.isEmpty ? "Checks failing" : "\(names(pr.failingChecks)) failed"
            return ("xmark.circle.fill", lead, Palette.red)
        }
        switch pr.review {
        case .changesRequested: return ("exclamationmark.circle.fill", "Changes requested", Palette.amber)
        case .approved where pr.checks == .pending: return ("checkmark.circle.fill", "Approved, checks running", Palette.green)
        case .approved: return ("checkmark.circle.fill", "Ready to merge", Palette.green)
        case .waiting, .draft:
            return pr.checks == .pending
                ? ("clock.fill", "In review, checks running", Palette.secondary)
                : ("eye.circle.fill", "In review", Palette.secondary)
        }
    }

    private static func more(_ count: Int, url: String) -> Row? {
        guard count > 0 else { return nil }
        return Row(
            id: "more",
            leading: .symbol("ellipsis.circle", Palette.tertiary),
            title: "\(count) more on GitHub",
            lead: "",
            leadTint: Palette.secondary,
            url: URL(string: url)
        )
    }

    /// "build, lint" or "build, lint and 3 more".
    private static func names(_ names: [String]) -> String {
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) and \(names.count - 2) more" : shown
    }

    private static func size(_ additions: Int, _ deletions: Int) -> String {
        "+\(additions) −\(deletions)"
    }

    private static func relative(_ date: Date) -> String {
        CardModel.relative(date)
    }
}

/// A piece of a comment, parsed from its Markdown just enough to read well in a popover.
enum TextBlock: Hashable {
    case paragraph(AttributedString)
    case heading(AttributedString)
    case quote(AttributedString)
    case code(String, label: String?)
    /// Marks where a long comment was cut off.
    case truncated

    /// Splits Markdown into paragraphs, headings, quotes and code. Inline styling
    /// (bold, italics, code spans, links) is kept; lists keep their bullets.
    static func parse(_ markdown: String, limit: Int = 1_400) -> [TextBlock] {
        var blocks: [TextBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?
        var codeLabel: String?
        var budget = limit
        var isCut = false

        /// The line, or as much of it as the budget allows, cut at a word.
        func take(_ text: some StringProtocol) -> String? {
            guard budget > 0 else { return nil }
            guard text.count > budget else {
                budget -= text.count
                return String(text)
            }
            let fits = text.prefix(budget)
            budget = 0
            isCut = true
            return String(fits[..<(fits.lastIndex(of: " ") ?? fits.endIndex)]) + "…"
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(inline(quote.joined(separator: "\n"))))
            quote = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if var lines = code {
                if line.hasPrefix("```") || line.hasPrefix("~~~") {
                    blocks.append(.code(lines.prefix(12).joined(separator: "\n"), label: codeLabel))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            guard budget > 0 else {
                if line.isEmpty { continue }
                isCut = true
                break
            }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                flushQuote()
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                codeLabel = language == "suggestion" ? "Suggested change" : nil
                code = []
            } else if line.isEmpty {
                flushParagraph()
                flushQuote()
            } else if line.hasPrefix(">") {
                flushParagraph()
                var text = line.drop(while: { $0 == ">" || $0 == " " })
                // GitHub alerts: > [!NOTE], > [!WARNING]…
                if text.hasPrefix("[!"), let end = text.firstIndex(of: "]") {
                    text = Substring(text[text.index(text.startIndex, offsetBy: 2)..<end].capitalized)
                }
                if !text.isEmpty, let text = take(text) { quote.append(text) }
            } else if let heading = line.firstMatch(of: /^#{1,6}\s+(.*)$/) {
                flushParagraph()
                flushQuote()
                if let text = take(heading.1) { blocks.append(.heading(inline(text))) }
            } else if let item = line.firstMatch(of: /^[-*+]\s+(\[[ xX]\]\s+)?(.*)$/) {
                flushQuote()
                let box = item.1.map { $0.contains("x") || $0.contains("X") ? "☑ " : "☐ " } ?? "• "
                if let text = take(item.2) { paragraph.append(box + text) }
            } else if line.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" }) && line.count >= 3 {
                flushParagraph()
                flushQuote()
            } else {
                flushQuote()
                if let text = take(line) { paragraph.append(text) }
            }
        }
        if let code { blocks.append(.code(code.prefix(12).joined(separator: "\n"), label: codeLabel)) }
        flushParagraph()
        flushQuote()
        if isCut { blocks.append(.truncated) }
        return blocks
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
