import AppKit
import SwiftUI

/// Development aid: `DockNotch --render <dir> [--sample] [--width <points>] [--details]`
/// writes the strip to a PNG once per rotating card, using live data from gh, or made-up
/// data that fills every card with `--sample`. `--width` is the space beside the Dock to
/// fill. `--details` also writes each card's hover popover.
@MainActor
enum CardRenderer {
    static func run(outputDirectory: String, sample: Bool, width: CGFloat, details: Bool) async {
        let store = NotchStore()
        if sample {
            store.load(.sample)
        } else {
            await store.refresh()
        }
        if let snapshot = store.snapshot {
            store.avatars.preload(snapshot.avatarURLs)
            for _ in 0..<50 where store.avatars.images.count < Set(snapshot.avatarURLs).count {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let height: CGFloat = 84
        let layout = StripLayout(width: width, height: height)
        store.setVisibleTiles(layout.tiles)

        let kinds = store.cards.isEmpty ? [store.current] : store.cards
        for kind in kinds {
            store.select(kind)
            let canvas = NotchView(store: store)
                .environment(\.notchIsStatic, true)
                .frame(
                    width: layout.totalWidth + notchShadowPadding * 2,
                    height: height + notchShadowPadding * 2
                )
                .background(LinearGradient(
                    colors: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.55, green: 0.35, blue: 0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            let url = directory.appendingPathComponent("\(kind.rawValue).png")
            try? png?.write(to: url)
            print(url.path)
        }

        guard details else { return }
        for kind in CardKind.allCases {
            store.select(kind)
            guard let model = DetailModel.make(for: .card, store: store) else { continue }
            // Rendered without a size limit, so a long conversation shows in full rather than
            // as a scroll view, which ImageRenderer can't draw.
            let canvas = DetailView(
                model: model, avatars: store.avatars,
                pointer: DetailPointer(), open: { _ in }
            )
            .environment(\.notchIsStatic, true)
            .background(LinearGradient(
                colors: [Color(red: 0.35, green: 0.55, blue: 0.85), Color(red: 0.55, green: 0.35, blue: 0.75)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 2
            guard let image = renderer.cgImage else { continue }
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            let url = directory.appendingPathComponent("detail-\(kind.rawValue).png")
            try? png?.write(to: url)
            print(url.path)
        }
    }
}

private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when drawing a still image, so views skip their entrance animations.
    var notchIsStatic: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

extension Snapshot {
    static var sample: Snapshot {
        let mona = URL(string: "https://avatars.githubusercontent.com/u/583231?s=128")
        let hour: TimeInterval = 3_600
        func ref(_ repo: String, _ number: Int, _ title: String) -> PRRef {
            PRRef(repo: repo, number: number, title: title, url: URL(string: "https://github.com/acme/\(repo)/pull/\(number)")!)
        }
        func pr(
            _ ref: PRRef, _ review: PullRequest.Review, _ checks: PullRequest.Checks,
            failing: [String] = [], running: [String] = [], _ additions: Int, _ deletions: Int, updated: TimeInterval
        ) -> PullRequest {
            PullRequest(
                ref: ref, review: review, checks: checks, failingChecks: failing, runningChecks: running,
                additions: additions, deletions: deletions, updatedAt: .now.addingTimeInterval(-updated * hour)
            )
        }

        let settings = ref("web", 233, "Move settings into a sheet")
        let counts = [4, 7, 0, 3, 9, 6, 2, 12, 9, 15, 0, 11, 13, 8]
        let today = Calendar.current.startOfDay(for: .now)
        let days = counts.enumerated().map { index, count in
            Contributions.Day(date: today.addingTimeInterval(Double(index - counts.count + 1) * 86_400), count: count)
        }

        let conversation = [
            Comment(
                id: "c1", kind: .comment, author: "octocat", avatar: nil, byViewer: true,
                text: "Moved the settings into a sheet.",
                body: "Moved the settings into a sheet so they don't take over the whole window. The old pane is still reachable from **Preferences → Legacy** until we remove it.",
                notes: [], date: .now.addingTimeInterval(-26 * hour), url: settings.url, pr: settings
            ),
            Comment(
                id: "c2", kind: .reviewed, author: "hubot", avatar: nil, byViewer: false,
                text: "The sheet feels cramped on small screens.", body: "",
                notes: [Comment.Note(
                    path: "Sources/Settings/SettingsSheet.swift",
                    body: "The sheet feels cramped on small screens.\n\n```suggestion\n.presentationDetents([.medium, .large])\n```"
                )],
                date: .now.addingTimeInterval(-5 * hour), url: settings.url, pr: settings
            ),
            Comment(
                id: "c3", kind: .comment, author: "octocat", avatar: nil, byViewer: true,
                text: "Good call, applied.",
                body: "Good call, applied. Also fixed the `lint` warning about the unused binding.",
                notes: [], date: .now.addingTimeInterval(-3 * hour), url: settings.url, pr: settings
            ),
            Comment(
                id: "sample", kind: .comment, author: "mona", avatar: mona, byViewer: false,
                text: "Looks great. Could you add a test for the empty state before we merge?",
                body: "Looks great. Could you add a test for the empty state before we merge?\n\n> What happens when there are no accounts?\n\nThat path crashed for me locally.",
                notes: [], date: .now.addingTimeInterval(-720), url: settings.url, pr: settings
            ),
        ]

        let pullRequests = [
            pr(settings, .waiting, .failing, failing: ["build (macos-14)", "lint"], 214, 58, updated: 0.2),
            pr(ref("api", 801, "Stream large exports"), .approved, .passing, 96, 12, updated: 2),
            pr(ref("api", 795, "Cache org lookups"), .approved, .pending, running: ["integration"], 40, 7, updated: 1),
            pr(ref("web", 240, "Keyboard shortcuts for the inbox"), .approved, .passing, 130, 22, updated: 20),
            pr(ref("api", 790, "Retry webhooks with backoff"), .changesRequested, .passing, 61, 19, updated: 6),
            pr(ref("web", 236, "Dark mode for charts"), .waiting, .passing, 88, 30, updated: 30),
            pr(ref("docs", 57, "Write the migration guide"), .draft, .passing, 310, 4, updated: 50),
        ]

        return Snapshot(
            login: "octocat",
            contributions: Contributions(
                total: 1_346, thisWeek: 68, lastWeek: 31,
                weekly: [12, 18, 9, 22, 30, 14, 26, 41, 19, 35, 28, 44, 38, 52, 31, 47, 58, 40, 63, 49, 71, 55, 31, 68],
                days: days, streak: 3
            ),
            openPRs: OpenPRs(total: 7, approved: 3, changesRequested: 1, awaitingReview: 2, drafts: 1, items: pullRequests),
            reviewQueue: ReviewQueue(count: 4, items: [
                ReviewRequest(ref: ref("api", 812, "Rate-limit the webhook retries"), author: "mona", avatar: mona,
                              openedAt: .now.addingTimeInterval(-3 * hour), additions: 72, deletions: 15),
                ReviewRequest(ref: ref("web", 244, "Split the settings store"), author: "hubot", avatar: nil,
                              openedAt: .now.addingTimeInterval(-26 * hour), additions: 180, deletions: 96),
                ReviewRequest(ref: ref("mobile", 91, "Offline queue for drafts"), author: "mona", avatar: mona,
                              openedAt: .now.addingTimeInterval(-50 * hour), additions: 412, deletions: 120),
                ReviewRequest(ref: ref("api", 808, "Bump the Postgres driver"), author: "lumen", avatar: nil,
                              openedAt: .now.addingTimeInterval(-98 * hour), additions: 8, deletions: 8),
            ]),
            checks: Checks(passing: 5, failing: 1, pending: 1, firstFailing: settings),
            merged: Merged(count: 3, items: [
                MergedPR(ref: ref("web", 229, "Faster cold start"), mergedAt: .now.addingTimeInterval(-2 * hour)),
                MergedPR(ref: ref("api", 784, "Drop the legacy auth path"), mergedAt: .now.addingTimeInterval(-27 * hour)),
                MergedPR(ref: ref("web", 226, "Fix the flaky upload test"), mergedAt: .now.addingTimeInterval(-75 * hour)),
            ]),
            latestComment: conversation.last,
            conversation: conversation
        )
    }
}
