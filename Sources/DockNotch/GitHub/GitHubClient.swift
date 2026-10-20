import Foundation

/// Fetches everything the notch shows in a single GraphQL round trip via `gh api graphql`.
struct GitHubClient: Sendable {
    let runner: GHRunner

    func fetchSnapshot(qualifier: String, now: Date = .now) async throws -> Snapshot {
        let scope = qualifier.isEmpty ? "" : " \(qualifier)"
        let weekAgo = now.addingTimeInterval(-7 * 86_400).formatted(.iso8601.year().month().day())

        let result = try await runner.run([
            "api", "graphql",
            "-f", "query=\(Self.query)",
            "-f", "authored=is:pr is:open author:@me archived:false\(scope)",
            "-f", "review=is:pr is:open review-requested:@me archived:false sort:updated-desc\(scope)",
            "-f", "merged=is:pr author:@me is:merged merged:>=\(weekAgo) sort:updated-desc\(scope)",
            // Only open PRs: talk on merged or closed ones is done with.
            "-f", "recent=is:pr is:open involves:@me archived:false sort:updated-desc\(scope)",
        ])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // gh exits non-zero when GraphQL reports errors, even if partial data came
        // back (e.g. an org that enforces SSO). Use the data whenever there is some.
        guard let response = try? decoder.decode(GQLResponse.self, from: result.stdout) else {
            throw Self.error(from: result)
        }
        guard let payload = response.data else {
            throw GitHubError.failed(response.errors?.first?.message ?? Self.error(from: result).localizedDescription)
        }
        return Snapshot(payload: payload)
    }

    private static func error(from result: ProcessResult) -> GitHubError {
        let message = result.stderrText
        if message.contains("gh auth login") || message.localizedCaseInsensitiveContains("not logged in") {
            return .notAuthenticated
        }
        return .failed(message.isEmpty ? "gh exited with status \(result.status)" : message)
    }

    private static let query = """
    query($authored: String!, $review: String!, $merged: String!, $recent: String!) {
      viewer {
        login
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks { contributionDays { contributionCount date } }
          }
        }
      }
      authored: search(query: $authored, type: ISSUE, first: 50) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url isDraft reviewDecision additions deletions updatedAt
            repository { nameWithOwner }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    state
                    contexts(first: 50) {
                      nodes {
                        __typename
                        ... on CheckRun { name conclusion status }
                        ... on StatusContext { context state }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      reviewRequested: search(query: $review, type: ISSUE, first: 10) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url createdAt additions deletions
            repository { nameWithOwner }
            author { __typename login avatarUrl(size: 128) }
          }
        }
      }
      merged: search(query: $merged, type: ISSUE, first: 10) {
        issueCount
        nodes {
          ... on PullRequest { number title url mergedAt repository { nameWithOwner } }
        }
      }
      recent: search(query: $recent, type: ISSUE, first: 15) {
        nodes {
          ... on PullRequest {
            number title url
            repository { nameWithOwner }
            comments(last: 6) {
              nodes { id body createdAt url author { __typename login avatarUrl(size: 128) } }
            }
            reviews(last: 6) {
              nodes {
                id body state submittedAt url
                author { __typename login avatarUrl(size: 128) }
                comments(first: 3) { nodes { body path } }
              }
            }
          }
        }
      }
    }
    """
}

// MARK: - Wire format

struct GQLResponse: Decodable {
    let data: Payload?
    let errors: [GQLError]?
}

struct GQLError: Decodable {
    let message: String
}

struct Payload: Decodable {
    let viewer: Viewer
    let authored: Search<AuthoredPR>
    let reviewRequested: Search<RequestedPR>
    let merged: Search<MergedPR>
    let recent: Search<RecentPR>
}

/// A search result or connection. Nodes that fail to decode (search can return
/// non-PR items, or null for inaccessible ones) are dropped instead of failing the batch.
struct Search<Node: Decodable>: Decodable {
    let issueCount: Int
    let nodes: [Node]

    private enum CodingKeys: CodingKey { case issueCount, nodes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueCount = try container.decodeIfPresent(Int.self, forKey: .issueCount) ?? 0
        nodes = (try container.decodeIfPresent([Lossy<Node>].self, forKey: .nodes) ?? []).compactMap(\.value)
    }
}

private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

struct Viewer: Decodable {
    struct Collection: Decodable { let contributionCalendar: ContributionCalendar }
    let login: String
    let contributionsCollection: Collection
}

struct ContributionCalendar: Decodable {
    struct Week: Decodable { let contributionDays: [Day] }
    struct Day: Decodable { let contributionCount: Int; let date: String }
    let totalContributions: Int
    let weeks: [Week]
}

struct Repository: Decodable {
    let nameWithOwner: String
    var name: String { nameWithOwner.split(separator: "/").last.map(String.init) ?? nameWithOwner }
}

struct GitHubUser: Decodable {
    let __typename: String?
    let login: String
    let avatarUrl: URL?
    var isBot: Bool { __typename == "Bot" || login.hasSuffix("[bot]") }
}

struct AuthoredPR: Decodable {
    struct Commit: Decodable {
        struct Inner: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable {
            let state: String
            let contexts: Search<CheckContext>
        }
        let commit: Inner
    }
    /// A check run (GitHub Actions and other apps) or a commit status (older integrations).
    struct CheckContext: Decodable {
        let name: String?
        let conclusion: String?
        let status: String?
        let context: String?
        let state: String?
    }
    let number: Int
    let title: String
    let url: URL
    let isDraft: Bool
    let reviewDecision: String?
    let additions: Int
    let deletions: Int
    let updatedAt: Date
    let repository: Repository
    let commits: Search<Commit>
}

struct RequestedPR: Decodable {
    let number: Int
    let title: String
    let url: URL
    let createdAt: Date
    let additions: Int
    let deletions: Int
    let repository: Repository
    let author: GitHubUser?
}

struct MergedPR: Decodable {
    let number: Int
    let title: String
    let url: URL
    let mergedAt: Date?
    let repository: Repository
}

struct RecentPR: Decodable {
    struct Comment: Decodable {
        let id: String
        let body: String
        let createdAt: Date
        let url: URL
        let author: GitHubUser?
    }
    struct Review: Decodable {
        struct Inline: Decodable { let body: String; let path: String? }
        let id: String
        let body: String
        let state: String
        let submittedAt: Date?
        let url: URL
        let author: GitHubUser?
        let comments: Search<Inline>
    }
    let number: Int
    let title: String
    let url: URL
    let repository: Repository
    let comments: Search<Comment>
    let reviews: Search<Review>
}
